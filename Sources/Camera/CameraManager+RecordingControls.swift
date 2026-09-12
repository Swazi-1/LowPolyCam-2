import AVFoundation
import Combine
import Foundation
import Photos
import UIKit

// MARK: - CameraManager: Recording pause/split controls, compression, presets, microphone and audio-meter control.

extension CameraManager {
    func finishQualityPreviewTransition(_ transitionID: UInt64) {
        // The iPhone 11 test stream needed roughly 0.32-0.37 seconds to produce a bright frame
        // after a resolution/FPS commit. Keep the existing frozen cover through that reset window.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.38) { [weak self] in
            guard let self, self.qualityPreviewTransitions.isLatest(transitionID) else { return }
            self.isPreviewTransitioning = false
        }
    }

    func setVideoStabilizationEnabled(_ enabled: Bool) {
        guard isVideoStabilizationEnabled != enabled else { return }
        AppEventLog.event("Video stabilization requested: \(isVideoStabilizationEnabled) -> \(enabled)")
        isVideoStabilizationEnabled = enabled
        guard captureMode == .video else {
            AppEventLog.event("Video stabilization saved; no active Video format to reconfigure")
            return
        }
        sessionQueue.async { [weak self] in self?.configureMovieOutputSettings() }
    }

    func refreshMovieOutputSettings() {
        sessionQueue.async { [weak self] in
            guard let self, !self.movieOutput.isRecording else { return }
            _ = self.configureMovieOutputSettings()
        }
    }

    func toggleRecordingPause() {
        sessionQueue.async { [weak self] in
            guard let self else { return }
            self.toggleRecordingPauseOnSessionQueue()
        }
    }

    func toggleRecordingPauseOnSessionQueue() {
        guard captureMode == .video || captureMode == .sloMo else {
            AppEventLog.guardRejected("toggleRecordingPause", reason: "capture mode is not recordable", traceID: activeRecordingTraceID)
            return
        }
        guard case .recording(_) = recordingState, movieOutput.isRecording else {
            AppEventLog.guardRejected("toggleRecordingPause", reason: "recording is not actively writing", traceID: activeRecordingTraceID, fields: [
                "recordingState": String(describing: recordingState),
                "movieOutput.isRecording": String(movieOutput.isRecording),
                "movieOutput.isRecordingPaused": String(movieOutput.isRecordingPaused),
                "pauseState": recordingPauseMachine.state.rawValue
            ])
            return
        }

        switch recordingPauseMachine.state {
        case .recording:
            guard !movieOutput.isRecordingPaused else {
                AppEventLog.guardRejected("toggleRecordingPause", reason: "native output is already paused", traceID: activeRecordingTraceID)
                return
            }
            guard recordingPauseMachine.requestPause() else {
                AppEventLog.guardRejected("toggleRecordingPause", reason: "pause transition rejected", traceID: activeRecordingTraceID)
                return
            }
            let requestID = recordingPauseRequests.next(reason: "native pause requested")
            let requestedAt = ProcessInfo.processInfo.systemUptime
            pendingRecordingPauseRequest = RecordingPauseRequest(
                id: requestID,
                operation: .pause,
                stateBefore: .recording,
                traceID: activeRecordingTraceID,
                requestedAt: requestedAt
            )
            publish { self.recordingPauseState = .pausing }
            AppEventLog.event(
                "RECORDING PAUSE REQUEST",
                category: .recording,
                traceID: activeRecordingTraceID,
                fields: recordingPauseLogFields(
                    requestID: requestID,
                    traceID: activeRecordingTraceID,
                    stateBefore: .recording,
                    stateAfter: recordingPauseMachine.state,
                    recordingStateBefore: String(describing: recordingState),
                    recordingStateAfter: String(describing: recordingState),
                    recordedDuration: movieOutput.recordedDuration.seconds,
                    recordingClockElapsed: recordingClock.elapsedSeconds,
                    movieIsRecording: movieOutput.isRecording,
                    movieIsPaused: movieOutput.isRecordingPaused,
                    requestedAt: requestedAt
                )
            )
            movieOutput.pauseRecording()

        case .paused:
            guard movieOutput.isRecordingPaused else {
                AppEventLog.guardRejected("toggleRecordingPause", reason: "native output is not paused", traceID: activeRecordingTraceID)
                return
            }
            guard recordingPauseMachine.requestResume() else {
                AppEventLog.guardRejected("toggleRecordingPause", reason: "resume transition rejected", traceID: activeRecordingTraceID)
                return
            }
            let requestID = recordingPauseRequests.next(reason: "native resume requested")
            let requestedAt = ProcessInfo.processInfo.systemUptime
            pendingRecordingPauseRequest = RecordingPauseRequest(
                id: requestID,
                operation: .resume,
                stateBefore: .paused,
                traceID: activeRecordingTraceID,
                requestedAt: requestedAt
            )
            publish { self.recordingPauseState = .resuming }
            AppEventLog.event(
                "RECORDING RESUME REQUEST",
                category: .recording,
                traceID: activeRecordingTraceID,
                fields: recordingPauseLogFields(
                    requestID: requestID,
                    traceID: activeRecordingTraceID,
                    stateBefore: .paused,
                    stateAfter: recordingPauseMachine.state,
                    recordingStateBefore: String(describing: recordingState),
                    recordingStateAfter: String(describing: recordingState),
                    recordedDuration: movieOutput.recordedDuration.seconds,
                    recordingClockElapsed: recordingClock.elapsedSeconds,
                    movieIsRecording: movieOutput.isRecording,
                    movieIsPaused: movieOutput.isRecordingPaused,
                    requestedAt: requestedAt
                )
            )
            movieOutput.resumeRecording()

        case .idle, .pausing, .resuming, .stopping:
            AppEventLog.guardRejected("toggleRecordingPause", reason: "pause/resume transition already in flight or stopping", traceID: activeRecordingTraceID, fields: [
                "pauseState": recordingPauseMachine.state.rawValue
            ])
        }
    }

    func handleNativeRecordingPaused(_ output: AVCaptureFileOutput, fileURL: URL) {
        guard output === movieOutput,
              let request = pendingRecordingPauseRequest,
              case .pause = request.operation,
              recordingPauseRequests.isLatest(request.id),
              recordingPauseMachine.state == .pausing,
              movieOutput.isRecording,
              movieOutput.isRecordingPaused else {
            AppEventLog.guardRejected("didPauseRecording", reason: "stale or invalid native pause callback", traceID: activeRecordingTraceID, fields: [
                "file": fileURL.lastPathComponent,
                "requestID": pendingRecordingPauseRequest.map { String($0.id) } ?? "none",
                "latestID": String(recordingPauseRequests.current()),
                "pauseState": recordingPauseMachine.state.rawValue,
                "movieOutput.isRecording": String(movieOutput.isRecording),
                "movieOutput.isRecordingPaused": String(movieOutput.isRecordingPaused)
            ])
            return
        }

        let stateBefore = recordingPauseMachine.state
        guard recordingPauseMachine.confirmPaused() else { return }
        pendingRecordingPauseRequest = nil
        cancelSplitTimer()
        let fields = recordingPauseLogFields(
            requestID: request.id,
            traceID: request.traceID,
            stateBefore: stateBefore,
            stateAfter: recordingPauseMachine.state,
            recordingStateBefore: String(describing: recordingState),
            recordingStateAfter: String(describing: recordingState),
            recordedDuration: movieOutput.recordedDuration.seconds,
            recordingClockElapsed: recordingClock.elapsedSeconds,
            movieIsRecording: movieOutput.isRecording,
            movieIsPaused: movieOutput.isRecordingPaused,
            requestedAt: request.requestedAt,
            file: fileURL.lastPathComponent
        )
        publish {
            self.recordingClock.pause()
            var actualFields = fields
            actualFields["recordingClockElapsed"] = String(format: "%.0f", self.recordingClock.elapsedSeconds)
            self.recordingPauseState = .paused
            AppEventLog.event("RECORDING PAUSED", category: .recording, traceID: request.traceID, fields: actualFields)
        }
    }

    func handleNativeRecordingResumed(_ output: AVCaptureFileOutput, fileURL: URL) {
        guard output === movieOutput,
              let request = pendingRecordingPauseRequest,
              case .resume = request.operation,
              recordingPauseRequests.isLatest(request.id),
              recordingPauseMachine.state == .resuming,
              movieOutput.isRecording,
              !movieOutput.isRecordingPaused else {
            AppEventLog.guardRejected("didResumeRecording", reason: "stale or invalid native resume callback", traceID: activeRecordingTraceID, fields: [
                "file": fileURL.lastPathComponent,
                "requestID": pendingRecordingPauseRequest.map { String($0.id) } ?? "none",
                "latestID": String(recordingPauseRequests.current()),
                "pauseState": recordingPauseMachine.state.rawValue,
                "movieOutput.isRecording": String(movieOutput.isRecording),
                "movieOutput.isRecordingPaused": String(movieOutput.isRecordingPaused)
            ])
            return
        }

        let stateBefore = recordingPauseMachine.state
        guard recordingPauseMachine.confirmResumed() else { return }
        pendingRecordingPauseRequest = nil
        let fields = recordingPauseLogFields(
            requestID: request.id,
            traceID: request.traceID,
            stateBefore: stateBefore,
            stateAfter: recordingPauseMachine.state,
            recordingStateBefore: String(describing: recordingState),
            recordingStateAfter: String(describing: recordingState),
            recordedDuration: movieOutput.recordedDuration.seconds,
            recordingClockElapsed: recordingClock.elapsedSeconds,
            movieIsRecording: movieOutput.isRecording,
            movieIsPaused: movieOutput.isRecordingPaused,
            requestedAt: request.requestedAt,
            file: fileURL.lastPathComponent
        )
        publish {
            self.recordingClock.resume()
            var actualFields = fields
            actualFields["recordingClockElapsed"] = String(format: "%.0f", self.recordingClock.elapsedSeconds)
            self.recordingPauseState = .recording
            AppEventLog.event("RECORDING RESUMED", category: .recording, traceID: request.traceID, fields: actualFields)
        }
        let splitDuration = recordingState.splitDuration
        if splitDuration > 0 {
            scheduleSplitTimer(splitDuration: splitDuration)
        }
    }

    func requestNativeRecordingStop(reason: String) {
        pendingRecordingPauseRequest = nil
        _ = recordingPauseRequests.next(reason: reason)
        if recordingPauseMachine.state != .idle && recordingPauseMachine.state != .stopping {
            _ = recordingPauseMachine.requestStop()
        }
        let state = recordingPauseMachine.state
        publish { self.recordingPauseState = state }
    }

    func completeNativeRecordingStop(reason: String) {
        pendingRecordingPauseRequest = nil
        _ = recordingPauseRequests.next(reason: reason)
        _ = recordingPauseMachine.completeStop()
        recordingPauseMachine.reset()
        publish { self.recordingPauseState = .idle }
    }

    func resetNativeRecordingPauseState(reason: String) {
        pendingRecordingPauseRequest = nil
        _ = recordingPauseRequests.next(reason: reason)
        recordingPauseMachine.reset()
        publish { self.recordingPauseState = .idle }
    }

    func recordingPauseLogFields(
        requestID: UInt64,
        traceID: String?,
        stateBefore: RecordingPauseState,
        stateAfter: RecordingPauseState,
        recordingStateBefore: String,
        recordingStateAfter: String,
        recordedDuration: Double,
        recordingClockElapsed: Double,
        movieIsRecording: Bool,
        movieIsPaused: Bool,
        requestedAt: TimeInterval,
        file: String? = nil
    ) -> [String: String] {
        var fields: [String: String] = [
            "requestID": String(requestID),
            "traceID": traceID ?? "none",
            "recordingTraceID": traceID ?? "none",
            "stateBefore": stateBefore.rawValue,
            "stateAfter": stateAfter.rawValue,
            "recordingPauseStateBefore": stateBefore.rawValue,
            "recordingPauseStateAfter": stateAfter.rawValue,
            "recordingStateBefore": recordingStateBefore,
            "recordingStateAfter": recordingStateAfter,
            "movieOutput.isRecording": String(movieIsRecording),
            "movieOutput.isRecordingPaused": String(movieIsPaused),
            "recordedDuration": String(format: "%.3f", max(recordedDuration.isFinite ? recordedDuration : 0, 0)),
            "recordingClockElapsed": String(format: "%.0f", max(recordingClockElapsed.isFinite ? recordingClockElapsed : 0, 0)),
            "requestElapsedMs": String(format: "%.2f", max(0, ProcessInfo.processInfo.systemUptime - requestedAt) * 1000)
        ]
        if let file { fields["file"] = file }
        return fields
    }

    func cancelSplitTimer() {
        segmentTimerGeneration &+= 1
        segmentTimer?.cancel()
        segmentTimer = nil
    }

    func scheduleSplitTimer(splitDuration: Double) {
        cancelSplitTimer()
        guard splitDuration.isFinite, splitDuration > 0,
              recordingState.requestsRecording,
              movieOutput.isRecording else { return }

        let remaining = RecordingSplitTimingPolicy.remainingDuration(
            splitDuration: splitDuration,
            recordedDuration: movieOutput.recordedDuration.seconds
        )
        let delay = remaining > 0.05 ? remaining : 0.25
        let generation = segmentTimerGeneration
        let timer = DispatchWorkItem { [weak self] in
            guard let self, self.segmentTimerGeneration == generation else { return }
            self.handleSplitTimer(splitDuration: splitDuration)
        }
        segmentTimer = timer
        sessionQueue.asyncAfter(deadline: .now() + delay, execute: timer)
    }

    func handleSplitTimer(splitDuration: Double) {
        guard recordingState.requestsRecording, movieOutput.isRecording else { return }
        guard recordingPauseMachine.state == .recording else {
            scheduleSplitTimer(splitDuration: splitDuration)
            return
        }

        let recordedDuration = movieOutput.recordedDuration.seconds
        guard RecordingSplitTimingPolicy.shouldSplit(
            splitDuration: splitDuration,
            recordedDuration: recordedDuration,
            pauseState: recordingPauseMachine.state
        ) else {
            scheduleSplitTimer(splitDuration: splitDuration)
            return
        }

        requestNativeRecordingStop(reason: "recording split timer")
        transitionRecordingState(to: .stoppingToContinueSegment(splitDuration: splitDuration))
        movieOutput.stopRecording()
    }

    func compressionSelection(for mode: CaptureMode) -> (mode: CompressionMode, level: VideoCompression, manualBitrateMbps: Double) {
        if mode == .sloMo {
            return (slowMotionCompressionMode, slowMotionCompression, slowMotionManualBitrateMbps)
        }
        return (videoCompressionMode, videoCompression, videoManualBitrateMbps)
    }

    func compressionDescription(for mode: CaptureMode) -> String {
        let selection = compressionSelection(for: mode)
        if selection.mode == .manual {
            return "Manual \(String(format: "%.1f", selection.manualBitrateMbps)) Mbps"
        }
        return "Auto \(selection.level.rawValue)"
    }

    func refreshCompressionOutputIfNeeded() {
        guard captureMode == .video || captureMode == .sloMo else { return }
        guard !isRecording, !isRecordingStarting, !isFinalizingRecording else { return }
        sessionQueue.async { [weak self] in
            guard let self, self.session.isRunning, !self.movieOutput.isRecording else { return }
            _ = self.configureMovieOutputSettings()
        }
    }

    func setVideoCompressionMode(_ mode: CompressionMode) {
        guard videoCompressionMode != mode else { return }
        videoCompressionMode = mode
        UserDefaults.standard.set(mode.rawValue, forKey: LowPolyCamPreferences.Key.videoCompressionMode)
        _ = compressionRequests.next(reason: "video compression mode")
        AppEventLog.event("Video compression mode changed: \(mode.rawValue)")
        refreshCompressionOutputIfNeeded()
    }

    func setVideoCompressionLevel(_ level: VideoCompression) {
        guard videoCompression != level else { return }
        videoCompression = level
        // Keep the historical key current for older installs and diagnostics.
        UserDefaults.standard.set(level.rawValue, forKey: LowPolyCamPreferences.Key.videoCompression)
    }

    func setVideoManualBitrateMbps(_ value: Double) {
        let validated = ManualBitratePolicy.validatedMbps(value, fallback: videoManualBitrateMbps)
        guard abs(videoManualBitrateMbps - validated) > 0.000_001 else { return }
        videoManualBitrateMbps = validated
        UserDefaults.standard.set(validated, forKey: LowPolyCamPreferences.Key.videoManualBitrateMbps)
        _ = compressionRequests.next(reason: "video manual bitrate")
        refreshCompressionOutputIfNeeded()
    }

    func setSlowMotionCompressionMode(_ mode: CompressionMode) {
        guard slowMotionCompressionMode != mode else { return }
        slowMotionCompressionMode = mode
        UserDefaults.standard.set(mode.rawValue, forKey: LowPolyCamPreferences.Key.slowMotionCompressionMode)
        _ = compressionRequests.next(reason: "Slo-Mo compression mode")
        refreshCompressionOutputIfNeeded()
    }

    func setSlowMotionCompressionLevel(_ level: VideoCompression) {
        guard slowMotionCompression != level else { return }
        slowMotionCompression = level
        UserDefaults.standard.set(level.rawValue, forKey: LowPolyCamPreferences.Key.slowMotionCompressionLevel)
        refreshCompressionOutputIfNeeded()
    }

    func setSlowMotionManualBitrateMbps(_ value: Double) {
        let validated = ManualBitratePolicy.validatedMbps(value, fallback: slowMotionManualBitrateMbps)
        guard abs(slowMotionManualBitrateMbps - validated) > 0.000_001 else { return }
        slowMotionManualBitrateMbps = validated
        UserDefaults.standard.set(validated, forKey: LowPolyCamPreferences.Key.slowMotionManualBitrateMbps)
        _ = compressionRequests.next(reason: "Slo-Mo manual bitrate")
        refreshCompressionOutputIfNeeded()
    }

    func setAudioLevelMeterMode(_ mode: AudioLevelMeterMode) {
        guard audioLevelMeterMode != mode else { return }
        let previousMode = audioLevelMeterMode
        audioLevelMeterMode = mode
        UserDefaults.standard.set(mode.rawValue, forKey: LowPolyCamPreferences.Key.audioLevelMeter)
        AppEventLog.event("Audio level meter mode changed: \(previousMode.rawValue) -> \(mode.rawValue)", category: .audio)
        sessionQueue.async { [weak self] in
            guard let self else { return }
            self.configureAudioMeterOutput()
            self.refreshLiveMetrics()
        }
    }

    func setCaptureOrientation(_ preference: CaptureOrientationPreference) {
        guard captureOrientation != preference else { return }
        captureOrientation = preference
        UserDefaults.standard.set(preference.rawValue, forKey: LowPolyCamPreferences.Key.captureOrientation)
        sessionQueue.async { [weak self] in
            guard let self else { return }
            let movieConnection = self.movieOutput.connection(with: .video)
            self.applyCaptureRotation(to: movieConnection)
            let photoConnection = self.photoOutput.connection(with: .video)
            self.applyCaptureRotation(to: photoConnection)
            AppEventLog.event("Capture orientation applied", category: .session, fields: [
                "requested": preference.rawValue,
                "movieRotationAngle": movieConnection.map { String(format: "%.1f", $0.videoRotationAngle) } ?? "unavailable",
                "photoRotationAngle": photoConnection.map { String(format: "%.1f", $0.videoRotationAngle) } ?? "unavailable"
            ])
        }
    }

    func setCustomWhiteBalance(temperature: Double, tint: Double, isFinal: Bool = true) {
        let nextTemperature = WhiteBalancePreferencePolicy.validatedTemperature(temperature)
        let nextTint = WhiteBalancePreferencePolicy.validatedTint(tint)
        customWhiteBalanceTemperature = nextTemperature
        customWhiteBalanceTint = nextTint

        if isFinal {
            persistCustomWhiteBalance(nextTemperature, tint: nextTint)
        }

        guard requestedWhiteBalancePreset == .custom else { return }

        customWhiteBalanceSubmissionLock.lock()
        let replaced = customWhiteBalanceSubmissionQueue.pending != nil
        if replaced { customWhiteBalanceCoalescedCount += 1 }
        customWhiteBalanceSubmissionQueue.submit(
            CustomWhiteBalanceSubmission(
                temperature: nextTemperature,
                tint: nextTint,
                isFinal: isFinal
            )
        )
        let shouldLogCoalesced = replaced &&
            (customWhiteBalanceCoalescedCount == 1 || customWhiteBalanceCoalescedCount % 10 == 0)
        let coalescedCount = customWhiteBalanceCoalescedCount
        let shouldSchedule = !isCustomWhiteBalanceSubmissionScheduled
        if shouldSchedule { isCustomWhiteBalanceSubmissionScheduled = true }
        customWhiteBalanceSubmissionLock.unlock()

        if shouldLogCoalesced {
            AppEventLog.deepEvent("CUSTOM WB REQUEST COALESCED", category: .whiteBalance, fields: [
                "pendingValue": String(format: "%.0fK/%+.0f", nextTemperature, nextTint),
                "coalescedCount": String(coalescedCount)
            ])
        }

        let delay: DispatchTimeInterval = isFinal ? .milliseconds(0) : .milliseconds(75)
        if shouldSchedule {
            sessionQueue.asyncAfter(deadline: .now() + delay) { [weak self] in
                self?.drainPendingCustomWhiteBalance()
            }
        } else if isFinal {
            // A drag-end value must not wait behind the normal throttle window. The serial camera
            // queue makes this safe even if the earlier delayed drain is still pending.
            sessionQueue.async { [weak self] in
                self?.drainPendingCustomWhiteBalance()
            }
        }
    }

    func persistCustomWhiteBalance(_ temperature: Double, tint: Double) {
        let defaults = UserDefaults.standard
        defaults.set(temperature, forKey: LowPolyCamPreferences.Key.customWhiteBalanceTemperature)
        defaults.set(tint, forKey: LowPolyCamPreferences.Key.customWhiteBalanceTint)
    }

    func beginCustomWhiteBalanceInteraction() {
        customWhiteBalanceSubmissionLock.lock()
        let shouldLog = !customWhiteBalanceInteractionActive
        customWhiteBalanceInteractionActive = true
        customWhiteBalanceCoalescedCount = 0
        customWhiteBalanceSubmissionLock.unlock()
        guard shouldLog else { return }
        AppEventLog.event("CUSTOM WB INTERACTION BEGIN", category: .whiteBalance, fields: [
            "temperature": String(format: "%.0f", customWhiteBalanceTemperature),
            "tint": String(format: "%+.0f", customWhiteBalanceTint)
        ])
    }

    func endCustomWhiteBalanceInteraction() {
        let finalTemperature = WhiteBalancePreferencePolicy.validatedTemperature(customWhiteBalanceTemperature)
        let finalTint = WhiteBalancePreferencePolicy.validatedTint(customWhiteBalanceTint)
        persistCustomWhiteBalance(finalTemperature, tint: finalTint)
        customWhiteBalanceSubmissionLock.lock()
        // Always enqueue the current published values at interaction end. The previous delayed
        // worker may already have consumed the pending value, and the final value still needs an
        // exact hardware apply in that case.
        customWhiteBalanceSubmissionQueue.submit(
            CustomWhiteBalanceSubmission(
                temperature: finalTemperature,
                tint: finalTint,
                isFinal: true
            )
        )
        customWhiteBalanceInteractionActive = false
        isCustomWhiteBalanceSubmissionScheduled = true
        let coalescedCount = customWhiteBalanceCoalescedCount
        customWhiteBalanceSubmissionLock.unlock()
        AppEventLog.event("CUSTOM WB INTERACTION END", category: .whiteBalance, fields: [
            "temperature": String(format: "%.0f", finalTemperature),
            "tint": String(format: "%+.0f", finalTint),
            "coalescedCount": String(coalescedCount),
            "finalApplyScheduled": "true"
        ])
        sessionQueue.async { [weak self] in
            self?.drainPendingCustomWhiteBalance()
        }
    }

    func drainPendingCustomWhiteBalance() {
        customWhiteBalanceSubmissionLock.lock()
        let submission = customWhiteBalanceSubmissionQueue.consumeLatest()
        isCustomWhiteBalanceSubmissionScheduled = false
        let coalescedCount = customWhiteBalanceCoalescedCount
        customWhiteBalanceSubmissionLock.unlock()

        guard let submission else { return }
        guard requestedWhiteBalancePreset == .custom,
              !movieOutput.isRecording,
              !recordingState.requestsRecording,
              !lensTransitionCoordinator.hasActiveTransition else {
            AppEventLog.guardRejected("custom white balance hardware apply", reason: "camera busy or preset changed", fields: [
                "isCustomPreset": String(requestedWhiteBalancePreset == .custom),
                "movieRecording": String(movieOutput.isRecording),
                "recordingRequested": String(recordingState.requestsRecording),
                "lensTransition": String(lensTransitionCoordinator.hasActiveTransition)
            ])
            return
        }

        let requestID = whiteBalanceRequests.next(reason: "coalesced custom white balance")
        let traceID = "WB-\(requestID)"
        AppEventLog.deepEvent("CUSTOM WB HARDWARE APPLY", category: .whiteBalance, traceID: traceID, fields: [
            "temperature": String(format: "%.0f", submission.temperature),
            "tint": String(format: "%+.0f", submission.tint),
            "isFinal": String(submission.isFinal),
            "coalescedCount": String(coalescedCount)
        ])
        applyWhiteBalanceRequest(
            .custom,
            previousPreset: .custom,
            requestID: requestID
        )

        customWhiteBalanceSubmissionLock.lock()
        let needsAnotherDrain = customWhiteBalanceSubmissionQueue.pending != nil &&
            !isCustomWhiteBalanceSubmissionScheduled
        if needsAnotherDrain { isCustomWhiteBalanceSubmissionScheduled = true }
        customWhiteBalanceSubmissionLock.unlock()
        if needsAnotherDrain {
            sessionQueue.async { [weak self] in
                self?.drainPendingCustomWhiteBalance()
            }
        }
    }

    func beginTorchBrightnessInteraction() {
        torchBrightnessSubmissionLock.lock()
        let shouldLog = !torchBrightnessInteractionActive
        torchBrightnessInteractionActive = true
        torchBrightnessCoalescedCount = 0
        torchBrightnessSubmissionLock.unlock()
        guard shouldLog else { return }
        AppEventLog.event("TORCH LEVEL INTERACTION BEGIN", category: .torch, fields: [
            "requestedNormalizedLevel": String(format: "%.3f", TorchLevelPolicy.validatedNormalized(torchBrightnessLevel)),
            "device": videoInput?.device.localizedName ?? "none"
        ])
    }

    func endTorchBrightnessInteraction() {
        let finalLevel = TorchLevelPolicy.validatedNormalized(torchBrightnessLevel)
        UserDefaults.standard.set(finalLevel, forKey: LowPolyCamPreferences.Key.torchBrightness)
        torchBrightnessSubmissionLock.lock()
        // Always enqueue the current published value at interaction end. A delayed worker can have
        // consumed the previous pending value before the slider sends its editing-ended callback.
        pendingTorchBrightness = finalLevel
        isTorchBrightnessSubmissionScheduled = true
        torchBrightnessInteractionActive = false
        let coalescedCount = torchBrightnessCoalescedCount
        torchBrightnessSubmissionLock.unlock()
        AppEventLog.event("TORCH LEVEL INTERACTION END", category: .torch, fields: [
            "requestedNormalizedLevel": String(format: "%.3f", finalLevel),
            "coalescedCount": String(coalescedCount),
            "finalApplyScheduled": "true"
        ])
        sessionQueue.async { [weak self] in
            self?.drainPendingTorchBrightness()
        }
    }

    func setTorchBrightness(_ level: Double, isFinal: Bool = true) {
        let validated = TorchLevelPolicy.validatedNormalized(level)
        let changed = abs(torchBrightnessLevel - validated) > 0.000_001
        guard changed || isFinal else { return }
        if changed { torchBrightnessLevel = validated }
        if isFinal {
            UserDefaults.standard.set(validated, forKey: LowPolyCamPreferences.Key.torchBrightness)
        }

        torchBrightnessSubmissionLock.lock()
        let replaced = pendingTorchBrightness != nil
        if replaced { torchBrightnessCoalescedCount += 1 }
        pendingTorchBrightness = validated
        let shouldLogCoalesced = replaced &&
            (torchBrightnessCoalescedCount == 1 || torchBrightnessCoalescedCount % 10 == 0)
        let coalescedCount = torchBrightnessCoalescedCount
        let isInteracting = torchBrightnessInteractionActive
        let shouldSchedule = !isTorchBrightnessSubmissionScheduled
        if shouldSchedule { isTorchBrightnessSubmissionScheduled = true }
        torchBrightnessSubmissionLock.unlock()

        if isFinal || !isInteracting {
            AppEventLog.event("TORCH LEVEL REQUEST", category: .torch, fields: [
                "requestedNormalizedLevel": String(format: "%.3f", validated),
                "device": videoInput?.device.localizedName ?? "none",
                "isFinal": String(isFinal)
            ])
        } else if shouldLogCoalesced {
            AppEventLog.deepEvent("TORCH LEVEL REQUEST COALESCED", category: .torch, fields: [
                "requestedNormalizedLevel": String(format: "%.3f", validated),
                "coalescedCount": String(coalescedCount)
            ])
        }

        let delay: DispatchTimeInterval = isFinal ? .milliseconds(0) : .milliseconds(75)
        if shouldSchedule {
            sessionQueue.asyncAfter(deadline: .now() + delay) { [weak self] in
                self?.drainPendingTorchBrightness()
            }
        } else if isFinal {
            sessionQueue.async { [weak self] in
                self?.drainPendingTorchBrightness()
            }
        }
    }

    func drainPendingTorchBrightness() {
        torchBrightnessSubmissionLock.lock()
        let pending = pendingTorchBrightness
        pendingTorchBrightness = nil
        isTorchBrightnessSubmissionScheduled = false
        torchBrightnessSubmissionLock.unlock()

        guard pending != nil,
              let device = videoInput?.device,
              device.hasTorch,
              device.torchMode == .on else { return }
        do {
            try device.lockForConfiguration()
            let application = applyTorchConfigurationLocked(to: device, enabled: true)
            device.unlockForConfiguration()
            publish {
                self.torchAvailable = application.torchAvailable
                self.isTorchOn = application.isOn
                self.torchBrightnessSupported = device.isTorchModeSupported(.on)
            }
            logTorchApplication(application, reason: "brightness slider")
        } catch {
            AppEventLog.log(error: error, prefix: "TORCH LEVEL APPLY FAILED", category: .torch)
        }

        torchBrightnessSubmissionLock.lock()
        let shouldDrainAgain = pendingTorchBrightness != nil && !isTorchBrightnessSubmissionScheduled
        if shouldDrainAgain { isTorchBrightnessSubmissionScheduled = true }
        torchBrightnessSubmissionLock.unlock()
        if shouldDrainAgain {
            sessionQueue.async { [weak self] in
                self?.drainPendingTorchBrightness()
            }
        }
    }

    var zoomShortcuts: [Double] {
        zoomShortcutValues
    }

    func setZoomShortcuts(_ values: [Double], count requestedCount: Int? = nil) {
        var validated = ZoomShortcutPolicy.validated(values)
        let targetCount = min(max(requestedCount ?? validated.count, 3), 5)
        for fallback in ZoomShortcutPolicy.defaultValues + [8.0] where validated.count < targetCount {
            guard !validated.contains(where: { abs($0 - fallback) < 0.0001 }) else { continue }
            validated.append(fallback)
        }
        let padded = Array(validated.prefix(targetCount))
        let defaults = UserDefaults.standard
        let keys = [
            LowPolyCamPreferences.Key.zoomButton1,
            LowPolyCamPreferences.Key.zoomButton2,
            LowPolyCamPreferences.Key.zoomButton3,
            LowPolyCamPreferences.Key.zoomButton4,
            LowPolyCamPreferences.Key.zoomButton5
        ]
        for (index, key) in keys.enumerated() {
            let fallback = ZoomShortcutPolicy.defaultValues.indices.contains(index)
                ? ZoomShortcutPolicy.defaultValues[index]
                : 8.0
            defaults.set(padded.indices.contains(index) ? padded[index] : fallback, forKey: key)
        }
        defaults.set(targetCount, forKey: LowPolyCamPreferences.Key.zoomButtonCount)
        zoomShortcutValues = padded.isEmpty ? Array(ZoomShortcutPolicy.defaultValues.prefix(targetCount)) : padded
        AppEventLog.event("Zoom shortcut buttons updated", category: .zoom, fields: [
            "values": padded.map { String(format: "%.2f", $0) }.joined(separator: ",")
        ])
    }

    static func loadZoomShortcutValues(from defaults: UserDefaults) -> [Double] {
        let storedCount = defaults.integer(forKey: LowPolyCamPreferences.Key.zoomButtonCount)
        let count = [3, 4, 5].contains(storedCount) ? storedCount : 4
        let values = [
            defaults.object(forKey: LowPolyCamPreferences.Key.zoomButton1) as? NSNumber,
            defaults.object(forKey: LowPolyCamPreferences.Key.zoomButton2) as? NSNumber,
            defaults.object(forKey: LowPolyCamPreferences.Key.zoomButton3) as? NSNumber,
            defaults.object(forKey: LowPolyCamPreferences.Key.zoomButton4) as? NSNumber,
            defaults.object(forKey: LowPolyCamPreferences.Key.zoomButton5) as? NSNumber
        ].prefix(count).compactMap { $0?.doubleValue }
        var validated = ZoomShortcutPolicy.validated(values)
        for fallback in ZoomShortcutPolicy.defaultValues + [8.0] where validated.count < count {
            guard !validated.contains(where: { abs($0 - fallback) < 0.0001 }) else { continue }
            validated.append(fallback)
        }
        return validated.isEmpty ? Array(ZoomShortcutPolicy.defaultValues.prefix(count)) : Array(validated.prefix(count))
    }

    func resetTemporaryCameraControls() {
        AppEventLog.event("Quick camera reset requested", category: .session, fields: [
            "exposureBiasBefore": String(format: "%.2f", exposureBias),
            "zoomBefore": String(format: "%.2f", Double(zoomFactor)),
            "whiteBalanceBefore": requestedWhiteBalancePreset.rawValue,
            "torchBefore": String(isTorchOn)
        ])
        setExposureBias(0)
        setZoomFactor(1)
        setCustomWhiteBalance(
            temperature: WhiteBalancePreferencePolicy.defaultTemperature,
            tint: 0
        )
        sessionQueue.async { [weak self] in
            guard let self else { return }
            self.resetFocusAndExposureState()
            self.setTorchEnabledOnCurrentDevice(false)
            self.postStatus("Temporary camera controls reset")
        }
    }

    func makeCameraPreset(named name: String) -> CameraPreset {
        CameraPreset(
            name: name,
            captureMode: captureMode.rawValue,
            videoResolution: selectedResolution.rawValue,
            videoFrameRate: selectedFrameRate.rawValue,
            slowMotionResolution: selectedSlowMotionResolution.rawValue,
            slowMotionFrameRate: selectedSlowMotionFrameRate.rawValue,
            codec: selectedVideoCodec,
            videoCompressionMode: videoCompressionMode.rawValue,
            videoCompressionLevel: videoCompression.rawValue,
            videoManualBitrateMbps: videoManualBitrateMbps,
            slowMotionCompressionMode: slowMotionCompressionMode.rawValue,
            slowMotionCompressionLevel: slowMotionCompression.rawValue,
            slowMotionManualBitrateMbps: slowMotionManualBitrateMbps,
            zoom: Double(requestedZoom),
            stabilization: isVideoStabilizationEnabled,
            whiteBalance: requestedWhiteBalancePreset.rawValue,
            customWhiteBalanceTemperature: customWhiteBalanceTemperature,
            customWhiteBalanceTint: customWhiteBalanceTint,
            cameraPosition: cameraPosition.rawValue
        )
    }

    func applyCameraPreset(_ preset: CameraPreset, completion: ((Bool) -> Void)? = nil) {
        let migrated = preset.migrated()
        guard !isRecording, !isRecordingStarting, !isFinalizingRecording,
              !isCapturingPhoto, !isLensTransitioning else {
            completion?(false)
            return
        }
        let targetPosition = CameraPosition(rawValue: migrated.cameraPosition) ?? cameraPosition
        if targetPosition != cameraPosition {
            switchCamera()
            sessionQueue.asyncAfter(deadline: .now() + 0.6) { [weak self] in
                self?.applyCameraPresetOnSessionQueue(migrated, completion: completion)
            }
        } else {
            sessionQueue.async { [weak self] in
                self?.applyCameraPresetOnSessionQueue(migrated, completion: completion)
            }
        }
    }

    func applyCameraPresetOnSessionQueue(_ preset: CameraPreset, completion: ((Bool) -> Void)?) {
        guard cameraPosition.rawValue == preset.cameraPosition || preset.cameraPosition.isEmpty else {
            completion?(false)
            return
        }
        guard let targetMode = CaptureMode(rawValue: preset.captureMode) else {
            completion?(false)
            return
        }

        invalidatePendingVideoConfiguration()
        lensTransitionCoordinator.cancel()
        _ = qualityRequests.next(reason: "custom camera preset")
        _ = captureConfigurationGeneration.next(reason: "custom camera preset")
        let previousSuppression = suppressAutomaticReconfiguration
        let previousPersistenceSuppression = suppressPreferencePersistence
        suppressAutomaticReconfiguration = true
        suppressPreferencePersistence = true
        captureMode = targetMode
        selectedResolution = VideoResolution(rawValue: preset.videoResolution) ?? .p1080
        selectedFrameRate = VideoFrameRate(rawValue: preset.videoFrameRate) ?? .fps60
        selectedSlowMotionResolution = VideoResolution(rawValue: preset.slowMotionResolution) ?? .p1080
        selectedSlowMotionFrameRate = SlowMotionFrameRate(rawValue: preset.slowMotionFrameRate) ?? .fps240
        selectedVideoCodec = preset.codec == "H264" ? "H264" : "HEVC"
        videoCompressionMode = CompressionMode(rawValue: preset.videoCompressionMode) ?? .auto
        videoCompression = VideoCompression(rawValue: preset.videoCompressionLevel) ?? .high
        videoManualBitrateMbps = ManualBitratePolicy.validatedMbps(preset.videoManualBitrateMbps)
        slowMotionCompressionMode = CompressionMode(rawValue: preset.slowMotionCompressionMode) ?? .auto
        slowMotionCompression = VideoCompression(rawValue: preset.slowMotionCompressionLevel) ?? .high
        slowMotionManualBitrateMbps = ManualBitratePolicy.validatedMbps(preset.slowMotionManualBitrateMbps)
        isVideoStabilizationEnabled = preset.stabilization
        customWhiteBalanceTemperature = WhiteBalancePreferencePolicy.validatedTemperature(preset.customWhiteBalanceTemperature)
        customWhiteBalanceTint = WhiteBalancePreferencePolicy.validatedTint(preset.customWhiteBalanceTint)
        requestedWhiteBalancePreset = WhiteBalancePreset(rawValue: preset.whiteBalance) ?? .auto
        whiteBalancePreset = requestedWhiteBalancePreset
        requestedZoom = CGFloat(preset.zoom.isFinite ? max(preset.zoom, 0.5) : 1)
        suppressAutomaticReconfiguration = previousSuppression
        suppressPreferencePersistence = previousPersistenceSuppression

        let defaults = UserDefaults.standard
        defaults.set(videoCompressionMode.rawValue, forKey: LowPolyCamPreferences.Key.videoCompressionMode)
        defaults.set(videoCompression.rawValue, forKey: LowPolyCamPreferences.Key.videoCompression)
        defaults.set(videoManualBitrateMbps, forKey: LowPolyCamPreferences.Key.videoManualBitrateMbps)
        defaults.set(slowMotionCompressionMode.rawValue, forKey: LowPolyCamPreferences.Key.slowMotionCompressionMode)
        defaults.set(slowMotionCompression.rawValue, forKey: LowPolyCamPreferences.Key.slowMotionCompressionLevel)
        defaults.set(slowMotionManualBitrateMbps, forKey: LowPolyCamPreferences.Key.slowMotionManualBitrateMbps)
        defaults.set(selectedVideoCodec, forKey: LowPolyCamPreferences.Key.selectedVideoCodec)
        defaults.set(isVideoStabilizationEnabled, forKey: LowPolyCamPreferences.Key.videoStabilizationEnabled)
        defaults.set(requestedWhiteBalancePreset.rawValue, forKey: LowPolyCamPreferences.Key.whiteBalancePreset)
        defaults.set(customWhiteBalanceTemperature, forKey: LowPolyCamPreferences.Key.customWhiteBalanceTemperature)
        defaults.set(customWhiteBalanceTint, forKey: LowPolyCamPreferences.Key.customWhiteBalanceTint)
        persistCameraPreferences()

        let success = applyActiveModeFormat(preferVirtualCamera: !requiresPhysicalWhiteBalanceInput)
        if success {
            synchronizeTorchState()
            synchronizeWhiteBalanceAfterConfiguration()
            persistRememberedCameraSetup()
            AppEventLog.event("Custom camera preset applied", category: .settings, fields: [
                "name": preset.name, "mode": preset.captureMode, "position": preset.cameraPosition
            ])
        } else {
            AppEventLog.event("Custom camera preset failed to apply", category: .settings, level: .warning, fields: [
                "name": preset.name, "mode": preset.captureMode, "position": preset.cameraPosition
            ])
        }
        publish { completion?(success) }
    }

    func prepareMicrophoneAndBeginRecording() {
        guard recordingState.requestsRecording else { return }
        let requestID = microphonePermissionRequests.next(reason: "prepare microphone for recording")
        let authorization = AVCaptureDevice.authorizationStatus(for: .audio)
        AppEventLog.deepEvent("MICROPHONE PREPARATION", category: .audio, traceID: activeRecordingTraceID, fields: [
            "requestID": String(requestID), "authorization": String(authorization.rawValue),
            "audioInputAttached": String(audioInput != nil)
        ])

        if authorization == .notDetermined {
            awaitingMicrophonePermission = true
            microphonePermissionPromptLifecyclePending = true
            publishAudioStatus()
            AppEventLog.event("Microphone permission requested lazily before recording")
            AVCaptureDevice.requestAccess(for: .audio) { [weak self] granted in
                self?.sessionQueue.async { [weak self] in
                    self?.finishMicrophonePermission(
                        granted: granted,
                        requestID: requestID
                    )
                }
            }
            return
        }

        let attached = authorization == .authorized && attachAudioInputIfAuthorized()
        publishAudioStatus()
        AppEventLog.event(
            "Microphone authorization before recording: state=\(authorization.rawValue), attached=\(attached)"
        )
        if authorization != .authorized {
            postStatus("Recording without audio · microphone access is off")
        } else if !attached {
            postStatus("Microphone unavailable · recording without audio")
        }
        beginRecording()
    }

    func finishMicrophonePermission(granted: Bool, requestID: UInt64) {
        guard microphonePermissionRequests.isLatest(requestID),
              awaitingMicrophonePermission,
              recordingState.requestsRecording,
              appLifecyclePhase == .active,
              session.isRunning,
              captureMode == .video || captureMode == .sloMo else {
            AppEventLog.event("Stale microphone permission completion dropped: granted=\(granted)")
            return
        }

        awaitingMicrophonePermission = false

        // Keep the lifecycle suppression armed briefly after the permission callback because
        // iOS may enqueue the permission sheet's .inactive notification after this callback.
        // If no lifecycle bounce arrives, expire the guard so an unrelated later inactive event
        // is never suppressed.
        let permissionLifecycleRequestID = requestID
        sessionQueue.asyncAfter(deadline: .now() + 1.0) { [weak self] in
            guard let self,
                  self.microphonePermissionPromptLifecyclePending,
                  self.microphonePermissionRequests.isLatest(permissionLifecycleRequestID) else { return }
            self.microphonePermissionPromptLifecyclePending = false
            AppEventLog.deepEvent("MICROPHONE PERMISSION LIFECYCLE GUARD EXPIRED", category: .audio, fields: [
                "requestID": String(permissionLifecycleRequestID)
            ])
        }

        let attached = granted && attachAudioInputIfAuthorized()
        publishAudioStatus()
        AppEventLog.event("Microphone permission result: granted=\(granted), audioInputAttached=\(attached)")
        if !granted {
            postStatus("Microphone access denied · recording without audio")
        } else if !attached {
            postStatus("Microphone unavailable · recording without audio")
        }
        beginRecording()
    }

    func startOrStopRecording() {
        guard captureMode == .video || captureMode == .sloMo else {
            AppEventLog.guardRejected("startOrStopRecording", reason: "capture mode is not recordable", fields: ["mode": captureMode.rawValue])
            return
        }
        let queueTicket = AppEventLog.queueScheduled("record button action", category: .recording, traceID: activeRecordingTraceID)
        sessionQueue.async { [weak self] in
            AppEventLog.queueStarted(queueTicket)
            guard let self else { return }
            guard !self.recordingState.isFinalizing else {
                AppEventLog.guardRejected("startOrStopRecording", reason: "recording is finalizing", traceID: self.activeRecordingTraceID)
                return
            }

            if self.recordingState.requestsRecording {
                AppEventLog.event("Recording stop requested", category: .recording, traceID: self.activeRecordingTraceID,
                                  fields: ["movieOutputRecording": String(self.movieOutput.isRecording),
                                           "state": String(describing: self.recordingState)])
                self.requestNativeRecordingStop(reason: "user requested recording stop")
                let wasWaitingForMicrophone = self.awaitingMicrophonePermission
                _ = self.recordingStartRequests.next(reason: "user requested recording stop")
                _ = self.microphonePermissionRequests.next(reason: "recording stop invalidates microphone request")
                self.awaitingMicrophonePermission = false
                self.microphonePermissionPromptLifecyclePending = false
                self.storageGuard.stopMonitoring()
                self.stopLiveMetrics()
                self.cancelSplitTimer()

                if self.movieOutput.isRecording {
                    self.transitionRecordingState(to: .finalizing, resetClock: true)
                    self.postStatus("Saving to Photos…")
                    self.movieOutput.stopRecording()
                } else if wasWaitingForMicrophone {
                    self.transitionRecordingState(to: .idle, resetClock: true)
                    self.closeRecordingDiagnostics(reason: "cancelled while waiting for microphone", result: "cancelled")
                } else {
                    // A second tap arrived while AVCaptureMovieFileOutput was still starting.
                    // If didStart arrives later, stop and discard that canceled startup clip.
                    self.transitionRecordingToDiscard(resetClock: true)
                }
                return
            }

            guard !self.isCapturingPhoto, !self.lensTransitionCoordinator.hasActiveTransition else {
                AppEventLog.guardRejected("recording start", reason: "camera busy", fields: [
                    "capturingPhoto": String(self.isCapturingPhoto),
                    "lensTransition": String(self.lensTransitionCoordinator.hasActiveTransition)
                ])
                return
            }
            self.resetNativeRecordingPauseState(reason: "new recording session")
            self.activeRecordingTraceID = AppEventLog.makeTraceID("RECORD")
            self.activeRecordingSessionID = UUID().uuidString
            self.recordingRequestStartedAt = ProcessInfo.processInfo.systemUptime
            self.recordingSegmentIndex = 1
            self.lastExtremeRecordingHealthSecond = -1
            let traceID = self.activeRecordingTraceID
            AppEventLog.event("========== RECORDING START REQUEST =========", category: .recording, traceID: traceID, fields: [
                "mode": self.captureMode.rawValue,
                "resolution": self.hudResolutionLabel,
                "fps": self.hudFrameRateLabel ?? "unknown",
                "codec": self.activeVideoCodec,
                "compression": self.compressionDescription(for: self.captureMode),
                "camera": self.cameraPosition.rawValue,
                "device": self.videoInput?.device.localizedName ?? "none",
                "requestedZoom": String(format: "%.3f", self.requestedZoom)
            ])
            let splitDuration = Double(UserDefaults.standard.integer(forKey: "splitMinutes")) * 60
            self.storageProtectionStopIssued = false
            self.transitionRecordingState(
                to: .starting(splitDuration: splitDuration),
                resetClock: true,
                clearLastFrameGaps: true
            )
            self.prepareMicrophoneAndBeginRecording()
        }
    }

    func applyQuickPreset(_ preset: VideoQuickPreset, completion: ((Bool) -> Void)? = nil) {
        guard captureMode == .video, !isRecording, !isRecordingStarting, !isCapturingPhoto, !isLensTransitioning else {
            AppEventLog.event("Quick preset ignored: \(preset.rawValue), camera busy or not in Video mode")
            completion?(false)
            return
        }

        AppEventLog.event("Quick preset requested: \(preset.rawValue), \(preset.resolution.rawValue) \(preset.frameRate.rawValue) fps, codec=HEVC, compression=\(preset.compression.rawValue)")

        sessionQueue.async { [weak self] in
            guard let self else { return }
            self.invalidatePendingVideoConfiguration()
            self.lensTransitionCoordinator.cancel()
            let devices = self.capabilityDevices(for: self.cameraPosition.avPosition)
            let presetSelector = CameraFormatSelector(
                selectedVideoCodec: "HEVC",
                selectedResolution: preset.resolution,
                selectedFrameRate: preset.frameRate
            )
            let supported = devices.contains { device in
                presetSelector.preferredRecordingFormat(
                    for: device,
                    resolution: preset.resolution,
                    rate: preset.frameRate
                ) != nil
            }
            let hevcAvailable = self.movieOutput.connection(with: .video).map {
                self.movieOutputSupportsCodec(.hevc, on: $0)
            } ?? false
            guard supported && hevcAvailable else {
                let message = hevcAvailable
                    ? "This preset isn’t supported by the current camera."
                    : "HEVC is unavailable for the current camera configuration."
                self.publish { self.codecAvailabilityMessage = message }
                self.showError(message)
                self.publish { completion?(false) }
                return
            }

            _ = self.qualityRequests.next()
            _ = self.captureConfigurationGeneration.next()

            self.publish {
                self.suppressPreferencePersistence = true
                self.suppressAutomaticReconfiguration = true
                self.selectedResolution = preset.resolution
                self.selectedFrameRate = preset.frameRate
                self.videoCompressionMode = .auto
                self.videoCompression = preset.compression
                self.selectedVideoCodec = "HEVC"
                self.suppressPreferencePersistence = false
                self.suppressAutomaticReconfiguration = false
                self.persistCameraPreferences()

                self.sessionQueue.async {
                    let success = self.applySelectedFormat(
                        preferVirtualCamera: !self.requiresPhysicalWhiteBalanceInput
                    )
                    AppEventLog.event("Quick preset \(success ? "applied" : "failed"): \(preset.rawValue)")
                    self.publish { completion?(success) }
                }
            }
        }
    }

    func makeAuthorizedAudioInput() -> AVCaptureDeviceInput? {
        guard AVCaptureDevice.authorizationStatus(for: .audio) == .authorized,
              let audioDevice = AVCaptureDevice.default(for: .audio) else { return nil }
        return try? AVCaptureDeviceInput(device: audioDevice)
    }

    func currentAudioStatusLabel() -> String {
        if audioInput != nil { return "Microphone" }
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .notDetermined: return "Checking microphone"
        case .denied, .restricted: return "Microphone off"
        case .authorized: return "Microphone unavailable"
        @unknown default: return "Microphone unavailable"
        }
    }

    func publishAudioStatus() {
        let label = currentAudioStatusLabel()
        publish {
            guard self.audioStatusLabel != label else { return }
            self.audioStatusLabel = label
            if label != "Microphone" {
                AppEventLog.event("Audio unavailable state: \(label)", category: .audio)
            }
        }
    }

    /// Called only on sessionQueue. Lazy microphone permission can grant audio after the initial
    /// camera session has already been built, so the input can be attached in a small transaction.
    @discardableResult
    func attachAudioInputIfAuthorized() -> Bool {
        guard AVCaptureDevice.authorizationStatus(for: .audio) == .authorized else {
            publishAudioStatus()
            return false
        }
        if let existingAudioInput = audioInput,
           session.inputs.contains(where: { $0 === existingAudioInput }) {
            configureAudioMeterOutput()
            publishAudioStatus()
            return true
        }
        guard let newInput = makeAuthorizedAudioInput(), session.canAddInput(newInput) else {
            AppEventLog.event("Microphone audio input attach failed: unavailable or session rejected input")
            publishAudioStatus()
            return false
        }
        session.beginConfiguration()
        session.addInput(newInput)
        session.commitConfiguration()
        audioInput = newInput
        configureAudioMeterOutput()
        AppEventLog.event("Microphone audio input attached: \(newInput.device.localizedName)")
        publishAudioStatus()
        return true
    }

    func audioMeterOutputIsAttached() -> Bool {
        session.outputs.contains { $0 === audioMeter.output }
    }

    func audioMeterShouldBeEnabled() -> Bool {
        audioMeterOutputIsAttached() &&
            audioInput != nil &&
            captureMode != .photo &&
            audioLevelMeterMode != .off &&
            recordingState.requestsRecording &&
            movieOutput.isRecording
    }

    /// The audio-data output is optional and disabled outside an active recording. It reads the
    /// same authorized microphone input as the movie output and never creates a parallel recorder.
    func configureAudioMeterOutput() {
        let optionalOutputsAllowed = postPreviewOutputsEnabled || recordingState.requestsRecording || movieOutput.isRecording
        let wanted = optionalOutputsAllowed && audioInput != nil && captureMode != .photo && audioLevelMeterMode != .off
        let attached = audioMeterOutputIsAttached()
        if wanted != attached {
            session.beginConfiguration()
            if wanted, session.canAddOutput(audioMeter.output) {
                if audioMeter.output.isDeferredStartSupported {
                    audioMeter.output.isDeferredStartEnabled = true
                }
                session.addOutput(audioMeter.output)
            } else if !wanted, attached {
                audioMeter.setEnabled(false)
                session.removeOutput(audioMeter.output)
            }
            session.commitConfiguration()
        }
        let available = audioMeterOutputIsAttached()
        let enabled = available && audioMeterShouldBeEnabled()
        audioMeter.output.connection(with: .audio)?.isEnabled = enabled
        audioMeter.setEnabled(enabled)
        AppEventLog.deepEvent("AUDIO LEVEL METER OUTPUT", category: .audio, fields: [
            "wanted": String(wanted), "attached": String(available), "enabled": String(enabled)
        ])
    }
}
