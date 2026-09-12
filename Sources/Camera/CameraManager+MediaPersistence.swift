import AVFoundation
import Combine
import Foundation
import Photos
import UIKit

// MARK: - CameraManager: Recovery, Photos persistence, background-save protection, finalization, status and errors.

extension CameraManager {
    func refreshRecoveryCount() {
        // Recovery enumeration is filesystem I/O. Keep it off the serialized camera queue so a
        // large Recovery folder can never delay zoom, recording, or session configuration.
        storageQueue.async { [weak self] in
            guard let self else { return }
            let recordings = CameraRecoveryStore.recordings()
            let photos = CameraRecoveryStore.photoRecoveryFiles()
            self.publish {
                self.recoverableRecordingCount = recordings.count
                self.recoverableRecordingFiles = recordings
                self.recoverablePhotoCount = photos.count
                self.recoverablePhotoFiles = photos
            }
        }
    }

    func retryRecoverableRecordings() {
        sessionQueue.async { [weak self] in
            guard let self else { return }
            let files = CameraRecoveryStore.recordings()
            guard !files.isEmpty else {
                self.refreshRecoveryCount()
                return
            }

            var accepted = 0
            for file in files {
                if self.saveVideoResourceToPhotos(file, runDiagnostics: false, recoveryRetry: true) {
                    accepted += 1
                }
            }

            if accepted > 0 {
                self.postStatus("Retrying \(accepted) recovered recording\(accepted == 1 ? "" : "s")…")
            } else {
                self.postStatus("Recovery save already in progress…")
            }
        }
    }

    @discardableResult
    func savePhotoFileToPhotos(_ fileURL: URL, recoveryRetry: Bool = true) -> Bool {
        let sourceKey = fileURL.standardizedFileURL
        guard inFlightPhotoFileSaves.insert(sourceKey).inserted else { return false }
        pendingPhotoSaves += 1
        beginBackgroundMediaSaveIfNeeded()

        storageQueue.async { [weak self] in
            guard let self else { return }
            let validation = MediaValidator.validatePhotoFile(at: fileURL)
            self.sessionQueue.async { [weak self] in
                guard let self,
                      self.inFlightPhotoFileSaves.contains(sourceKey) else { return }
                AppEventLog.event(
                    "RECOVERY PHOTO MEDIA VALIDATION",
                    category: .save,
                    level: validation.isValid ? .info : .error,
                    fields: validation.fields.merging([
                        "valid": String(validation.isValid),
                        "summary": validation.summary
                    ]) { current, _ in current }
                )
                guard validation.isValid else {
                    self.showError("A Recovery photo is not readable and was left in Recovery.")
                    self.inFlightPhotoFileSaves.remove(sourceKey)
                    self.pendingPhotoSaves = max(self.pendingPhotoSaves - 1, 0)
                    self.refreshRecoveryCount()
                    self.endBackgroundMediaSaveIfPossible()
                    return
                }

                PHPhotoLibrary.shared().performChanges({
                    let request = PHAssetCreationRequest.forAsset()
                    let options = PHAssetResourceCreationOptions()
                    options.originalFilename = fileURL.lastPathComponent
                    options.shouldMoveFile = true
                    request.addResource(with: .photo, fileURL: fileURL, options: options)
                }) { [weak self] success, error in
                    guard let self else { return }
                    self.sessionQueue.async {
                        if success {
                            self.postStatus(recoveryRetry ? "Recovered photo saved to Photos" : "Photo saved to Photos")
                            AppEventLog.event("Recovery photo saved to Photos: \(fileURL.lastPathComponent)", category: .save)
                        } else {
                            let detail = error?.localizedDescription ?? "Unknown Photos error"
                            self.showError("Couldn’t save the Recovery photo. It remains in Recovery. \(detail)")
                            AppEventLog.event("Recovery photo save failed: \(detail)", category: .save, level: .error)
                        }
                        self.inFlightPhotoFileSaves.remove(sourceKey)
                        self.pendingPhotoSaves = max(self.pendingPhotoSaves - 1, 0)
                        self.refreshRecoveryCount()
                        self.refreshAvailableStorage()
                        self.endBackgroundMediaSaveIfPossible()
                    }
                }
            }
        }
        return true
    }

    func retryRecoverablePhotos() {
        sessionQueue.async { [weak self] in
            guard let self else { return }
            let files = CameraRecoveryStore.photoRecoveryFiles()
            guard !files.isEmpty else {
                self.refreshRecoveryCount()
                return
            }

            var accepted = 0
            for file in files {
                if self.savePhotoFileToPhotos(file) {
                    accepted += 1
                }
            }
            if accepted > 0 {
                self.postStatus("Retrying \(accepted) recovered photo\(accepted == 1 ? "" : "s")…")
            } else {
                self.postStatus("Recovery photo save already in progress…")
            }
        }
    }

    func deleteAllRecoveryFiles() {
        sessionQueue.async { [weak self] in
            guard let self else { return }
            guard self.inFlightVideoSaves.isEmpty, self.inFlightPhotoFileSaves.isEmpty else {
                self.postStatus("Wait for the current Recovery save to finish.")
                return
            }
            CameraRecoveryStore.removeAll()
            self.refreshRecoveryCount()
        }
    }

    func deleteRecoveryFile(_ fileURL: URL) {
        sessionQueue.async { [weak self] in
            guard let self else { return }
            let sourceKey = fileURL.standardizedFileURL
            guard !self.inFlightVideoSaves.contains(sourceKey), !self.inFlightPhotoFileSaves.contains(sourceKey) else {
                self.postStatus("Wait for the current Recovery save to finish.")
                return
            }
            guard CameraRecoveryStore.delete(fileURL) else {
                self.showError("Couldn’t delete that Recovery file.")
                return
            }
            self.refreshRecoveryCount()
            self.refreshAvailableStorage()
        }
    }

    var hasPendingMediaSaves: Bool {
        pendingVideoSaves > 0 || pendingPhotoSaves > 0
    }

    func beginBackgroundMediaSaveIfNeeded() {
        guard hasPendingMediaSaves else { return }
        let requestID = mediaSaveTaskRequests.next()
        DispatchQueue.main.async { [weak self] in
            guard let self,
                  self.mediaSaveTaskRequests.isLatest(requestID),
                  self.backgroundSaveTask == .invalid else { return }
            self.backgroundSaveTask = UIApplication.shared.beginBackgroundTask(withName: "Finish camera media save") { [weak self] in
                guard let self, self.backgroundSaveTask != .invalid else { return }
                let task = self.backgroundSaveTask
                self.backgroundSaveTask = .invalid
                self.mediaSaveTaskRequests.next()
                UIApplication.shared.endBackgroundTask(task)
                self.sessionQueue.async {
                    AppEventLog.event(
                        "Background media-save task expired: pendingVideoSaves=\(self.pendingVideoSaves), " +
                        "pendingPhotoSaves=\(self.pendingPhotoSaves)"
                    )
                }
            }
            AppEventLog.event("Background media-save task started")
        }
    }

    func endBackgroundMediaSaveIfPossible() {
        guard !hasPendingMediaSaves else { return }
        let requestID = mediaSaveTaskRequests.next()
        DispatchQueue.main.async { [weak self] in
            guard let self,
                  self.mediaSaveTaskRequests.isLatest(requestID),
                  self.backgroundSaveTask != .invalid else { return }
            let task = self.backgroundSaveTask
            self.backgroundSaveTask = .invalid
            UIApplication.shared.endBackgroundTask(task)
            AppEventLog.event("Background media-save task ended")
        }
    }

    func finishFinalizingIfPossible() {
        guard pendingVideoSaves == 0 else { return }
        closeRecordingDiagnostics(reason: "finalization complete", result: "success")
        transitionRecordingState(to: .idle, resetClock: true)
        storageProtectionStopIssued = false
        endBackgroundMediaSaveIfPossible()
    }

    func closeRecordingDiagnostics(reason: String, result: String) {
        guard let traceID = activeRecordingTraceID else {
            activeRecordingSessionID = nil
            return
        }
        AppEventLog.event("========== RECORDING TRACE END =========", category: .recording,
                          level: result == "success" ? .info : .warning, traceID: traceID, fields: [
                            "reason": reason,
                            "result": result,
                            "segments": String(recordingSegmentIndex),
                            "lifetimeMs": recordingRequestStartedAt > 0
                                ? String(format: "%.2f", (ProcessInfo.processInfo.systemUptime - recordingRequestStartedAt) * 1000)
                                : "unknown"
                          ])
        activeRecordingTraceID = nil
        activeRecordingSessionID = nil
        recordingRequestStartedAt = 0
        movieStartCallAt = 0
        recordingSegmentIndex = 0
        lastExtremeRecordingHealthSecond = -1
    }

    func restoreIdleCaptureConfigurationAfterRecording() {
        guard !movieOutput.isRecording else { return }
        switch captureMode {
        case .video:
            if !activeVideoFormatMatchesSelection() {
                _ = applySelectedFormat(
                    preferVirtualCamera: !requiresPhysicalWhiteBalanceInput
                )
            }
        case .sloMo:
            if !activeSlowMotionFormatMatchesSelection() {
                _ = applySlowMotionFormat()
            }
        case .photo:
            break
        }
    }

    func finishVideoSaveValidationFailure(
        fileURL: URL,
        sourceKey: URL,
        reason: String,
        recoveryRetry: Bool
    ) {
        let preserved = CameraRecoveryStore.preserve(fileURL)
        if preserved != nil {
            showError("The recording failed media validation and was kept in Recovery. \(reason)")
        } else {
            showError("The recording failed media validation and could not be preserved. \(reason)")
        }
        AppEventLog.event("Video media validation rejected save", category: .save, level: .error, fields: [
            "file": fileURL.lastPathComponent,
            "reason": reason,
            "recoveryRetry": String(recoveryRetry),
            "preserved": String(preserved != nil)
        ])
        inFlightVideoSaves.remove(sourceKey)
        pendingVideoSaves = max(pendingVideoSaves - 1, 0)
        refreshRecoveryCount()
        refreshAvailableStorage()
        if recordingState.isFinalizing {
            finishFinalizingIfPossible()
        } else {
            endBackgroundMediaSaveIfPossible()
        }
    }

    @discardableResult
    func saveVideoResourceToPhotos(
        _ fileURL: URL,
        runDiagnostics: Bool,
        recoveryRetry: Bool = false
    ) -> Bool {
        let sourceKey = fileURL.standardizedFileURL
        guard inFlightVideoSaves.insert(sourceKey).inserted else { return false }

        pendingVideoSaves += 1
        beginBackgroundMediaSaveIfNeeded()

        let performSave: (Int?) -> Void = { [weak self] gaps in
            guard let self else { return }
            PHPhotoLibrary.shared().performChanges({
                let request = PHAssetCreationRequest.forAsset()
                let options = PHAssetResourceCreationOptions()
                options.originalFilename = fileURL.lastPathComponent
                options.shouldMoveFile = true
                request.addResource(with: .video, fileURL: fileURL, options: options)
            }) { [weak self] success, error in
                guard let self else { return }
                self.sessionQueue.async {
                    if success {
                        if let gaps {
                            self.publish { self.lastFrameGaps = gaps }
                        }
                        self.postStatus(recoveryRetry ? "Recovered recording saved to Photos" : "Saved to Photos")
                        AppEventLog.event("Video saved to Photos: \(fileURL.lastPathComponent)")
                    } else {
                        let preserved = CameraRecoveryStore.preserve(fileURL)
                        let detail = error?.localizedDescription ?? "Unknown Photos error"
                        if preserved != nil {
                            self.showError("Couldn’t save to Photos. The recording is kept in Recovery. \(detail)")
                        } else {
                            self.showError("Couldn’t save to Photos, and Recovery preservation could not be confirmed. \(detail)")
                        }
                        AppEventLog.event("Video save failed: \(detail)")
                    }

                    self.inFlightVideoSaves.remove(sourceKey)
                    self.pendingVideoSaves = max(self.pendingVideoSaves - 1, 0)
                    self.refreshRecoveryCount()
                    self.refreshAvailableStorage()
                    if self.recordingState.isFinalizing {
                        self.finishFinalizingIfPossible()
                    } else {
                        self.endBackgroundMediaSaveIfPossible()
                    }
                }
            }
        }

        let validateAndSave: (Int?) -> Void = { [weak self] gaps in
            guard let self else { return }
            self.storageQueue.async { [weak self] in
                guard let self else { return }
                let validation = MediaValidator.validateVideo(at: fileURL)
                self.sessionQueue.async { [weak self] in
                    guard let self,
                          self.inFlightVideoSaves.contains(sourceKey) else { return }
                    AppEventLog.event(
                        "VIDEO MEDIA VALIDATION",
                        category: .save,
                        level: validation.isValid ? .info : .error,
                        fields: validation.fields.merging([
                            "valid": String(validation.isValid),
                            "summary": validation.summary
                        ]) { current, _ in current }
                    )
                    guard validation.isValid else {
                        self.finishVideoSaveValidationFailure(
                            fileURL: fileURL,
                            sourceKey: sourceKey,
                            reason: validation.summary,
                            recoveryRetry: recoveryRetry
                        )
                        return
                    }
                    performSave(gaps)
                }
            }
        }

        if runDiagnostics {
            ClipFrameDiagnostics.inspect(fileURL) { gaps in
                validateAndSave(gaps)
            }
        } else {
            validateAndSave(nil)
        }
        return true
    }

    func postStatus(_ message: String) {
        AppEventLog.event("STATUS: \(message)")
        publish {
            self.statusMessageID &+= 1
            self.statusMessage = message
        }
    }

    func clearStatus(id: UInt64) {
        publish {
            guard self.statusMessageID == id else { return }
            self.statusMessage = nil
        }
    }

    func showError(_ message: String) {
        AppEventLog.event("ERROR: \(message)", category: .error, level: .error, traceID: activeRecordingTraceID, fields: [
            "mode": captureMode.rawValue,
            "camera": cameraPosition.rawValue,
            "recordingState": String(describing: recordingState),
            "sessionRunning": String(session.isRunning),
            "sessionInterrupted": String(session.isInterrupted),
            "requestedZoom": String(format: "%.3f", requestedZoom),
            "device": videoInput?.device.localizedName ?? "none"
        ])
        if AppEventLog.extremeDiagnosticsEnabled {
            sessionQueue.async { [weak self] in
                guard let self else { return }
                self.logCaptureConfiguration("automatic error context", label: "ERROR CAPTURE READBACK")
                self.logSessionSnapshot("automatic error context: \(message)")
            }
        }
        postStatus(message)
    }
}
