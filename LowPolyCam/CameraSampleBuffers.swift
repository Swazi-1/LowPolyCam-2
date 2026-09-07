//
//  CameraSampleBuffers.swift
//  LowPolyCam
//
//  Updated for iOS 27 / Xcode 27 / Swift 6.4.
//  Swift 6 complete concurrency · Observation · Liquid Glass · RotationCoordinator
//

import AVFoundation
import UIKit
import Photos
import MediaPlayer
import CoreMotion
import AudioToolbox
import ImageIO
import CoreImage
import VideoToolbox

extension CameraRecorder: AVCaptureVideoDataOutputSampleBufferDelegate, AVCaptureAudioDataOutputSampleBufferDelegate {

    private struct CaptureWriterSnapshot {
        let writer: AVAssetWriter?
        let videoInput: AVAssetWriterInput?
        let audioInput: AVAssetWriterInput?
        let segmentStart: CMTime
        let draining: Bool
        let shouldFinalizeAfterAppend: Bool
        let needsNewSegment: Bool
        let needsRotate: Bool
    }

    func captureOutput(_ output: AVCaptureOutput,
                       didOutput sampleBuffer: CMSampleBuffer,
                       from connection: AVCaptureConnection) {
        if consumePreviewReadinessSampleIfNeeded(output: output, sampleBuffer: sampleBuffer) {
            return
        }

        // Hard stop only after drain finished.
        guard !stopRequested, CMSampleBufferDataIsReady(sampleBuffer) else { return }

        let isVideo = (output === videoOutput)
        let pts = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
        guard let snapshot = prepareCaptureWriterSnapshot(isVideo: isVideo, pts: pts) else { return }

        if isVideo,
           consumeVideoSampleBeforeAppendIfNeeded(sampleBuffer,
                                                  pts: pts,
                                                  snapshot: snapshot) {
            return
        }

        guard let currentWriter = snapshot.writer,
              currentWriter.status == .writing,
              snapshot.segmentStart.isValid,
              CMTimeCompare(pts, snapshot.segmentStart) >= 0 else {
            handleUnavailableWriter(snapshot.writer)
            return
        }

        if isVideo {
            appendVideoCaptureBatch(sampleBuffer, snapshot: snapshot)
        } else if snapshot.audioInput?.isReadyForMoreMediaData == true {
            snapshot.audioInput?.append(sampleBuffer)
        }
    }

    private func consumePreviewReadinessSampleIfNeeded(output: AVCaptureOutput,
                                                       sampleBuffer: CMSampleBuffer) -> Bool {
        guard output === videoOutput,
              previewReadyCompletion != nil,
              let expected = previewExpectedDimensions,
              let description = CMSampleBufferGetFormatDescription(sampleBuffer) else {
            return false
        }

        let received = CMVideoFormatDescriptionGetDimensions(description)
        if received.width == expected.width && received.height == expected.height {
            finishPreviewReadiness(success: true)
        }
        return true
    }

    private func prepareCaptureWriterSnapshot(isVideo: Bool,
                                              pts: CMTime) -> CaptureWriterSnapshot? {
        writerLock.lock()
        var currentlyWants = wantsRecording
        var shouldFinalizeAfterAppend = false
        let draining = isStopDraining

        if draining {
            currentlyWants = true
            if isVideo && CACurrentMediaTime() >= stopDrainDeadlineHost {
                shouldFinalizeAfterAppend = true
            }
        }

        if !currentlyWants {
            let hasWriter = writer != nil
            writerLock.unlock()
            if hasWriter {
                DebugLog.write("finishSegment triggered from didOutput (wantsRecording=false, writer still present)")
                finishSegment()
            }
            return nil
        }

        // Silently discard the first few video frames after a fresh record
        // start — AE/AGC brightness ramp. Counter lives under writerLock.
        if isVideo && pendingWarmupFrames > 0 {
            pendingWarmupFrames -= 1
            writerLock.unlock()
            return nil
        }

        var needsNewSegment = false
        var needsRotate = false
        if isVideo {
            needsNewSegment = (writer == nil) && !segmentStartInFlight
            if writer != nil, let splitLimit = plan?.splitInterval.seconds, segmentStart.isValid {
                let duration = CMTimeGetSeconds(CMTimeSubtract(pts, segmentStart))
                needsRotate = duration >= splitLimit
            }
            if needsNewSegment { segmentStartInFlight = true }
        }

        let snapshot = CaptureWriterSnapshot(
            writer: writer,
            videoInput: videoIn,
            audioInput: audioIn,
            segmentStart: segmentStart,
            draining: draining,
            shouldFinalizeAfterAppend: shouldFinalizeAfterAppend,
            needsNewSegment: needsNewSegment,
            needsRotate: needsRotate
        )
        writerLock.unlock()
        return snapshot
    }

    private func consumeVideoSampleBeforeAppendIfNeeded(_ sampleBuffer: CMSampleBuffer,
                                                        pts: CMTime,
                                                        snapshot: CaptureWriterSnapshot) -> Bool {
        if snapshot.needsNewSegment {
            DebugLog.write("first video frame arrived, dispatching startSegment to ioQueue")
            ioQueue.async { [weak self] in
                self?.startSegment(at: pts, firstSampleBuffer: sampleBuffer)
            }
            return true
        }

        if snapshot.needsRotate {
            ioQueue.async { [weak self] in
                self?.rotateSegment(at: pts, firstSampleBuffer: sampleBuffer)
            }
            return true
        }

        guard snapshot.writer == nil else { return false }

        writerLock.lock()
        var droppedForStats = false
        if segmentStartInFlight {
            // At 120/240fps, retain only the newest pending frame. At lower
            // rates keep the existing bounded startup queue.
            let highFPS = (plan?.frameRate ?? 30) >= 120
            if highFPS {
                pendingStartBuffers.removeAll(keepingCapacity: true)
                pendingStartBuffers.append(sampleBuffer)
            } else if pendingStartBuffers.count < Self.pendingStartBufferLimit {
                pendingStartBuffers.append(sampleBuffer)
            } else {
                droppedFrameCount += 1
                droppedForStats = true
            }
        }
        writerLock.unlock()

        if droppedForStats { statsTracker.recordDroppedFrame() }
        return true
    }

    private func handleUnavailableWriter(_ currentWriter: AVAssetWriter?) {
        guard let currentWriter, currentWriter.status == .failed else { return }
        let reason = currentWriter.error?.localizedDescription ?? "unknown encoder failure"
        DebugLog.write("❌ writer failed during capture: \(reason)")
        Task { @MainActor in
            if self.isRecording {
                self.stopRecording(notice: "Encoder stopped · Clip could not continue")
            }
        }
    }

    private func appendVideoCaptureBatch(_ sampleBuffer: CMSampleBuffer,
                                         snapshot: CaptureWriterSnapshot) {
        let targetFPS = plan?.frameRate ?? 30

        // Drain older frames before the current frame so AVAssetWriter always
        // receives non-decreasing timestamps.
        writerLock.lock()
        var orderedBatch = pendingMidBuffers
        pendingMidBuffers.removeAll(keepingCapacity: true)
        if snapshot.draining {
            orderedBatch.append(contentsOf: pendingStopBuffers)
            pendingStopBuffers.removeAll(keepingCapacity: true)
        }
        writerLock.unlock()
        orderedBatch.append(sampleBuffer)

        var firstUnwrittenIndex: Int?
        var appendedEndPTS: CMTime?
        var droppedInBatch = 0

        for index in orderedBatch.indices {
            let buffer = orderedBatch[index]
            guard let input = snapshot.videoInput, input.isReadyForMoreMediaData else {
                firstUnwrittenIndex = index
                break
            }

            if appendVideoSample(buffer, to: input) {
                let bufferPTS = CMSampleBufferGetPresentationTimeStamp(buffer)
                let bufferDuration = CMSampleBufferGetDuration(buffer)
                appendedEndPTS = Self.endPTS(for: bufferPTS,
                                             duration: bufferDuration,
                                             fps: targetFPS)
                statsTracker.recordAppendedFrame(at: bufferPTS)
            } else {
                droppedInBatch += 1
            }
        }

        if let firstUnwrittenIndex {
            let unwritten = Array(orderedBatch[firstUnwrittenIndex...])
            writerLock.lock()
            if snapshot.draining {
                pendingStopBuffers.append(contentsOf: unwritten)
                let overflow = max(0, pendingStopBuffers.count - Self.pendingStopBufferLimit)
                if overflow > 0 {
                    pendingStopBuffers.removeLast(overflow)
                    droppedInBatch += overflow
                }
            } else {
                pendingMidBuffers.append(contentsOf: unwritten)
                let limit = RecordingLimits.backpressureFrameLimit(fps: targetFPS)
                let overflow = max(0, pendingMidBuffers.count - limit)
                if overflow > 0 {
                    pendingMidBuffers.removeLast(overflow)
                    droppedInBatch += overflow
                }
            }
            writerLock.unlock()
        }

        writerLock.lock()
        if let appendedEndPTS { lastVideoPTS = appendedEndPTS }
        if droppedInBatch > 0 { droppedFrameCount += droppedInBatch }
        writerLock.unlock()

        if droppedInBatch > 0 {
            statsTracker.recordDroppedFrame(count: droppedInBatch)
        }

        if snapshot.shouldFinalizeAfterAppend {
            DebugLog.write("[stop] drain deadline reached in didOutput, finalizing")
            completeStopDrainIfNeeded(force: false)
        }
        if !snapshot.draining {
            pushElapsed(CMSampleBufferGetPresentationTimeStamp(sampleBuffer))
        }
    }

    func captureOutput(_ output: AVCaptureOutput,
                       didDrop sampleBuffer: CMSampleBuffer,
                       from connection: AVCaptureConnection) {
        writerLock.lock()
        let currentlyWants = wantsRecording
        writerLock.unlock()
        guard output === videoOutput, currentlyWants else { return }
        countDroppedFrame()
    }

    func countDroppedFrame() {
        writerLock.lock()
        droppedFrameCount += 1
        writerLock.unlock()
        statsTracker.recordDroppedFrame() // 📊 no lock shared with writerLock
    }

    /// End timestamp for a written frame. Prefer the buffer's own duration;
    /// if it's invalid (common on some A10 paths), fall back to 1/fps so
    /// endSession does not undershoot and Photos duration stays consistent
    /// with frame count.

    /// Append a camera frame. Matching formats stay on the zero-copy sample
    /// path; lower tiers use VideoToolbox's hardware scaler and retain their
    /// exact selected dimensions in the saved movie.
    @discardableResult
    func appendVideoSample(_ sampleBuffer: CMSampleBuffer, to input: AVAssetWriterInput?) -> Bool {
        guard let input = input, input.isReadyForMoreMediaData else { return false }
        guard let plan = plan,
              let sourceBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else {
            return input.append(sampleBuffer)
        }

        let sourceWidth = CVPixelBufferGetWidth(sourceBuffer)
        let sourceHeight = CVPixelBufferGetHeight(sourceBuffer)
        guard sourceWidth != plan.width || sourceHeight != plan.height else {
            return input.append(sampleBuffer)
        }

        guard let adaptor = pixelBufferAdaptor,
              let pool = scalePixelBufferPool else {
            DebugLog.write("❌ missing scaler for \(sourceWidth)x\(sourceHeight) → \(plan.width)x\(plan.height)")
            return false
        }

        var scaledBuffer: CVPixelBuffer?
        guard CVPixelBufferPoolCreatePixelBuffer(kCFAllocatorDefault, pool, &scaledBuffer) == kCVReturnSuccess,
              let destinationBuffer = scaledBuffer else {
            DebugLog.write("⚠️ scaler output pool exhausted")
            return false
        }

        // Core Image scaling is hardware-backed on the supported device and
        // keeps the low-resolution recording path independent of newer APIs.
        let sourceImage = CIImage(cvPixelBuffer: sourceBuffer)
        let scaleX = CGFloat(plan.width) / CGFloat(sourceWidth)
        let scaleY = CGFloat(plan.height) / CGFloat(sourceHeight)
        let scale = max(scaleX, scaleY)
        let scaledImage = sourceImage
            .transformed(by: CGAffineTransform(scaleX: scale, y: scale))
            .transformed(by: CGAffineTransform(
                translationX: (CGFloat(plan.width) - CGFloat(sourceWidth) * scale) / 2,
                y: (CGFloat(plan.height) - CGFloat(sourceHeight) * scale) / 2))
        scaleContext.render(scaledImage, to: destinationBuffer)

        return adaptor.append(destinationBuffer, withPresentationTime: CMSampleBufferGetPresentationTimeStamp(sampleBuffer))
    }

    static func endPTS(for pts: CMTime, duration: CMTime, fps: Int) -> CMTime {
        if duration.isValid && duration.isNumeric && duration.seconds > 0 {
            return CMTimeAdd(pts, duration)
        }
        let safeFPS = max(fps, 1)
        let oneFrame = CMTime(value: 1, timescale: CMTimeScale(safeFPS))
        return CMTimeAdd(pts, oneFrame)
    }

    func pushElapsed(_ pts: CMTime) {
        writerLock.lock()
        let start = recordStartPTS
        writerLock.unlock()
        guard start.isValid else { return }
        if lastElapsedPush.isValid,
           CMTimeGetSeconds(CMTimeSubtract(pts, lastElapsedPush)) < 0.25 { return }
        lastElapsedPush = pts

        if freeBytesSnapshot <= Self.reserveBytes {
            Task { @MainActor in
                self.stopRecording(notice: "Storage full · Recording stopped")
            }
            return
        }

        let seconds = CMTimeGetSeconds(CMTimeSubtract(pts, start))
        writerLock.lock()
        let drops = droppedFrameCount
        let outputURL = writer?.outputURL // 📊 read-only, same lock writer already lives under
        writerLock.unlock()
        let level = currentAudioLevel()

        // 📊 Cheap: just a stat() call on the currently-open output file.
        // Same io cost class as the existing fileByteSize() helper used
        // elsewhere in the recording path (finishSegment).
        if let outputURL = outputURL {
            let bytes = (try? outputURL.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? 0
            statsTracker.sample(currentFileBytes: Int64(bytes))
        }
        let statsSnapshot = statsTracker.snapshot

        // Auto-stop when max duration is reached
        if let limit = self.settings.maxDuration.seconds, seconds >= limit {
            Task { @MainActor in
                self.elapsed = seconds
                self.stopRecording(notice: "Max duration reached · Recording stopped")
            }
            return
        }

        Task { @MainActor in
            self.elapsed = seconds
            if self.droppedFrames != drops { self.droppedFrames = drops }
            self.audioLevel = level
            self.recordingStats = statsSnapshot // 📊
        }
    }

    func currentAudioLevel() -> Float {
        guard let channel = audioOutput.connection(with: .audio)?.audioChannels.first else { return 0 }
        let db = channel.averagePowerLevel
        let normalized = (db + 50) / 50
        return Float(max(0, min(1, normalized)))
    }
}
