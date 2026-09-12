import AVFoundation
import Combine
import Foundation
import Photos
import UIKit

// MARK: - AVCaptureFileOutputRecordingDelegate

extension CameraManager: AVCaptureFileOutputRecordingDelegate {
    func fileOutput(_ output: AVCaptureFileOutput, didStartRecordingTo fileURL: URL, from connections: [AVCaptureConnection]) {
        sessionQueue.async { [weak self] in
            guard let self else { return }

            if !self.recordingState.requestsRecording {
                self.transitionRecordingToDiscard()
                if self.movieOutput.isRecording {
                    self.requestNativeRecordingStop(reason: "stale recording start callback")
                    self.movieOutput.stopRecording()
                }
                return
            }

            guard self.recordingPauseMachine.start() else {
                AppEventLog.guardRejected("didStartRecording", reason: "pause state machine was not idle", traceID: self.activeRecordingTraceID, fields: [
                    "pauseState": self.recordingPauseMachine.state.rawValue
                ])
                self.transitionRecordingToDiscard()
                self.requestNativeRecordingStop(reason: "pause state machine rejected recording start")
                self.movieOutput.stopRecording()
                return
            }
            self.publish { self.recordingPauseState = .recording }

            self.startLiveMetrics()
            self.configureAudioMeterOutput()
            let callbackAt = ProcessInfo.processInfo.systemUptime
            AppEventLog.event("RECORDING DID START CALLBACK", category: .recording, traceID: self.activeRecordingTraceID, fields: [
                "file": fileURL.lastPathComponent,
                "segment": String(self.recordingSegmentIndex),
                "startCallToCallbackMs": self.movieStartCallAt > 0 ? String(format: "%.2f", (callbackAt - self.movieStartCallAt) * 1000) : "unknown",
                "userRequestToCallbackMs": self.recordingRequestStartedAt > 0 ? String(format: "%.2f", (callbackAt - self.recordingRequestStartedAt) * 1000) : "unknown",
                "microphoneAuthorized": String(AVCaptureDevice.authorizationStatus(for: .audio).rawValue),
                "audioInputAttached": String(self.audioInput != nil)
            ])
            let splitDuration = self.recordingState.splitDuration

            self.transitionRecordingState(
                to: .recording(splitDuration: splitDuration),
                startClock: true
            )
            self.scheduleSplitTimer(splitDuration: splitDuration)

            // Validate and publish the recording state before collecting detailed diagnostics.
            // Snapshot formatting and disk I/O are handled asynchronously by AppEventLog.
            AppEventLog.event("Recording started: \(fileURL.lastPathComponent)", category: .recording, traceID: self.activeRecordingTraceID)
            self.logCaptureConfiguration(
                "delegate callback",
                label: "RECORDING START CALLBACK"
            )
            self.logSessionSnapshot("recording started")
        }
    }

    func fileOutput(_ output: AVCaptureFileOutput, didPauseRecordingTo fileURL: URL, from connections: [AVCaptureConnection]) {
        sessionQueue.async { [weak self] in
            self?.handleNativeRecordingPaused(output, fileURL: fileURL)
        }
    }

    func fileOutput(_ output: AVCaptureFileOutput, didResumeRecordingTo fileURL: URL, from connections: [AVCaptureConnection]) {
        sessionQueue.async { [weak self] in
            self?.handleNativeRecordingResumed(output, fileURL: fileURL)
        }
    }

    func fileOutput(_ output: AVCaptureFileOutput, didFinishRecordingTo outputFileURL: URL, from connections: [AVCaptureConnection], error: Error?) {
        let successful = error == nil || (error as NSError?)?.userInfo[AVErrorRecordingSuccessfullyFinishedKey] as? Bool == true

        sessionQueue.async { [weak self] in
            guard let self else { return }
            let errorDetail = error.map { " error=\($0.localizedDescription)" } ?? ""
            AppEventLog.event("RECORDING DID FINISH CALLBACK", category: .recording, level: successful ? .info : .warning,
                              traceID: self.activeRecordingTraceID, fields: [
                                "file": outputFileURL.lastPathComponent,
                                "success": String(successful),
                                "segment": String(self.recordingSegmentIndex),
                                "recordedDuration": String(format: "%.3f", self.movieOutput.recordedDuration.seconds),
                                "recordedBytes": String(self.movieOutput.recordedFileSize),
                                "error": error?.localizedDescription ?? "none"
                              ])
            AppEventLog.event("Recording finished: \(outputFileURL.lastPathComponent), success=\(successful)\(errorDetail)", category: .recording, traceID: self.activeRecordingTraceID)
            if let error { AppEventLog.log(error: error, prefix: "Recording delegate error", category: .recording, traceID: self.activeRecordingTraceID) }
            self.stopLiveMetrics()
            self.configureAudioMeterOutput()
            self.storageGuard.stopMonitoring()
            self.cancelSplitTimer()
            self.completeNativeRecordingStop(reason: "native recording finished")

            if self.recordingState.shouldDiscardWhenFinished {
                try? FileManager.default.removeItem(at: outputFileURL)
                self.transitionRecordingState(to: .idle, resetClock: true)
                self.storageProtectionStopIssued = false
                self.restoreIdleCaptureConfigurationAfterRecording()
                self.closeRecordingDiagnostics(reason: "recording discarded/cancelled", result: "cancelled")
                return
            }

            if successful, let sessionID = self.activeRecordingSessionID {
                let isSlowMotion = self.captureMode == .sloMo
                RecordingSessionStore.record(RecordingSessionSegment(
                    sessionID: sessionID,
                    segmentIndex: self.recordingSegmentIndex,
                    filename: outputFileURL.lastPathComponent,
                    mode: self.captureMode.rawValue,
                    cameraPosition: self.cameraPosition.rawValue,
                    resolution: (isSlowMotion ? self.selectedSlowMotionResolution : self.selectedResolution).rawValue,
                    frameRate: Double((isSlowMotion ? self.selectedSlowMotionFrameRate.rawValue : self.selectedFrameRate.rawValue)),
                    codec: self.activeVideoCodec,
                    compression: self.compressionDescription(for: self.captureMode),
                    duration: max(self.movieOutput.recordedDuration.seconds, 0),
                    recordedAt: Date()
                ))
            }

            let splitDuration = self.recordingState.splitDuration
            let shouldContinue = successful &&
                self.recordingState.requestsRecording &&
                self.recordingState.isContinuingSegment &&
                self.session.isRunning

            if !successful {
                let retained = CameraRecoveryStore.preserve(outputFileURL)
                self.refreshRecoveryCount()
                self.transitionRecordingState(to: .idle, resetClock: true)
                self.storageProtectionStopIssued = false
                self.restoreIdleCaptureConfigurationAfterRecording()
                let suffix = retained == nil ? "" : " It is kept in Recovery."
                self.showError("Recording stopped: \(error?.localizedDescription ?? "Unknown error").\(suffix)")
                self.closeRecordingDiagnostics(reason: "recording delegate failure", result: "failed")
                return
            }

            let diagnosticsEnabled = UserDefaults.standard.bool(forKey: "cameraHUDDroppedFrames")
            // Avoid decoding a completed split segment while the next HFR/4K segment is recording.
            self.saveVideoResourceToPhotos(
                outputFileURL,
                runDiagnostics: diagnosticsEnabled && !shouldContinue
            )

            if shouldContinue {
                self.recordingSegmentIndex += 1
                AppEventLog.event("RECORDING SPLIT CONTINUE", category: .recording, traceID: self.activeRecordingTraceID,
                                  fields: ["nextSegment": String(self.recordingSegmentIndex)])
                self.transitionRecordingState(to: .starting(splitDuration: splitDuration))
                self.beginRecording()
            } else {
                AppEventLog.event("========== RECORDING CAPTURE COMPLETE =========", category: .recording, traceID: self.activeRecordingTraceID,
                                  fields: ["segments": String(self.recordingSegmentIndex),
                                           "totalRequestLifetimeMs": self.recordingRequestStartedAt > 0 ? String(format: "%.2f", (ProcessInfo.processInfo.systemUptime - self.recordingRequestStartedAt) * 1000) : "unknown"])
                self.transitionRecordingState(to: .finalizing, resetClock: true)
                self.restoreIdleCaptureConfigurationAfterRecording()
                self.finishFinalizingIfPossible()
            }
        }
    }
}
