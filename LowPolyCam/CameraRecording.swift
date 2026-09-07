//
//  CameraRecording.swift
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
import VideoToolbox

enum CaptureFileNamer {
    private static let lock = NSLock()
    private static let sequenceKey = "nextIMGSequence"
    private static var scannedLibrary = false

    static func nextFileName(extension fileExtension: String) -> String {
        lock.lock()
        defer { lock.unlock() }

        var highest = max(0, UserDefaults.standard.integer(forKey: sequenceKey) - 1)

        func include(_ fileName: String) {
            let stem = URL(fileURLWithPath: fileName).deletingPathExtension().lastPathComponent.uppercased()
            guard stem.hasPrefix("IMG_") else { return }
            let digits = stem.dropFirst(4).prefix { $0.isNumber }
            if let value = Int(digits) { highest = max(highest, value) }
        }

        if let localFiles = try? FileManager.default.contentsOfDirectory(
            at: CameraRecorder.clipsDirectory,
            includingPropertiesForKeys: nil
        ) {
            localFiles.forEach { include($0.lastPathComponent) }
        }

        let photoStatus = PHPhotoLibrary.authorizationStatus(for: .readWrite)
        if !scannedLibrary && (photoStatus == .authorized || photoStatus == .limited) {
            scannedLibrary = true
            let assets = PHAsset.fetchAssets(with: nil)
            assets.enumerateObjects { asset, _, _ in
                PHAssetResource.assetResources(for: asset).forEach {
                    include($0.originalFilename)
                }
            }
        }

        let next = highest + 1
        UserDefaults.standard.set(next + 1, forKey: sequenceKey)
        return String(format: "IMG_%04d.%@", next, fileExtension.uppercased())
    }
}

extension CameraRecorder {

    // MARK: Recording control

    func toggleRecording() {
        (isRecording || isStartingRecording) ? stopRecording(notice: nil) : startRecording()
    }

    private struct RecordingStartRequest {
        let token: Int
        let initialPlan: EncodePlan
        let captureAngle: CGFloat
    }

    func startRecording() {
        guard canBeginRecording() else { return }
        if isBursting { cancelBurstCapture() }

        DebugLog.reset()
        DebugLog.write("===== startRecording() called =====")
        guard freeBytes > Self.reserveBytes else {
            DebugLog.write("❌ blocked: low storage, freeBytes=\(freeBytes)")
            notice = "Low storage · Free space needed"
            return
        }

        let request = prepareRecordingStartRequest()
        sessionQueue.async {
            self.configureRecordingStart(request)
        }
    }

    private func canBeginRecording() -> Bool {
        isSessionRunning && !isRecording && !isStartingRecording && !isSaving &&
            !isCapturingPhoto && !isBursting && !isSwitchingMode && !isSwitchingCamera
    }

    private func prepareRecordingStartRequest() -> RecordingStartRequest {
        if settings.saveLocation == .photos { ensurePhotosAccess() }
        isStartingRecording = true
        suppressVolumeTriggerBriefly(duration: 1.2)

        stopRequested = false
        resetPendingStopStateForNewRecording()
        recordingSessionToken += 1
        let token = recordingSessionToken

        configureRecordingSpaceTimer()
        let initialPlan = Encoder.plan(for: settings, isFrontCamera: isFrontCamera)
        resetRecordingPublishedState(initialFPS: initialPlan.frameRate)

        if settings.shutterSoundEnabled { SoundPlayer.play(.start) }
        return RecordingStartRequest(
            token: token,
            initialPlan: initialPlan,
            captureAngle: physicalOrientation.captureVideoRotationAngle
        )
    }

    private func resetPendingStopStateForNewRecording() {
        writerLock.lock()
        isStopDraining = false
        stopDrainDeadlineHost = 0
        pendingStopBuffers.removeAll(keepingCapacity: false)
        pendingStopToken = 0
        pendingStopBackgroundTask = .invalid
        writerLock.unlock()
    }

    private func configureRecordingSpaceTimer() {
        spaceTimer?.invalidate()
        spaceTimer = Timer.scheduledTimer(withTimeInterval: 5, repeats: true) { [weak self] _ in
            self?.refreshFreeSpace()
        }
        refreshFreeSpace()
    }

    private func resetRecordingPublishedState(initialFPS: Int) {
        notice = nil
        elapsed = 0
        clipsThisSession = 0
        droppedFrames = 0
        audioLevel = 0
        statsTracker.reset(targetFPS: Double(initialFPS))
        recordingStats = statsTracker.snapshot
    }

    private func configureRecordingStart(_ request: RecordingStartRequest) {
        guard recordingSessionToken == request.token, !stopRequested else { return }
        let formatChanged = applyActiveFormat(forRecording: true)
        guard recordingSessionToken == request.token, !stopRequested else { return }
        guard let device = cameraInput?.device else {
            Task { @MainActor in self.stopRecording(notice: "Camera unavailable") }
            return
        }

        guard let actualFPS = activeFrameRate(for: device) else {
            Task { @MainActor in self.stopRecording(notice: "Camera frame rate unavailable") }
            return
        }

        var plan = resolveRecordingPlan(initialPlan: request.initialPlan,
                                        device: device,
                                        actualFPS: actualFPS)
        plan.hasAudio = plan.hasAudio && micInput != nil
        applyStabilization(forceRecording: true)

        DebugLog.write("[plan] encode \(plan.width)x\(plan.height) @\(plan.frameRate)fps")
        let transform = Self.transform(width: plan.width,
                                       height: plan.height,
                                       isFront: isFrontCamera,
                                       mirrorFront: !settings.saveSelfiesUnmirrored,
                                       angle: request.captureAngle)

        publishRecordingDidStart(token: request.token)
        let beginCapture = makeBeginRecordingCapture(token: request.token,
                                                     plan: plan,
                                                     transform: transform,
                                                     formatChanged: formatChanged)
        if formatChanged {
            waitForExposureSettled(device: device, timeout: 0.22, completion: beginCapture)
        } else {
            beginCapture()
        }
    }

    private func activeFrameRate(for device: AVCaptureDevice) -> Int? {
        let duration = device.activeVideoMinFrameDuration.seconds
        guard duration.isFinite, duration > 0 else { return nil }
        return max(1, Int((1 / duration).rounded()))
    }

    private func resolveRecordingPlan(initialPlan: EncodePlan,
                                      device: AVCaptureDevice,
                                      actualFPS: Int) -> EncodePlan {
        var resolvedSlowResolution: Resolution?
        let sensorDimensions = CMVideoFormatDescriptionGetDimensions(device.activeFormat.formatDescription)
        if settings.cameraMode == .slowMo,
           Int(sensorDimensions.width) < initialPlan.width || Int(sensorDimensions.height) < initialPlan.height {
            resolvedSlowResolution = Resolution.allCases
                .filter {
                    $0 != .p2160 &&
                    $0.captureDimensions.w <= Int(sensorDimensions.width) &&
                    $0.captureDimensions.h <= Int(sensorDimensions.height)
                }
                .max {
                    $0.captureDimensions.w * $0.captureDimensions.h <
                    $1.captureDimensions.w * $1.captureDimensions.h
                }
            if let resolvedSlowResolution {
                Task { @MainActor in
                    self.settings.slowMoResolution = resolvedSlowResolution
                    self.notice = "Slow-Mo recording at \(resolvedSlowResolution.label)"
                }
            }
        }

        return Encoder.plan(for: settings,
                            fpsOverride: actualFPS,
                            resolutionOverride: resolvedSlowResolution,
                            isFrontCamera: isFrontCamera)
    }

    private func publishRecordingDidStart(token: Int) {
        Task { @MainActor in
            guard self.recordingSessionToken == token, !self.stopRequested else { return }
            self.isRecording = true
            self.isStartingRecording = false
            UIApplication.shared.isIdleTimerDisabled = true
            self.recordWallStart = Date()
            self.recordElapsedTimer?.invalidate()
            self.recordElapsedTimer = nil
        }
    }

    private func makeBeginRecordingCapture(token: Int,
                                           plan: EncodePlan,
                                           transform: CGAffineTransform,
                                           formatChanged: Bool) -> () -> Void {
        { [weak self] in
            guard let self,
                  self.recordingSessionToken == token,
                  !self.stopRequested else { return }

            self.videoOutput.alwaysDiscardsLateVideoFrames = RecordingLimits.discardsLateFrames(isRecording: true)
            self.videoOutput.setSampleBufferDelegate(self, queue: self.videoQueue)
            self.audioOutput.setSampleBufferDelegate(self, queue: self.audioQueue)

            self.ioQueue.async {
                guard self.recordingSessionToken == token, !self.stopRequested else { return }
                self.prepareWriterStateForIncomingSamples(plan: plan,
                                                          transform: transform,
                                                          formatChanged: formatChanged)
            }
        }
    }

    private func prepareWriterStateForIncomingSamples(plan: EncodePlan,
                                                      transform: CGAffineTransform,
                                                      formatChanged: Bool) {
        self.plan = plan
        recordingDestination = settings.saveLocation
        clipTransform = transform
        lastElapsedPush = .invalid
        droppedFrameCount = 0
        statsTracker.reset(targetFPS: Double(plan.frameRate))

        let warmup: Int
        if formatChanged {
            let fps = max(Double(plan.frameRate), 1)
            let rawWarmupFrames = Int((Self.recordStartWarmupSeconds * fps).rounded(.up))
            let ceiling = Self.recordStartWarmupFrameCeiling(fps: plan.frameRate)
            warmup = min(max(rawWarmupFrames, Self.recordStartWarmupFrameFloor), ceiling)
        } else {
            warmup = 0
        }

        writerLock.lock()
        recordStartPTS = .invalid
        segmentStartInFlight = false
        pendingStartBuffers.removeAll(keepingCapacity: true)
        pendingMidBuffers.removeAll(keepingCapacity: false)
        pendingWarmupFrames = warmup
        wantsRecording = true
        writerLock.unlock()
    }

    func stopRecording(notice message: String?) {
        guard isRecording || isStartingRecording else { return }
        if cancelPendingRecordingStartIfNeeded(message: message) { return }
        isStartingRecording = false

        let token = recordingSessionToken
        DebugLog.write("===== stopRecording() called token=\(token) =====")
        suppressVolumeTriggerBriefly(duration: 1.2)
        if settings.shutterSoundEnabled { SoundPlayer.play(.stop) }

        publishRecordingStopState(message: message)
        let backgroundTask = beginFinishClipBackgroundTask()
        beginStopDrain(token: token, backgroundTask: backgroundTask)
        scheduleStopDrainSafetyChecks(token: token)
    }

    private func cancelPendingRecordingStartIfNeeded(message: String?) -> Bool {
        guard isStartingRecording && !isRecording else { return false }
        recordingSessionToken += 1
        stopRequested = true
        isStartingRecording = false
        notice = message
        return true
    }

    private func publishRecordingStopState(message: String?) {
        isRecording = false
        isSaving = true
        recordElapsedTimer?.invalidate()
        recordElapsedTimer = nil
        recordWallStart = nil
        audioLevel = 0
        UIApplication.shared.isIdleTimerDisabled = false
        notice = message
        refreshFreeSpace()

        spaceTimer?.invalidate()
        spaceTimer = Timer.scheduledTimer(withTimeInterval: 20, repeats: true) { [weak self] _ in
            self?.refreshFreeSpace()
        }
    }

    private func beginFinishClipBackgroundTask() -> UIBackgroundTaskIdentifier {
        var task: UIBackgroundTaskIdentifier = .invalid
        task = UIApplication.shared.beginBackgroundTask(withName: "finishClip") {
            if task != .invalid {
                UIApplication.shared.endBackgroundTask(task)
                task = .invalid
            }
        }
        return task
    }

    private func beginStopDrain(token: Int,
                                backgroundTask: UIBackgroundTaskIdentifier) {
        let highFPS = (plan?.frameRate ?? 30) >= 120
        let drainWindow: CFTimeInterval = highFPS ? 0.15 : 0.25
        let hardCeiling: Double = highFPS ? 0.3 : 0.45
        DebugLog.write("[stop] draining token=\(token) drainWindow=\(drainWindow) hardCeiling=\(hardCeiling) highFPS=\(highFPS)")

        writerLock.lock()
        isStopDraining = true
        stopDrainDeadlineHost = CACurrentMediaTime() + drainWindow
        pendingStopBuffers.removeAll(keepingCapacity: true)
        pendingStopToken = token
        pendingStopBackgroundTask = backgroundTask
        writerLock.unlock()

        DispatchQueue.main.asyncAfter(deadline: .now() + hardCeiling) { [weak self] in
            DebugLog.write("[stop] hard ceiling reached token=\(token), forcing drain completion")
            self?.ioQueue.async {
                self?.completeStopDrainIfNeeded(force: true)
            }
        }
    }

    private func scheduleStopDrainSafetyChecks(token: Int) {
        DispatchQueue.main.asyncAfter(deadline: .now() + 4.0) { [weak self] in
            guard let self,
                  self.isSaving,
                  self.recordingSessionToken == token else { return }
            DebugLog.write("❌ stopRecording watchdog: isSaving still true 4s after Stop (token=\(token)) — force-recovering UI")
            self.notice = "Still finishing your recording…"
        }
    }

    /// Finalize the stop drain. `force` is used by the safety timeout.
    private struct StopDrainClaim {
        let token: Int
        let backgroundTask: UIBackgroundTaskIdentifier
        let bufferedSamples: [CMSampleBuffer]
        let videoInput: AVAssetWriterInput?
    }

    /// Finalize the stop drain. `force` is used by the safety timeout.
    func completeStopDrainIfNeeded(force: Bool = false) {
        guard let claim = claimStopDrain(force: force) else { return }
        stopRequested = true
        flushStopDrainSamples(claim)
        restoreIdleCaptureGraphAfterStop()
        finishClaimedStopDrain(claim)
    }

    private func claimStopDrain(force: Bool) -> StopDrainClaim? {
        writerLock.lock()
        let token = pendingStopToken
        let task = pendingStopBackgroundTask
        let pastDeadline = CACurrentMediaTime() >= stopDrainDeadlineHost
        guard token != 0,
              token == recordingSessionToken,
              force || pastDeadline else {
            let reason = token == 0
                ? "already claimed"
                : (token != recordingSessionToken ? "stale token" : "before deadline")
            writerLock.unlock()
            DebugLog.write("[stop] completeStopDrainIfNeeded skipped (\(reason)) force=\(force) token=\(token) currentToken=\(recordingSessionToken)")
            return nil
        }

        DebugLog.write("[stop] completeStopDrainIfNeeded firing force=\(force) token=\(token) bufferedStopFrames=\(pendingStopBuffers.count)")
        pendingStopToken = 0
        pendingStopBackgroundTask = .invalid
        isStopDraining = false
        wantsRecording = false
        stopDrainDeadlineHost = 0
        let buffered = pendingMidBuffers + pendingStopBuffers
        pendingStopBuffers.removeAll(keepingCapacity: false)
        pendingStartBuffers.removeAll(keepingCapacity: false)
        pendingMidBuffers.removeAll(keepingCapacity: false)
        let input = videoIn
        writerLock.unlock()

        return StopDrainClaim(token: token,
                              backgroundTask: task,
                              bufferedSamples: buffered,
                              videoInput: input)
    }

    private func flushStopDrainSamples(_ claim: StopDrainClaim) {
        guard let input = claim.videoInput else { return }
        for sample in claim.bufferedSamples where input.isReadyForMoreMediaData {
            guard appendVideoSample(sample, to: input) else { continue }
            let pts = CMSampleBufferGetPresentationTimeStamp(sample)
            let duration = CMSampleBufferGetDuration(sample)
            writerLock.lock()
            lastVideoPTS = Self.endPTS(for: pts,
                                       duration: duration,
                                       fps: plan?.frameRate ?? 30)
            writerLock.unlock()
            statsTracker.recordAppendedFrame(at: pts)
        }
    }

    private func restoreIdleCaptureGraphAfterStop() {
        sessionQueue.async {
            self.videoOutput.setSampleBufferDelegate(nil, queue: nil)
            self.audioOutput.setSampleBufferDelegate(nil, queue: nil)
            self.videoOutput.alwaysDiscardsLateVideoFrames = RecordingLimits.discardsLateFrames(isRecording: false)
            self.applyActiveFormat(forRecording: false)
            self.applyStabilization()
        }
    }

    private func finishClaimedStopDrain(_ claim: StopDrainClaim) {
        DebugLog.write("[stop] dispatching finishSegment to ioQueue token=\(claim.token)")
        ioQueue.async {
            var task = claim.backgroundTask
            guard claim.token == self.recordingSessionToken else {
                DebugLog.write("[stop] finishSegment skipped, stale token=\(claim.token) currentToken=\(self.recordingSessionToken)")
                Task { @MainActor in self.isSaving = false }
                if task != .invalid {
                    UIApplication.shared.endBackgroundTask(task)
                    task = .invalid
                }
                return
            }

            self.finishSegment {
                DebugLog.write("[stop] finishSegment completion fired, isSaving -> false token=\(claim.token)")
                Task { @MainActor in self.isSaving = false }
                if task != .invalid {
                    UIApplication.shared.endBackgroundTask(task)
                    task = .invalid
                }
            }
        }
    }

    // MARK: Segments & Rolling Split

}
