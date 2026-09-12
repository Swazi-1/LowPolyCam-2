import AVFoundation
import Combine
import Foundation
import Photos
import UIKit

// MARK: - CameraManager: Torch, zoom/lens transitions, camera/mode switching, live metrics, and longevity mode.

extension CameraManager {
    func toggleTorch() {
        sessionQueue.async { [weak self] in
            guard let self else { return }
            guard self.captureMode != .photo else { return }
            _ = self.torchRequests.next()
            guard let device = self.videoInput?.device, device.hasTorch else { return }
            if device.torchMode != .on && !device.isTorchAvailable {
                self.synchronizeTorchState()
                self.showError("Torch is temporarily unavailable.")
                return
            }
            self.setTorchEnabledOnCurrentDevice(device.torchMode != .on, showErrorOnFailure: true)
        }
    }

    func cyclePhotoFlashMode() {
        guard captureMode == .photo, photoFlashAvailable else { return }
        sessionQueue.async { [weak self] in
            guard let self, self.captureMode == .photo, self.photoFlashAvailable else { return }
            let next: PhotoFlashMode
            switch self.photoFlashMode {
            case .off: next = .auto
            case .auto: next = .on
            case .on: next = .off
            }
            self.publish {
                guard self.captureMode == .photo else { return }
                self.photoFlashMode = next
            }
            AppEventLog.event("Photo flash mode selected: \(next.rawValue)")
        }
    }

    /// Applies the requested torch state to whichever camera input is currently active.
    /// Mode changes can replace the AVCaptureDevice even though the user did not touch Flash,
    /// so this is also used immediately after a successful mode reconfiguration.
    struct TorchApplication {
        let requestedNormalizedLevel: Double
        let actualTorchLevel: Float
        let torchAvailable: Bool
        let deviceName: String
        let isOn: Bool
        let fallbackUsed: Bool
    }

    /// Must be called while `device` is locked for configuration. The Apple maximum-level
    /// constant is a sentinel for the API, not a physical scalar, so it is intentionally never
    /// read or multiplied here.
    func applyTorchConfigurationLocked(to device: AVCaptureDevice, enabled: Bool) -> TorchApplication {
        let requested = TorchLevelPolicy.validatedNormalized(torchBrightnessLevel)
        var fallbackUsed = false

        if enabled {
            guard device.isTorchAvailable else {
                fallbackUsed = true
                return TorchApplication(
                    requestedNormalizedLevel: requested,
                    actualTorchLevel: device.torchLevel,
                    torchAvailable: false,
                    deviceName: device.localizedName,
                    isOn: false,
                    fallbackUsed: fallbackUsed
                )
            }

            do {
                // Custom torch values are already normalized to the documented 0...1 range.
                try device.setTorchModeOn(level: Float(requested))
            } catch {
                // Some devices/thermal states expose only on/off at this moment. Preserve the
                // requested intent with the safe full-on fallback and make the fallback visible.
                device.torchMode = .on
                fallbackUsed = true
                AppEventLog.event("TORCH LEVEL FALLBACK", category: .torch, level: .warning, fields: [
                    "reason": "custom level rejected",
                    "requestedNormalizedLevel": String(format: "%.3f", requested),
                    "device": device.localizedName
                ])
            }
        } else {
            device.torchMode = .off
        }

        return TorchApplication(
            requestedNormalizedLevel: requested,
            actualTorchLevel: device.torchLevel,
            torchAvailable: device.isTorchAvailable,
            deviceName: device.localizedName,
            isOn: device.torchMode == .on,
            fallbackUsed: fallbackUsed
        )
    }

    func logTorchApplication(_ application: TorchApplication, reason: String) {
        AppEventLog.event("TORCH LEVEL APPLIED", category: .torch, fields: [
            "requestedNormalizedLevel": String(format: "%.3f", application.requestedNormalizedLevel),
            "actualTorchLevel": String(format: "%.3f", application.actualTorchLevel),
            "torchAvailable": String(application.torchAvailable),
            "device": application.deviceName,
            "fallbackUsed": String(application.fallbackUsed),
            "isOn": String(application.isOn),
            "reason": reason
        ])
    }

    func setTorchEnabledOnCurrentDevice(_ enabled: Bool, showErrorOnFailure: Bool = false) {
        guard let device = videoInput?.device, device.hasTorch else {
            publish {
                if self.torchAvailable { self.torchAvailable = false }
                if self.isTorchOn { self.isTorchOn = false }
                if self.torchBrightnessSupported { self.torchBrightnessSupported = false }
            }
            return
        }

        do {
            if enabled && !device.isTorchAvailable {
                publish {
                    if self.torchAvailable { self.torchAvailable = false }
                    if self.isTorchOn { self.isTorchOn = false }
                    if self.torchBrightnessSupported { self.torchBrightnessSupported = false }
                }
                logTorchApplication(
                    TorchApplication(
                        requestedNormalizedLevel: TorchLevelPolicy.validatedNormalized(torchBrightnessLevel),
                        actualTorchLevel: device.torchLevel,
                        torchAvailable: false,
                        deviceName: device.localizedName,
                        isOn: false,
                        fallbackUsed: true
                    ),
                    reason: "temporarily unavailable"
                )
                if showErrorOnFailure { showError("Torch is temporarily unavailable.") }
                return
            }
            try device.lockForConfiguration()
            let application = applyTorchConfigurationLocked(to: device, enabled: enabled)
            device.unlockForConfiguration()
            publish {
                if self.torchAvailable != application.torchAvailable {
                    self.torchAvailable = application.torchAvailable
                }
                if self.isTorchOn != application.isOn {
                    self.isTorchOn = application.isOn
                }
                let supportsIntensity = device.hasTorch && device.isTorchModeSupported(.on)
                if self.torchBrightnessSupported != supportsIntensity {
                    self.torchBrightnessSupported = supportsIntensity
                }
            }
            AppEventLog.event("Torch applied: \(application.isOn ? "on" : "off") on \(device.localizedName)")
            logTorchApplication(application, reason: enabled ? "toggle or restore" : "disabled")
        } catch {
            synchronizeTorchState()
            AppEventLog.event("TORCH LEVEL FALLBACK", category: .torch, level: .warning, fields: [
                "reason": "configuration lock failed",
                "requestedNormalizedLevel": String(format: "%.3f", TorchLevelPolicy.validatedNormalized(torchBrightnessLevel)),
                "actualTorchLevel": String(format: "%.3f", device.torchLevel),
                "torchAvailable": String(device.isTorchAvailable),
                "device": device.localizedName,
                "fallbackUsed": "true"
            ])
            if showErrorOnFailure { showError("Couldn’t change the torch.") }
        }
    }

    func setZoomFactor(_ requestedFactor: CGFloat) {
        let requestID = zoomRequests.next(reason: "zoom factor requested")
        let requestTraceID = "ZOOM-\(requestID)"
        AppEventLog.deepEvent("ZOOM REQUEST SUBMITTED", category: .zoom, traceID: requestTraceID, fields: [
            "requestedDisplayedZoom": String(format: "%.3f", Double(requestedFactor)),
            "publishedZoom": String(format: "%.3f", Double(zoomFactor)),
            "hudZoom": zoomLabel
        ])
        // A 60 Hz drag can outpace an expensive 4K60 lens handoff. Retain only the newest value
        // instead of leaving obsolete device/format scans queued behind the current camera work.
        zoomSubmissionLock.lock()
        pendingZoomSubmission = ZoomSubmission(factor: requestedFactor, requestID: requestID)
        let shouldSchedule = !isZoomSubmissionScheduled
        if shouldSchedule { isZoomSubmissionScheduled = true }
        zoomSubmissionLock.unlock()

        guard shouldSchedule else {
            AppEventLog.deepEvent("ZOOM REQUEST COALESCED", category: .zoom, traceID: requestTraceID)
            return
        }
        let ticket = AppEventLog.queueScheduled("drainZoomSubmissions", category: .zoom, traceID: requestTraceID)
        sessionQueue.async { [weak self] in
            AppEventLog.queueStarted(ticket)
            self?.drainZoomSubmissions()
        }
    }

    func beginZoomInteraction() {
        let trace = AppEventLog.extremeDiagnosticsEnabled ? AppEventLog.makeTraceID("ZOOM-INTERACTION") : nil
        sessionQueue.async { [weak self] in
            guard let self else { return }
            self.didLogRecordingLensClamp = false
            if let previousTrace = self.diagnosticZoomInteractionTraceID,
               self.diagnosticZoomProbeStarted {
                self.liveMetrics.endZoomTransitionProbe(traceID: previousTrace, reason: "zoom interaction superseded")
            }
            self.diagnosticZoomInteractionTraceID = trace
            self.diagnosticZoomProbeStarted = false
            AppEventLog.deepEvent("ZOOM GESTURE BEGIN", category: .zoom, traceID: trace, fields: [
                "requestedZoom": String(format: "%.3f", Double(self.requestedZoom)),
                "hudZoom": self.zoomLabel,
                "device": self.videoInput?.device.localizedName ?? "none"
            ])
        }
    }

    func endZoomInteraction() {
        sessionQueue.async { [weak self] in
            guard let self else { return }
            let trace = self.diagnosticZoomInteractionTraceID
            AppEventLog.deepEvent("ZOOM GESTURE END", category: .zoom, traceID: trace, fields: [
                "requestedZoom": String(format: "%.3f", Double(self.requestedZoom)),
                "hudZoom": self.zoomLabel,
                "deviceZoom": self.videoInput.map { String(format: "%.3f", Double($0.device.videoZoomFactor)) } ?? "none"
            ])
            if let trace {
                self.sessionQueue.asyncAfter(deadline: .now() + 1.0) { [weak self] in
                    guard let self, self.diagnosticZoomInteractionTraceID == trace else { return }
                    self.liveMetrics.endZoomTransitionProbe(traceID: trace, reason: "zoom interaction settled")
                    self.diagnosticZoomInteractionTraceID = nil
                    self.diagnosticZoomProbeStarted = false
                }
            }
        }
    }

    func drainZoomSubmissions() {
        while let submission = takePendingZoomSubmission() {
            applyZoomSubmission(submission)
        }
    }

    func takePendingZoomSubmission() -> ZoomSubmission? {
        zoomSubmissionLock.lock()
        defer { zoomSubmissionLock.unlock() }
        guard let submission = pendingZoomSubmission else {
            isZoomSubmissionScheduled = false
            return nil
        }
        pendingZoomSubmission = nil
        return submission
    }

    func applyZoomSubmission(_ submission: ZoomSubmission) {
            let requestID = submission.requestID
            let requestTraceID = "ZOOM-\(requestID)"
            let startedAt = ProcessInfo.processInfo.systemUptime
            guard zoomRequests.isLatest(requestID) else { return }
            guard let currentDevice = videoInput?.device else {
                AppEventLog.guardRejected("applyZoomSubmission", reason: "no active video input", traceID: requestTraceID)
                return
            }
            guard session.isRunning else {
                AppEventLog.guardRejected("applyZoomSubmission", reason: "session not running", traceID: requestTraceID)
                return
            }
            guard !session.isInterrupted else {
                AppEventLog.guardRejected("applyZoomSubmission", reason: "session interrupted", traceID: requestTraceID)
                return
            }
            AppEventLog.deepEvent("ZOOM APPLY BEGIN", category: .zoom, traceID: requestTraceID, fields: [
                "requested": String(format: "%.3f", Double(submission.factor)),
                "currentRequested": String(format: "%.3f", Double(requestedZoom)),
                "device": currentDevice.localizedName,
                "actualDeviceZoom": String(format: "%.3f", Double(currentDevice.videoZoomFactor)),
                "lensTransitionActive": String(lensTransitionCoordinator.hasActiveTransition)
            ])

            // minimumZoomFactor describes the currently attached input. It can be 1× while a
            // supported physical Ultra Wide lens can provide 0.5×, so using it here would clamp
            // the shortcut before desiredPhysicalDevice(...) gets a chance to route the handoff.
            // Keep the app-wide 0.5× floor until the selected lens has had a chance to clamp it.
            var requested = min(max(submission.factor, 0.5), maximumZoomFactor)
            if !lensTransitionCoordinator.hasActiveTransition,
               abs(requested - requestedZoom) < 0.0005 {
                AppEventLog.deepEvent("ZOOM APPLY NO-OP", category: .zoom, traceID: requestTraceID,
                                      fields: ["reason": "already at requested zoom"])
                return
            }

            // When rear 4K60 can stay on Apple's virtual Dual-Wide/Triple camera, keep the
            // capture session intact and let AVFoundation switch constituent cameras via zoom.
            // The short blur only masks the optical handoff; no AVCaptureDeviceInput is rebuilt.
            if !self.lensTransitionCoordinator.hasActiveTransition,
               self.lensTransitionCoordinator.shouldUseVirtual4K60Handoff(
                    on: currentDevice,
                    captureMode: self.captureMode,
                    cameraPosition: self.cameraPosition,
                    selectedResolution: self.selectedResolution,
                    selectedFrameRate: self.selectedFrameRate,
                    usesAutoWhiteBalance: self.requestedWhiteBalancePreset == .auto,
                    formatSelector: self.formatSelector
               ) {
                let currentDisplayed = self.displayedZoomFactor(for: currentDevice.videoZoomFactor, device: currentDevice)
                if self.lensTransitionCoordinator.crossesVirtualBoundary(
                    on: currentDevice,
                    from: currentDisplayed,
                    to: requested,
                    displayedZoomFactor: { factor, device in
                        self.displayedZoomFactor(for: factor, device: device)
                    }
                ) {
                    self.beginExtremeZoomTransitionProbeIfPossible(
                        device: currentDevice,
                        targetDisplayedZoom: requested,
                        requestTraceID: requestTraceID,
                        reason: "virtual lens boundary"
                    )
                    let request = LensTransitionCoordinator.Request(
                        id: requestID,
                        mode: self.captureMode,
                        requestedZoom: requested,
                        position: self.cameraPosition,
                        codec: self.selectedVideoCodec,
                        videoResolution: self.selectedResolution,
                        videoFrameRate: self.selectedFrameRate,
                        slowMotionResolution: self.selectedSlowMotionResolution,
                        slowMotionFrameRate: self.selectedSlowMotionFrameRate,
                        targetDeviceID: currentDevice.uniqueID
                    )
                    self.lensTransitionCoordinator.beginVirtualHandoff(
                        request,
                        device: currentDevice,
                        initialValidate: { [weak self] _, device in
                            guard let self else { return false }
                            return self.lensTransitionCoordinator.shouldUseVirtual4K60Handoff(
                                on: device,
                                captureMode: self.captureMode,
                                cameraPosition: self.cameraPosition,
                                selectedResolution: self.selectedResolution,
                                selectedFrameRate: self.selectedFrameRate,
                                usesAutoWhiteBalance: self.requestedWhiteBalancePreset == .auto,
                                formatSelector: self.formatSelector
                            )
                        },
                        delayedValidate: { [weak self] request, _ in
                            guard let self else { return false }
                            return self.videoInput?.device.uniqueID == request.targetDeviceID &&
                                self.captureMode == .video &&
                                self.cameraPosition == .back &&
                                self.selectedResolution == request.videoResolution &&
                                self.selectedFrameRate == request.videoFrameRate &&
                                self.selectedVideoCodec == request.codec
                        },
                        applyZoom: { [weak self] request, device in
                            self?.applyVirtualLensZoom(request, device: device) ?? false
                        },
                        onFailure: { [weak self] in
                            self?.showError("Couldn’t change the zoom.")
                        }
                    )
                    return
                }
            }

            if !currentDevice.isVirtualDevice, currentDevice.position == .back {
                let transitionDevices = self.lensTransitionCoordinator.supportedPhysicalLensDevices(
                    from: self.capabilityDevices(for: self.cameraPosition.avPosition),
                    captureMode: self.captureMode,
                    selectedResolution: self.selectedResolution,
                    selectedFrameRate: self.selectedFrameRate,
                    selectedSlowMotionResolution: self.selectedSlowMotionResolution,
                    selectedSlowMotionFrameRate: self.selectedSlowMotionFrameRate,
                    formatSelector: self.formatSelector
                )
                let candidateDevices: [AVCaptureDevice]
                if self.lensTransitionCoordinator.shouldUseCoveredPhysicalHandoff(
                    captureMode: self.captureMode,
                    cameraPosition: self.cameraPosition,
                    selectedResolution: self.selectedResolution,
                    selectedFrameRate: self.selectedFrameRate
                ) {
                    // Never cross onto a lens that cannot sustain the exact selected 4K60/HFR
                    // configuration. If capability discovery finds no alternative, stay put.
                    candidateDevices = transitionDevices.isEmpty ? [currentDevice] : transitionDevices
                } else {
                    candidateDevices = transitionDevices.isEmpty
                        ? self.capabilityDevices(for: .back).filter { !$0.isVirtualDevice }
                        : transitionDevices
                }
                let desiredPhysical = self.desiredPhysicalDevice(in: candidateDevices, forDisplayedZoom: requested)
                let wantsDifferentLens = desiredPhysical?.uniqueID != currentDevice.uniqueID

                if wantsDifferentLens {
                    let recordingOrStarting = self.movieOutput.isRecording || self.recordingState.requestsRecording || self.isRecordingStarting
                    if recordingOrStarting {
                        // Recording keeps the physical input fixed. There is no physical
                        // handoff to probe here, and the optional video-data diagnostics
                        // output is intentionally disabled for protected capture paths.
                        AppEventLog.deepEvent("FRAME-LEVEL ZOOM PROBE SKIPPED WHILE RECORDING",
                                              category: .zoom,
                                              traceID: diagnosticZoomInteractionTraceID ?? requestTraceID,
                                              fields: [
                                                "reason": "recording keeps the current physical lens; zoom is digital only",
                                                "mode": self.captureMode.rawValue,
                                                "device": currentDevice.localizedName,
                                                "requestedDisplayedZoom": String(format: "%.3f", Double(requested))
                                              ])
                    } else {
                        self.beginExtremeZoomTransitionProbeIfPossible(
                            device: currentDevice,
                            targetDisplayedZoom: requested,
                            requestTraceID: requestTraceID,
                            reason: "physical lens handoff",
                            probeExpectedDeviceZoom: currentDevice.videoZoomFactor
                        )
                    }
                    if recordingOrStarting && self.captureMode != .video {
                        // HFR recording must keep its physical input for the whole file. Do not
                        // reject the zoom gesture when it crosses the optical boundary; keep the
                        // active sensor and apply the part of the request that it can provide
                        // digitally. This is what lets rear Slo-Mo zoom from 0.5× while recording
                        // without rebuilding the 120/240 fps capture input mid-file.
                        let currentLensMinimum = self.minimumSupportedZoom(for: currentDevice)
                        let currentLensMaximum = self.maximumSupportedZoom(for: currentDevice)
                        let fixedLensZoom = min(max(requested, currentLensMinimum), currentLensMaximum)
                        if !self.didLogRecordingLensClamp {
                            self.didLogRecordingLensClamp = true
                            AppEventLog.event(
                                "Recording zoom kept on current physical lens: " +
                                "requested=\(String(format: "%.2f", requested))×, " +
                                "applied=\(String(format: "%.2f", fixedLensZoom))×, " +
                                "device=\(currentDevice.localizedName)"
                            )
                        }
                        requested = fixedLensZoom
                    }

                    // While recording, keep the physical input fixed and digitally zoom that
                    // sensor. Rebuilding AVCaptureDeviceInput mid-file can interrupt recording.
                    // Idle 4K60 and rear Slo-Mo use the covered physical-lens handoff below.
                    if !recordingOrStarting {
                        if self.lensTransitionCoordinator.shouldUseCoveredPhysicalHandoff(
                            captureMode: self.captureMode,
                            cameraPosition: self.cameraPosition,
                            selectedResolution: self.selectedResolution,
                            selectedFrameRate: self.selectedFrameRate
                        ), let desiredPhysical {
                            let request = LensTransitionCoordinator.Request(
                                id: requestID,
                                mode: self.captureMode,
                                requestedZoom: requested,
                                position: self.cameraPosition,
                                codec: self.selectedVideoCodec,
                                videoResolution: self.selectedResolution,
                                videoFrameRate: self.selectedFrameRate,
                                slowMotionResolution: self.selectedSlowMotionResolution,
                                slowMotionFrameRate: self.selectedSlowMotionFrameRate,
                                targetDeviceID: desiredPhysical.uniqueID
                            )
                            self.lensTransitionCoordinator.beginPhysicalHandoff(
                                request,
                                devices: self.capabilityDevices(for: request.position.avPosition),
                                currentDeviceID: self.videoInput?.device.uniqueID,
                                selectedResolution: self.selectedResolution,
                                selectedFrameRate: self.selectedFrameRate,
                                selectedSlowMotionResolution: self.selectedSlowMotionResolution,
                                selectedSlowMotionFrameRate: self.selectedSlowMotionFrameRate,
                                selectedVideoCodec: self.selectedVideoCodec,
                                formatSelector: self.formatSelector,
                                applyPrepared: { [weak self] prepared in
                                    self?.applyPreparedLensHardware(prepared) ?? false
                                },
                                recoverAfterFailedApply: { [weak self] _ in
                                    guard let self, let device = self.videoInput?.device else { return }
                                    let actualZoom = self.displayedZoomFactor(for: device.videoZoomFactor, device: device)
                                    self.requestedZoom = actualZoom
                                    self.publish {
                                        self.applyPublishedZoomIfNeeded(actualZoom)
                                    }
                                },
                                onPreparationFailure: { [weak self] in
                                    self?.showError("This lens can’t use the selected camera format.")
                                },
                                onApplyFailure: { [weak self] in
                                    self?.showError("Couldn’t finish the lens transition.")
                                }
                            )
                            return
                        }

                        let previousRequested = self.requestedZoom
                        self.requestedZoom = requested
                        guard self.zoomRequests.isLatest(requestID),
                              self.applyActiveModeFormat(preferVirtualCamera: !self.requiresPhysicalWhiteBalanceInput),
                              self.zoomRequests.isLatest(requestID) else {
                            self.requestedZoom = previousRequested
                            return
                        }
                        // applyActiveModeFormat already applied and published the snapped zoom on the
                        // correct physical lens. Do not queue a second ramp after the lens switch.
                        return
                    }
                }
            }

            guard self.zoomRequests.isLatest(requestID),
                  let device = self.videoInput?.device else { return }
            let factor = self.snappedZoomFactor(requested, for: device)
            do {
                let lockStart = ProcessInfo.processInfo.systemUptime
                try device.lockForConfiguration()
                let lockWaitMs = (ProcessInfo.processInfo.systemUptime - lockStart) * 1000
                let deviceFactor = self.deviceZoomFactor(for: factor, device: device)
                AppEventLog.deepEvent("ZOOM DEVICE LOCK ACQUIRED", category: .device, traceID: requestTraceID, fields: [
                    "waitMs": String(format: "%.2f", lockWaitMs),
                    "targetDeviceZoom": String(format: "%.3f", Double(deviceFactor))
                ])

                let usedImmediateSet = self.lensTransitionCoordinator.hasActiveTransition
                if usedImmediateSet {
                    // A newer drag returned to the currently active lens while a covered switch
                    // was pending/settling. Keep the cover up, commit the newest zoom immediately
                    // (no post-transition ramp), then let this newest request own the reveal.
                    self.lensTransitionCoordinator.takeOwnership(of: requestID)
                    device.cancelVideoZoomRamp()
                    device.videoZoomFactor = deviceFactor
                } else {
                    device.ramp(toVideoZoomFactor: deviceFactor, withRate: 12)
                }
                let readbackZoom = device.videoZoomFactor
                device.unlockForConfiguration()
                guard self.zoomRequests.isLatest(requestID) else { return }
                self.requestedZoom = factor

                if usedImmediateSet {
                    AppEventLog.deepEvent("ZOOM HARDWARE SET", category: .zoom, traceID: requestTraceID, fields: [
                        "displayedTarget": String(format: "%.3f", Double(factor)),
                        "deviceTarget": String(format: "%.3f", Double(deviceFactor)),
                        "deviceReadback": String(format: "%.3f", Double(readbackZoom)),
                        "durationMs": String(format: "%.2f", (ProcessInfo.processInfo.systemUptime - startedAt) * 1000)
                    ])
                } else {
                    // ramp(toVideoZoomFactor:) is asynchronous. The previous diagnostic event called
                    // this state "HARDWARE APPLIED" even though immediate readback was usually still
                    // at the old zoom. Record scheduling separately and verify the eventual settle.
                    AppEventLog.deepEvent("ZOOM RAMP SCHEDULED", category: .zoom, traceID: requestTraceID, fields: [
                        "displayedTarget": String(format: "%.3f", Double(factor)),
                        "deviceTarget": String(format: "%.3f", Double(deviceFactor)),
                        "initialReadback": String(format: "%.3f", Double(readbackZoom)),
                        "durationMs": String(format: "%.2f", (ProcessInfo.processInfo.systemUptime - startedAt) * 1000)
                    ])
                    self.monitorZoomRamp(
                        requestID: requestID,
                        traceID: requestTraceID,
                        device: device,
                        targetDeviceZoom: deviceFactor,
                        displayedTarget: factor
                    )
                }

                self.publish {
                    self.applyPublishedZoomIfNeeded(factor)
                }

                if usedImmediateSet, self.lensTransitionCoordinator.isActive(requestID) {
                    self.lensTransitionCoordinator.finishWhenDeviceSettled(
                        requestID,
                        device: device,
                        minimumHold: 0.08,
                        maximumHold: 0.30
                    )
                }
            } catch {
                // If this request inherited an existing transition cover before the hardware lock
                // failed, make sure the cover cannot stay stuck indefinitely. The coordinator only
                // releases it when this exact request still owns the transition.
                self.lensTransitionCoordinator.abortIfOwned(requestID, reason: "zoom device configuration failed")
                AppEventLog.log(error: error, prefix: "ZOOM APPLY FAILED", category: .zoom, traceID: requestTraceID)
                self.showError("Couldn’t change the zoom.")
            }
    }

    func monitorZoomRamp(
        requestID: UInt64,
        traceID: String,
        device: AVCaptureDevice,
        targetDeviceZoom: CGFloat,
        displayedTarget: CGFloat,
        startedAt: TimeInterval = ProcessInfo.processInfo.systemUptime
    ) {
        sessionQueue.asyncAfter(deadline: .now() + 0.025) { [weak self, weak device] in
            guard let self, let device,
                  self.zoomRequests.isLatest(requestID),
                  self.videoInput?.device.uniqueID == device.uniqueID else { return }

            let now = ProcessInfo.processInfo.systemUptime
            let readback = device.videoZoomFactor
            let delta = abs(readback - targetDeviceZoom)
            let tolerance = max(CGFloat(0.02), abs(targetDeviceZoom) * 0.005)
            if delta <= tolerance {
                AppEventLog.deepEvent("ZOOM RAMP SETTLED", category: .zoom, traceID: traceID, fields: [
                    "displayedTarget": String(format: "%.3f", Double(displayedTarget)),
                    "deviceTarget": String(format: "%.3f", Double(targetDeviceZoom)),
                    "deviceReadback": String(format: "%.3f", Double(readback)),
                    "elapsedMs": String(format: "%.2f", (now - startedAt) * 1000)
                ])
                return
            }

            if !device.isRampingVideoZoom, now - startedAt > 0.075 {
                AppEventLog.event("ZOOM RAMP STOPPED BEFORE TARGET", category: .zoom, level: .warning, traceID: traceID, fields: [
                    "displayedTarget": String(format: "%.3f", Double(displayedTarget)),
                    "deviceTarget": String(format: "%.3f", Double(targetDeviceZoom)),
                    "deviceReadback": String(format: "%.3f", Double(readback)),
                    "delta": String(format: "%.3f", Double(delta)),
                    "elapsedMs": String(format: "%.2f", (now - startedAt) * 1000)
                ])
                return
            }

            if now - startedAt >= 0.80 {
                AppEventLog.event("ZOOM RAMP SETTLE TIMEOUT", category: .zoom, level: .warning, traceID: traceID, fields: [
                    "displayedTarget": String(format: "%.3f", Double(displayedTarget)),
                    "deviceTarget": String(format: "%.3f", Double(targetDeviceZoom)),
                    "deviceReadback": String(format: "%.3f", Double(readback)),
                    "delta": String(format: "%.3f", Double(delta))
                ])
                return
            }

            self.monitorZoomRamp(
                requestID: requestID,
                traceID: traceID,
                device: device,
                targetDeviceZoom: targetDeviceZoom,
                displayedTarget: displayedTarget,
                startedAt: startedAt
            )
        }
    }

    func beginExtremeZoomTransitionProbeIfPossible(
        device: AVCaptureDevice,
        targetDisplayedZoom: CGFloat,
        requestTraceID: String,
        reason: String,
        probeExpectedDeviceZoom: CGFloat? = nil
    ) {
        guard AppEventLog.extremeDiagnosticsEnabled else { return }
        let interactionTrace = diagnosticZoomInteractionTraceID ?? requestTraceID
        let targetDeviceZoom = deviceZoomFactor(for: snappedZoomFactor(targetDisplayedZoom, for: device), device: device)
        // During a physical handoff the callback stream still belongs to the old input until
        // commitConfiguration() succeeds. Compare those frames with the old input's current
        // zoom; after commit, applyPreparedLensHardware retargets the probe to the new device
        // and its committed zoom. Comparing the old stream with the future target creates false
        // flicker warnings for every frame while the cover is up.
        let expectedDeviceZoom = probeExpectedDeviceZoom ?? targetDeviceZoom
        let canObserveFrames = session.outputs.contains { $0 === liveMetrics.output } &&
            liveMetrics.output.connection(with: .video)?.isEnabled == true
        AppEventLog.deepEvent("EXTREME ZOOM TRANSITION MONITOR", category: .zoom, traceID: interactionTrace, fields: [
            "reason": reason,
            "requestTrace": requestTraceID,
            "frameProbeAvailable": String(canObserveFrames),
            "device": device.localizedName,
            "actualDeviceZoomBefore": String(format: "%.3f", Double(device.videoZoomFactor)),
            "targetDisplayedZoom": String(format: "%.3f", Double(targetDisplayedZoom)),
            "targetDeviceZoom": String(format: "%.3f", Double(targetDeviceZoom)),
            "probeExpectedDeviceZoom": String(format: "%.3f", Double(expectedDeviceZoom)),
            "probeExpectation": probeExpectedDeviceZoom == nil ? "future target" : "current device until handoff commit"
        ])
        guard canObserveFrames else {
            AppEventLog.deepEvent("FRAME-LEVEL ZOOM PROBE UNAVAILABLE", category: .zoom, traceID: interactionTrace,
                                  fields: ["reason": "video-data diagnostics output intentionally unavailable/disabled for this capture configuration"])
            return
        }
        if diagnosticZoomProbeStarted {
            liveMetrics.updateZoomTransitionProbe(
                traceID: interactionTrace,
                device: device,
                expectedDeviceZoom: expectedDeviceZoom,
                expectedDisplayedZoom: targetDisplayedZoom,
                hudZoom: formattedZoomLabel(for: targetDisplayedZoom)
            )
        } else {
            diagnosticZoomProbeStarted = true
            liveMetrics.beginZoomTransitionProbe(
                traceID: interactionTrace,
                device: device,
                expectedDeviceZoom: expectedDeviceZoom,
                expectedDisplayedZoom: targetDisplayedZoom,
                hudZoom: formattedZoomLabel(for: targetDisplayedZoom)
            )
        }
    }

    func applyVirtualLensZoom(_ request: LensTransitionCoordinator.Request, device: AVCaptureDevice) -> Bool {
        let factor = snappedZoomFactor(request.requestedZoom, for: device)
        let traceID = "ZOOM-\(request.id)"
        do {
            let lockStart = ProcessInfo.processInfo.systemUptime
            try device.lockForConfiguration()
            let lockWait = (ProcessInfo.processInfo.systemUptime - lockStart) * 1000
            let target = deviceZoomFactor(for: factor, device: device)
            let before = device.videoZoomFactor
            device.cancelVideoZoomRamp()
            device.videoZoomFactor = target
            let after = device.videoZoomFactor
            device.unlockForConfiguration()
            AppEventLog.deepEvent("VIRTUAL LENS ZOOM SET", category: .zoom, traceID: traceID, fields: [
                "lockWaitMs": String(format: "%.2f", lockWait),
                "before": String(format: "%.3f", Double(before)),
                "target": String(format: "%.3f", Double(target)),
                "readback": String(format: "%.3f", Double(after)),
                "displayedTarget": String(format: "%.3f", Double(factor))
            ])
            if let interactionTrace = diagnosticZoomInteractionTraceID, diagnosticZoomProbeStarted {
                liveMetrics.updateZoomTransitionProbe(
                    traceID: interactionTrace,
                    device: device,
                    expectedDeviceZoom: target,
                    expectedDisplayedZoom: factor,
                    hudZoom: formattedZoomLabel(for: factor)
                )
            }
        } catch {
            AppEventLog.log(error: error, prefix: "VIRTUAL LENS ZOOM FAILED", category: .zoom, traceID: traceID)
            return false
        }

        // The hardware zoom succeeded. If a newer request took ownership during the device call,
        // leave publishing/reveal to that request exactly as the previous inlined path did.
        guard lensTransitionCoordinator.isActive(request.id),
              zoomRequests.isLatest(request.id) else { return true }
        requestedZoom = factor
        publish {
            self.applyPublishedZoomIfNeeded(factor)
        }
        return true
    }

    func applyPreparedLensHardware(_ prepared: LensTransitionCoordinator.PreparedTransition) -> Bool {
        let request = prepared.request
        guard lensTransitionCoordinator.isActive(request.id),
              zoomRequests.isLatest(request.id),
              captureMode == request.mode,
              cameraPosition == request.position,
              selectedVideoCodec == request.codec else { return false }

        let previousRequested = requestedZoom
        requestedZoom = request.requestedZoom
        guard let displayed = applyAtomicCaptureConfiguration(
            device: prepared.device,
            format: prepared.format,
            frameRate: prepared.frameRate,
            preparedReplacementInput: prepared.replacementInput,
            refreshAuxiliaryOutputs: false
        ) else {
            requestedZoom = previousRequested
            return false
        }

        // Input replacement may recreate the movie-output connection, but on devices where the
        // connection and its settings survive the swap, do not tear the encoder/stabilization
        // configuration down and rebuild it again. That extra reset is especially expensive at
        // 4K60 and is unnecessary when the desired settings are already in place.
        if !movieOutputSettingsMatchCurrentConfiguration() {
            _ = configureMovieOutputSettings()
        }
        // This handoff keeps the same mode, resolution and frame rate, so the published zoom
        // range is already correct. Re-scanning every format on every lens after the blocking
        // hardware commit only extends the visible transition.
        let torchAvailable = prepared.device.hasTorch && prepared.device.isTorchAvailable
        let torchOn = prepared.device.hasTorch && prepared.device.torchMode == .on
        let lensLabel = lensDisplayLabel(for: prepared.device)
        publish {
            self.applyPublishedZoomIfNeeded(displayed)
            if self.activeLensLabel != lensLabel {
                self.activeLensLabel = lensLabel
            }
            if self.torchAvailable != torchAvailable {
                self.torchAvailable = torchAvailable
            }
            if self.isTorchOn != torchOn {
                self.isTorchOn = torchOn
            }
        }
        resetFocusAndExposureState()
        synchronizeWhiteBalanceAfterConfiguration()
        logCaptureConfiguration("Lens handoff")

        if let interactionTrace = diagnosticZoomInteractionTraceID,
           diagnosticZoomProbeStarted {
            liveMetrics.retargetZoomTransitionProbe(
                traceID: interactionTrace,
                device: prepared.device,
                expectedDeviceZoom: prepared.device.videoZoomFactor,
                expectedDisplayedZoom: displayed,
                hudZoom: formattedZoomLabel(for: displayed),
                reason: "physical lens handoff committed"
            )
        }

        // applyAtomicCaptureConfiguration has already validated the input replacement, locked the
        // target device, applied the requested format/FPS/zoom, and successfully committed the
        // capture-session transaction. Do not fail the transition on an immediate post-commit
        // read-back: AVFoundation can report transient duration/zoom state while the new 4K60/HFR
        // stream is still settling, which produced the false “Couldn’t finish…” message even though
        // the lens switch itself completed correctly.
        return true
    }



    func setRememberCameraSetupEnabled(_ enabled: Bool) {
        UserDefaults.standard.set(enabled, forKey: "rememberCaptureMode")
        if enabled {
            persistRememberedCameraSetup()
            AppEventLog.event(
                "CAMERA SETUP MEMORY ENABLED: mode=\(captureMode.rawValue), position=\(cameraPosition.rawValue)"
            )
        } else {
            AppEventLog.event("CAMERA SETUP MEMORY DISABLED")
        }
    }

    func persistRememberedCameraSetup() {
        guard UserDefaults.standard.bool(forKey: "rememberCaptureMode") else { return }
        UserDefaults.standard.set(captureMode.rawValue, forKey: "lastCaptureMode")
        UserDefaults.standard.set(cameraPosition.rawValue, forKey: "lastCameraPosition")
    }

    func switchCamera() {
        guard !isRecording, !isRecordingStarting, !isFinalizingRecording, !isCapturingPhoto, !isLensTransitioning else {
            AppEventLog.guardRejected("switchCamera", reason: "camera busy", fields: [
                "recording": String(isRecording), "recordingStarting": String(isRecordingStarting),
                "finalizing": String(isFinalizingRecording), "capturingPhoto": String(isCapturingPhoto),
                "lensTransition": String(isLensTransitioning)
            ])
            return
        }
        let previous = cameraPosition
        let target: CameraPosition = previous == .back ? .front : .back
        let switchTraceID = AppEventLog.makeTraceID("CAMSWITCH")
        let switchStartedAt = ProcessInfo.processInfo.systemUptime
        let beforeDevice = videoInput?.device
        AppEventLog.event("========== CAMERA SWITCH START =========", category: .device, traceID: switchTraceID, fields: [
            "from": previous.rawValue, "to": target.rawValue,
            "device": beforeDevice?.localizedName ?? "none",
            "deviceID": beforeDevice?.uniqueID ?? "none",
            "mode": captureMode.rawValue,
            "requestedZoom": String(format: "%.3f", requestedZoom),
            "actualDeviceZoom": beforeDevice.map { String(format: "%.3f", $0.videoZoomFactor) } ?? "none"
        ])
        let previousCodec = selectedVideoCodec
        let previousSupportedResolutions = supportedResolutions
        let previousSupportedFrameRates = supportedFrameRates
        let previousVideoAvailabilityKnown = isVideoAvailabilityKnown
        let previousVideoAvailable = isVideoAvailable
        let previousSupportedSlowMotionResolutions = supportedSlowMotionResolutions
        let previousSupportedSlowMotionFrameRates = supportedSlowMotionFrameRates
        let previousSlowMotionAvailabilityKnown = isSlowMotionAvailabilityKnown
        let previousSlowMotionAvailable = isSlowMotionAvailable
        AppEventLog.event("Camera switch requested: \(previous == .back ? "back" : "front") to \(target == .back ? "back" : "front")", category: .device, traceID: switchTraceID)
        invalidateCodecSupportCache()
        codecAvailabilityMessage = nil
        isVideoAvailabilityKnown = false
        isVideoAvailable = true
        supportedResolutions.removeAll(keepingCapacity: true)
        supportedFrameRates.removeAll(keepingCapacity: true)
        supportedSlowMotionResolutions.removeAll(keepingCapacity: true)
        supportedSlowMotionFrameRates.removeAll(keepingCapacity: true)
        isSlowMotionAvailabilityKnown = false
        isSlowMotionAvailable = true
        _ = capabilityRequests.next(reason: "camera switch invalidated capability snapshot")
        publish {
            self.capabilitySnapshot = .empty
            self.isCapabilitySnapshotLoading = true
        }
        let requestID = cameraSwitchRequests.next(reason: "camera switch \(previous.rawValue) -> \(target.rawValue)")
        let switchQueueTicket = AppEventLog.queueScheduled("camera switch", category: .device, traceID: switchTraceID)
        _ = zoomRequests.next() // Drop any drag command that belongs to the old camera.
        _ = qualityRequests.next() // Do not apply an old quality request to the new input.
        _ = captureConfigurationGeneration.next() // Drop output work captured for the old input.
        _ = videoConfigurationRequests.next() // Drop pending Video-setting work for the old input.
        _ = exposureRequests.next() // Do not apply a queued slider value to the new input.

        cameraPosition = target
        loadCameraPreferences(for: target)
        _ = autoPromoteH264ForUnsupportedVideoSelection(
            position: target,
            resolution: selectedResolution,
            frameRate: selectedFrameRate
        )

        sessionQueue.async { [weak self] in
            AppEventLog.queueStarted(switchQueueTicket)
            guard let self else { return }
            guard self.cameraSwitchRequests.isLatest(requestID) else {
                AppEventLog.staleRequest(token: "cameraSwitchRequests", requestID: requestID, latestID: self.cameraSwitchRequests.current(), operation: "camera switch", traceID: switchTraceID)
                return
            }
            self.invalidatePendingVideoConfiguration()
            self.lensTransitionCoordinator.cancel()
            guard self.applyActiveModeFormat(preferVirtualCamera: !self.requiresPhysicalWhiteBalanceInput) else {
                AppEventLog.event("CAMERA SWITCH FORMAT/APPLY FAILED", category: .device, level: .warning, traceID: switchTraceID,
                                  fields: ["elapsedMs": String(format: "%.2f", (ProcessInfo.processInfo.systemUptime - switchStartedAt) * 1000)])
                guard self.cameraSwitchRequests.isLatest(requestID) else {
                    AppEventLog.staleRequest(token: "cameraSwitchRequests", requestID: requestID, latestID: self.cameraSwitchRequests.current(), operation: "camera switch rollback", traceID: switchTraceID)
                    return
                }
                self.publish {
                    self.cameraPosition = previous
                    self.loadCameraPreferences(for: previous)
                    let wasSuppressing = self.suppressAutomaticReconfiguration
                    self.suppressAutomaticReconfiguration = true
                    if self.selectedVideoCodec != previousCodec {
                        self.selectedVideoCodec = previousCodec
                    }
                    self.suppressAutomaticReconfiguration = wasSuppressing
                    self.supportedResolutions = previousSupportedResolutions
                    self.supportedFrameRates = previousSupportedFrameRates
                    self.isVideoAvailabilityKnown = previousVideoAvailabilityKnown
                    self.isVideoAvailable = previousVideoAvailable
                    self.supportedSlowMotionResolutions = previousSupportedSlowMotionResolutions
                    self.supportedSlowMotionFrameRates = previousSupportedSlowMotionFrameRates
                    self.isSlowMotionAvailabilityKnown = previousSlowMotionAvailabilityKnown
                    self.isSlowMotionAvailable = previousSlowMotionAvailable
                    self.codecAvailabilityMessage = nil
                    self.capabilitySnapshot = .empty
                    self.isCapabilitySnapshotLoading = false
                    self.scheduleCapabilitySnapshotRefresh(reason: "camera switch rolled back")
                }
                self.showError("That camera is unavailable.")
                AppEventLog.event("========== CAMERA SWITCH END =========", category: .device, level: .warning, traceID: switchTraceID,
                                  fields: ["result": "failed", "totalMs": String(format: "%.2f", (ProcessInfo.processInfo.systemUptime - switchStartedAt) * 1000)])
                return
            }
            guard self.cameraSwitchRequests.isLatest(requestID) else {
                AppEventLog.staleRequest(token: "cameraSwitchRequests", requestID: requestID, latestID: self.cameraSwitchRequests.current(), operation: "camera switch post-apply", traceID: switchTraceID)
                return
            }
            self.synchronizeTorchState()
            self.persistRememberedCameraSetup()
            self.scheduleCapabilitySnapshotRefresh(reason: "camera switch applied")
            let afterDevice = self.videoInput?.device
            AppEventLog.event("Camera switch applied: \(target == .back ? "back" : "front")", category: .device, traceID: switchTraceID, fields: [
                "device": afterDevice?.localizedName ?? "none",
                "deviceID": afterDevice?.uniqueID ?? "none",
                "actualDeviceZoom": afterDevice.map { String(format: "%.3f", $0.videoZoomFactor) } ?? "none",
                "totalMs": String(format: "%.2f", (ProcessInfo.processInfo.systemUptime - switchStartedAt) * 1000)
            ])
            AppEventLog.stateDiff("CAMERA SWITCH", before: ["position": previous.rawValue, "device": beforeDevice?.localizedName ?? "none"],
                                  after: ["position": target.rawValue, "device": afterDevice?.localizedName ?? "none"], traceID: switchTraceID, category: .device)
            AppEventLog.event("========== CAMERA SWITCH END =========", category: .device, traceID: switchTraceID,
                              fields: ["result": "success", "totalMs": String(format: "%.2f", (ProcessInfo.processInfo.systemUptime - switchStartedAt) * 1000)])
        }
    }

    func selectCaptureMode(_ mode: CaptureMode) {
        guard !isRecording, !isRecordingStarting, !isFinalizingRecording, !isCapturingPhoto, !isPreviewTransitioning, !isLensTransitioning, captureMode != mode else {
            AppEventLog.guardRejected("selectCaptureMode", reason: "busy or already selected", fields: [
                "requested": mode.rawValue, "current": captureMode.rawValue,
                "recording": String(isRecording), "capturingPhoto": String(isCapturingPhoto),
                "previewTransition": String(isPreviewTransitioning), "lensTransition": String(isLensTransitioning)
            ])
            return
        }
        guard isCaptureModeSupported(mode) else {
            AppEventLog.guardRejected("selectCaptureMode", reason: "unsupported mode", fields: ["requested": mode.rawValue])
            return
        }
        let previousMode = captureMode
        let modeTraceID = AppEventLog.makeTraceID("MODE")
        let modeStartedAt = ProcessInfo.processInfo.systemUptime
        AppEventLog.event("========== MODE CHANGE START =========", category: .session, traceID: modeTraceID,
                          fields: ["from": previousMode.rawValue, "to": mode.rawValue, "camera": cameraPosition.rawValue])
        AppEventLog.event("Capture mode requested: \(previousMode.rawValue) to \(mode.rawValue)", category: .session, traceID: modeTraceID)
        codecAvailabilityMessage = nil
        let requestID = modeChangeRequests.next(reason: "capture mode \(previousMode.rawValue) -> \(mode.rawValue)")
        let modeQueueTicket = AppEventLog.queueScheduled("capture mode change", category: .session, traceID: modeTraceID)
        _ = zoomRequests.next() // A queued old-mode zoom must not reconfigure the new mode.
        _ = qualityRequests.next() // Drop quality work that belonged to the previous mode.
        _ = captureConfigurationGeneration.next() // Drop output work captured for the previous mode.
        _ = videoConfigurationRequests.next() // Drop pending Video-setting work for the previous mode.
        _ = exposureRequests.next() // The new mode reapplies the current requested EV itself.
        isPreviewTransitioning = true
        captureMode = mode
        if mode == .video {
            _ = autoPromoteH264ForUnsupportedVideoSelection(
                position: cameraPosition,
                resolution: selectedResolution,
                frameRate: selectedFrameRate
            )
        }
        sessionQueue.async { [weak self] in
            AppEventLog.queueStarted(modeQueueTicket)
            guard let self else { return }
            guard self.modeChangeRequests.isLatest(requestID) else {
                AppEventLog.staleRequest(token: "modeChangeRequests", requestID: requestID, latestID: self.modeChangeRequests.current(), operation: "capture mode change", traceID: modeTraceID)
                return
            }
            self.invalidatePendingVideoConfiguration()
            self.lensTransitionCoordinator.cancel()
            let success = self.applyActiveModeFormat(
                preferVirtualCamera: !self.requiresPhysicalWhiteBalanceInput,
                deferMovieOutputConfiguration: true
            )
            if success {
                self.configureAudioMeterOutput()
                if mode == .photo {
                    self.setTorchEnabledOnCurrentDevice(false)
                }
                self.synchronizeTorchState()
            }
            AppEventLog.event("Capture mode \(success ? "applied" : "failed"): \(mode.rawValue)", category: .session,
                              level: success ? .info : .warning, traceID: modeTraceID,
                              fields: ["totalMs": String(format: "%.2f", (ProcessInfo.processInfo.systemUptime - modeStartedAt) * 1000),
                                       "device": self.videoInput?.device.localizedName ?? "none"])

            self.publish {
                self.isPreviewTransitioning = false
                if success {
                    self.persistRememberedCameraSetup()
                    self.scheduleCapabilitySnapshotRefresh(reason: "capture mode applied")
                } else {
                    self.captureMode = previousMode
                    self.sessionQueue.async {
                        _ = self.applyActiveModeFormat(preferVirtualCamera: !self.requiresPhysicalWhiteBalanceInput)
                        self.synchronizeTorchState()
                    }
                    self.scheduleCapabilitySnapshotRefresh(reason: "capture mode rolled back")
                }
                AppEventLog.event("========== MODE CHANGE END =========", category: .session,
                                  level: success ? .info : .warning, traceID: modeTraceID,
                                  fields: ["result": success ? "success" : "rolled-back",
                                           "publishedMode": self.captureMode.rawValue,
                                           "totalMs": String(format: "%.2f", (ProcessInfo.processInfo.systemUptime - modeStartedAt) * 1000)])
            }
        }
    }

    func scheduleTorchRestoreAfterLensHandoff(
        on device: AVCaptureDevice,
        requestID: UInt64,
        attempt: Int = 0
    ) {
        let delay = attempt == 0 ? 0.02 : 0.04
        sessionQueue.asyncAfter(deadline: .now() + delay) { [weak self, weak device] in
            guard let self, let device,
                  self.torchRequests.isLatest(requestID),
                  self.videoInput?.device.uniqueID == device.uniqueID,
                  self.session.isRunning,
                  !self.session.isInterrupted,
                  self.captureMode == .video,
                  self.cameraPosition == .back,
                  self.selectedResolution == .p4k,
                  self.selectedFrameRate == .fps60,
                  !self.recordingState.requestsRecording,
                  !self.movieOutput.isRecording else { return }

            guard device.hasTorch else {
                self.synchronizeTorchState()
                return
            }
            if device.torchMode == .on {
                self.synchronizeTorchState()
                return
            }
            guard attempt <= 3 else {
                self.synchronizeTorchState()
                AppEventLog.event("Torch remained off after rear 4K60 lens handoff")
                return
            }

            self.setTorchEnabledOnCurrentDevice(true)
            guard self.torchRequests.isLatest(requestID),
                  self.videoInput?.device.uniqueID == device.uniqueID,
                  device.torchMode != .on else { return }
            self.scheduleTorchRestoreAfterLensHandoff(
                on: device,
                requestID: requestID,
                attempt: attempt + 1
            )
        }
    }

    func refreshLiveMetrics() {
        sessionQueue.async { [weak self] in
            guard let self, !self.recordingState.requestsRecording, !self.movieOutput.isRecording,
                   !self.lensTransitionCoordinator.hasActiveTransition,
                   self.videoInput != nil else { return }

            let wanted = self.liveMetricsAttachmentWanted()
            let attached = self.liveMetricsOutputIsAttached()
            let connectionNeedsDisable = self.liveMetrics.output.connection(with: .video)?.isEnabled == true &&
                !AppEventLog.extremeDiagnosticsEnabled
            let publishedStateNeedsSync = self.liveMetricsAvailable != attached
            guard wanted != attached || connectionNeedsDisable || publishedStateNeedsSync else { return }

            // If the actual output state is already correct, synchronize only the published
            // snapshot. Do not open a no-op AVCaptureSession configuration transaction.
            if wanted == attached && !connectionNeedsDisable {
                self.publish {
                    if self.liveMetricsAvailable != attached {
                        self.liveMetricsAvailable = attached
                    }
                }
                return
            }

            self.session.beginConfiguration()
            self.configureLiveMetrics()
            self.session.commitConfiguration()
        }
    }

    // Called inside the same transaction as the input/format change.
    func configureLiveMetrics() {
        let wanted = liveMetricsAttachmentWanted()
        let attached = liveMetricsOutputIsAttached()
        let previewFramesWanted = AppEventLog.extremeDiagnosticsEnabled &&
            captureMode != .photo
        let connectionNeedsDisable = liveMetrics.output.connection(with: .video)?.isEnabled == true &&
            !recordingState.requestsRecording &&
            !movieOutput.isRecording &&
            !previewFramesWanted

        if wanted == attached && !connectionNeedsDisable {
            setLiveMetricsConnectionEnabled(previewFramesWanted)
            publish {
                if self.liveMetricsAvailable != attached {
                    self.liveMetricsAvailable = attached
                }
            }
            return
        }

        if wanted && !attached && session.canAddOutput(liveMetrics.output) {
            // Live Stats is optional analysis, not the preview path. On iOS 26+ let AVFoundation
            // defer this output when supported so it never competes with preview startup.
            if liveMetrics.output.isDeferredStartSupported {
                liveMetrics.output.isDeferredStartEnabled = true
            }
            session.addOutput(liveMetrics.output)
        } else if !wanted && attached {
            stopLiveMetrics()
            session.removeOutput(liveMetrics.output)
        }

        let available = session.outputs.contains { $0 === liveMetrics.output }
        if available && !movieOutput.isRecording {
            setLiveMetricsConnectionEnabled(
                previewFramesWanted
            )
        }
        publish {
            if self.liveMetricsAvailable != available {
                self.liveMetricsAvailable = available
            }
        }
        AppEventLog.event(
            "LIVE METRICS CONFIGURED: requested=\(wanted), attached=\(available), mode=\(captureMode.rawValue)"
        )
    }

    func liveMetricsAttachmentWanted() -> Bool {
        let isRear4K60 = isProtectedRear4K60Configuration
        // A second video-data stream can push multi-camera 4K60 beyond the device's sustainable
        // capture budget and trigger a runtime-error rebuild loop. File bitrate remains available
        // without this optional output; only measured FPS/drop counters are omitted in rear 4K60.
        let requestedByUser = UserDefaults.standard.bool(forKey: "liveRecordingStats")
        let requestedByExtremeDiagnostics = AppEventLog.extremeDiagnosticsEnabled
        return (requestedByUser || requestedByExtremeDiagnostics) &&
            captureMode != .photo &&
            !isRear4K60
    }

    var isProtectedRear4K60Configuration: Bool {
        captureMode == .video &&
            cameraPosition == .back &&
            selectedResolution == .p4k &&
            selectedFrameRate == .fps60
    }

    func liveMetricsOutputIsAttached() -> Bool {
        session.outputs.contains { $0 === liveMetrics.output }
    }

    func setLiveMetricsConnectionEnabled(_ enabled: Bool) {
        guard let connection = liveMetrics.output.connection(with: .video) else { return }
        if enabled {
            // Keep the optional preview-analysis stream in the same orientation/mirroring
            // coordinate space as the camera preview. This does not touch the movie/photo
            // outputs and therefore cannot change the protected rear 4K60 path.
            if connection.isVideoMirroringSupported {
                connection.automaticallyAdjustsVideoMirroring = false
                connection.isVideoMirrored = cameraPosition == .front
            }
            applyCaptureRotation(to: connection)
        }
        if connection.isEnabled != enabled {
            connection.isEnabled = enabled
        }
    }

    func stopLiveMetrics() {
        let wasRunning = metricsTimer != nil
        metricsTimer?.cancel()
        metricsTimer = nil
        liveMetrics.setRunning(false)
        setLiveMetricsConnectionEnabled(
            (AppEventLog.extremeDiagnosticsEnabled &&
                liveMetricsOutputIsAttached() && captureMode != .photo)
        )
        if wasRunning {
            AppEventLog.event("Live metrics stopped")
        }
    }

    func startLiveMetrics() {
        stopLiveMetrics()
        previousMetricBytes = 0
        previousMetricDuration = 0
        lastExtremeRecordingHealthSecond = -1
        let userStatsEnabled = UserDefaults.standard.bool(forKey: "liveRecordingStats")
        let extremeEnabled = AppEventLog.extremeDiagnosticsEnabled
        if userStatsEnabled { publish { self.liveStats.reset() } }
        guard userStatsEnabled || extremeEnabled else {
            AppEventLog.event("Live metrics not started: setting disabled")
            return
        }

        let captureMetricsAvailable = session.outputs.contains { $0 === liveMetrics.output }
        if captureMetricsAvailable {
            setLiveMetricsConnectionEnabled(true)
            liveMetrics.setRunning(true)
        }
        let initialDuration = videoInput?.device.activeVideoMinFrameDuration.seconds ?? 0
        let initialFPS: Double? = initialDuration > 0 ? 1 / initialDuration : nil
        if userStatsEnabled { publish { self.liveStats.update(fps: initialFPS, mbps: nil, drops: nil) } }
        AppEventLog.event("Live metrics started: captureMetricsAvailable=\(captureMetricsAvailable), mode=\(captureMode.rawValue)", category: .performance,
                          traceID: activeRecordingTraceID, fields: ["userStats": String(userStatsEnabled), "extreme": String(extremeEnabled)])

        // Bitrate comes from AVCaptureMovieFileOutput and remains available even if the optional
        // video-data output could not be attached. Only FPS/drop measurement depends on it.
        let timer = DispatchSource.makeTimerSource(queue: sessionQueue)
        timer.schedule(deadline: .now() + 1, repeating: 1)
        timer.setEventHandler { [weak self] in
            guard let self, self.movieOutput.isRecording else { return }
            let duration = self.movieOutput.recordedDuration.seconds
            let bytes = self.movieOutput.recordedFileSize
            let delta = duration - self.previousMetricDuration
            let bits = bytes - self.previousMetricBytes
            let mbps: Double? = delta > 0 && bits > 0 ? Double(bits) * 8 / delta / 1_000_000 : nil
            self.previousMetricBytes = bytes
            self.previousMetricDuration = duration

            let attached = self.session.outputs.contains { $0 === self.liveMetrics.output }
            var fps: Double?
            var drops: Int?
            if attached {
                let measurement = self.liveMetrics.read()
                fps = measurement.fps
                drops = measurement.fps != nil ? measurement.drops : nil
            }

            let activeDuration = self.videoInput?.device.activeVideoMinFrameDuration.seconds ?? 0
            let activeFPS: Double? = activeDuration > 0 ? 1 / activeDuration : nil
            let monitoredStreamRepresentsCaptureRate: Bool
            if let measuredFPS = fps, let activeFPS {
                monitoredStreamRepresentsCaptureRate = measuredFPS >= activeFPS * 0.75
            } else {
                monitoredStreamRepresentsCaptureRate = false
            }
            // AVCaptureVideoDataOutput can be capped below the movie stream (notably rear 240 fps
            // and front 120 fps), and is intentionally detached for rear 4K60. The active device
            // duration is the recording frame rate; only expose drop counts when the monitoring
            // stream is actually keeping up closely enough to make that counter meaningful.
            let displayedFPS = activeFPS ?? fps
            let displayedDrops = attached && monitoredStreamRepresentsCaptureRate ? drops : nil

            let fpsText = fps.map { String(format: "%.1f", $0) } ?? "unavailable"
            let activeFPSText = activeFPS.map { String(format: "%.1f", $0) } ?? "unavailable"
            let bitrateText = mbps.map { String(format: "%.2f Mbps", $0) } ?? "unavailable"
            let dropsText = drops.map { String($0) } ?? "unavailable"
            if userStatsEnabled {
                AppEventLog.event(
                    "LIVE METRICS: duration=\(String(format: "%.1f", duration))s, bytes=\(bytes), bitrate=\(bitrateText), " +
                    "monitoredFPS=\(fpsText), activeFPS=\(activeFPSText), monitoredDrops=\(dropsText), " +
                    "dropsAvailable=\(displayedDrops != nil), captureMetricsAttached=\(attached)",
                    category: .performance, traceID: self.activeRecordingTraceID
                )
                self.publish {
                    self.liveStats.update(fps: displayedFPS, mbps: mbps, drops: displayedDrops)
                }
            }
            if AppEventLog.extremeDiagnosticsEnabled {
                let second = Int(duration.rounded(.down))
                if second == 0 || second >= self.lastExtremeRecordingHealthSecond + 5 {
                    self.lastExtremeRecordingHealthSecond = second
                    let device = self.videoInput?.device
                    AppEventLog.deepEvent("RECORDING HEALTH", category: .recording, traceID: self.activeRecordingTraceID, fields: [
                        "elapsedSeconds": String(format: "%.2f", duration),
                        "fileBytes": String(bytes),
                        "bitrateMbps": mbps.map { String(format: "%.2f", $0) } ?? "unavailable",
                        "activeFPS": activeFPSText,
                        "monitoredFPS": fpsText,
                        "drops": dropsText,
                        "metricsOutputAttached": String(attached),
                        "device": device?.localizedName ?? "none",
                        "deviceZoom": device.map { String(format: "%.3f", $0.videoZoomFactor) } ?? "none",
                        "thermal": String(describing: ProcessInfo.processInfo.thermalState),
                        "lowPowerMode": String(ProcessInfo.processInfo.isLowPowerModeEnabled)
                    ])
                }
            }
        }
        metricsTimer = timer
        timer.resume()
    }

    func applyLongevityMode(_ enabled: Bool) {
        guard !isRecording, !isRecordingStarting, !isFinalizingRecording else {
            AppEventLog.event("Longevity Mode ignored: recording is active")
            return
        }
        AppEventLog.event("Longevity Mode requested: \(enabled)")
        let defaults = UserDefaults.standard
        _ = videoConfigurationRequests.next()
        _ = qualityRequests.next()
        _ = captureConfigurationGeneration.next()
        if enabled {
            defaults.set(selectedResolution.rawValue, forKey: "longevityPreviousResolution")
            defaults.set(selectedFrameRate.rawValue, forKey: "longevityPreviousFPS")
            defaults.set(selectedVideoCodec, forKey: "longevityPreviousCodec")
            defaults.set(videoCompression.rawValue, forKey: "longevityPreviousCompression")
        }
        suppressAutomaticReconfiguration = true
        if enabled {
            selectedResolution = .p720
            selectedFrameRate = .fps30
            selectedVideoCodec = "HEVC"
            videoCompressionMode = .auto
            videoCompression = .dataSaver
        } else {
            selectedResolution = VideoResolution(rawValue: defaults.string(forKey: "longevityPreviousResolution") ?? "") ?? .p1080
            selectedFrameRate = VideoFrameRate(rawValue: defaults.integer(forKey: "longevityPreviousFPS")) ?? .fps30
            selectedVideoCodec = defaults.string(forKey: "longevityPreviousCodec") ?? "HEVC"
            videoCompression = VideoCompression(rawValue: defaults.string(forKey: "longevityPreviousCompression") ?? "") ?? .high
        }
        suppressAutomaticReconfiguration = false
        defaults.set(enabled, forKey: "longevityMode")
        sessionQueue.async { [weak self] in
            guard let self else { return }
            self.invalidatePendingVideoConfiguration()
            self.lensTransitionCoordinator.cancel()
            let success = self.applyActiveModeFormat(preferVirtualCamera: !self.requiresPhysicalWhiteBalanceInput)
            AppEventLog.event("Longevity Mode \(success ? "applied" : "failed"): enabled=\(enabled)")
        }
    }
}
