import AVFoundation
import Combine
import Foundation
import Photos
import UIKit

// MARK: - CameraManager: Session notifications, storage protection, app lifecycle, start and stop.

extension CameraManager {
    func installSessionObservers() {
        let center = NotificationCenter.default
        sessionObserverTokens = [
            center.addObserver(forName: AVCaptureSession.runtimeErrorNotification, object: session, queue: nil) { [weak self] note in
                self?.sessionQueue.async { self?.handleSessionRuntimeError(note) }
            },
            center.addObserver(forName: AVCaptureSession.wasInterruptedNotification, object: session, queue: nil) { [weak self] note in
                self?.sessionQueue.async { self?.handleSessionInterrupted(note) }
            },
            center.addObserver(forName: AVCaptureSession.interruptionEndedNotification, object: session, queue: nil) { [weak self] _ in
                self?.sessionQueue.async { self?.handleSessionInterruptionEnded() }
            }
        ]
    }

    func handleSessionRuntimeError(_ notification: Notification) {
        invalidateVerifiedHighOutputProvenance()
        invalidatePendingVideoConfiguration()
        storageGuard.stopMonitoring()
        _ = recordingStartRequests.next()
        _ = microphonePermissionRequests.next()
        awaitingMicrophonePermission = false
        microphonePermissionPromptLifecyclePending = false
        _ = qualityRequests.next()
        _ = captureConfigurationGeneration.next()
        stopLiveMetrics()
        let nsError = notification.userInfo?[AVCaptureSessionErrorKey] as? NSError
        AppEventLog.event(
            "SESSION RUNTIME ERROR: domain=\(nsError?.domain ?? "unknown"), code=\(nsError?.code ?? -1), " +
            "description=\(nsError?.localizedDescription ?? "unknown")"
        )
        if nsError?.code == AVError.Code.mediaServicesWereReset.rawValue {
            AppEventLog.event("Session recovery: media services reset; rebuilding camera session")
            rebuildSessionAfterMediaServicesReset()
        } else {
            AppEventLog.event("Session recovery: forcing camera session rebuild")
            showError("Camera session error. Trying to recover…")
            configureSessionIfNeeded(forceRebuild: true)
            if !session.isRunning { session.startRunning() }
            publish { self.isSessionRunning = self.session.isRunning }
        }
    }

    func handleSessionInterrupted(_ notification: Notification) {
        invalidateVerifiedHighOutputProvenance()
        _ = torchRequests.next()
        storageGuard.stopMonitoring()
        _ = recordingStartRequests.next()
        _ = microphonePermissionRequests.next()
        awaitingMicrophonePermission = false
        microphonePermissionPromptLifecyclePending = false
        let reason = (notification.userInfo?[AVCaptureSessionInterruptionReasonKey] as? NSNumber)?.intValue ?? -1
        AppEventLog.event("SESSION INTERRUPTED: reason=\(reason), running=\(session.isRunning), recording=\(movieOutput.isRecording), requestedRecording=\(recordingState.requestsRecording)")
        invalidatePendingVideoConfiguration()
        _ = qualityRequests.next()
        _ = captureConfigurationGeneration.next()
        let currentWhiteBalanceRequestID = whiteBalanceRequests.current()
        if deferredWhiteBalanceRequest == nil ||
            !whiteBalanceRequests.isLatest(deferredWhiteBalanceRequest?.id ?? 0) {
            deferredWhiteBalanceRequest = DeferredWhiteBalanceRequest(
                id: currentWhiteBalanceRequestID,
                preset: requestedWhiteBalancePreset,
                previousPreset: requestedWhiteBalancePreset
            )
        }
        stopLiveMetrics()
        lensTransitionCoordinator.cancel()
        burstRemaining = 0
        burstStopRequested = true
        synchronizeTorchState()
        let sessionAvailable = session.isRunning && !session.isInterrupted
        publish {
            self.isSessionRunning = sessionAvailable
        }
        guard recordingState.requestsRecording || movieOutput.isRecording else { return }

        cancelSplitTimer()

        if movieOutput.isRecording {
            requestNativeRecordingStop(reason: "session interruption")
            transitionRecordingToFinalizing(resetClock: true)
            postStatus("Recording interrupted · saving…")
            movieOutput.stopRecording()
        } else {
            resetNativeRecordingPauseState(reason: "session interruption without active movie output")
            transitionRecordingToDiscard(resetClock: true)
        }
    }

    func handleSessionInterruptionEnded() {
        AppEventLog.event("SESSION INTERRUPTION ENDED; restoring camera session")
        invalidatePendingVideoConfiguration()
        _ = qualityRequests.next()
        _ = captureConfigurationGeneration.next()
        configureSessionIfNeeded()
        if !session.isRunning { session.startRunning() }
        applyDeferredWhiteBalanceIfPossible()
        synchronizeTorchState()
        publish { self.isSessionRunning = self.session.isRunning }
        logSessionSnapshot("after interruption recovery")
    }

    func rebuildSessionAfterMediaServicesReset() {
        configureSessionIfNeeded(forceRebuild: true)
        if !session.isRunning { session.startRunning() }
        publish { self.isSessionRunning = self.session.isRunning }
    }

    var hudResolutionLabel: String {
        switch captureMode {
        case .video: return selectedResolution.rawValue
        case .sloMo: return selectedSlowMotionResolution.rawValue
        case .photo: return currentPhotoResolutionLabel
        }
    }

    var hudFrameRateLabel: String? {
        switch captureMode {
        case .video: return "\(selectedFrameRate.rawValue)"
        case .sloMo: return "\(selectedSlowMotionFrameRate.rawValue)"
        case .photo: return nil
        }
    }

    var hudRemainingLabel: String {
        let reserve: Int64 = 500 * 1_024 * 1_024
        let usable = max(availableStorageBytes - reserve, 0)
        guard usable > 0 else { return captureMode == .photo ? "~0" : "~0m" }

        if captureMode == .photo {
            let bytesPerPhoto = estimatedBytesPerPhoto
            guard bytesPerPhoto > 0 else { return "—" }
            let count = Int64(Double(usable) / bytesPerPhoto)
            if count >= 10_000 { return "~10k+" }
            return "~\(max(count, 0))"
        }

        let bitsPerSecond = estimatedVideoBitsPerSecond
        guard bitsPerSecond > 0 else { return "—" }
        let seconds = Int(Double(usable) * 8.0 / bitsPerSecond)
        if seconds >= 3_600 {
            return String(format: "~%dh%02dm", seconds / 3_600, (seconds % 3_600) / 60)
        }
        return "~\(max(seconds / 60, 0))m"
    }

    func refreshAvailableStorage() {
        storageGuard.checkNow(criticalReserveBytes: criticalStorageReserveBytes) { [weak self] snapshot in
            guard let self, let snapshot else { return }
            self.sessionQueue.async {
                self.applyStorageSnapshot(snapshot, source: "refresh")
            }
        }
    }

    var criticalStorageReserveBytes: Int64 {
        StorageGuard.criticalReserveBytes(forVideoBitrate: estimatedVideoBitsPerSecond)
    }

    /// Called on sessionQueue for both the idle HUD refresh and the active recording monitor.
    func applyStorageSnapshot(_ snapshot: StorageSnapshot, source: String) {
        publish {
            if self.availableStorageBytes != snapshot.availableBytes {
                self.availableStorageBytes = snapshot.availableBytes
            }
        }

        if snapshot.availableBytes > StorageGuard.warningThresholdBytes {
            storageWarningEpisodeActive = false
        } else if snapshot.isWarning, !storageWarningEpisodeActive {
            storageWarningEpisodeActive = true
            if UserDefaults.standard.object(forKey: "lowStorageWarning") as? Bool ?? true {
                postStatus("Storage is below 1 GB. Long recordings may stop early.")
            }
            AppEventLog.event("Storage warning threshold crossed: available=\(snapshot.availableBytes), source=\(source)")
        }

        guard snapshot.isCritical,
              recordingState.requestsRecording || movieOutput.isRecording else { return }
        issueStorageProtectionStop(snapshot: snapshot, source: source)
    }

    func issueStorageProtectionStop(snapshot: StorageSnapshot, source: String) {
        guard !storageProtectionStopIssued else { return }
        storageProtectionStopIssued = true
        _ = recordingStartRequests.next()
        _ = microphonePermissionRequests.next()
        awaitingMicrophonePermission = false
        microphonePermissionPromptLifecyclePending = false
        cancelSplitTimer()
        storageGuard.stopMonitoring()
        AppEventLog.event(
            "STORAGE CRITICAL: available=\(snapshot.availableBytes), reserve=\(activeCriticalStorageReserveBytes), " +
            "bitrate=\(Int(estimatedVideoBitsPerSecond)), source=\(source), stopReason=low-storage protection"
        )

        if movieOutput.isRecording {
            requestNativeRecordingStop(reason: "critical storage protection")
            transitionRecordingToFinalizing(resetClock: true)
            postStatus("Recording stopped to protect the file because storage is critically low.")
            movieOutput.stopRecording()
        } else if recordingState.requestsRecording {
            resetNativeRecordingPauseState(reason: "critical storage before movie output start")
            transitionRecordingState(to: .idle, resetClock: true)
            restoreIdleCaptureConfigurationAfterRecording()
            postStatus("Not enough free storage to safely start recording.")
        }
    }

    func rejectRecordingStartForStorage(snapshot: StorageSnapshot) {
        storageProtectionStopIssued = true
        _ = recordingStartRequests.next()
        storageGuard.stopMonitoring()
        AppEventLog.event(
            "Recording start rejected: critically low storage, available=\(snapshot.availableBytes), " +
            "reserve=\(activeCriticalStorageReserveBytes), bitrate=\(Int(estimatedVideoBitsPerSecond))"
        )
        transitionRecordingState(to: .idle, resetClock: true)
        restoreIdleCaptureConfigurationAfterRecording()
        showError("Not enough free storage to safely start recording.")
    }


    var estimatedVideoBitsPerSecond: Double {
        let resolution = captureMode == .sloMo ? selectedSlowMotionResolution : selectedResolution
        let fps: Double = captureMode == .sloMo
            ? Double(selectedSlowMotionFrameRate.rawValue)
            : Double(selectedFrameRate.rawValue)
        let compression = compressionSelection(for: captureMode)
        return estimatedVideoBitsPerSecond(
            resolution: resolution,
            fps: fps,
            codec: activeVideoCodec,
            compression: compression.level,
            compressionMode: compression.mode,
            manualBitrateMbps: compression.manualBitrateMbps,
            isSlowMotion: captureMode == .sloMo
        )
    }

    func estimatedVideoBitsPerSecond(
        resolution: VideoResolution,
        fps: Double,
        codec: String,
        compression: VideoCompression,
        compressionMode: CompressionMode = .auto,
        manualBitrateMbps: Double = ManualBitratePolicy.defaultMbps,
        isSlowMotion: Bool = false
    ) -> Double {
        if compressionMode == .manual {
            let effective = ManualBitratePolicy.effectiveMbps(
                requested: manualBitrateMbps,
                resolution: resolution,
                fps: fps,
                isSlowMotion: isSlowMotion,
                codec: codec
            )
            return max(ManualBitratePolicy.bitsPerSecond(forMbps: effective), 2_000_000)
        }
        let pixels = Double(resolution.dimensions.width) * Double(resolution.dimensions.height)
        let codecFactor = codec == "H264" ? 1.0 : 0.72
        return max(pixels * fps * compression.bitsPerPixel * codecFactor, 2_000_000)
    }

    var estimatedBytesPerPhoto: Double {
        let pixels = max(Double(currentPhotoPixelCount), 1)
        let bytesPerPixel = photoFileFormat == "HEIC" ? 0.22 : 0.48
        return max(pixels * bytesPerPixel, photoFileFormat == "HEIC" ? 250_000 : 500_000)
    }

    func start() {
        sessionQueue.async { [weak self] in
            guard let self else { return }
            AppEventLog.event("Camera start requested")
            self.requestedZoom = 1
            self.configureSessionIfNeeded()
            self.scheduleCapabilitySnapshotRefresh(reason: "camera start")
            guard self.session.isRunning == false else {
                self.publish { self.isSessionRunning = true }
                self.applyDeferredWhiteBalanceIfPossible()
                return
            }
            self.session.startRunning()
            AppEventLog.event("Camera session running")
            try? AVAudioSession.sharedInstance().setAllowHapticsAndSystemSoundsDuringRecording(true)
            self.publish { self.isSessionRunning = true }
            self.applyDeferredWhiteBalanceIfPossible()
            self.configureAudioMeterOutput()
            self.synchronizeTorchState()
            self.refreshAvailableStorage()
            self.storageQueue.async { [weak self] in
                self?.refreshRecoveryCount()
            }
        }
    }

    func stop() {
        sessionQueue.async { [weak self] in
            guard let self else { return }
            AppEventLog.event("Camera stop requested")
            self.invalidateVerifiedHighOutputProvenance()
            _ = self.torchRequests.next()
            _ = self.recordingStartRequests.next()
            _ = self.microphonePermissionRequests.next()
            self.awaitingMicrophonePermission = false
            self.microphonePermissionPromptLifecyclePending = false
            self.storageGuard.stopMonitoring()
            self.invalidatePendingVideoConfiguration()
            _ = self.qualityRequests.next()
            _ = self.captureConfigurationGeneration.next()
            self.stopLiveMetrics()
            self.lensTransitionCoordinator.cancel()
            self.burstRemaining = 0
            self.burstStopRequested = true
            self.cancelSplitTimer()
            if self.movieOutput.isRecording {
                self.requestNativeRecordingStop(reason: "camera stop")
                self.transitionRecordingToFinalizing(resetClock: true)
                self.movieOutput.stopRecording()
            } else if self.recordingState.requestsRecording {
                self.requestNativeRecordingStop(reason: "camera stop without active movie output")
                self.transitionRecordingState(to: .idle, resetClock: true)
            }
            if self.session.isRunning {
                self.session.stopRunning()
                AppEventLog.event("Camera session stopped")
                self.publish { self.isSessionRunning = false }
            }
        }
    }

    func appDidBecomeInactive(isBackground: Bool = false) {
        AppEventLog.flush()
        let requestedPhase: AppLifecyclePhase = isBackground ? .background : .inactive
        sessionQueue.async { [weak self] in
            guard let self else { return }

            // The system microphone permission UI can emit a short .inactive transition even
            // after requestAccess has completed. Treat only that one permission-sheet bounce as
            // transient so a just-started first recording is not discarded. A real background
            // transition still performs the full cleanup below.
            if requestedPhase == .inactive && self.microphonePermissionPromptLifecyclePending {
                AppEventLog.event("App lifecycle inactive ignored during microphone permission prompt")
                return
            }
            if requestedPhase == .background {
                self.microphonePermissionPromptLifecyclePending = false
            }

            guard self.appLifecyclePhase != requestedPhase else {
                AppEventLog.event("App lifecycle ignored: \(requestedPhase.rawValue) already handled")
                return
            }
            let previousPhase = self.appLifecyclePhase
            self.appLifecyclePhase = requestedPhase
            AppEventLog.event("App lifecycle transition: \(previousPhase.rawValue) -> \(requestedPhase.rawValue)")
            self.invalidatePendingVideoConfiguration()
            _ = self.recordingStartRequests.next()
            _ = self.microphonePermissionRequests.next()
            self.awaitingMicrophonePermission = false
            self.microphonePermissionPromptLifecyclePending = false
            self.storageGuard.stopMonitoring()
            // ACTIVE -> INACTIVE/BACKGROUND owns the cleanup. INACTIVE -> BACKGROUND is a
            // distinct lifecycle transition, but has no additional camera work today.
            guard previousPhase == .active else { return }

            _ = self.qualityRequests.next()
            _ = self.captureConfigurationGeneration.next()
            self.invalidateVerifiedHighOutputProvenance()
            _ = self.torchRequests.next()
            self.stopLiveMetrics()
            self.lensTransitionCoordinator.cancel()
            self.burstRemaining = 0
            self.burstStopRequested = true
            self.cancelSplitTimer()

            // Keep hardware and UI in sync when the app/phone becomes inactive. iOS normally
            // disables the torch itself, but doing it explicitly prevents a stale-on edge case.
            if let device = self.videoInput?.device, device.hasTorch, device.torchMode == .on {
                do {
                    try device.lockForConfiguration()
                    device.torchMode = .off
                    device.unlockForConfiguration()
                } catch {
                    // The session interruption can already own the device; the state is synced below.
                }
            }

            if self.movieOutput.isRecording {
                self.requestNativeRecordingStop(reason: "app became inactive")
                self.transitionRecordingToFinalizing(resetClock: true)
                self.movieOutput.stopRecording()
            } else if self.recordingState.requestsRecording {
                self.resetNativeRecordingPauseState(reason: "app became inactive without active movie output")
                self.transitionRecordingState(to: .idle, resetClock: true)
            }

            self.publish {
                if self.isTorchOn { self.isTorchOn = false }
                if self.torchBrightnessSupported { self.torchBrightnessSupported = false }
            }
        }
    }

    func appDidBecomeActive() {
        sessionQueue.async { [weak self] in
            guard let self else { return }
            if self.microphonePermissionPromptLifecyclePending {
                self.microphonePermissionPromptLifecyclePending = false
                AppEventLog.event("Microphone permission lifecycle bounce completed")
            }
            guard self.appLifecyclePhase != .active else {
                AppEventLog.event("App lifecycle ignored: active already handled")
                return
            }
            let previousPhase = self.appLifecyclePhase
            self.appLifecyclePhase = .active
            AppEventLog.event("App lifecycle transition: \(previousPhase.rawValue) -> active")
            self.invalidatePendingVideoConfiguration()
            self.configureSessionIfNeeded()
            self.scheduleCapabilitySnapshotRefresh(reason: "app became active")
            if !self.session.isRunning {
                self.session.startRunning()
            }
            try? AVAudioSession.sharedInstance().setAllowHapticsAndSystemSoundsDuringRecording(true)
            self.publish { self.isSessionRunning = self.session.isRunning }
            self.applyDeferredWhiteBalanceIfPossible()
            self.synchronizeTorchState()
        }
    }
}
