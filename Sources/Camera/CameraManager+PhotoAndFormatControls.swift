import AVFoundation
import Combine
import Foundation
import Photos
import UIKit

// MARK: - CameraManager: Photo controls, AF/AE, white balance, video/slow-motion quality selection.

extension CameraManager {
    func selectPhotoMegapixels(_ megapixels: Int) {
        guard supportedPhotoMegapixels.contains(megapixels), selectedPhotoMegapixels != megapixels else { return }
        AppEventLog.event("Photo megapixels requested: \(selectedPhotoMegapixels) MP -> \(megapixels) MP")
        preferredPhotoMegapixels = megapixels
        UserDefaults.standard.set(megapixels, forKey: Self.photoMegapixelsKey)
        selectedPhotoMegapixels = megapixels
        currentPhotoResolutionLabel = "\(megapixels) MP"
        currentPhotoPixelCount = Int64(megapixels) * 1_000_000
        refreshAvailableStorage()
        AppEventLog.event("Photo megapixels applied: \(megapixels) MP")
    }

    func updatePhotoAspectSelection(_ aspect: String) {
        AppEventLog.event("Photo aspect requested: \(aspect)")
        sessionQueue.async { [weak self] in
            guard let self,
                  self.nativePhotoDimensions.width > 0,
                  self.nativePhotoDimensions.height > 0 else { return }
            self.updatePhotoMegapixelAvailability(for: self.nativePhotoDimensions, aspect: aspect)
            AppEventLog.event("Photo aspect applied: \(aspect), supported megapixels=\(self.supportedPhotoMegapixels.map { String($0) }.joined(separator: ","))")
        }
    }

    @discardableResult
    func captureBurst() -> Bool {
        guard captureMode == .photo, !isCapturingPhoto, !isRecordingStarting, !isFinalizingRecording else {
            AppEventLog.guardRejected("captureBurst", reason: "camera busy or not in Photo mode", fields: [
                "mode": captureMode.rawValue,
                "isCapturingPhoto": String(isCapturingPhoto),
                "recordingStarting": String(isRecordingStarting),
                "finalizing": String(isFinalizingRecording)
            ])
            return false
        }
        let savedCount = UserDefaults.standard.integer(forKey: "burstCount")
        let count = Self.photoBurstCountOptions.contains(savedCount) ? savedCount : Self.defaultPhotoBurstCount
        let burstTrace = AppEventLog.extremeDiagnosticsEnabled ? AppEventLog.makeTraceID("BURST") : "BURST"
        AppEventLog.event("========== BURST CAPTURE START =========", category: .burst, traceID: burstTrace,
                          fields: ["requestedCount": String(count)])
        isCapturingPhoto = true
        sessionQueue.async { [weak self] in
            guard let self else { return }
            self.activeBurstTraceID = burstTrace
            self.burstRequestedCount = count
            self.burstRemaining = count
            self.burstStopRequested = false
            self.burstAspect = UserDefaults.standard.string(forKey: "photoAspect") ?? "4:3"
            self.burstMegapixels = self.selectedPhotoMegapixels
            AppEventLog.deepEvent("BURST SETTINGS SNAPSHOT", category: .burst, traceID: burstTrace, fields: [
                "aspect": self.burstAspect,
                "megapixels": String(self.burstMegapixels),
                "camera": self.videoInput?.device.localizedName ?? "none"
            ])
            self.refreshAvailableStorage()
            self.beginPhotoCapture()
        }
        return true
    }

    func stopBurst() {
        sessionQueue.async { [weak self] in
            guard let self, self.burstRemaining > 0 else { return }
            self.burstStopRequested = true
            AppEventLog.event("Burst capture stop requested: remaining=\(self.burstRemaining)", category: .burst,
                              traceID: self.activeBurstTraceID)
        }
    }

    @discardableResult
    func capturePhoto() -> Bool {
        guard captureMode == .photo, !isRecording, !isRecordingStarting, !isFinalizingRecording, !isCapturingPhoto else {
            AppEventLog.guardRejected("capturePhoto", reason: "camera busy or not in Photo mode", fields: [
                "mode": captureMode.rawValue,
                "recording": String(isRecording),
                "recordingStarting": String(isRecordingStarting),
                "finalizing": String(isFinalizingRecording),
                "capturingPhoto": String(isCapturingPhoto)
            ])
            return false
        }
        isCapturingPhoto = true
        sessionQueue.async { [weak self] in
            guard let self else { return }
            self.burstRemaining = 0
            self.burstRequestedCount = 0
            self.activeBurstTraceID = nil
            self.burstStopRequested = false
            self.beginPhotoCapture()
        }
        return true
    }

    func focusAndExpose(at point: CGPoint) {
        let requestID = focusExposureRequests.next(reason: "tap focus/exposure")
        sessionQueue.async { [weak self] in
            guard let self, self.focusExposureRequests.isLatest(requestID) else { return }
            self.configureFocusAndExposure(at: point, lockAfterFocusing: false, requestID: requestID)
        }
    }

    func lockFocusAndExposure(at point: CGPoint) {
        let requestID = focusExposureRequests.next(reason: "lock focus/exposure")
        sessionQueue.async { [weak self] in
            guard let self, self.focusExposureRequests.isLatest(requestID) else { return }
            self.configureFocusAndExposure(at: point, lockAfterFocusing: true, requestID: requestID)
        }
    }

    func setExposureBias(_ bias: Float) {
        let requestID = exposureRequests.next()
        sessionQueue.async { [weak self] in
            guard let self, self.exposureRequests.isLatest(requestID) else { return }
            self.applyExposureBias(bias)
        }
    }

    func selectWhiteBalancePreset(_ preset: WhiteBalancePreset) {
        let requestID = whiteBalanceRequests.next(reason: "white balance -> \(preset.rawValue)")
        let traceID = "WB-\(requestID)"
        let ticket = AppEventLog.queueScheduled("white balance apply", category: .whiteBalance, traceID: traceID)
        AppEventLog.event("White balance requested: \(preset.rawValue)", category: .whiteBalance, traceID: traceID, fields: [
            "currentPreset": requestedWhiteBalancePreset.rawValue,
            "camera": cameraPosition.rawValue,
            "device": videoInput?.device.localizedName ?? "none"
        ])
        sessionQueue.async { [weak self] in
            AppEventLog.queueStarted(ticket)
            guard let self else { return }
            guard self.whiteBalanceRequests.isLatest(requestID) else {
                AppEventLog.staleRequest(token: "whiteBalanceRequests", requestID: requestID, latestID: self.whiteBalanceRequests.current(),
                                         operation: "white balance selection", traceID: traceID)
                return
            }
            guard !self.movieOutput.isRecording, !self.recordingState.requestsRecording,
                  !self.lensTransitionCoordinator.hasActiveTransition else {
                AppEventLog.guardRejected("white balance selection", reason: "camera busy", traceID: traceID, fields: [
                    "movieRecording": String(self.movieOutput.isRecording),
                    "recordingRequested": String(self.recordingState.requestsRecording),
                    "lensTransition": String(self.lensTransitionCoordinator.hasActiveTransition)
                ])
                return
            }

            let previousPreset = self.requestedWhiteBalancePreset
            self.requestedWhiteBalancePreset = preset
            UserDefaults.standard.set(preset.rawValue, forKey: LowPolyCamPreferences.Key.whiteBalancePreset)

            guard self.session.isRunning, !self.session.isInterrupted else {
                self.deferWhiteBalanceRequest(
                    id: requestID,
                    preset: preset,
                    previousPreset: previousPreset
                )
                return
            }

            self.applyWhiteBalanceRequest(
                preset,
                previousPreset: previousPreset,
                requestID: requestID
            )
        }
    }

    func deferWhiteBalanceRequest(
        id: UInt64,
        preset: WhiteBalancePreset,
        previousPreset: WhiteBalancePreset
    ) {
        guard whiteBalanceRequests.isLatest(id) else { return }
        deferredWhiteBalanceRequest = DeferredWhiteBalanceRequest(
            id: id,
            preset: preset,
            previousPreset: previousPreset
        )
        let state = session.isInterrupted ? "interrupted" : "not running"
        AppEventLog.event("White balance deferred: camera session is \(state)", category: .whiteBalance, traceID: "WB-\(id)", fields: [
            "preset": preset.rawValue, "previousPreset": previousPreset.rawValue
        ])
    }

    func applyDeferredWhiteBalanceIfPossible() {
        guard let deferred = deferredWhiteBalanceRequest else { return }
        guard whiteBalanceRequests.isLatest(deferred.id) else {
            deferredWhiteBalanceRequest = nil
            return
        }
        guard session.isRunning, !session.isInterrupted else { return }
        deferredWhiteBalanceRequest = nil
        applyWhiteBalanceRequest(
            deferred.preset,
            previousPreset: deferred.previousPreset,
            requestID: deferred.id
        )
    }

    func applyWhiteBalanceRequest(
        _ preset: WhiteBalancePreset,
        previousPreset: WhiteBalancePreset,
        requestID: UInt64
    ) {
        let traceID = "WB-\(requestID)"
        let wbStartedAt = ProcessInfo.processInfo.systemUptime
        guard whiteBalanceRequests.isLatest(requestID),
              !movieOutput.isRecording, !recordingState.requestsRecording,
              !lensTransitionCoordinator.hasActiveTransition else {
            AppEventLog.guardRejected("applyWhiteBalanceRequest", reason: "stale or camera busy", traceID: traceID, fields: [
                "latestID": String(whiteBalanceRequests.current()), "requestID": String(requestID),
                "movieRecording": String(movieOutput.isRecording), "recordingRequested": String(recordingState.requestsRecording),
                "lensTransition": String(lensTransitionCoordinator.hasActiveTransition)
            ])
            return
        }
        guard session.isRunning, !session.isInterrupted else {
            deferWhiteBalanceRequest(
                id: requestID,
                preset: preset,
                previousPreset: previousPreset
            )
            return
        }

        deferredWhiteBalanceRequest = nil
        requestedWhiteBalancePreset = preset
        let currentDevice = videoInput?.device
        // Slo-Mo always uses a physical HFR camera. Rear 4K60 may use Apple's
        // Dual-Wide/Triple virtual camera while WB is Auto, but manual WB must move to a
        // physical constituent so locked temperature/tint is applied to the real capture input.
        let modeRequiresPhysicalInput = cameraPosition == .back && captureMode == .sloMo
        let needsInputSwap = cameraPosition == .back && !modeRequiresPhysicalInput && (
            (preset != .auto && currentDevice?.isVirtualDevice == true) ||
            (preset == .auto && currentDevice?.isVirtualDevice == false)
        )
        AppEventLog.deepEvent("WB APPLY DECISION", category: .whiteBalance, traceID: traceID, fields: [
            "preset": preset.rawValue, "previousPreset": previousPreset.rawValue,
            "device": currentDevice?.localizedName ?? "none", "virtualDevice": String(currentDevice?.isVirtualDevice ?? false),
            "needsInputSwap": String(needsInputSwap), "mode": captureMode.rawValue
        ])

        // Manual-to-manual (or any front-camera WB change) only needs a device WB update.
        // Do not rebuild/reapply the whole capture format for a color-temperature change.
        if !needsInputSwap {
            if applyWhiteBalancePresetToCurrentCamera(preset) {
                publish {
                    self.whiteBalancePreset = preset
                    self.isPreviewTransitioning = false
                }
                let device = self.videoInput?.device
                let gains = device?.deviceWhiteBalanceGains
                AppEventLog.event("White balance applied: \(preset.rawValue)", category: .whiteBalance, traceID: traceID, fields: [
                    "device": device?.localizedName ?? "none",
                    "mode": device.map { String(describing: $0.whiteBalanceMode) } ?? "none",
                    "redGain": gains.map { String(format: "%.3f", $0.redGain) } ?? "none",
                    "greenGain": gains.map { String(format: "%.3f", $0.greenGain) } ?? "none",
                    "blueGain": gains.map { String(format: "%.3f", $0.blueGain) } ?? "none",
                    "totalMs": String(format: "%.2f", (ProcessInfo.processInfo.systemUptime - wbStartedAt) * 1000)
                ])
            } else {
                requestedWhiteBalancePreset = previousPreset
                _ = applyWhiteBalancePresetToCurrentCamera(previousPreset)
                publish {
                    self.whiteBalancePreset = previousPreset
                    self.isPreviewTransitioning = false
                }
                showError(preset == .auto
                    ? "Couldn’t enable Auto white balance."
                    : "Manual white balance isn’t available on this lens.")
            }
            return
        }

        // Rear Auto <-> manual requires a virtual/physical input handoff. Freeze the
        // current preview first, then perform exactly one atomic input+format change.
        publish { self.isPreviewTransitioning = true }
        sessionQueue.asyncAfter(deadline: .now() + 0.045) { [weak self] in
            guard let self, self.whiteBalanceRequests.isLatest(requestID) else { return }
            guard self.session.isRunning, !self.session.isInterrupted else {
                self.deferWhiteBalanceRequest(
                    id: requestID,
                    preset: preset,
                    previousPreset: previousPreset
                )
                return
            }

            let configured = self.applyActiveModeFormat(
                preferVirtualCamera: preset == .auto
            )
            guard self.whiteBalanceRequests.isLatest(requestID) else { return }

            if !configured || self.requestedWhiteBalancePreset != preset {
                self.requestedWhiteBalancePreset = previousPreset
                _ = self.applyActiveModeFormat(preferVirtualCamera: previousPreset == .auto)
                self.publish { self.whiteBalancePreset = previousPreset }
                self.showError(preset == .auto
                    ? "Couldn’t enable Auto white balance."
                    : "Manual white balance isn’t available on this lens.")
            } else {
                let device = self.videoInput?.device
                AppEventLog.event("White balance applied after camera handoff: \(preset.rawValue)", category: .whiteBalance, traceID: traceID, fields: [
                    "device": device?.localizedName ?? "none",
                    "virtualDevice": String(device?.isVirtualDevice ?? false),
                    "mode": device.map { String(describing: $0.whiteBalanceMode) } ?? "none",
                    "totalMs": String(format: "%.2f", (ProcessInfo.processInfo.systemUptime - wbStartedAt) * 1000)
                ])
            }

            DispatchQueue.main.asyncAfter(deadline: .now() + 0.12) { [weak self] in
                guard let self, self.whiteBalanceRequests.isLatest(requestID) else { return }
                self.isPreviewTransitioning = false
            }
        }
    }



    /// Returns whether a specific resolution/FPS pair is available on the currently selected
    /// front/rear camera. The Settings UI uses this instead of combining two independent support
    /// lists, which could otherwise display a pair that no single AVCaptureDevice.Format supports.
    func supportedVideoFormatPairs() -> [(VideoResolution, VideoFrameRate)] {
        let devices = capabilityDevices(for: cameraPosition.avPosition)
        let resolutions: [VideoResolution] = [.p720, .p1080, .p4k]
        return resolutions.flatMap { resolution in
            VideoFrameRate.allCases.compactMap { frameRate in
                let needsHEVCPromotion = isKnownUnsupportedH264VideoSelection(
                    codec: selectedVideoCodec,
                    resolution: resolution,
                    frameRate: frameRate
                )
                let effectiveCodec = needsHEVCPromotion ? "HEVC" : selectedVideoCodec
                let selector = CameraFormatSelector(
                    selectedVideoCodec: effectiveCodec,
                    selectedResolution: resolution,
                    selectedFrameRate: frameRate
                )
                let supported = devices.contains { device in
                    selector.preferredRecordingFormat(
                        for: device,
                        resolution: resolution,
                        rate: frameRate
                    ) != nil
                }
                return supported ? (resolution, frameRate) : nil
            }
        }
    }

    func isVideoFormatSupported(resolution: VideoResolution, frameRate: VideoFrameRate) -> Bool {
        supportedVideoFormatPairs().contains {
            $0.0 == resolution && $0.1 == frameRate
        }
    }

    /// Applies a Video resolution and FPS as one user request. This prevents the new Settings list
    /// from producing an unnecessary intermediate camera configuration (for example 4K30 before
    /// the requested 4K60). When Video is not the active capture mode, the choice is saved for the
    /// next time Video is opened without reconfiguring the active Photo/Slo-Mo pipeline.
    func selectVideoFormat(resolution: VideoResolution, frameRate: VideoFrameRate) {
        guard !isRecording,
              !isRecordingStarting,
              !isFinalizingRecording,
              !isCapturingPhoto,
              !isLensTransitioning else { return }
        guard isVideoFormatSupported(resolution: resolution, frameRate: frameRate) else { return }

        var promotedCodec = false
        if isKnownUnsupportedH264VideoSelection(
            codec: selectedVideoCodec,
            resolution: resolution,
            frameRate: frameRate
        ) {
            let wasSuppressing = suppressAutomaticReconfiguration
            suppressAutomaticReconfiguration = true
            selectedVideoCodec = "HEVC"
            suppressAutomaticReconfiguration = wasSuppressing
            codecAvailabilityMessage = nil
            promotedCodec = true
            AppEventLog.event("Video codec promoted automatically: H264 -> HEVC for Settings format selection \(resolution.rawValue) \(frameRate.rawValue) fps")
        }

        guard selectedResolution != resolution || selectedFrameRate != frameRate || promotedCodec else { return }
        AppEventLog.event(
            "Video format requested from Settings: \(selectedResolution.rawValue)/\(selectedFrameRate.rawValue) fps -> \(resolution.rawValue)/\(frameRate.rawValue) fps"
        )
        codecAvailabilityMessage = nil

        let wasSuppressingPersistence = suppressPreferencePersistence
        suppressPreferencePersistence = true
        selectedResolution = resolution
        selectedFrameRate = frameRate
        suppressPreferencePersistence = wasSuppressingPersistence
        persistCameraPreferences()

        guard captureMode == .video else {
            AppEventLog.event("Video format saved for later; active mode=\(captureMode.rawValue)")
            return
        }

        let transitionID = qualityPreviewTransitions.next()
        isPreviewTransitioning = true
        scheduleVideoConfiguration(
            formatAffecting: true,
            qualityRequestID: qualityRequests.next(),
            compressionRequestID: compressionRequests.current(),
            transitionID: transitionID
        )
    }

    /// Pair-aware Slo-Mo capability check used by the Settings UI. Slo-Mo always uses HEVC in
    /// LowPolyCam, so this deliberately ignores the saved normal-Video codec preference.
    func supportedSlowMotionFormatPairs() -> [(VideoResolution, SlowMotionFrameRate)] {
        let devices = capabilityDevices(for: cameraPosition.avPosition)
        let selector = CameraFormatSelector(
            selectedVideoCodec: "HEVC",
            selectedResolution: selectedResolution,
            selectedFrameRate: selectedFrameRate
        )
        let resolutions: [VideoResolution] = [.p720, .p1080, .p4k]
        return resolutions.flatMap { resolution in
            SlowMotionFrameRate.allCases.compactMap { frameRate in
                let selection = selector.slowMotionFormatSelection(
                    for: devices,
                    requestedResolution: resolution,
                    requestedFrameRate: frameRate
                )
                let supported = selection.resolution == resolution &&
                    selection.frameRate == frameRate &&
                    !selection.supportedDevices.isEmpty
                return supported ? (resolution, frameRate) : nil
            }
        }
    }

    func isSlowMotionFormatSupported(
        resolution: VideoResolution,
        frameRate: SlowMotionFrameRate
    ) -> Bool {
        supportedSlowMotionFormatPairs().contains {
            $0.0 == resolution && $0.1 == frameRate
        }
    }

    /// Applies a Slo-Mo resolution/FPS pair as a single request. Like the Video equivalent, this
    /// only touches active capture hardware when Slo-Mo is currently open; otherwise it persists
    /// the preference for the next Slo-Mo session.
    func selectSlowMotionFormat(
        resolution: VideoResolution,
        frameRate: SlowMotionFrameRate
    ) {
        guard !isRecording,
              !isRecordingStarting,
              !isFinalizingRecording,
              !isCapturingPhoto,
              !isLensTransitioning else { return }
        guard isSlowMotionFormatSupported(resolution: resolution, frameRate: frameRate) else { return }
        guard selectedSlowMotionResolution != resolution || selectedSlowMotionFrameRate != frameRate else { return }

        AppEventLog.event(
            "Slo-Mo format requested from Settings: \(selectedSlowMotionResolution.rawValue)/\(selectedSlowMotionFrameRate.rawValue) fps -> \(resolution.rawValue)/\(frameRate.rawValue) fps"
        )

        let wasSuppressingPersistence = suppressPreferencePersistence
        suppressPreferencePersistence = true
        selectedSlowMotionResolution = resolution
        selectedSlowMotionFrameRate = frameRate
        suppressPreferencePersistence = wasSuppressingPersistence
        persistCameraPreferences()

        guard captureMode == .sloMo else {
            AppEventLog.event("Slo-Mo format saved for later; active mode=\(captureMode.rawValue)")
            return
        }

        let transitionID = qualityPreviewTransitions.next()
        isPreviewTransitioning = true
        let request = SlowMotionQualityRequest(
            id: qualityRequests.next(),
            resolution: resolution,
            frameRate: frameRate,
            position: cameraPosition,
            codec: selectedVideoCodec
        )
        sessionQueue.asyncAfter(deadline: .now() + 0.07) { [weak self] in
            guard let self else { return }
            guard self.qualityRequests.isLatest(request.id),
                  self.captureMode == .sloMo,
                  self.cameraPosition == request.position,
                  self.selectedVideoCodec == request.codec,
                  !self.recordingState.requestsRecording,
                  !self.recordingState.isFinalizing,
                  !self.movieOutput.isRecording else {
                self.finishQualityPreviewTransition(transitionID)
                return
            }
            self.lensTransitionCoordinator.cancel()
            _ = self.applySlowMotionFormat(
                requestedResolution: request.resolution,
                requestedFrameRate: request.frameRate,
                qualityRequestID: request.id,
                requestedPosition: request.position
            )
            self.finishQualityPreviewTransition(transitionID)
        }
    }



    func selectResolution(_ resolution: VideoResolution) {
        guard captureMode == .video, !isRecording, !isRecordingStarting, !isFinalizingRecording, !isLensTransitioning else { return }
        guard isVideoResolutionSupported(resolution) else { return }
        let promotedCodec = autoPromoteH264ForUnsupportedVideoSelection(
            position: cameraPosition,
            resolution: resolution,
            frameRate: selectedFrameRate
        )
        guard selectedResolution != resolution || promotedCodec else { return }
        AppEventLog.event("Video resolution requested: \(selectedResolution.rawValue) to \(resolution.rawValue)")
        codecAvailabilityMessage = nil
        selectedResolution = resolution
        let transitionID = qualityPreviewTransitions.next()
        isPreviewTransitioning = true
        scheduleVideoConfiguration(
            formatAffecting: true,
            qualityRequestID: qualityRequests.next(),
            compressionRequestID: compressionRequests.current(),
            transitionID: transitionID
        )
    }

    func selectFrameRate(_ frameRate: VideoFrameRate) {
        guard captureMode == .video, !isRecording, !isRecordingStarting, !isFinalizingRecording, !isLensTransitioning else { return }
        guard isVideoFrameRateSupported(frameRate) else { return }
        guard selectedFrameRate != frameRate else { return }
        AppEventLog.event("Video frame rate requested: \(selectedFrameRate.rawValue) to \(frameRate.rawValue)")
        codecAvailabilityMessage = nil
        selectedFrameRate = frameRate
        let transitionID = qualityPreviewTransitions.next()
        isPreviewTransitioning = true
        scheduleVideoConfiguration(
            formatAffecting: true,
            qualityRequestID: qualityRequests.next(),
            compressionRequestID: compressionRequests.current(),
            transitionID: transitionID
        )
    }

    func selectSlowMotionResolution(_ resolution: VideoResolution) {
        guard captureMode == .sloMo, !isRecording, !isRecordingStarting, !isFinalizingRecording, !isLensTransitioning else { return }
        guard isSlowMotionResolutionSupported(resolution) else { return }
        guard selectedSlowMotionResolution != resolution else { return }
        AppEventLog.event("Slo-Mo resolution requested: \(selectedSlowMotionResolution.rawValue) to \(resolution.rawValue)")
        selectedSlowMotionResolution = resolution
        let transitionID = qualityPreviewTransitions.next()
        isPreviewTransitioning = true
        let request = SlowMotionQualityRequest(
            id: qualityRequests.next(),
            resolution: selectedSlowMotionResolution,
            frameRate: selectedSlowMotionFrameRate,
            position: cameraPosition,
            codec: selectedVideoCodec
        )
        sessionQueue.asyncAfter(deadline: .now() + 0.07) { [weak self] in
            guard let self else { return }
            guard self.qualityRequests.isLatest(request.id),
                  self.captureMode == .sloMo,
                  self.cameraPosition == request.position,
                  self.selectedVideoCodec == request.codec,
                  !self.recordingState.requestsRecording,
                  !self.recordingState.isFinalizing,
                  !self.movieOutput.isRecording else {
                self.finishQualityPreviewTransition(transitionID)
                return
            }
            self.lensTransitionCoordinator.cancel()
            _ = self.applySlowMotionFormat(
                requestedResolution: request.resolution,
                requestedFrameRate: request.frameRate,
                qualityRequestID: request.id,
                requestedPosition: request.position
            )
            self.finishQualityPreviewTransition(transitionID)
        }
    }

    func selectSlowMotionFrameRate(_ frameRate: SlowMotionFrameRate) {
        guard captureMode == .sloMo, !isRecording, !isRecordingStarting, !isFinalizingRecording, !isLensTransitioning else { return }
        guard isSlowMotionFrameRateSupported(frameRate) else { return }
        guard selectedSlowMotionFrameRate != frameRate else { return }
        AppEventLog.event("Slo-Mo frame rate requested: \(selectedSlowMotionFrameRate.rawValue) to \(frameRate.rawValue)")
        selectedSlowMotionFrameRate = frameRate
        let transitionID = qualityPreviewTransitions.next()
        isPreviewTransitioning = true
        let request = SlowMotionQualityRequest(
            id: qualityRequests.next(),
            resolution: selectedSlowMotionResolution,
            frameRate: selectedSlowMotionFrameRate,
            position: cameraPosition,
            codec: selectedVideoCodec
        )
        sessionQueue.asyncAfter(deadline: .now() + 0.07) { [weak self] in
            guard let self else { return }
            guard self.qualityRequests.isLatest(request.id),
                  self.captureMode == .sloMo,
                  self.cameraPosition == request.position,
                  self.selectedVideoCodec == request.codec,
                  !self.recordingState.requestsRecording,
                  !self.recordingState.isFinalizing,
                  !self.movieOutput.isRecording else {
                self.finishQualityPreviewTransition(transitionID)
                return
            }
            self.lensTransitionCoordinator.cancel()
            _ = self.applySlowMotionFormat(
                requestedResolution: request.resolution,
                requestedFrameRate: request.frameRate,
                qualityRequestID: request.id,
                requestedPosition: request.position
            )
            self.finishQualityPreviewTransition(transitionID)
        }
    }
}
