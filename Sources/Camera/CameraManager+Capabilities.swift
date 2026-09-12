import AVFoundation
import Combine
import Foundation
import Photos
import UIKit

// MARK: - CameraManager: Capability queries, cached support checks, pending configuration requests, and camera preferences.

extension CameraManager {
    func isVideoResolutionSupported(_ resolution: VideoResolution) -> Bool {
        supportedResolutions.contains(resolution)
    }

    func isVideoFrameRateSupported(_ frameRate: VideoFrameRate) -> Bool {
        if isKnownUnsupportedH264VideoSelection(
            codec: selectedVideoCodec,
            resolution: selectedResolution,
            frameRate: frameRate
        ) {
            return false
        }
        guard supportedFrameRates.contains(frameRate) else { return false }
        if codecAvailabilityMessage != nil,
           selectedVideoCodec == "H264",
           selectedFrameRate == frameRate {
            return false
        }
        return true
    }

    func isVideoCodecSupported(_ codec: String) -> Bool {
        guard codec == "HEVC" || codec == "H264" else { return false }
        if isKnownUnsupportedH264VideoSelection(
            codec: codec,
            resolution: selectedResolution,
            frameRate: selectedFrameRate
        ) {
            return false
        }
        if codec == selectedVideoCodec {
            return codecAvailabilityMessage == nil &&
                (!isVideoAvailabilityKnown ||
                (isVideoResolutionSupported(selectedResolution) &&
                        isVideoFrameRateSupported(selectedFrameRate)))
        }

        let devices = capabilityDevices(for: cameraPosition.avPosition)
        let cacheKey: CodecSupportKey
        let cachedSnapshot: CodecSupportSnapshot?
        codecSupportCacheLock.lock()
        let generation = codecSupportCacheGeneration
        cacheKey = CodecSupportKey(
            isBackCamera: cameraPosition == .back,
            resolution: selectedResolution.rawValue,
            frameRate: selectedFrameRate.rawValue,
            deviceIDs: devices.map(\.uniqueID),
            generation: generation
        )
        cachedSnapshot = codecSupportSnapshot?.key == cacheKey ? codecSupportSnapshot : nil
        codecSupportCacheLock.unlock()

        if let cachedSnapshot {
            return cachedSnapshot.supports(codec)
        }

        let hevcSelector = CameraFormatSelector(
            selectedVideoCodec: "HEVC",
            selectedResolution: selectedResolution,
            selectedFrameRate: selectedFrameRate
        )
        let h264Selector = CameraFormatSelector(
            selectedVideoCodec: "H264",
            selectedResolution: selectedResolution,
            selectedFrameRate: selectedFrameRate
        )
        var hevcSupported = false
        var h264Supported = false
        for device in devices {
            for format in device.formats {
                if !hevcSupported,
                   hevcSelector.format(format, supports: selectedResolution, at: selectedFrameRate),
                   hevcSelector.formatSupportsSelectedCodec(format) {
                    hevcSupported = true
                }
                if !h264Supported,
                   h264Selector.format(format, supports: selectedResolution, at: selectedFrameRate),
                   h264Selector.formatSupportsSelectedCodec(format) {
                    h264Supported = true
                }
                if hevcSupported && h264Supported {
                    break
                }
            }
            if hevcSupported && h264Supported { break }
        }

        let snapshot = CodecSupportSnapshot(
            key: cacheKey,
            hevcSupported: hevcSupported,
            h264Supported: h264Supported
        )
        codecSupportCacheLock.lock()
        if codecSupportCacheGeneration == generation {
            codecSupportSnapshot = snapshot
        }
        codecSupportCacheLock.unlock()
        return snapshot.supports(codec)
    }

    func invalidateCodecSupportCache() {
        codecSupportCacheLock.lock()
        codecSupportCacheGeneration &+= 1
        codecSupportSnapshot = nil
        codecSupportCacheLock.unlock()
    }

    /// Refreshes the Settings-facing capability answer away from SwiftUI body evaluation. The
    /// existing synchronous helpers remain available for guarded user actions and hardware
    /// configuration, but the UI reads this published snapshot so format scans do not repeat on
    /// every render.
    func scheduleCapabilitySnapshotRefresh(reason: String) {
        let requestID = capabilityRequests.next(reason: reason)
        publish {
            self.isCapabilitySnapshotLoading = true
        }
        sessionQueue.async { [weak self] in
            guard let self, self.capabilityRequests.isLatest(requestID) else { return }
            let snapshot = self.makeCapabilitySnapshot()
            guard self.capabilityRequests.isLatest(requestID) else { return }
            self.publish {
                guard self.capabilityRequests.isLatest(requestID) else { return }
                self.capabilitySnapshot = snapshot
                self.isCapabilitySnapshotLoading = false
            }
        }
    }

    func makeCapabilitySnapshot() -> CameraCapabilitySnapshot {
        let devices = capabilityDevices(for: cameraPosition.avPosition)
        let resolutions: [VideoResolution] = [.p720, .p1080, .p4k]
        let position = cameraPosition.rawValue

        let videoPairs = resolutions.flatMap { resolution in
            VideoFrameRate.allCases.compactMap { frameRate -> CameraVideoFormatPair? in
                let effectiveCodec = isKnownUnsupportedH264VideoSelection(
                    codec: selectedVideoCodec,
                    resolution: resolution,
                    frameRate: frameRate
                ) ? "HEVC" : selectedVideoCodec
                let selector = CameraFormatSelector(
                    selectedVideoCodec: effectiveCodec,
                    selectedResolution: resolution,
                    selectedFrameRate: frameRate
                )
                let supported = devices.contains { device in
                    selector.preferredRecordingFormat(for: device, resolution: resolution, rate: frameRate) != nil
                }
                return supported ? CameraVideoFormatPair(resolution: resolution, frameRate: frameRate) : nil
            }
        }

        let slowMotionSelector = CameraFormatSelector(
            selectedVideoCodec: "HEVC",
            selectedResolution: selectedResolution,
            selectedFrameRate: selectedFrameRate
        )
        let slowMotionPairs = resolutions.flatMap { resolution in
            SlowMotionFrameRate.allCases.compactMap { frameRate -> CameraSlowMotionFormatPair? in
                let supported = devices.contains { device in
                    device.formats.contains {
                        slowMotionSelector.supportsSlowMotion($0, resolution: resolution, frameRate: frameRate)
                    }
                }
                return supported
                    ? CameraSlowMotionFormatPair(resolution: resolution, frameRate: frameRate)
                    : nil
            }
        }

        let availableCodecs = ["HEVC", "H264"].filter { codec in
            guard !isKnownUnsupportedH264VideoSelection(
                codec: codec,
                resolution: selectedResolution,
                frameRate: selectedFrameRate
            ) else { return false }
            let selector = CameraFormatSelector(
                selectedVideoCodec: codec,
                selectedResolution: selectedResolution,
                selectedFrameRate: selectedFrameRate
            )
            return devices.contains { device in
                selector.preferredRecordingFormat(
                    for: device,
                    resolution: selectedResolution,
                    rate: selectedFrameRate
                ) != nil
            }
        }

        return CameraCapabilitySnapshot(
            position: position,
            deviceIDs: devices.map(\.uniqueID),
            videoPairs: videoPairs,
            slowMotionPairs: slowMotionPairs,
            availableVideoCodecs: availableCodecs,
            photoMegapixelOptions: supportedPhotoMegapixels,
            isReady: !devices.isEmpty
        )
    }

    static func normalizedVideoCodec(
        _ codec: String,
        resolution: VideoResolution,
        frameRate: VideoFrameRate
    ) -> String {
        // AVCaptureMovieFileOutput on the supported iPhone 11 paths exposes HEVC, not AVC, for
        // 4K60. Treat this as a state invariant, not merely a Settings/UI restriction: camera
        // preferences can be restored while Photo/Slo-Mo is active and then carried into Video.
        if codec == "H264", resolution == .p4k, frameRate == .fps60 {
            return "HEVC"
        }
        return codec
    }

    func isKnownUnsupportedH264VideoSelection(
        codec: String,
        resolution: VideoResolution,
        frameRate: VideoFrameRate
    ) -> Bool {
        Self.normalizedVideoCodec(codec, resolution: resolution, frameRate: frameRate) != codec
    }

    /// Keeps the requested 4K60 quality when AVC cannot encode the selection. This deliberately
    /// does NOT depend on the currently visible capture mode: per-camera Video preferences may be
    /// loaded while Photo/Slo-Mo is active, and the codec must already be valid before a later
    /// transition into Video schedules its hardware transaction.
    @discardableResult
    func autoPromoteH264ForUnsupportedVideoSelection(
        position: CameraPosition,
        resolution: VideoResolution,
        frameRate: VideoFrameRate
    ) -> Bool {
        let normalizedCodec = Self.normalizedVideoCodec(
            selectedVideoCodec,
            resolution: resolution,
            frameRate: frameRate
        )
        guard normalizedCodec != selectedVideoCodec,
              position == cameraPosition else { return false }

        let previousCodec = selectedVideoCodec
        let wasSuppressing = suppressAutomaticReconfiguration
        suppressAutomaticReconfiguration = true
        selectedVideoCodec = normalizedCodec
        suppressAutomaticReconfiguration = wasSuppressing
        codecAvailabilityMessage = nil
        AppEventLog.event(
            "Video codec promoted automatically: \(previousCodec) -> \(normalizedCodec) for \(position == .back ? "rear" : "front") \(resolution.rawValue)\(frameRate.rawValue)"
        )
        return true
    }

    func isSlowMotionResolutionSupported(_ resolution: VideoResolution) -> Bool {
        supportedSlowMotionResolutions.contains(resolution)
    }

    func isSlowMotionFrameRateSupported(_ frameRate: SlowMotionFrameRate) -> Bool {
        supportedSlowMotionFrameRates.contains(frameRate)
    }

    func isCaptureModeSupported(_ mode: CaptureMode) -> Bool {
        switch mode {
        case .photo:
            return true
        case .video:
            return !isVideoAvailabilityKnown || isVideoAvailable
        case .sloMo:
            return !isSlowMotionAvailabilityKnown || isSlowMotionAvailable
        }
    }

    func publishVideoAvailability(_ available: Bool) {
        publish {
            if self.isVideoAvailabilityKnown != true {
                self.isVideoAvailabilityKnown = true
            }
            if self.isVideoAvailable != available {
                self.isVideoAvailable = available
            }
        }
    }

    func publishSlowMotionAvailability(_ available: Bool) {
        publish {
            if self.isSlowMotionAvailabilityKnown != true {
                self.isSlowMotionAvailabilityKnown = true
            }
            if self.isSlowMotionAvailable != available {
                self.isSlowMotionAvailable = available
            }
        }
    }

    func updateSlowMotionAvailability(
        for devices: [AVCaptureDevice],
        selector: CameraFormatSelector? = nil,
        position: CameraPosition? = nil,
        codec: String? = nil,
        validation: (() -> Bool)? = nil
    ) {
        let targetPosition = position ?? cameraPosition
        let targetCodec = codec ?? activeVideoCodec
        let targetSelector = selector ?? formatSelector
        let key = [
            targetPosition == .back ? "back" : "front",
            targetCodec,
            devices.map(\.uniqueID).joined(separator: ",")
        ].joined(separator: "|")
        guard slowMotionAvailabilityKey != key else { return }
        let available = !targetSelector.slowMotionResolutions(for: devices).isEmpty
        if let validation, !validation() { return }
        slowMotionAvailabilityKey = key
        publishSlowMotionAvailability(available)
    }

    func transitionRecordingState(
        to newState: RecordingState,
        resetClock: Bool = false,
        startClock: Bool = false,
        clearLastFrameGaps: Bool = false
    ) {
        let previousState = recordingState
        let previousFlags = recordingState.uiFlags
        let resetPauseState = newState.isIdle
        if resetPauseState {
            let hadPauseActivity = pendingRecordingPauseRequest != nil || recordingPauseMachine.state != .idle
            pendingRecordingPauseRequest = nil
            if hadPauseActivity {
                _ = recordingPauseRequests.next(reason: "recording state returned to idle")
            }
            recordingPauseMachine.reset()
        }
        recordingState = newState
        if newState.isIdle {
            storageGuard.stopMonitoring()
            cancelSplitTimer()
        }
        if previousState != newState {
            invalidatePendingVideoConfiguration()
            _ = qualityRequests.next()
            _ = captureConfigurationGeneration.next()
            AppEventLog.event("Recording state: \(String(describing: previousState)) -> \(String(describing: newState))")
        }
        let flags = newState.uiFlags
        let flagsChanged = previousFlags.starting != flags.starting ||
            previousFlags.recording != flags.recording ||
            previousFlags.finalizing != flags.finalizing
        guard flagsChanged || resetClock || startClock || clearLastFrameGaps || resetPauseState else { return }

        publish {
            if resetClock {
                self.recordingClock.stopAndReset()
            } else if startClock {
                self.recordingClock.startIfNeeded()
            }
            self.isRecordingStarting = flags.starting
            self.isRecording = flags.recording
            self.isFinalizingRecording = flags.finalizing
            if resetPauseState {
                self.recordingPauseState = .idle
            }
            if clearLastFrameGaps {
                self.lastFrameGaps = nil
            }
        }
    }

    func scheduleVideoConfiguration(
        formatAffecting: Bool,
        qualityRequestID: UInt64,
        compressionRequestID: UInt64,
        transitionID: UInt64? = nil
    ) {
        let request = PendingVideoConfiguration(
            id: videoConfigurationRequests.next(),
            qualityRequestID: qualityRequestID,
            compressionRequestID: compressionRequestID,
            resolution: selectedResolution,
            frameRate: selectedFrameRate,
            slowMotionResolution: selectedSlowMotionResolution,
            slowMotionFrameRate: selectedSlowMotionFrameRate,
            codec: selectedVideoCodec,
            compression: videoCompression,
            compressionMode: videoCompressionMode,
            manualBitrateMbps: videoManualBitrateMbps,
            position: cameraPosition,
            mode: captureMode,
            configurationGenerationID: captureConfigurationGeneration.current(),
            whiteBalanceRequestID: whiteBalanceRequests.current(),
            preferVirtualCamera: !requiresPhysicalWhiteBalanceInput,
            formatAffecting: formatAffecting,
            transitionID: transitionID
        )
        AppEventLog.event(
            "VIDEO CONFIG REQUEST SCHEDULED: reason=\(formatAffecting ? "format" : "output"), " +
            "resolution=\(request.resolution.rawValue), fps=\(request.frameRate.rawValue), " +
            "codec=\(request.codec), compression=\(request.compression.rawValue)"
        )

        sessionQueue.async { [weak self] in
            guard let self else { return }
            if let pending = self.pendingVideoConfiguration {
                self.pendingVideoConfiguration = PendingVideoConfiguration(
                    id: request.id,
                    qualityRequestID: request.qualityRequestID,
                    compressionRequestID: request.compressionRequestID,
                    resolution: request.resolution,
                    frameRate: request.frameRate,
                    slowMotionResolution: request.slowMotionResolution,
                    slowMotionFrameRate: request.slowMotionFrameRate,
                    codec: request.codec,
                    compression: request.compression,
                    compressionMode: request.compressionMode,
                    manualBitrateMbps: request.manualBitrateMbps,
                    position: request.position,
                    mode: request.mode,
                    configurationGenerationID: request.configurationGenerationID,
                    whiteBalanceRequestID: request.whiteBalanceRequestID,
                    preferVirtualCamera: request.preferVirtualCamera,
                    formatAffecting: pending.formatAffecting || request.formatAffecting,
                    transitionID: request.transitionID ?? pending.transitionID
                )
                AppEventLog.event(
                    "VIDEO CONFIG REQUEST COALESCED: previous=\(pending.id), latest=\(request.id), " +
                    "formatAffecting=\(pending.formatAffecting || request.formatAffecting)"
                )
            } else {
                self.pendingVideoConfiguration = request
            }

            guard self.pendingVideoConfigurationWorkItem == nil else { return }
            let workItem = DispatchWorkItem { [weak self] in
                self?.applyPendingVideoConfiguration()
            }
            self.pendingVideoConfigurationWorkItem = workItem
            self.sessionQueue.asyncAfter(deadline: .now() + 0.07, execute: workItem)
        }
    }

    /// Invalidates queued idle Video-setting work. This must run on sessionQueue so the pending
    /// request and its timer cannot race an input/mode/recording transition.
    func invalidatePendingVideoConfiguration() {
        _ = videoConfigurationRequests.next()
        let pending = pendingVideoConfiguration
        pendingVideoConfiguration = nil
        pendingVideoConfigurationWorkItem?.cancel()
        pendingVideoConfigurationWorkItem = nil
        guard let pending else { return }
        if pending.transitionID != nil {
            _ = qualityPreviewTransitions.next()
            publish { self.isPreviewTransitioning = false }
        }
        AppEventLog.event("VIDEO CONFIG REQUEST DROPPED: invalidated by camera state transition")
    }

    func isCurrentVideoConfiguration(_ request: PendingVideoConfiguration) -> Bool {
        videoConfigurationRequests.isLatest(request.id) &&
            qualityRequests.isLatest(request.qualityRequestID) &&
            compressionRequests.isLatest(request.compressionRequestID) &&
            captureConfigurationGeneration.isLatest(request.configurationGenerationID) &&
            whiteBalanceRequests.isLatest(request.whiteBalanceRequestID) &&
            selectedResolution == request.resolution &&
            selectedFrameRate == request.frameRate &&
            selectedVideoCodec == request.codec &&
            videoCompression == request.compression &&
            videoCompressionMode == request.compressionMode &&
            abs(videoManualBitrateMbps - request.manualBitrateMbps) < 0.000_001 &&
            cameraPosition == request.position &&
            captureMode == request.mode &&
            request.mode == .video &&
            appLifecyclePhase == .active &&
            !suppressAutomaticReconfiguration &&
            recordingState.isIdle &&
            !movieOutput.isRecording &&
            !session.isInterrupted &&
            session.isRunning
    }

    func applyPendingVideoConfiguration() {
        let request = pendingVideoConfiguration
        pendingVideoConfiguration = nil
        pendingVideoConfigurationWorkItem = nil
        guard let request else { return }

        guard isCurrentVideoConfiguration(request) else {
            AppEventLog.event(
                "VIDEO CONFIG REQUEST DROPPED: stale or invalid state, " +
                "resolution=\(request.resolution.rawValue), fps=\(request.frameRate.rawValue), " +
                "codec=\(request.codec), compression=\(request.compression.rawValue)"
            )
            if let transitionID = request.transitionID {
                finishQualityPreviewTransition(transitionID)
            }
            return
        }

        let success: Bool
        if request.formatAffecting {
            lensTransitionCoordinator.cancel()
            switch request.mode {
            case .video:
                success = applySelectedFormat(
                    preferVirtualCamera: request.preferVirtualCamera,
                    requestedResolution: request.resolution,
                    requestedFrameRate: request.frameRate,
                    requestedCodec: request.codec,
                    requestedCompression: request.compression,
                    requestedCompressionMode: request.compressionMode,
                    requestedManualBitrateMbps: request.manualBitrateMbps,
                    qualityRequestID: request.qualityRequestID,
                    requestedPosition: request.position,
                    requestValidation: { self.isCurrentVideoConfiguration(request) }
                )
            case .sloMo:
                success = applySlowMotionFormat(
                    requestedResolution: request.slowMotionResolution,
                    requestedFrameRate: request.slowMotionFrameRate,
                    qualityRequestID: request.qualityRequestID,
                    requestedPosition: request.position
                )
            case .photo:
                success = applyBestPhotoFormat(preferVirtualCamera: request.preferVirtualCamera)
            }
        } else {
            success = configureMovieOutputSettings(
                requestedCodec: request.codec,
                requestedCompression: request.compression,
                requestedCompressionMode: request.compressionMode,
                requestedManualBitrateMbps: request.manualBitrateMbps,
                requestedResolution: request.resolution,
                requestedFrameRate: request.frameRate,
                requestedPosition: request.position,
                requestedMode: request.mode
            )
        }

        AppEventLog.event(
            "VIDEO CONFIG APPLY: formatApply=\(request.formatAffecting), " +
            "outputOnly=\(!request.formatAffecting), resolution=\(request.resolution.rawValue), " +
            "fps=\(request.frameRate.rawValue), codec=\(request.codec), " +
            "compression=\(request.compression.rawValue), success=\(success)"
        )
        if let transitionID = request.transitionID {
            finishQualityPreviewTransition(transitionID)
        }
    }

    func transitionRecordingToDiscard(resetClock: Bool = false) {
        transitionRecordingState(
            to: .stoppingToDiscard(finalizing: recordingState.isFinalizing),
            resetClock: resetClock
        )
    }

    func transitionRecordingToFinalizing(resetClock: Bool = false) {
        if recordingState.shouldDiscardWhenFinished {
            transitionRecordingState(to: .stoppingToDiscard(finalizing: true), resetClock: resetClock)
        } else {
            transitionRecordingState(to: .finalizing, resetClock: resetClock)
        }
    }

    func preferenceKey(_ base: String, for position: CameraPosition) -> String {
        position == .back ? base : "\(base).front"
    }

    func persistCameraPreference(_ base: String, value: Any) {
        UserDefaults.standard.set(value, forKey: preferenceKey(base, for: cameraPosition))
    }

    func persistCameraPreferences() {
        let defaults = UserDefaults.standard
        let position = cameraPosition
        defaults.set(selectedResolution.rawValue, forKey: preferenceKey(Self.resolutionKey, for: position))
        defaults.set(selectedFrameRate.rawValue, forKey: preferenceKey(Self.frameRateKey, for: position))
        defaults.set(selectedSlowMotionResolution.rawValue, forKey: preferenceKey(Self.slowMotionResolutionKey, for: position))
        defaults.set(selectedSlowMotionFrameRate.rawValue, forKey: preferenceKey(Self.slowMotionFrameRateKey, for: position))
    }

    func loadCameraPreferences(for position: CameraPosition) {
        let defaults = UserDefaults.standard
        suppressPreferencePersistence = true
        defer { suppressPreferencePersistence = false }
        let resolution = defaults.string(forKey: preferenceKey(Self.resolutionKey, for: position))
        selectedResolution = VideoResolution(rawValue: resolution ?? "") ?? .p1080
        let fps = defaults.integer(forKey: preferenceKey(Self.frameRateKey, for: position))
        selectedFrameRate = VideoFrameRate(rawValue: fps) ?? .fps60
        let slowResolution = defaults.string(forKey: preferenceKey(Self.slowMotionResolutionKey, for: position))
        selectedSlowMotionResolution = VideoResolution(rawValue: slowResolution ?? "") ?? .p1080
        let slowFPS = defaults.integer(forKey: preferenceKey(Self.slowMotionFrameRateKey, for: position))
        selectedSlowMotionFrameRate = SlowMotionFrameRate(rawValue: slowFPS) ?? (position == .front ? .fps120 : .fps240)
    }

}
