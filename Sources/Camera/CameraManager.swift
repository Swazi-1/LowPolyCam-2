import AVFoundation
import Foundation
import Photos
import UIKit

final class CameraManager: NSObject, ObservableObject {
    private struct PhotoFormatCandidate {
        let id: String
        let format: AVCaptureDevice.Format
        let dimensions: CMVideoDimensions
        let photoPixels: Int64
        let previewPixels: Int64
        let supports30FPS: Bool
    }

    @Published private(set) var isSessionRunning = false
    @Published private(set) var recordingLifecycle: RecordingLifecycle = .idle
    var isRecording: Bool { recordingLifecycle.isRecording }
    var isRecordingStarting: Bool { recordingLifecycle.isStarting }
    var isFinalizingRecording: Bool { recordingLifecycle.isFinalizing }
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
    @Published private(set) var supportedPhotoResolutions: [PhotoResolutionOption] = []
    @Published private(set) var selectedPhotoResolutionID: String
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
                _ = self.configureCurrentMode(phase: .preview)
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
        didSet { preferenceStore.saveVideoStabilization(isVideoStabilizationEnabled) }
    }

    let session = AVCaptureSession()
    private let sessionQueue = DispatchQueue(label: "com.swazi.lowpolycam.camera")
    private let storageQueue = DispatchQueue(label: "com.swazi.lowpolycam.storage", qos: .utility)
    private let movieOutput = AVCaptureMovieFileOutput()
    private let photoOutput = AVCapturePhotoOutput()
    private let liveMetrics = LiveCaptureMetrics()
    private let audioMeter = AudioLevelMeter()
    private let preferenceStore = CameraPreferenceStore()
    private let captureSettingsStore = CaptureSettingsStore()
    @Published private(set) var liveFPS: Double?
    @Published private(set) var liveMbps: Double?
    @Published private(set) var liveCaptureDrops: Int?
    @Published private(set) var liveMetricsAvailable = false
    @Published private(set) var audioLevel: CGFloat = 0
    private var metricsTimer: DispatchSourceTimer?
    private var diagnosticsGeneration: UInt64 = 0
    private var previousMetricBytes: Int64 = 0
    private var previousMetricDuration: Double = 0
    private struct PendingPhotoCapture {
        let aspect: String
        let outputDimensions: CMVideoDimensions
        let filename: String
        let isBurst: Bool
    }

    private var burstRemaining = 0
    private var burstAspect = "4:3"
    private var activeMaximumPhotoDimensions = CMVideoDimensions(width: 0, height: 0)
    private var pendingPhotoCaptures: [Int64: PendingPhotoCapture] = [:]
    private var pendingPhotoSaves = 0

    private var videoInput: AVCaptureDeviceInput?
    private var durationTimer: Timer?
    private var recordingSessionStartedAt: Date?
    private var requestedZoom: CGFloat = 1
    private var requestedExposureBias: Float = 0
    private var requestedWhiteBalancePreset: WhiteBalancePreset = .auto
    private var pendingFocusLockWorkItem: DispatchWorkItem?
    private var pendingFocusReturnWorkItem: DispatchWorkItem?
    private let requestGate = CaptureRequestGate()
    private var previewPipeline: CameraPreviewPipeline = .native
    private var recordingOperation = RecordingOperationContext()
    private var segmentTimer: DispatchWorkItem?
    private var pendingVideoSaves = 0
    private var recoveryRetriesInFlight = Set<URL>()
    private var backgroundSaveTask: UIBackgroundTaskIdentifier = .invalid
    private var rotationCoordinator: AVCaptureDevice.RotationCoordinator?
    private var sessionObserverTokens: [NSObjectProtocol] = []
    private var suppressPreferencePersistence = false
    private var suppressAutomaticReconfiguration = false


    override init() {
        let preferences = CameraPreferenceStore()
        let initial = preferences.initialSelection
        selectedResolution = initial.resolution
        selectedFrameRate = initial.frameRate
        selectedSlowMotionResolution = initial.slowMotionResolution
        selectedSlowMotionFrameRate = initial.slowMotionFrameRate
        isVideoStabilizationEnabled = preferences.videoStabilizationEnabled
        selectedPhotoResolutionID = preferences.photoResolutionID
        super.init()
        if let mode = preferences.rememberedCaptureMode() { captureMode = mode }
        installSessionObservers()
        recoverableRecordingCount = CameraRecoveryStore.recordings().count
    }

    deinit {
        metricsTimer?.cancel()
        durationTimer?.invalidate()
        sessionObserverTokens.forEach(NotificationCenter.default.removeObserver)
        if backgroundSaveTask != .invalid {
            let task = backgroundSaveTask
            DispatchQueue.main.async { UIApplication.shared.endBackgroundTask(task) }
        }
    }

    private func persistCameraPreferences() {
        preferenceStore.save(
            CameraPreferenceStore.Selection(
                resolution: selectedResolution,
                frameRate: selectedFrameRate,
                slowMotionResolution: selectedSlowMotionResolution,
                slowMotionFrameRate: selectedSlowMotionFrameRate
            ),
            for: cameraPosition
        )
    }

    private func loadCameraPreferences(for position: CameraPosition) {
        let saved = preferenceStore.selection(for: position)
        suppressPreferencePersistence = true
        defer { suppressPreferencePersistence = false }
        selectedResolution = saved.resolution
        selectedFrameRate = saved.frameRate
        selectedSlowMotionResolution = saved.slowMotionResolution
        selectedSlowMotionFrameRate = saved.slowMotionFrameRate
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
        burstRemaining = 0
        synchronizeTorchState()
        guard recordingOperation.requested || movieOutput.isRecording else { return }

        recordingOperation.cancelSegmentContinuation()
        requestGate.invalidate(.recordingStart)
        segmentTimer?.cancel()

        if recordingOperation.segmentActive || movieOutput.isRecording {
            recordingOperation.requestFinalStop()
            publish { self.recordingLifecycle = .stopping }
            postStatus("Recording interrupted · saving…")
            if movieOutput.isRecording { movieOutput.stopRecording() }
        } else {
            let hadExistingSession = recordingSessionStartedAt != nil
            let awaitingDelegateCleanup = recordingOperation.cancelPendingStart(
                finalizeExistingSession: hadExistingSession
            )
            if awaitingDelegateCleanup {
                publish { self.recordingLifecycle = .stopping }
            } else if recordingOperation.finalizationPending {
                recordingSessionStartedAt = nil
                publish {
                    self.durationTimer?.invalidate()
                    self.durationTimer = nil
                    self.recordingDuration = 0
                    self.recordingLifecycle = .saving
                }
                finishFinalizingIfPossible()
            } else {
                publish { self.recordingLifecycle = .idle }
            }
        }
    }

    private func handleSessionInterruptionEnded() {
        configureSessionIfNeeded()
        if !recordingOperation.segmentActive,
           !recordingOperation.startIssued,
           !movieOutput.isRecording {
            _ = configureCurrentMode(phase: .preview)
        }
        if !session.isRunning { session.startRunning() }
        synchronizeTorchState()
        publish { self.isSessionRunning = self.session.isRunning }
    }

    private func rebuildSessionAfterMediaServicesReset() {
        configureSessionIfNeeded(forceRebuild: true)
        if !session.isRunning { session.startRunning() }
        publish { self.isSessionRunning = self.session.isRunning }
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
        return CaptureStorageEstimator.videoBitsPerSecond(
            resolution: resolution,
            frameRate: fps,
            compression: videoCompression,
            codec: selectedVideoCodec
        )
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
            self.burstRemaining = 0
            self.requestGate.invalidate(.recordingStart)
            self.segmentTimer?.cancel()
            if self.recordingOperation.segmentActive || self.movieOutput.isRecording {
                self.recordingOperation.requestFinalStop()
                self.publish { self.recordingLifecycle = .stopping }
                if self.movieOutput.isRecording { self.movieOutput.stopRecording() }
            } else if self.recordingOperation.requested {
                let hadExistingSession = self.recordingSessionStartedAt != nil
                let awaitingDelegateCleanup = self.recordingOperation.cancelPendingStart(
                    finalizeExistingSession: hadExistingSession
                )
                if awaitingDelegateCleanup {
                    self.publish { self.recordingLifecycle = .stopping }
                } else if self.recordingOperation.finalizationPending {
                    self.recordingSessionStartedAt = nil
                    self.publish {
                        self.durationTimer?.invalidate()
                        self.durationTimer = nil
                        self.recordingDuration = 0
                        self.recordingLifecycle = .saving
                    }
                    self.restoreIdleCaptureConfigurationAfterRecording()
                    self.finishFinalizingIfPossible()
                } else {
                    self.publish { self.recordingLifecycle = .idle }
                    self.restoreIdleCaptureConfigurationAfterRecording()
                }
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
            self.burstRemaining = 0
            self.recordingOperation.cancelSegmentContinuation()
            self.requestGate.invalidate(.recordingStart)
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

            if self.recordingOperation.segmentActive || self.movieOutput.isRecording {
                self.recordingOperation.requestFinalStop()
                self.publish { self.recordingLifecycle = .stopping }
                if self.movieOutput.isRecording { self.movieOutput.stopRecording() }
            } else if self.recordingOperation.requested {
                let hadExistingSession = self.recordingSessionStartedAt != nil
                let awaitingDelegateCleanup = self.recordingOperation.cancelPendingStart(
                    finalizeExistingSession: hadExistingSession
                )
                if awaitingDelegateCleanup {
                    self.publish { self.recordingLifecycle = .stopping }
                } else if self.recordingOperation.finalizationPending {
                    self.recordingSessionStartedAt = nil
                    self.publish {
                        self.durationTimer?.invalidate()
                        self.durationTimer = nil
                        self.recordingDuration = 0
                        self.recordingLifecycle = .saving
                    }
                    self.finishFinalizingIfPossible()
                } else {
                    self.publish { self.recordingLifecycle = .idle }
                }
            }
        }
        publish { self.isTorchOn = false }
    }

    func appDidBecomeActive() {
        sessionQueue.async { [weak self] in
            guard let self else { return }
            self.configureSessionIfNeeded()
            if !self.recordingOperation.segmentActive,
               !self.recordingOperation.startIssued,
               !self.movieOutput.isRecording {
                _ = self.configureCurrentMode(phase: .preview)
            }
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
        let requestID = requestGate.next(.zoom)
        sessionQueue.async { [weak self] in
            guard let self, self.requestGate.isCurrent(requestID),
                  let currentDevice = self.videoInput?.device else { return }

            let requested = min(max(requestedFactor, self.minimumZoomFactor), self.maximumZoomFactor)
            let plan = CameraZoomController.planRequest(
                displayedZoom: requested,
                currentDevice: currentDevice,
                availableDevices: self.capabilityDevices(for: currentDevice.position),
                mode: self.captureMode,
                recordingOrStarting: self.movieOutput.isRecording || self.recordingOperation.requested
            )

            switch plan {
            case .blockedPhysicalSwitch:
                self.showError("Stop recording to switch physical lenses.")
                return

            case .reconfigureLens(let targetZoom):
                let previousRequested = self.requestedZoom
                self.requestedZoom = targetZoom
                guard self.requestGate.isCurrent(requestID),
                      self.configureCurrentMode(phase: .preview),
                      self.requestGate.isCurrent(requestID) else {
                    self.requestedZoom = previousRequested
                    return
                }
                // The mode coordinator already applied and published the zoom on the new lens.
                return

            case .applyToCurrentDevice(let targetZoom):
                guard self.requestGate.isCurrent(requestID),
                      let device = self.videoInput?.device else { return }
                let factor = CameraZoomController.snappedDisplayedZoom(targetZoom, for: device)
                do {
                    try device.lockForConfiguration()
                    let deviceFactor = CameraZoomController.deviceZoom(forDisplayedZoom: factor, device: device)
                    device.ramp(toVideoZoomFactor: deviceFactor, withRate: 12)
                    device.unlockForConfiguration()
                    guard self.requestGate.isCurrent(requestID) else { return }
                    self.requestedZoom = factor
                    self.publish {
                        self.zoomFactor = factor
                        self.zoomLabel = CameraZoomController.formattedLabel(for: factor)
                    }
                } catch {
                    self.showError("Couldn’t change the zoom.")
                }
            }
        }
    }



    func switchCamera() {
        guard !isRecording, !isRecordingStarting, !isFinalizingRecording, !isCapturingPhoto else { return }
        let previous = cameraPosition
        let target: CameraPosition = previous == .back ? .front : .back
        let requestID = requestGate.next(.cameraSwitch)
        requestGate.invalidate(.zoom) // Drop any drag command that belongs to the old camera.

        cameraPosition = target
        loadCameraPreferences(for: target)

        sessionQueue.async { [weak self] in
            guard let self, self.requestGate.isCurrent(requestID) else { return }
            guard self.configureCurrentMode(phase: .preview) else {
                guard self.requestGate.isCurrent(requestID) else { return }
                self.publish {
                    self.cameraPosition = previous
                    self.loadCameraPreferences(for: previous)
                }
                self.showError("That camera is unavailable.")
                return
            }
            guard self.requestGate.isCurrent(requestID) else { return }
            self.updateCapabilities()
            self.synchronizeTorchState()
        }
    }

    func selectCaptureMode(_ mode: CaptureMode) {
        guard !isRecording, !isRecordingStarting, !isFinalizingRecording, !isCapturingPhoto, !isPreviewTransitioning, captureMode != mode else { return }
        let previousMode = captureMode
        let requestID = requestGate.next(.modeChange)
        requestGate.invalidate(.zoom) // A queued old-mode zoom must not reconfigure the new mode.
        isPreviewTransitioning = true
        captureMode = mode
        sessionQueue.async { [weak self] in
            guard let self, self.requestGate.isCurrent(requestID) else { return }
            let success = self.configureCurrentMode(phase: .preview)
            if success { self.synchronizeTorchState() }

            self.publish {
                self.isPreviewTransitioning = false
                if success {
                    self.preferenceStore.saveLastCaptureMode(mode)
                } else {
                    self.captureMode = previousMode
                    self.sessionQueue.async {
                        _ = self.configureCurrentMode(phase: .preview)
                        self.synchronizeTorchState()
                    }
                }
            }
        }
    }

    func refreshLiveMetrics() {
        refreshAuxiliaryOutputs()
    }

    func refreshAuxiliaryOutputs() {
        sessionQueue.async { [weak self] in
            guard let self, !self.recordingOperation.requested, !self.movieOutput.isRecording else { return }
            self.session.beginConfiguration()
            self.configureAuxiliaryOutputs()
            self.session.commitConfiguration()
        }
    }

    // Called inside the same transaction as the input/format change.
    private func configureAuxiliaryOutputs() {
        configureLiveMetrics()
        configureAudioMeter()
    }

    private func configureLiveMetrics() {
        let wanted = captureSettingsStore.liveRecordingStatsEnabled && captureMode != .photo
        let attached = session.outputs.contains { $0 === liveMetrics.output }
        guard wanted != attached else { return }
        if wanted && !attached && session.canAddOutput(liveMetrics.output) { session.addOutput(liveMetrics.output) }
        if !wanted && attached { session.removeOutput(liveMetrics.output) }
        let available = session.outputs.contains { $0 === liveMetrics.output }
        publish { self.liveMetricsAvailable = available }
    }

    private func configureAudioMeter() {
        let wanted = captureSettingsStore.audioMeterEnabled && captureMode != .photo
        let attached = session.outputs.contains { $0 === audioMeter.output }
        guard wanted != attached else { return }

        if wanted && !attached && session.canAddOutput(audioMeter.output) {
            session.addOutput(audioMeter.output)
        }
        if !wanted && attached {
            session.removeOutput(audioMeter.output)
            audioMeter.stop()
            publish { self.audioLevel = 0 }
        }
    }

    private func startLiveMetrics() {
        metricsTimer?.cancel()
        previousMetricBytes = 0
        previousMetricDuration = 0
        liveMetrics.setRunning(true)
        publish { self.liveFPS = nil; self.liveMbps = nil; self.liveCaptureDrops = nil }
        guard captureSettingsStore.liveRecordingStatsEnabled else { return }
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
            let measurement = self.liveMetrics.read()
            let attached = self.session.outputs.contains { $0 === self.liveMetrics.output }
            self.publish {
                self.liveFPS = attached ? measurement.fps : nil
                self.liveMbps = mbps
                self.liveCaptureDrops = attached && measurement.fps != nil ? measurement.drops : nil
            }
        }
        metricsTimer = timer
        timer.resume()
    }

    private func startAudioMeter() {
        let enabled = captureSettingsStore.audioMeterEnabled && captureMode != .photo
        let attached = session.outputs.contains { $0 === audioMeter.output }
        publish { self.audioLevel = 0 }

        guard enabled && attached else {
            audioMeter.stop()
            return
        }

        audioMeter.startPublishing { [weak self] level in
            guard let self else { return }
            self.publish { self.audioLevel = level }
        }
    }

    private func stopAudioMeter() {
        audioMeter.stop()
        publish { self.audioLevel = 0 }
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
            _ = self.configureCurrentMode(phase: .preview)
        }
    }

    func captureBurst() {
        guard captureMode == .photo, isSessionRunning, !isCapturingPhoto, !isRecordingStarting, !isFinalizingRecording, !isPreviewTransitioning else { return }
        let count = captureSettingsStore.burstCount
        isCapturingPhoto = true
        sessionQueue.async { [weak self] in
            guard let self else { return }
            self.burstRemaining = count
            self.burstAspect = self.captureSettingsStore.photoAspect
            self.beginPhotoCapture()
        }
    }

    /// Stops a held burst after the photo currently in flight returns from the camera.
    func cancelBurst() {
        sessionQueue.async { [weak self] in
            guard let self, self.burstRemaining > 0 else { return }
            self.burstRemaining = 0
        }
    }

    func capturePhoto() {
        guard captureMode == .photo, !isRecording, !isRecordingStarting, !isFinalizingRecording, !isCapturingPhoto, !isPreviewTransitioning else { return }
        isCapturingPhoto = true
        sessionQueue.async { [weak self] in
            guard let self else { return }
            self.beginPhotoCapture()
        }
    }

    func selectPhotoResolution(_ option: PhotoResolutionOption) {
        guard supportedPhotoResolutions.contains(option) else { return }
        preferenceStore.savePhotoResolutionID(option.id)
        sessionQueue.async { [weak self] in
            guard let self else { return }
            self.refreshPhotoResolutionState()
        }
    }

    /// Rebuilds the output-size choices when 4:3 / 1:1 changes. Lower MP choices are
    /// post-processed from the camera's maximum still, so changing resolution never forces a
    /// sensor-format reconfiguration or changes the requested aspect ratio.
    func refreshPhotoResolutionForCurrentAspect() {
        sessionQueue.async { [weak self] in
            guard let self else { return }
            if self.activeMaximumPhotoDimensions.width > 0 && self.activeMaximumPhotoDimensions.height > 0 {
                self.refreshPhotoResolutionState()
            } else if self.captureMode == .photo {
                _ = self.applyBestPhotoFormat(preferVirtualCamera: !self.requiresPhysicalWhiteBalanceInput)
            }
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
        let requestID = requestGate.next(.whiteBalance)
        sessionQueue.async { [weak self] in
            guard let self, self.requestGate.isCurrent(requestID),
                  !self.movieOutput.isRecording, !self.recordingOperation.requested else { return }

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
                guard self.requestGate.isCurrent(requestID) else { return }
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
                guard let self, self.requestGate.isCurrent(requestID) else { return }

                let configured = self.configureCurrentMode(phase: .preview, preferVirtualCamera: preset == .auto)
                guard self.requestGate.isCurrent(requestID) else { return }

                if !configured || self.requestedWhiteBalancePreset != preset {
                    self.requestedWhiteBalancePreset = previousPreset
                    _ = self.configureCurrentMode(phase: .preview, preferVirtualCamera: previousPreset == .auto)
                    self.publish { self.whiteBalancePreset = previousPreset }
                    self.showError(preset == .auto
                        ? "Couldn’t enable Auto white balance."
                        : "Manual white balance isn’t available on this lens.")
                }

                DispatchQueue.main.asyncAfter(deadline: .now() + 0.12) { [weak self] in
                    guard let self, self.requestGate.isCurrent(requestID) else { return }
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
            self.configureCurrentMode(phase: .preview)
        }
    }

    func selectFrameRate(_ frameRate: VideoFrameRate) {
        selectedFrameRate = frameRate
        guard captureMode == .video else { return }
        sessionQueue.async { [weak self] in
            guard let self else { return }
            self.configureCurrentMode(phase: .preview)
        }
    }

    func selectSlowMotionResolution(_ resolution: VideoResolution) {
        selectedSlowMotionResolution = resolution
        guard captureMode == .sloMo else { return }
        sessionQueue.async { [weak self] in _ = self?.configureCurrentMode(phase: .preview) }
    }

    func selectSlowMotionFrameRate(_ frameRate: SlowMotionFrameRate) {
        selectedSlowMotionFrameRate = frameRate
        guard captureMode == .sloMo else { return }
        sessionQueue.async { [weak self] in _ = self?.configureCurrentMode(phase: .preview) }
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
            guard let self, !self.recordingOperation.finalizationPending else { return }

            if self.recordingOperation.requested {
                self.requestGate.invalidate(.recordingStart)
                self.segmentTimer?.cancel()

                if self.recordingOperation.segmentActive || self.movieOutput.isRecording {
                    self.recordingOperation.requestFinalStop()
                    self.publish { self.recordingLifecycle = .stopping }
                    self.postStatus("Saving to Photos…")
                    if self.movieOutput.isRecording { self.movieOutput.stopRecording() }
                } else {
                    let hadExistingSession = self.recordingSessionStartedAt != nil
                    let awaitingDelegateCleanup = self.recordingOperation.cancelPendingStart(
                        finalizeExistingSession: hadExistingSession
                    )
                    if awaitingDelegateCleanup {
                        self.publish { self.recordingLifecycle = .stopping }
                    } else if self.recordingOperation.finalizationPending {
                        self.recordingSessionStartedAt = nil
                        self.publish {
                            self.durationTimer?.invalidate()
                            self.durationTimer = nil
                            self.recordingDuration = 0
                            self.recordingLifecycle = .saving
                        }
                        self.restoreIdleCaptureConfigurationAfterRecording()
                        self.finishFinalizingIfPossible()
                    } else {
                        self.publish { self.recordingLifecycle = .idle }
                        self.restoreIdleCaptureConfigurationAfterRecording()
                    }
                }
                return
            }

            guard !self.isCapturingPhoto else { return }
            self.recordingOperation.begin(splitSeconds: self.captureSettingsStore.splitDurationSeconds)
            let startToken = self.requestGate.next(.recordingStart)
            self.publish {
                self.recordingLifecycle = .starting
                self.lastFrameGaps = nil
            }
            self.beginRecording(requestToken: startToken)
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
                device.formats.contains { CameraFormatSelector.format($0, supports: preset.resolution, frameRate: preset.frameRate) }
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
                    let success = self.configureCurrentMode(phase: .preview)
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
        _ = configureCurrentMode(phase: .preview)
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
        let shouldPreserveTorch = oldInput?.device.hasTorch == true && oldInput?.device.torchMode == .on
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
        configureAuxiliaryOutputs()
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

            let displayedZoom = CameraZoomController.snappedDisplayedZoom(requestedZoom, for: desiredDevice)
            desiredDevice.cancelVideoZoomRamp()
            desiredDevice.videoZoomFactor = CameraZoomController.deviceZoom(forDisplayedZoom: displayedZoom, device: desiredDevice)
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
        let supported = CameraFormatSelector.availableResolutions(devices: devices, codec: selectedVideoCodec)
        let selection = validSelection(for: devices, availableResolutions: supported)
        let slowMotionResolutions = CameraFormatSelector.slowMotionResolutions(devices: devices, codec: selectedVideoCodec)
        let slowMotionResolution = slowMotionResolutions.contains(selectedSlowMotionResolution)
            ? selectedSlowMotionResolution
            : (slowMotionResolutions.contains(.p1080) ? .p1080 : (slowMotionResolutions.first ?? .p1080))
        let slowMotionRates = CameraFormatSelector.slowMotionFrameRates(devices: devices, resolution: slowMotionResolution, codec: selectedVideoCodec)
        let slowMotionSelection = slowMotionRates.contains(selectedSlowMotionFrameRate)
            ? selectedSlowMotionFrameRate
            : (slowMotionRates.last ?? .fps120)
        publish {
            let wasSuppressing = self.suppressPreferencePersistence
            self.suppressPreferencePersistence = true
            self.supportedResolutions = supported
            self.torchAvailable = device.hasTorch && device.isTorchAvailable
            self.isTorchOn = device.hasTorch && device.torchMode == .on
            self.minimumZoomFactor = CameraZoomController.minimumDisplayedZoom(for: device)
            self.maximumZoomFactor = CameraZoomController.maximumDisplayedZoom(for: device)
            let displayedZoom = CameraZoomController.displayedZoom(forDeviceZoom: device.videoZoomFactor, device: device)
            self.zoomFactor = displayedZoom
            self.zoomLabel = CameraZoomController.formattedLabel(for: displayedZoom)
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
        WhiteBalanceController.requiresPhysicalRearInput(
            preset: requestedWhiteBalancePreset,
            position: cameraPosition
        )
    }

    @discardableResult
    private func applyWhiteBalancePresetToCurrentCamera(_ preset: WhiteBalancePreset) -> Bool {
        guard let device = videoInput?.device else { return false }

        // Auto WB is supported on virtual and physical cameras. Manual presets are only
        // considered successful on the actual capture input so the UI can't claim a change
        // that isn't visible in the rear Video/Photo stream.
        let applied = WhiteBalanceController.apply(preset, to: device)

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
    private func configureCurrentMode(
        phase: CaptureConfigurationPhase,
        preferVirtualCamera override: Bool? = nil
    ) -> Bool {
        let preferVirtualCamera = override ?? !requiresPhysicalWhiteBalanceInput

        switch captureMode {
        case .photo:
            guard phase == .preview else { return false }
            return applyBestPhotoFormat(preferVirtualCamera: preferVirtualCamera)

        case .video:
            let alreadyReadyToRecord = phase == .recording && previewPipeline == .native && videoInput.map {
                CameraFormatSelector.activeVideoFormatMatches(
                    device: $0.device,
                    resolution: selectedResolution,
                    frameRate: selectedFrameRate,
                    codec: selectedVideoCodec
                )
            } == true
            let configured = alreadyReadyToRecord || applySelectedFormat(
                preferVirtualCamera: preferVirtualCamera,
                phase: phase
            )
            guard configured else { return false }
            guard phase == .recording, let device = videoInput?.device else { return phase == .preview }

            // The preview path may have just normalized an unsupported saved choice (for example
            // after a rapid rear/front switch). Verify against the same normalized selection rather
            // than waiting for its async @Published update to reach the main thread.
            let devices = capabilityDevices(for: cameraPosition.avPosition)
            let available = CameraFormatSelector.availableResolutions(devices: devices, codec: selectedVideoCodec)
            let expected = validSelection(for: devices, availableResolutions: available)
            return CameraFormatSelector.activeVideoFormatMatches(
                device: device,
                resolution: expected.resolution,
                frameRate: expected.frameRate,
                codec: selectedVideoCodec
            )

        case .sloMo:
            let configured = applySlowMotionFormat(phase: phase)
            guard configured else { return false }
            guard phase == .recording, let device = videoInput?.device,
                  previewPipeline != .slowMotionProxy else { return phase == .preview }

            let devices = capabilityDevices(for: cameraPosition.avPosition)
            let resolutions = CameraFormatSelector.slowMotionResolutions(devices: devices, codec: selectedVideoCodec)
            guard !resolutions.isEmpty else { return false }
            let expectedResolution = resolutions.contains(selectedSlowMotionResolution)
                ? selectedSlowMotionResolution
                : (resolutions.contains(.p1080) ? .p1080 : resolutions[0])
            let rates = CameraFormatSelector.slowMotionFrameRates(
                devices: devices,
                resolution: expectedResolution,
                codec: selectedVideoCodec
            )
            guard !rates.isEmpty else { return false }
            let expectedRate = rates.contains(selectedSlowMotionFrameRate)
                ? selectedSlowMotionFrameRate
                : (rates.last ?? .fps120)
            return CameraFormatSelector.activeSlowMotionFormatMatches(
                device: device,
                resolution: expectedResolution,
                frameRate: expectedRate,
                codec: selectedVideoCodec
            )
        }
    }

    @discardableResult
    private func applyBestPhotoFormat(preferVirtualCamera: Bool = true) -> Bool {
        let devices = capabilityDevices(for: cameraPosition.avPosition)
        guard !devices.isEmpty else {
            showError("Photo capture is unavailable on this camera.")
            return false
        }

        let physical = CameraZoomController.desiredPhysicalDevice(in: devices, displayedZoom: requestedZoom)
        let desiredDevice = preferVirtualCamera
            ? (devices.first(where: { $0.isVirtualDevice }) ?? physical ?? devices.first)
            : (physical ?? devices.first(where: { !$0.isVirtualDevice }) ?? devices.first)

        guard let desiredDevice,
              let maximum = photoFormatCandidates(for: desiredDevice).first else {
            showError("Full-resolution photos aren’t available on this camera.")
            return false
        }

        let previewRange = maximum.format.videoSupportedFrameRateRanges.first {
            $0.minFrameRate <= 30 && $0.maxFrameRate >= 30
        } ?? maximum.format.videoSupportedFrameRateRanges.first
        let previewFPS = min(max(30.0, previewRange?.minFrameRate ?? 30), previewRange?.maxFrameRate ?? 30)

        // Always keep Photo mode on the camera's best still-photo source. The selectable MP
        // values are produced after capture. This avoids lower-resolution sensor formats that
        // can silently return fewer pixels or a different aspect ratio (for example 10 MP ->
        // ~7 MP, or a tall non-4:3 image on some formats).
        guard let displayedZoom = applyAtomicCaptureConfiguration(
            device: desiredDevice,
            format: maximum.format,
            frameRate: previewFPS,
            photoDimensions: maximum.dimensions
        ) else {
            showError("Couldn’t configure full-resolution Photo mode.")
            return false
        }

        activeMaximumPhotoDimensions = maximum.dimensions
        previewPipeline = .native
        let minimum = CameraZoomController.minimumDisplayedZoom(for: desiredDevice)
        let maximumZoom = CameraZoomController.maximumDisplayedZoom(for: desiredDevice)
        let resolutionState = resolvedPhotoResolutionState(
            maximumCaptureDimensions: maximum.dimensions,
            aspect: currentPhotoAspect
        )
        publish {
            self.minimumZoomFactor = minimum
            self.maximumZoomFactor = maximumZoom
            self.zoomFactor = displayedZoom
            self.zoomLabel = CameraZoomController.formattedLabel(for: displayedZoom)
            self.torchAvailable = desiredDevice.hasTorch && desiredDevice.isTorchAvailable
            self.isTorchOn = desiredDevice.hasTorch && desiredDevice.torchMode == .on
            self.currentPhotoResolutionLabel = PhotoResolutionCatalog.label(for: resolutionState.selected.dimensions)
            self.currentPhotoPixelCount = PhotoResolutionCatalog.pixelCount(resolutionState.selected.dimensions)
            self.supportedPhotoResolutions = resolutionState.options
            self.selectedPhotoResolutionID = resolutionState.selected.id
        }
        resetFocusAndExposureState()
        synchronizeWhiteBalanceAfterConfiguration()
        return true
    }

    private var currentPhotoAspect: String {
        captureSettingsStore.photoAspect
    }


    private func refreshPhotoResolutionState() {
        guard activeMaximumPhotoDimensions.width > 0, activeMaximumPhotoDimensions.height > 0 else { return }
        let state = resolvedPhotoResolutionState(
            maximumCaptureDimensions: activeMaximumPhotoDimensions,
            aspect: currentPhotoAspect
        )
        publish {
            self.supportedPhotoResolutions = state.options
            self.selectedPhotoResolutionID = state.selected.id
            self.currentPhotoResolutionLabel = PhotoResolutionCatalog.label(for: state.selected.dimensions)
            self.currentPhotoPixelCount = PhotoResolutionCatalog.pixelCount(state.selected.dimensions)
        }
    }

    private func resolvedPhotoResolutionState(
        maximumCaptureDimensions: CMVideoDimensions,
        aspect: String,
        requestedID overrideID: String? = nil
    ) -> (selected: PhotoResolutionOption, options: [PhotoResolutionOption]) {
        let options = PhotoResolutionCatalog.options(
            maximumCaptureDimensions: maximumCaptureDimensions,
            aspect: aspect
        )
        if options.isEmpty {
            let fallback = PhotoResolutionOption(id: "max", label: "Max", dimensions: maximumCaptureDimensions)
            return (fallback, [fallback])
        }

        var requestedID = overrideID ?? preferenceStore.photoResolutionID
        if overrideID == nil,
           requestedID.hasPrefix("photo-"),
           let migrated = PhotoResolutionCatalog.migratedID(fromLegacyID: requestedID, options: options) {
            requestedID = migrated
            preferenceStore.savePhotoResolutionID(migrated)
        }
        if overrideID == nil,
           !options.contains(where: { $0.id == requestedID }),
           let replacement = PhotoResolutionCatalog.replacementForRemovedPreset(requestedID, options: options) {
            requestedID = replacement
            preferenceStore.savePhotoResolutionID(replacement)
        }

        let selected = options.first(where: { $0.id == requestedID }) ?? options[0]
        return (selected, options)
    }

    private func photoFormatCandidates(for device: AVCaptureDevice) -> [PhotoFormatCandidate] {
        var bestByDimensions: [String: PhotoFormatCandidate] = [:]

        for format in device.formats {
            let previewDimensions = CMVideoFormatDescriptionGetDimensions(format.formatDescription)
            let previewPixels = Int64(previewDimensions.width) * Int64(previewDimensions.height)
            let supports30FPS = format.videoSupportedFrameRateRanges.contains {
                $0.minFrameRate <= 30 && $0.maxFrameRate >= 30
            }

            for dimensions in format.supportedMaxPhotoDimensions where dimensions.width > 0 && dimensions.height > 0 {
                let id = "photo-\(dimensions.width)x\(dimensions.height)"
                let candidate = PhotoFormatCandidate(
                    id: id,
                    format: format,
                    dimensions: dimensions,
                    photoPixels: Int64(dimensions.width) * Int64(dimensions.height),
                    previewPixels: previewPixels,
                    supports30FPS: supports30FPS
                )

                if let current = bestByDimensions[id], !isPreferredPhotoCandidate(candidate, over: current) {
                    continue
                }
                bestByDimensions[id] = candidate
            }
        }

        return bestByDimensions.values.sorted { lhs, rhs in
            if lhs.photoPixels != rhs.photoPixels { return lhs.photoPixels > rhs.photoPixels }
            return isPreferredPhotoCandidate(lhs, over: rhs)
        }
    }

    private func isPreferredPhotoCandidate(_ lhs: PhotoFormatCandidate, over rhs: PhotoFormatCandidate) -> Bool {
        if lhs.supports30FPS != rhs.supports30FPS { return lhs.supports30FPS }
        return lhs.previewPixels > rhs.previewPixels
    }

    private func validSelection(for devices: [AVCaptureDevice], availableResolutions: [VideoResolution]) -> (resolution: VideoResolution, frameRate: VideoFrameRate, supportedFrameRates: [VideoFrameRate]) {
        let resolution = availableResolutions.contains(selectedResolution) ? selectedResolution : (availableResolutions.first ?? .p1080)
        let rates = CameraFormatSelector.frameRates(for: resolution, devices: devices, codec: selectedVideoCodec)
        let frameRate = rates.contains(selectedFrameRate) ? selectedFrameRate : (rates.first ?? .fps30)
        return (resolution, frameRate, rates)
    }

    @discardableResult
    private func applySelectedFormat(preferVirtualCamera: Bool = true, phase: CaptureConfigurationPhase) -> Bool {
        let devices = capabilityDevices(for: cameraPosition.avPosition)
        let available = CameraFormatSelector.availableResolutions(devices: devices, codec: selectedVideoCodec)
        guard !available.isEmpty else {
            showError("Video isn’t available on this camera with the selected codec.")
            return false
        }
        let selection = validSelection(for: devices, availableResolutions: available)
        let supportedDevices = devices.filter { device in
            device.formats.contains {
                CameraFormatSelector.format($0, supports: selection.resolution, frameRate: selection.frameRate) && CameraFormatSelector.supports(codec: selectedVideoCodec, format: $0)
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
        let wantsSmooth4K60Preview = phase == .preview && cameraPosition == .back &&
            selection.resolution == .p4k && selection.frameRate == .fps60 &&
            !movieOutput.isRecording && !requiresPhysicalWhiteBalanceInput
        if wantsSmooth4K60Preview,
           let virtual = devices.first(where: { $0.isVirtualDevice }),
           let previewFormat = CameraFormatSelector.smoothPreviewFormat(for: virtual, preferredFrameRate: .fps60),
           let displayed = applyAtomicCaptureConfiguration(device: virtual, format: previewFormat, frameRate: 60) {
            previewPipeline = .videoProxy
            let minZoom = CameraZoomController.minimumDisplayedZoom(for: virtual)
            let maxZoom = CameraZoomController.maximumDisplayedZoom(for: virtual)
            publish {
                self.minimumZoomFactor = minZoom
                self.maximumZoomFactor = maxZoom
                self.zoomFactor = displayed
                self.zoomLabel = CameraZoomController.formattedLabel(for: displayed)
                self.torchAvailable = virtual.hasTorch && virtual.isTorchAvailable
                self.isTorchOn = virtual.hasTorch && virtual.torchMode == .on
            }
            resetFocusAndExposureState()
            synchronizeWhiteBalanceAfterConfiguration()
            return true
        }

        let physical = CameraZoomController.desiredPhysicalDevice(in: supportedDevices, displayedZoom: requestedZoom)
        let desiredDevice = preferVirtualCamera
            ? (supportedDevices.first(where: { $0.isVirtualDevice }) ?? physical ?? supportedDevices.first)
            : (physical ?? supportedDevices.first(where: { !$0.isVirtualDevice }) ?? supportedDevices.first)
        guard let desiredDevice,
              let selectedFormat = CameraFormatSelector.preferredRecordingFormat(for: desiredDevice, resolution: selection.resolution, frameRate: selection.frameRate, codec: selectedVideoCodec) else {
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

        previewPipeline = .native
        _ = configureMovieOutputSettings()
        let minZoom = CameraZoomController.minimumDisplayedZoom(for: desiredDevice)
        let maxZoom = CameraZoomController.maximumDisplayedZoom(for: desiredDevice)
        publish {
            self.minimumZoomFactor = minZoom
            self.maximumZoomFactor = maxZoom
            self.zoomFactor = displayed
            self.zoomLabel = CameraZoomController.formattedLabel(for: displayed)
            self.torchAvailable = desiredDevice.hasTorch && desiredDevice.isTorchAvailable
            self.isTorchOn = desiredDevice.hasTorch && desiredDevice.torchMode == .on
        }
        resetFocusAndExposureState()
        synchronizeWhiteBalanceAfterConfiguration()
        return true
    }

    @discardableResult
    private func applySlowMotionFormat(phase: CaptureConfigurationPhase) -> Bool {
        let devices = capabilityDevices(for: cameraPosition.avPosition)
        let allResolutions = CameraFormatSelector.slowMotionResolutions(devices: devices, codec: selectedVideoCodec)
        guard !allResolutions.isEmpty else {
            showError("Slo-Mo isn’t available on this camera with the selected codec.")
            return false
        }

        let resolution = allResolutions.contains(selectedSlowMotionResolution)
            ? selectedSlowMotionResolution
            : (allResolutions.contains(.p1080) ? .p1080 : allResolutions[0])
        let allRates = CameraFormatSelector.slowMotionFrameRates(devices: devices, resolution: resolution, codec: selectedVideoCodec)
        guard !allRates.isEmpty else {
            showError("Slo-Mo isn’t available at this resolution.")
            return false
        }
        let selectedRate = allRates.contains(selectedSlowMotionFrameRate)
            ? selectedSlowMotionFrameRate
            : (allRates.last ?? .fps120)

        let supportedDevices = devices.filter {
            CameraFormatSelector.bestSlowMotionFormat(for: $0, resolution: resolution, frameRate: selectedRate, codec: selectedVideoCodec) != nil
        }
        guard !supportedDevices.isEmpty else {
            showError("\(selectedRate.rawValue) fps Slo-Mo isn’t available on this camera.")
            return false
        }

        // The selected Slo-Mo quality determines which physical lenses are legal. Keep the
        // viewfinder zoom range inside those lenses even while a virtual camera drives the idle
        // preview, so the user never frames a 0.5×/tele view that cannot actually be recorded.
        let physicalRecordingDevices = supportedDevices.filter { !$0.isVirtualDevice }
        let recordingDevices = physicalRecordingDevices.isEmpty ? supportedDevices : physicalRecordingDevices
        let sloMoMinimumZoom = recordingDevices.map { CameraZoomController.minimumDisplayedZoom(for: $0) }.min() ?? 1
        let sloMoMaximumZoom = recordingDevices.map { CameraZoomController.maximumDisplayedZoom(for: $0) }.max() ?? 1
        requestedZoom = min(max(requestedZoom, sloMoMinimumZoom), sloMoMaximumZoom)

        // Idle Slo-Mo used to stay on a physical HFR lens. Crossing 0.5× <-> 1× therefore
        // removed/added AVCaptureDeviceInput and caused the visible pause. While idle, use the
        // same virtual-camera + 60 fps zoom path as normal Video. Recording still switches once
        // to the real physical HFR format below for the recording phase.
        if phase == .preview,
           !movieOutput.isRecording,
           !requiresPhysicalWhiteBalanceInput,
           let virtual = devices.first(where: { $0.isVirtualDevice }),
           let previewFormat = CameraFormatSelector.smoothPreviewFormat(for: virtual, preferredFrameRate: .fps60),
           let displayed = applyAtomicCaptureConfiguration(device: virtual, format: previewFormat, frameRate: 60) {
            previewPipeline = .slowMotionProxy
            _ = configureMovieOutputSettings()

            let targetPhysical = CameraZoomController.desiredPhysicalDevice(in: recordingDevices, displayedZoom: displayed)
                ?? recordingDevices.first(where: { !$0.isVirtualDevice })
                ?? recordingDevices.first
            let lensResolutions = targetPhysical.map { CameraFormatSelector.slowMotionResolutions(devices: [$0], codec: selectedVideoCodec) } ?? allResolutions
            let lensRates = targetPhysical.map { CameraFormatSelector.slowMotionFrameRates(devices: [$0], resolution: resolution, codec: selectedVideoCodec) } ?? allRates

            publish {
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
                self.zoomLabel = CameraZoomController.formattedLabel(for: displayed)
                self.torchAvailable = virtual.hasTorch && virtual.isTorchAvailable
                self.isTorchOn = virtual.hasTorch && virtual.torchMode == .on
            }
            resetFocusAndExposureState()
            synchronizeWhiteBalanceAfterConfiguration()
            return true
        }

        let physical = CameraZoomController.desiredPhysicalDevice(in: recordingDevices, displayedZoom: requestedZoom)
        // Recording and manual-WB paths use a real constituent camera. This guarantees that the
        // selected lens really supports the requested HFR format instead of relying on a virtual
        // camera format that cannot encode the requested 120/240 fps stream.
        let desiredDevice = physical
            ?? recordingDevices.first(where: { !$0.isVirtualDevice })
            ?? recordingDevices.first
        guard let desiredDevice,
              let hfrFormat = CameraFormatSelector.bestSlowMotionFormat(for: desiredDevice, resolution: resolution, frameRate: selectedRate, codec: selectedVideoCodec) else {
            showError("\(selectedRate.rawValue) fps Slo-Mo isn’t available on this lens.")
            return false
        }

        let requestedFPS = Double(selectedRate.rawValue)
        var appliedFPS = requestedFPS
        if phase == .preview, !movieOutput.isRecording,
           hfrFormat.videoSupportedFrameRateRanges.contains(where: { $0.minFrameRate <= 60.5 && $0.maxFrameRate >= 59.5 }) {
            appliedFPS = 60
        }

        guard let displayed = applyAtomicCaptureConfiguration(
            device: desiredDevice,
            format: hfrFormat,
            frameRate: appliedFPS
        ) else {
            showError("Couldn’t set the Slo-Mo quality.")
            return false
        }

        previewPipeline = phase == .preview && abs(appliedFPS - requestedFPS) > 0.5 ? .slowMotionProxy : .native
        _ = configureMovieOutputSettings()

        let lensResolutions = CameraFormatSelector.slowMotionResolutions(devices: [desiredDevice], codec: selectedVideoCodec)
        let lensRates = CameraFormatSelector.slowMotionFrameRates(devices: [desiredDevice], resolution: resolution, codec: selectedVideoCodec)
        publish {
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
            self.zoomLabel = CameraZoomController.formattedLabel(for: displayed)
            self.torchAvailable = desiredDevice.hasTorch && desiredDevice.isTorchAvailable
            self.isTorchOn = desiredDevice.hasTorch && desiredDevice.torchMode == .on
        }
        resetFocusAndExposureState()
        synchronizeWhiteBalanceAfterConfiguration()
        return true
    }

    @discardableResult
    private func configureMovieOutputSettings() -> Bool {
        guard let connection = movieOutput.connection(with: .video) else { return false }

        let shouldMirror = cameraPosition == .front && captureSettingsStore.mirrorSelfies
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
        guard session.isRunning else {
            burstRemaining = 0
            publish { self.isCapturingPhoto = false }
            showError("Camera isn’t ready yet.")
            return
        }

        let isBurstShot = burstRemaining > 0
        let aspect = isBurstShot ? burstAspect : currentPhotoAspect
        let resolutionState = resolvedPhotoResolutionState(
            maximumCaptureDimensions: photoOutput.maxPhotoDimensions,
            aspect: aspect
        )
        let useHEIC = photoFileFormat == "HEIC" && photoOutput.availablePhotoCodecTypes.contains(.hevc)

        if let connection = photoOutput.connection(with: .video) {
            if connection.isVideoMirroringSupported {
                connection.automaticallyAdjustsVideoMirroring = false
                connection.isVideoMirrored = cameraPosition == .front && captureSettingsStore.mirrorSelfies
            }
            applyCaptureRotation(to: connection)
        }

        let settings = useHEIC
            ? AVCapturePhotoSettings(format: [AVVideoCodecKey: AVVideoCodecType.hevc])
            : AVCapturePhotoSettings(format: [AVVideoCodecKey: AVVideoCodecType.jpeg])

        // One predictable capture path. Balanced avoids the extra latency of the old quality-first
        // setting while keeping normal still-photo quality. MP/aspect processing happens later.
        settings.photoQualityPrioritization = .balanced
        let dimensions = photoOutput.maxPhotoDimensions
        if dimensions.width > 0, dimensions.height > 0 {
            settings.maxPhotoDimensions = dimensions
        }

        let request = PendingPhotoCapture(
            aspect: aspect,
            outputDimensions: resolutionState.selected.dimensions,
            filename: nextMediaFilename(fileExtension: useHEIC ? "heic" : "jpg"),
            isBurst: isBurstShot
        )
        pendingPhotoCaptures[settings.uniqueID] = request
        photoOutput.capturePhoto(with: settings, delegate: self)
    }

    private func beginRecording(requestToken: CaptureRequestGate.Token) {
        // A canceled delayed start must never reset or start a newer recording request.
        guard requestGate.isCurrent(requestToken) else { return }

        func failStart(_ message: String? = nil) {
            let hadExistingSession = recordingSessionStartedAt != nil
            if hadExistingSession {
                recordingOperation.requestFinalStop()
                recordingSessionStartedAt = nil
                publish {
                    self.durationTimer?.invalidate()
                    self.durationTimer = nil
                    self.recordingDuration = 0
                    self.recordingLifecycle = .saving
                }
                restoreIdleCaptureConfigurationAfterRecording()
                finishFinalizingIfPossible()
            } else {
                recordingOperation.reset()
                publish { self.recordingLifecycle = .idle }
                restoreIdleCaptureConfigurationAfterRecording()
            }
            if let message { showError(message) }
        }

        guard recordingOperation.requested,
              session.isRunning,
              movieOutput.isRecording == false else {
            failStart()
            return
        }

        guard configureCurrentMode(phase: .recording) else {
            failStart(captureMode == .sloMo
                ? "Couldn’t start the selected Slo-Mo frame rate."
                : "Couldn’t prepare the selected recording quality.")
            return
        }

        guard configureMovieOutputSettings() else {
            failStart("\(selectedVideoCodec == "H264" ? "H.264" : "HEVC") isn’t available at this resolution/FPS on this lens.")
            return
        }

        applyCaptureRotation(to: movieOutput.connection(with: .video))
        movieOutput.metadata = CameraMovieMetadata.items(isSlowMotion: captureMode == .sloMo)
        refreshAvailableStorage()

        // Format/lens changes can make AF/AE settle for a few frames. Wait briefly so the first
        // recorded frames do not contain avoidable focus/exposure hunting.
        startMovieOutputWhenReady(
            deadline: Date().addingTimeInterval(1.0),
            requestToken: requestToken
        )
    }

    private func startMovieOutputWhenReady(
        deadline: Date,
        requestToken: CaptureRequestGate.Token
    ) {
        guard requestGate.isCurrent(requestToken),
              recordingOperation.requested,
              !movieOutput.isRecording else { return }
        if let device = videoInput?.device,
           (device.isAdjustingFocus || device.isAdjustingExposure),
           Date() < deadline {
            sessionQueue.asyncAfter(deadline: .now() + 0.06) { [weak self] in
                self?.startMovieOutputWhenReady(deadline: deadline, requestToken: requestToken)
            }
            return
        }

        guard requestGate.isCurrent(requestToken), recordingOperation.requested else { return }
        let filename = nextMediaFilename(fileExtension: "mov")
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(filename)
        recordingOperation.markStartIssued()
        movieOutput.startRecording(to: url, recordingDelegate: self)
    }

    private func nextMediaFilename(fileExtension: String) -> String {
        MediaFilenameGenerator.nextFilename(fileExtension: fileExtension)
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
        let count = CameraRecoveryStore.recordings().count
        publish { self.recoverableRecordingCount = count }
    }

    func retryRecoverableRecordings() {
        sessionQueue.async { [weak self] in
            guard let self else { return }
            let files = CameraRecoveryStore.recordings().filter { !self.recoveryRetriesInFlight.contains($0) }
            guard !files.isEmpty else {
                self.refreshRecoveryCount()
                return
            }
            self.pendingVideoSaves += files.count
            self.recoveryRetriesInFlight.formUnion(files)
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
        guard pendingVideoSaves == 0, pendingPhotoSaves == 0 else { return }
        DispatchQueue.main.async {
            guard self.backgroundSaveTask != .invalid else { return }
            UIApplication.shared.endBackgroundTask(self.backgroundSaveTask)
            self.backgroundSaveTask = .invalid
        }
    }

    private func finishFinalizingIfPossible() {
        // A previous split segment can finish importing before AVFoundation delivers didFinish for
        // the segment currently stopping. Never unlock the camera until that active/pending segment
        // has reached its delegate cleanup point as well.
        guard recordingOperation.finalizationPending,
              pendingVideoSaves == 0,
              !movieOutput.isRecording,
              !recordingOperation.segmentActive,
              !recordingOperation.startIssued else { return }
        recordingOperation.reset()
        recordingSessionStartedAt = nil
        publish {
            self.recordingLifecycle = .idle
            self.recordingDuration = 0
        }
        endBackgroundSaveIfPossible()
    }

    private func restoreIdleCaptureConfigurationAfterRecording() {
        guard !movieOutput.isRecording else { return }
        _ = configureCurrentMode(phase: .preview)
    }

    private func saveVideoResourceToPhotos(
        _ fileURL: URL,
        runDiagnostics: Bool,
        recoveryRetry: Bool = false
    ) {
        if runDiagnostics {
            diagnosticsGeneration &+= 1
            publish { self.lastFrameGaps = nil }
        }
        let generation = diagnosticsGeneration
        let performSave: () -> Void = { [weak self] in
            guard let self else { return }
            PHPhotoLibrary.shared().performChanges({
                let request = PHAssetCreationRequest.forAsset()
                let options = PHAssetResourceCreationOptions()
                options.originalFilename = fileURL.lastPathComponent
                options.shouldMoveFile = !runDiagnostics
                request.addResource(with: .video, fileURL: fileURL, options: options)
            }) { [weak self] success, error in
                guard let self else { return }
                self.sessionQueue.async {
                    self.pendingVideoSaves = max(self.pendingVideoSaves - 1, 0)
                    if recoveryRetry { self.recoveryRetriesInFlight.remove(fileURL) }
                    if success {
                        if runDiagnostics {
                            // Photos already owns the saved copy. Diagnose the temporary source
                            // without holding the capture UI in its finalizing state.
                            ClipFrameDiagnostics.inspect(fileURL) { [weak self] gaps in
                                try? FileManager.default.removeItem(at: fileURL)
                                self?.sessionQueue.async { [weak self] in
                                    guard let self, self.diagnosticsGeneration == generation else { return }
                                    self.publish { self.lastFrameGaps = gaps }
                                    self.refreshAvailableStorage()
                                }
                            }
                        }
                        self.postStatus(recoveryRetry ? "Recovered recording saved to Photos" : "Saved to Photos")
                    } else {
                        _ = CameraRecoveryStore.preserve(fileURL)
                        self.showError("Couldn’t save to Photos. The recording is kept in Recovery. \(error?.localizedDescription ?? "")")
                    }
                    self.refreshRecoveryCount()
                    self.refreshAvailableStorage()
                    if self.recordingOperation.finalizationPending {
                        self.finishFinalizingIfPossible()
                    } else {
                        self.endBackgroundSaveIfPossible()
                    }
                }
            }
        }

        performSave()
    }

    private func savePhotoResourceToPhotos(_ data: Data, filename: String) {
        pendingPhotoSaves += 1
        beginBackgroundSaveIfNeeded()

        PHPhotoLibrary.shared().performChanges({
            let request = PHAssetCreationRequest.forAsset()
            let options = PHAssetResourceCreationOptions()
            options.originalFilename = filename
            request.addResource(with: .photo, data: data, options: options)
        }) { [weak self] success, error in
            guard let self else { return }
            self.sessionQueue.async {
                self.pendingPhotoSaves = max(self.pendingPhotoSaves - 1, 0)
                if success {
                    self.postStatus("Saved to Photos")
                } else {
                    self.showError(error?.localizedDescription ?? "Couldn’t save the photo.")
                }

                if self.pendingPhotoSaves == 0 {
                    self.refreshAvailableStorage()
                    self.endBackgroundSaveIfPossible()
                }
            }
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
            // `startIssued` only describes the gap between startRecording(...) and this callback.
            // Clear it as soon as AVFoundation confirms the segment actually started so a later
            // split-segment startup cannot inherit stale pending-start state.
            self.recordingOperation.markStartConfirmed()

            if !self.recordingOperation.requested {
                self.recordingOperation.markDiscardOnFinish()
                if self.movieOutput.isRecording { self.movieOutput.stopRecording() }
                return
            }

            self.startLiveMetrics()
            self.startAudioMeter()
            self.segmentTimer?.cancel()
            if self.recordingOperation.splitSeconds > 0 {
                let timer = DispatchWorkItem { [weak self] in
                    guard let self, self.recordingOperation.requested, self.movieOutput.isRecording else { return }
                    self.recordingOperation.markSegmentBoundary()
                    self.movieOutput.stopRecording()
                }
                self.segmentTimer = timer
                self.sessionQueue.asyncAfter(deadline: .now() + self.recordingOperation.splitSeconds, execute: timer)
            }

            if self.recordingSessionStartedAt == nil {
                self.recordingSessionStartedAt = Date()
            }
            let sessionStartedAt = self.recordingSessionStartedAt
            self.publish {
                self.recordingLifecycle = .recording
                self.durationTimer?.invalidate()
                let timer = Timer(timeInterval: 0.25, repeats: true) { [weak self] _ in
                    guard let self, let startedAt = sessionStartedAt else { return }
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
            self.metricsTimer?.cancel()
            self.metricsTimer = nil
            self.liveMetrics.setRunning(false)
            self.stopAudioMeter()
            self.segmentTimer?.cancel()

            if self.recordingOperation.discardOnFinish {
                try? FileManager.default.removeItem(at: outputFileURL)
                let hadExistingSession = self.recordingSessionStartedAt != nil
                self.recordingOperation.finishDiscardedSegment(
                    finalizeExistingSession: hadExistingSession
                )
                self.recordingSessionStartedAt = nil
                self.publish {
                    self.durationTimer?.invalidate()
                    self.durationTimer = nil
                    self.recordingDuration = 0
                    self.recordingLifecycle = hadExistingSession ? .saving : .idle
                }
                self.restoreIdleCaptureConfigurationAfterRecording()
                if hadExistingSession {
                    self.finishFinalizingIfPossible()
                }
                return
            }

            let shouldContinue = self.recordingOperation.consumeSegmentContinuation(
                successful: successful,
                sessionRunning: self.session.isRunning
            )

            if !successful {
                let hasOutstandingSaves = self.pendingVideoSaves > 0
                if hasOutstandingSaves {
                    self.recordingOperation.requestFinalStop()
                } else {
                    self.recordingOperation.reset()
                }
                self.recordingSessionStartedAt = nil
                let retained = CameraRecoveryStore.preserve(outputFileURL)
                self.refreshRecoveryCount()
                self.publish {
                    self.durationTimer?.invalidate()
                    self.durationTimer = nil
                    self.recordingDuration = 0
                    self.recordingLifecycle = hasOutstandingSaves ? .saving : .idle
                }
                self.restoreIdleCaptureConfigurationAfterRecording()
                if hasOutstandingSaves {
                    self.finishFinalizingIfPossible()
                }
                let suffix = retained == nil ? "" : " It is kept in Recovery."
                self.showError("Recording stopped: \(error?.localizedDescription ?? "Unknown error").\(suffix)")
                return
            }

            self.pendingVideoSaves += 1
            self.beginBackgroundSaveIfNeeded()
            let diagnosticsEnabled = captureSettingsStore.droppedFrameDiagnosticsEnabled
            // Avoid decoding a completed split segment while the next HFR/4K segment is recording.
            self.saveVideoResourceToPhotos(
                outputFileURL,
                runDiagnostics: diagnosticsEnabled && !shouldContinue
            )

            if shouldContinue {
                let startToken = self.requestGate.next(.recordingStart)
                self.publish {
                    self.recordingLifecycle = .starting
                }
                self.beginRecording(requestToken: startToken)
            } else {
                self.recordingOperation.requestFinalStop()
                self.publish {
                    self.durationTimer?.invalidate()
                    self.durationTimer = nil
                    self.recordingDuration = 0
                    self.recordingLifecycle = .saving
                }
                self.restoreIdleCaptureConfigurationAfterRecording()
                self.finishFinalizingIfPossible()
            }
        }
    }
}


extension CameraManager: AVCapturePhotoCaptureDelegate {
    func photoOutput(_ output: AVCapturePhotoOutput, didFinishProcessingPhoto photo: AVCapturePhoto, error: Error?) {
        let captureID = photo.resolvedSettings.uniqueID
        let data = error == nil ? photo.fileDataRepresentation() : nil

        sessionQueue.async { [weak self] in
            guard let self else { return }
            guard let request = self.pendingPhotoCaptures[captureID] else { return }

            guard let data else {
                // didFinishCaptureFor is the camera-side finish point and will release the shutter.
                // Stop a burst now so a failed frame does not queue another capture.
                self.burstRemaining = 0
                self.showError(error?.localizedDescription ?? "Couldn’t create the photo file.")
                return
            }

            // Camera capture and app-side processing are separate now. The request is already a
            // complete snapshot, so crop/resize/encode can run without holding up the camera queue.
            self.storageQueue.async { [weak self] in
                guard let self else { return }
                guard let processed = PhotoAspectProcessor.process(
                    data,
                    aspect: request.aspect,
                    targetDimensions: request.outputDimensions
                ) else {
                    self.showError("Couldn’t prepare the selected photo size. Please try again.")
                    return
                }

                self.sessionQueue.async {
                    self.publish {
                        self.currentPhotoResolutionLabel = PhotoResolutionCatalog.label(for: processed.dimensions)
                        self.currentPhotoPixelCount = PhotoResolutionCatalog.pixelCount(processed.dimensions)
                    }
                    self.savePhotoResourceToPhotos(processed.data, filename: request.filename)
                }
            }
        }
    }

    private func finishCameraSidePhotoCapture(request: PendingPhotoCapture, succeeded: Bool) {
        if request.isBurst {
            burstRemaining = succeeded ? max(0, burstRemaining - 1) : 0
            if burstRemaining > 0, session.isRunning {
                beginPhotoCapture()
                return
            }
            burstRemaining = 0
        }
        publish { self.isCapturingPhoto = false }
    }

    func photoOutput(
        _ output: AVCapturePhotoOutput,
        didFinishCaptureFor resolvedSettings: AVCaptureResolvedPhotoSettings,
        error: Error?
    ) {
        sessionQueue.async { [weak self] in
            guard let self else { return }
            guard let request = self.pendingPhotoCaptures.removeValue(forKey: resolvedSettings.uniqueID) else {
                if let error { self.showError("Photo capture failed: \(error.localizedDescription)") }
                return
            }

            self.finishCameraSidePhotoCapture(request: request, succeeded: error == nil)
            if let error {
                self.showError("Photo capture failed: \(error.localizedDescription)")
            }
        }
    }
}
