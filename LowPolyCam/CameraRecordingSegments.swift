import AVFoundation
import UIKit
import Photos
import MediaPlayer
import CoreMotion
import AudioToolbox
import ImageIO
import VideoToolbox

extension CameraRecorder {

    private struct SegmentWriterContext {
        let writer: AVAssetWriter
        let videoInput: AVAssetWriterInput
        let audioInput: AVAssetWriterInput?
        let adaptor: AVAssetWriterInputPixelBufferAdaptor
        let pixelBufferPool: CVPixelBufferPool
        let url: URL
    }

    func startSegment(at pts: CMTime, firstSampleBuffer: CMSampleBuffer? = nil) {
        DebugLog.write("[0] startSegment called at pts=\(CMTimeGetSeconds(pts)) plan=\(plan != nil) freeBytesSnapshot=\(freeBytesSnapshot)")
        guard let plan else {
            failSegmentStartNoPlan()
            return
        }
        guard freeBytesSnapshot > Self.reserveBytes else {
            failSegmentStartForStorage()
            return
        }

        do {
            let context = try createSegmentWriterContext(plan: plan,
                                                         firstSampleBuffer: firstSampleBuffer)
            try startAndPublishSegment(context,
                                       plan: plan,
                                       requestedPTS: pts,
                                       firstSampleBuffer: firstSampleBuffer)
        } catch {
            failSegmentStart(error)
        }
    }

    private func failSegmentStartNoPlan() {
        DebugLog.write("❌ no plan, bailing")
        writerLock.lock()
        segmentStartInFlight = false
        writerLock.unlock()
        abortRecordingStart(message: "Encoder setup failed")
    }

    private func failSegmentStartForStorage() {
        DebugLog.write("❌ storage guard failed: freeBytesSnapshot=\(freeBytesSnapshot) reserveBytes=\(Self.reserveBytes)")
        writerLock.lock()
        segmentStartInFlight = false
        pendingStartBuffers.removeAll(keepingCapacity: false)
        pendingMidBuffers.removeAll(keepingCapacity: false)
        wantsRecording = false
        writerLock.unlock()

        Task { @MainActor in
            self.isRecording = false
            self.notice = "Storage full · Recording stopped"
            UIApplication.shared.isIdleTimerDisabled = false
        }
        sessionQueue.async {
            self.videoOutput.setSampleBufferDelegate(nil, queue: nil)
            self.audioOutput.setSampleBufferDelegate(nil, queue: nil)
            self.videoOutput.alwaysDiscardsLateVideoFrames = RecordingLimits.discardsLateFrames(isRecording: false)
        }
    }

    private func createSegmentWriterContext(plan: EncodePlan,
                                            firstSampleBuffer: CMSampleBuffer?) throws -> SegmentWriterContext {
        let url = Self.newClipURL()
        DebugLog.write("[1] clip URL=\(url.lastPathComponent)")
        UserDefaults.standard.set(url.lastPathComponent, forKey: Self.inProgressKey)
        RecordingRecoveryJournal.record(url, destination: recordingDestination)

        let writer = try AVAssetWriter(outputURL: url, fileType: .mov)
        DebugLog.write("[2] AVAssetWriter created OK")
        writer.movieFragmentInterval = CMTime(seconds: Self.fragmentSeconds, preferredTimescale: 600)
        writer.metadata = Self.captureMetadataItems()

        let resolvedVideo = Encoder.videoSettings(for: plan, writer: writer)
        let videoSettings = resolvedVideo.settings
        self.plan = resolvedVideo.plan
        DebugLog.write("[3] video settings=\(videoSettings)")

        let sourceHint = firstSampleBuffer.flatMap { CMSampleBufferGetFormatDescription($0) }
        let videoInput = AVAssetWriterInput(mediaType: .video,
                                            outputSettings: videoSettings,
                                            sourceFormatHint: sourceHint)
        videoInput.expectsMediaDataInRealTime = true
        videoInput.performsMultiPassEncodingIfSupported = false
        videoInput.transform = clipTransform
        let canAddVideo = writer.canAdd(videoInput)
        DebugLog.write("[4] canAdd video input=\(canAddVideo)")
        guard canAddVideo else { throw RecorderError.cannotAddInput }
        writer.add(videoInput)
        DebugLog.write("[5] video input added")

        let pixelAttributes: [String: Any] = [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,
            kCVPixelBufferWidthKey as String: plan.width,
            kCVPixelBufferHeightKey as String: plan.height,
            kCVPixelBufferIOSurfacePropertiesKey as String: [String: Any]()
        ]
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: videoInput,
                                                           sourcePixelBufferAttributes: pixelAttributes)
        var pool: CVPixelBufferPool?
        let poolStatus = CVPixelBufferPoolCreate(kCFAllocatorDefault,
                                                 nil,
                                                 pixelAttributes as CFDictionary,
                                                 &pool)
        guard poolStatus == kCVReturnSuccess, let outputPool = pool else {
            throw RecorderError.cannotAddInput
        }
        // Preserve the original early publication of scaler objects. The writer
        // itself is still not published until startup frames have been flushed.
        pixelBufferAdaptor = adaptor
        scalePixelBufferPool = outputPool

        let audioInput = createSegmentAudioInputIfNeeded(plan: plan, writer: writer)

        DebugLog.write("[8] calling startWriting()...")
        guard writer.startWriting() else {
            DebugLog.write("❌ startWriting() returned FALSE. writer.error=\(writer.error?.localizedDescription ?? "nil") status=\(writer.status.rawValue)")
            throw writer.error ?? RecorderError.cannotAddInput
        }
        DebugLog.write("[8] startWriting() OK status=\(writer.status.rawValue)")

        return SegmentWriterContext(writer: writer,
                                    videoInput: videoInput,
                                    audioInput: audioInput,
                                    adaptor: adaptor,
                                    pixelBufferPool: outputPool,
                                    url: url)
    }

    private func createSegmentAudioInputIfNeeded(plan: EncodePlan,
                                                 writer: AVAssetWriter) -> AVAssetWriterInput? {
        guard plan.hasAudio,
              let settings = audioSettings(for: plan, writer: writer) else {
            DebugLog.write("[6] no audio (hasAudio=\(plan.hasAudio))")
            return nil
        }

        DebugLog.write("[6] audio settings=\(settings)")
        let input = AVAssetWriterInput(mediaType: .audio, outputSettings: settings)
        input.expectsMediaDataInRealTime = true
        if writer.canAdd(input) {
            writer.add(input)
            DebugLog.write("[7] audio input added")
            return input
        }
        DebugLog.write("[7] audio input REJECTED by canAdd")
        return nil
    }

    private func startAndPublishSegment(_ context: SegmentWriterContext,
                                        plan: EncodePlan,
                                        requestedPTS: CMTime,
                                        firstSampleBuffer: CMSampleBuffer?) throws {
        let highFPS = plan.frameRate >= 120
        let firstFrame = selectFirstSegmentFrame(firstSampleBuffer,
                                                 highFPS: highFPS)
        let startPTS = firstFrame.map { CMSampleBufferGetPresentationTimeStamp($0) } ?? requestedPTS
        context.writer.startSession(atSourceTime: startPTS)
        DebugLog.write("[9] startSession OK at pts=\(CMTimeGetSeconds(startPTS))")

        let firstAppend = try appendInitialSegmentFrame(firstFrame,
                                                        startPTS: startPTS,
                                                        plan: plan,
                                                        context: context)
        publishSegmentWriter(context,
                             plan: plan,
                             highFPS: highFPS,
                             startPTS: startPTS,
                             appendedFirstPTS: firstAppend.endPTS,
                             appendedFirstFrame: firstAppend.didAppend)
    }

    private func selectFirstSegmentFrame(_ firstSampleBuffer: CMSampleBuffer?,
                                         highFPS: Bool) -> CMSampleBuffer? {
        guard highFPS else { return firstSampleBuffer }
        writerLock.lock()
        let latest = pendingStartBuffers.last ?? firstSampleBuffer
        writerLock.unlock()
        return latest
    }

    private func appendInitialSegmentFrame(_ firstFrame: CMSampleBuffer?,
                                           startPTS: CMTime,
                                           plan: EncodePlan,
                                           context: SegmentWriterContext) throws -> (endPTS: CMTime, didAppend: Bool) {
        var endPTS = startPTS
        var didAppend = false
        if let firstFrame, context.videoInput.isReadyForMoreMediaData {
            if appendVideoSample(firstFrame, to: context.videoInput) {
                let duration = CMSampleBufferGetDuration(firstFrame)
                endPTS = Self.endPTS(for: startPTS, duration: duration, fps: plan.frameRate)
                didAppend = true
                DebugLog.write("[9b] first frame appended at segment start ✅")
            } else {
                DebugLog.write("⚠️ first frame append failed, status=\(context.writer.status.rawValue) error=\(context.writer.error?.localizedDescription ?? "nil")")
                if context.writer.status == .failed {
                    context.writer.cancelWriting()
                    throw context.writer.error ?? RecorderError.cannotAddInput
                }
            }
        } else {
            DebugLog.write("⚠️ no first sample buffer / input not ready yet, black-frame gap possible")
        }
        return (endPTS, didAppend)
    }

    private func publishSegmentWriter(_ context: SegmentWriterContext,
                                      plan: EncodePlan,
                                      highFPS: Bool,
                                      startPTS: CMTime,
                                      appendedFirstPTS: CMTime,
                                      appendedFirstFrame: Bool) {
        writerLock.lock()
        let buffered = pendingStartBuffers
        pendingStartBuffers.removeAll(keepingCapacity: true)
        pendingMidBuffers.removeAll(keepingCapacity: false)
        let isFirstSegment = !recordStartPTS.isValid
        if isFirstSegment, appendedFirstFrame {
            statsTracker.reset(targetFPS: Double(plan.frameRate))
            statsTracker.recordAppendedFrame(at: startPTS)
        }
        var endPTS = appendedFirstPTS
        if isFirstSegment { recordStartPTS = startPTS }

        if !highFPS {
            endPTS = flushStartupBuffers(buffered,
                                         after: startPTS,
                                         currentEndPTS: endPTS,
                                         plan: plan,
                                         videoInput: context.videoInput)
        }

        writer = context.writer
        videoIn = context.videoInput
        pixelBufferAdaptor = context.adaptor
        scalePixelBufferPool = context.pixelBufferPool
        audioIn = context.audioInput
        segmentStart = startPTS
        lastVideoPTS = endPTS
        segmentStartInFlight = false
        writerLock.unlock()

        Task { @MainActor in self.clipsThisSession += 1 }
        if highFPS {
            DebugLog.write("[10] segment fully started ✅ (high-fps: skipped \(buffered.count) stale buffered frames)")
        } else {
            DebugLog.write("[10] segment fully started ✅ (flushed \(buffered.count) buffered frames)")
        }
    }

    private func flushStartupBuffers(_ buffered: [CMSampleBuffer],
                                     after startPTS: CMTime,
                                     currentEndPTS: CMTime,
                                     plan: EncodePlan,
                                     videoInput: AVAssetWriterInput) -> CMTime {
        var endPTS = currentEndPTS
        for buffer in buffered {
            let pts = CMSampleBufferGetPresentationTimeStamp(buffer)
            if CMTimeCompare(pts, startPTS) <= 0 { continue }
            if videoInput.isReadyForMoreMediaData,
               appendVideoSample(buffer, to: videoInput) {
                let duration = CMSampleBufferGetDuration(buffer)
                endPTS = Self.endPTS(for: pts, duration: duration, fps: plan.frameRate)
                statsTracker.recordAppendedFrame(at: pts)
            }
        }
        return endPTS
    }

    private func failSegmentStart(_ error: Error) {
        DebugLog.write("❌ startSegment threw: \(error.localizedDescription) | full: \(error)")
        writerLock.lock()
        segmentStartInFlight = false
        pendingStartBuffers.removeAll(keepingCapacity: false)
        pendingMidBuffers.removeAll(keepingCapacity: false)
        writer = nil
        videoIn = nil
        audioIn = nil
        pixelBufferAdaptor = nil
        scalePixelBufferPool = nil
        wantsRecording = false
        writerLock.unlock()
        Task { @MainActor in
            self.isRecording = false
            self.notice = "Encoder error"
            UIApplication.shared.isIdleTimerDisabled = false
        }
        abortRecordingStart(message: "Encoder error")
    }

    /// Restores the idle capture graph if writer creation fails after sample
    /// delegates were attached. Without this, frames continued arriving forever
    /// and a second press could not reliably start a clean take.
    func abortRecordingStart(message: String) {
        stopRequested = true
        sessionQueue.async {
            self.videoOutput.setSampleBufferDelegate(nil, queue: nil)
            self.audioOutput.setSampleBufferDelegate(nil, queue: nil)
            self.videoOutput.alwaysDiscardsLateVideoFrames = RecordingLimits.discardsLateFrames(isRecording: false)
            self.applyActiveFormat(forRecording: false)
        }
        Task { @MainActor in
            self.isRecording = false
            self.isSaving = false
            self.notice = message
            UIApplication.shared.isIdleTimerDisabled = false
        }
    }


    private struct SegmentFinishContext {
        let writer: AVAssetWriter
        let videoInput: AVAssetWriterInput
        let audioInput: AVAssetWriterInput?
        let endPTS: CMTime
        let startPTS: CMTime
        let destination: SaveLocation
        let url: URL
        let hadFrames: Bool
    }

    private final class FinishOnceGate {
        private let lock = NSLock()
        private var didFinish = false

        func run(_ body: () -> Void) {
            lock.lock()
            guard !didFinish else {
                lock.unlock()
                return
            }
            didFinish = true
            lock.unlock()
            body()
        }
    }

    func finishSegment(_ completion: (() -> Void)? = nil) {
        DebugLog.write("[finish] finishSegment entered")
        guard let context = claimSegmentForFinish(completion: completion) else { return }

        guard context.writer.status == .writing else {
            let error = context.writer.error?.localizedDescription ?? "status=\(context.writer.status.rawValue)"
            if context.writer.status != .failed && context.writer.status != .cancelled {
                context.writer.cancelWriting()
            }
            failIncompleteSegment(context, reason: "writer not writing: \(error)", completion: completion)
            return
        }

        guard context.hadFrames else {
            DebugLog.write("⚠️ finishSegment: no video frames written")
            context.writer.cancelWriting()
            failIncompleteSegment(context, reason: "no frames", completion: completion)
            return
        }

        context.videoInput.markAsFinished()
        context.audioInput?.markAsFinished()
        context.writer.endSession(atSourceTime: context.endPTS)
        DebugLog.write("[finish] endSession done, calling finishWriting() status=\(context.writer.status.rawValue)")
        finishSegmentWriter(context, completion: completion)
    }

    private func claimSegmentForFinish(completion: (() -> Void)?) -> SegmentFinishContext? {
        writerLock.lock()
        guard let writer, let videoIn else {
            DebugLog.write("[finish] finishSegment called with no writer/videoIn — nothing to finalize")
            self.writer = nil
            self.videoIn = nil
            audioIn = nil
            pixelBufferAdaptor = nil
            scalePixelBufferPool = nil
            writerLock.unlock()
            completion?()
            return nil
        }

        let context = SegmentFinishContext(
            writer: writer,
            videoInput: videoIn,
            audioInput: audioIn,
            endPTS: lastVideoPTS,
            startPTS: segmentStart,
            destination: recordingDestination,
            url: writer.outputURL,
            hadFrames: lastVideoPTS.isValid && segmentStart.isValid &&
                CMTimeCompare(lastVideoPTS, segmentStart) > 0
        )

        self.writer = nil
        self.videoIn = nil
        audioIn = nil
        pixelBufferAdaptor = nil
        scalePixelBufferPool = nil
        segmentStart = .invalid
        lastVideoDuration = .invalid
        writerLock.unlock()
        return context
    }

    private func segmentFileByteSize(_ url: URL) -> Int {
        (try? url.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? 0
    }

    private func failIncompleteSegment(_ context: SegmentFinishContext,
                                       reason: String,
                                       completion: (() -> Void)?) {
        let bytes = segmentFileByteSize(context.url)
        DebugLog.write("❌ finishSegment \(reason) fileBytes=\(bytes) (incomplete — not sending to Photos)")
        RecordingRecoveryJournal.remove(context.url)
        try? FileManager.default.removeItem(at: context.url)
        Task { @MainActor in
            self.notice = "Clip failed to save"
            self.refreshFreeSpace()
        }
        completion?()
    }

    private func finishSegmentWriter(_ context: SegmentFinishContext,
                                     completion: (() -> Void)?) {
        let gate = FinishOnceGate()

        ioQueue.asyncAfter(deadline: .now() + 20.0) {
            gate.run {
                DebugLog.write("❌ finishWriting watchdog fired (no callback within 20s), status=\(context.writer.status.rawValue)")
                DebugLog.write("   fileBytes=\(self.segmentFileByteSize(context.url))")
                if context.writer.status == .writing || context.writer.status == .unknown {
                    context.writer.cancelWriting()
                }
                RecordingRecoveryJournal.remove(context.url)
                Task { @MainActor in
                    self.notice = "Recording interrupted · Local file retained"
                    self.refreshFreeSpace()
                }
                completion?()
            }
        }

        context.writer.finishWriting {
            gate.run {
                self.handleFinishedSegmentWriter(context, completion: completion)
            }
        }
    }

    private func handleFinishedSegmentWriter(_ context: SegmentFinishContext,
                                             completion: (() -> Void)?) {
        RecordingRecoveryJournal.remove(context.url)
        if context.writer.status == .completed {
            generateThumbnail(for: context.url)
            completion?()
            deliver(context.url, to: context.destination) {
                Task { @MainActor in self.refreshFreeSpace() }
            }
            return
        }

        let error = context.writer.error?.localizedDescription ?? "status=\(context.writer.status.rawValue)"
        let bytes = segmentFileByteSize(context.url)
        DebugLog.write("❌ finishWriting not completed: \(error) fileBytes=\(bytes)")
        try? FileManager.default.removeItem(at: context.url)
        Task { @MainActor in
            self.notice = "Clip failed to save"
            self.refreshFreeSpace()
        }
        completion?()
    }

    func rotateSegment(at pts: CMTime, firstSampleBuffer: CMSampleBuffer? = nil) {
        writerLock.lock()
        guard let oldWriter = writer, let oldVideoIn = videoIn else {
            writerLock.unlock()
            return
        }
        let oldAudioIn = audioIn
        let oldEnd = lastVideoPTS
        let oldStart = segmentStart
        let oldUrl = oldWriter.outputURL
        let destination = recordingDestination

        writer = nil; videoIn = nil; audioIn = nil; pixelBufferAdaptor = nil; scalePixelBufferPool = nil
        segmentStart = .invalid
        writerLock.unlock()

        if oldWriter.status == .writing {
            oldVideoIn.markAsFinished()
            oldAudioIn?.markAsFinished()
            if oldEnd.isValid, oldStart.isValid, CMTimeCompare(oldEnd, oldStart) > 0 {
                oldWriter.endSession(atSourceTime: oldEnd)
            }
            oldWriter.finishWriting {
                guard oldWriter.status == .completed else {
                    DebugLog.write("❌ rotated segment failed to finish: \(oldWriter.error?.localizedDescription ?? "status=\(oldWriter.status.rawValue)")")
                    try? FileManager.default.removeItem(at: oldUrl)
                    Task { @MainActor in
                        self.notice = "A video segment failed to save"
                        self.refreshFreeSpace()
                    }
                    return
                }
                RecordingRecoveryJournal.remove(oldUrl)
                self.generateThumbnail(for: oldUrl)
                // 📊 Keep average-bitrate math accurate across segment
                // rotation on long takes: fold the finished segment's bytes
                // in before the new segment's file starts growing from 0.
                let finishedBytes = (try? oldUrl.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? 0
                self.statsTracker.carryOverSegmentBytes(Int64(finishedBytes))
                self.deliver(oldUrl, to: destination) {
                    Task { @MainActor in self.refreshFreeSpace() }
                }
            }
        } else {
            DebugLog.write("❌ rotated segment was not writable: status=\(oldWriter.status.rawValue)")
            try? FileManager.default.removeItem(at: oldUrl)
        }

        startSegment(at: pts, firstSampleBuffer: firstSampleBuffer)
    }

    func audioSettings(for plan: EncodePlan, writer w: AVAssetWriter) -> [String: Any]? {

        func valid(_ s: [String: Any]) -> Bool {
            w.canApply(outputSettings: s, forMediaType: .audio)
        }

        if var s = audioOutput.recommendedAudioSettingsForAssetWriter(writingTo: .mov) {
            let recommended = s
            s[AVEncoderBitRateKey] = plan.audioBitrate
            if valid(s) { return s }
            if valid(recommended) { return recommended }
        }

        let fallback: [String: Any] = [
            AVFormatIDKey: kAudioFormatMPEG4AAC,
            AVNumberOfChannelsKey: 1,
            AVSampleRateKey: 44100,
            AVEncoderBitRateKey: plan.audioBitrate
        ]
        if valid(fallback) { return fallback }
        return nil
    }

    // MARK: Recovering interrupted recordings

}
