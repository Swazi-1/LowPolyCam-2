import AVFoundation
import Combine
import Foundation
import Photos
import UIKit

// MARK: - CameraManager: Capture-session configuration, format application, movie-output validation, rotation, and flash resolution.

extension CameraManager {
    func configureSessionIfNeeded(forceRebuild: Bool = false) {
        let hasVideo = videoInput.map { current in
            session.inputs.contains(where: { $0 === current })
        } ?? false
        let hasMovie = session.outputs.contains(where: { $0 === movieOutput })
        let hasPhoto = session.outputs.contains(where: { $0 === photoOutput })
        if !forceRebuild, hasVideo, hasMovie, hasPhoto {
            publishAudioStatus()
            configureAudioMeterOutput()
            return
        }

        invalidateVerifiedHighOutputProvenance()
        movieOutputUsesSystemDefaultCompression = false
        invalidateCodecSupportCache()
        AppEventLog.event("Configuring camera session\(forceRebuild ? " rebuild" : "")")

        invalidatePendingVideoConfiguration()
        lensTransitionCoordinator.cancel()
        _ = qualityRequests.next()
        _ = captureConfigurationGeneration.next()
        stopLiveMetrics()

        // LowPolyCam targets iOS 26+, where AVFoundation can bring up preview before
        // noncritical capture outputs finish initialization. Keep automatic deferred start
        // enabled explicitly so this performance behavior is part of our session contract.
        session.automaticallyRunsDeferredStart = true
        session.beginConfiguration()
        session.sessionPreset = .inputPriority

        // A partial setup is not considered configured. Rebuild from a known clean state so
        // an earlier input/output failure cannot permanently wedge this CameraManager.
        for input in session.inputs {
            session.removeInput(input)
        }
        for output in session.outputs {
            session.removeOutput(output)
        }
        videoInput = nil
        audioInput = nil
        audioMeter.setEnabled(false)
        publishAudioStatus()

        guard let device = preferredCamera(for: cameraPosition.avPosition) else {
            session.commitConfiguration()
            showError("Camera is unavailable on this device.")
            return
        }

        do {
            let input = try AVCaptureDeviceInput(device: device)
            guard session.canAddInput(input) else {
                session.commitConfiguration()
                showError("Couldn’t add the camera input.")
                return
            }
            session.addInput(input)
            videoInput = input
        } catch {
            session.commitConfiguration()
            showError("Couldn’t access the camera.")
            return
        }

        // Microphone is optional so Photo mode still works when microphone permission is denied.
        if let input = makeAuthorizedAudioInput(), session.canAddInput(input) {
            session.addInput(input)
            audioInput = input
            AppEventLog.event("Microphone audio input attached during session configuration")
            publishAudioStatus()
        } else {
            AppEventLog.event("Microphone audio input not attached during session configuration: authorization=\(AVCaptureDevice.authorizationStatus(for: .audio).rawValue)")
            publishAudioStatus()
        }

        guard session.canAddOutput(movieOutput) else {
            for input in session.inputs { session.removeInput(input) }
            videoInput = nil
            session.commitConfiguration()
            showError("Video recording is unavailable on this device.")
            return
        }

        // iOS 26+ Deferred Start: recording and photo outputs aren't required for the first
        // preview frame. Mark them as deferred before the configuration commit so AVFoundation
        // can prioritize bringing up AVCaptureVideoPreviewLayer first.
        if movieOutput.isDeferredStartSupported {
            movieOutput.isDeferredStartEnabled = true
        }
        session.addOutput(movieOutput)

        guard session.canAddOutput(photoOutput) else {
            session.removeOutput(movieOutput)
            for input in session.inputs { session.removeInput(input) }
            videoInput = nil
            session.commitConfiguration()
            showError("Photo capture is unavailable on this device.")
            return
        }
        photoOutput.maxPhotoQualityPrioritization = .quality
        if photoOutput.isDeferredStartSupported {
            photoOutput.isDeferredStartEnabled = true
        }
        session.addOutput(photoOutput)
        if photoOutput.isResponsiveCaptureSupported {
            photoOutput.isResponsiveCaptureEnabled = true
        }

        // Fold the optional audio-meter output into the initial transaction. Previously this was
        // added by configureAudioMeterOutput() immediately after commitConfiguration(), which
        // forced a second capture-session transaction during startup. The connection remains
        // disabled until an actual recording needs meter samples.
        let wantsInitialAudioMeter = audioInput != nil && captureMode != .photo && audioLevelMeterMode != .off
        if wantsInitialAudioMeter, session.canAddOutput(audioMeter.output) {
            if audioMeter.output.isDeferredStartSupported {
                audioMeter.output.isDeferredStartEnabled = true
            }
            session.addOutput(audioMeter.output)
        }

        session.commitConfiguration()
        configureAudioMeterOutput()

        let formatApplied = applyActiveModeFormat(preferVirtualCamera: !requiresPhysicalWhiteBalanceInput)
        if formatApplied {
            deferredWhiteBalanceRequest = nil
        }
        synchronizeTorchState()
        AppEventLog.event("Camera session configured")
        logSessionSnapshot("after session configuration")
    }







    @discardableResult
    func applyAtomicCaptureConfiguration(
        device desiredDevice: AVCaptureDevice,
        format: AVCaptureDevice.Format,
        frameRate: Double,
        photoDimensions: CMVideoDimensions? = nil,
        preparedReplacementInput: AVCaptureDeviceInput? = nil,
        refreshAuxiliaryOutputs: Bool = true,
        requestedCodec: String? = nil
    ) -> CGFloat? {
        let transactionTrace = AppEventLog.extremeDiagnosticsEnabled ? AppEventLog.makeTraceID("CAPTURE-TX") : nil
        let transactionStart = ProcessInfo.processInfo.systemUptime
        let oldDeviceForTrace = videoInput?.device
        let oldDimensionsForTrace = oldDeviceForTrace.map { CMVideoFormatDescriptionGetDimensions($0.activeFormat.formatDescription) }
        let oldFPSForTrace: Double = oldDeviceForTrace.map {
            let duration = $0.activeVideoMinFrameDuration.seconds
            return duration > 0 ? 1 / duration : 0
        } ?? 0
        let beforeTraceState: [String: String] = [
            "device": oldDeviceForTrace?.localizedName ?? "none",
            "format": oldDimensionsForTrace.map { "\($0.width)x\($0.height)" } ?? "none",
            "fps": String(format: "%.2f", oldFPSForTrace),
            "deviceZoom": oldDeviceForTrace.map { String(format: "%.3f", Double($0.videoZoomFactor)) } ?? "none",
            "requestedZoom": String(format: "%.3f", Double(requestedZoom)),
            "inputs": String(session.inputs.count),
            "outputs": String(session.outputs.count)
        ]
        let targetDimensionsForTrace = CMVideoFormatDescriptionGetDimensions(format.formatDescription)
        AppEventLog.deepEvent("CAPTURE TRANSACTION REQUEST", category: .session, traceID: transactionTrace, fields: [
            "targetDevice": desiredDevice.localizedName,
            "targetFormat": "\(targetDimensionsForTrace.width)x\(targetDimensionsForTrace.height)",
            "targetFPS": String(format: "%.2f", frameRate),
            "photoDimensions": photoDimensions.map { "\($0.width)x\($0.height)" } ?? "none",
            "requestedCodec": requestedCodec ?? activeVideoCodec,
            "refreshAuxiliaryOutputs": String(refreshAuxiliaryOutputs)
        ])
        let effectiveCodec = requestedCodec ?? activeVideoCodec
        let currentInput = videoInput
        let displayedZoomCandidate = snappedZoomFactor(requestedZoom, for: desiredDevice)
        let targetDeviceZoomCandidate = deviceZoomFactor(for: displayedZoomCandidate, device: desiredDevice)
        let activeMinDuration = desiredDevice.activeVideoMinFrameDuration.seconds
        let activeMaxDuration = desiredDevice.activeVideoMaxFrameDuration.seconds
        let activeMinFrameRate = activeMinDuration > 0 ? 1 / activeMinDuration : 0
        let activeMaxFrameRate = activeMaxDuration > 0 ? 1 / activeMaxDuration : 0
        let sameInput = currentInput?.device.uniqueID == desiredDevice.uniqueID
        let sameFormat = desiredDevice.activeFormat === format
        // A fixed requested rate requires BOTH AVFoundation duration bounds to match. Checking only
        // activeVideoMinFrameDuration can mistake a variable-FPS range for a settled fixed rate.
        let sameFrameRate = abs(activeMinFrameRate - frameRate) < 0.5 &&
            abs(activeMaxFrameRate - frameRate) < 0.5
        let samePhotoDimensions = photoDimensions.map { dimensions in
            photoOutput.maxPhotoDimensions.width == dimensions.width &&
                photoOutput.maxPhotoDimensions.height == dimensions.height
        } ?? true
        let auxiliaryGraphChangeNeeded = refreshAuxiliaryOutputs &&
            liveMetricsAttachmentWanted() != liveMetricsOutputIsAttached()
        let baseOutputsPresent = session.outputs.contains(where: { $0 === movieOutput }) &&
            session.outputs.contains(where: { $0 === photoOutput })

        // Most AVFoundation latency in the diagnostic session came from commitConfiguration().
        // If the capture graph/format/FPS is already exactly what was requested, do not open a
        // no-op session transaction just to re-assert zoom/HDR device properties. Those properties
        // can be updated directly under the AVCaptureDevice configuration lock.
        if sameInput, sameFormat, sameFrameRate, samePhotoDimensions,
           !auxiliaryGraphChangeNeeded, baseOutputsPresent {
            let desiredAutoHDR = effectiveCodec != "H264"
            let needsDeviceUpdate =
                abs(desiredDevice.videoZoomFactor - targetDeviceZoomCandidate) >= 0.005 ||
                desiredDevice.automaticallyAdjustsVideoHDREnabled != desiredAutoHDR ||
                (effectiveCodec == "H264" && desiredDevice.isVideoHDREnabled) ||
                (desiredDevice.isGeometricDistortionCorrectionSupported &&
                    !desiredDevice.isGeometricDistortionCorrectionEnabled)

            if needsDeviceUpdate {
                do {
                    try desiredDevice.lockForConfiguration()
                    desiredDevice.automaticallyAdjustsVideoHDREnabled = desiredAutoHDR
                    if effectiveCodec == "H264", desiredDevice.isVideoHDREnabled {
                        desiredDevice.isVideoHDREnabled = false
                    }
                    if desiredDevice.isGeometricDistortionCorrectionSupported {
                        desiredDevice.isGeometricDistortionCorrectionEnabled = true
                    }
                    desiredDevice.cancelVideoZoomRamp()
                    desiredDevice.videoZoomFactor = targetDeviceZoomCandidate
                    desiredDevice.unlockForConfiguration()
                } catch {
                    AppEventLog.log(error: error, prefix: "CAPTURE FAST PATH DEVICE UPDATE FAILED", category: .device, traceID: transactionTrace)
                    // Fall through to the normal atomic transaction, which retains the existing
                    // rollback/error behavior for a device that could not be updated directly.
                }
            }

            let zoomMatches = abs(desiredDevice.videoZoomFactor - targetDeviceZoomCandidate) < 0.02
            let hdrMatches = desiredDevice.automaticallyAdjustsVideoHDREnabled == desiredAutoHDR &&
                (effectiveCodec != "H264" || !desiredDevice.isVideoHDREnabled)
            let distortionMatches = !desiredDevice.isGeometricDistortionCorrectionSupported ||
                desiredDevice.isGeometricDistortionCorrectionEnabled
            if zoomMatches, hdrMatches, distortionMatches {
                setLiveMetricsConnectionEnabled(
                    (recordingState.requestsRecording && movieOutput.isRecording) ||
                    (AppEventLog.extremeDiagnosticsEnabled &&
                        liveMetricsOutputIsAttached() && captureMode != .photo)
                )
                rotationCoordinator = AVCaptureDevice.RotationCoordinator(device: desiredDevice, previewLayer: nil)
                requestedZoom = displayedZoomCandidate
                AppEventLog.deepEvent("CAPTURE TRANSACTION FAST PATH", category: .session, traceID: transactionTrace, fields: [
                    "device": desiredDevice.localizedName,
                    "format": "\(targetDimensionsForTrace.width)x\(targetDimensionsForTrace.height)",
                    "fps": String(format: "%.2f", activeMinFrameRate),
                    "displayedZoom": String(format: "%.3f", Double(displayedZoomCandidate)),
                    "reason": "capture graph already matched request",
                    "totalMs": String(format: "%.2f", (ProcessInfo.processInfo.systemUptime - transactionStart) * 1000)
                ])
                return displayedZoomCandidate
            }
        }

        // A real input/format/output transaction makes proof from the previous capture graph
        // unusable, including attempts that fail before AVFoundation accepts the replacement.
        invalidateVerifiedHighOutputProvenance()
        let oldInput = currentInput
        let shouldPreserveTorch = oldInput?.device.hasTorch == true && oldInput?.device.torchMode == .on
        let isSwitchingInput = oldInput?.device.uniqueID != desiredDevice.uniqueID
        let torchRequestID = torchRequests.next(reason: "capture configuration transaction")
        let shouldRetryTorchAfterPreviewHandoff = shouldPreserveTorch &&
            isSwitchingInput &&
            captureMode == .video &&
            cameraPosition == .back &&
            selectedResolution == .p4k &&
            selectedFrameRate == .fps60 &&
            !recordingState.requestsRecording &&
            !movieOutput.isRecording
        var replacementInput: AVCaptureDeviceInput?
        var torchRestoreDevice: AVCaptureDevice?

        func restoreSuspendedTorchIfPossible() {
            guard let device = torchRestoreDevice else { return }
            do {
                try device.lockForConfiguration()
                defer { device.unlockForConfiguration() }
                guard device.hasTorch, device.isTorchAvailable else {
                    AppEventLog.event("Torch could not be restored after camera input switch: unavailable on \(device.localizedName)")
                    return
                }
                let application = self.applyTorchConfigurationLocked(to: device, enabled: true)
                AppEventLog.event("Torch restored after camera input switch on \(device.localizedName)", category: .torch, fields: [
                    "requestedNormalizedLevel": String(format: "%.3f", application.requestedNormalizedLevel),
                    "actualTorchLevel": String(format: "%.3f", application.actualTorchLevel),
                    "torchAvailable": String(application.torchAvailable),
                    "device": application.deviceName,
                    "fallbackUsed": String(application.fallbackUsed)
                ])
                self.logTorchApplication(application, reason: "camera input switch restore")
            } catch {
                AppEventLog.event("Torch could not be restored after camera input switch: \(error.localizedDescription)")
            }
        }

        if isSwitchingInput {
            if let preparedReplacementInput,
               preparedReplacementInput.device.uniqueID == desiredDevice.uniqueID {
                replacementInput = preparedReplacementInput
            } else {
                do {
                    let inputStart = ProcessInfo.processInfo.systemUptime
                    replacementInput = try AVCaptureDeviceInput(device: desiredDevice)
                    AppEventLog.deepEvent("CAPTURE TX REPLACEMENT INPUT CREATED", category: .device, traceID: transactionTrace, fields: [
                        "device": desiredDevice.localizedName,
                        "durationMs": String(format: "%.2f", (ProcessInfo.processInfo.systemUptime - inputStart) * 1000)
                    ])
                } catch {
                    AppEventLog.log(error: error, prefix: "CAPTURE TX REPLACEMENT INPUT FAILED", category: .device, traceID: transactionTrace)
                    showError("Couldn’t access the selected camera.")
                    return nil
                }
            }
        }

        // Keeping the old device's torch active while removing that input can leave the physical
        // camera resource occupied as the replacement input starts. Device logs showed that exact
        // sequence interrupting the session during rear 4K60 lens handoffs. Suspend the torch
        // before the transaction and restore it only after commit, on whichever input survived.
        if isSwitchingInput, shouldPreserveTorch, let oldDevice = oldInput?.device {
            do {
                try oldDevice.lockForConfiguration()
                defer { oldDevice.unlockForConfiguration() }
                oldDevice.torchMode = .off
                torchRestoreDevice = oldDevice
                AppEventLog.event("Torch suspended before camera input switch from \(oldDevice.localizedName) to \(desiredDevice.localizedName)")
            } catch {
                AppEventLog.event("Camera input switch cancelled because the active torch could not be suspended: \(error.localizedDescription)")
                showError("Couldn’t safely switch cameras while the torch is on.")
                return nil
            }
        }

        let beginConfigurationAt = ProcessInfo.processInfo.systemUptime
        session.beginConfiguration()
        AppEventLog.deepEvent("SESSION beginConfiguration", category: .session, traceID: transactionTrace, fields: [
            "elapsedMs": String(format: "%.2f", (ProcessInfo.processInfo.systemUptime - transactionStart) * 1000),
            "switchingInput": String(isSwitchingInput)
        ])
        var committed = false
        if refreshAuxiliaryOutputs {
            configureLiveMetrics()
        }
        defer {
            if !committed {
                let fallbackCommitStart = ProcessInfo.processInfo.systemUptime
                session.commitConfiguration()
                AppEventLog.deepEvent("SESSION fallback commitConfiguration", category: .session, level: .warning, traceID: transactionTrace, fields: [
                    "durationMs": String(format: "%.2f", (ProcessInfo.processInfo.systemUptime - fallbackCommitStart) * 1000)
                ])
            }
            restoreSuspendedTorchIfPossible()
            if committed, shouldRetryTorchAfterPreviewHandoff {
                scheduleTorchRestoreAfterLensHandoff(on: desiredDevice, requestID: torchRequestID)
            }
        }

        if isSwitchingInput {
            if let oldInput { session.removeInput(oldInput) }
            guard let replacementInput, session.canAddInput(replacementInput) else {
                AppEventLog.guardRejected("capture transaction input replacement", reason: "session cannot add replacement input", traceID: transactionTrace, fields: [
                    "targetDevice": desiredDevice.localizedName,
                    "oldDevice": oldInput?.device.localizedName ?? "none"
                ])
                if let oldInput, session.canAddInput(oldInput) {
                    session.addInput(oldInput)
                    videoInput = oldInput
                } else {
                    torchRestoreDevice = nil
                }
                return nil
            }
            session.addInput(replacementInput)
            videoInput = replacementInput
        }

        let displayedZoom = snappedZoomFactor(requestedZoom, for: desiredDevice)
        do {
            let lockRequestedAt = ProcessInfo.processInfo.systemUptime
            try desiredDevice.lockForConfiguration()
            let lockWaitMs = (ProcessInfo.processInfo.systemUptime - lockRequestedAt) * 1000
            AppEventLog.deepEvent("DEVICE LOCK ACQUIRED", category: .device, traceID: transactionTrace, fields: [
                "device": desiredDevice.localizedName,
                "waitMs": String(format: "%.2f", lockWaitMs)
            ])
            if lockWaitMs > 100 {
                AppEventLog.event("SLOW DEVICE LOCK", category: .performance, level: .warning, traceID: transactionTrace,
                                  fields: ["waitMs": String(format: "%.2f", lockWaitMs), "device": desiredDevice.localizedName])
            }
            do {
                let lockHeldAt = ProcessInfo.processInfo.systemUptime
                defer {
                    let heldMs = (ProcessInfo.processInfo.systemUptime - lockHeldAt) * 1000
                    desiredDevice.unlockForConfiguration()
                    AppEventLog.deepEvent("DEVICE LOCK RELEASED", category: .device, traceID: transactionTrace,
                                          fields: ["heldMs": String(format: "%.2f", heldMs)])
                }

                desiredDevice.activeFormat = format
                desiredDevice.automaticallyAdjustsVideoHDREnabled = effectiveCodec != "H264"
                if effectiveCodec == "H264", desiredDevice.isVideoHDREnabled {
                    desiredDevice.isVideoHDREnabled = false
                }
                if desiredDevice.isGeometricDistortionCorrectionSupported {
                    desiredDevice.isGeometricDistortionCorrectionEnabled = true
                }

                let supportedRange = format.videoSupportedFrameRateRanges.first {
                    $0.minFrameRate <= frameRate + 0.5 && $0.maxFrameRate >= frameRate - 0.5
                } ?? format.videoSupportedFrameRateRanges.first
                let actualRate = min(max(frameRate, supportedRange?.minFrameRate ?? frameRate), supportedRange?.maxFrameRate ?? frameRate)
                let duration = CMTimeMakeWithSeconds(1.0 / max(actualRate, 1), preferredTimescale: 60_000)
                desiredDevice.activeVideoMinFrameDuration = duration
                desiredDevice.activeVideoMaxFrameDuration = duration

                desiredDevice.cancelVideoZoomRamp()
                desiredDevice.videoZoomFactor = deviceZoomFactor(for: displayedZoom, device: desiredDevice)
                if shouldPreserveTorch, !isSwitchingInput,
                   desiredDevice.hasTorch, desiredDevice.isTorchAvailable {
                    let application = applyTorchConfigurationLocked(to: desiredDevice, enabled: true)
                    logTorchApplication(application, reason: "capture configuration transaction")
                }
            }

            if let photoDimensions,
               (photoOutput.maxPhotoDimensions.width != photoDimensions.width ||
                photoOutput.maxPhotoDimensions.height != photoDimensions.height) {
                photoOutput.maxPhotoDimensions = photoDimensions
            }

            let commitStart = ProcessInfo.processInfo.systemUptime
            session.commitConfiguration()
            let commitMs = (ProcessInfo.processInfo.systemUptime - commitStart) * 1000
            committed = true
            AppEventLog.deepEvent("SESSION commitConfiguration", category: .session, traceID: transactionTrace, fields: [
                "commitMs": String(format: "%.2f", commitMs),
                "transactionMs": String(format: "%.2f", (ProcessInfo.processInfo.systemUptime - transactionStart) * 1000),
                "beginToCommitMs": String(format: "%.2f", (ProcessInfo.processInfo.systemUptime - beginConfigurationAt) * 1000)
            ])
            if commitMs > 250 {
                AppEventLog.event("SLOW SESSION COMMIT", category: .performance, level: .warning, traceID: transactionTrace,
                                  fields: ["commitMs": String(format: "%.2f", commitMs)])
            }
            setLiveMetricsConnectionEnabled(
                (recordingState.requestsRecording && movieOutput.isRecording) ||
                (AppEventLog.extremeDiagnosticsEnabled &&
                    liveMetricsOutputIsAttached() && captureMode != .photo)
            )
            rotationCoordinator = AVCaptureDevice.RotationCoordinator(device: desiredDevice, previewLayer: nil)
            requestedZoom = displayedZoom
            if shouldPreserveTorch, isSwitchingInput {
                torchRestoreDevice = desiredDevice
            }
            let afterDimensions = CMVideoFormatDescriptionGetDimensions(desiredDevice.activeFormat.formatDescription)
            let afterDuration = desiredDevice.activeVideoMinFrameDuration.seconds
            let afterFPS = afterDuration > 0 ? 1 / afterDuration : 0
            let afterTraceState: [String: String] = [
                "device": desiredDevice.localizedName,
                "format": "\(afterDimensions.width)x\(afterDimensions.height)",
                "fps": String(format: "%.2f", afterFPS),
                "deviceZoom": String(format: "%.3f", Double(desiredDevice.videoZoomFactor)),
                "requestedZoom": String(format: "%.3f", Double(displayedZoom)),
                "inputs": String(session.inputs.count),
                "outputs": String(session.outputs.count)
            ]
            AppEventLog.stateDiff("CAPTURE TRANSACTION", before: beforeTraceState, after: afterTraceState,
                                  traceID: transactionTrace, category: .session)
            AppEventLog.deepEvent("CAPTURE TRANSACTION COMPLETE", category: .session, traceID: transactionTrace, fields: [
                "totalMs": String(format: "%.2f", (ProcessInfo.processInfo.systemUptime - transactionStart) * 1000),
                "displayedZoom": String(format: "%.3f", Double(displayedZoom))
            ])
            return displayedZoom
        } catch {
            if isSwitchingInput {
                if let replacementInput, session.inputs.contains(where: { $0 === replacementInput }) {
                    session.removeInput(replacementInput)
                }
                if let oldInput, session.canAddInput(oldInput) {
                    session.addInput(oldInput)
                    videoInput = oldInput
                } else {
                    torchRestoreDevice = nil
                }
            }
            AppEventLog.log(error: error, prefix: "CAPTURE TRANSACTION FAILED", category: .session, traceID: transactionTrace)
            showError("Couldn’t configure the selected camera format.")
            return nil
        }
    }





    func preferredCamera(for position: AVCaptureDevice.Position) -> AVCaptureDevice? {
        let deviceTypes: [AVCaptureDevice.DeviceType] = position == .front
            ? [.builtInWideAngleCamera, .builtInUltraWideCamera]
            : [.builtInTripleCamera, .builtInDualWideCamera, .builtInDualCamera, .builtInWideAngleCamera]

        for type in deviceTypes {
            if let device = AVCaptureDevice.default(type, for: .video, position: position) {
                return device
            }
        }
        return nil
    }

    func capabilityDevices(for position: AVCaptureDevice.Position) -> [AVCaptureDevice] {
        var devices: [AVCaptureDevice] = []
        func append(_ device: AVCaptureDevice?) {
            guard let device, !devices.contains(where: { $0.uniqueID == device.uniqueID }) else { return }
            devices.append(device)
        }
        append(preferredCamera(for: position))
        append(AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: position))
        append(AVCaptureDevice.default(.builtInUltraWideCamera, for: .video, position: position))
        if position == .back {
            append(AVCaptureDevice.default(.builtInTelephotoCamera, for: .video, position: position))
        }
        return devices
    }

    func desiredPhysicalDevice(in devices: [AVCaptureDevice], forDisplayedZoom zoom: CGFloat) -> AVCaptureDevice? {
        let physical = devices.filter { !$0.isVirtualDevice }
        if zoom < 1 {
            return physical.first(where: { $0.deviceType == .builtInUltraWideCamera })
                ?? physical.first(where: { $0.deviceType == .builtInWideAngleCamera })
                ?? physical.first
        }
        if zoom >= 1.75, let tele = physical.first(where: { $0.deviceType == .builtInTelephotoCamera }) {
            return tele
        }
        return physical.first(where: { $0.deviceType == .builtInWideAngleCamera }) ?? physical.first
    }

    func telephotoOpticalFactor(for device: AVCaptureDevice) -> CGFloat {
        guard device.deviceType == .builtInTelephotoCamera,
              let wide = AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: device.position) else { return 1 }
        let wideFOV = Double(wide.activeFormat.videoFieldOfView) * .pi / 180
        let teleFOV = Double(device.activeFormat.videoFieldOfView) * .pi / 180
        guard wideFOV > 0, teleFOV > 0 else { return 2 }
        let factor = tan(wideFOV / 2) / tan(teleFOV / 2)
        return CGFloat(min(max(factor, 1.5), 8))
    }

    func resetFocusAndExposureState() {
        _ = focusExposureRequests.next(reason: "focus/exposure reset")
        pendingFocusLockWorkItem?.cancel()
        pendingFocusLockWorkItem = nil
        pendingFocusReturnWorkItem?.cancel()
        pendingFocusReturnWorkItem = nil
        focusLockedInHardware = false
        exposureLockedInHardware = false
        guard let device = videoInput?.device else {
            publish { self.isFocusExposureLocked = false }
            return
        }

        do {
            try device.lockForConfiguration()
            let center = CGPoint(x: 0.5, y: 0.5)
            if device.isFocusPointOfInterestSupported {
                device.focusPointOfInterest = center
            }
            if device.isExposurePointOfInterestSupported {
                device.exposurePointOfInterest = center
            }
            if device.isFocusModeSupported(.continuousAutoFocus) {
                device.focusMode = .continuousAutoFocus
            }
            if device.isExposureModeSupported(.continuousAutoExposure) {
                device.exposureMode = .continuousAutoExposure
            }
            let target = clampedExposureBias(requestedExposureBias, for: device)
            device.setExposureTargetBias(target, completionHandler: nil)
            device.unlockForConfiguration()
            publish {
                self.isFocusExposureLocked = false
                self.exposureBias = target
            }
        } catch {
            showError("Couldn’t reset focus and exposure.")
        }
    }

    func clampedExposureBias(_ bias: Float, for device: AVCaptureDevice) -> Float {
        let proToolsMinimum: Float = -2
        let proToolsMaximum: Float = 2
        return min(max(bias, max(device.minExposureTargetBias, proToolsMinimum)), min(device.maxExposureTargetBias, proToolsMaximum))
    }

    func applyExposureBias(_ bias: Float) {
        guard let device = videoInput?.device else { return }
        let target = clampedExposureBias(bias, for: device)
        guard abs(target - requestedExposureBias) >= 0.001 else { return }
        do {
            try device.lockForConfiguration()
            device.setExposureTargetBias(target, completionHandler: nil)
            device.unlockForConfiguration()
            requestedExposureBias = target
            publish { self.exposureBias = target }
        } catch {
            showError("Couldn’t adjust the exposure.")
        }
    }

    var requiresPhysicalWhiteBalanceInput: Bool {
        requestedWhiteBalancePreset != .auto && cameraPosition == .back
    }

    @discardableResult
    func applyWhiteBalancePresetToCurrentCamera(_ preset: WhiteBalancePreset) -> Bool {
        guard let device = videoInput?.device else { return false }

        // Auto WB is supported on virtual and physical cameras. Manual presets are only
        // considered successful on the actual capture input so the UI can't claim a change
        // that isn't visible in the rear Video/Photo stream.
        let applied = applyWhiteBalancePreset(preset, to: device)

        // Configure only the input actually owned by this capture session.
        return applied
    }

    @discardableResult
    func synchronizeWhiteBalanceAfterConfiguration() -> Bool {
        let preset = requestedWhiteBalancePreset
        guard applyWhiteBalancePresetToCurrentCamera(preset) else {
            if preset != .auto {
                requestedWhiteBalancePreset = .auto
                _ = applyWhiteBalancePresetToCurrentCamera(.auto)
                publish { self.whiteBalancePreset = .auto }
                showError("White balance reset to Auto because this camera configuration doesn’t support that preset.")
            } else {
                showError("Auto white balance is unavailable on this camera configuration.")
            }
            return false
        }
        publish { self.whiteBalancePreset = preset }
        return true
    }






    @discardableResult
    func applyWhiteBalancePreset(_ preset: WhiteBalancePreset, to device: AVCaptureDevice) -> Bool {
        let traceID = AppEventLog.extremeDiagnosticsEnabled ? AppEventLog.makeTraceID("WBHW") : nil
        let lockRequestedAt = ProcessInfo.processInfo.systemUptime
        do {
            try device.lockForConfiguration()
            let lockAcquiredAt = ProcessInfo.processInfo.systemUptime
            let beforeGains = device.deviceWhiteBalanceGains
            AppEventLog.deepEvent("WB DEVICE LOCK ACQUIRED", category: .whiteBalance, traceID: traceID, fields: [
                "device": device.localizedName,
                "waitMs": String(format: "%.3f", (lockAcquiredAt - lockRequestedAt) * 1000),
                "modeBefore": String(describing: device.whiteBalanceMode),
                "beforeR": String(format: "%.3f", beforeGains.redGain),
                "beforeG": String(format: "%.3f", beforeGains.greenGain),
                "beforeB": String(format: "%.3f", beforeGains.blueGain)
            ])
            defer {
                let afterGains = device.deviceWhiteBalanceGains
                device.unlockForConfiguration()
                AppEventLog.deepEvent("WB DEVICE UNLOCK", category: .whiteBalance, traceID: traceID, fields: [
                    "heldMs": String(format: "%.3f", (ProcessInfo.processInfo.systemUptime - lockAcquiredAt) * 1000),
                    "modeAfter": String(describing: device.whiteBalanceMode),
                    "afterR": String(format: "%.3f", afterGains.redGain),
                    "afterG": String(format: "%.3f", afterGains.greenGain),
                    "afterB": String(format: "%.3f", afterGains.blueGain)
                ])
            }

            if preset == .auto {
                if device.isWhiteBalanceModeSupported(.continuousAutoWhiteBalance) {
                    device.whiteBalanceMode = .continuousAutoWhiteBalance
                    return true
                }
                if device.isWhiteBalanceModeSupported(.autoWhiteBalance) {
                    device.whiteBalanceMode = .autoWhiteBalance
                    return true
                }
                return false
            }

            guard device.isWhiteBalanceModeSupported(.locked),
                  device.isLockingWhiteBalanceWithCustomDeviceGainsSupported else {
                return false
            }

            let temperature: Float
            let tint: Float
            if preset == .custom {
                temperature = Float(WhiteBalancePreferencePolicy.validatedTemperature(customWhiteBalanceTemperature))
                tint = Float(WhiteBalancePreferencePolicy.validatedTint(customWhiteBalanceTint))
            } else if let presetTemperature = preset.temperature {
                temperature = presetTemperature
                tint = preset.tint
            } else {
                return false
            }

            // Convert to device gains and clamp before applying. The temperature/tint setter can
            // raise an Objective-C range exception for values a particular lens rejects; Swift
            // do/catch cannot recover from that exception. iPhone 11 supports custom gains.
            let values = AVCaptureDevice.WhiteBalanceTemperatureAndTintValues(temperature: temperature, tint: tint)
            var gains = device.deviceWhiteBalanceGains(for: values)
            let maximum = device.maxWhiteBalanceGain
            gains.redGain = min(max(gains.redGain, 1), maximum)
            gains.greenGain = min(max(gains.greenGain, 1), maximum)
            gains.blueGain = min(max(gains.blueGain, 1), maximum)
            AppEventLog.deepEvent("WB LOCKED GAINS TARGET", category: .whiteBalance, traceID: traceID, fields: [
                "preset": preset.rawValue,
                "temperature": String(format: "%.1f", temperature),
                "tint": String(format: "%.1f", tint),
                "red": String(format: "%.3f", gains.redGain),
                "green": String(format: "%.3f", gains.greenGain),
                "blue": String(format: "%.3f", gains.blueGain),
                "maxGain": String(format: "%.3f", maximum)
            ])
            device.setWhiteBalanceModeLocked(with: gains, completionHandler: nil)
            return true
        } catch {
            AppEventLog.log(error: error, prefix: "White balance device configuration failed", category: .whiteBalance, traceID: traceID)
            return false
        }
    }

    func configureFocusAndExposure(at point: CGPoint, lockAfterFocusing: Bool, requestID: UInt64) {
        guard focusExposureRequests.isLatest(requestID),
              let device = videoInput?.device else { return }
        pendingFocusLockWorkItem?.cancel()
        pendingFocusReturnWorkItem?.cancel()
        pendingFocusLockWorkItem = nil
        pendingFocusReturnWorkItem = nil
        focusLockedInHardware = false
        exposureLockedInHardware = false

        let clampedPoint = CGPoint(
            x: min(max(point.x, 0), 1),
            y: min(max(point.y, 0), 1)
        )
        let defaults = UserDefaults.standard
        let lockPreference = defaults.string(forKey: LowPolyCamPreferences.Key.focusExposureLockMode) ?? "AE/AF"
        let wantsFocusLock = lockPreference != "AE Only"
        let wantsExposureLock = lockPreference != "AF Only"

        do {
            try device.lockForConfiguration()
            defer { device.unlockForConfiguration() }

            if device.isFocusPointOfInterestSupported {
                device.focusPointOfInterest = clampedPoint
            }
            if device.isFocusModeSupported(.autoFocus) {
                device.focusMode = .autoFocus
            } else if device.isFocusModeSupported(.continuousAutoFocus) {
                device.focusMode = .continuousAutoFocus
            }

            if device.isExposurePointOfInterestSupported {
                device.exposurePointOfInterest = clampedPoint
            }
            if device.isExposureModeSupported(.continuousAutoExposure) {
                device.exposureMode = .continuousAutoExposure
            } else if device.isExposureModeSupported(.autoExpose) {
                device.exposureMode = .autoExpose
            }
        } catch {
            showError("Couldn’t set focus and exposure.")
            return
        }

        publish { self.isFocusExposureLocked = false }
        AppEventLog.event(
            "Focus/exposure applied: point=(\(String(format: "%.3f", clampedPoint.x)), \(String(format: "%.3f", clampedPoint.y))), lock requested=\(lockAfterFocusing), preference=\(lockPreference)"
        )

        let deviceID = device.uniqueID

        if lockAfterFocusing {
            // Wait only for controls we can and actually intend to lock. On fixed-focus cameras
            // (for example an ultra-wide without AF), AE can still lock independently.
            let deadline = ProcessInfo.processInfo.systemUptime + 1.5

            func attemptLock() {
                guard self.focusExposureRequests.isLatest(requestID),
                      let current = self.videoInput?.device,
                      current.uniqueID == deviceID else { return }

                let canLockFocus = wantsFocusLock && current.isFocusModeSupported(.locked)
                let canLockExposure = wantsExposureLock &&
                    (current.isExposureModeSupported(.locked) || current.isExposureModeSupported(.custom))
                let focusStillSettling = canLockFocus && current.isAdjustingFocus
                let exposureStillSettling = canLockExposure && current.isAdjustingExposure

                if (focusStillSettling || exposureStillSettling), ProcessInfo.processInfo.systemUptime < deadline {
                    let retry = DispatchWorkItem { [weak self] in
                        guard let self else { return }
                        self.sessionQueue.async { attemptLock() }
                    }
                    self.pendingFocusLockWorkItem = retry
                    self.sessionQueue.asyncAfter(deadline: .now() + 0.06, execute: retry)
                    return
                }

                var focusApplied = false
                var exposureApplied = false
                do {
                    try current.lockForConfiguration()
                    defer { current.unlockForConfiguration() }

                    if canLockFocus {
                        // The current-position sentinel works even when arbitrary manual lens
                        // positions are unavailable; it freezes the position AF just reached.
                        current.setFocusModeLocked(
                            lensPosition: AVCaptureDevice.currentLensPosition,
                            completionHandler: nil
                        )
                        focusApplied = true
                    }

                    if canLockExposure {
                        if current.isExposureModeSupported(.locked) {
                            current.exposureMode = .locked
                        } else {
                            // Some devices expose custom exposure but not the simple locked mode.
                            // Preserve the current auto-selected values using AVFoundation's
                            // current-value sentinels instead of copying values that could race a frame.
                            current.setExposureModeCustom(
                                duration: AVCaptureDevice.currentExposureDuration,
                                iso: AVCaptureDevice.currentISO,
                                completionHandler: nil
                            )
                        }
                        exposureApplied = true
                    }
                } catch {
                    self.showError("Couldn’t lock focus and exposure.")
                    return
                }

                // Verify the modes after configuration instead of claiming a lock just because the
                // setters did not throw. This keeps the HUD truthful on lenses with partial support.
                let verify = DispatchWorkItem { [weak self, weak current] in
                    guard let self,
                          self.focusExposureRequests.isLatest(requestID),
                          let current,
                          self.videoInput?.device.uniqueID == deviceID else { return }

                    let focusVerified = focusApplied && current.focusMode == .locked
                    let exposureVerified = exposureApplied &&
                        (current.exposureMode == .locked || current.exposureMode == .custom)
                    self.focusLockedInHardware = focusVerified
                    self.exposureLockedInHardware = exposureVerified

                    let label: String
                    if focusVerified && exposureVerified {
                        label = "AE/AF • FOCUS + EXPOSURE"
                    } else if focusVerified {
                        label = "AF • FOCUS"
                    } else if exposureVerified {
                        label = "AE • EXPOSURE"
                    } else {
                        label = "AE/AF • FOCUS + EXPOSURE"
                    }
                    self.publish {
                        self.isFocusExposureLocked = focusVerified || exposureVerified
                        self.focusExposureLockLabel = label
                    }

                    AppEventLog.event(
                        "Focus/exposure lock verified: requested=\(lockPreference), focus=\(focusVerified), exposure=\(exposureVerified), " +
                        "focusMode=\(String(describing: current.focusMode)), exposureMode=\(String(describing: current.exposureMode))"
                    )

                    guard !focusVerified && !exposureVerified else { return }
                    switch lockPreference {
                    case "AF Only":
                        self.showError("AF lock isn’t supported on this lens.")
                    case "AE Only":
                        self.showError("AE lock isn’t supported on this lens.")
                    default:
                        self.showError("AE/AF lock isn’t supported by this camera configuration.")
                    }
                }
                self.pendingFocusLockWorkItem = verify
                self.sessionQueue.asyncAfter(deadline: .now() + 0.05, execute: verify)
            }
            attemptLock()
        } else {
            let resetSeconds = defaults.integer(forKey: LowPolyCamPreferences.Key.tapFocusResetSeconds)
            guard resetSeconds > 0 else {
                AppEventLog.event("Tap focus auto-reset disabled")
                return
            }

            let returnWork = DispatchWorkItem { [weak self] in
                guard let self,
                      self.focusExposureRequests.isLatest(requestID),
                      let current = self.videoInput?.device,
                      current.uniqueID == deviceID,
                      !self.focusLockedInHardware,
                      !self.exposureLockedInHardware else { return }
                do {
                    try current.lockForConfiguration()
                    defer { current.unlockForConfiguration() }
                    let center = CGPoint(x: 0.5, y: 0.5)
                    if current.isFocusPointOfInterestSupported {
                        current.focusPointOfInterest = center
                    }
                    if current.isExposurePointOfInterestSupported {
                        current.exposurePointOfInterest = center
                    }
                    if current.isFocusModeSupported(.continuousAutoFocus) {
                        current.focusMode = .continuousAutoFocus
                    }
                    if current.isExposureModeSupported(.continuousAutoExposure) {
                        current.exposureMode = .continuousAutoExposure
                    }
                    AppEventLog.event("Tap focus returned to continuous auto after \(resetSeconds)s")
                } catch {
                    // A later focus interaction, camera switch, or mode change will safely reset it.
                }
            }
            pendingFocusReturnWorkItem = returnWork
            sessionQueue.asyncAfter(deadline: .now() + .seconds(resetSeconds), execute: returnWork)
        }
    }

    @discardableResult
    func applyActiveModeFormat(preferVirtualCamera: Bool = true) -> Bool {
        switch captureMode {
        case .photo:
            return applyBestPhotoFormat(preferVirtualCamera: preferVirtualCamera)
        case .sloMo:
            return applySlowMotionFormat()
        case .video:
            return applySelectedFormat(preferVirtualCamera: preferVirtualCamera)
        }
    }

    func photoMegapixelOptions(for dimensions: CMVideoDimensions, aspect: String) -> [Int] {
        let width = Double(dimensions.width)
        let height = Double(dimensions.height)
        guard width > 0, height > 0 else { return Self.photoMegapixelPresets }

        let pixels: Double
        if aspect == "1:1" {
            let side = min(width, height)
            pixels = side * side
        } else {
            let targetRatio = width >= height ? (4.0 / 3.0) : (3.0 / 4.0)
            if width / height > targetRatio {
                let croppedWidth = height * targetRatio
                pixels = croppedWidth * height
            } else {
                let croppedHeight = width / targetRatio
                pixels = width * croppedHeight
            }
        }

        let megapixels = pixels / 1_000_000.0
        let rounded = megapixels.rounded()
        let maximumNative = abs(megapixels - rounded) < 0.35 ? Int(rounded) : Int(megapixels.rounded(.down))
        let maximum = max(1, min(Self.photoMegapixelPresets.first ?? 12, maximumNative))
        return Self.photoMegapixelPresets.filter { $0 <= maximum }
    }

    static func normalizedPhotoMegapixels(_ value: Int) -> Int {
        guard value > 0 else { return photoMegapixelPresets.first ?? 12 }
        return photoMegapixelPresets.first(where: { $0 <= value }) ?? photoMegapixelPresets.last ?? 1
    }

    func updatePhotoMegapixelAvailability(for dimensions: CMVideoDimensions, aspect: String) {
        let options = photoMegapixelOptions(for: dimensions, aspect: aspect)
        let effective = options.contains(preferredPhotoMegapixels) ? preferredPhotoMegapixels : (options.first ?? 1)
        publish {
            if self.supportedPhotoMegapixels != options {
                self.supportedPhotoMegapixels = options
            }
            if self.selectedPhotoMegapixels != effective {
                self.selectedPhotoMegapixels = effective
            }
            let label = "\(effective) MP"
            if self.currentPhotoResolutionLabel != label {
                self.currentPhotoResolutionLabel = label
            }
            let pixelCount = Int64(effective) * 1_000_000
            if self.currentPhotoPixelCount != pixelCount {
                self.currentPhotoPixelCount = pixelCount
            }
        }
    }

    @discardableResult
    func applyBestPhotoFormat(preferVirtualCamera: Bool = true) -> Bool {
        let devices = capabilityDevices(for: cameraPosition.avPosition)
        updateSlowMotionAvailability(for: devices)
        guard !devices.isEmpty else {
            showError("Photo capture is unavailable on this camera.")
            return false
        }

        let physical = desiredPhysicalDevice(in: devices, forDisplayedZoom: requestedZoom)
        let desiredDevice = preferVirtualCamera
            ? (devices.first(where: { $0.isVirtualDevice }) ?? physical ?? devices.first)
            : (physical ?? devices.first(where: { !$0.isVirtualDevice }) ?? devices.first)

        guard let desiredDevice, let photoChoice = formatSelector.bestPhotoFormat(for: desiredDevice) else {
            showError("Full-resolution photos aren’t available on this camera.")
            return false
        }

        let previewRange = photoChoice.format.videoSupportedFrameRateRanges.first {
            $0.minFrameRate <= 30 && $0.maxFrameRate >= 30
        } ?? photoChoice.format.videoSupportedFrameRateRanges.first
        let previewFPS = min(max(30.0, previewRange?.minFrameRate ?? 30), previewRange?.maxFrameRate ?? 30)

        guard let displayedZoom = applyAtomicCaptureConfiguration(
            device: desiredDevice,
            format: photoChoice.format,
            frameRate: previewFPS,
            photoDimensions: photoChoice.dimensions
        ) else {
            showError("Couldn’t configure full-resolution Photo mode.")
            return false
        }

        nativePhotoDimensions = photoChoice.dimensions
        let minimum = minimumSupportedZoom(for: desiredDevice)
        let maximum = maximumSupportedZoom(for: desiredDevice)
        publish {
            if abs(self.minimumZoomFactor - minimum) >= 0.0005 {
                self.minimumZoomFactor = minimum
            }
            if abs(self.maximumZoomFactor - maximum) >= 0.0005 {
                self.maximumZoomFactor = maximum
            }
            self.applyPublishedZoomIfNeeded(displayedZoom)
            let torchAvailable = desiredDevice.hasTorch && desiredDevice.isTorchAvailable
            let torchOn = desiredDevice.hasTorch && desiredDevice.torchMode == .on
            if self.torchAvailable != torchAvailable {
                self.torchAvailable = torchAvailable
            }
            if self.isTorchOn != torchOn {
                self.isTorchOn = torchOn
            }
        }
        updatePhotoMegapixelAvailability(
            for: photoChoice.dimensions,
            aspect: UserDefaults.standard.string(forKey: "photoAspect") ?? "4:3"
        )
        resetFocusAndExposureState()
        synchronizeWhiteBalanceAfterConfiguration()
        logCaptureConfiguration("Photo")
        return true
    }



    func minimumSupportedZoom(for device: AVCaptureDevice) -> CGFloat {
        max(0.5, displayedZoomFactor(for: device.minAvailableVideoZoomFactor, device: device))
    }

    func maximumSupportedZoom(for device: AVCaptureDevice) -> CGFloat {
        min(8, displayedZoomFactor(for: device.maxAvailableVideoZoomFactor, device: device))
    }

    func snappedZoomFactor(_ requestedFactor: CGFloat, for device: AVCaptureDevice) -> CGFloat {
        let minimum = minimumSupportedZoom(for: device)
        let maximum = maximumSupportedZoom(for: device)
        let clamped = min(max(requestedFactor, minimum), maximum)

        if minimum <= 0.5, abs(clamped - 0.5) < 0.10 {
            return 0.5
        }
        if abs(clamped - 1) < 0.16 {
            return 1
        }
        return clamped
    }

    func wideAngleDeviceZoomFactor(for device: AVCaptureDevice) -> CGFloat {
        if device.deviceType == .builtInUltraWideCamera { return 2 }
        if device.deviceType == .builtInTelephotoCamera {
            return 1 / max(telephotoOpticalFactor(for: device), 1)
        }
        let hasUltraWide = device.constituentDevices.contains { $0.deviceType == .builtInUltraWideCamera }
        guard hasUltraWide, let switchFactor = device.virtualDeviceSwitchOverVideoZoomFactors.first else {
            return 1
        }
        return CGFloat(switchFactor.doubleValue)
    }

    func displayedZoomFactor(for deviceZoomFactor: CGFloat, device: AVCaptureDevice) -> CGFloat {
        deviceZoomFactor / wideAngleDeviceZoomFactor(for: device)
    }

    func deviceZoomFactor(for displayedZoomFactor: CGFloat, device: AVCaptureDevice) -> CGFloat {
        let requested = displayedZoomFactor * wideAngleDeviceZoomFactor(for: device)
        return min(max(requested, device.minAvailableVideoZoomFactor), device.maxAvailableVideoZoomFactor)
    }

    func formattedZoomLabel(for zoomFactor: CGFloat) -> String {
        abs(zoomFactor.rounded() - zoomFactor) < 0.01
            ? "\(Int(zoomFactor.rounded()))×"
            : String(format: "%.1f×", zoomFactor)
    }

    /// Runs on the main queue inside an existing publish block. Avoiding identical assignments
    /// prevents ObservableObject redraws when a drag request resolves to the current zoom.
    func applyPublishedZoomIfNeeded(_ factor: CGFloat) {
        if abs(zoomFactor - factor) >= 0.0005 {
            zoomFactor = factor
        }
        let label = formattedZoomLabel(for: factor)
        if zoomLabel != label {
            zoomLabel = label
        }
    }

    /// Captures only immutable primitive values on sessionQueue. AppEventLog formats and writes
    /// the detailed message on its own utility queue so record start is not held by interpolation.
    func captureConfigurationLogSnapshot(
        _ context: String,
        label: String = "CAPTURE FORMAT/INPUT APPLIED"
    ) -> AppEventLog.CaptureConfigurationLogSnapshot? {
        guard let device = videoInput?.device else { return nil }

        let dimensions = CMVideoFormatDescriptionGetDimensions(device.activeFormat.formatDescription)
        let duration = device.activeVideoMinFrameDuration.seconds
        let frameRate = duration > 0 ? 1 / duration : 0
        let connection = movieOutput.connection(with: .video)
        let settings = connection.map { movieOutput.outputSettings(for: $0) } ?? [:]
        let codec = settings[AVVideoCodecKey] as? String ?? "system default"
        let compression = settings[AVVideoCompressionPropertiesKey] as? [String: Any]
        let bitRate = (compression?[AVVideoAverageBitRateKey] as? NSNumber)?.intValue
        return AppEventLog.CaptureConfigurationLogSnapshot(
            label: label,
            context: context,
            isBackCamera: cameraPosition == .back,
            isVirtualDevice: device.isVirtualDevice,
            deviceName: device.localizedName,
            width: dimensions.width,
            height: dimensions.height,
            frameRate: frameRate,
            codec: codec,
            bitRate: bitRate,
            zoomFactor: Double(requestedZoom),
            whiteBalance: requestedWhiteBalancePreset.rawValue,
            torchOn: device.hasTorch && device.torchMode == .on,
            photoFlashMode: photoFlashMode.rawValue
        )
    }

    func enqueueCaptureConfigurationLog(
        _ snapshot: AppEventLog.CaptureConfigurationLogSnapshot?,
        context: String,
        label: String
    ) {
        if let snapshot {
            AppEventLog.event(snapshot)
        } else {
            AppEventLog.event("\(label) [\(context)]: failed — no active camera input")
        }
    }

    /// Records the pieces AVFoundation does not expose in the normal format trace. The primitive
    /// snapshot is collected on sessionQueue; formatting and disk I/O stay on AppEventLog.queue.
    func captureSessionLogSnapshot(_ context: String) -> AppEventLog.SessionLogSnapshot {
        let inputNames = session.inputs.map { input -> String in
            if let deviceInput = input as? AVCaptureDeviceInput {
                return "camera:\(deviceInput.device.localizedName)"
            }
            if input is AVCaptureDeviceInput { return "device input" }
            return String(describing: type(of: input))
        }
        let outputNames = session.outputs.map { String(describing: type(of: $0)) }
        let torchOn = videoInput.map { $0.device.hasTorch && $0.device.torchMode == .on } ?? false
        return AppEventLog.SessionLogSnapshot(
            context: context,
            isRunning: session.isRunning,
            preset: session.sessionPreset.rawValue,
            mode: captureMode.rawValue,
            isBackCamera: cameraPosition == .back,
            recordingState: String(describing: recordingState),
            inputNames: inputNames,
            outputNames: outputNames,
            photoResponsive: photoOutput.isResponsiveCaptureEnabled,
            liveMetricsAttached: session.outputs.contains { $0 === liveMetrics.output },
            availableStorageBytes: availableStorageBytes,
            requestedResolution: hudResolutionLabel,
            requestedFrameRate: Int(hudFrameRateLabel ?? "0") ?? 0,
            selectedCodec: activeVideoCodec,
            compression: compressionDescription(for: captureMode),
            torchOn: torchOn,
            photoFlashMode: photoFlashMode.rawValue,
            zoomFactor: Double(requestedZoom),
            exposureBias: requestedExposureBias,
            whiteBalance: requestedWhiteBalancePreset.rawValue,
            focusExposureLocked: isFocusExposureLocked,
            microphoneAuthorized: String(AVCaptureDevice.authorizationStatus(for: .audio).rawValue),
            microphoneAttached: audioInput != nil
        )
    }

    func logCaptureConfiguration(
        _ context: String,
        label: String = "CAPTURE FORMAT/INPUT APPLIED"
    ) {
        enqueueCaptureConfigurationLog(
            captureConfigurationLogSnapshot(context, label: label),
            context: context,
            label: label
        )
    }

    func logSessionSnapshot(_ context: String) {
        AppEventLog.event(captureSessionLogSnapshot(context))
    }



    @discardableResult
    func applySelectedFormat(
        preferVirtualCamera: Bool = true,
        requestedResolution: VideoResolution? = nil,
        requestedFrameRate: VideoFrameRate? = nil,
        requestedCodec: String? = nil,
        requestedCompression: VideoCompression? = nil,
        requestedCompressionMode: CompressionMode? = nil,
        requestedManualBitrateMbps: Double? = nil,
        qualityRequestID: UInt64? = nil,
        requestedPosition: CameraPosition? = nil,
        requestValidation: (() -> Bool)? = nil
    ) -> Bool {
        if let qualityRequestID, !qualityRequests.isLatest(qualityRequestID) { return false }
        if let requestValidation, !requestValidation() { return false }
        let targetPosition = requestedPosition ?? cameraPosition
        let effectiveCodec = requestedCodec ?? activeVideoCodec
        let currentCompressionSelection = compressionSelection(for: .video)
        let effectiveCompression = requestedCompression ?? currentCompressionSelection.level
        let effectiveCompressionMode = requestedCompressionMode ?? currentCompressionSelection.mode
        let effectiveManualBitrateMbps = requestedManualBitrateMbps ?? currentCompressionSelection.manualBitrateMbps
        let requestSelector = CameraFormatSelector(
            selectedVideoCodec: effectiveCodec,
            selectedResolution: requestedResolution ?? selectedResolution,
            selectedFrameRate: requestedFrameRate ?? selectedFrameRate
        )
        let devices = capabilityDevices(for: targetPosition.avPosition)
        let videoSelection = requestSelector.videoFormatSelection(
            for: devices,
            requestedResolution: requestedResolution,
            requestedFrameRate: requestedFrameRate
        )
        if let requestValidation, !requestValidation() { return false }
        publishVideoAvailability(
            !videoSelection.availableResolutions.isEmpty &&
                !videoSelection.supportedFrameRates.isEmpty
        )
        updateSlowMotionAvailability(
            for: devices,
            selector: requestSelector,
            position: targetPosition,
            codec: effectiveCodec,
            validation: requestValidation
        )
        if let requestValidation, !requestValidation() { return false }
        let available = videoSelection.availableResolutions
        guard !available.isEmpty else {
            if qualityRequests.isCurrent(qualityRequestID) {
                showError("Video isn’t available on this camera with the selected codec.")
            }
            return false
        }
        let selection = videoSelection
        let supportedDevices = selection.supportedDevices

        publish {
            if let qualityRequestID {
                guard self.qualityRequests.isLatest(qualityRequestID),
                      self.captureMode == .video,
                      self.cameraPosition == targetPosition else { return }
            }
            let wasSuppressing = self.suppressPreferencePersistence
            self.suppressPreferencePersistence = true
            if self.selectedResolution != selection.resolution {
                self.selectedResolution = selection.resolution
            }
            if self.selectedFrameRate != selection.frameRate {
                self.selectedFrameRate = selection.frameRate
            }
            if self.supportedResolutions != available {
                self.supportedResolutions = available
            }
            if self.supportedFrameRates != selection.supportedFrameRates {
                self.supportedFrameRates = selection.supportedFrameRates
            }
            self.suppressPreferencePersistence = wasSuppressing
        }

        // Rear 4K60 stays on the real selected 4K60 format while idle so Record never needs a
        // proxy-to-recording rebuild. When Apple's Dual-Wide/Triple virtual device itself exposes
        // this exact 4K60 + codec combination, keep that one input attached and let AVFoundation
        // switch its physical constituents while zooming. Manual WB still deliberately chooses a
        // physical input because locked custom gains are not equivalent on virtual cameras.
        let isRear4K60 = targetPosition == .back &&
            selection.resolution == .p4k && selection.frameRate == .fps60
        let appleStyle4K60Device = isRear4K60 && preferVirtualCamera
            ? supportedDevices.first(where: { self.lensTransitionCoordinator.isRearVirtualLensSystem($0) })
            : nil
        let physicalSupportedDevices = supportedDevices.filter { !$0.isVirtualDevice }
        let forcePhysical4K60 = isRear4K60 && appleStyle4K60Device == nil && !physicalSupportedDevices.isEmpty
        let lensCandidates = forcePhysical4K60 ? physicalSupportedDevices : supportedDevices
        let physical = desiredPhysicalDevice(in: lensCandidates, forDisplayedZoom: requestedZoom)
        let desiredDevice: AVCaptureDevice?
        if let appleStyle4K60Device {
            desiredDevice = appleStyle4K60Device
        } else if forcePhysical4K60 {
            desiredDevice = physical ?? physicalSupportedDevices.first
        } else {
            desiredDevice = preferVirtualCamera
                ? (supportedDevices.first(where: { $0.isVirtualDevice }) ?? physical ?? supportedDevices.first)
                : (physical ?? supportedDevices.first(where: { !$0.isVirtualDevice }) ?? supportedDevices.first)
        }
        guard let desiredDevice,
              let selectedFormat = videoSelection.selectedFormatByDeviceID[desiredDevice.uniqueID] else {
            if qualityRequests.isCurrent(qualityRequestID) {
                showError("This video quality isn’t available on this lens.")
            }
            return false
        }

        if let requestValidation, !requestValidation() { return false }
        guard let displayed = applyAtomicCaptureConfiguration(
            device: desiredDevice,
            format: selectedFormat,
            frameRate: Double(selection.frameRate.rawValue),
            requestedCodec: effectiveCodec
        ) else {
            if qualityRequests.isCurrent(qualityRequestID) {
                showError("Couldn’t set the video quality.")
            }
            return false
        }

        let outputConfigured = configureMovieOutputSettings(
            requestedCodec: effectiveCodec,
            requestedCompression: effectiveCompression,
            requestedCompressionMode: effectiveCompressionMode,
            requestedManualBitrateMbps: effectiveManualBitrateMbps,
            requestedResolution: selection.resolution,
            requestedFrameRate: selection.frameRate,
            requestedPosition: targetPosition,
            requestedMode: .video
        )
        if requestedCodec != nil || requestedCompression != nil ||
            requestedCompressionMode != nil || requestedManualBitrateMbps != nil {
            guard outputConfigured else { return false }
        }
        let zoomDevices = forcePhysical4K60 ? physicalSupportedDevices : [desiredDevice]
        let minZoom = zoomDevices.map { minimumSupportedZoom(for: $0) }.min() ?? minimumSupportedZoom(for: desiredDevice)
        let maxZoom = zoomDevices.map { maximumSupportedZoom(for: $0) }.max() ?? maximumSupportedZoom(for: desiredDevice)
        publish {
            if let qualityRequestID {
                guard self.qualityRequests.isLatest(qualityRequestID),
                      self.captureMode == .video,
                      self.cameraPosition == targetPosition else { return }
            }
            if abs(self.minimumZoomFactor - minZoom) >= 0.0005 {
                self.minimumZoomFactor = minZoom
            }
            if abs(self.maximumZoomFactor - maxZoom) >= 0.0005 {
                self.maximumZoomFactor = maxZoom
            }
            self.applyPublishedZoomIfNeeded(displayed)
            let torchAvailable = desiredDevice.hasTorch && desiredDevice.isTorchAvailable
            let torchOn = desiredDevice.hasTorch && desiredDevice.torchMode == .on
            if self.torchAvailable != torchAvailable {
                self.torchAvailable = torchAvailable
            }
            if self.isTorchOn != torchOn {
                self.isTorchOn = torchOn
            }
        }
        resetFocusAndExposureState()
        synchronizeWhiteBalanceAfterConfiguration()
        logCaptureConfiguration("Video")
        return true
    }

    func activeVideoFormatMatchesSelection() -> Bool {
        guard let device = videoInput?.device else { return false }
        let dimensions = CMVideoFormatDescriptionGetDimensions(device.activeFormat.formatDescription)
        guard dimensions.width == selectedResolution.dimensions.width,
              dimensions.height == selectedResolution.dimensions.height else { return false }

        let requestedRate = Double(selectedFrameRate.rawValue)
        let duration = device.activeVideoMinFrameDuration.seconds
        return duration > 0 &&
            abs(1 / duration - requestedRate) < 0.5 &&
            formatSelector.formatSupportsSelectedCodec(device.activeFormat)
    }

    func activeSlowMotionFormatMatchesSelection() -> Bool {
        guard let device = videoInput?.device else { return false }
        let dimensions = CMVideoFormatDescriptionGetDimensions(device.activeFormat.formatDescription)
        guard dimensions.width == selectedSlowMotionResolution.dimensions.width,
              dimensions.height == selectedSlowMotionResolution.dimensions.height else { return false }

        let requestedRate = Double(selectedSlowMotionFrameRate.rawValue)
        let duration = device.activeVideoMinFrameDuration.seconds
        return duration > 0 && abs(1 / duration - requestedRate) < 1
    }


    @discardableResult
    func applySlowMotionFormat(
        requestedResolution: VideoResolution? = nil,
        requestedFrameRate: SlowMotionFrameRate? = nil,
        qualityRequestID: UInt64? = nil,
        requestedPosition: CameraPosition? = nil
    ) -> Bool {
        if let qualityRequestID, !qualityRequests.isLatest(qualityRequestID) { return false }
        let targetPosition = requestedPosition ?? cameraPosition
        let devices = capabilityDevices(for: targetPosition.avPosition)
        let slowMotionSelection = formatSelector.slowMotionFormatSelection(
            for: devices,
            requestedResolution: requestedResolution ?? selectedSlowMotionResolution,
            requestedFrameRate: requestedFrameRate ?? selectedSlowMotionFrameRate
        )
        let allResolutions = slowMotionSelection.availableResolutions
        slowMotionAvailabilityKey = [
            cameraPosition == .back ? "back" : "front",
            activeVideoCodec,
            devices.map(\.uniqueID).joined(separator: ",")
        ].joined(separator: "|")
        publishSlowMotionAvailability(!allResolutions.isEmpty)
        guard !allResolutions.isEmpty else {
            if qualityRequests.isCurrent(qualityRequestID) {
                showError("Slo-Mo isn’t available on this camera with the selected codec.")
            }
            return false
        }

        let resolution = slowMotionSelection.resolution
        let allRates = slowMotionSelection.supportedFrameRates
        guard !allRates.isEmpty else {
            if qualityRequests.isCurrent(qualityRequestID) {
                showError("Slo-Mo isn’t available at this resolution.")
            }
            return false
        }
        let selectedRate = slowMotionSelection.frameRate

        let supportedDevices = slowMotionSelection.supportedDevices
        guard !supportedDevices.isEmpty else {
            if qualityRequests.isCurrent(qualityRequestID) {
                showError("\(selectedRate.rawValue) fps Slo-Mo isn’t available on this camera.")
            }
            return false
        }

        // Slo-Mo stays on the actual selected HFR physical format while idle. This moves the
        // expensive input/format work away from the Record button. The preview and recording now
        // use the same 120/240 fps configuration; physical lens changes are covered separately.
        let physicalRecordingDevices = supportedDevices.filter { !$0.isVirtualDevice }
        let recordingDevices = physicalRecordingDevices.isEmpty ? supportedDevices : physicalRecordingDevices
        let sloMoMinimumZoom = recordingDevices.map { minimumSupportedZoom(for: $0) }.min() ?? 1
        let sloMoMaximumZoom = recordingDevices.map { maximumSupportedZoom(for: $0) }.max() ?? 1
        requestedZoom = min(max(requestedZoom, sloMoMinimumZoom), sloMoMaximumZoom)

        let physical = desiredPhysicalDevice(in: recordingDevices, forDisplayedZoom: requestedZoom)
        // Recording and manual-WB paths use a real constituent camera. This guarantees that the
        // selected lens really supports the requested HFR format instead of relying on a virtual
        // camera format that cannot encode the requested 120/240 fps stream.
        let desiredDevice = physical
            ?? recordingDevices.first(where: { !$0.isVirtualDevice })
            ?? recordingDevices.first
        guard let desiredDevice,
              let hfrFormat = slowMotionSelection.selectedFormatByDeviceID[desiredDevice.uniqueID] else {
            if qualityRequests.isCurrent(qualityRequestID) {
                showError("\(selectedRate.rawValue) fps Slo-Mo isn’t available on this lens.")
            }
            return false
        }

        let requestedFPS = Double(selectedRate.rawValue)
        guard let displayed = applyAtomicCaptureConfiguration(
            device: desiredDevice,
            format: hfrFormat,
            frameRate: requestedFPS
        ) else {
            if qualityRequests.isCurrent(qualityRequestID) {
                showError("Couldn’t set the Slo-Mo quality.")
            }
            return false
        }

        _ = configureMovieOutputSettings()

        let lensResolutions = slowMotionSelection.availableResolutionsByDeviceID[desiredDevice.uniqueID] ?? []
        let lensRates = slowMotionSelection.supportedFrameRatesByDeviceID[desiredDevice.uniqueID] ?? []
        publish {
            if let qualityRequestID {
                guard self.qualityRequests.isLatest(qualityRequestID),
                      self.captureMode == .sloMo,
                      self.cameraPosition == targetPosition else { return }
            }
            let wasSuppressing = self.suppressPreferencePersistence
            self.suppressPreferencePersistence = true
            let resolvedResolutions = lensResolutions.isEmpty ? allResolutions : lensResolutions
            let resolvedRates = lensRates.isEmpty ? allRates : lensRates
            if self.supportedSlowMotionResolutions != resolvedResolutions {
                self.supportedSlowMotionResolutions = resolvedResolutions
            }
            if self.selectedSlowMotionResolution != resolution {
                self.selectedSlowMotionResolution = resolution
            }
            if self.supportedSlowMotionFrameRates != resolvedRates {
                self.supportedSlowMotionFrameRates = resolvedRates
            }
            if self.selectedSlowMotionFrameRate != selectedRate {
                self.selectedSlowMotionFrameRate = selectedRate
            }
            self.suppressPreferencePersistence = wasSuppressing
            if abs(self.minimumZoomFactor - sloMoMinimumZoom) >= 0.0005 {
                self.minimumZoomFactor = sloMoMinimumZoom
            }
            if abs(self.maximumZoomFactor - sloMoMaximumZoom) >= 0.0005 {
                self.maximumZoomFactor = sloMoMaximumZoom
            }
            self.applyPublishedZoomIfNeeded(displayed)
            let torchAvailable = desiredDevice.hasTorch && desiredDevice.isTorchAvailable
            let torchOn = desiredDevice.hasTorch && desiredDevice.torchMode == .on
            if self.torchAvailable != torchAvailable {
                self.torchAvailable = torchAvailable
            }
            if self.isTorchOn != torchOn {
                self.isTorchOn = torchOn
            }
        }
        resetFocusAndExposureState()
        synchronizeWhiteBalanceAfterConfiguration()
        logCaptureConfiguration("Slo-Mo")
        return true
    }





    func currentOutputConfigurationRequestSnapshot() -> OutputConfigurationRequestSnapshot {
        OutputConfigurationRequestSnapshot(
            qualityRequestID: qualityRequests.current(),
            compressionRequestID: compressionRequests.current(),
            captureConfigurationGenerationID: captureConfigurationGeneration.current(),
            videoConfigurationRequestID: videoConfigurationRequests.current(),
            cameraSwitchRequestID: cameraSwitchRequests.current(),
            modeChangeRequestID: modeChangeRequests.current(),
            whiteBalanceRequestID: whiteBalanceRequests.current()
        )
    }

    func outputConfigurationRequestIsUnchanged(
        _ snapshot: OutputConfigurationRequestSnapshot
    ) -> Bool {
        qualityRequests.isLatest(snapshot.qualityRequestID) &&
            compressionRequests.isLatest(snapshot.compressionRequestID) &&
            captureConfigurationGeneration.isLatest(snapshot.captureConfigurationGenerationID) &&
            videoConfigurationRequests.isLatest(snapshot.videoConfigurationRequestID) &&
            cameraSwitchRequests.isLatest(snapshot.cameraSwitchRequestID) &&
            modeChangeRequests.isLatest(snapshot.modeChangeRequestID) &&
            whiteBalanceRequests.isLatest(snapshot.whiteBalanceRequestID)
    }

    func invalidateVerifiedHighOutputProvenance() {
        highOutputProvenanceEpoch &+= 1
        verifiedHighOutputProvenance = nil
    }

    func highOutputReadbackSignature(
        from settings: [String: Any]
    ) -> HighOutputReadbackSignature? {
        let codec = settings[AVVideoCodecKey] as? String ?? ""
        guard !codec.isEmpty else { return nil }

        guard let compressionValue = settings[AVVideoCompressionPropertiesKey] else {
            return HighOutputReadbackSignature(
                codec: codec,
                compressionPropertiesPresent: false,
                averageBitrate: nil
            )
        }
        guard let compression = compressionValue as? [String: Any] else { return nil }
        guard let bitrateValue = compression[AVVideoAverageBitRateKey] else {
            return HighOutputReadbackSignature(
                codec: codec,
                compressionPropertiesPresent: true,
                averageBitrate: nil
            )
        }
        guard let bitrate = bitrateValue as? NSNumber,
              bitrate.doubleValue.isFinite else {
            return nil
        }
        return HighOutputReadbackSignature(
            codec: codec,
            compressionPropertiesPresent: true,
            averageBitrate: bitrate.doubleValue
        )
    }

    func frameDurationMatchesFPS(_ duration: CMTime, fps: Double) -> Bool {
        let seconds = duration.seconds
        guard seconds.isFinite, seconds > 0, fps > 0 else { return false }
        let tolerance = fps >= 100 ? 1.0 : 0.5
        return abs((1.0 / seconds) - fps) < tolerance
    }

    func installVerifiedHighOutputProvenance(
        requestSnapshot: OutputConfigurationRequestSnapshot,
        connection: AVCaptureConnection,
        settings: [String: Any],
        mode: CaptureMode,
        position: CameraPosition,
        resolution: VideoResolution,
        frameRate: Double,
        codec: String,
        shouldMirror: Bool,
        expectedStabilization: AVCaptureVideoStabilizationMode
    ) {
        guard outputConfigurationRequestIsUnchanged(requestSnapshot),
              !session.isInterrupted,
              session.outputs.contains(where: { $0 === movieOutput }),
              let input = videoInput,
              session.inputs.contains(where: { $0 === input }),
              let device = videoInput?.device,
              device.position == position.avPosition,
              let currentConnection = movieOutput.connection(with: .video),
              currentConnection === connection,
              let readback = highOutputReadbackSignature(from: settings),
              readback.codec == codec else { return }

        let dimensions = CMVideoFormatDescriptionGetDimensions(device.activeFormat.formatDescription)
        guard dimensions.width == resolution.dimensions.width,
              dimensions.height == resolution.dimensions.height,
              frameDurationMatchesFPS(device.activeVideoMinFrameDuration, fps: frameRate),
              frameDurationMatchesFPS(device.activeVideoMaxFrameDuration, fps: frameRate),
              connection.isVideoMirroringSupported == false ||
                  connection.isVideoMirrored == shouldMirror,
              connection.isVideoStabilizationSupported == false ||
                  connection.preferredVideoStabilizationMode == expectedStabilization else {
            return
        }

        verifiedHighOutputProvenance = VerifiedHighOutputProvenance(
            videoInput: input,
            movieConnection: connection,
            activeFormat: device.activeFormat,
            epoch: highOutputProvenanceEpoch,
            deviceUniqueID: device.uniqueID,
            mode: mode.rawValue,
            isBackCamera: position == .back,
            resolution: resolution.rawValue,
            frameRate: frameRate,
            codec: codec,
            dimensions: dimensions,
            minFrameDuration: device.activeVideoMinFrameDuration,
            maxFrameDuration: device.activeVideoMaxFrameDuration,
            mirroringSupported: connection.isVideoMirroringSupported,
            mirrored: connection.isVideoMirrored,
            stabilizationSupported: connection.isVideoStabilizationSupported,
            stabilizationModeRawValue: connection.preferredVideoStabilizationMode.rawValue,
            readback: readback
        )
    }

    func verifiedHighOutputProvenanceMatchesCurrentConfiguration(
        connection: AVCaptureConnection,
        applied: [String: Any],
        preferredCodec: AVVideoCodecType
    ) -> Bool {
        guard let provenance = verifiedHighOutputProvenance,
              provenance.epoch == highOutputProvenanceEpoch,
              !session.isInterrupted,
              session.outputs.contains(where: { $0 === movieOutput }),
              let input = videoInput,
              session.inputs.contains(where: { $0 === input }),
              let device = videoInput?.device,
              let provenInput = provenance.videoInput,
              provenInput === input,
              let provenConnection = provenance.movieConnection,
              provenConnection === connection,
              let provenFormat = provenance.activeFormat,
              provenFormat === device.activeFormat,
              device.uniqueID == provenance.deviceUniqueID,
              device.position == (provenance.isBackCamera ? .back : .front),
              provenance.mode == captureMode.rawValue,
              provenance.isBackCamera == (cameraPosition == .back),
              provenance.resolution == (captureMode == .sloMo
                  ? selectedSlowMotionResolution.rawValue
                  : selectedResolution.rawValue),
              abs(provenance.frameRate - (captureMode == .sloMo
                  ? Double(selectedSlowMotionFrameRate.rawValue)
                  : Double(selectedFrameRate.rawValue))) < 0.0001,
              provenance.codec == preferredCodec.rawValue else {
            return false
        }

        let currentCompression = compressionSelection(for: captureMode)
        guard currentCompression.mode == .auto,
              currentCompression.level == .high else {
            return false
        }

        let dimensions = CMVideoFormatDescriptionGetDimensions(device.activeFormat.formatDescription)
        guard dimensions.width == provenance.dimensions.width,
              dimensions.height == provenance.dimensions.height,
              CMTimeCompare(device.activeVideoMinFrameDuration, provenance.minFrameDuration) == 0,
              CMTimeCompare(device.activeVideoMaxFrameDuration, provenance.maxFrameDuration) == 0,
              connection.isVideoMirroringSupported == provenance.mirroringSupported,
              connection.isVideoStabilizationSupported == provenance.stabilizationSupported else {
            return false
        }
        if provenance.mirroringSupported, connection.isVideoMirrored != provenance.mirrored {
            return false
        }
        if provenance.stabilizationSupported,
           connection.preferredVideoStabilizationMode.rawValue != provenance.stabilizationModeRawValue {
            return false
        }

        guard let readback = highOutputReadbackSignature(from: applied),
              readback == provenance.readback,
              readback.codec == preferredCodec.rawValue else {
            return false
        }
        return true
    }

    func movieOutputSettingsMatchCurrentConfiguration(
        allowVerifiedHighDefault: Bool = false
    ) -> Bool {
        guard let connection = movieOutput.connection(with: .video) else { return false }
        let preferred: AVVideoCodecType = activeVideoCodec == "H264" ? .h264 : .hevc
        let applied = movieOutput.outputSettings(for: connection)
        guard (applied[AVVideoCodecKey] as? String) == preferred.rawValue else { return false }

        let shouldMirror = cameraPosition == .front && UserDefaults.standard.bool(forKey: "mirrorSelfies")
        if connection.isVideoMirroringSupported, connection.isVideoMirrored != shouldMirror { return false }

        if connection.isVideoStabilizationSupported {
            let expected: AVCaptureVideoStabilizationMode = captureMode == .video && isVideoStabilizationEnabled ? .auto : .off
            if connection.preferredVideoStabilizationMode != expected { return false }
        }

        let compression = compressionSelection(for: captureMode)
        let usesCustomBitrate = compression.mode == .manual || compression.level != .high
        if usesCustomBitrate {
            guard let compression = applied[AVVideoCompressionPropertiesKey] as? [String: Any],
                  let bitrate = compression[AVVideoAverageBitRateKey] as? NSNumber else { return false }
            let expected = estimatedVideoBitsPerSecond
            if abs(bitrate.doubleValue - expected) > max(expected * 0.20, 1_000_000) { return false }
        } else if allowVerifiedHighDefault {
            guard verifiedHighOutputProvenanceMatchesCurrentConfiguration(
                connection: connection,
                applied: applied,
                preferredCodec: preferred
            ) else { return false }
        } else if applied[AVVideoCompressionPropertiesKey] != nil {
            // High means the system/default compression path. A previous custom bitrate must
            // not be mistaken for the current setting when a non-Record caller reconciles work.
            return false
        }
        return true
    }

    @discardableResult
    func configureMovieOutputSettings(
        requestedCodec: String? = nil,
        requestedCompression: VideoCompression? = nil,
        requestedCompressionMode: CompressionMode? = nil,
        requestedManualBitrateMbps: Double? = nil,
        requestedResolution: VideoResolution? = nil,
        requestedFrameRate: VideoFrameRate? = nil,
        requestedPosition: CameraPosition? = nil,
        requestedMode: CaptureMode? = nil
    ) -> Bool {
        invalidateVerifiedHighOutputProvenance()
        let outputTraceID = activeRecordingTraceID ?? (AppEventLog.extremeDiagnosticsEnabled ? AppEventLog.makeTraceID("OUTPUT") : nil)
        let outputStartedAt = ProcessInfo.processInfo.systemUptime
        let requestSnapshot = currentOutputConfigurationRequestSnapshot()
        guard let connection = movieOutput.connection(with: .video) else {
            AppEventLog.guardRejected("configureMovieOutputSettings", reason: "movie output video connection missing", traceID: outputTraceID)
            return false
        }

        let effectiveMode = requestedMode ?? captureMode
        let effectivePosition = requestedPosition ?? cameraPosition
        let effectiveCodec = effectiveMode == .sloMo ? "HEVC" : (requestedCodec ?? activeVideoCodec)
        let currentCompression = compressionSelection(for: effectiveMode)
        let effectiveCompression = requestedCompression ?? currentCompression.level
        let effectiveCompressionMode = requestedCompressionMode ?? currentCompression.mode
        let requestedBitrateMbps = ManualBitratePolicy.validatedMbps(
            requestedManualBitrateMbps ?? currentCompression.manualBitrateMbps
        )
        let effectiveResolution = effectiveMode == .sloMo
            ? selectedSlowMotionResolution
            : (requestedResolution ?? selectedResolution)
        let effectiveFPS: Double = effectiveMode == .sloMo
            ? Double(selectedSlowMotionFrameRate.rawValue)
            : Double((requestedFrameRate ?? selectedFrameRate).rawValue)
        let effectiveManualBitrateMbps = ManualBitratePolicy.effectiveMbps(
            requested: requestedBitrateMbps,
            resolution: effectiveResolution,
            fps: effectiveFPS,
            isSlowMotion: effectiveMode == .sloMo,
            codec: effectiveCodec
        )
        let expectedBitRate = estimatedVideoBitsPerSecond(
            resolution: effectiveResolution,
            fps: effectiveFPS,
            codec: effectiveCodec,
            compression: effectiveCompression,
            compressionMode: effectiveCompressionMode,
            manualBitrateMbps: requestedBitrateMbps,
            isSlowMotion: effectiveMode == .sloMo
        )
        AppEventLog.deepEvent("MOVIE OUTPUT CONFIG REQUEST", category: .video, traceID: outputTraceID, fields: [
            "mode": effectiveMode.rawValue,
            "Video/Slo-Mo": effectiveMode.rawValue,
            "position": effectivePosition.rawValue,
            "resolution": effectiveResolution.rawValue,
            "fps": String(format: "%.1f", effectiveFPS),
            "FPS": String(format: "%.1f", effectiveFPS),
            "codec": effectiveCodec,
            "requestedManualBitrateMbps": String(format: "%.1f", requestedBitrateMbps),
            "effectiveManualBitrateMbps": String(format: "%.1f", effectiveManualBitrateMbps),
            "compression": effectiveCompressionMode == .manual
                ? "Manual \(String(format: "%.1f", effectiveManualBitrateMbps)) Mbps"
                : "Auto \(effectiveCompression.rawValue)",
            "expectedBitrate": String(Int(expectedBitRate)),
            "availableCodecs": movieOutput.availableVideoCodecTypes.map(\.rawValue).joined(separator: ",")
        ])

        let shouldMirror = effectivePosition == .front && UserDefaults.standard.bool(forKey: "mirrorSelfies")
        if connection.isVideoMirroringSupported {
            if connection.automaticallyAdjustsVideoMirroring {
                connection.automaticallyAdjustsVideoMirroring = false
            }
            if connection.isVideoMirrored != shouldMirror {
                connection.isVideoMirrored = shouldMirror
            }
        }

        let shouldStabilize = effectiveMode == .video && isVideoStabilizationEnabled
        let expectedStabilization: AVCaptureVideoStabilizationMode = shouldStabilize ? .auto : .off
        if connection.isVideoStabilizationSupported {
            if connection.preferredVideoStabilizationMode != expectedStabilization {
                connection.preferredVideoStabilizationMode = expectedStabilization
            }
        }

        let supportedKeys = Set(movieOutput.supportedOutputSettingsKeys(for: connection))
        let preferred: AVVideoCodecType = effectiveCodec == "H264" ? .h264 : .hevc
        let codecAvailable = movieOutputSupportsCodec(preferred, on: connection, supportedKeys: supportedKeys)
        let message: String? = codecAvailable ? nil : (preferred == .h264 && movieOutput.availableVideoCodecTypes.contains(.hevc)
            ? "This camera configuration requires HEVC / H.265. Select HEVC, or lower the resolution or frame rate to use H.264."
            : "The selected codec is unavailable for this camera configuration.")
        publish {
            if requestedCodec != nil, self.selectedVideoCodec != effectiveCodec { return }
            if self.codecAvailabilityMessage != message {
                self.codecAvailabilityMessage = message
            }
        }
        guard codecAvailable else {
            AppEventLog.event("MOVIE OUTPUT CODEC REJECTED", category: .video, level: .warning, traceID: outputTraceID, fields: [
                "requestedCodec": preferred.rawValue,
                "availableCodecs": movieOutput.availableVideoCodecTypes.map(\.rawValue).joined(separator: ","),
                "supportedKeys": supportedKeys.sorted().joined(separator: ",")
            ])
            return false
        }

        let needsCompressionProperties = effectiveCompressionMode == .manual || effectiveCompression != .high
        guard !needsCompressionProperties || supportedKeys.contains(AVVideoCompressionPropertiesKey) else {
            AppEventLog.event("MOVIE OUTPUT COMPRESSION REJECTED: compression properties are unsupported",
                              category: .video, level: .warning, traceID: outputTraceID,
                              fields: ["mode": effectiveMode.rawValue, "compression": effectiveCompressionMode == .manual
                                       ? "manual" : effectiveCompression.rawValue])
            return false
        }

        // Codec-only Auto/High output settings are a persistent policy, not a per-format bitrate.
        // AVFoundation recalculates its own default compression for the active format. If that
        // exact policy is already installed, resetting MovieFileOutput is expensive and can add
        // hundreds of milliseconds to Photo -> Video without changing the result.
        if !needsCompressionProperties, movieOutputUsesSystemDefaultCompression {
            let existing = movieOutput.outputSettings(for: connection)
            if (existing[AVVideoCodecKey] as? String) == preferred.rawValue {
                logMovieOutputConfigurationReadback(
                    connection: connection,
                    settings: existing,
                    mode: effectiveMode,
                    position: effectivePosition,
                    compression: effectiveCompression,
                    compressionMode: effectiveCompressionMode,
                    manualBitrateMbps: effectiveManualBitrateMbps
                )
                installVerifiedHighOutputProvenance(
                    requestSnapshot: requestSnapshot,
                    connection: connection,
                    settings: existing,
                    mode: effectiveMode,
                    position: effectivePosition,
                    resolution: effectiveResolution,
                    frameRate: effectiveFPS,
                    codec: preferred.rawValue,
                    shouldMirror: shouldMirror,
                    expectedStabilization: expectedStabilization
                )
                AppEventLog.deepEvent("MOVIE OUTPUT CONFIG REUSED", category: .video, traceID: outputTraceID, fields: [
                    "codec": preferred.rawValue,
                    "policy": "system-default compression",
                    "totalMs": String(format: "%.2f", (ProcessInfo.processInfo.systemUptime - outputStartedAt) * 1000)
                ])
                return true
            }
        }

        var settings: [String: Any] = [AVVideoCodecKey: preferred]
        if needsCompressionProperties {
            settings[AVVideoCompressionPropertiesKey] = [
                AVVideoAverageBitRateKey: Int(expectedBitRate)
            ]
        }

        movieOutputUsesSystemDefaultCompression = false
        movieOutput.setOutputSettings(nil, for: connection)
        movieOutput.setOutputSettings(settings, for: connection)

        let applied = movieOutput.outputSettings(for: connection)
        let appliedCompression = applied[AVVideoCompressionPropertiesKey] as? [String: Any]
        AppEventLog.deepEvent("MOVIE OUTPUT CONFIG READBACK", category: .video, traceID: outputTraceID, fields: [
            "codec": applied[AVVideoCodecKey] as? String ?? "missing",
            "bitrate": (appliedCompression?[AVVideoAverageBitRateKey] as? NSNumber).map { String($0.int64Value) } ?? "default",
            "mirrored": String(connection.isVideoMirrored),
            "stabilization": String(describing: connection.preferredVideoStabilizationMode),
            "totalMs": String(format: "%.2f", (ProcessInfo.processInfo.systemUptime - outputStartedAt) * 1000)
        ])
        guard (applied[AVVideoCodecKey] as? String) == preferred.rawValue else {
            let message = preferred == .h264 && movieOutput.availableVideoCodecTypes.contains(.hevc)
                ? "This camera configuration requires HEVC / H.265. Select HEVC, or lower the resolution or frame rate to use H.264."
                : "The selected codec is unavailable for this camera configuration."
            publish {
                if requestedCodec != nil, self.selectedVideoCodec != effectiveCodec { return }
                if self.codecAvailabilityMessage != message {
                    self.codecAvailabilityMessage = message
                }
            }
            return false
        }
        if connection.isVideoMirroringSupported, connection.isVideoMirrored != shouldMirror { return false }
        if connection.isVideoStabilizationSupported {
            let expected: AVCaptureVideoStabilizationMode = shouldStabilize ? .auto : .off
            if connection.preferredVideoStabilizationMode != expected { return false }
        }
        if needsCompressionProperties {
            guard let compression = applied[AVVideoCompressionPropertiesKey] as? [String: Any],
                  let bitrate = compression[AVVideoAverageBitRateKey] as? NSNumber else {
                AppEventLog.event("MOVIE OUTPUT COMPRESSION READBACK REJECTED: bitrate missing",
                                  category: .video, level: .warning, traceID: outputTraceID)
                return false
            }
            if abs(bitrate.doubleValue - expectedBitRate) > max(expectedBitRate * 0.20, 1_000_000) {
                return false
            }
        }
        movieOutputUsesSystemDefaultCompression = !needsCompressionProperties
        logMovieOutputConfigurationReadback(
            connection: connection,
            settings: applied,
            mode: effectiveMode,
            position: effectivePosition,
            compression: effectiveCompression,
            compressionMode: effectiveCompressionMode,
            manualBitrateMbps: effectiveManualBitrateMbps
        )
        if effectiveCompressionMode == .auto, effectiveCompression == .high {
            installVerifiedHighOutputProvenance(
                requestSnapshot: requestSnapshot,
                connection: connection,
                settings: applied,
                mode: effectiveMode,
                position: effectivePosition,
                resolution: effectiveResolution,
                frameRate: effectiveFPS,
                codec: preferred.rawValue,
                shouldMirror: shouldMirror,
                expectedStabilization: expectedStabilization
            )
        }
        AppEventLog.deepEvent("MOVIE OUTPUT CONFIG COMPLETE", category: .video, traceID: outputTraceID, fields: [
            "result": "success",
            "totalMs": String(format: "%.2f", (ProcessInfo.processInfo.systemUptime - outputStartedAt) * 1000)
        ])
        return true
    }

    func movieOutputSupportsCodec(
        _ codec: AVVideoCodecType,
        on connection: AVCaptureConnection,
        supportedKeys: Set<String>? = nil
    ) -> Bool {
        let keys = supportedKeys ?? Set(movieOutput.supportedOutputSettingsKeys(for: connection))
        return movieOutput.availableVideoCodecTypes.contains(codec) && keys.contains(AVVideoCodecKey)
    }

    func logMovieOutputConfigurationReadback(
        connection: AVCaptureConnection,
        settings: [String: Any],
        mode: CaptureMode,
        position: CameraPosition,
        compression configuredCompression: VideoCompression,
        compressionMode: CompressionMode = .auto,
        manualBitrateMbps: Double = ManualBitratePolicy.defaultMbps
    ) {
        let codec = settings[AVVideoCodecKey] as? String ?? "system default"
        let compression = settings[AVVideoCompressionPropertiesKey] as? [String: Any]
        let bitRate = (compression?[AVVideoAverageBitRateKey] as? NSNumber)?.intValue
        let bitRateText = bitRate.map { "\($0)" } ?? "default"
        let compressionText = compressionMode == .manual
            ? "Manual \(String(format: "%.1f", manualBitrateMbps)) Mbps"
            : "Auto \(configuredCompression.rawValue)"
        AppEventLog.event(
            "MOVIE OUTPUT READBACK: mode=\(mode.rawValue), " +
            "position=\(position == .back ? "back" : "front"), codec=\(codec), " +
            "compression=\(compressionText), averageBitrate=\(bitRateText), " +
            "mirrored=\(connection.isVideoMirrored), " +
            "stabilization=\(String(describing: connection.preferredVideoStabilizationMode))"
        )
    }






    func applyCaptureRotation(to connection: AVCaptureConnection?) {
        guard let connection else { return }
        let automaticAngle = rotationCoordinator?.videoRotationAngleForHorizonLevelCapture
        let requestedAngle: CGFloat?
        switch captureOrientation {
        case .auto:
            requestedAngle = automaticAngle
        case .portrait:
            requestedAngle = 90
        case .landscapeLeft:
            requestedAngle = 180
        case .landscapeRight:
            requestedAngle = 0
        }
        let angle = requestedAngle.flatMap { connection.isVideoRotationAngleSupported($0) ? $0 : nil }
            ?? automaticAngle.flatMap { connection.isVideoRotationAngleSupported($0) ? $0 : nil }
        guard let angle else { return }
        connection.videoRotationAngle = angle
    }

    func resolvedPhotoFlashMode() -> AVCaptureDevice.FlashMode {
        guard let device = videoInput?.device,
              device.hasFlash else { return .off }
        let supportedModes = photoOutput.supportedFlashModes
        guard supportedModes.contains(photoFlashMode.avMode) else { return .off }
        guard photoFlashMode == .auto, cameraPosition == .front else {
            return photoFlashMode.avMode
        }

        // Front-camera Auto is resolved from the current preview scene instead of delegating
        // the final decision to the capture moment. The extra exposure gate keeps ordinary
        // rooms and a nearby lamp from being treated as flash-dark by the front sensor.
        let sceneNeedsFlash = photoOutput.isFlashScene
        let shouldUseFlash = shouldUseFrontAutoFlash(on: device)
        let resolved = shouldUseFlash ? AVCaptureDevice.FlashMode.on : .off
        AppEventLog.event(
            "Front Auto flash decision: sceneNeedsFlash=\(sceneNeedsFlash), " +
            "applied=\(shouldUseFlash), ISO=\(String(format: "%.0f", device.iso)), " +
            "exposure=\(String(format: "%.4f", device.exposureDuration.seconds))s"
        )
        return supportedModes.contains(resolved) ? resolved : .off
    }

    func shouldUseFrontAutoFlash(on device: AVCaptureDevice) -> Bool {
        guard photoOutput.isFlashScene else { return false }

        let isoThreshold = max(device.activeFormat.minISO * 8, 500)
        let iso = device.iso
        guard iso.isFinite else { return true }
        if iso >= isoThreshold { return true }

        let exposureSeconds = device.exposureDuration.seconds
        let maximumExposureSeconds = device.activeMaxExposureDuration.seconds
        let isNearAutoExposureLimit = exposureSeconds.isFinite &&
            exposureSeconds >= (1.0 / 30.0) &&
            (!maximumExposureSeconds.isFinite || maximumExposureSeconds <= 0 ||
             exposureSeconds >= maximumExposureSeconds * 0.9)
        return isNearAutoExposureLimit && iso >= isoThreshold * 0.7
    }
}
