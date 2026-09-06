import AVFoundation
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
    @Published private(set) var recordingDuration: TimeInterval = 0
    @Published private(set) var availableStorageBytes: Int64 = 0
    @Published private(set) var currentPhotoResolutionLabel = "MAX"
    @Published private(set) var currentPhotoPixelCount: Int64 = 12_000_000
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
            UserDefaults.standard.set(selectedVideoCodec, forKey: "selectedVideoCodec")
            guard !suppressAutomaticReconfiguration else { return }
            sessionQueue.async { [weak self] in
                guard let self, !self.movieOutput.isRecording else { return }
                self.updateCapabilities()
                _ = self.applyActiveModeFormat(preferVirtualCamera: !self.requiresPhysicalWhiteBalanceInput)
            }
        }
    }
    @Published var photoFileFormat = UserDefaults.standard.string(forKey: "photoFileFormat") ?? "HEIC" {
        didSet { UserDefaults.standard.set(photoFileFormat, forKey: "photoFileFormat") }
    }
    @Published var videoCompression = VideoCompression(rawValue: UserDefaults.standard.string(forKey: "videoCompression") ?? "") ?? .high {
        didSet {
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
    private var videoInput: AVCaptureDeviceInput?
    private var durationTimer: Timer?
    private var recordingSessionStartedAt: Date?
    private var requestedZoom: CGFloat = 1
    private var requestedExposureBias: Float = 0
    private var requestedWhiteBalancePreset: WhiteBalancePreset = .auto
    private var pendingFocusLockWorkItem: DispatchWorkItem?
    private var pendingFocusReturnWorkItem: DispatchWorkItem?
    private var pendingPhotoFilename: String?
    private let zoomRequestLock = NSLock()
    private var latestZoomRequestID: UInt64 = 0
    private var latestCameraSwitchRequestID: UInt64 = 0
    private var latestWhiteBalanceRequestID: UInt64 = 0
    private var latestModeChangeRequestID: UInt64 = 0
    private var isUsingSlowMotionPreview = false
    private var isUsingVideoPreviewProxy = false
    private var recordingRequested = false
    private var recordingFinalizationRequested = false
    private var segmentTimer: DispatchWorkItem?
    private var continuingSegment = false
    private var segmentSeconds: Double = 0
    private var pendingVideoSaves = 0
    private var discardCurrentRecordingWhenFinished = false
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
        if UserDefaults.standard.bool(forKey: "rememberCaptureMode"),
           let saved = UserDefaults.standard.string(forKey: "lastCaptureMode"),
           let mode = CaptureMode(rawValue: saved) { captureMode = mode }
        installSessionObservers()
        recoverableRecordingCount = CameraRecoveryStore.recordings().count
    }

    deinit {
        sessionObserverTokens.forEach(NotificationCenter.default.removeObserver)
        if backgroundSaveTask != .invalid {
            let task = backgroundSaveTask
            DispatchQueue.main.async { UIApplication.shared.endBackgroundTask(task) }
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
        synchronizeTorchState()
        guard recordingRequested || movieOutput.isRecording else { return }

        continuingSegment = false
        segmentTimer?.cancel()

        if movieOutput.isRecording {
            recordingRequested = false
            recordingFinalizationRequested = true
            publish {
                self.isRecordingStarting = false
                self.isRecording = false
                self.isFinalizingRecording = true
            }
            postStatus("Recording interrupted · saving…")
            movieOutput.stopRecording()
        } else {
            recordingRequested = false
            recordingFinalizationRequested = false
            discardCurrentRecordingWhenFinished = true
            publish {
                self.isRecordingStarting = false
                self.isRecording = false
                self.isFinalizingRecording = false
            }
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
            let values = try? homeURL.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
            let bytes = values?.volumeAvailableCapacityForImportantUsage ?? 0
            self.publish { self.availableStorageBytes = max(bytes, 0) }
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
        return max(pixels * bytesPerPixel, photoFileFormat == "HEIC" ? 1_200_000 : 2_000_000)
    }

    func start() {
        sessionQueue.async { [weak self] in
            guard let self else { return }
            self.requestedZoom = 1
            self.configureSessionIfNeeded()
            self.refreshAvailableStorage()
            guard self.session.isRunning == false else {
                self.publish { self.isSessionRunning = true }
                return
            }
            self.session.startRunning()
            try? AVAudioSession.sharedInstance().setAllowHapticsAndSystemSoundsDuringRecording(true)
            self.publish { self.isSessionRunning = true }
        }
    }

    func stop() {
        sessionQueue.async { [weak self] in
            guard let self else { return }
            self.segmentTimer?.cancel()
            if self.movieOutput.isRecording {
                self.recordingRequested = false
                self.recordingFinalizationRequested = true
                self.publish {
                    self.isRecordingStarting = false
                    self.isRecording = false
                    self.isFinalizingRecording = true
                }
                self.movieOutput.stopRecording()
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
            self.continuingSegment = false
            self.segmentTimer?.cancel()

            if self.movieOutput.isRecording {
                self.recordingRequested = false
                self.recordingFinalizationRequested = true
                self.publish {
                    self.isRecordingStarting = false
                    self.isRecording = false
                    self.isFinalizingRecording = true
                }
                self.movieOutput.stopRecording()
            } else if self.recordingRequested {
                self.recordingRequested = false
                self.recordingFinalizationRequested = false
                self.discardCurrentRecordingWhenFinished = true
                self.publish {
                    self.isRecordingStarting = false
                    self.isRecording = false
                    self.isFinalizingRecording = false
                }
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
                try? AVAudioSession.sharedInstance().setAllowHapticsAndSystemSoundsDuringRecording(true)
            }
            self.publish { self.isSessionRunning = self.session.isRunning }
            self.synchronizeTorchState()
        }
    }

    func toggleTorch() {
        sessionQueue.async { [weak self] in
            guard let self, let device = self.videoInput?.device, device.hasTorch else { return }
            do {
                try device.lockForConfiguration()
                device.torchMode = device.torchMode == .on ? .off : .on
                let isOn = device.torchMode == .on
                device.unlockForConfiguration()
                self.publish { self.isTorchOn = isOn }
            } catch {
                self.showError("Couldn’t change the torch.")
            }
        }
    }

    func setZoomFactor(_ requestedFactor: CGFloat) {
        let requestID = nextZoomRequestID()
        sessionQueue.async { [weak self] in
            guard let self, self.isLatestZoomRequest(requestID),
                  let currentDevice = self.videoInput?.device else { return }

            let requested = min(max(requestedFactor, self.minimumZoomFactor), self.maximumZoomFactor)

            if !currentDevice.isVirtualDevice, currentDevice.position == .back {
                let desiredDevices = self.capabilityDevices(for: .back)
                let desiredPhysical = self.desiredPhysicalDevice(in: desiredDevices, forDisplayedZoom: requested)
                let wantsDifferentLens = desiredPhysical?.uniqueID != currentDevice.uniqueID

                if wantsDifferentLens {
                    if self.movieOutput.isRecording || self.isRecordingStarting {
                        self.showError("Stop recording to switch physical lenses.")
                        return
                    }

                    let previousRequested = self.requestedZoom
                    self.requestedZoom = requested
                    guard self.isLatestZoomRequest(requestID),
                          self.applyActiveModeFormat(preferVirtualCamera: !self.requiresPhysicalWhiteBalanceInput),
                          self.isLatestZoomRequest(requestID) else {
                        self.requestedZoom = previousRequested
                        return
                    }
                    // applyActiveModeFormat already applied and published the snapped zoom on the
                    // correct physical lens. Do not queue a second ramp after the lens switch.
                    return
                }
            }

            guard self.isLatestZoomRequest(requestID),
                  let device = self.videoInput?.device else { return }
            let factor = self.snappedZoomFactor(requested, for: device)
            do {
                try device.lockForConfiguration()
                let deviceFactor = self.deviceZoomFactor(for: factor, device: device)
                device.ramp(toVideoZoomFactor: deviceFactor, withRate: 12)
                device.unlockForConfiguration()
                guard self.isLatestZoomRequest(requestID) else { return }
                self.requestedZoom = factor
                self.publish {
                    self.zoomFactor = factor
                    self.zoomLabel = self.formattedZoomLabel(for: factor)
                }
            } catch {
                self.showError("Couldn’t change the zoom.")
            }
        }
    }

    private func nextZoomRequestID() -> UInt64 {
        zoomRequestLock.lock()
        defer { zoomRequestLock.unlock() }
        latestZoomRequestID &+= 1
        return latestZoomRequestID
    }

    private func isLatestZoomRequest(_ requestID: UInt64) -> Bool {
        zoomRequestLock.lock()
        defer { zoomRequestLock.unlock() }
        return requestID == latestZoomRequestID
    }

    private func nextCameraSwitchRequestID() -> UInt64 {
        zoomRequestLock.lock()
        defer { zoomRequestLock.unlock() }
        latestCameraSwitchRequestID &+= 1
        return latestCameraSwitchRequestID
    }

    private func isLatestCameraSwitchRequest(_ requestID: UInt64) -> Bool {
        zoomRequestLock.lock()
        defer { zoomRequestLock.unlock() }
        return requestID == latestCameraSwitchRequestID
    }

    private func nextWhiteBalanceRequestID() -> UInt64 {
        zoomRequestLock.lock()
        defer { zoomRequestLock.unlock() }
        latestWhiteBalanceRequestID &+= 1
        return latestWhiteBalanceRequestID
    }

    private func isLatestWhiteBalanceRequest(_ requestID: UInt64) -> Bool {
        zoomRequestLock.lock()
        defer { zoomRequestLock.unlock() }
        return requestID == latestWhiteBalanceRequestID
    }

    private func nextModeChangeRequestID() -> UInt64 {
        zoomRequestLock.lock()
        defer { zoomRequestLock.unlock() }
        latestModeChangeRequestID &+= 1
        return latestModeChangeRequestID
    }

    private func isLatestModeChangeRequest(_ requestID: UInt64) -> Bool {
        zoomRequestLock.lock()
        defer { zoomRequestLock.unlock() }
        return requestID == latestModeChangeRequestID
    }


    func switchCamera() {
        guard !isRecording, !isRecordingStarting, !isFinalizingRecording, !isCapturingPhoto else { return }
        let previous = cameraPosition
        let target: CameraPosition = previous == .back ? .front : .back
        let requestID = nextCameraSwitchRequestID()

        cameraPosition = target
        loadCameraPreferences(for: target)

        sessionQueue.async { [weak self] in
            guard let self, self.isLatestCameraSwitchRequest(requestID) else { return }
            guard self.applyActiveModeFormat(preferVirtualCamera: !self.requiresPhysicalWhiteBalanceInput) else {
                guard self.isLatestCameraSwitchRequest(requestID) else { return }
                self.publish {
                    self.cameraPosition = previous
                    self.loadCameraPreferences(for: previous)
                }
                self.showError("That camera is unavailable.")
                return
            }
            guard self.isLatestCameraSwitchRequest(requestID) else { return }
            self.updateCapabilities()
            self.synchronizeTorchState()
        }
    }

    func selectCaptureMode(_ mode: CaptureMode) {
        guard !isRecording, !isRecordingStarting, !isFinalizingRecording, !isCapturingPhoto, captureMode != mode else { return }
        let requestID = nextModeChangeRequestID()
        captureMode = mode
        UserDefaults.standard.set(mode.rawValue, forKey: "lastCaptureMode")
        sessionQueue.async { [weak self] in
            guard let self, self.isLatestModeChangeRequest(requestID) else { return }
            _ = self.applyActiveModeFormat(preferVirtualCamera: !self.requiresPhysicalWhiteBalanceInput)
        }
    }

    func capturePhoto() {
        guard captureMode == .photo, !isRecording, !isRecordingStarting, !isFinalizingRecording, !isCapturingPhoto else { return }
        isCapturingPhoto = true
        sessionQueue.async { [weak self] in
            guard let self else { return }
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
        sessionQueue.async { [weak self] in
            self?.applyExposureBias(bias)
        }
    }

    func selectWhiteBalancePreset(_ preset: WhiteBalancePreset) {
        let requestID = nextWhiteBalanceRequestID()
        sessionQueue.async { [weak self] in
            guard let self, self.isLatestWhiteBalanceRequest(requestID),
                  !self.movieOutput.isRecording, !self.recordingRequested else { return }

            let previousPreset = self.requestedWhiteBalancePreset
            let currentDevice = self.videoInput?.device
            let needsInputSwap = self.cameraPosition == .back && (
                (preset != .auto && currentDevice?.isVirtualDevice == true) ||
                (preset == .auto && currentDevice?.isVirtualDevice == false)
            )

            self.requestedWhiteBalancePreset = preset

            // Manual-to-manual (or any front-camera WB change) only needs a device WB update.
            // Do not rebuild/reapply the whole capture format for a color-temperature change.
            if !needsInputSwap {
                guard self.isLatestWhiteBalanceRequest(requestID) else { return }
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
                guard let self, self.isLatestWhiteBalanceRequest(requestID) else { return }

                let configured = self.applyActiveModeFormat(
                    preferVirtualCamera: preset == .auto
                )
                guard self.isLatestWhiteBalanceRequest(requestID) else { return }

                if !configured || self.requestedWhiteBalancePreset != preset {
                    self.requestedWhiteBalancePreset = previousPreset
                    _ = self.applyActiveModeFormat(preferVirtualCamera: previousPreset == .auto)
                    self.publish { self.whiteBalancePreset = previousPreset }
                    self.showError(preset == .auto
                        ? "Couldn’t enable Auto white balance."
                        : "Manual white balance isn’t available on this lens.")
                }

                DispatchQueue.main.asyncAfter(deadline: .now() + 0.12) { [weak self] in
                    guard let self, self.isLatestWhiteBalanceRequest(requestID) else { return }
                    self.isPreviewTransitioning = false
                }
            }
        }
    }



    func selectResolution(_ resolution: VideoResolution) {
        selectedResolution = resolution
        guard captureMode == .video else { return }
        sessionQueue.async { [weak self] in
            guard let self else { return }
            self.applySelectedFormat(preferVirtualCamera: !self.requiresPhysicalWhiteBalanceInput)
        }
    }

    func selectFrameRate(_ frameRate: VideoFrameRate) {
        selectedFrameRate = frameRate
        guard captureMode == .video else { return }
        sessionQueue.async { [weak self] in
            guard let self else { return }
            self.applySelectedFormat(preferVirtualCamera: !self.requiresPhysicalWhiteBalanceInput)
        }
    }

    func selectSlowMotionResolution(_ resolution: VideoResolution) {
        selectedSlowMotionResolution = resolution
        guard captureMode == .sloMo else { return }
        sessionQueue.async { [weak self] in self?.applySlowMotionFormat() }
    }

    func selectSlowMotionFrameRate(_ frameRate: SlowMotionFrameRate) {
        selectedSlowMotionFrameRate = frameRate
        guard captureMode == .sloMo else { return }
        sessionQueue.async { [weak self] in self?.applySlowMotionFormat() }
    }

    func setVideoStabilizationEnabled(_ enabled: Bool) {
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
            guard let self, !self.recordingFinalizationRequested else { return }

            if self.recordingRequested {
                self.recordingRequested = false
                self.continuingSegment = false
                self.segmentTimer?.cancel()

                if self.movieOutput.isRecording {
                    self.recordingFinalizationRequested = true
                    self.publish {
                        self.isRecordingStarting = false
                        self.isRecording = false
                        self.isFinalizingRecording = true
                    }
                    self.postStatus("Saving to Photos…")
                    self.movieOutput.stopRecording()
                } else {
                    // A second tap arrived while AVCaptureMovieFileOutput was still starting.
                    // If didStart arrives later, stop and discard that canceled startup clip.
                    self.discardCurrentRecordingWhenFinished = true
                    self.publish {
                        self.isRecordingStarting = false
                        self.isRecording = false
                    }
                }
                return
            }

            guard !self.isCapturingPhoto else { return }
            self.recordingRequested = true
            self.recordingFinalizationRequested = false
            self.discardCurrentRecordingWhenFinished = false
            self.continuingSegment = false
            self.segmentSeconds = Double(UserDefaults.standard.integer(forKey: "splitMinutes")) * 60
            self.publish {
                self.isRecordingStarting = true
                self.isRecording = false
                self.lastFrameGaps = nil
            }
            self.beginRecording()
        }
    }

    func applyQuickPreset(_ preset: VideoQuickPreset, completion: ((Bool) -> Void)? = nil) {
        guard captureMode == .video, !isRecording, !isRecordingStarting, !isCapturingPhoto else {
            completion?(false)
            return
        }

        sessionQueue.async { [weak self] in
            guard let self else { return }
            let devices = self.capabilityDevices(for: self.cameraPosition.avPosition)
            let supported = devices.contains { device in
                device.formats.contains { self.format($0, supports: preset.resolution, at: preset.frameRate) }
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

    private func configureSessionIfNeeded(forceRebuild: Bool = false) {
        let hasVideo = videoInput.map { current in
            session.inputs.contains(where: { $0 === current })
        } ?? false
        let hasMovie = session.outputs.contains(where: { $0 === movieOutput })
        let hasPhoto = session.outputs.contains(where: { $0 === photoOutput })
        if !forceRebuild, hasVideo, hasMovie, hasPhoto {
            return
        }

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
        session.commitConfiguration()

        updateCapabilities()
        _ = applyActiveModeFormat(preferVirtualCamera: !requiresPhysicalWhiteBalanceInput)
        synchronizeTorchState()
    }







    @discardableResult
    private func applyAtomicCaptureConfiguration(
        device desiredDevice: AVCaptureDevice,
        format: AVCaptureDevice.Format,
        frameRate: Double,
        photoDimensions: CMVideoDimensions? = nil
    ) -> CGFloat? {
        let oldInput = videoInput
        let isSwitchingInput = oldInput?.device.uniqueID != desiredDevice.uniqueID
        var replacementInput: AVCaptureDeviceInput?

        if isSwitchingInput {
            do {
                replacementInput = try AVCaptureDeviceInput(device: desiredDevice)
            } catch {
                showError("Couldn’t access the selected camera.")
                return nil
            }
        }

        session.beginConfiguration()
        var committed = false
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
            desiredDevice.unlockForConfiguration()
            deviceLocked = false

            if let photoDimensions,
               (photoOutput.maxPhotoDimensions.width != photoDimensions.width ||
                photoOutput.maxPhotoDimensions.height != photoDimensions.height) {
                photoOutput.maxPhotoDimensions = photoDimensions
            }

            session.commitConfiguration()
            committed = true
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
        let supported = availableResolutions(for: devices)
        let selection = validSelection(for: devices, availableResolutions: supported)
        let slowMotionResolutions = slowMotionResolutions(for: devices)
        let slowMotionResolution = slowMotionResolutions.contains(selectedSlowMotionResolution)
            ? selectedSlowMotionResolution
            : (slowMotionResolutions.contains(.p1080) ? .p1080 : (slowMotionResolutions.first ?? .p1080))
        let slowMotionRates = slowMotionFrameRates(for: devices, resolution: slowMotionResolution)
        let slowMotionSelection = slowMotionRates.contains(selectedSlowMotionFrameRate)
            ? selectedSlowMotionFrameRate
            : (slowMotionRates.last ?? .fps120)
        publish {
            let wasSuppressing = self.suppressPreferencePersistence
            self.suppressPreferencePersistence = true
            self.supportedResolutions = supported
            self.torchAvailable = device.hasTorch
            self.isTorchOn = device.torchMode == .on
            self.minimumZoomFactor = self.minimumSupportedZoom(for: device)
            self.maximumZoomFactor = self.maximumSupportedZoom(for: device)
            let displayedZoom = self.displayedZoomFactor(for: device.videoZoomFactor, device: device)
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
            device.formats.contains { format($0, supports: selectedResolution, at: selectedFrameRate) }
        }
    }

    private func cameraSupportingSlowMotion(for position: AVCaptureDevice.Position) -> AVCaptureDevice? {
        let devices = capabilityDevices(for: position)
        let resolutions = slowMotionResolutions(for: devices)
        guard !resolutions.isEmpty else { return nil }
        let resolution = resolutions.contains(selectedSlowMotionResolution)
            ? selectedSlowMotionResolution
            : (resolutions.contains(.p1080) ? .p1080 : resolutions[0])
        let rates = slowMotionFrameRates(for: devices, resolution: resolution)
        guard let rate = rates.contains(selectedSlowMotionFrameRate)
            ? selectedSlowMotionFrameRate
            : rates.last else { return nil }

        let supported = devices.filter { bestSlowMotionFormat(for: $0, resolution: resolution, frameRate: rate) != nil }
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

        guard let desiredDevice, let photoChoice = bestPhotoFormat(for: desiredDevice) else {
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

        isUsingVideoPreviewProxy = false
        isUsingSlowMotionPreview = false
        let minimum = minimumSupportedZoom(for: desiredDevice)
        let maximum = maximumSupportedZoom(for: desiredDevice)
        publish {
            self.minimumZoomFactor = minimum
            self.maximumZoomFactor = maximum
            self.zoomFactor = displayedZoom
            self.zoomLabel = self.formattedZoomLabel(for: displayedZoom)
            self.torchAvailable = desiredDevice.hasTorch
            self.isTorchOn = desiredDevice.torchMode == .on
            self.currentPhotoResolutionLabel = self.photoResolutionLabel(for: photoChoice.dimensions)
            self.currentPhotoPixelCount = Int64(photoChoice.dimensions.width) * Int64(photoChoice.dimensions.height)
        }
        resetFocusAndExposureState()
        synchronizeWhiteBalanceAfterConfiguration()
        return true
    }

    private func bestPhotoFormat(for device: AVCaptureDevice) -> (format: AVCaptureDevice.Format, dimensions: CMVideoDimensions)? {
        struct Candidate {
            let format: AVCaptureDevice.Format
            let photoDimensions: CMVideoDimensions
            let photoPixels: Int64
            let previewPixels: Int64
            let supports30FPS: Bool
        }

        var best: Candidate?
        for format in device.formats {
            guard let photoDimensions = format.supportedMaxPhotoDimensions.max(by: { lhs, rhs in
                Int64(lhs.width) * Int64(lhs.height) < Int64(rhs.width) * Int64(rhs.height)
            }) else { continue }

            let videoDimensions = CMVideoFormatDescriptionGetDimensions(format.formatDescription)
            let candidate = Candidate(
                format: format,
                photoDimensions: photoDimensions,
                photoPixels: Int64(photoDimensions.width) * Int64(photoDimensions.height),
                previewPixels: Int64(videoDimensions.width) * Int64(videoDimensions.height),
                supports30FPS: format.videoSupportedFrameRateRanges.contains { $0.minFrameRate <= 30 && $0.maxFrameRate >= 30 }
            )

            guard let current = best else {
                best = candidate
                continue
            }

            // Max still-photo resolution always wins. For formats that produce the same
            // max-resolution photo, prefer 30 fps and then the sharpest live-preview format.
            if candidate.photoPixels > current.photoPixels ||
                (candidate.photoPixels == current.photoPixels && candidate.supports30FPS && !current.supports30FPS) ||
                (candidate.photoPixels == current.photoPixels && candidate.supports30FPS == current.supports30FPS && candidate.previewPixels > current.previewPixels) {
                best = candidate
            }
        }

        guard let best else { return nil }
        return (best.format, best.photoDimensions)
    }

    private func photoResolutionLabel(for dimensions: CMVideoDimensions) -> String {
        let megapixels = Double(dimensions.width) * Double(dimensions.height) / 1_000_000.0
        let rounded = megapixels.rounded()
        if abs(megapixels - rounded) < 0.35 {
            return "\(Int(rounded)) MP"
        }
        return String(format: "%.1f MP", megapixels)
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

    private func availableResolutions(for devices: [AVCaptureDevice]) -> [VideoResolution] {
        VideoResolution.allCases.filter { resolution in
            devices.contains { device in
                device.formats.contains { self.format($0, supports: resolution) && self.formatSupportsSelectedCodec($0) }
            }
        }
    }

    private func validSelection(for devices: [AVCaptureDevice], availableResolutions: [VideoResolution]) -> (resolution: VideoResolution, frameRate: VideoFrameRate, supportedFrameRates: [VideoFrameRate]) {
        let resolution = availableResolutions.contains(selectedResolution) ? selectedResolution : (availableResolutions.first ?? .p1080)
        let rates = frameRates(for: resolution, devices: devices)
        let frameRate = rates.contains(selectedFrameRate) ? selectedFrameRate : (rates.first ?? .fps30)
        return (resolution, frameRate, rates)
    }

    @discardableResult
    private func applySelectedFormat(preferVirtualCamera: Bool = true, allowSmoothPreview: Bool = true) -> Bool {
        let devices = capabilityDevices(for: cameraPosition.avPosition)
        let available = availableResolutions(for: devices)
        guard !available.isEmpty else {
            showError("Video isn’t available on this camera with the selected codec.")
            return false
        }
        let selection = validSelection(for: devices, availableResolutions: available)
        let supportedDevices = devices.filter { device in
            device.formats.contains {
                self.format($0, supports: selection.resolution, at: selection.frameRate) && self.formatSupportsSelectedCodec($0)
            }
        }

        publish {
            let wasSuppressing = self.suppressPreferencePersistence
            self.suppressPreferencePersistence = true
            self.selectedResolution = selection.resolution
            self.selectedFrameRate = selection.frameRate
            self.supportedResolutions = available
            self.supportedFrameRates = selection.supportedFrameRates
            self.suppressPreferencePersistence = wasSuppressing
        }

        // 4K60 is expensive to preview on some iPhones even before recording. Keep the same
        // virtual multi-camera 1080p60 preview path that is smooth at 0.5x <-> 1x, then switch
        // once to the true selected recording format only when Record is pressed.
        let wantsSmooth4K60Preview = allowSmoothPreview && cameraPosition == .back &&
            selection.resolution == .p4k && selection.frameRate == .fps60 &&
            !movieOutput.isRecording && !requiresPhysicalWhiteBalanceInput
        if wantsSmooth4K60Preview,
           let virtual = devices.first(where: { $0.isVirtualDevice }),
           let previewFormat = smoothPreviewFormat(for: virtual, preferredFrameRate: .fps60),
           let displayed = applyAtomicCaptureConfiguration(device: virtual, format: previewFormat, frameRate: 60) {
            isUsingVideoPreviewProxy = true
            isUsingSlowMotionPreview = false
            let minZoom = minimumSupportedZoom(for: virtual)
            let maxZoom = maximumSupportedZoom(for: virtual)
            publish {
                self.minimumZoomFactor = minZoom
                self.maximumZoomFactor = maxZoom
                self.zoomFactor = displayed
                self.zoomLabel = self.formattedZoomLabel(for: displayed)
                self.torchAvailable = virtual.hasTorch
                self.isTorchOn = virtual.torchMode == .on
            }
            resetFocusAndExposureState()
            synchronizeWhiteBalanceAfterConfiguration()
            return true
        }

        let physical = desiredPhysicalDevice(in: supportedDevices, forDisplayedZoom: requestedZoom)
        let desiredDevice = preferVirtualCamera
            ? (supportedDevices.first(where: { $0.isVirtualDevice }) ?? physical ?? supportedDevices.first)
            : (physical ?? supportedDevices.first(where: { !$0.isVirtualDevice }) ?? supportedDevices.first)
        guard let desiredDevice,
              let selectedFormat = preferredRecordingFormat(for: desiredDevice, resolution: selection.resolution, rate: selection.frameRate) else {
            showError("This video quality isn’t available on this lens.")
            return false
        }

        guard let displayed = applyAtomicCaptureConfiguration(
            device: desiredDevice,
            format: selectedFormat,
            frameRate: Double(selection.frameRate.rawValue)
        ) else {
            showError("Couldn’t set the video quality.")
            return false
        }

        isUsingVideoPreviewProxy = false
        isUsingSlowMotionPreview = false
        _ = configureMovieOutputSettings()
        let minZoom = minimumSupportedZoom(for: desiredDevice)
        let maxZoom = maximumSupportedZoom(for: desiredDevice)
        publish {
            self.minimumZoomFactor = minZoom
            self.maximumZoomFactor = maxZoom
            self.zoomFactor = displayed
            self.zoomLabel = self.formattedZoomLabel(for: displayed)
            self.torchAvailable = desiredDevice.hasTorch
            self.isTorchOn = desiredDevice.torchMode == .on
        }
        resetFocusAndExposureState()
        synchronizeWhiteBalanceAfterConfiguration()
        return true
    }

    private func smoothPreviewFormat(for device: AVCaptureDevice, preferredFrameRate: VideoFrameRate) -> AVCaptureDevice.Format? {
        let requestedRate = Double(preferredFrameRate.rawValue)

        // Slo-Mo-only idle preview; standard video always uses its recording format.
        for resolution in [VideoResolution.p1080, .p720] {
            if let format = device.formats.first(where: {
                self.format($0, supports: resolution, at: preferredFrameRate)
            }) {
                return format
            }
        }

        // Last-resort virtual preview: keep the requested FPS even if the device exposes a
        // nonstandard preview size.
        return device.formats.first(where: { format in
            format.videoSupportedFrameRateRanges.contains {
                $0.minFrameRate <= requestedRate + 0.5 && $0.maxFrameRate >= requestedRate - 0.5
            }
        })
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

    private func preferredRecordingFormat(for device: AVCaptureDevice, resolution: VideoResolution, rate: VideoFrameRate) -> AVCaptureDevice.Format? {
        let formats = device.formats.filter { format($0, supports: resolution, at: rate) }
        if selectedVideoCodec == "H264" {
            // H.264 needs an 8-bit source; a 10-bit/HDR first match can expose HEVC only.
            return formats.first {
                let type = CMFormatDescriptionGetMediaSubType($0.formatDescription)
                return type == kCVPixelFormatType_420YpCbCr8BiPlanarFullRange || type == kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange
            } ?? formats.first
        }
        return formats.first
    }

    @discardableResult
    private func applySlowMotionFormat(allowPreview: Bool = true) -> Bool {
        let devices = capabilityDevices(for: cameraPosition.avPosition)
        let allResolutions = slowMotionResolutions(for: devices)
        guard !allResolutions.isEmpty else {
            showError("Slo-Mo isn’t available on this camera with the selected codec.")
            return false
        }

        let resolution = allResolutions.contains(selectedSlowMotionResolution)
            ? selectedSlowMotionResolution
            : (allResolutions.contains(.p1080) ? .p1080 : allResolutions[0])
        let allRates = slowMotionFrameRates(for: devices, resolution: resolution)
        guard !allRates.isEmpty else {
            showError("Slo-Mo isn’t available at this resolution.")
            return false
        }
        let selectedRate = allRates.contains(selectedSlowMotionFrameRate)
            ? selectedSlowMotionFrameRate
            : (allRates.last ?? .fps120)

        let supportedDevices = devices.filter {
            bestSlowMotionFormat(for: $0, resolution: resolution, frameRate: selectedRate) != nil
        }
        let physical = desiredPhysicalDevice(in: supportedDevices, forDisplayedZoom: requestedZoom)
        // Prefer a physical constituent for HFR so the lens and field of view are already the
        // ones that will record. This avoids a virtual->physical jump on the first recorded frame.
        let desiredDevice = physical
            ?? supportedDevices.first(where: { !$0.isVirtualDevice })
            ?? supportedDevices.first
        guard let desiredDevice,
              let hfrFormat = bestSlowMotionFormat(for: desiredDevice, resolution: resolution, frameRate: selectedRate) else {
            showError("\(selectedRate.rawValue) fps Slo-Mo isn’t available on this lens.")
            return false
        }

        let requestedFPS = Double(selectedRate.rawValue)
        var appliedFPS = requestedFPS
        if allowPreview, !movieOutput.isRecording {
            if hfrFormat.videoSupportedFrameRateRanges.contains(where: { $0.minFrameRate <= 60.5 && $0.maxFrameRate >= 59.5 }) {
                appliedFPS = 60
            }
        }

        guard let displayed = applyAtomicCaptureConfiguration(
            device: desiredDevice,
            format: hfrFormat,
            frameRate: appliedFPS
        ) else {
            showError("Couldn’t set the Slo-Mo quality.")
            return false
        }

        isUsingSlowMotionPreview = allowPreview && abs(appliedFPS - requestedFPS) > 0.5
        isUsingVideoPreviewProxy = false
        _ = configureMovieOutputSettings()

        let lensResolutions = slowMotionResolutions(for: [desiredDevice])
        let lensRates = slowMotionFrameRates(for: [desiredDevice], resolution: resolution)
        publish {
            let wasSuppressing = self.suppressPreferencePersistence
            self.suppressPreferencePersistence = true
            self.supportedSlowMotionResolutions = lensResolutions.isEmpty ? allResolutions : lensResolutions
            self.selectedSlowMotionResolution = resolution
            self.supportedSlowMotionFrameRates = lensRates.isEmpty ? allRates : lensRates
            self.selectedSlowMotionFrameRate = selectedRate
            self.suppressPreferencePersistence = wasSuppressing
            self.minimumZoomFactor = self.minimumSupportedZoom(for: desiredDevice)
            self.maximumZoomFactor = self.maximumSupportedZoom(for: desiredDevice)
            self.zoomFactor = displayed
            self.zoomLabel = self.formattedZoomLabel(for: displayed)
            self.torchAvailable = desiredDevice.hasTorch
            self.isTorchOn = desiredDevice.torchMode == .on
        }
        resetFocusAndExposureState()
        synchronizeWhiteBalanceAfterConfiguration()
        return true
    }

    private func slowMotionResolutions(for devices: [AVCaptureDevice]) -> [VideoResolution] {
        VideoResolution.allCases.filter { resolution in
            SlowMotionFrameRate.allCases.contains { rate in
                devices.contains { bestSlowMotionFormat(for: $0, resolution: resolution, frameRate: rate) != nil }
            }
        }
    }

    private func slowMotionFrameRates(for devices: [AVCaptureDevice], resolution: VideoResolution) -> [SlowMotionFrameRate] {
        SlowMotionFrameRate.allCases.filter { rate in
            devices.contains { bestSlowMotionFormat(for: $0, resolution: resolution, frameRate: rate) != nil }
        }
    }

    private func bestSlowMotionFormat(for device: AVCaptureDevice, resolution: VideoResolution, frameRate: SlowMotionFrameRate) -> AVCaptureDevice.Format? {
        let requestedFPS = Double(frameRate.rawValue)
        let candidates = device.formats.filter { format in
            let dimensions = CMVideoFormatDescriptionGetDimensions(format.formatDescription)
            guard dimensions.width == resolution.dimensions.width, dimensions.height == resolution.dimensions.height else { return false }
            guard formatSupportsSelectedCodec(format) else { return false }
            return format.videoSupportedFrameRateRanges.contains {
                $0.minFrameRate <= requestedFPS + 0.5 && $0.maxFrameRate >= requestedFPS - 0.5
            }
        }

        // Prefer the format whose supported range is closest to the requested HFR. This keeps
        // 120 fps on a 120-oriented format when one exists instead of needlessly selecting a
        // 240-oriented sensor mode.
        return candidates.min { lhs, rhs in
            let lhsMax = lhs.videoSupportedFrameRateRanges.map { $0.maxFrameRate }.max() ?? .greatestFiniteMagnitude
            let rhsMax = rhs.videoSupportedFrameRateRanges.map { $0.maxFrameRate }.max() ?? .greatestFiniteMagnitude
            let lhsDistance = abs(lhsMax - requestedFPS)
            let rhsDistance = abs(rhsMax - requestedFPS)
            if abs(lhsDistance - rhsDistance) > 0.01 { return lhsDistance < rhsDistance }
            let lhsPixels = CMVideoFormatDescriptionGetDimensions(lhs.formatDescription)
            let rhsPixels = CMVideoFormatDescriptionGetDimensions(rhs.formatDescription)
            return Int64(lhsPixels.width) * Int64(lhsPixels.height) > Int64(rhsPixels.width) * Int64(rhsPixels.height)
        }
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



    private func format(_ format: AVCaptureDevice.Format, supports resolution: VideoResolution, at frameRate: VideoFrameRate? = nil) -> Bool {
        let dimensions = CMVideoFormatDescriptionGetDimensions(format.formatDescription)
        guard dimensions.width == resolution.dimensions.width, dimensions.height == resolution.dimensions.height else { return false }
        guard let frameRate else { return true }
        return format.videoSupportedFrameRateRanges.contains {
            let requestedRate = Double(frameRate.rawValue)
            return $0.minFrameRate <= requestedRate + 0.5 && $0.maxFrameRate >= requestedRate - 0.5
        }
    }

    private func frameRates(for resolution: VideoResolution, devices: [AVCaptureDevice]) -> [VideoFrameRate] {
        VideoFrameRate.allCases.filter { rate in
            devices.contains { device in
                device.formats.contains { format($0, supports: resolution, at: rate) && formatSupportsSelectedCodec($0) }
            }
        }
    }

    private func formatSupportsSelectedCodec(_ format: AVCaptureDevice.Format) -> Bool {
        guard selectedVideoCodec == "H264" else { return true }
        let type = CMFormatDescriptionGetMediaSubType(format.formatDescription)
        return type == kCVPixelFormatType_420YpCbCr8BiPlanarFullRange ||
            type == kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange
    }

    private func applyCaptureRotation(to connection: AVCaptureConnection?) {
        guard let connection,
              let angle = rotationCoordinator?.videoRotationAngleForHorizonLevelCapture,
              connection.isVideoRotationAngleSupported(angle) else { return }
        connection.videoRotationAngle = angle
    }

    private func beginPhotoCapture() {
        guard session.isRunning else {
            publish { self.isCapturingPhoto = false }
            showError("Camera isn’t ready yet.")
            return
        }

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
        settings.photoQualityPrioritization = .quality
        let dimensions = photoOutput.maxPhotoDimensions
        if dimensions.width > 0, dimensions.height > 0 {
            settings.maxPhotoDimensions = dimensions
        }
        pendingPhotoFilename = nextMediaFilename(fileExtension: useHEIC ? "heic" : "jpg")
        refreshAvailableStorage()
        photoOutput.capturePhoto(with: settings, delegate: self)
    }

    private func beginRecording() {
        guard recordingRequested, session.isRunning, movieOutput.isRecording == false else {
            recordingRequested = false
            publish {
                self.isRecordingStarting = false
                self.isRecording = false
            }
            return
        }

        if captureMode == .video {
            if isUsingVideoPreviewProxy || !activeVideoFormatMatchesSelection() {
                guard applySelectedFormat(
                    preferVirtualCamera: !requiresPhysicalWhiteBalanceInput,
                    allowSmoothPreview: false
                ), activeVideoFormatMatchesSelection() else {
                    recordingRequested = false
                    publish { self.isRecordingStarting = false }
                    showError("Couldn’t prepare the selected recording quality.")
                    return
                }
            }
        } else if captureMode == .sloMo {
            guard applySlowMotionFormat(allowPreview: false),
                  let device = videoInput?.device,
                  bestSlowMotionFormat(
                    for: device,
                    resolution: selectedSlowMotionResolution,
                    frameRate: selectedSlowMotionFrameRate
                  ) != nil,
                  !isUsingSlowMotionPreview,
                  abs(1 / device.activeVideoMinFrameDuration.seconds - Double(selectedSlowMotionFrameRate.rawValue)) < 1 else {
                recordingRequested = false
                publish { self.isRecordingStarting = false }
                showError("Couldn’t start the selected Slo-Mo frame rate.")
                return
            }
        }

        guard configureMovieOutputSettings() else {
            recordingRequested = false
            publish { self.isRecordingStarting = false }
            showError("\(selectedVideoCodec == "H264" ? "H.264" : "HEVC") isn’t available at this resolution/FPS on this lens.")
            return
        }

        applyCaptureRotation(to: movieOutput.connection(with: .video))
        movieOutput.metadata = CameraMovieMetadata.items(isSlowMotion: captureMode == .sloMo)
        refreshAvailableStorage()

        // Format/lens changes can make AF/AE settle for a few frames. Wait briefly so the first
        // recorded frames do not contain avoidable focus/exposure hunting.
        startMovieOutputWhenReady(deadline: Date().addingTimeInterval(1.0))
    }

    private func startMovieOutputWhenReady(deadline: Date) {
        guard recordingRequested, !movieOutput.isRecording else { return }
        if let device = videoInput?.device,
           (device.isAdjustingFocus || device.isAdjustingExposure),
           Date() < deadline {
            sessionQueue.asyncAfter(deadline: .now() + 0.06) { [weak self] in
                self?.startMovieOutputWhenReady(deadline: deadline)
            }
            return
        }

        guard recordingRequested else { return }
        let filename = nextMediaFilename(fileExtension: "mov")
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(filename)
        movieOutput.startRecording(to: url, recordingDelegate: self)
    }

    private func nextMediaFilename(fileExtension: String) -> String {
        let defaults = UserDefaults.standard
        let ext = fileExtension.lowercased()
        let recoveryNames = Set(CameraRecoveryStore.recordings().map(\.lastPathComponent))
        var number = defaults.integer(forKey: Self.mediaSequenceKey)
        if number < 1 || number > 9_999 { number = 1 }

        for _ in 0..<9_999 {
            let filename = String(format: "img_%04d.%@", number, ext)
            let tempURL = FileManager.default.temporaryDirectory.appendingPathComponent(filename)
            let next = number == 9_999 ? 1 : number + 1
            defaults.set(next, forKey: Self.mediaSequenceKey)
            if !FileManager.default.fileExists(atPath: tempURL.path), !recoveryNames.contains(filename) {
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
            self.torchAvailable = device.hasTorch
            self.isTorchOn = device.hasTorch && device.torchMode == .on
        }
    }

    private func publish(_ update: @escaping () -> Void) {
        DispatchQueue.main.async(execute: update)
    }

    private func refreshRecoveryCount() {
        let count = CameraRecoveryStore.recordings().count
        publish { self.recoverableRecordingCount = count }
    }

    func retryRecoverableRecordings() {
        sessionQueue.async { [weak self] in
            guard let self else { return }
            let files = CameraRecoveryStore.recordings()
            guard !files.isEmpty else {
                self.refreshRecoveryCount()
                return
            }
            self.pendingVideoSaves += files.count
            self.beginBackgroundSaveIfNeeded()
            for file in files {
                self.saveVideoResourceToPhotos(file, runDiagnostics: false, recoveryRetry: true)
            }
            self.postStatus("Retrying \(files.count) recovered recording\(files.count == 1 ? "" : "s")…")
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
        recordingFinalizationRequested = false
        recordingSessionStartedAt = nil
        publish {
            self.isFinalizingRecording = false
            self.isRecordingStarting = false
            self.isRecording = false
            self.recordingDuration = 0
        }
        endBackgroundSaveIfPossible()
    }

    private func restoreIdleCaptureConfigurationAfterRecording() {
        guard !movieOutput.isRecording else { return }
        switch captureMode {
        case .video:
            _ = applySelectedFormat(
                preferVirtualCamera: !requiresPhysicalWhiteBalanceInput,
                allowSmoothPreview: true
            )
        case .sloMo:
            _ = applySlowMotionFormat(allowPreview: true)
        case .photo:
            break
        }
    }

    private func saveVideoResourceToPhotos(
        _ fileURL: URL,
        runDiagnostics: Bool,
        recoveryRetry: Bool = false
    ) {
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
                    self.pendingVideoSaves = max(self.pendingVideoSaves - 1, 0)
                    if success {
                        if let gaps {
                            self.publish { self.lastFrameGaps = gaps }
                        }
                        self.postStatus(recoveryRetry ? "Recovered recording saved to Photos" : "Saved to Photos")
                    } else {
                        _ = CameraRecoveryStore.preserve(fileURL)
                        self.showError("Couldn’t save to Photos. The recording is kept in Recovery. \(error?.localizedDescription ?? "")")
                    }
                    self.refreshRecoveryCount()
                    self.refreshAvailableStorage()
                    if self.recordingFinalizationRequested {
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

            if !self.recordingRequested {
                self.discardCurrentRecordingWhenFinished = true
                if self.movieOutput.isRecording { self.movieOutput.stopRecording() }
                return
            }

            self.segmentTimer?.cancel()
            if self.segmentSeconds > 0 {
                let timer = DispatchWorkItem { [weak self] in
                    guard let self, self.recordingRequested, self.movieOutput.isRecording else { return }
                    self.continuingSegment = true
                    self.movieOutput.stopRecording()
                }
                self.segmentTimer = timer
                self.sessionQueue.asyncAfter(deadline: .now() + self.segmentSeconds, execute: timer)
            }

            self.publish {
                self.isRecordingStarting = false
                self.isRecording = true
                if self.recordingSessionStartedAt == nil {
                    self.recordingSessionStartedAt = Date()
                }
                self.durationTimer?.invalidate()
                let timer = Timer(timeInterval: 0.25, repeats: true) { [weak self] _ in
                    guard let self, let startedAt = self.recordingSessionStartedAt else { return }
                    self.recordingDuration = Date().timeIntervalSince(startedAt)
                }
                self.durationTimer = timer
                RunLoop.main.add(timer, forMode: .common)
            }
        }
    }

    func fileOutput(_ output: AVCaptureFileOutput, didFinishRecordingTo outputFileURL: URL, from connections: [AVCaptureConnection], error: Error?) {
        let successful = error == nil || (error as NSError?)?.userInfo[AVErrorRecordingSuccessfullyFinishedKey] as? Bool == true

        sessionQueue.async { [weak self] in
            guard let self else { return }
            self.segmentTimer?.cancel()

            if self.discardCurrentRecordingWhenFinished {
                self.discardCurrentRecordingWhenFinished = false
                try? FileManager.default.removeItem(at: outputFileURL)
                self.recordingRequested = false
                self.recordingFinalizationRequested = false
                self.recordingSessionStartedAt = nil
                self.publish {
                    self.durationTimer?.invalidate()
                    self.durationTimer = nil
                    self.recordingDuration = 0
                    self.isRecording = false
                    self.isRecordingStarting = false
                    self.isFinalizingRecording = false
                }
                self.restoreIdleCaptureConfigurationAfterRecording()
                return
            }

            let shouldContinue = successful &&
                self.recordingRequested &&
                self.continuingSegment &&
                self.session.isRunning
            self.continuingSegment = false

            if !successful {
                self.recordingRequested = false
                self.recordingFinalizationRequested = false
                self.recordingSessionStartedAt = nil
                let retained = CameraRecoveryStore.preserve(outputFileURL)
                self.refreshRecoveryCount()
                self.publish {
                    self.durationTimer?.invalidate()
                    self.durationTimer = nil
                    self.recordingDuration = 0
                    self.isRecording = false
                    self.isRecordingStarting = false
                    self.isFinalizingRecording = false
                }
                self.restoreIdleCaptureConfigurationAfterRecording()
                let suffix = retained == nil ? "" : " It is kept in Recovery."
                self.showError("Recording stopped: \(error?.localizedDescription ?? "Unknown error").\(suffix)")
                return
            }

            self.pendingVideoSaves += 1
            self.beginBackgroundSaveIfNeeded()
            let diagnosticsEnabled = UserDefaults.standard.bool(forKey: "cameraHUDDroppedFrames")
            // Avoid decoding a completed split segment while the next HFR/4K segment is recording.
            self.saveVideoResourceToPhotos(
                outputFileURL,
                runDiagnostics: diagnosticsEnabled && !shouldContinue
            )

            if shouldContinue {
                self.publish {
                    self.isRecording = false
                    self.isRecordingStarting = true
                }
                self.beginRecording()
            } else {
                self.recordingRequested = false
                self.recordingFinalizationRequested = true
                self.publish {
                    self.durationTimer?.invalidate()
                    self.durationTimer = nil
                    self.recordingDuration = 0
                    self.isRecording = false
                    self.isRecordingStarting = false
                    self.isFinalizingRecording = true
                }
                self.restoreIdleCaptureConfigurationAfterRecording()
                self.finishFinalizingIfPossible()
            }
        }
    }
}


extension CameraManager: AVCapturePhotoCaptureDelegate {
    func photoOutput(_ output: AVCapturePhotoOutput, didFinishProcessingPhoto photo: AVCapturePhoto, error: Error?) {
        if let error {
            showError("Photo failed: \(error.localizedDescription)")
            return
        }

        guard let data = photo.fileDataRepresentation() else {
            showError("Couldn’t create the photo file.")
            return
        }

        let filename = pendingPhotoFilename ?? nextMediaFilename(fileExtension: "jpg")
        pendingPhotoFilename = nil
        PHPhotoLibrary.shared().performChanges({
            let request = PHAssetCreationRequest.forAsset()
            let options = PHAssetResourceCreationOptions()
            options.originalFilename = filename
            request.addResource(with: .photo, data: data, options: options)
        }) { [weak self] success, error in
            self?.refreshAvailableStorage()
            if success {
                self?.postStatus("Photo saved to Photos")
            } else {
                self?.showError(error?.localizedDescription ?? "Couldn’t save the photo to Photos.")
            }
        }
    }

    func photoOutput(_ output: AVCapturePhotoOutput, didFinishCaptureFor resolvedSettings: AVCaptureResolvedPhotoSettings, error: Error?) {
        let delivered = resolvedSettings.photoDimensions
        publish {
            self.isCapturingPhoto = false
            if delivered.width > 0, delivered.height > 0 {
                self.currentPhotoResolutionLabel = self.photoResolutionLabel(for: delivered)
                self.currentPhotoPixelCount = Int64(delivered.width) * Int64(delivered.height)
            }
        }

        if let error {
            showError("Photo capture failed: \(error.localizedDescription)")
        }
    }
}
