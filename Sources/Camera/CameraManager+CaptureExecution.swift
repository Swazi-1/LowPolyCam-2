import AVFoundation
import Combine
import Foundation
import Photos
import UIKit

// MARK: - CameraManager: Photo/record execution, movie-output start, media filenames, torch synchronization, and UI publishing.

extension CameraManager {
    func configurePhotoSceneMonitoring() {
        guard photoOutput.supportedFlashModes.contains(.auto) else { return }
        let monitoringSettings = AVCapturePhotoSettings()
        monitoringSettings.flashMode = .auto
        monitoringSettings.isAutoStillImageStabilizationEnabled = true
        photoOutput.photoSettingsForSceneMonitoring = monitoringSettings
    }

    func beginPhotoCapture() {
        pumpPendingPhotoCaptures()
    }

    func pumpPendingPhotoCaptures() {
        guard session.isRunning else {
            AppEventLog.event("PHOTO CAPTURE REJECTED", category: .photo, level: .warning,
                              fields: ["reason": "session not running"])
            pendingSinglePhotoCapture = false
            burstRemaining = 0
            burstStopRequested = false
            activeBurstTraceID = nil
            burstRequestedCount = 0
            burstCompletedCount = 0
            publish { self.isCapturingPhoto = false }
            showError("Camera isn’t ready yet.")
            return
        }

        if pendingSinglePhotoCapture {
            guard inFlightPhotoCaptureIDs.isEmpty else { return }
            // A shutter press must capture the moment even while iOS 26 Deferred Start is still
            // preparing AVCapturePhotoOutput. Responsive Capture is specifically designed to
            // buffer that request, so readiness is diagnostic here rather than a hard gate.
            AppEventLog.deepEvent("PHOTO REQUEST SUBMITTING", category: .photo, fields: [
                "readiness": photoCaptureReadinessLabel(photoCaptureCoordinator.captureReadiness)
            ])
            pendingSinglePhotoCapture = false
            guard submitPhotoCapture(isBurst: false, burstOrdinal: nil) else {
                publish { self.isCapturingPhoto = false }
                AppEventLog.event("PHOTO CAPTURE REJECTED", category: .photo, level: .warning,
                                  fields: ["reason": "session stopped before hardware submission"])
                return
            }
            return
        }

        guard activeBurstTraceID != nil else { return }
        if burstStopRequested {
            if inFlightPhotoCaptureIDs.isEmpty {
                finishBurstHardwareCapture()
            }
            return
        }

        while burstRemaining > 0,
              inFlightPhotoCaptureIDs.count < maximumBurstHardwareCapturesInFlight {
            // Always honor the first press immediately. After one request is in flight, let
            // Apple's readiness coordinator pace additional burst captures so we never build an
            // unbounded queue behind the photo processor.
            if !inFlightPhotoCaptureIDs.isEmpty, !photoCaptureCoordinator.isReady { break }
            let ordinal = max(1, burstRequestedCount - burstRemaining + 1)
            burstRemaining -= 1
            guard submitPhotoCapture(isBurst: true, burstOrdinal: ordinal) else {
                burstPipelineHadFailure = true
                burstRemaining = 0
                burstStopRequested = true
                if inFlightPhotoCaptureIDs.isEmpty {
                    finishBurstHardwareCapture()
                }
                break
            }
        }

        if burstRemaining == 0, inFlightPhotoCaptureIDs.isEmpty {
            finishBurstHardwareCapture()
        }
    }

    @discardableResult
    func submitPhotoCapture(isBurst: Bool, burstOrdinal: Int?) -> Bool {
        guard session.isRunning else { return false }

        let traceID: String
        if isBurst, let parent = activeBurstTraceID {
            traceID = "\(parent)-P\(burstOrdinal ?? 0)"
        } else {
            traceID = AppEventLog.makeTraceID("PHOTO")
        }
        let captureStartedAt = ProcessInfo.processInfo.systemUptime
        let aspect = isBurst ? burstAspect : (UserDefaults.standard.string(forKey: "photoAspect") ?? "4:3")
        let megapixels = isBurst ? burstMegapixels : selectedPhotoMegapixels
        let useHEIC = photoFileFormat == "HEIC" && photoOutput.availablePhotoCodecTypes.contains(.hevc)
        let mirrored = cameraPosition == .front && UserDefaults.standard.bool(forKey: "mirrorSelfies")
        if let connection = photoOutput.connection(with: .video) {
            if connection.isVideoMirroringSupported {
                connection.automaticallyAdjustsVideoMirroring = false
                connection.isVideoMirrored = mirrored
            }
            applyCaptureRotation(to: connection)
        }

        let settings = useHEIC
            ? AVCapturePhotoSettings(format: [AVVideoCodecKey: AVVideoCodecType.hevc])
            : AVCapturePhotoSettings(format: [AVVideoCodecKey: AVVideoCodecType.jpeg])

        let requestedFlash = photoFlashMode
        let appliedFlash = resolvedPhotoFlashMode()
        let appliedFlashLabel: String
        switch appliedFlash {
        case .off: appliedFlashLabel = "Off"
        case .auto: appliedFlashLabel = "Auto"
        case .on: appliedFlashLabel = "On"
        @unknown default: appliedFlashLabel = "Unknown"
        }
        settings.flashMode = appliedFlash

        // AVFoundation may override a locked device exposure for multi-image processing when
        // photo quality is .balanced/.quality. When AE is locked, use .speed so the saved photo
        // honors the device's locked exposure. Normal captures keep the existing balanced path.
        settings.photoQualityPrioritization = exposureLockedInHardware ? .speed : .balanced
        let dimensions = photoOutput.maxPhotoDimensions
        if dimensions.width > 0, dimensions.height > 0 {
            settings.maxPhotoDimensions = dimensions
        }

        let captureID = settings.uniqueID
        photoCaptureContexts[captureID] = PhotoCaptureContext(
            aspect: aspect,
            megapixels: megapixels,
            filename: nextMediaFilename(fileExtension: useHEIC ? "heic" : "jpg"),
            isBurst: isBurst,
            requestedFlash: requestedFlash.rawValue,
            appliedFlash: appliedFlashLabel,
            traceID: traceID,
            startedAt: captureStartedAt,
            burstOrdinal: burstOrdinal
        )
        inFlightPhotoCaptureIDs.insert(captureID)
        photoCaptureCoordinator.startTracking(settings)
        photoPerformanceIntervals[captureID] = performanceMonitor.begin(.photoRequest)

        let activeDevice = videoInput?.device
        let activeDimensions = activeDevice.map { CMVideoFormatDescriptionGetDimensions($0.activeFormat.formatDescription) }
        AppEventLog.event("PHOTO CAPTURE REQUEST", category: isBurst ? .burst : .photo, traceID: traceID, fields: [
            "captureID": String(captureID),
            "burstOrdinal": burstOrdinal.map(String.init) ?? "none",
            "requestedMP": String(megapixels),
            "codec": useHEIC ? "HEIC" : "JPEG",
            "aspect": aspect,
            "mirrored": String(mirrored),
            "flashRequested": requestedFlash.rawValue,
            "flashApplied": appliedFlashLabel,
            "photoQualityPriority": exposureLockedInHardware ? "speed (AE locked)" : "balanced",
            "responsive": String(photoOutput.isResponsiveCaptureEnabled),
            "zeroShutterLag": String(photoOutput.isZeroShutterLagEnabled),
            "fastCapturePrioritization": String(photoOutput.isFastCapturePrioritizationEnabled),
            "readiness": photoCaptureReadinessLabel(photoCaptureCoordinator.captureReadiness),
            "inFlight": String(inFlightPhotoCaptureIDs.count),
            "device": activeDevice?.localizedName ?? "none",
            "activePreviewFormat": activeDimensions.map { "\($0.width)x\($0.height)" } ?? "none",
            "maxPhotoDimensions": "\(dimensions.width)x\(dimensions.height)",
            "filename": photoCaptureContexts[captureID]?.filename ?? "unknown"
        ])
        if !isBurst { refreshAvailableStorage() }
        let submitAt = ProcessInfo.processInfo.systemUptime
        photoOutput.capturePhoto(with: settings, delegate: self)
        AppEventLog.deepEvent("capturePhoto() RETURNED", category: .photo, traceID: traceID, fields: [
            "callMs": String(format: "%.3f", (ProcessInfo.processInfo.systemUptime - submitAt) * 1000),
            "elapsedFromRequestMs": String(format: "%.3f", (ProcessInfo.processInfo.systemUptime - captureStartedAt) * 1000)
        ])
        return true
    }

    func finishBurstHardwareCapture() {
        guard activeBurstTraceID != nil else { return }
        let captured = burstCompletedCount
        let requested = burstRequestedCount
        let traceID = activeBurstTraceID
        burstRemaining = 0
        burstStopRequested = false
        activeBurstTraceID = nil
        burstRequestedCount = 0
        burstCompletedCount = 0
        publish { self.isCapturingPhoto = false }
        AppEventLog.event("========== BURST HARDWARE COMPLETE =========", category: .burst,
                          traceID: traceID, fields: [
            "requested": String(requested),
            "captured": String(captured),
            "pendingSaves": String(pendingPhotoSaves)
        ])
    }

    func cancelPendingPhotoScheduling(reason: String, abandonInFlight: Bool) {
        pendingSinglePhotoCapture = false
        burstRemaining = 0
        burstStopRequested = true

        if abandonInFlight {
            for captureID in inFlightPhotoCaptureIDs {
                photoCaptureCoordinator.stopTracking(captureID)
                if let interval = photoPerformanceIntervals.removeValue(forKey: captureID) {
                    performanceMonitor.end(interval)
                }
            }
            inFlightPhotoCaptureIDs.removeAll()
        }

        let burstTrace = activeBurstTraceID
        activeBurstTraceID = nil
        burstRequestedCount = 0
        burstCompletedCount = 0
        publish { self.isCapturingPhoto = false }
        AppEventLog.event("PHOTO HARDWARE SCHEDULER RESET", category: .photo, level: .info, traceID: burstTrace, fields: [
            "reason": reason,
            "abandonInFlight": String(abandonInFlight),
            "pendingSaves": String(pendingPhotoSaves),
            "retainedContexts": String(photoCaptureContexts.count)
        ])
    }

    func beginRecording() {
        let traceID = activeRecordingTraceID
        guard recordingState.requestsRecording, session.isRunning, movieOutput.isRecording == false else {
            AppEventLog.guardRejected("beginRecording", reason: "recording preconditions failed", traceID: traceID, fields: [
                "requestsRecording": String(recordingState.requestsRecording),
                "sessionRunning": String(session.isRunning),
                "movieOutputRecording": String(movieOutput.isRecording)
            ])
            transitionRecordingState(to: .idle, resetClock: true)
            return
        }
        AppEventLog.deepEvent("RECORDING PREPARATION BEGIN", category: .recording, traceID: traceID, fields: [
            "elapsedFromUserRequestMs": String(format: "%.2f", (ProcessInfo.processInfo.systemUptime - recordingRequestStartedAt) * 1000)
        ])

        var reconfiguredForRecording = false
        if captureMode == .video {
            if !activeVideoFormatMatchesSelection() {
                reconfiguredForRecording = true
                guard applySelectedFormat(
                    preferVirtualCamera: !requiresPhysicalWhiteBalanceInput
                ), activeVideoFormatMatchesSelection() else {
                    transitionRecordingState(to: .idle, resetClock: true)
                    showError("Couldn’t prepare the selected recording quality.")
                    return
                }
            }
        } else if captureMode == .sloMo {
            let activeSloMoReady = activeSlowMotionFormatMatchesSelection() &&
                videoInput.map {
                    formatSelector.supportsSlowMotion(
                        $0.device.activeFormat,
                        resolution: selectedSlowMotionResolution,
                        frameRate: selectedSlowMotionFrameRate
                    )
                } == true

            if !activeSloMoReady {
                reconfiguredForRecording = true
                guard applySlowMotionFormat(),
                      activeSlowMotionFormatMatchesSelection(),
                      let device = videoInput?.device,
                      formatSelector.supportsSlowMotion(
                          device.activeFormat,
                          resolution: selectedSlowMotionResolution,
                          frameRate: selectedSlowMotionFrameRate
                      ) else {
                    transitionRecordingState(to: .idle, resetClock: true)
                    showError("Couldn’t start the selected Slo-Mo frame rate.")
                    return
                }
            }
        }

        guard movieOutputSettingsMatchCurrentConfiguration(allowVerifiedHighDefault: true) ||
              configureMovieOutputSettings() else {
            transitionRecordingState(to: .idle, resetClock: true)
            showError("\(activeVideoCodec == "H264" ? "H.264" : "HEVC") isn’t available at this resolution/FPS on this lens.")
            return
        }

        applyCaptureRotation(to: movieOutput.connection(with: .video))
        movieOutput.metadata = CameraMovieMetadata.items(isSlowMotion: captureMode == .sloMo)

        // When the idle preview is already the exact recording configuration (the normal case for
        // rear 4K60 and Slo-Mo now), start immediately instead of imposing the old AF/AE wait. Only
        // keep the settle window for the recovery path that actually had to reconfigure hardware.
        let readinessDeadline = reconfiguredForRecording ? Date().addingTimeInterval(1.0) : Date()
        let storageStartRequestID = recordingStartRequests.next(reason: "recording storage safety check")
        let reserve = criticalStorageReserveBytes
        activeCriticalStorageReserveBytes = reserve
        AppEventLog.event("Recording storage check requested: reserve=\(reserve), bitrate=\(Int(estimatedVideoBitsPerSecond))", category: .storage, traceID: traceID,
                          fields: ["reconfiguredForRecording": String(reconfiguredForRecording)])
        storageGuard.checkNow(criticalReserveBytes: reserve) { [weak self] snapshot in
            guard let self else { return }
            self.sessionQueue.async {
                guard self.recordingStartRequests.isLatest(storageStartRequestID),
                      self.recordingState.requestsRecording,
                      self.appLifecyclePhase == .active,
                      self.session.isRunning else {
                    AppEventLog.staleRequest(token: "recordingStartRequests", requestID: storageStartRequestID,
                                                latestID: self.recordingStartRequests.current(), operation: "recording storage completion", traceID: self.activeRecordingTraceID)
                    return
                }
                guard let snapshot else {
                    self.transitionRecordingState(to: .idle, resetClock: true)
                    self.showError("Couldn’t check free storage before recording.")
                    return
                }

                self.applyStorageSnapshot(snapshot, source: "recording start")
                guard self.recordingStartRequests.isLatest(storageStartRequestID),
                      self.recordingState.requestsRecording,
                      !snapshot.isCritical else { return }

                let preparationCaptureSnapshot = self.captureConfigurationLogSnapshot(
                    "before start",
                    label: "RECORDING PREPARATION READBACK"
                )
                let preparationSessionSnapshot = self.captureSessionLogSnapshot("recording preparation")
                let enqueuePreparationDiagnostics: () -> Void = { [weak self] in
                    guard let self else { return }
                    self.enqueueCaptureConfigurationLog(
                        preparationCaptureSnapshot,
                        context: "before start",
                        label: "RECORDING PREPARATION READBACK"
                    )
                    AppEventLog.event(preparationSessionSnapshot)
                }
                self.startMovieOutputWhenReady(
                    deadline: readinessDeadline,
                    storageStartRequestID: storageStartRequestID,
                    afterStart: enqueuePreparationDiagnostics
                )
            }
        }
    }

    func startMovieOutputWhenReady(
        deadline: Date,
        storageStartRequestID: UInt64,
        afterStart: @escaping () -> Void = {}
    ) {
        guard recordingStartRequests.isLatest(storageStartRequestID),
              recordingState.requestsRecording,
              !movieOutput.isRecording else {
            AppEventLog.guardRejected("startMovieOutputWhenReady", reason: "request/state changed", traceID: activeRecordingTraceID, fields: [
                "requestID": String(storageStartRequestID), "latestID": String(recordingStartRequests.current()),
                "requestsRecording": String(recordingState.requestsRecording), "movieOutputRecording": String(movieOutput.isRecording)
            ])
            return
        }
        if let device = videoInput?.device,
           (device.isAdjustingFocus || device.isAdjustingExposure),
            Date() < deadline {
            sessionQueue.asyncAfter(deadline: .now() + 0.06) { [weak self] in
                self?.startMovieOutputWhenReady(
                    deadline: deadline,
                    storageStartRequestID: storageStartRequestID,
                    afterStart: afterStart
                )
            }
            return
        }

        guard recordingStartRequests.isLatest(storageStartRequestID), recordingState.requestsRecording else {
            AppEventLog.staleRequest(token: "recordingStartRequests", requestID: storageStartRequestID,
                                     latestID: recordingStartRequests.current(), operation: "movie output start", traceID: activeRecordingTraceID)
            return
        }
        let filename = nextMediaFilename(fileExtension: "mov")
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(filename)
        movieStartCallAt = ProcessInfo.processInfo.systemUptime
        performanceMonitor.end(recordingStartPerformanceInterval)
        recordingStartPerformanceInterval = performanceMonitor.begin(.recordingStart)
        AppEventLog.event("MOVIE OUTPUT startRecording()", category: .recording, traceID: activeRecordingTraceID, fields: [
            "filename": filename,
            "segment": String(recordingSegmentIndex),
            "elapsedFromUserRequestMs": String(format: "%.2f", (movieStartCallAt - recordingRequestStartedAt) * 1000),
            "focusAdjusting": String(videoInput?.device.isAdjustingFocus ?? false),
            "exposureAdjusting": String(videoInput?.device.isAdjustingExposure ?? false)
        ])
        storageGuard.startMonitoring(criticalReserveBytes: activeCriticalStorageReserveBytes) { [weak self] snapshot in
            self?.sessionQueue.async { [weak self] in
                self?.applyStorageSnapshot(snapshot, source: "recording monitor")
            }
        }
        movieOutput.startRecording(to: url, recordingDelegate: self)
        AppEventLog.deepEvent("MOVIE OUTPUT startRecording() RETURNED", category: .recording, traceID: activeRecordingTraceID, fields: [
            "callMs": String(format: "%.3f", (ProcessInfo.processInfo.systemUptime - movieStartCallAt) * 1000)
        ])
        afterStart()
    }

    func nextMediaFilename(fileExtension: String) -> String {
        let defaults = UserDefaults.standard
        let ext = fileExtension.lowercased()
        var number = defaults.integer(forKey: Self.mediaSequenceKey)
        if number < 1 || number > 9_999 { number = 1 }

        for _ in 0..<9_999 {
            let filename = String(format: "img_%04d.%@", number, ext)
            let tempURL = FileManager.default.temporaryDirectory.appendingPathComponent(filename)
            let next = number == 9_999 ? 1 : number + 1
            defaults.set(next, forKey: Self.mediaSequenceKey)
            let recoveryCollision = ext == "mov" && CameraRecoveryStore.containsRecording(named: filename)
            if !FileManager.default.fileExists(atPath: tempURL.path), !recoveryCollision {
                return filename
            }
            number = next
        }

        // Four digits are exhausted locally. Keep the lowercase prefix and add a short suffix
        // rather than overwriting an existing recording.
        return "img_\(UUID().uuidString.prefix(8).lowercased()).\(ext)"
    }

    func synchronizeTorchState() {
        guard let device = videoInput?.device else {
            publish {
                if self.activeLensLabel != "Lens —" { self.activeLensLabel = "Lens —" }
                if self.torchAvailable { self.torchAvailable = false }
                if self.isTorchOn { self.isTorchOn = false }
                if self.photoFlashAvailable { self.photoFlashAvailable = false }
                if self.torchBrightnessSupported { self.torchBrightnessSupported = false }
            }
            return
        }
        var torchOn = device.hasTorch && device.torchMode == .on
        if captureMode == .photo, torchOn {
            do {
                try device.lockForConfiguration()
                device.torchMode = .off
                device.unlockForConfiguration()
                torchOn = false
                AppEventLog.event("Torch forced off while Photo mode became active")
            } catch {
                AppEventLog.log(error: error, prefix: "Torch could not be disabled for Photo mode")
            }
        }
        let torchAvailable = device.hasTorch && device.isTorchAvailable
        let torchLevelSupported = device.hasTorch && device.isTorchModeSupported(.on)
        configurePhotoSceneMonitoring()
        let flashAvailable = device.hasFlash && !photoOutput.supportedFlashModes.isEmpty
        let lensLabel = lensDisplayLabel(for: device)
        publish {
            if self.activeLensLabel != lensLabel {
                self.activeLensLabel = lensLabel
            }
            if self.torchAvailable != torchAvailable {
                self.torchAvailable = torchAvailable
            }
            if self.isTorchOn != torchOn {
                self.isTorchOn = torchOn
            }
            if self.photoFlashAvailable != flashAvailable {
                self.photoFlashAvailable = flashAvailable
            }
            if self.torchBrightnessSupported != torchLevelSupported {
                self.torchBrightnessSupported = torchLevelSupported
            }
        }
    }

    func lensDisplayLabel(for device: AVCaptureDevice) -> String {
        guard cameraPosition == .back else { return "Front" }
        let displayedDevice: AVCaptureDevice
        if AppleCameraFeatureFlags.virtualRoutingV2, device.isVirtualDevice, let constituent = device.activePrimaryConstituent {
            displayedDevice = constituent
        } else {
            displayedDevice = device
        }
        switch displayedDevice.deviceType {
        case .builtInUltraWideCamera:
            return "Ultra Wide"
        case .builtInTelephotoCamera:
            return "Tele"
        case .builtInWideAngleCamera:
            return "Wide"
        case .builtInDualCamera, .builtInDualWideCamera, .builtInTripleCamera:
            return "Multi-Camera"
        default:
            return "Camera"
        }
    }

    func publish(_ update: @escaping () -> Void) {
        DispatchQueue.main.async(execute: update)
    }

}
