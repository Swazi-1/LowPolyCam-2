import AVFoundation
import Combine
import Foundation
import Photos
import UIKit

final class CameraManager: NSObject, ObservableObject {
    enum CaptureMode: String, CaseIterable, Identifiable {
        case video = "VIDEO"
        case photo = "PHOTO"
        case sloMo = "SLO-MO"

        var id: String { rawValue }
    }

    enum SlowMotionFrameRate: Int, CaseIterable, Identifiable {
        case fps120 = 120
        case fps240 = 240

        var id: Int { rawValue }
        var label: String { "\(rawValue) fps" }
    }

    enum CameraPosition {
        case back
        case front

        var avPosition: AVCaptureDevice.Position {
            self == .back ? .back : .front
        }
    }

    private struct VideoQualityRequest {
        let id: UInt64
        let resolution: VideoResolution
        let frameRate: VideoFrameRate
        let position: CameraPosition
        let codec: String
        let preferVirtualCamera: Bool
    }

    private struct SlowMotionQualityRequest {
        let id: UInt64
        let resolution: VideoResolution
        let frameRate: SlowMotionFrameRate
        let position: CameraPosition
        let codec: String
    }

    enum WhiteBalancePreset: String, CaseIterable, Identifiable {
        case auto = "Auto"
        case daylight = "Daylight"
        case cloudy = "Cloudy"
        case tungsten = "Tungsten"
        case fluorescent = "Fluorescent"

        var id: String { rawValue }

        var temperature: Float? {
            switch self {
            case .auto: return nil
            case .daylight: return 5_500
            case .cloudy: return 6_500
            case .tungsten: return 3_200
            case .fluorescent: return 4_200
            }
        }

        var tint: Float {
            switch self {
            case .fluorescent: return 8
            default: return 0
            }
        }
    }

    @Published private(set) var isSessionRunning = false
    @Published private(set) var isRecording = false
    @Published private(set) var isRecordingStarting = false
    @Published private(set) var isFinalizingRecording = false
    @Published private(set) var isCapturingPhoto = false
    @Published private(set) var captureMode: CaptureMode = .video
    @Published private(set) var isFocusExposureLocked = false
    @Published private(set) var exposureBias: Float = 0
    @Published private(set) var whiteBalancePreset: WhiteBalancePreset = .auto
    @Published private(set) var isPreviewTransitioning = false
    @Published private(set) var isLensTransitioning = false
    @Published private(set) var availableStorageBytes: Int64 = 0
    @Published private(set) var currentPhotoResolutionLabel = "12 MP"
    @Published private(set) var currentPhotoPixelCount: Int64 = 12_000_000
    @Published private(set) var selectedPhotoMegapixels = 12
    @Published private(set) var supportedPhotoMegapixels = Array((1...12).reversed())
    @Published private(set) var supportedResolutions: [VideoResolution] = []
    @Published private(set) var supportedFrameRates: [VideoFrameRate] = []
    @Published private(set) var supportedSlowMotionResolutions: [VideoResolution] = []
    @Published private(set) var supportedSlowMotionFrameRates: [SlowMotionFrameRate] = []
    @Published private(set) var cameraPosition: CameraPosition = .back
    @Published private(set) var torchAvailable = false
    @Published private(set) var isTorchOn = false
    @Published private(set) var minimumZoomFactor: CGFloat = 1
    @Published private(set) var maximumZoomFactor: CGFloat = 1
    @Published private(set) var zoomFactor: CGFloat = 1
    @Published private(set) var zoomLabel = "1×"
    @Published private(set) var statusMessage: String?
    @Published private(set) var statusMessageID: UInt64 = 0
    @Published private(set) var lastFrameGaps: Int?
    @Published private(set) var codecAvailabilityMessage: String?
    @Published private(set) var recoverableRecordingCount = 0
    @Published var selectedVideoCodec = UserDefaults.standard.string(forKey: "selectedVideoCodec") ?? "HEVC" {
        didSet {
            guard selectedVideoCodec != oldValue else { return }
            _ = qualityRequests.next()
            UserDefaults.standard.set(selectedVideoCodec, forKey: "selectedVideoCodec")
            guard !suppressAutomaticReconfiguration else { return }
            sessionQueue.async { [weak self] in
                guard let self, !self.movieOutput.isRecording else { return }
                self.lensTransitionCoordinator.cancel()
                self.updateCapabilities()
                _ = self.applyActiveModeFormat(preferVirtualCamera: !self.requiresPhysicalWhiteBalanceInput)
            }
        }
    }
    @Published var photoFileFormat = UserDefaults.standard.string(forKey: "photoFileFormat") ?? "HEIC" {
        didSet {
            guard photoFileFormat != oldValue else { return }
            UserDefaults.standard.set(photoFileFormat, forKey: "photoFileFormat")
        }
    }
    @Published var videoCompression = VideoCompression(rawValue: UserDefaults.standard.string(forKey: "videoCompression") ?? "") ?? .high {
        didSet {
            guard videoCompression != oldValue else { return }
            UserDefaults.standard.set(videoCompression.rawValue, forKey: "videoCompression")
            guard !suppressAutomaticReconfiguration else { return }
            sessionQueue.async { [weak self] in
                guard let self, !self.movieOutput.isRecording else { return }
                _ = self.configureMovieOutputSettings()
            }
        }
    }

    @Published var selectedResolution: VideoResolution {
        didSet { if !suppressPreferencePersistence { persistCameraPreferences() } }
    }
    @Published var selectedFrameRate: VideoFrameRate {
        didSet { if !suppressPreferencePersistence { persistCameraPreferences() } }
    }
    @Published var selectedSlowMotionResolution: VideoResolution {
        didSet { if !suppressPreferencePersistence { persistCameraPreferences() } }
    }
    @Published var selectedSlowMotionFrameRate: SlowMotionFrameRate {
        didSet { if !suppressPreferencePersistence { persistCameraPreferences() } }
    }
    @Published var isVideoStabilizationEnabled: Bool {
        didSet { UserDefaults.standard.set(isVideoStabilizationEnabled, forKey: Self.videoStabilizationKey) }
    }

    let session = AVCaptureSession()
    private let sessionQueue = DispatchQueue(label: "com.swazi.lowpolycam.camera")
    private let storageQueue = DispatchQueue(label: "com.swazi.lowpolycam.storage", qos: .utility)
    private let movieOutput = AVCaptureMovieFileOutput()
    private let photoOutput = AVCapturePhotoOutput()
    private let liveMetrics = LiveCaptureMetrics()
    let liveStats = LiveRecordingStatsState()
    let recordingClock = RecordingClockState()
    @Published private(set) var liveMetricsAvailable = false
    private var metricsTimer: DispatchSourceTimer?
    private var previousMetricBytes: Int64 = 0
    private var previousMetricDuration: Double = 0
    private struct PhotoCaptureContext {
        let aspect: String
        let megapixels: Int
        let filename: String
        let isBurst: Bool
    }

    private var burstRemaining = 0
    private var burstStopRequested = false
    private var burstAspect = "4:3"
    private var burstMegapixels = 12
    private var nativePhotoDimensions = CMVideoDimensions(width: 0, height: 0)
    private var preferredPhotoMegapixels = 12
    private var photoCaptureContexts: [Int64: PhotoCaptureContext] = [:]
    private var activePhotoCaptureID: Int64?
    private var activePhotoCaptureIsBurst = false
    private var pendingPhotoSaves = 0

    private var videoInput: AVCaptureDeviceInput?
    private var requestedZoom: CGFloat = 1
    private var requestedExposureBias: Float = 0
    private var requestedWhiteBalancePreset: WhiteBalancePreset = .auto
    private var pendingFocusLockWorkItem: DispatchWorkItem?
    private var pendingFocusReturnWorkItem: DispatchWorkItem?
    private struct ZoomSubmission {
        let factor: CGFloat
        let requestID: UInt64
    }
    private let zoomSubmissionLock = NSLock()
    private var pendingZoomSubmission: ZoomSubmission?
    private var isZoomSubmissionScheduled = false
    private let zoomRequests = RequestToken()
    private let cameraSwitchRequests = RequestToken()
    private let whiteBalanceRequests = RequestToken()
    private let modeChangeRequests = RequestToken()
    private let qualityRequests = RequestToken()
    private let qualityPreviewTransitions = RequestToken()
    private let exposureRequests = RequestToken()

    private var formatSelector: CameraFormatSelector {
        CameraFormatSelector(
            selectedVideoCodec: selectedVideoCodec,
            selectedResolution: selectedResolution,
            selectedFrameRate: selectedFrameRate
        )
    }
    private lazy var lensTransitionCoordinator = LensTransitionCoordinator(
        sessionQueue: self.sessionQueue,
        zoomRequests: self.zoomRequests,
        onTransitioningChanged: { [weak self] transitioning in
            guard let self else { return }
            self.publish { self.isLensTransitioning = transitioning }
        }
    )
    private enum RecordingState {
        case idle
        case starting(splitDuration: Double)
        case recording(splitDuration: Double)
        case stoppingToContinueSegment(splitDuration: Double)
        case stoppingToDiscard(finalizing: Bool)
        case finalizing

        var requestsRecording: Bool {
            switch self {
            case .starting(_), .recording(_), .stoppingToContinueSegment(_):
                return true
            case .idle, .stoppingToDiscard(_), .finalizing:
                return false
            }
        }

        var isFinalizing: Bool {
            switch self {
            case .finalizing:
                return true
            case .stoppingToDiscard(let finalizing):
                return finalizing
            case .idle, .starting(_), .recording(_), .stoppingToContinueSegment(_):
                return false
            }
        }

        var isContinuingSegment: Bool {
            if case .stoppingToContinueSegment(_) = self { return true }
            return false
        }

        var shouldDiscardWhenFinished: Bool {
            if case .stoppingToDiscard(_) = self { return true }
            return false
        }

        var splitDuration: Double {
            switch self {
            case .starting(let seconds), .recording(let seconds), .stoppingToContinueSegment(let seconds):
                return seconds
            case .idle, .stoppingToDiscard(_), .finalizing:
                return 0
            }
        }

        var uiFlags: (starting: Bool, recording: Bool, finalizing: Bool) {
            switch self {
            case .idle:
                return (false, false, false)
            case .starting(_):
                return (true, false, false)
            case .recording(_), .stoppingToContinueSegment(_):
                return (false, true, false)
            case .stoppingToDiscard(let finalizing):
                return (false, false, finalizing)
            case .finalizing:
                return (false, false, true)
            }
        }
    }

    private var isUsingSlowMotionPreview = false
    private var isUsingVideoPreviewProxy = false
    private var recordingState: RecordingState = .idle
    private var segmentTimer: DispatchWorkItem?
    private var pendingVideoSaves = 0
    private var inFlightVideoSaves: Set<URL> = []
    private var backgroundSaveTask: UIBackgroundTaskIdentifier = .invalid
    private var rotationCoordinator: AVCaptureDevice.RotationCoordinator?
    private var sessionObserverTokens: [NSObjectProtocol] = []
    private var suppressPreferencePersistence = false
    private var suppressAutomaticReconfiguration = false

    private static let resolutionKey = "selectedVideoResolution"
    private static let frameRateKey = "selectedVideoFrameRate"
    private static let slowMotionResolutionKey = "selectedSlowMotionResolution"
    private static let slowMotionFrameRateKey = "selectedSlowMotionFrameRate"
    private static let videoStabilizationKey = "videoStabilizationEnabled"
    private static let photoMegapixelsKey = "selectedPhotoMegapixels"
    private static let mediaSequenceKey = "lowPolyCamMediaSequence"

    override init() {
        let savedResolution = UserDefaults.standard.string(forKey: Self.resolutionKey)
        selectedResolution = VideoResolution(rawValue: savedResolution ?? "") ?? .p1080
        let savedFrameRate = UserDefaults.standard.integer(forKey: Self.frameRateKey)
        selectedFrameRate = VideoFrameRate(rawValue: savedFrameRate) ?? .fps30
        let savedSlowMotionResolution = UserDefaults.standard.string(forKey: Self.slowMotionResolutionKey)
        selectedSlowMotionResolution = VideoResolution(rawValue: savedSlowMotionResolution ?? "") ?? .p1080
        let savedSlowMotionFrameRate = UserDefaults.standard.integer(forKey: Self.slowMotionFrameRateKey)
        selectedSlowMotionFrameRate = SlowMotionFrameRate(rawValue: savedSlowMotionFrameRate) ?? .fps240
        isVideoStabilizationEnabled = UserDefaults.standard.object(forKey: Self.videoStabilizationKey) as? Bool ?? true
        super.init()
        let savedPhotoMegapixels = UserDefaults.standard.integer(forKey: Self.photoMegapixelsKey)
        preferredPhotoMegapixels = (1...12).contains(savedPhotoMegapixels) ? savedPhotoMegapixels : 12
        selectedPhotoMegapixels = preferredPhotoMegapixels
        currentPhotoResolutionLabel = "\(selectedPhotoMegapixels) MP"
        currentPhotoPixelCount = Int64(selectedPhotoMegapixels) * 1_000_000
        if UserDefaults.standard.bool(forKey: "rememberCaptureMode"),
           let saved = UserDefaults.standard.string(forKey: "lastCaptureMode"),
           let mode = CaptureMode(rawValue: saved) { captureMode = mode }
        installSessionObservers()
    }

    deinit {
        sessionObserverTokens.forEach(NotificationCenter.default.removeObserver)
        if backgroundSaveTask != .invalid {
            let task = backgroundSaveTask
            DispatchQueue.main.async { UIApplication.shared.endBackgroundTask(task) }
        }
    }

    private func transitionRecordingState(
        to newState: RecordingState,
        resetClock: Bool = false,
        startClock: Bool = false,
        clearLastFrameGaps: Bool = false
    ) {
        let previousFlags = recordingState.uiFlags
        recordingState = newState
        let flags = newState.uiFlags
        let flagsChanged = previousFlags.starting != flags.starting ||
            previousFlags.recording != flags.recording ||
            previousFlags.finalizing != flags.finalizing
        guard flagsChanged || resetClock || startClock || clearLastFrameGaps else { return }

        publish {
            if resetClock {
                self.recordingClock.stopAndReset()
            } else if startClock {
                self.recordingClock.startIfNeeded()
            }
            self.isRecordingStarting = flags.starting
            self.isRecording = flags.recording
            self.isFinalizingRecording = flags.finalizing
            if clearLastFrameGaps {
                self.lastFrameGaps = nil
            }
        }
    }

    private func transitionRecordingToDiscard(resetClock: Bool = false) {
        transitionRecordingState(
            to: .stoppingToDiscard(finalizing: recordingState.isFinalizing),
            resetClock: resetClock
        )
    }

    private func transitionRecordingToFinalizing(resetClock: Bool = false) {
        if recordingState.shouldDiscardWhenFinished {
            transitionRecordingState(to: .stoppingToDiscard(finalizing: true), resetClock: resetClock)
        } else {
            transitionRecordingState(to: .finalizing, resetClock: resetClock)
        }
    }

    private func preferenceKey(_ base: String, for position: CameraPosition) -> String {
        position == .back ? base : "\(base).front"
    }

    private func persistCameraPreferences() {
        let defaults = UserDefaults.standard
        let position = cameraPosition
        defaults.set(selectedResolution.rawValue, forKey: preferenceKey(Self.resolutionKey, for: position))
        defaults.set(selectedFrameRate.rawValue, forKey: preferenceKey(Self.frameRateKey, for: position))
        defaults.set(selectedSlowMotionResolution.rawValue, forKey: preferenceKey(Self.slowMotionResolutionKey, for: position))
        defaults.set(selectedSlowMotionFrameRate.rawValue, forKey: preferenceKey(Self.slowMotionFrameRateKey, for: position))
    }

    private func loadCameraPreferences(for position: CameraPosition) {
        let defaults = UserDefaults.standard
        suppressPreferencePersistence = true
        defer { suppressPreferencePersistence = false }
        let resolution = defaults.string(forKey: preferenceKey(Self.resolutionKey, for: position))
        selectedResolution = VideoResolution(rawValue: resolution ?? "") ?? .p1080
        let fps = defaults.integer(forKey: preferenceKey(Self.frameRateKey, for: position))
        selectedFrameRate = VideoFrameRate(rawValue: fps) ?? .fps30
        let slowResolution = defaults.string(forKey: preferenceKey(Self.slowMotionResolutionKey, for: position))
        selectedSlowMotionResolution = VideoResolution(rawValue: slowResolution ?? "") ?? .p1080
        let slowFPS = defaults.integer(forKey: preferenceKey(Self.slowMotionFrameRateKey, for: position))
        selectedSlowMotionFrameRate = SlowMotionFrameRate(rawValue: slowFPS) ?? (position == .front ? .fps120 : .fps240)
    }

    private func installSessionObservers() {
        let center = NotificationCenter.default
        sessionObserverTokens = [
            center.addObserver(forName: AVCaptureSession.runtimeErrorNotification, object: session, queue: nil) { [weak self] note in
                self?.sessionQueue.async { self?.handleSessionRuntimeError(note) }
            },
            center.addObserver(forName: AVCaptureSession.wasInterruptedNotification, object: session, queue: nil) { [weak self] _ in
                self?.sessionQueue.async { self?.handleSessionInterrupted() }
            },
            center.addObserver(forName: AVCaptureSession.interruptionEndedNotification, object: session, queue: nil) { [weak self] _ in
                self?.sessionQueue.async { self?.handleSessionInterruptionEnded() }
            }
        ]
    }

    private func handleSessionRuntimeError(_ notification: Notification) {
        stopLiveMetrics()
        let nsError = notification.userInfo?[AVCaptureSessionErrorKey] as? NSError
        if nsError?.code == AVError.Code.mediaServicesWereReset.rawValue {
            rebuildSessionAfterMediaServicesReset()
        } else {
            showError("Camera session error. Trying to recover…")
            configureSessionIfNeeded(forceRebuild: true)
            if !session.isRunning { session.startRunning() }
            publish { self.isSessionRunning = self.session.isRunning }
        }
    }

    private func handleSessionInterrupted() {
        stopLiveMetrics()
        lensTransitionCoordinator.cancel()
        burstRemaining = 0
        burstStopRequested = true
        synchronizeTorchState()
        guard recordingState.requestsRecording || movieOutput.isRecording else { return }

        segmentTimer?.cancel()

        if movieOutput.isRecording {
            transitionRecordingToFinalizing(resetClock: true)
            postStatus("Recording interrupted · saving…")
            movieOutput.stopRecording()
        } else {
            transitionRecordingToDiscard(resetClock: true)
        }
    }

    private func handleSessionInterruptionEnded() {
        configureSessionIfNeeded()
        if !session.isRunning { session.startRunning() }
        synchronizeTorchState()
        publish { self.isSessionRunning = self.session.isRunning }
    }

    private func rebuildSessionAfterMediaServicesReset() {
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
        storageQueue.async { [weak self] in
            guard let self else { return }
            let homeURL = URL(fileURLWithPath: NSHomeDirectory())
            guard let values = try? homeURL.resourceValues(
                forKeys: [.volumeAvailableCapacityForImportantUsageKey]
            ), let available = values.volumeAvailableCapacityForImportantUsage else { return }
            let bytes = max(available, 0)
            self.publish {
                if self.availableStorageBytes != bytes {
                    self.availableStorageBytes = bytes
                }
            }
        }
    }


    private var estimatedVideoBitsPerSecond: Double {
        let resolution = captureMode == .sloMo ? selectedSlowMotionResolution : selectedResolution
        let fps: Double = captureMode == .sloMo
            ? Double(selectedSlowMotionFrameRate.rawValue)
            : Double(selectedFrameRate.rawValue)
        let pixels = Double(resolution.dimensions.width) * Double(resolution.dimensions.height)
        let codecFactor = selectedVideoCodec == "H264" ? 1.0 : 0.72
        return max(pixels * fps * videoCompression.bitsPerPixel * codecFactor, 2_000_000)
    }

    private var estimatedBytesPerPhoto: Double {
        let pixels = max(Double(currentPhotoPixelCount), 1)
        let bytesPerPixel = photoFileFormat == "HEIC" ? 0.22 : 0.48
        return max(pixels * bytesPerPixel, photoFileFormat == "HEIC" ? 250_000 : 500_000)
    }

    func start() {
        sessionQueue.async { [weak self] in
            guard let self else { return }
            self.requestedZoom = 1
            // The active format still has to be ready before startRunning, but the full
            // settings-capability scan can happen after the first frame is unblocked.
            self.configureSessionIfNeeded(finalizePublishedState: false)
            guard self.session.isRunning == false else {
                self.publish { self.isSessionRunning = true }
                return
            }
            self.session.startRunning()
            try? AVAudioSession.sharedInstance().setAllowHapticsAndSystemSoundsDuringRecording(true)
            self.publish { self.isSessionRunning = true }
            self.updateCapabilities()
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
            self.stopLiveMetrics()
            self.lensTransitionCoordinator.cancel()
            self.burstRemaining = 0
            self.burstStopRequested = true
            self.segmentTimer?.cancel()
            if self.movieOutput.isRecording {
                self.transitionRecordingToFinalizing(resetClock: true)
                self.movieOutput.stopRecording()
            } else if self.recordingState.requestsRecording {
                self.transitionRecordingToDiscard(resetClock: true)
            }
            if self.session.isRunning {
                self.session.stopRunning()
                self.publish { self.isSessionRunning = false }
            }
        }
    }

    func appDidBecomeInactive() {
        sessionQueue.async { [weak self] in
            guard let self else { return }
            self.stopLiveMetrics()
            self.lensTransitionCoordinator.cancel()
            self.burstRemaining = 0
            self.burstStopRequested = true
            self.segmentTimer?.cancel()

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
                self.transitionRecordingToFinalizing(resetClock: true)
                self.movieOutput.stopRecording()
            } else if self.recordingState.requestsRecording {
                self.transitionRecordingToDiscard(resetClock: true)
            }
        }
        publish { self.isTorchOn = false }
    }

    func appDidBecomeActive() {
        sessionQueue.async { [weak self] in
            guard let self else { return }
            self.configureSessionIfNeeded()
            if !self.session.isRunning {
                self.session.startRunning()
            }
            try? AVAudioSession.sharedInstance().setAllowHapticsAndSystemSoundsDuringRecording(true)
            self.publish { self.isSessionRunning = self.session.isRunning }
            self.synchronizeTorchState()
        }
    }

    func toggleTorch() {
        sessionQueue.async { [weak self] in
            guard let self, let device = self.videoInput?.device, device.hasTorch else { return }
            if device.torchMode != .on && !device.isTorchAvailable {
                self.synchronizeTorchState()
                self.showError("Torch is temporarily unavailable.")
                return
            }
            self.setTorchEnabledOnCurrentDevice(device.torchMode != .on, showErrorOnFailure: true)
        }
    }

    /// Applies the requested torch state to whichever camera input is currently active.
    /// Mode changes can replace the AVCaptureDevice even though the user did not touch Flash,
    /// so this is also used immediately after a successful mode reconfiguration.
    private func setTorchEnabledOnCurrentDevice(_ enabled: Bool, showErrorOnFailure: Bool = false) {
        guard let device = videoInput?.device, device.hasTorch else {
            publish {
                self.torchAvailable = false
                self.isTorchOn = false
            }
            return
        }

        do {
            if enabled && !device.isTorchAvailable {
                publish {
                    self.torchAvailable = false
                    self.isTorchOn = false
                }
                if showErrorOnFailure { showError("Torch is temporarily unavailable.") }
                return
            }
            try device.lockForConfiguration()
            device.torchMode = enabled ? .on : .off
            let actualState = device.torchMode == .on
            device.unlockForConfiguration()
            publish {
                self.torchAvailable = device.isTorchAvailable
                self.isTorchOn = actualState
            }
        } catch {
            synchronizeTorchState()
            if showErrorOnFailure { showError("Couldn’t change the torch.") }
        }
    }

    func setZoomFactor(_ requestedFactor: CGFloat) {
        let requestID = zoomRequests.next()
        // A 60 Hz drag can outpace an expensive 4K60 lens handoff. Retain only the newest value
        // instead of leaving obsolete device/format scans queued behind the current camera work.
        zoomSubmissionLock.lock()
        pendingZoomSubmission = ZoomSubmission(factor: requestedFactor, requestID: requestID)
        let shouldSchedule = !isZoomSubmissionScheduled
        if shouldSchedule { isZoomSubmissionScheduled = true }
        zoomSubmissionLock.unlock()

        guard shouldSchedule else { return }
        sessionQueue.async { [weak self] in
            self?.drainZoomSubmissions()
        }
    }

    private func drainZoomSubmissions() {
        while let submission = takePendingZoomSubmission() {
            applyZoomSubmission(submission)
        }
    }

    private func takePendingZoomSubmission() -> ZoomSubmission? {
        zoomSubmissionLock.lock()
        defer { zoomSubmissionLock.unlock() }
        guard let submission = pendingZoomSubmission else {
            isZoomSubmissionScheduled = false
            return nil
        }
        pendingZoomSubmission = nil
        return submission
    }

    private func applyZoomSubmission(_ submission: ZoomSubmission) {
            let requestID = submission.requestID
            guard zoomRequests.isLatest(requestID),
                  let currentDevice = videoInput?.device else { return }

            let requested = min(max(submission.factor, minimumZoomFactor), maximumZoomFactor)
            if !lensTransitionCoordinator.hasActiveTransition,
               abs(requested - requestedZoom) < 0.0005 {
                return
            }

            // When rear 4K60 can stay on Apple's virtual Dual-Wide/Triple camera, keep the
            // capture session intact and let AVFoundation switch constituent cameras via zoom.
            // The short blur only masks the optical handoff; no AVCaptureDeviceInput is rebuilt.
            if !self.lensTransitionCoordinator.hasActiveTransition,
               self.lensTransitionCoordinator.shouldUseVirtual4K60Handoff(
                    on: currentDevice,
                    captureMode: self.captureMode,
                    cameraPosition: self.cameraPosition,
                    selectedResolution: self.selectedResolution,
                    selectedFrameRate: self.selectedFrameRate,
                    usesAutoWhiteBalance: self.requestedWhiteBalancePreset == .auto,
                    formatSelector: self.formatSelector
               ) {
                let currentDisplayed = self.displayedZoomFactor(for: currentDevice.videoZoomFactor, device: currentDevice)
                if self.lensTransitionCoordinator.crossesVirtualBoundary(
                    on: currentDevice,
                    from: currentDisplayed,
                    to: requested,
                    displayedZoomFactor: { factor, device in
                        self.displayedZoomFactor(for: factor, device: device)
                    }
                ) {
                    let request = LensTransitionCoordinator.Request(
                        id: requestID,
                        mode: self.captureMode,
                        requestedZoom: requested,
                        position: self.cameraPosition,
                        codec: self.selectedVideoCodec,
                        videoResolution: self.selectedResolution,
                        videoFrameRate: self.selectedFrameRate,
                        slowMotionResolution: self.selectedSlowMotionResolution,
                        slowMotionFrameRate: self.selectedSlowMotionFrameRate,
                        targetDeviceID: currentDevice.uniqueID
                    )
                    self.lensTransitionCoordinator.beginVirtualHandoff(
                        request,
                        device: currentDevice,
                        initialValidate: { [weak self] _, device in
                            guard let self else { return false }
                            return self.lensTransitionCoordinator.shouldUseVirtual4K60Handoff(
                                on: device,
                                captureMode: self.captureMode,
                                cameraPosition: self.cameraPosition,
                                selectedResolution: self.selectedResolution,
                                selectedFrameRate: self.selectedFrameRate,
                                usesAutoWhiteBalance: self.requestedWhiteBalancePreset == .auto,
                                formatSelector: self.formatSelector
                            )
                        },
                        delayedValidate: { [weak self] request, _ in
                            guard let self else { return false }
                            return self.videoInput?.device.uniqueID == request.targetDeviceID &&
                                self.captureMode == .video &&
                                self.cameraPosition == .back &&
                                self.selectedResolution == request.videoResolution &&
                                self.selectedFrameRate == request.videoFrameRate &&
                                self.selectedVideoCodec == request.codec
                        },
                        applyZoom: { [weak self] request, device in
                            self?.applyVirtualLensZoom(request, device: device) ?? false
                        },
                        onFailure: { [weak self] in
                            self?.showError("Couldn’t change the zoom.")
                        }
                    )
                    return
                }
            }

            if !currentDevice.isVirtualDevice, currentDevice.position == .back {
                let transitionDevices = self.lensTransitionCoordinator.supportedPhysicalLensDevices(
                    from: self.capabilityDevices(for: self.cameraPosition.avPosition),
                    captureMode: self.captureMode,
                    selectedResolution: self.selectedResolution,
                    selectedFrameRate: self.selectedFrameRate,
                    selectedSlowMotionResolution: self.selectedSlowMotionResolution,
                    selectedSlowMotionFrameRate: self.selectedSlowMotionFrameRate,
                    formatSelector: self.formatSelector
                )
                let candidateDevices: [AVCaptureDevice]
                if self.lensTransitionCoordinator.shouldUseCoveredPhysicalHandoff(
                    captureMode: self.captureMode,
                    cameraPosition: self.cameraPosition,
                    selectedResolution: self.selectedResolution,
                    selectedFrameRate: self.selectedFrameRate
                ) {
                    // Never cross onto a lens that cannot sustain the exact selected 4K60/HFR
                    // configuration. If capability discovery finds no alternative, stay put.
                    candidateDevices = transitionDevices.isEmpty ? [currentDevice] : transitionDevices
                } else {
                    candidateDevices = transitionDevices.isEmpty
                        ? self.capabilityDevices(for: .back).filter { !$0.isVirtualDevice }
                        : transitionDevices
                }
                let desiredPhysical = self.desiredPhysicalDevice(in: candidateDevices, forDisplayedZoom: requested)
                let wantsDifferentLens = desiredPhysical?.uniqueID != currentDevice.uniqueID

                if wantsDifferentLens {
                    let recordingOrStarting = self.movieOutput.isRecording || self.recordingState.requestsRecording || self.isRecordingStarting
                    if recordingOrStarting && self.captureMode != .video {
                        self.showError("Stop recording to switch physical lenses.")
                        return
                    }

                    // While recording normal Video, keep the physical input fixed and digitally
                    // zoom that sensor. Rebuilding AVCaptureDeviceInput mid-file can interrupt the
                    // recording. Idle 4K60 and rear Slo-Mo instead use the covered physical-lens
                    // handoff below.
                    if !recordingOrStarting {
                        if self.lensTransitionCoordinator.shouldUseCoveredPhysicalHandoff(
                            captureMode: self.captureMode,
                            cameraPosition: self.cameraPosition,
                            selectedResolution: self.selectedResolution,
                            selectedFrameRate: self.selectedFrameRate
                        ), let desiredPhysical {
                            let request = LensTransitionCoordinator.Request(
                                id: requestID,
                                mode: self.captureMode,
                                requestedZoom: requested,
                                position: self.cameraPosition,
                                codec: self.selectedVideoCodec,
                                videoResolution: self.selectedResolution,
                                videoFrameRate: self.selectedFrameRate,
                                slowMotionResolution: self.selectedSlowMotionResolution,
                                slowMotionFrameRate: self.selectedSlowMotionFrameRate,
                                targetDeviceID: desiredPhysical.uniqueID
                            )
                            self.lensTransitionCoordinator.beginPhysicalHandoff(
                                request,
                                devices: self.capabilityDevices(for: request.position.avPosition),
                                currentDeviceID: self.videoInput?.device.uniqueID,
                                selectedResolution: self.selectedResolution,
                                selectedFrameRate: self.selectedFrameRate,
                                selectedSlowMotionResolution: self.selectedSlowMotionResolution,
                                selectedSlowMotionFrameRate: self.selectedSlowMotionFrameRate,
                                selectedVideoCodec: self.selectedVideoCodec,
                                formatSelector: self.formatSelector,
                                applyPrepared: { [weak self] prepared in
                                    self?.applyPreparedLensHardware(prepared) ?? false
                                },
                                recoverAfterFailedApply: { [weak self] _ in
                                    guard let self, let device = self.videoInput?.device else { return }
                                    let actualZoom = self.displayedZoomFactor(for: device.videoZoomFactor, device: device)
                                    self.requestedZoom = actualZoom
                                    self.publish {
                                        self.zoomFactor = actualZoom
                                        self.zoomLabel = self.formattedZoomLabel(for: actualZoom)
                                    }
                                },
                                onPreparationFailure: { [weak self] in
                                    self?.showError("This lens can’t use the selected camera format.")
                                },
                                onApplyFailure: { [weak self] in
                                    self?.showError("Couldn’t finish the lens transition.")
                                }
                            )
                            return
                        }

                        let previousRequested = self.requestedZoom
                        self.requestedZoom = requested
                        guard self.zoomRequests.isLatest(requestID),
                              self.applyActiveModeFormat(preferVirtualCamera: !self.requiresPhysicalWhiteBalanceInput),
                              self.zoomRequests.isLatest(requestID) else {
                            self.requestedZoom = previousRequested
                            return
                        }
                        // applyActiveModeFormat already applied and published the snapped zoom on the
                        // correct physical lens. Do not queue a second ramp after the lens switch.
                        return
                    }
                }
            }

            guard self.zoomRequests.isLatest(requestID),
                  let device = self.videoInput?.device else { return }
            let factor = self.snappedZoomFactor(requested, for: device)
            do {
                try device.lockForConfiguration()
                let deviceFactor = self.deviceZoomFactor(for: factor, device: device)

                if self.lensTransitionCoordinator.hasActiveTransition {
                    // A newer drag returned to the currently active lens while a covered switch
                    // was pending/settling. Keep the cover up, commit the newest zoom immediately
                    // (no post-transition ramp), then let this newest request own the reveal.
                    self.lensTransitionCoordinator.takeOwnership(of: requestID)
                    device.cancelVideoZoomRamp()
                    device.videoZoomFactor = deviceFactor
                } else {
                    device.ramp(toVideoZoomFactor: deviceFactor, withRate: 12)
                }
                device.unlockForConfiguration()
                guard self.zoomRequests.isLatest(requestID) else { return }
                self.requestedZoom = factor
                self.publish {
                    self.zoomFactor = factor
                    self.zoomLabel = self.formattedZoomLabel(for: factor)
                }

                if self.lensTransitionCoordinator.isActive(requestID) {
                    self.lensTransitionCoordinator.finish(requestID, revealDelay: 0.08)
                }
            } catch {
                self.showError("Couldn’t change the zoom.")
            }
    }

    private func applyVirtualLensZoom(_ request: LensTransitionCoordinator.Request, device: AVCaptureDevice) -> Bool {
        let factor = snappedZoomFactor(request.requestedZoom, for: device)
        do {
            try device.lockForConfiguration()
            device.cancelVideoZoomRamp()
            device.videoZoomFactor = deviceZoomFactor(for: factor, device: device)
            device.unlockForConfiguration()
        } catch {
            return false
        }

        // The hardware zoom succeeded. If a newer request took ownership during the device call,
        // leave publishing/reveal to that request exactly as the previous inlined path did.
        guard lensTransitionCoordinator.isActive(request.id),
              zoomRequests.isLatest(request.id) else { return true }
        requestedZoom = factor
        publish {
            self.zoomFactor = factor
            self.zoomLabel = self.formattedZoomLabel(for: factor)
        }
        return true
    }

    private func applyPreparedLensHardware(_ prepared: LensTransitionCoordinator.PreparedTransition) -> Bool {
        let request = prepared.request
        guard lensTransitionCoordinator.isActive(request.id),
              zoomRequests.isLatest(request.id),
              captureMode == request.mode,
              cameraPosition == request.position,
              selectedVideoCodec == request.codec else { return false }

        let previousRequested = requestedZoom
        requestedZoom = request.requestedZoom
        guard let displayed = applyAtomicCaptureConfiguration(
            device: prepared.device,
            format: prepared.format,
            frameRate: prepared.frameRate,
            preparedReplacementInput: prepared.replacementInput,
            refreshAuxiliaryOutputs: false
        ) else {
            requestedZoom = previousRequested
            return false
        }

        // Input replacement may recreate the movie-output connection, but on devices where the
        // connection and its settings survive the swap, do not tear the encoder/stabilization
        // configuration down and rebuild it again. That extra reset is especially expensive at
        // 4K60 and is unnecessary when the desired settings are already in place.
        if !movieOutputSettingsMatchCurrentConfiguration() {
            _ = configureMovieOutputSettings()
        }
        isUsingVideoPreviewProxy = false
        isUsingSlowMotionPreview = false

        // This handoff keeps the same mode, resolution and frame rate, so the published zoom
        // range is already correct. Re-scanning every format on every lens after the blocking
        // hardware commit only extends the visible transition.
        publish {
            self.zoomFactor = displayed
            self.zoomLabel = self.formattedZoomLabel(for: displayed)
            self.torchAvailable = prepared.device.hasTorch && prepared.device.isTorchAvailable
            self.isTorchOn = prepared.device.hasTorch && prepared.device.torchMode == .on
        }
        resetFocusAndExposureState()
        synchronizeWhiteBalanceAfterConfiguration()

        // applyAtomicCaptureConfiguration has already validated the input replacement, locked the
        // target device, applied the requested format/FPS/zoom, and successfully committed the
        // capture-session transaction. Do not fail the transition on an immediate post-commit
        // read-back: AVFoundation can report transient duration/zoom state while the new 4K60/HFR
        // stream is still settling, which produced the false “Couldn’t finish…” message even though
        // the lens switch itself completed correctly.
        return true
    }



    func switchCamera() {
        guard !isRecording, !isRecordingStarting, !isFinalizingRecording, !isCapturingPhoto, !isLensTransitioning else { return }
        let previous = cameraPosition
        let target: CameraPosition = previous == .back ? .front : .back
        let requestID = cameraSwitchRequests.next()
        _ = zoomRequests.next() // Drop any drag command that belongs to the old camera.
        _ = qualityRequests.next() // Do not apply an old quality request to the new input.
        _ = exposureRequests.next() // Do not apply a queued slider value to the new input.

        cameraPosition = target
        loadCameraPreferences(for: target)

        sessionQueue.async { [weak self] in
            guard let self, self.cameraSwitchRequests.isLatest(requestID) else { return }
            self.lensTransitionCoordinator.cancel()
            guard self.applyActiveModeFormat(preferVirtualCamera: !self.requiresPhysicalWhiteBalanceInput) else {
                guard self.cameraSwitchRequests.isLatest(requestID) else { return }
                self.publish {
                    self.cameraPosition = previous
                    self.loadCameraPreferences(for: previous)
                }
                self.showError("That camera is unavailable.")
                return
            }
            guard self.cameraSwitchRequests.isLatest(requestID) else { return }
            self.updateCapabilities()
            self.synchronizeTorchState()
        }
    }

    func selectCaptureMode(_ mode: CaptureMode) {
        guard !isRecording, !isRecordingStarting, !isFinalizingRecording, !isCapturingPhoto, !isPreviewTransitioning, !isLensTransitioning, captureMode != mode else { return }
        let previousMode = captureMode
        let requestID = modeChangeRequests.next()
        _ = zoomRequests.next() // A queued old-mode zoom must not reconfigure the new mode.
        _ = qualityRequests.next() // Drop quality work that belonged to the previous mode.
        _ = exposureRequests.next() // The new mode reapplies the current requested EV itself.
        isPreviewTransitioning = true
        captureMode = mode
        sessionQueue.async { [weak self] in
            guard let self, self.modeChangeRequests.isLatest(requestID) else { return }
            self.lensTransitionCoordinator.cancel()
            let success = self.applyActiveModeFormat(preferVirtualCamera: !self.requiresPhysicalWhiteBalanceInput)
            if success { self.synchronizeTorchState() }

            self.publish {
                self.isPreviewTransitioning = false
                if success {
                    UserDefaults.standard.set(mode.rawValue, forKey: "lastCaptureMode")
                } else {
                    self.captureMode = previousMode
                    self.sessionQueue.async {
                        _ = self.applyActiveModeFormat(preferVirtualCamera: !self.requiresPhysicalWhiteBalanceInput)
                        self.synchronizeTorchState()
                    }
                }
            }
        }
    }

    func refreshLiveMetrics() {
        sessionQueue.async { [weak self] in
            guard let self, !self.recordingState.requestsRecording, !self.movieOutput.isRecording,
                  !self.lensTransitionCoordinator.hasActiveTransition,
                  self.videoInput != nil else { return }
            self.session.beginConfiguration()
            self.configureLiveMetrics()
            self.session.commitConfiguration()
        }
    }

    // Called inside the same transaction as the input/format change.
    private func configureLiveMetrics() {
        let isRear4K60 = captureMode == .video &&
            cameraPosition == .back &&
            selectedResolution == .p4k &&
            selectedFrameRate == .fps60
        // A second video-data stream can push multi-camera 4K60 beyond the device's sustainable
        // capture budget and trigger a runtime-error rebuild loop. File bitrate remains available
        // without this optional output; only measured FPS/drop counters are omitted in rear 4K60.
        let wanted = UserDefaults.standard.bool(forKey: "liveRecordingStats") &&
            captureMode != .photo &&
            !isRear4K60
        let attached = session.outputs.contains { $0 === liveMetrics.output }

        if wanted && !attached && session.canAddOutput(liveMetrics.output) {
            session.addOutput(liveMetrics.output)
        } else if !wanted && attached {
            stopLiveMetrics()
            session.removeOutput(liveMetrics.output)
        }

        let available = session.outputs.contains { $0 === liveMetrics.output }
        if available && !movieOutput.isRecording {
            setLiveMetricsConnectionEnabled(false)
        }
        publish {
            if self.liveMetricsAvailable != available {
                self.liveMetricsAvailable = available
            }
        }
    }

    private func setLiveMetricsConnectionEnabled(_ enabled: Bool) {
        guard let connection = liveMetrics.output.connection(with: .video),
              connection.isEnabled != enabled else { return }
        connection.isEnabled = enabled
    }

    private func stopLiveMetrics() {
        metricsTimer?.cancel()
        metricsTimer = nil
        liveMetrics.setRunning(false)
        setLiveMetricsConnectionEnabled(false)
    }

    private func startLiveMetrics() {
        stopLiveMetrics()
        previousMetricBytes = 0
        previousMetricDuration = 0
        publish { self.liveStats.reset() }
        guard UserDefaults.standard.bool(forKey: "liveRecordingStats") else { return }

        let captureMetricsAvailable = session.outputs.contains { $0 === liveMetrics.output }
        if captureMetricsAvailable {
            setLiveMetricsConnectionEnabled(true)
            liveMetrics.setRunning(true)
        }

        // Bitrate comes from AVCaptureMovieFileOutput and remains available even if the optional
        // video-data output could not be attached. Only FPS/drop measurement depends on it.
        let timer = DispatchSource.makeTimerSource(queue: sessionQueue)
        timer.schedule(deadline: .now() + 1, repeating: 1)
        timer.setEventHandler { [weak self] in
            guard let self, self.movieOutput.isRecording else { return }
            let duration = self.movieOutput.recordedDuration.seconds
            let bytes = self.movieOutput.recordedFileSize
            let delta = duration - self.previousMetricDuration
            let bits = bytes - self.previousMetricBytes
            let mbps: Double? = delta > 0 && bits > 0 ? Double(bits) * 8 / delta / 1_000_000 : nil
            self.previousMetricBytes = bytes
            self.previousMetricDuration = duration

            let attached = self.session.outputs.contains { $0 === self.liveMetrics.output }
            var fps: Double?
            var drops: Int?
            if attached {
                let measurement = self.liveMetrics.read()
                fps = measurement.fps
                drops = measurement.fps != nil ? measurement.drops : nil
            }

            self.publish {
                self.liveStats.update(fps: fps, mbps: mbps, drops: drops)
            }
        }
        metricsTimer = timer
        timer.resume()
    }

    func applyLongevityMode(_ enabled: Bool) {
        guard !isRecording, !isRecordingStarting, !isFinalizingRecording else { return }
        let defaults = UserDefaults.standard
        if enabled {
            defaults.set(selectedResolution.rawValue, forKey: "longevityPreviousResolution")
            defaults.set(selectedFrameRate.rawValue, forKey: "longevityPreviousFPS")
            defaults.set(selectedVideoCodec, forKey: "longevityPreviousCodec")
            defaults.set(videoCompression.rawValue, forKey: "longevityPreviousCompression")
        }
        suppressAutomaticReconfiguration = true
        if enabled {
            selectedResolution = .p720
            selectedFrameRate = .fps30
            selectedVideoCodec = "HEVC"
            videoCompression = .dataSaver
        } else {
            selectedResolution = VideoResolution(rawValue: defaults.string(forKey: "longevityPreviousResolution") ?? "") ?? .p1080
            selectedFrameRate = VideoFrameRate(rawValue: defaults.integer(forKey: "longevityPreviousFPS")) ?? .fps30
            selectedVideoCodec = defaults.string(forKey: "longevityPreviousCodec") ?? "HEVC"
            videoCompression = VideoCompression(rawValue: defaults.string(forKey: "longevityPreviousCompression") ?? "") ?? .high
        }
        suppressAutomaticReconfiguration = false
        defaults.set(enabled, forKey: "longevityMode")
        sessionQueue.async { [weak self] in
            guard let self else { return }
            self.lensTransitionCoordinator.cancel()
            _ = self.applyActiveModeFormat(preferVirtualCamera: !self.requiresPhysicalWhiteBalanceInput)
        }
    }

    func selectPhotoMegapixels(_ megapixels: Int) {
        guard supportedPhotoMegapixels.contains(megapixels), selectedPhotoMegapixels != megapixels else { return }
        preferredPhotoMegapixels = megapixels
        UserDefaults.standard.set(megapixels, forKey: Self.photoMegapixelsKey)
        selectedPhotoMegapixels = megapixels
        currentPhotoResolutionLabel = "\(megapixels) MP"
        currentPhotoPixelCount = Int64(megapixels) * 1_000_000
        refreshAvailableStorage()
    }

    func updatePhotoAspectSelection(_ aspect: String) {
        sessionQueue.async { [weak self] in
            guard let self,
                  self.nativePhotoDimensions.width > 0,
                  self.nativePhotoDimensions.height > 0 else { return }
            self.updatePhotoMegapixelAvailability(for: self.nativePhotoDimensions, aspect: aspect)
        }
    }

    func captureBurst() {
        guard captureMode == .photo, !isCapturingPhoto, !isRecordingStarting, !isFinalizingRecording else { return }
        let savedCount = UserDefaults.standard.integer(forKey: "burstCount")
        let count = [5, 10, 15].contains(savedCount) ? savedCount : 5
        isCapturingPhoto = true
        sessionQueue.async { [weak self] in
            guard let self else { return }
            self.burstRemaining = count
            self.burstStopRequested = false
            self.burstAspect = UserDefaults.standard.string(forKey: "photoAspect") ?? "4:3"
            self.burstMegapixels = self.selectedPhotoMegapixels
            self.beginPhotoCapture()
        }
    }

    func stopBurst() {
        sessionQueue.async { [weak self] in
            guard let self, self.burstRemaining > 0 else { return }
            self.burstStopRequested = true
        }
    }

    func capturePhoto() {
        guard captureMode == .photo, !isRecording, !isRecordingStarting, !isFinalizingRecording, !isCapturingPhoto else { return }
        isCapturingPhoto = true
        sessionQueue.async { [weak self] in
            guard let self else { return }
            self.burstRemaining = 0
            self.burstStopRequested = false
            self.beginPhotoCapture()
        }
    }

    func focusAndExpose(at point: CGPoint) {
        sessionQueue.async { [weak self] in
            self?.configureFocusAndExposure(at: point, lockAfterFocusing: false)
        }
    }

    func lockFocusAndExposure(at point: CGPoint) {
        sessionQueue.async { [weak self] in
            self?.configureFocusAndExposure(at: point, lockAfterFocusing: true)
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
        let requestID = whiteBalanceRequests.next()
        sessionQueue.async { [weak self] in
            guard let self, self.whiteBalanceRequests.isLatest(requestID),
                  !self.movieOutput.isRecording, !self.recordingState.requestsRecording,
                  !self.lensTransitionCoordinator.hasActiveTransition else { return }

            let previousPreset = self.requestedWhiteBalancePreset
            let currentDevice = self.videoInput?.device
            // Slo-Mo always uses a physical HFR camera. Rear 4K60 may use Apple's
            // Dual-Wide/Triple virtual camera while WB is Auto, but manual WB must move to a
            // physical constituent so locked temperature/tint is applied to the real capture input.
            let modeRequiresPhysicalInput = self.cameraPosition == .back && self.captureMode == .sloMo
            let needsInputSwap = self.cameraPosition == .back && !modeRequiresPhysicalInput && (
                (preset != .auto && currentDevice?.isVirtualDevice == true) ||
                (preset == .auto && currentDevice?.isVirtualDevice == false)
            )

            self.requestedWhiteBalancePreset = preset

            // Manual-to-manual (or any front-camera WB change) only needs a device WB update.
            // Do not rebuild/reapply the whole capture format for a color-temperature change.
            if !needsInputSwap {
                guard self.whiteBalanceRequests.isLatest(requestID) else { return }
                if self.applyWhiteBalancePresetToCurrentCamera(preset) {
                    self.publish {
                        self.whiteBalancePreset = preset
                        self.isPreviewTransitioning = false
                    }
                } else {
                    self.requestedWhiteBalancePreset = previousPreset
                    _ = self.applyWhiteBalancePresetToCurrentCamera(previousPreset)
                    self.publish {
                        self.whiteBalancePreset = previousPreset
                        self.isPreviewTransitioning = false
                    }
                    self.showError(preset == .auto
                        ? "Couldn’t enable Auto white balance."
                        : "Manual white balance isn’t available on this lens.")
                }
                return
            }

            // Rear Auto <-> manual requires a virtual/physical input handoff. Freeze the
            // current preview first, then perform exactly one atomic input+format change.
            self.publish { self.isPreviewTransitioning = true }
            self.sessionQueue.asyncAfter(deadline: .now() + 0.045) { [weak self] in
                guard let self, self.whiteBalanceRequests.isLatest(requestID) else { return }

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
                }

                DispatchQueue.main.asyncAfter(deadline: .now() + 0.12) { [weak self] in
                    guard let self, self.whiteBalanceRequests.isLatest(requestID) else { return }
                    self.isPreviewTransitioning = false
                }
            }
        }
    }



    func selectResolution(_ resolution: VideoResolution) {
        guard captureMode == .video, !isRecording, !isRecordingStarting, !isFinalizingRecording, !isLensTransitioning else { return }
        guard selectedResolution != resolution else { return }
        selectedResolution = resolution
        let transitionID = qualityPreviewTransitions.next()
        isPreviewTransitioning = true
        let request = VideoQualityRequest(
            id: qualityRequests.next(),
            resolution: selectedResolution,
            frameRate: selectedFrameRate,
            position: cameraPosition,
            codec: selectedVideoCodec,
            preferVirtualCamera: !requiresPhysicalWhiteBalanceInput
        )
        sessionQueue.asyncAfter(deadline: .now() + 0.07) { [weak self] in
            guard let self else { return }
            guard self.qualityRequests.isLatest(request.id),
                  self.captureMode == .video,
                  self.cameraPosition == request.position,
                  self.selectedVideoCodec == request.codec,
                  !self.recordingState.requestsRecording,
                  !self.recordingState.isFinalizing,
                  !self.movieOutput.isRecording else {
                self.finishQualityPreviewTransition(transitionID)
                return
            }
            self.lensTransitionCoordinator.cancel()
            _ = self.applySelectedFormat(
                preferVirtualCamera: request.preferVirtualCamera,
                requestedResolution: request.resolution,
                requestedFrameRate: request.frameRate,
                qualityRequestID: request.id,
                requestedPosition: request.position
            )
            self.finishQualityPreviewTransition(transitionID)
        }
    }

    func selectFrameRate(_ frameRate: VideoFrameRate) {
        guard captureMode == .video, !isRecording, !isRecordingStarting, !isFinalizingRecording, !isLensTransitioning else { return }
        guard selectedFrameRate != frameRate else { return }
        selectedFrameRate = frameRate
        let transitionID = qualityPreviewTransitions.next()
        isPreviewTransitioning = true
        let request = VideoQualityRequest(
            id: qualityRequests.next(),
            resolution: selectedResolution,
            frameRate: selectedFrameRate,
            position: cameraPosition,
            codec: selectedVideoCodec,
            preferVirtualCamera: !requiresPhysicalWhiteBalanceInput
        )
        sessionQueue.asyncAfter(deadline: .now() + 0.07) { [weak self] in
            guard let self else { return }
            guard self.qualityRequests.isLatest(request.id),
                  self.captureMode == .video,
                  self.cameraPosition == request.position,
                  self.selectedVideoCodec == request.codec,
                  !self.recordingState.requestsRecording,
                  !self.recordingState.isFinalizing,
                  !self.movieOutput.isRecording else {
                self.finishQualityPreviewTransition(transitionID)
                return
            }
            self.lensTransitionCoordinator.cancel()
            _ = self.applySelectedFormat(
                preferVirtualCamera: request.preferVirtualCamera,
                requestedResolution: request.resolution,
                requestedFrameRate: request.frameRate,
                qualityRequestID: request.id,
                requestedPosition: request.position
            )
            self.finishQualityPreviewTransition(transitionID)
        }
    }

    func selectSlowMotionResolution(_ resolution: VideoResolution) {
        guard captureMode == .sloMo, !isRecording, !isRecordingStarting, !isFinalizingRecording, !isLensTransitioning else { return }
        guard selectedSlowMotionResolution != resolution else { return }
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
        guard selectedSlowMotionFrameRate != frameRate else { return }
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

    private func finishQualityPreviewTransition(_ transitionID: UInt64) {
        // The iPhone 11 test stream needed roughly 0.32-0.37 seconds to produce a bright frame
        // after a resolution/FPS commit. Keep the existing frozen cover through that reset window.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.38) { [weak self] in
            guard let self, self.qualityPreviewTransitions.isLatest(transitionID) else { return }
            self.isPreviewTransitioning = false
        }
    }

    func setVideoStabilizationEnabled(_ enabled: Bool) {
        guard isVideoStabilizationEnabled != enabled else { return }
        isVideoStabilizationEnabled = enabled
        guard captureMode == .video else { return }
        sessionQueue.async { [weak self] in self?.configureMovieOutputSettings() }
    }

    func refreshMovieOutputSettings() {
        sessionQueue.async { [weak self] in
            guard let self, !self.movieOutput.isRecording else { return }
            _ = self.configureMovieOutputSettings()
        }
    }

    func startOrStopRecording() {
        guard captureMode == .video || captureMode == .sloMo else { return }
        sessionQueue.async { [weak self] in
            guard let self, !self.recordingState.isFinalizing else { return }

            if self.recordingState.requestsRecording {
                self.stopLiveMetrics()
                self.segmentTimer?.cancel()

                if self.movieOutput.isRecording {
                    self.transitionRecordingState(to: .finalizing, resetClock: true)
                    self.postStatus("Saving to Photos…")
                    self.movieOutput.stopRecording()
                } else {
                    // A second tap arrived while AVCaptureMovieFileOutput was still starting.
                    // If didStart arrives later, stop and discard that canceled startup clip.
                    self.transitionRecordingToDiscard(resetClock: true)
                }
                return
            }

            guard !self.isCapturingPhoto, !self.lensTransitionCoordinator.hasActiveTransition else { return }
            let splitDuration = Double(UserDefaults.standard.integer(forKey: "splitMinutes")) * 60
            self.transitionRecordingState(
                to: .starting(splitDuration: splitDuration),
                resetClock: true,
                clearLastFrameGaps: true
            )
            self.beginRecording()
        }
    }

    func applyQuickPreset(_ preset: VideoQuickPreset, completion: ((Bool) -> Void)? = nil) {
        guard captureMode == .video, !isRecording, !isRecordingStarting, !isCapturingPhoto, !isLensTransitioning else {
            completion?(false)
            return
        }

        sessionQueue.async { [weak self] in
            guard let self else { return }
            self.lensTransitionCoordinator.cancel()
            let devices = self.capabilityDevices(for: self.cameraPosition.avPosition)
            let supported = devices.contains { device in
                device.formats.contains { self.formatSelector.format($0, supports: preset.resolution, at: preset.frameRate) }
            }
            guard supported else {
                self.showError("This preset isn’t supported by the current camera.")
                self.publish { completion?(false) }
                return
            }

            self.publish {
                self.suppressPreferencePersistence = true
                self.suppressAutomaticReconfiguration = true
                self.selectedResolution = preset.resolution
                self.selectedFrameRate = preset.frameRate
                self.videoCompression = preset.compression
                self.selectedVideoCodec = "HEVC"
                self.suppressPreferencePersistence = false
                self.suppressAutomaticReconfiguration = false
                self.persistCameraPreferences()

                self.sessionQueue.async {
                    let success = self.applySelectedFormat(
                        preferVirtualCamera: !self.requiresPhysicalWhiteBalanceInput
                    )
                    self.publish { completion?(success) }
                }
            }
        }
    }

    private func configureSessionIfNeeded(
        forceRebuild: Bool = false,
        finalizePublishedState: Bool = true
    ) {
        let hasVideo = videoInput.map { current in
            session.inputs.contains(where: { $0 === current })
        } ?? false
        let hasMovie = session.outputs.contains(where: { $0 === movieOutput })
        let hasPhoto = session.outputs.contains(where: { $0 === photoOutput })
        if !forceRebuild, hasVideo, hasMovie, hasPhoto {
            return
        }

        lensTransitionCoordinator.cancel()
        _ = qualityRequests.next()
        stopLiveMetrics()
        session.beginConfiguration()
        session.sessionPreset = .inputPriority

        // A partial setup is not considered configured. Rebuild from a known clean state so
        // an earlier input/output failure cannot permanently wedge this CameraManager.
        for input in session.inputs {
            session.removeInput(input)
        }
        for output in session.outputs {
            session.removeOutput(output)
        }
        videoInput = nil

        guard let device = preferredCamera(for: cameraPosition.avPosition) else {
            session.commitConfiguration()
            showError("Camera is unavailable on this device.")
            return
        }

        do {
            let input = try AVCaptureDeviceInput(device: device)
            guard session.canAddInput(input) else {
                session.commitConfiguration()
                showError("Couldn’t add the camera input.")
                return
            }
            session.addInput(input)
            videoInput = input
        } catch {
            session.commitConfiguration()
            showError("Couldn’t access the camera.")
            return
        }

        // Microphone is optional so Photo mode still works when microphone permission is denied.
        if AVCaptureDevice.authorizationStatus(for: .audio) == .authorized,
           let audioDevice = AVCaptureDevice.default(for: .audio),
           let audioInput = try? AVCaptureDeviceInput(device: audioDevice),
           session.canAddInput(audioInput) {
            session.addInput(audioInput)
        }

        guard session.canAddOutput(movieOutput) else {
            for input in session.inputs { session.removeInput(input) }
            videoInput = nil
            session.commitConfiguration()
            showError("Video recording is unavailable on this device.")
            return
        }
        session.addOutput(movieOutput)

        guard session.canAddOutput(photoOutput) else {
            session.removeOutput(movieOutput)
            for input in session.inputs { session.removeInput(input) }
            videoInput = nil
            session.commitConfiguration()
            showError("Photo capture is unavailable on this device.")
            return
        }
        photoOutput.maxPhotoQualityPrioritization = .quality
        session.addOutput(photoOutput)
        if photoOutput.isResponsiveCaptureSupported {
            photoOutput.isResponsiveCaptureEnabled = true
        }
        session.commitConfiguration()

        _ = applyActiveModeFormat(preferVirtualCamera: !requiresPhysicalWhiteBalanceInput)
        if finalizePublishedState {
            updateCapabilities()
            synchronizeTorchState()
        }
    }







    @discardableResult
    private func applyAtomicCaptureConfiguration(
        device desiredDevice: AVCaptureDevice,
        format: AVCaptureDevice.Format,
        frameRate: Double,
        photoDimensions: CMVideoDimensions? = nil,
        preparedReplacementInput: AVCaptureDeviceInput? = nil,
        refreshAuxiliaryOutputs: Bool = true
    ) -> CGFloat? {
        let oldInput = videoInput
        let shouldPreserveTorch = oldInput?.device.hasTorch == true && oldInput?.device.torchMode == .on
        let isSwitchingInput = oldInput?.device.uniqueID != desiredDevice.uniqueID
        var replacementInput: AVCaptureDeviceInput?

        if isSwitchingInput {
            if let preparedReplacementInput,
               preparedReplacementInput.device.uniqueID == desiredDevice.uniqueID {
                replacementInput = preparedReplacementInput
            } else {
                do {
                    replacementInput = try AVCaptureDeviceInput(device: desiredDevice)
                } catch {
                    showError("Couldn’t access the selected camera.")
                    return nil
                }
            }
        }

        session.beginConfiguration()
        var committed = false
        if refreshAuxiliaryOutputs {
            configureLiveMetrics()
        }
        defer {
            if !committed { session.commitConfiguration() }
        }

        if isSwitchingInput {
            if let oldInput { session.removeInput(oldInput) }
            guard let replacementInput, session.canAddInput(replacementInput) else {
                if let oldInput, session.canAddInput(oldInput) {
                    session.addInput(oldInput)
                    videoInput = oldInput
                }
                return nil
            }
            session.addInput(replacementInput)
            videoInput = replacementInput
        }

        var deviceLocked = false
        do {
            try desiredDevice.lockForConfiguration()
            deviceLocked = true

            desiredDevice.activeFormat = format
            desiredDevice.automaticallyAdjustsVideoHDREnabled = selectedVideoCodec != "H264"
            if selectedVideoCodec == "H264", desiredDevice.isVideoHDREnabled {
                desiredDevice.isVideoHDREnabled = false
            }
            if desiredDevice.isGeometricDistortionCorrectionSupported {
                desiredDevice.isGeometricDistortionCorrectionEnabled = true
            }

            let supportedRange = format.videoSupportedFrameRateRanges.first {
                $0.minFrameRate <= frameRate + 0.5 && $0.maxFrameRate >= frameRate - 0.5
            } ?? format.videoSupportedFrameRateRanges.first
            let actualRate = min(max(frameRate, supportedRange?.minFrameRate ?? frameRate), supportedRange?.maxFrameRate ?? frameRate)
            let duration = CMTimeMakeWithSeconds(1.0 / max(actualRate, 1), preferredTimescale: 60_000)
            desiredDevice.activeVideoMinFrameDuration = duration
            desiredDevice.activeVideoMaxFrameDuration = duration

            let displayedZoom = snappedZoomFactor(requestedZoom, for: desiredDevice)
            desiredDevice.cancelVideoZoomRamp()
            desiredDevice.videoZoomFactor = deviceZoomFactor(for: displayedZoom, device: desiredDevice)
            if shouldPreserveTorch, desiredDevice.hasTorch, desiredDevice.isTorchAvailable {
                desiredDevice.torchMode = .on
            }
            desiredDevice.unlockForConfiguration()
            deviceLocked = false

            if let photoDimensions,
               (photoOutput.maxPhotoDimensions.width != photoDimensions.width ||
                photoOutput.maxPhotoDimensions.height != photoDimensions.height) {
                photoOutput.maxPhotoDimensions = photoDimensions
            }

            session.commitConfiguration()
            committed = true
            setLiveMetricsConnectionEnabled(recordingState.requestsRecording && movieOutput.isRecording)
            rotationCoordinator = AVCaptureDevice.RotationCoordinator(device: desiredDevice, previewLayer: nil)
            requestedZoom = displayedZoom
            return displayedZoom
        } catch {
            if deviceLocked {
                desiredDevice.unlockForConfiguration()
            }
            if isSwitchingInput {
                if let replacementInput, session.inputs.contains(where: { $0 === replacementInput }) {
                    session.removeInput(replacementInput)
                }
                if let oldInput, session.canAddInput(oldInput) {
                    session.addInput(oldInput)
                    videoInput = oldInput
                }
            }
            showError("Couldn’t configure the selected camera format.")
            return nil
        }
    }





    private func updateCapabilities() {
        guard let device = videoInput?.device else { return }
        let devices = capabilityDevices(for: device.position)
        let supported = formatSelector.availableResolutions(for: devices)
        let selection = formatSelector.validSelection(for: devices, availableResolutions: supported)
        let slowMotionResolutions = formatSelector.slowMotionResolutions(for: devices)
        let slowMotionResolution = slowMotionResolutions.contains(selectedSlowMotionResolution)
            ? selectedSlowMotionResolution
            : (slowMotionResolutions.contains(.p1080) ? .p1080 : (slowMotionResolutions.first ?? .p1080))
        let slowMotionRates = formatSelector.slowMotionFrameRates(for: devices, resolution: slowMotionResolution)
        let slowMotionSelection = slowMotionRates.contains(selectedSlowMotionFrameRate)
            ? selectedSlowMotionFrameRate
            : (slowMotionRates.last ?? .fps120)

        let zoomDevices: [AVCaptureDevice]
        if device.position == .back, captureMode == .video,
           selection.resolution == .p4k, selection.frameRate == .fps60 {
            if lensTransitionCoordinator.isRearVirtualLensSystem(device),
               formatSelector.format(device.activeFormat, supports: selection.resolution, at: selection.frameRate),
               formatSelector.formatSupportsSelectedCodec(device.activeFormat) {
                zoomDevices = [device]
            } else {
                let physical = devices.filter { candidate in
                    !candidate.isVirtualDevice && candidate.formats.contains {
                        self.formatSelector.format($0, supports: selection.resolution, at: selection.frameRate) && self.formatSelector.formatSupportsSelectedCodec($0)
                    }
                }
                zoomDevices = physical.isEmpty ? [device] : physical
            }
        } else if device.position == .back, captureMode == .sloMo {
            let physical = devices.filter { candidate in
                !candidate.isVirtualDevice && candidate.formats.contains {
                    self.formatSelector.supportsSlowMotion($0, resolution: slowMotionResolution, frameRate: slowMotionSelection)
                }
            }
            zoomDevices = physical.isEmpty ? [device] : physical
        } else {
            zoomDevices = [device]
        }
        let minimumZoom = zoomDevices.map { minimumSupportedZoom(for: $0) }.min() ?? minimumSupportedZoom(for: device)
        let maximumZoom = zoomDevices.map { maximumSupportedZoom(for: $0) }.max() ?? maximumSupportedZoom(for: device)
        let displayedZoom = displayedZoomFactor(for: device.videoZoomFactor, device: device)

        publish {
            let wasSuppressing = self.suppressPreferencePersistence
            self.suppressPreferencePersistence = true
            self.supportedResolutions = supported
            self.torchAvailable = device.hasTorch && device.isTorchAvailable
            self.isTorchOn = device.hasTorch && device.torchMode == .on
            self.minimumZoomFactor = minimumZoom
            self.maximumZoomFactor = maximumZoom
            self.zoomFactor = displayedZoom
            self.zoomLabel = self.formattedZoomLabel(for: displayedZoom)
            self.selectedResolution = selection.resolution
            self.selectedFrameRate = selection.frameRate
            self.supportedFrameRates = selection.supportedFrameRates
            self.supportedSlowMotionResolutions = slowMotionResolutions
            self.selectedSlowMotionResolution = slowMotionResolution
            self.supportedSlowMotionFrameRates = slowMotionRates
            self.selectedSlowMotionFrameRate = slowMotionSelection
            self.suppressPreferencePersistence = wasSuppressing
        }
    }

    private func preferredCamera(for position: AVCaptureDevice.Position) -> AVCaptureDevice? {
        let deviceTypes: [AVCaptureDevice.DeviceType] = position == .front
            ? [.builtInWideAngleCamera, .builtInUltraWideCamera]
            : [.builtInTripleCamera, .builtInDualWideCamera, .builtInDualCamera, .builtInWideAngleCamera]

        for type in deviceTypes {
            if let device = AVCaptureDevice.default(type, for: .video, position: position) {
                return device
            }
        }
        return nil
    }

    private func capabilityDevices(for position: AVCaptureDevice.Position) -> [AVCaptureDevice] {
        var devices: [AVCaptureDevice] = []
        func append(_ device: AVCaptureDevice?) {
            guard let device, !devices.contains(where: { $0.uniqueID == device.uniqueID }) else { return }
            devices.append(device)
        }
        append(preferredCamera(for: position))
        append(AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: position))
        append(AVCaptureDevice.default(.builtInUltraWideCamera, for: .video, position: position))
        if position == .back {
            append(AVCaptureDevice.default(.builtInTelephotoCamera, for: .video, position: position))
        }
        return devices
    }

    private func desiredPhysicalDevice(in devices: [AVCaptureDevice], forDisplayedZoom zoom: CGFloat) -> AVCaptureDevice? {
        let physical = devices.filter { !$0.isVirtualDevice }
        if zoom < 1 {
            return physical.first(where: { $0.deviceType == .builtInUltraWideCamera })
                ?? physical.first(where: { $0.deviceType == .builtInWideAngleCamera })
                ?? physical.first
        }
        if zoom >= 1.75, let tele = physical.first(where: { $0.deviceType == .builtInTelephotoCamera }) {
            return tele
        }
        return physical.first(where: { $0.deviceType == .builtInWideAngleCamera }) ?? physical.first
    }

    private func telephotoOpticalFactor(for device: AVCaptureDevice) -> CGFloat {
        guard device.deviceType == .builtInTelephotoCamera,
              let wide = AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: device.position) else { return 1 }
        let wideFOV = Double(wide.activeFormat.videoFieldOfView) * .pi / 180
        let teleFOV = Double(device.activeFormat.videoFieldOfView) * .pi / 180
        guard wideFOV > 0, teleFOV > 0 else { return 2 }
        let factor = tan(wideFOV / 2) / tan(teleFOV / 2)
        return CGFloat(min(max(factor, 1.5), 8))
    }

    private func cameraSupportingCurrentQuality(for position: AVCaptureDevice.Position) -> AVCaptureDevice? {
        capabilityDevices(for: position).first { device in
            device.formats.contains { formatSelector.format($0, supports: selectedResolution, at: selectedFrameRate) }
        }
    }

    private func cameraSupportingSlowMotion(for position: AVCaptureDevice.Position) -> AVCaptureDevice? {
        let devices = capabilityDevices(for: position)
        let resolutions = formatSelector.slowMotionResolutions(for: devices)
        guard !resolutions.isEmpty else { return nil }
        let resolution = resolutions.contains(selectedSlowMotionResolution)
            ? selectedSlowMotionResolution
            : (resolutions.contains(.p1080) ? .p1080 : resolutions[0])
        let rates = formatSelector.slowMotionFrameRates(for: devices, resolution: resolution)
        guard let rate = rates.contains(selectedSlowMotionFrameRate)
            ? selectedSlowMotionFrameRate
            : rates.last else { return nil }

        let supported = devices.filter { device in
            device.formats.contains { formatSelector.supportsSlowMotion($0, resolution: resolution, frameRate: rate) }
        }
        let desiredType: AVCaptureDevice.DeviceType = requestedZoom < 1
            ? .builtInUltraWideCamera
            : .builtInWideAngleCamera
        return supported.first(where: { $0.deviceType == desiredType })
            ?? supported.first(where: { !$0.isVirtualDevice })
            ?? supported.first
    }

    private func resetFocusAndExposureState() {
        pendingFocusLockWorkItem?.cancel()
        pendingFocusLockWorkItem = nil
        pendingFocusReturnWorkItem?.cancel()
        pendingFocusReturnWorkItem = nil
        guard let device = videoInput?.device else { return }

        do {
            try device.lockForConfiguration()
            let center = CGPoint(x: 0.5, y: 0.5)
            if device.isFocusPointOfInterestSupported {
                device.focusPointOfInterest = center
            }
            if device.isExposurePointOfInterestSupported {
                device.exposurePointOfInterest = center
            }
            if device.isFocusModeSupported(.continuousAutoFocus) {
                device.focusMode = .continuousAutoFocus
            }
            if device.isExposureModeSupported(.continuousAutoExposure) {
                device.exposureMode = .continuousAutoExposure
            }
            let target = clampedExposureBias(requestedExposureBias, for: device)
            device.setExposureTargetBias(target, completionHandler: nil)
            device.unlockForConfiguration()
            publish {
                self.isFocusExposureLocked = false
                self.exposureBias = target
            }
        } catch {
            showError("Couldn’t reset focus and exposure.")
        }
    }

    private func clampedExposureBias(_ bias: Float, for device: AVCaptureDevice) -> Float {
        let proToolsMinimum: Float = -2
        let proToolsMaximum: Float = 2
        return min(max(bias, max(device.minExposureTargetBias, proToolsMinimum)), min(device.maxExposureTargetBias, proToolsMaximum))
    }

    private func applyExposureBias(_ bias: Float) {
        guard let device = videoInput?.device else { return }
        let target = clampedExposureBias(bias, for: device)
        guard abs(target - requestedExposureBias) >= 0.001 else { return }
        do {
            try device.lockForConfiguration()
            device.setExposureTargetBias(target, completionHandler: nil)
            device.unlockForConfiguration()
            requestedExposureBias = target
            publish { self.exposureBias = target }
        } catch {
            showError("Couldn’t adjust the exposure.")
        }
    }

    private var requiresPhysicalWhiteBalanceInput: Bool {
        requestedWhiteBalancePreset != .auto && cameraPosition == .back
    }

    @discardableResult
    private func applyWhiteBalancePresetToCurrentCamera(_ preset: WhiteBalancePreset) -> Bool {
        guard let device = videoInput?.device else { return false }

        // Auto WB is supported on virtual and physical cameras. Manual presets are only
        // considered successful on the actual capture input so the UI can't claim a change
        // that isn't visible in the rear Video/Photo stream.
        let applied = applyWhiteBalancePreset(preset, to: device)

        // Configure only the input actually owned by this capture session.
        return applied
    }

    @discardableResult
    private func synchronizeWhiteBalanceAfterConfiguration() -> Bool {
        let preset = requestedWhiteBalancePreset
        guard applyWhiteBalancePresetToCurrentCamera(preset) else {
            if preset != .auto {
                requestedWhiteBalancePreset = .auto
                _ = applyWhiteBalancePresetToCurrentCamera(.auto)
                publish { self.whiteBalancePreset = .auto }
                showError("White balance reset to Auto because this camera configuration doesn’t support that preset.")
            } else {
                showError("Auto white balance is unavailable on this camera configuration.")
            }
            return false
        }
        publish { self.whiteBalancePreset = preset }
        return true
    }






    @discardableResult
    private func applyWhiteBalancePreset(_ preset: WhiteBalancePreset, to device: AVCaptureDevice) -> Bool {
        do {
            try device.lockForConfiguration()
            defer { device.unlockForConfiguration() }

            if preset == .auto {
                if device.isWhiteBalanceModeSupported(.continuousAutoWhiteBalance) {
                    device.whiteBalanceMode = .continuousAutoWhiteBalance
                    return true
                }
                if device.isWhiteBalanceModeSupported(.autoWhiteBalance) {
                    device.whiteBalanceMode = .autoWhiteBalance
                    return true
                }
                return false
            }

            guard let temperature = preset.temperature,
                  device.isWhiteBalanceModeSupported(.locked) else {
                return false
            }

            let values = AVCaptureDevice.WhiteBalanceTemperatureAndTintValues(temperature: temperature, tint: preset.tint)
            if #available(iOS 26.0, *) {
                device.setWhiteBalanceModeLocked(whiteBalanceTemperatureAndTintValues: values, handler: nil)
                return true
            }
            guard device.isLockingWhiteBalanceWithCustomDeviceGainsSupported else { return false }
            var gains = device.deviceWhiteBalanceGains(for: values)
            let maximum = device.maxWhiteBalanceGain
            gains.redGain = min(max(gains.redGain, 1), maximum)
            gains.greenGain = min(max(gains.greenGain, 1), maximum)
            gains.blueGain = min(max(gains.blueGain, 1), maximum)
            device.setWhiteBalanceModeLocked(with: gains, completionHandler: nil)
            return true
        } catch {
            return false
        }
    }

    private func configureFocusAndExposure(at point: CGPoint, lockAfterFocusing: Bool) {
        guard let device = videoInput?.device else { return }
        pendingFocusLockWorkItem?.cancel()
        pendingFocusReturnWorkItem?.cancel()
        pendingFocusLockWorkItem = nil
        pendingFocusReturnWorkItem = nil

        let clampedPoint = CGPoint(
            x: min(max(point.x, 0), 1),
            y: min(max(point.y, 0), 1)
        )

        do {
            try device.lockForConfiguration()
            if device.isFocusPointOfInterestSupported {
                device.focusPointOfInterest = clampedPoint
            }
            if device.isFocusModeSupported(.autoFocus) {
                device.focusMode = .autoFocus
            } else if device.isFocusModeSupported(.continuousAutoFocus) {
                device.focusMode = .continuousAutoFocus
            }

            if device.isExposurePointOfInterestSupported {
                device.exposurePointOfInterest = clampedPoint
            }
            if device.isExposureModeSupported(.continuousAutoExposure) {
                device.exposureMode = .continuousAutoExposure
            } else if device.isExposureModeSupported(.autoExpose) {
                device.exposureMode = .autoExpose
            }
            device.unlockForConfiguration()
            publish { self.isFocusExposureLocked = false }
        } catch {
            showError("Couldn’t set focus and exposure.")
            return
        }

        let deviceID = device.uniqueID
        let deadline = Date().addingTimeInterval(1.25)

        if lockAfterFocusing {
            func attemptLock() {
                guard let current = self.videoInput?.device,
                      current.uniqueID == deviceID else { return }

                if (current.isAdjustingFocus || current.isAdjustingExposure), Date() < deadline {
                    let retry = DispatchWorkItem { [weak self] in
                        guard let self else { return }
                        self.sessionQueue.async { attemptLock() }
                    }
                    self.pendingFocusLockWorkItem = retry
                    self.sessionQueue.asyncAfter(deadline: .now() + 0.08, execute: retry)
                    return
                }

                do {
                    try current.lockForConfiguration()
                    let canLockFocus = current.isFocusModeSupported(.locked)
                    let canLockExposure = current.isExposureModeSupported(.locked)
                    if canLockFocus { current.focusMode = .locked }
                    if canLockExposure { current.exposureMode = .locked }
                    current.unlockForConfiguration()
                    self.publish { self.isFocusExposureLocked = canLockFocus || canLockExposure }
                } catch {
                    self.showError("Couldn’t lock focus and exposure.")
                }
            }
            attemptLock()
        } else {
            let returnWork = DispatchWorkItem { [weak self] in
                guard let self,
                      let current = self.videoInput?.device,
                      current.uniqueID == deviceID,
                      !self.isFocusExposureLocked else { return }
                do {
                    try current.lockForConfiguration()
                    if current.isFocusModeSupported(.continuousAutoFocus) {
                        current.focusMode = .continuousAutoFocus
                    }
                    if current.isExposureModeSupported(.continuousAutoExposure) {
                        current.exposureMode = .continuousAutoExposure
                    }
                    current.unlockForConfiguration()
                } catch {
                    // The next focus interaction or mode change retries this harmless reset.
                }
            }
            pendingFocusReturnWorkItem = returnWork
            sessionQueue.asyncAfter(deadline: .now() + 1.0, execute: returnWork)
        }
    }

    @discardableResult
    private func applyActiveModeFormat(preferVirtualCamera: Bool = true) -> Bool {
        switch captureMode {
        case .photo:
            return applyBestPhotoFormat(preferVirtualCamera: preferVirtualCamera)
        case .sloMo:
            return applySlowMotionFormat()
        case .video:
            return applySelectedFormat(preferVirtualCamera: preferVirtualCamera)
        }
    }

    private func photoMegapixelOptions(for dimensions: CMVideoDimensions, aspect: String) -> [Int] {
        let width = Double(dimensions.width)
        let height = Double(dimensions.height)
        guard width > 0, height > 0 else { return Array((1...12).reversed()) }

        let pixels: Double
        if aspect == "1:1" {
            let side = min(width, height)
            pixels = side * side
        } else {
            let targetRatio = width >= height ? (4.0 / 3.0) : (3.0 / 4.0)
            if width / height > targetRatio {
                let croppedWidth = height * targetRatio
                pixels = croppedWidth * height
            } else {
                let croppedHeight = width / targetRatio
                pixels = width * croppedHeight
            }
        }

        let megapixels = pixels / 1_000_000.0
        let rounded = megapixels.rounded()
        let maximumNative = abs(megapixels - rounded) < 0.35 ? Int(rounded) : Int(megapixels.rounded(.down))
        let maximum = max(1, min(12, maximumNative))
        return Array((1...maximum).reversed())
    }

    private func updatePhotoMegapixelAvailability(for dimensions: CMVideoDimensions, aspect: String) {
        let options = photoMegapixelOptions(for: dimensions, aspect: aspect)
        let effective = options.contains(preferredPhotoMegapixels) ? preferredPhotoMegapixels : (options.first ?? 1)
        publish {
            self.supportedPhotoMegapixels = options
            self.selectedPhotoMegapixels = effective
            self.currentPhotoResolutionLabel = "\(effective) MP"
            self.currentPhotoPixelCount = Int64(effective) * 1_000_000
        }
    }

    @discardableResult
    private func applyBestPhotoFormat(preferVirtualCamera: Bool = true) -> Bool {
        let devices = capabilityDevices(for: cameraPosition.avPosition)
        guard !devices.isEmpty else {
            showError("Photo capture is unavailable on this camera.")
            return false
        }

        let physical = desiredPhysicalDevice(in: devices, forDisplayedZoom: requestedZoom)
        let desiredDevice = preferVirtualCamera
            ? (devices.first(where: { $0.isVirtualDevice }) ?? physical ?? devices.first)
            : (physical ?? devices.first(where: { !$0.isVirtualDevice }) ?? devices.first)

        guard let desiredDevice, let photoChoice = formatSelector.bestPhotoFormat(for: desiredDevice) else {
            showError("Full-resolution photos aren’t available on this camera.")
            return false
        }

        let previewRange = photoChoice.format.videoSupportedFrameRateRanges.first {
            $0.minFrameRate <= 30 && $0.maxFrameRate >= 30
        } ?? photoChoice.format.videoSupportedFrameRateRanges.first
        let previewFPS = min(max(30.0, previewRange?.minFrameRate ?? 30), previewRange?.maxFrameRate ?? 30)

        guard let displayedZoom = applyAtomicCaptureConfiguration(
            device: desiredDevice,
            format: photoChoice.format,
            frameRate: previewFPS,
            photoDimensions: photoChoice.dimensions
        ) else {
            showError("Couldn’t configure full-resolution Photo mode.")
            return false
        }

        nativePhotoDimensions = photoChoice.dimensions
        isUsingVideoPreviewProxy = false
        isUsingSlowMotionPreview = false
        let minimum = minimumSupportedZoom(for: desiredDevice)
        let maximum = maximumSupportedZoom(for: desiredDevice)
        publish {
            self.minimumZoomFactor = minimum
            self.maximumZoomFactor = maximum
            self.zoomFactor = displayedZoom
            self.zoomLabel = self.formattedZoomLabel(for: displayedZoom)
            self.torchAvailable = desiredDevice.hasTorch && desiredDevice.isTorchAvailable
            self.isTorchOn = desiredDevice.hasTorch && desiredDevice.torchMode == .on
        }
        updatePhotoMegapixelAvailability(
            for: photoChoice.dimensions,
            aspect: UserDefaults.standard.string(forKey: "photoAspect") ?? "4:3"
        )
        resetFocusAndExposureState()
        synchronizeWhiteBalanceAfterConfiguration()
        return true
    }



    private func minimumSupportedZoom(for device: AVCaptureDevice) -> CGFloat {
        max(0.5, displayedZoomFactor(for: device.minAvailableVideoZoomFactor, device: device))
    }

    private func maximumSupportedZoom(for device: AVCaptureDevice) -> CGFloat {
        min(8, displayedZoomFactor(for: device.maxAvailableVideoZoomFactor, device: device))
    }

    private func snappedZoomFactor(_ requestedFactor: CGFloat, for device: AVCaptureDevice) -> CGFloat {
        let minimum = minimumSupportedZoom(for: device)
        let maximum = maximumSupportedZoom(for: device)
        let clamped = min(max(requestedFactor, minimum), maximum)

        if minimum <= 0.5, abs(clamped - 0.5) < 0.10 {
            return 0.5
        }
        if abs(clamped - 1) < 0.16 {
            return 1
        }
        return clamped
    }

    private func wideAngleDeviceZoomFactor(for device: AVCaptureDevice) -> CGFloat {
        if device.deviceType == .builtInUltraWideCamera { return 2 }
        if device.deviceType == .builtInTelephotoCamera {
            return 1 / max(telephotoOpticalFactor(for: device), 1)
        }
        let hasUltraWide = device.constituentDevices.contains { $0.deviceType == .builtInUltraWideCamera }
        guard hasUltraWide, let switchFactor = device.virtualDeviceSwitchOverVideoZoomFactors.first else {
            return 1
        }
        return CGFloat(switchFactor.doubleValue)
    }

    private func displayedZoomFactor(for deviceZoomFactor: CGFloat, device: AVCaptureDevice) -> CGFloat {
        deviceZoomFactor / wideAngleDeviceZoomFactor(for: device)
    }

    private func deviceZoomFactor(for displayedZoomFactor: CGFloat, device: AVCaptureDevice) -> CGFloat {
        let requested = displayedZoomFactor * wideAngleDeviceZoomFactor(for: device)
        return min(max(requested, device.minAvailableVideoZoomFactor), device.maxAvailableVideoZoomFactor)
    }

    private func formattedZoomLabel(for zoomFactor: CGFloat) -> String {
        abs(zoomFactor.rounded() - zoomFactor) < 0.01
            ? "\(Int(zoomFactor.rounded()))×"
            : String(format: "%.1f×", zoomFactor)
    }



    @discardableResult
    private func applySelectedFormat(
        preferVirtualCamera: Bool = true,
        allowSmoothPreview: Bool = true,
        requestedResolution: VideoResolution? = nil,
        requestedFrameRate: VideoFrameRate? = nil,
        qualityRequestID: UInt64? = nil,
        requestedPosition: CameraPosition? = nil
    ) -> Bool {
        if let qualityRequestID, !qualityRequests.isLatest(qualityRequestID) { return false }
        let targetPosition = requestedPosition ?? cameraPosition
        let devices = capabilityDevices(for: targetPosition.avPosition)
        let available = formatSelector.availableResolutions(for: devices)
        guard !available.isEmpty else {
            if qualityRequests.isCurrent(qualityRequestID) {
                showError("Video isn’t available on this camera with the selected codec.")
            }
            return false
        }
        let selection = formatSelector.validSelection(
            for: devices,
            availableResolutions: available,
            requestedResolution: requestedResolution,
            requestedFrameRate: requestedFrameRate
        )
        let supportedDevices = devices.filter { device in
            device.formats.contains {
                self.formatSelector.format($0, supports: selection.resolution, at: selection.frameRate) && self.formatSelector.formatSupportsSelectedCodec($0)
            }
        }

        publish {
            if let qualityRequestID {
                guard self.qualityRequests.isLatest(qualityRequestID),
                      self.captureMode == .video,
                      self.cameraPosition == targetPosition else { return }
            }
            let wasSuppressing = self.suppressPreferencePersistence
            self.suppressPreferencePersistence = true
            self.selectedResolution = selection.resolution
            self.selectedFrameRate = selection.frameRate
            self.supportedResolutions = available
            self.supportedFrameRates = selection.supportedFrameRates
            self.suppressPreferencePersistence = wasSuppressing
        }

        // Rear 4K60 stays on the real selected 4K60 format while idle so Record never needs a
        // proxy-to-recording rebuild. When Apple's Dual-Wide/Triple virtual device itself exposes
        // this exact 4K60 + codec combination, keep that one input attached and let AVFoundation
        // switch its physical constituents while zooming. Manual WB still deliberately chooses a
        // physical input because locked custom gains are not equivalent on virtual cameras.
        _ = allowSmoothPreview
        let isRear4K60 = targetPosition == .back &&
            selection.resolution == .p4k && selection.frameRate == .fps60
        let appleStyle4K60Device = isRear4K60 && preferVirtualCamera
            ? supportedDevices.first(where: { self.lensTransitionCoordinator.isRearVirtualLensSystem($0) })
            : nil
        let physicalSupportedDevices = supportedDevices.filter { !$0.isVirtualDevice }
        let forcePhysical4K60 = isRear4K60 && appleStyle4K60Device == nil && !physicalSupportedDevices.isEmpty
        let lensCandidates = forcePhysical4K60 ? physicalSupportedDevices : supportedDevices
        let physical = desiredPhysicalDevice(in: lensCandidates, forDisplayedZoom: requestedZoom)
        let desiredDevice: AVCaptureDevice?
        if let appleStyle4K60Device {
            desiredDevice = appleStyle4K60Device
        } else if forcePhysical4K60 {
            desiredDevice = physical ?? physicalSupportedDevices.first
        } else {
            desiredDevice = preferVirtualCamera
                ? (supportedDevices.first(where: { $0.isVirtualDevice }) ?? physical ?? supportedDevices.first)
                : (physical ?? supportedDevices.first(where: { !$0.isVirtualDevice }) ?? supportedDevices.first)
        }
        guard let desiredDevice,
              let selectedFormat = formatSelector.preferredRecordingFormat(for: desiredDevice, resolution: selection.resolution, rate: selection.frameRate) else {
            if qualityRequests.isCurrent(qualityRequestID) {
                showError("This video quality isn’t available on this lens.")
            }
            return false
        }

        guard let displayed = applyAtomicCaptureConfiguration(
            device: desiredDevice,
            format: selectedFormat,
            frameRate: Double(selection.frameRate.rawValue)
        ) else {
            if qualityRequests.isCurrent(qualityRequestID) {
                showError("Couldn’t set the video quality.")
            }
            return false
        }

        isUsingVideoPreviewProxy = false
        isUsingSlowMotionPreview = false
        _ = configureMovieOutputSettings()
        let zoomDevices = forcePhysical4K60 ? physicalSupportedDevices : [desiredDevice]
        let minZoom = zoomDevices.map { minimumSupportedZoom(for: $0) }.min() ?? minimumSupportedZoom(for: desiredDevice)
        let maxZoom = zoomDevices.map { maximumSupportedZoom(for: $0) }.max() ?? maximumSupportedZoom(for: desiredDevice)
        publish {
            if let qualityRequestID {
                guard self.qualityRequests.isLatest(qualityRequestID),
                      self.captureMode == .video,
                      self.cameraPosition == targetPosition else { return }
            }
            self.minimumZoomFactor = minZoom
            self.maximumZoomFactor = maxZoom
            self.zoomFactor = displayed
            self.zoomLabel = self.formattedZoomLabel(for: displayed)
            self.torchAvailable = desiredDevice.hasTorch && desiredDevice.isTorchAvailable
            self.isTorchOn = desiredDevice.hasTorch && desiredDevice.torchMode == .on
        }
        resetFocusAndExposureState()
        synchronizeWhiteBalanceAfterConfiguration()
        return true
    }

    private func activeVideoFormatMatchesSelection() -> Bool {
        guard let device = videoInput?.device else { return false }
        let dimensions = CMVideoFormatDescriptionGetDimensions(device.activeFormat.formatDescription)
        guard dimensions.width == selectedResolution.dimensions.width,
              dimensions.height == selectedResolution.dimensions.height else { return false }

        let requestedRate = Double(selectedFrameRate.rawValue)
        let duration = device.activeVideoMinFrameDuration.seconds
        return duration > 0 && abs(1 / duration - requestedRate) < 0.5
    }

    private func activeSlowMotionFormatMatchesSelection() -> Bool {
        guard let device = videoInput?.device else { return false }
        let dimensions = CMVideoFormatDescriptionGetDimensions(device.activeFormat.formatDescription)
        guard dimensions.width == selectedSlowMotionResolution.dimensions.width,
              dimensions.height == selectedSlowMotionResolution.dimensions.height else { return false }

        let requestedRate = Double(selectedSlowMotionFrameRate.rawValue)
        let duration = device.activeVideoMinFrameDuration.seconds
        return duration > 0 && abs(1 / duration - requestedRate) < 1
    }


    @discardableResult
    private func applySlowMotionFormat(
        allowPreview: Bool = true,
        requestedResolution: VideoResolution? = nil,
        requestedFrameRate: SlowMotionFrameRate? = nil,
        qualityRequestID: UInt64? = nil,
        requestedPosition: CameraPosition? = nil
    ) -> Bool {
        if let qualityRequestID, !qualityRequests.isLatest(qualityRequestID) { return false }
        let targetPosition = requestedPosition ?? cameraPosition
        let devices = capabilityDevices(for: targetPosition.avPosition)
        let allResolutions = formatSelector.slowMotionResolutions(for: devices)
        guard !allResolutions.isEmpty else {
            if qualityRequests.isCurrent(qualityRequestID) {
                showError("Slo-Mo isn’t available on this camera with the selected codec.")
            }
            return false
        }

        let wantedResolution = requestedResolution ?? selectedSlowMotionResolution
        let resolution = allResolutions.contains(wantedResolution)
            ? wantedResolution
            : (allResolutions.contains(.p1080) ? .p1080 : allResolutions[0])
        let allRates = formatSelector.slowMotionFrameRates(for: devices, resolution: resolution)
        guard !allRates.isEmpty else {
            if qualityRequests.isCurrent(qualityRequestID) {
                showError("Slo-Mo isn’t available at this resolution.")
            }
            return false
        }
        let wantedFrameRate = requestedFrameRate ?? selectedSlowMotionFrameRate
        let selectedRate = allRates.contains(wantedFrameRate)
            ? wantedFrameRate
            : (allRates.last ?? .fps120)

        let supportedDevices = devices.filter { device in
            device.formats.contains { formatSelector.supportsSlowMotion($0, resolution: resolution, frameRate: selectedRate) }
        }
        guard !supportedDevices.isEmpty else {
            if qualityRequests.isCurrent(qualityRequestID) {
                showError("\(selectedRate.rawValue) fps Slo-Mo isn’t available on this camera.")
            }
            return false
        }

        // Slo-Mo stays on the actual selected HFR physical format while idle. This moves the
        // expensive input/format work away from the Record button. The preview and recording now
        // use the same 120/240 fps configuration; physical lens changes are covered separately.
        _ = allowPreview
        let physicalRecordingDevices = supportedDevices.filter { !$0.isVirtualDevice }
        let recordingDevices = physicalRecordingDevices.isEmpty ? supportedDevices : physicalRecordingDevices
        let sloMoMinimumZoom = recordingDevices.map { minimumSupportedZoom(for: $0) }.min() ?? 1
        let sloMoMaximumZoom = recordingDevices.map { maximumSupportedZoom(for: $0) }.max() ?? 1
        requestedZoom = min(max(requestedZoom, sloMoMinimumZoom), sloMoMaximumZoom)

        let physical = desiredPhysicalDevice(in: recordingDevices, forDisplayedZoom: requestedZoom)
        // Recording and manual-WB paths use a real constituent camera. This guarantees that the
        // selected lens really supports the requested HFR format instead of relying on a virtual
        // camera format that cannot encode the requested 120/240 fps stream.
        let desiredDevice = physical
            ?? recordingDevices.first(where: { !$0.isVirtualDevice })
            ?? recordingDevices.first
        guard let desiredDevice,
              let hfrFormat = formatSelector.bestSlowMotionFormat(for: desiredDevice, resolution: resolution, frameRate: selectedRate) else {
            if qualityRequests.isCurrent(qualityRequestID) {
                showError("\(selectedRate.rawValue) fps Slo-Mo isn’t available on this lens.")
            }
            return false
        }

        let requestedFPS = Double(selectedRate.rawValue)
        guard let displayed = applyAtomicCaptureConfiguration(
            device: desiredDevice,
            format: hfrFormat,
            frameRate: requestedFPS
        ) else {
            if qualityRequests.isCurrent(qualityRequestID) {
                showError("Couldn’t set the Slo-Mo quality.")
            }
            return false
        }

        isUsingSlowMotionPreview = false
        isUsingVideoPreviewProxy = false
        _ = configureMovieOutputSettings()

        let lensResolutions = formatSelector.slowMotionResolutions(for: [desiredDevice])
        let lensRates = formatSelector.slowMotionFrameRates(for: [desiredDevice], resolution: resolution)
        publish {
            if let qualityRequestID {
                guard self.qualityRequests.isLatest(qualityRequestID),
                      self.captureMode == .sloMo,
                      self.cameraPosition == targetPosition else { return }
            }
            let wasSuppressing = self.suppressPreferencePersistence
            self.suppressPreferencePersistence = true
            self.supportedSlowMotionResolutions = lensResolutions.isEmpty ? allResolutions : lensResolutions
            self.selectedSlowMotionResolution = resolution
            self.supportedSlowMotionFrameRates = lensRates.isEmpty ? allRates : lensRates
            self.selectedSlowMotionFrameRate = selectedRate
            self.suppressPreferencePersistence = wasSuppressing
            self.minimumZoomFactor = sloMoMinimumZoom
            self.maximumZoomFactor = sloMoMaximumZoom
            self.zoomFactor = displayed
            self.zoomLabel = self.formattedZoomLabel(for: displayed)
            self.torchAvailable = desiredDevice.hasTorch && desiredDevice.isTorchAvailable
            self.isTorchOn = desiredDevice.hasTorch && desiredDevice.torchMode == .on
        }
        resetFocusAndExposureState()
        synchronizeWhiteBalanceAfterConfiguration()
        return true
    }





    private func movieOutputSettingsMatchCurrentConfiguration() -> Bool {
        guard let connection = movieOutput.connection(with: .video) else { return false }
        let preferred: AVVideoCodecType = selectedVideoCodec == "H264" ? .h264 : .hevc
        let applied = movieOutput.outputSettings(for: connection)
        guard (applied[AVVideoCodecKey] as? String) == preferred.rawValue else { return false }

        let shouldMirror = cameraPosition == .front && UserDefaults.standard.bool(forKey: "mirrorSelfies")
        if connection.isVideoMirroringSupported, connection.isVideoMirrored != shouldMirror { return false }

        if connection.isVideoStabilizationSupported {
            let expected: AVCaptureVideoStabilizationMode = captureMode == .video && isVideoStabilizationEnabled ? .auto : .off
            if connection.preferredVideoStabilizationMode != expected { return false }
        }

        if videoCompression != .high {
            guard let compression = applied[AVVideoCompressionPropertiesKey] as? [String: Any],
                  let bitrate = compression[AVVideoAverageBitRateKey] as? NSNumber else { return false }
            let expected = estimatedVideoBitsPerSecond
            if abs(bitrate.doubleValue - expected) > max(expected * 0.20, 1_000_000) { return false }
        }
        return true
    }

    @discardableResult
    private func configureMovieOutputSettings() -> Bool {
        guard let connection = movieOutput.connection(with: .video) else { return false }

        let shouldMirror = cameraPosition == .front && UserDefaults.standard.bool(forKey: "mirrorSelfies")
        if connection.isVideoMirroringSupported {
            connection.automaticallyAdjustsVideoMirroring = false
            connection.isVideoMirrored = shouldMirror
        }

        let shouldStabilize = captureMode == .video && isVideoStabilizationEnabled
        if connection.isVideoStabilizationSupported {
            connection.preferredVideoStabilizationMode = shouldStabilize ? .auto : .off
        }

        let supportedKeys = Set(movieOutput.supportedOutputSettingsKeys(for: connection))
        let preferred: AVVideoCodecType = selectedVideoCodec == "H264" ? .h264 : .hevc
        let codecAvailable = movieOutput.availableVideoCodecTypes.contains(preferred) && supportedKeys.contains(AVVideoCodecKey)
        let message: String? = codecAvailable ? nil : (preferred == .h264 && movieOutput.availableVideoCodecTypes.contains(.hevc)
            ? "This camera configuration requires HEVC / H.265. Select HEVC, or lower the resolution or frame rate to use H.264."
            : "The selected codec is unavailable for this camera configuration.")
        publish { self.codecAvailabilityMessage = message }
        guard codecAvailable else { return false }

        var settings: [String: Any] = [AVVideoCodecKey: preferred]
        if videoCompression != .high, supportedKeys.contains(AVVideoCompressionPropertiesKey) {
            settings[AVVideoCompressionPropertiesKey] = [
                AVVideoAverageBitRateKey: Int(estimatedVideoBitsPerSecond)
            ]
        }

        movieOutput.setOutputSettings(nil, for: connection)
        movieOutput.setOutputSettings(settings, for: connection)

        let applied = movieOutput.outputSettings(for: connection)
        guard (applied[AVVideoCodecKey] as? String) == preferred.rawValue else { return false }
        if connection.isVideoMirroringSupported, connection.isVideoMirrored != shouldMirror { return false }
        if connection.isVideoStabilizationSupported {
            let expected: AVCaptureVideoStabilizationMode = shouldStabilize ? .auto : .off
            if connection.preferredVideoStabilizationMode != expected { return false }
        }
        if videoCompression != .high,
           let compression = applied[AVVideoCompressionPropertiesKey] as? [String: Any],
           let bitrate = compression[AVVideoAverageBitRateKey] as? NSNumber {
            let expected = estimatedVideoBitsPerSecond
            if abs(bitrate.doubleValue - expected) > max(expected * 0.20, 1_000_000) {
                return false
            }
        }
        return true
    }






    private func applyCaptureRotation(to connection: AVCaptureConnection?) {
        guard let connection,
              let angle = rotationCoordinator?.videoRotationAngleForHorizonLevelCapture,
              connection.isVideoRotationAngleSupported(angle) else { return }
        connection.videoRotationAngle = angle
    }

    private func beginPhotoCapture() {
        guard activePhotoCaptureID == nil else { return }
        guard session.isRunning else {
            burstRemaining = 0
            burstStopRequested = false
            publish { self.isCapturingPhoto = false }
            showError("Camera isn’t ready yet.")
            return
        }

        let isBurst = burstRemaining > 0
        let aspect = isBurst ? burstAspect : (UserDefaults.standard.string(forKey: "photoAspect") ?? "4:3")
        let megapixels = isBurst ? burstMegapixels : selectedPhotoMegapixels
        let useHEIC = photoFileFormat == "HEIC" && photoOutput.availablePhotoCodecTypes.contains(.hevc)
        if let connection = photoOutput.connection(with: .video) {
            if connection.isVideoMirroringSupported {
                connection.automaticallyAdjustsVideoMirroring = false
                connection.isVideoMirrored = cameraPosition == .front && UserDefaults.standard.bool(forKey: "mirrorSelfies")
            }
            applyCaptureRotation(to: connection)
        }

        let settings = useHEIC
            ? AVCapturePhotoSettings(format: [AVVideoCodecKey: AVVideoCodecType.hevc])
            : AVCapturePhotoSettings(format: [AVVideoCodecKey: AVVideoCodecType.jpeg])

        // Balanced is AVFoundation's default speed/quality tradeoff. It avoids the extra
        // shot-to-shot latency of .quality while keeping more quality than .speed.
        settings.photoQualityPrioritization = .balanced
        let dimensions = photoOutput.maxPhotoDimensions
        if dimensions.width > 0, dimensions.height > 0 {
            settings.maxPhotoDimensions = dimensions
        }

        let captureID = settings.uniqueID
        photoCaptureContexts[captureID] = PhotoCaptureContext(
            aspect: aspect,
            megapixels: megapixels,
            filename: nextMediaFilename(fileExtension: useHEIC ? "heic" : "jpg"),
            isBurst: isBurst
        )
        activePhotoCaptureID = captureID
        activePhotoCaptureIsBurst = isBurst
        refreshAvailableStorage()
        photoOutput.capturePhoto(with: settings, delegate: self)
    }

    private func beginRecording() {
        guard recordingState.requestsRecording, session.isRunning, movieOutput.isRecording == false else {
            transitionRecordingState(to: .idle, resetClock: true)
            return
        }

        var reconfiguredForRecording = false
        if captureMode == .video {
            if isUsingVideoPreviewProxy || !activeVideoFormatMatchesSelection() {
                reconfiguredForRecording = true
                guard applySelectedFormat(
                    preferVirtualCamera: !requiresPhysicalWhiteBalanceInput,
                    allowSmoothPreview: false
                ), activeVideoFormatMatchesSelection() else {
                    transitionRecordingState(to: .idle, resetClock: true)
                    showError("Couldn’t prepare the selected recording quality.")
                    return
                }
            }
        } else if captureMode == .sloMo {
            let activeSloMoReady = activeSlowMotionFormatMatchesSelection() &&
                videoInput.map {
                    formatSelector.supportsSlowMotion(
                        $0.device.activeFormat,
                        resolution: selectedSlowMotionResolution,
                        frameRate: selectedSlowMotionFrameRate
                    )
                } == true && !isUsingSlowMotionPreview

            if !activeSloMoReady {
                reconfiguredForRecording = true
                guard applySlowMotionFormat(allowPreview: false),
                      activeSlowMotionFormatMatchesSelection(),
                      let device = videoInput?.device,
                      formatSelector.supportsSlowMotion(
                          device.activeFormat,
                          resolution: selectedSlowMotionResolution,
                          frameRate: selectedSlowMotionFrameRate
                      ),
                      !isUsingSlowMotionPreview else {
                    transitionRecordingState(to: .idle, resetClock: true)
                    showError("Couldn’t start the selected Slo-Mo frame rate.")
                    return
                }
            }
        }

        guard movieOutputSettingsMatchCurrentConfiguration() || configureMovieOutputSettings() else {
            transitionRecordingState(to: .idle, resetClock: true)
            showError("\(selectedVideoCodec == "H264" ? "H.264" : "HEVC") isn’t available at this resolution/FPS on this lens.")
            return
        }

        applyCaptureRotation(to: movieOutput.connection(with: .video))
        movieOutput.metadata = CameraMovieMetadata.items(isSlowMotion: captureMode == .sloMo)
        refreshAvailableStorage()

        // When the idle preview is already the exact recording configuration (the normal case for
        // rear 4K60 and Slo-Mo now), start immediately instead of imposing the old AF/AE wait. Only
        // keep the settle window for the recovery path that actually had to reconfigure hardware.
        let readinessDeadline = reconfiguredForRecording ? Date().addingTimeInterval(1.0) : Date()
        startMovieOutputWhenReady(deadline: readinessDeadline)
    }

    private func startMovieOutputWhenReady(deadline: Date) {
        guard recordingState.requestsRecording, !movieOutput.isRecording else { return }
        if let device = videoInput?.device,
           (device.isAdjustingFocus || device.isAdjustingExposure),
           Date() < deadline {
            sessionQueue.asyncAfter(deadline: .now() + 0.06) { [weak self] in
                self?.startMovieOutputWhenReady(deadline: deadline)
            }
            return
        }

        guard recordingState.requestsRecording else { return }
        let filename = nextMediaFilename(fileExtension: "mov")
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(filename)
        movieOutput.startRecording(to: url, recordingDelegate: self)
    }

    private func nextMediaFilename(fileExtension: String) -> String {
        let defaults = UserDefaults.standard
        let ext = fileExtension.lowercased()
        var number = defaults.integer(forKey: Self.mediaSequenceKey)
        if number < 1 || number > 9_999 { number = 1 }

        for _ in 0..<9_999 {
            let filename = String(format: "img_%04d.%@", number, ext)
            let tempURL = FileManager.default.temporaryDirectory.appendingPathComponent(filename)
            let next = number == 9_999 ? 1 : number + 1
            defaults.set(next, forKey: Self.mediaSequenceKey)
            let recoveryCollision = ext == "mov" && CameraRecoveryStore.containsRecording(named: filename)
            if !FileManager.default.fileExists(atPath: tempURL.path), !recoveryCollision {
                return filename
            }
            number = next
        }

        // Four digits are exhausted locally. Keep the lowercase prefix and add a short suffix
        // rather than overwriting an existing recording.
        return "img_\(UUID().uuidString.prefix(8).lowercased()).\(ext)"
    }

    private func synchronizeTorchState() {
        guard let device = videoInput?.device else {
            publish {
                self.torchAvailable = false
                self.isTorchOn = false
            }
            return
        }
        publish {
            self.torchAvailable = device.hasTorch && device.isTorchAvailable
            self.isTorchOn = device.hasTorch && device.torchMode == .on
        }
    }

    private func publish(_ update: @escaping () -> Void) {
        DispatchQueue.main.async(execute: update)
    }

    private func refreshRecoveryCount() {
        let count = CameraRecoveryStore.recordingCount()
        publish {
            if self.recoverableRecordingCount != count {
                self.recoverableRecordingCount = count
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

    private func beginBackgroundSaveIfNeeded() {
        guard backgroundSaveTask == .invalid else { return }
        DispatchQueue.main.async {
            guard self.backgroundSaveTask == .invalid else { return }
            self.backgroundSaveTask = UIApplication.shared.beginBackgroundTask(withName: "Finish camera save") { [weak self] in
                guard let self else { return }
                if self.backgroundSaveTask != .invalid {
                    UIApplication.shared.endBackgroundTask(self.backgroundSaveTask)
                    self.backgroundSaveTask = .invalid
                }
            }
        }
    }

    private func endBackgroundSaveIfPossible() {
        guard pendingVideoSaves == 0 else { return }
        DispatchQueue.main.async {
            guard self.backgroundSaveTask != .invalid else { return }
            UIApplication.shared.endBackgroundTask(self.backgroundSaveTask)
            self.backgroundSaveTask = .invalid
        }
    }

    private func finishFinalizingIfPossible() {
        guard pendingVideoSaves == 0 else { return }
        transitionRecordingState(to: .idle, resetClock: true)
        endBackgroundSaveIfPossible()
    }

    private func restoreIdleCaptureConfigurationAfterRecording() {
        guard !movieOutput.isRecording else { return }
        switch captureMode {
        case .video:
            if !activeVideoFormatMatchesSelection() {
                _ = applySelectedFormat(
                    preferVirtualCamera: !requiresPhysicalWhiteBalanceInput,
                    allowSmoothPreview: true
                )
            }
        case .sloMo:
            if !activeSlowMotionFormatMatchesSelection() {
                _ = applySlowMotionFormat(allowPreview: true)
            }
        case .photo:
            break
        }
    }

    @discardableResult
    private func saveVideoResourceToPhotos(
        _ fileURL: URL,
        runDiagnostics: Bool,
        recoveryRetry: Bool = false
    ) -> Bool {
        let sourceKey = fileURL.standardizedFileURL
        guard inFlightVideoSaves.insert(sourceKey).inserted else { return false }

        pendingVideoSaves += 1
        beginBackgroundSaveIfNeeded()

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
                    } else {
                        let preserved = CameraRecoveryStore.preserve(fileURL)
                        let detail = error?.localizedDescription ?? "Unknown Photos error"
                        if preserved != nil {
                            self.showError("Couldn’t save to Photos. The recording is kept in Recovery. \(detail)")
                        } else {
                            self.showError("Couldn’t save to Photos, and Recovery preservation could not be confirmed. \(detail)")
                        }
                    }

                    self.inFlightVideoSaves.remove(sourceKey)
                    self.pendingVideoSaves = max(self.pendingVideoSaves - 1, 0)
                    self.refreshRecoveryCount()
                    self.refreshAvailableStorage()
                    if self.recordingState.isFinalizing {
                        self.finishFinalizingIfPossible()
                    } else {
                        self.endBackgroundSaveIfPossible()
                    }
                }
            }
        }

        if runDiagnostics {
            ClipFrameDiagnostics.inspect(fileURL) { gaps in
                performSave(gaps)
            }
        } else {
            performSave(nil)
        }
        return true
    }

    func postStatus(_ message: String) {
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

    private func showError(_ message: String) {
        postStatus(message)
    }
}

extension CameraManager: AVCaptureFileOutputRecordingDelegate {
    func fileOutput(_ output: AVCaptureFileOutput, didStartRecordingTo fileURL: URL, from connections: [AVCaptureConnection]) {
        sessionQueue.async { [weak self] in
            guard let self else { return }

            if !self.recordingState.requestsRecording {
                self.transitionRecordingToDiscard()
                if self.movieOutput.isRecording { self.movieOutput.stopRecording() }
                return
            }

            self.startLiveMetrics()
            self.segmentTimer?.cancel()
            let splitDuration = self.recordingState.splitDuration
            if splitDuration > 0 {
                let timer = DispatchWorkItem { [weak self] in
                    guard let self, self.recordingState.requestsRecording, self.movieOutput.isRecording else { return }
                    self.transitionRecordingState(to: .stoppingToContinueSegment(splitDuration: splitDuration))
                    self.movieOutput.stopRecording()
                }
                self.segmentTimer = timer
                self.sessionQueue.asyncAfter(deadline: .now() + splitDuration, execute: timer)
            }

            self.transitionRecordingState(
                to: .recording(splitDuration: splitDuration),
                startClock: true
            )
        }
    }

    func fileOutput(_ output: AVCaptureFileOutput, didFinishRecordingTo outputFileURL: URL, from connections: [AVCaptureConnection], error: Error?) {
        let successful = error == nil || (error as NSError?)?.userInfo[AVErrorRecordingSuccessfullyFinishedKey] as? Bool == true

        sessionQueue.async { [weak self] in
            guard let self else { return }
            self.stopLiveMetrics()
            self.segmentTimer?.cancel()

            if self.recordingState.shouldDiscardWhenFinished {
                try? FileManager.default.removeItem(at: outputFileURL)
                self.transitionRecordingState(to: .idle, resetClock: true)
                self.restoreIdleCaptureConfigurationAfterRecording()
                return
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
                self.restoreIdleCaptureConfigurationAfterRecording()
                let suffix = retained == nil ? "" : " It is kept in Recovery."
                self.showError("Recording stopped: \(error?.localizedDescription ?? "Unknown error").\(suffix)")
                return
            }

            let diagnosticsEnabled = UserDefaults.standard.bool(forKey: "cameraHUDDroppedFrames")
            // Avoid decoding a completed split segment while the next HFR/4K segment is recording.
            self.saveVideoResourceToPhotos(
                outputFileURL,
                runDiagnostics: diagnosticsEnabled && !shouldContinue
            )

            if shouldContinue {
                self.transitionRecordingState(to: .starting(splitDuration: splitDuration))
                self.beginRecording()
            } else {
                self.transitionRecordingState(to: .finalizing, resetClock: true)
                self.restoreIdleCaptureConfigurationAfterRecording()
                self.finishFinalizingIfPossible()
            }
        }
    }
}


extension CameraManager: AVCapturePhotoCaptureDelegate {
    func photoOutput(_ output: AVCapturePhotoOutput, didFinishProcessingPhoto photo: AVCapturePhoto, error: Error?) {
        let captureID = photo.resolvedSettings.uniqueID
        guard error == nil, let data = photo.fileDataRepresentation() else {
            sessionQueue.async {
                self.photoCaptureContexts.removeValue(forKey: captureID)
                self.burstStopRequested = true
            }
            showError(error?.localizedDescription ?? "Couldn’t create the photo file.")
            return
        }

        sessionQueue.async { [weak self] in
            guard let self, let context = self.photoCaptureContexts[captureID] else { return }
            self.pendingPhotoSaves += 1
            if !context.isBurst {
                self.postStatus("Photo captured · saving…")
            }

            self.storageQueue.async {
                guard let result = PhotoAspectProcessor.process(
                    data,
                    aspect: context.aspect,
                    megapixels: context.megapixels
                ) else {
                    self.showError("Couldn’t process the photo. Please try again.")
                    self.completePhotoSave(captureID: captureID, context: context, success: false)
                    return
                }

                PHPhotoLibrary.shared().performChanges({
                    let request = PHAssetCreationRequest.forAsset()
                    let options = PHAssetResourceCreationOptions()
                    options.originalFilename = context.filename
                    request.addResource(with: .photo, data: result, options: options)
                }) { success, error in
                    if !success {
                        self.showError(error?.localizedDescription ?? "Couldn’t save the photo.")
                    }
                    self.completePhotoSave(captureID: captureID, context: context, success: success)
                }
            }
        }
    }

    private func completePhotoSave(captureID: Int64, context: PhotoCaptureContext, success: Bool) {
        sessionQueue.async {
            self.photoCaptureContexts.removeValue(forKey: captureID)
            self.pendingPhotoSaves = max(0, self.pendingPhotoSaves - 1)

            if !success {
                self.burstStopRequested = true
            } else if !context.isBurst {
                self.postStatus("Photo saved to Photos")
            } else if self.pendingPhotoSaves == 0,
                      self.activePhotoCaptureID == nil,
                      self.burstRemaining == 0 {
                self.postStatus("Photos saved to Photos")
            }

            if self.pendingPhotoSaves == 0 {
                self.refreshAvailableStorage()
            }
        }
    }

    func photoOutput(_ output: AVCapturePhotoOutput, didFinishCaptureFor resolvedSettings: AVCaptureResolvedPhotoSettings, error: Error?) {
        let captureID = resolvedSettings.uniqueID
        sessionQueue.async {
            guard self.activePhotoCaptureID == captureID else {
                if error != nil {
                    self.photoCaptureContexts.removeValue(forKey: captureID)
                }
                return
            }

            let wasBurst = self.activePhotoCaptureIsBurst
            self.activePhotoCaptureID = nil
            self.activePhotoCaptureIsBurst = false

            if let error {
                self.photoCaptureContexts.removeValue(forKey: captureID)
                self.burstRemaining = 0
                self.burstStopRequested = false
                self.publish { self.isCapturingPhoto = false }
                self.showError("Photo capture failed: \(error.localizedDescription)")
                return
            }

            if wasBurst {
                self.burstRemaining = max(0, self.burstRemaining - 1)
                if self.burstRemaining > 0 && !self.burstStopRequested && self.session.isRunning {
                    self.beginPhotoCapture()
                } else {
                    self.burstRemaining = 0
                    self.burstStopRequested = false
                    self.publish { self.isCapturingPhoto = false }
                }
            } else {
                // The hardware capture is finished. Cropping, resizing and Photos-library
                // saving can continue on storageQueue without making the shutter feel stuck.
                self.publish { self.isCapturingPhoto = false }
            }
        }
    }
}
