import AVFoundation
import Combine
import Foundation
import Photos
import UIKit

// MARK: - AVCapturePhotoCaptureDelegate

extension CameraManager: AVCapturePhotoCaptureDelegate {
    func photoOutput(_ output: AVCapturePhotoOutput, willBeginCaptureFor resolvedSettings: AVCaptureResolvedPhotoSettings) {
        let captureID = resolvedSettings.uniqueID
        sessionQueue.async {
            guard let context = self.photoCaptureContexts[captureID] else { return }
            AppEventLog.deepEvent("PHOTO willBeginCapture", category: context.isBurst ? .burst : .photo, traceID: context.traceID, fields: [
                "captureID": String(captureID),
                "elapsedMs": String(format: "%.2f", (ProcessInfo.processInfo.systemUptime - context.startedAt) * 1000)
            ])
        }
    }

    func photoOutput(_ output: AVCapturePhotoOutput, willCapturePhotoFor resolvedSettings: AVCaptureResolvedPhotoSettings) {
        let captureID = resolvedSettings.uniqueID
        sessionQueue.async {
            guard let context = self.photoCaptureContexts[captureID] else { return }
            AppEventLog.deepEvent("PHOTO willCapturePhoto", category: context.isBurst ? .burst : .photo, traceID: context.traceID, fields: [
                "captureID": String(captureID),
                "elapsedMs": String(format: "%.2f", (ProcessInfo.processInfo.systemUptime - context.startedAt) * 1000)
            ])
        }
    }

    func photoOutput(_ output: AVCapturePhotoOutput, didFinishProcessingPhoto photo: AVCapturePhoto, error: Error?) {
        let captureID = photo.resolvedSettings.uniqueID
        if let error {
            sessionQueue.async {
                let trace = self.photoCaptureContexts[captureID]?.traceID
                AppEventLog.log(error: error, prefix: "PHOTO PROCESSING CALLBACK FAILED", category: .photo, traceID: trace)
                self.photoProcessingFailedCaptureIDs.insert(captureID)
                if self.photoCaptureContexts[captureID]?.isBurst == true {
                    self.burstPipelineHadFailure = true
                    self.burstStopRequested = true
                    self.burstRemaining = 0
                }
            }
            showError(error.localizedDescription)
            return
        }
        guard let data = photo.fileDataRepresentation() else {
            sessionQueue.async {
                let trace = self.photoCaptureContexts[captureID]?.traceID
                AppEventLog.event("PHOTO FILE REPRESENTATION MISSING", category: .photo, level: .error, traceID: trace,
                                  fields: ["captureID": String(captureID)])
                self.photoProcessingFailedCaptureIDs.insert(captureID)
                if self.photoCaptureContexts[captureID]?.isBurst == true {
                    self.burstPipelineHadFailure = true
                    self.burstStopRequested = true
                    self.burstRemaining = 0
                }
            }
            showError("Couldn’t create the photo file.")
            return
        }

        sessionQueue.async { [weak self] in
            guard let self, let context = self.photoCaptureContexts[captureID] else { return }
            self.pendingPhotoSaves += 1
            self.beginBackgroundMediaSaveIfNeeded()
            let pixelWidth = photo.pixelBuffer.map { CVPixelBufferGetWidth($0) }
            let pixelHeight = photo.pixelBuffer.map { CVPixelBufferGetHeight($0) }
            let actualMP: String
            if let pixelWidth, let pixelHeight {
                actualMP = String(format: "%.2f", Double(pixelWidth * pixelHeight) / 1_000_000)
            } else {
                actualMP = "unknown"
            }
            AppEventLog.event("PHOTO PROCESSING CALLBACK", category: context.isBurst ? .burst : .photo, traceID: context.traceID, fields: [
                "captureID": String(captureID),
                "filename": context.filename,
                "fileBytes": String(data.count),
                "pixelDimensions": (pixelWidth != nil && pixelHeight != nil) ? "\(pixelWidth!)x\(pixelHeight!)" : "unknown",
                "actualMP": actualMP,
                "requestedMP": String(context.megapixels),
                "flashRequested": context.requestedFlash,
                "flashApplied": context.appliedFlash,
                "pendingPhotoSaves": String(self.pendingPhotoSaves),
                "hardwareToProcessedMs": String(format: "%.2f", (ProcessInfo.processInfo.systemUptime - context.startedAt) * 1000)
            ])
            if let pixelWidth, let pixelHeight {
                let actual = Double(pixelWidth * pixelHeight) / 1_000_000
                if actual + 0.6 < Double(context.megapixels) {
                    AppEventLog.invariant("PHOTO RESOLUTION LOWER THAN REQUESTED", expected: "~\(context.megapixels)MP", actual: String(format: "%.2fMP", actual),
                                          traceID: context.traceID, fields: ["dimensions": "\(pixelWidth)x\(pixelHeight)"])
                }
            }
            if !context.isBurst {
                self.postStatus("Photo captured · saving…")
            }

            let processingQueuedAt = ProcessInfo.processInfo.systemUptime
            self.storageQueue.async {
                let processingStartedAt = ProcessInfo.processInfo.systemUptime
                AppEventLog.deepEvent("PHOTO STORAGE QUEUE START", category: .photo, traceID: context.traceID,
                                      fields: ["queueWaitMs": String(format: "%.2f", (processingStartedAt - processingQueuedAt) * 1000)])
                guard let result = PhotoAspectProcessor.process(
                    data,
                    aspect: context.aspect,
                    megapixels: context.megapixels,
                    traceID: context.traceID
                ) else {
                    let preserved = CameraRecoveryStore.preservePhotoData(data, named: context.filename)
                    self.showError(
                        preserved == nil
                            ? "Couldn’t process the photo, and Recovery preservation could not be confirmed."
                            : "Couldn’t process the photo. The original is kept in Recovery."
                    )
                    AppEventLog.event("PHOTO PROCESSING VALIDATION FAILED", category: .save, level: .error, traceID: context.traceID,
                                      fields: ["filename": context.filename, "preserved": String(preserved != nil)])
                    self.completePhotoSave(captureID: captureID, context: context, success: false)
                    return
                }

                let validation = MediaValidator.validatePhoto(
                    data: result,
                    expectedAspect: context.aspect,
                    requestedMegapixels: context.megapixels
                )
                AppEventLog.event(
                    "PHOTO MEDIA VALIDATION",
                    category: .save,
                    level: validation.isValid ? .info : .error,
                    traceID: context.traceID,
                    fields: validation.fields.merging([
                        "valid": String(validation.isValid),
                        "summary": validation.summary,
                        "filename": context.filename
                    ]) { current, _ in current }
                )
                guard validation.isValid else {
                    let preserved = CameraRecoveryStore.preservePhotoData(result, named: context.filename)
                    self.showError(
                        preserved == nil
                            ? "The photo failed media validation, and Recovery preservation could not be confirmed."
                            : "The photo failed media validation. It is kept in Recovery."
                    )
                    self.completePhotoSave(captureID: captureID, context: context, success: false)
                    return
                }

                AppEventLog.deepEvent("PHOTOS SAVE REQUESTED", category: .save, traceID: context.traceID, fields: [
                    "filename": context.filename,
                    "bytes": String(result.count),
                    "elapsedMs": String(format: "%.2f", (ProcessInfo.processInfo.systemUptime - context.startedAt) * 1000)
                ])
                PHPhotoLibrary.shared().performChanges({
                    let request = PHAssetCreationRequest.forAsset()
                    let options = PHAssetResourceCreationOptions()
                    options.originalFilename = context.filename
                    request.addResource(with: .photo, data: result, options: options)
                }) { success, error in
                    if let error {
                        AppEventLog.log(error: error, prefix: "PHOTOS SAVE CALLBACK", category: .save, traceID: context.traceID)
                    }
                    AppEventLog.event("PHOTOS SAVE CALLBACK", category: .save, level: success ? .info : .error, traceID: context.traceID, fields: [
                        "success": String(success),
                        "filename": context.filename,
                        "totalMs": String(format: "%.2f", (ProcessInfo.processInfo.systemUptime - context.startedAt) * 1000)
                    ])
                    if !success {
                        let preserved = CameraRecoveryStore.preservePhotoData(result, named: context.filename)
                        let detail = error?.localizedDescription ?? "Couldn’t save the photo."
                        self.showError(
                            preserved == nil
                                ? "\(detail) Recovery preservation could not be confirmed."
                                : "\(detail) The photo is kept in Recovery."
                        )
                    }
                    self.completePhotoSave(captureID: captureID, context: context, success: success)
                }
            }
        }
    }

    func completePhotoSave(captureID: Int64, context: PhotoCaptureContext, success: Bool) {
        sessionQueue.async {
            self.photoCaptureContexts.removeValue(forKey: captureID)
            self.pendingPhotoSaves = max(0, self.pendingPhotoSaves - 1)
            AppEventLog.event("PHOTO PIPELINE COMPLETE", category: context.isBurst ? .burst : .photo,
                              level: success ? .info : .error, traceID: context.traceID, fields: [
                "success": String(success),
                "filename": context.filename,
                "burstOrdinal": context.burstOrdinal.map(String.init) ?? "none",
                "totalMs": String(format: "%.2f", (ProcessInfo.processInfo.systemUptime - context.startedAt) * 1000),
                "pendingPhotoSaves": String(self.pendingPhotoSaves)
            ])

            if !success {
                if context.isBurst {
                    self.burstPipelineHadFailure = true
                    self.burstStopRequested = true
                    self.burstRemaining = 0
                }
                AppEventLog.event("Photo save failed: \(context.filename)")
            } else if !context.isBurst {
                self.postStatus("Photo saved to Photos")
                AppEventLog.event("Photo saved to Photos: \(context.filename)")
            } else if self.pendingPhotoSaves == 0,
                      self.inFlightPhotoCaptureIDs.isEmpty,
                      self.burstRemaining == 0,
                      self.activeBurstTraceID == nil,
                      !self.burstPipelineHadFailure {
                self.postStatus("Photos saved to Photos")
            }

            if self.pendingPhotoSaves == 0 {
                self.refreshAvailableStorage()
                // A burst failure only suppresses the aggregate success message for the save
                // batch it belongs to. Once every pending save has settled, a future burst gets
                // a clean result state even if it starts before this callback finishes.
                self.burstPipelineHadFailure = false
            }
            self.refreshRecoveryCount()
            self.endBackgroundMediaSaveIfPossible()
        }
    }

    func photoOutput(_ output: AVCapturePhotoOutput, didFinishCaptureFor resolvedSettings: AVCaptureResolvedPhotoSettings, error: Error?) {
        let captureID = resolvedSettings.uniqueID
        sessionQueue.async {
            self.photoCaptureCoordinator.stopTracking(captureID)
            self.inFlightPhotoCaptureIDs.remove(captureID)
            if let interval = self.photoPerformanceIntervals.removeValue(forKey: captureID) {
                self.performanceMonitor.end(interval)
            }

            let context = self.photoCaptureContexts[captureID]
            let wasBurst = context?.isBurst ?? false
            let processingFailed = self.photoProcessingFailedCaptureIDs.remove(captureID) != nil

            if let context {
                AppEventLog.event("PHOTO HARDWARE CAPTURE COMPLETE", category: wasBurst ? .burst : .photo, traceID: context.traceID, fields: [
                    "captureID": String(captureID),
                    "elapsedMs": String(format: "%.2f", (ProcessInfo.processInfo.systemUptime - context.startedAt) * 1000),
                    "error": error?.localizedDescription ?? (processingFailed ? "processing failed" : "none"),
                    "inFlight": String(self.inFlightPhotoCaptureIDs.count),
                    "readiness": self.photoCaptureReadinessLabel(self.photoCaptureCoordinator.captureReadiness)
                ])
            }

            if let error {
                self.photoCaptureContexts.removeValue(forKey: captureID)
                if wasBurst {
                    self.burstPipelineHadFailure = true
                    self.burstStopRequested = true
                    self.burstRemaining = 0
                } else {
                    self.pendingSinglePhotoCapture = false
                }
                if let context {
                    AppEventLog.log(error: error, prefix: "PHOTO HARDWARE CAPTURE FAILED", category: wasBurst ? .burst : .photo, traceID: context.traceID)
                }
                self.showError("Photo capture failed: \(error.localizedDescription)")
            } else if processingFailed {
                // didFinishProcessingPhoto already surfaced the specific processing/file error.
                // Keep the hardware scheduler consistent and release the retained context here.
                self.photoCaptureContexts.removeValue(forKey: captureID)
                if wasBurst {
                    self.burstPipelineHadFailure = true
                    self.burstStopRequested = true
                    self.burstRemaining = 0
                } else {
                    self.pendingSinglePhotoCapture = false
                }
            } else if wasBurst, self.activeBurstTraceID != nil {
                self.burstCompletedCount += 1
            }

            if wasBurst {
                self.pumpPendingPhotoCaptures()
                if self.burstStopRequested, self.inFlightPhotoCaptureIDs.isEmpty {
                    self.finishBurstHardwareCapture()
                }
            } else {
                // The hardware capture is finished. Cropping, resizing and Photos-library
                // saving can continue on storageQueue without making the shutter feel stuck.
                self.publish { self.isCapturingPhoto = false }
                self.pumpPendingPhotoCaptures()
            }
        }
    }
}
