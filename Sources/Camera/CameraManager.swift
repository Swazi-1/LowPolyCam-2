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
            let configurationToken = requestGate.next(.configuration)
            requestGate.invalidate(.whiteBalance)
            sessionQueue.async { [weak self] in
                guard let self, !self.movieOutput.isRecording, self.requestGate.isCurrent(configurationToken) else { return }
                self.updateCapabilities()
                guard self.requestGate.isCurrent(configurationToken) else { return }
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
    private var activeWhiteBalanceOperationID: UUID?
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
    private var rotationCoordinatorDeviceID: String?
    private var lastHardwareConfigurationChangeAt: Date?
    private var lastAppliedMovieSettingsSignature: String?
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
        if let device = videoInput?.device {
            let dimensions = CMVideoFormatDescriptionGetDimensions(device.activeFormat.formatDescription)
            if let resolution = VideoResolution.allCases.first(where: {
                $0.dimensions.width == dimensions.width && $0.dimensions.height == dimensions.height
            }) {
                let seconds = device.activeVideoMinFrameDuration.seconds
                if seconds > 0 {
                    return CaptureStorageEstimator.videoBitsPerSecond(
                        resolution: resolution,
                        frameRate: 1 / seconds,
                        compression: videoCompression,
                        codec: selectedVideoCodec
                    )
                }
            }
        }
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

            let legalDevices = self.legalZoomDevicesForCurrentMode()
            let recordingOrStarting = self.movieOutput.isRecording || self.recordingOperation.requested
            let domainDevices = recordingOrStarting ? [currentDevice] : legalDevices
            let domain = CameraZoomController.displayedZoomDomain(for: domainDevices)
            let requested = CameraZoomController.clampDisplayedZoom(requestedFactor, to: domain)
            let plan = CameraZoomController.planRequest(
                displayedZoom: requested,
                currentDevice: currentDevice,
                availableDevices: legalDevices,
                mode: self.captureMode,
                recordingOrStarting: recordingOrStarting
            )

            switch plan {
            case .blockedPhysicalSwitch:
                self.showError("Stop recording to switch physical lenses.")
                return

            case .reconfigureLens(let targetZoom):
                let previousRequested = self.requestedZoom
                self.requestedZoom = targetZoom
                let configurationToken = self.requestGate.next(.configuration)
                self.requestGate.invalidate(.whiteBalance)
                guard self.requestGate.isCurrent(requestID),
                      self.requestGate.isCurrent(configurationToken),
                      self.configureCurrentMode(phase: .preview),
                      self.requestGate.isCurrent(requestID),
                      self.requestGate.isCurrent(configurationToken) else {
                    self.requestedZoom = previousRequested
                    return
                }
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
        let configurationToken = requestGate.next(.configuration)
        requestGate.invalidate(.zoom)
        requestGate.invalidate(.whiteBalance)

        cameraPosition = target
        loadCameraPreferences(for: target)

        sessionQueue.async { [weak self] in
            guard let self,
                  self.requestGate.isCurrent(requestID),
                  self.requestGate.isCurrent(configurationToken) else { return }
            guard self.configureCurrentMode(phase: .preview) else {
                guard self.requestGate.isCurrent(requestID), self.requestGate.isCurrent(configurationToken) else { return }
                self.publish {
                    self.cameraPosition = previous
                    self.loadCameraPreferences(for: previous)
                }
                self.showError("That camera is unavailable.")
                return
            }
            guard self.requestGate.isCurrent(requestID), self.requestGate.isCurrent(configurationToken) else { return }
            self.updateCapabilities()
            self.synchronizeTorchState()
        }
    }

    func selectCaptureMode(_ mode: CaptureMode) {
        guard !isRecording, !isRecordingStarting, !isFinalizingRecording, !isCapturingPhoto, captureMode != mode else { return }
        let previousMode = captureMode
        let requestID = requestGate.next(.modeChange)
        let configurationToken = requestGate.next(.configuration)
        requestGate.invalidate(.zoom)
        requestGate.invalidate(.whiteBalance)
        isPreviewTransitioning = true
        captureMode = mode
        sessionQueue.async { [weak self] in
            guard let self,
                  self.requestGate.isCurrent(requestID),
                  self.requestGate.isCurrent(configurationToken) else { return }
            let success = self.configureCurrentMode(phase: .preview)
            guard self.requestGate.isCurrent(requestID), self.requestGate.isCurrent(configurationToken) else { return }
            if success { self.synchronizeTorchState() }

            self.publish {
                guard self.requestGate.isCurrent(requestID), self.requestGate.isCurrent(configurationToken) else { return }
                self.isPreviewTransitioning = false
                if success {
                    self.preferenceStore.saveLastCaptureMode(mode)
                } else {
                    self.captureMode = previousMode
                    let rollbackToken = self.requestGate.next(.configuration)
                    self.sessionQueue.async {
                        guard self.requestGate.isCurrent(rollbackToken) else { return }
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
            guard let self,
                  !self.recordingOperation.requested,
                  !self.movieOutput.isRecording,
                  self.auxiliaryOutputsNeedUpdate() else { return }
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
        let configurationToken = requestGate.next(.configuration)
        sessionQueue.async { [weak self] in
            guard let self,
                  self.requestGate.isCurrent(requestID),
                  self.requestGate.isCurrent(configurationToken),
                  !self.movieOutput.isRecording, !self.recordingOperation.requested else { return }

            let previousPreset = self.requestedWhiteBalancePreset
            let currentDevice = self.videoInput?.device
            let operationID = UUID()
            self.activeWhiteBalanceOperationID = operationID
            // Going manual from a virtual rear input needs a physical lens. Returning to Auto does
            // not require another swap: Auto works on the current physical input and avoiding that
            // round trip makes the handoff substantially lighter.
            let needsInputSwap = self.cameraPosition == .back && preset != .auto && currentDevice?.isVirtualDevice == true
            self.requestedWhiteBalancePreset = preset

            let finish: (Bool, String?) -> Void = { [weak self] success, deviceID in
                guard let self else { return }
                self.sessionQueue.async {
                    guard self.requestGate.isCurrent(requestID),
                          self.requestGate.isCurrent(configurationToken),
                          self.activeWhiteBalanceOperationID == operationID else { return }
                    self.activeWhiteBalanceOperationID = nil
                    if success, let currentDevice = self.videoInput?.device, currentDevice.uniqueID == deviceID {
                        let legalDevices = self.legalZoomDevicesForCurrentMode()
                        let domain = self.publishedZoomDomain(
                            legalDevices: legalDevices.isEmpty ? [currentDevice] : legalDevices,
                            currentDevice: currentDevice
                        )
                        self.publish {
                            guard self.requestGate.isCurrent(requestID), self.requestGate.isCurrent(configurationToken) else { return }
                            self.whiteBalancePreset = preset
                            self.minimumZoomFactor = domain.lowerBound
                            self.maximumZoomFactor = domain.upperBound
                            self.isPreviewTransitioning = false
                        }
                    } else {
                        self.requestedWhiteBalancePreset = previousPreset
                        _ = self.applyWhiteBalancePresetToCurrentCamera(previousPreset)
                        self.publish {
                            guard self.requestGate.isCurrent(requestID), self.requestGate.isCurrent(configurationToken) else { return }
                            self.whiteBalancePreset = previousPreset
                            self.isPreviewTransitioning = false
                        }
                        self.showError(preset == .auto
                            ? "Couldn’t enable Auto white balance."
                            : "Manual white balance isn’t available on this lens.")
                    }
                }
            }

            let scheduleTimeout: () -> Void = { [weak self] in
                guard let self else { return }
                self.sessionQueue.asyncAfter(deadline: .now() + 1.5) { [weak self] in
                    guard let self,
                          self.requestGate.isCurrent(requestID),
                          self.requestGate.isCurrent(configurationToken),
                          self.activeWhiteBalanceOperationID == operationID else { return }
                    self.activeWhiteBalanceOperationID = nil
                    self.requestedWhiteBalancePreset = previousPreset
                    _ = self.applyWhiteBalancePresetToCurrentCamera(previousPreset)
                    self.publish {
                        self.whiteBalancePreset = previousPreset
                        self.isPreviewTransitioning = false
                    }
                    self.showError("White balance change timed out. Please try again.")
                }
            }

            if !needsInputSwap {
                guard let deviceID = self.videoInput?.device.uniqueID else { return }
                let accepted = self.applyWhiteBalancePresetToCurrentCamera(preset) { success in
                    finish(success, deviceID)
                }
                if accepted { scheduleTimeout() } else { finish(false, deviceID) }
                return
            }

            // Install the transition cover on the main thread before mutating session topology.
            // The second main-queue turn replaces the old arbitrary 45 ms sleep with ownership of
            // the UI transition itself.
            self.publish { self.isPreviewTransitioning = true }
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                self.sessionQueue.async {
                    guard self.requestGate.isCurrent(requestID), self.requestGate.isCurrent(configurationToken) else { return }
                    guard self.configureCurrentMode(phase: .preview, preferVirtualCamera: false, synchronizeWhiteBalance: false),
                          let deviceID = self.videoInput?.device.uniqueID else {
                        finish(false, self.videoInput?.device.uniqueID)
                        return
                    }
                    // The handoff intentionally skipped automatic WB synchronization. Apply once
                    // with the hardware completion so "selected" means the preset reached the input
                    // that won the configuration revision.
                    let accepted = self.applyWhiteBalancePresetToCurrentCamera(preset) { success in
                        finish(success, deviceID)
                    }
                    if accepted { scheduleTimeout() } else { finish(false, deviceID) }
                }
            }
        }
    }



    func selectResolution(_ resolution: VideoResolution) {
        selectedResolution = resolution
        guard captureMode == .video else { return }
        let token = requestGate.next(.configuration)
        requestGate.invalidate(.whiteBalance)
        sessionQueue.async { [weak self] in
            guard let self, self.requestGate.isCurrent(token) else { return }
            _ = self.configureCurrentMode(phase: .preview)
        }
    }

    func selectFrameRate(_ frameRate: VideoFrameRate) {
        selectedFrameRate = frameRate
        guard captureMode == .video else { return }
        let token = requestGate.next(.configuration)
        requestGate.invalidate(.whiteBalance)
        sessionQueue.async { [weak self] in
            guard let self, self.requestGate.isCurrent(token) else { return }
            _ = self.configureCurrentMode(phase: .preview)
        }
    }

    func selectSlowMotionResolution(_ resolution: VideoResolution) {
        selectedSlowMotionResolution = resolution
        guard captureMode == .sloMo else { return }
        let token = requestGate.next(.configuration)
        requestGate.invalidate(.whiteBalance)
        sessionQueue.async { [weak self] in
            guard let self, self.requestGate.isCurrent(token) else { return }
            _ = self.configureCurrentMode(phase: .preview)
        }
    }

    func selectSlowMotionFrameRate(_ frameRate: SlowMotionFrameRate) {
        selectedSlowMotionFrameRate = frameRate
        guard captureMode == .sloMo else { return }
        let token = requestGate.next(.configuration)
        requestGate.invalidate(.whiteBalance)
        sessionQueue.async { [weak self] in
            guard let self, self.requestGate.isCurrent(token) else { return }
            _ = self.configureCurrentMode(phase: .preview)
        }
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
        let configurationToken = requestGate.next(.configuration)
        requestGate.invalidate(.whiteBalance)

        sessionQueue.async { [weak self] in
            guard let self, self.requestGate.isCurrent(configurationToken) else { return }
            let devices = self.capabilityDevices(for: self.cameraPosition.avPosition)
            let supported = !CameraFormatSelector.videoDevices(
                from: devices,
                resolution: preset.resolution,
                frameRate: preset.frameRate,
                codec: "HEVC"
            ).isEmpty
            guard supported else {
                self.showError("This preset isn’t supported by the current camera.")
                self.publish { completion?(false) }
                return
            }

            self.publish {
                guard self.requestGate.isCurrent(configurationToken) else { return }
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
                    guard self.requestGate.isCurrent(configurationToken) else { return }
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
        rotationCoordinator = nil
        rotationCoordinatorDeviceID = nil
        lastAppliedMovieSettingsSignature = nil

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
    ) -> CaptureConfigurationApplyResult? {
        guard let supportedRange = format.videoSupportedFrameRateRanges.first(where: {
            $0.minFrameRate <= frameRate + 0.5 && $0.maxFrameRate >= frameRate - 0.5
        }) else {
            showError("The selected camera format doesn’t support the requested frame rate.")
            return nil
        }

        let actualRate = min(max(frameRate, supportedRange.minFrameRate), supportedRange.maxFrameRate)
        let duration = CMTimeMakeWithSeconds(1.0 / max(actualRate, 1), preferredTimescale: 60_000)
        let oldInput = videoInput
        let shouldPreserveTorch = oldInput?.device.hasTorch == true && oldInput?.device.torchMode == .on
        let isSwitchingInput = oldInput?.device.uniqueID != desiredDevice.uniqueID
        let sameFormat = !isSwitchingInput && desiredDevice.activeFormat === format
        let frameTolerance = actualRate >= 100 ? 1.0 : 0.5
        let sameFrameDurations = sameFormat && CameraFormatSelector.activeFrameDurationsMatch(
            device: desiredDevice,
            frameRate: actualRate,
            tolerance: frameTolerance
        )
        let displayedZoom = CameraZoomController.snappedDisplayedZoom(requestedZoom, for: desiredDevice)
        let targetDeviceZoom = CameraZoomController.deviceZoom(forDisplayedZoom: displayedZoom, device: desiredDevice)
        let sameZoom = !isSwitchingInput && abs(desiredDevice.videoZoomFactor - targetDeviceZoom) < 0.002
        let samePhotoDimensions = photoDimensions.map {
            photoOutput.maxPhotoDimensions.width == $0.width && photoOutput.maxPhotoDimensions.height == $0.height
        } ?? true
        let auxiliaryChange = auxiliaryOutputsNeedUpdate()
        let wantsAutomaticHDR = selectedVideoCodec != "H264"
        let hdrPolicyMatches = desiredDevice.automaticallyAdjustsVideoHDREnabled == wantsAutomaticHDR &&
            (selectedVideoCodec != "H264" || !desiredDevice.isVideoHDREnabled)
        let distortionMatches = !desiredDevice.isGeometricDistortionCorrectionSupported || desiredDevice.isGeometricDistortionCorrectionEnabled
        let needsDeviceWrite = !sameFormat || !sameFrameDurations || !sameZoom || !hdrPolicyMatches || !distortionMatches ||
            (shouldPreserveTorch && desiredDevice.hasTorch && desiredDevice.isTorchAvailable && desiredDevice.torchMode != .on)
        let needsSessionTransaction = isSwitchingInput || !sameFormat || auxiliaryChange || !samePhotoDimensions

        // True no-op path: record start/stop and repeated mode configuration do not reopen an
        // AVCaptureSession transaction, rewrite activeFormat, cancel zoom ramps, or reset AF/AE.
        if !needsSessionTransaction && !needsDeviceWrite {
            if rotationCoordinatorDeviceID != desiredDevice.uniqueID {
                rotationCoordinator = AVCaptureDevice.RotationCoordinator(device: desiredDevice, previewLayer: nil)
                rotationCoordinatorDeviceID = desiredDevice.uniqueID
            }
            requestedZoom = displayedZoom
            return CaptureConfigurationApplyResult(
                displayedZoom: displayedZoom,
                topologyChanged: false,
                deviceConfigurationChanged: false
            )
        }

        var replacementInput: AVCaptureDeviceInput?
        if isSwitchingInput {
            do {
                replacementInput = try AVCaptureDeviceInput(device: desiredDevice)
            } catch {
                showError("Couldn’t access the selected camera.")
                return nil
            }
        }

        var transactionOpen = false
        var committed = false
        if needsSessionTransaction {
            session.beginConfiguration()
            transactionOpen = true
            if auxiliaryChange { configureAuxiliaryOutputs() }
        }
        defer {
            if transactionOpen && !committed { session.commitConfiguration() }
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
            if needsDeviceWrite || isSwitchingInput {
                try desiredDevice.lockForConfiguration()
                deviceLocked = true

                if isSwitchingInput || desiredDevice.activeFormat !== format {
                    desiredDevice.activeFormat = format
                }
                desiredDevice.automaticallyAdjustsVideoHDREnabled = wantsAutomaticHDR
                if selectedVideoCodec == "H264", desiredDevice.isVideoHDREnabled {
                    desiredDevice.isVideoHDREnabled = false
                }
                if desiredDevice.isGeometricDistortionCorrectionSupported,
                   !desiredDevice.isGeometricDistortionCorrectionEnabled {
                    desiredDevice.isGeometricDistortionCorrectionEnabled = true
                }
                if !sameFrameDurations || isSwitchingInput {
                    desiredDevice.activeVideoMinFrameDuration = duration
                    desiredDevice.activeVideoMaxFrameDuration = duration
                }
                if !sameZoom || isSwitchingInput {
                    desiredDevice.cancelVideoZoomRamp()
                    desiredDevice.videoZoomFactor = targetDeviceZoom
                }
                if shouldPreserveTorch, desiredDevice.hasTorch, desiredDevice.isTorchAvailable {
                    desiredDevice.torchMode = .on
                }
                desiredDevice.unlockForConfiguration()
                deviceLocked = false
            }

            if let photoDimensions, !samePhotoDimensions {
                photoOutput.maxPhotoDimensions = photoDimensions
            }

            if transactionOpen {
                session.commitConfiguration()
                committed = true
            }
            if rotationCoordinatorDeviceID != desiredDevice.uniqueID {
                rotationCoordinator = AVCaptureDevice.RotationCoordinator(device: desiredDevice, previewLayer: nil)
                rotationCoordinatorDeviceID = desiredDevice.uniqueID
            }
            requestedZoom = displayedZoom

            let formatOrInputChanged = isSwitchingInput || !sameFormat || !sameFrameDurations
            if formatOrInputChanged { lastHardwareConfigurationChangeAt = Date() }
            return CaptureConfigurationApplyResult(
                displayedZoom: displayedZoom,
                topologyChanged: isSwitchingInput,
                deviceConfigurationChanged: !sameFormat || !sameFrameDurations
            )
        } catch {
            if deviceLocked { desiredDevice.unlockForConfiguration() }
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

        var zoomDevices: [AVCaptureDevice]
        switch captureMode {
        case .photo:
            zoomDevices = devices.filter { !photoFormatCandidates(for: $0).isEmpty }
        case .video:
            zoomDevices = CameraFormatSelector.videoDevices(
                from: devices,
                resolution: selection.resolution,
                frameRate: selection.frameRate,
                codec: selectedVideoCodec
            )
        case .sloMo:
            zoomDevices = CameraFormatSelector.slowMotionDevices(
                from: devices,
                resolution: slowMotionResolution,
                frameRate: slowMotionSelection,
                codec: selectedVideoCodec
            )
        }
        let wbZoomDevices = whiteBalanceCompatibleZoomDevices(zoomDevices)
        if !wbZoomDevices.isEmpty { zoomDevices = wbZoomDevices }
        let zoomDomain = publishedZoomDomain(legalDevices: zoomDevices, currentDevice: device)
        let displayedZoom = CameraZoomController.displayedZoom(forDeviceZoom: device.videoZoomFactor, device: device)
        requestedZoom = CameraZoomController.clampDisplayedZoom(displayedZoom, to: zoomDomain)

        publish {
            let wasSuppressing = self.suppressPreferencePersistence
            self.suppressPreferencePersistence = true
            self.supportedResolutions = supported
            self.torchAvailable = device.hasTorch && device.isTorchAvailable
            self.isTorchOn = device.hasTorch && device.torchMode == .on
            self.minimumZoomFactor = zoomDomain.lowerBound
            self.maximumZoomFactor = zoomDomain.upperBound
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

    private func whiteBalanceCompatibleZoomDevices(_ devices: [AVCaptureDevice]) -> [AVCaptureDevice] {
        guard requiresPhysicalWhiteBalanceInput else { return devices }
        return devices.filter { device in
            !device.isVirtualDevice && device.isWhiteBalanceModeSupported(.locked)
        }
    }

    /// Legal optical navigation for the current requested mode/quality. This deliberately differs
    /// from the active sensor's digital zoom interval: while idle a physical 1x input can still
    /// navigate to a compatible Ultra Wide input at 0.5x.
    private func legalZoomDevicesForCurrentMode() -> [AVCaptureDevice] {
        let devices = capabilityDevices(for: cameraPosition.avPosition)
        let legal: [AVCaptureDevice]
        switch captureMode {
        case .photo:
            legal = devices.filter { !photoFormatCandidates(for: $0).isEmpty }

        case .video:
            let available = CameraFormatSelector.availableResolutions(devices: devices, codec: selectedVideoCodec)
            guard !available.isEmpty else { return videoInput.map { [$0.device] } ?? [] }
            let selection = validSelection(for: devices, availableResolutions: available)
            legal = CameraFormatSelector.videoDevices(
                from: devices,
                resolution: selection.resolution,
                frameRate: selection.frameRate,
                codec: selectedVideoCodec
            )

        case .sloMo:
            let resolutions = CameraFormatSelector.slowMotionResolutions(devices: devices, codec: selectedVideoCodec)
            guard !resolutions.isEmpty else { return videoInput.map { [$0.device] } ?? [] }
            let resolution = resolutions.contains(selectedSlowMotionResolution)
                ? selectedSlowMotionResolution
                : (resolutions.contains(.p1080) ? .p1080 : resolutions[0])
            let rates = CameraFormatSelector.slowMotionFrameRates(devices: devices, resolution: resolution, codec: selectedVideoCodec)
            guard !rates.isEmpty else { return videoInput.map { [$0.device] } ?? [] }
            let rate = rates.contains(selectedSlowMotionFrameRate) ? selectedSlowMotionFrameRate : (rates.last ?? .fps120)
            legal = CameraFormatSelector.slowMotionDevices(
                from: devices,
                resolution: resolution,
                frameRate: rate,
                codec: selectedVideoCodec
            )
        }
        let wbLegal = whiteBalanceCompatibleZoomDevices(legal)
        return wbLegal.isEmpty ? legal : wbLegal
    }

    private func publishedZoomDomain(
        legalDevices: [AVCaptureDevice],
        currentDevice: AVCaptureDevice
    ) -> ClosedRange<CGFloat> {
        let lockedToCurrentSensor = movieOutput.isRecording || recordingOperation.requested
        let domainDevices = lockedToCurrentSensor ? [currentDevice] : legalDevices
        return CameraZoomController.displayedZoomDomain(for: domainDevices.isEmpty ? [currentDevice] : domainDevices)
    }

    private func auxiliaryOutputsNeedUpdate() -> Bool {
        let wantsMetrics = captureSettingsStore.liveRecordingStatsEnabled && captureMode != .photo
        let hasMetrics = session.outputs.contains { $0 === liveMetrics.output }
        let wantsAudioMeter = captureSettingsStore.audioMeterEnabled && captureMode != .photo
        let hasAudioMeter = session.outputs.contains { $0 === audioMeter.output }
        return wantsMetrics != hasMetrics || wantsAudioMeter != hasAudioMeter
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
    private func applyWhiteBalancePresetToCurrentCamera(
        _ preset: WhiteBalancePreset,
        completion: ((Bool) -> Void)? = nil
    ) -> Bool {
        guard let device = videoInput?.device else {
            completion?(false)
            return false
        }
        return WhiteBalanceController.apply(preset, to: device, completion: completion)
    }

    @discardableResult
    private func synchronizeWhiteBalanceAfterConfiguration() -> Bool {
        let preset = requestedWhiteBalancePreset
        guard let deviceID = videoInput?.device.uniqueID else { return false }
        let accepted = applyWhiteBalancePresetToCurrentCamera(preset) { [weak self] success in
            guard success, let self else { return }
            self.sessionQueue.async {
                guard self.requestedWhiteBalancePreset == preset,
                      self.videoInput?.device.uniqueID == deviceID else { return }
                self.publish {
                    guard self.requestedWhiteBalancePreset == preset else { return }
                    self.whiteBalancePreset = preset
                }
            }
        }
        guard accepted else {
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

    private func configureCurrentMode(
        phase: CaptureConfigurationPhase,
        preferVirtualCamera override: Bool? = nil,
        synchronizeWhiteBalance: Bool = true
    ) -> Bool {
        let preferVirtualCamera = override ?? !requiresPhysicalWhiteBalanceInput

        switch captureMode {
        case .photo:
            guard phase == .preview else { return false }
            return applyBestPhotoFormat(preferVirtualCamera: preferVirtualCamera, synchronizeWhiteBalance: synchronizeWhiteBalance)

        case .video:
            let devices = capabilityDevices(for: cameraPosition.avPosition)
            let available = CameraFormatSelector.availableResolutions(devices: devices, codec: selectedVideoCodec)
            guard !available.isEmpty else { return false }
            let expected = validSelection(for: devices, availableResolutions: available)
            let alreadyReadyToRecord = phase == .recording && videoInput.map {
                CameraFormatSelector.activeVideoFormatMatches(
                    device: $0.device,
                    resolution: expected.resolution,
                    frameRate: expected.frameRate,
                    codec: selectedVideoCodec
                )
            } == true
            let configured = alreadyReadyToRecord || applySelectedFormat(
                preferVirtualCamera: preferVirtualCamera,
                phase: phase,
                synchronizeWhiteBalance: synchronizeWhiteBalance
            )
            guard configured else { return false }
            guard phase == .recording, let device = videoInput?.device else { return phase == .preview }
            return CameraFormatSelector.activeVideoFormatMatches(
                device: device,
                resolution: expected.resolution,
                frameRate: expected.frameRate,
                codec: selectedVideoCodec
            )

        case .sloMo:
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

            let alreadyReadyToRecord = phase == .recording && previewPipeline == .native && videoInput.map {
                CameraFormatSelector.activeSlowMotionFormatMatches(
                    device: $0.device,
                    resolution: expectedResolution,
                    frameRate: expectedRate,
                    codec: selectedVideoCodec
                )
            } == true
            let configured = alreadyReadyToRecord || applySlowMotionFormat(phase: phase, synchronizeWhiteBalance: synchronizeWhiteBalance)
            guard configured else { return false }
            guard phase == .recording, let device = videoInput?.device,
                  previewPipeline != .slowMotionProxy else { return phase == .preview }
            return CameraFormatSelector.activeSlowMotionFormatMatches(
                device: device,
                resolution: expectedResolution,
                frameRate: expectedRate,
                codec: selectedVideoCodec
            )
        }
    }

    @discardableResult
    private func applyBestPhotoFormat(preferVirtualCamera: Bool = true, synchronizeWhiteBalance: Bool = true) -> Bool {
        let devices = capabilityDevices(for: cameraPosition.avPosition)
        var legalDevices = devices.filter { !photoFormatCandidates(for: $0).isEmpty }
        let wbLegal = whiteBalanceCompatibleZoomDevices(legalDevices)
        if !wbLegal.isEmpty { legalDevices = wbLegal }
        guard !legalDevices.isEmpty else {
            showError("Photo capture is unavailable on this camera.")
            return false
        }

        let domain = CameraZoomController.displayedZoomDomain(for: legalDevices)
        requestedZoom = CameraZoomController.clampDisplayedZoom(requestedZoom, to: domain)
        let physical = CameraZoomController.desiredPhysicalDevice(in: legalDevices, displayedZoom: requestedZoom)
        let desiredDevice = preferVirtualCamera
            ? (legalDevices.first(where: { $0.isVirtualDevice }) ?? physical ?? legalDevices.first)
            : (physical ?? legalDevices.first(where: { !$0.isVirtualDevice }) ?? legalDevices.first)

        guard let desiredDevice,
              let maximum = photoFormatCandidates(for: desiredDevice).first else {
            showError("Full-resolution photos aren’t available on this camera.")
            return false
        }

        let previewRange = maximum.format.videoSupportedFrameRateRanges.first {
            $0.minFrameRate <= 30 && $0.maxFrameRate >= 30
        } ?? maximum.format.videoSupportedFrameRateRanges.first
        let previewFPS = min(max(30.0, previewRange?.minFrameRate ?? 30), previewRange?.maxFrameRate ?? 30)

        guard let result = applyAtomicCaptureConfiguration(
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
        let zoomDomain = publishedZoomDomain(legalDevices: legalDevices, currentDevice: desiredDevice)
        let resolutionState = resolvedPhotoResolutionState(
            maximumCaptureDimensions: maximum.dimensions,
            aspect: currentPhotoAspect
        )
        publish {
            self.minimumZoomFactor = zoomDomain.lowerBound
            self.maximumZoomFactor = zoomDomain.upperBound
            self.zoomFactor = result.displayedZoom
            self.zoomLabel = CameraZoomController.formattedLabel(for: result.displayedZoom)
            self.torchAvailable = desiredDevice.hasTorch && desiredDevice.isTorchAvailable
            self.isTorchOn = desiredDevice.hasTorch && desiredDevice.torchMode == .on
            self.currentPhotoResolutionLabel = PhotoResolutionCatalog.label(for: resolutionState.selected.dimensions)
            self.currentPhotoPixelCount = PhotoResolutionCatalog.pixelCount(resolutionState.selected.dimensions)
            self.supportedPhotoResolutions = resolutionState.options
            self.selectedPhotoResolutionID = resolutionState.selected.id
        }
        if result.requiresFocusReset { resetFocusAndExposureState() }
        if synchronizeWhiteBalance { synchronizeWhiteBalanceAfterConfiguration() }
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
    private func applySelectedFormat(preferVirtualCamera: Bool = true, phase: CaptureConfigurationPhase, synchronizeWhiteBalance: Bool = true) -> Bool {
        let devices = capabilityDevices(for: cameraPosition.avPosition)
        let available = CameraFormatSelector.availableResolutions(devices: devices, codec: selectedVideoCodec)
        guard !available.isEmpty else {
            showError("Video isn’t available on this camera with the selected codec.")
            return false
        }
        let selection = validSelection(for: devices, availableResolutions: available)
        var supportedDevices = CameraFormatSelector.videoDevices(
            from: devices,
            resolution: selection.resolution,
            frameRate: selection.frameRate,
            codec: selectedVideoCodec
        )
        let wbLegal = whiteBalanceCompatibleZoomDevices(supportedDevices)
        if !wbLegal.isEmpty { supportedDevices = wbLegal }
        guard !supportedDevices.isEmpty else {
            showError("This video quality isn’t available with the selected white balance.")
            return false
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

        // Rear 4K60 now follows the same native lifecycle as 1080p60. The real recording-capable
        // source and exact 60-fps format are prepared while idle, so Record/Stop do not exchange a
        // 1080p proxy for a 4K sensor and then swap it back.
        let navigationDomain = CameraZoomController.displayedZoomDomain(for: supportedDevices)
        requestedZoom = CameraZoomController.clampDisplayedZoom(requestedZoom, to: navigationDomain)
        let physical = CameraZoomController.desiredPhysicalDevice(in: supportedDevices, displayedZoom: requestedZoom)
        let desiredDevice = preferVirtualCamera
            ? (supportedDevices.first(where: { $0.isVirtualDevice }) ?? physical ?? supportedDevices.first)
            : (physical ?? supportedDevices.first(where: { !$0.isVirtualDevice }) ?? supportedDevices.first)
        guard let desiredDevice,
              let selectedFormat = CameraFormatSelector.preferredRecordingFormat(
                for: desiredDevice,
                resolution: selection.resolution,
                frameRate: selection.frameRate,
                codec: selectedVideoCodec
              ) else {
            showError("This video quality isn’t available on this lens.")
            return false
        }

        guard let result = applyAtomicCaptureConfiguration(
            device: desiredDevice,
            format: selectedFormat,
            frameRate: Double(selection.frameRate.rawValue)
        ) else {
            showError("Couldn’t set the video quality.")
            return false
        }

        previewPipeline = .native
        guard configureMovieOutputSettings() else { return false }
        let zoomDomain = publishedZoomDomain(legalDevices: supportedDevices, currentDevice: desiredDevice)
        publish {
            self.minimumZoomFactor = zoomDomain.lowerBound
            self.maximumZoomFactor = zoomDomain.upperBound
            self.zoomFactor = result.displayedZoom
            self.zoomLabel = CameraZoomController.formattedLabel(for: result.displayedZoom)
            self.torchAvailable = desiredDevice.hasTorch && desiredDevice.isTorchAvailable
            self.isTorchOn = desiredDevice.hasTorch && desiredDevice.torchMode == .on
        }
        if result.requiresFocusReset { resetFocusAndExposureState() }
        if synchronizeWhiteBalance { synchronizeWhiteBalanceAfterConfiguration() }
        return true
    }

    @discardableResult
    private func applySlowMotionFormat(phase: CaptureConfigurationPhase, synchronizeWhiteBalance: Bool = true) -> Bool {
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

        var supportedDevices = CameraFormatSelector.slowMotionDevices(
            from: devices,
            resolution: resolution,
            frameRate: selectedRate,
            codec: selectedVideoCodec
        )
        let wbLegal = whiteBalanceCompatibleZoomDevices(supportedDevices)
        if !wbLegal.isEmpty { supportedDevices = wbLegal }
        guard !supportedDevices.isEmpty else {
            showError("\(selectedRate.rawValue) fps Slo-Mo isn’t available on this camera.")
            return false
        }

        // HFR recording uses a physical constituent unless the selected input itself proves it can
        // deliver the requested HFR format. This keeps capability claims tied to the real sensor.
        let physicalRecordingDevices = supportedDevices.filter { !$0.isVirtualDevice }
        let recordingDevices = physicalRecordingDevices.isEmpty ? supportedDevices : physicalRecordingDevices
        let navigationDomain = CameraZoomController.displayedZoomDomain(for: recordingDevices)
        requestedZoom = CameraZoomController.clampDisplayedZoom(requestedZoom, to: navigationDomain)
        let desiredDevice = CameraZoomController.desiredPhysicalDevice(in: recordingDevices, displayedZoom: requestedZoom)
            ?? recordingDevices.first
        guard let desiredDevice,
              let hfrFormat = CameraFormatSelector.bestSlowMotionFormat(
                for: desiredDevice,
                resolution: resolution,
                frameRate: selectedRate,
                codec: selectedVideoCodec
              ) else {
            showError("\(selectedRate.rawValue) fps Slo-Mo isn’t available on this lens.")
            return false
        }

        let requestedFPS = Double(selectedRate.rawValue)
        var appliedFPS = requestedFPS
        // Preserve the user's known-good front-camera preview behavior. Rear 120/240 is always
        // prepared natively while idle so it no longer swaps 60 -> HFR -> 60 at record boundaries.
        if cameraPosition == .front,
           phase == .preview,
           !movieOutput.isRecording,
           hfrFormat.videoSupportedFrameRateRanges.contains(where: { $0.minFrameRate <= 60.5 && $0.maxFrameRate >= 59.5 }) {
            appliedFPS = 60
        }

        guard let result = applyAtomicCaptureConfiguration(
            device: desiredDevice,
            format: hfrFormat,
            frameRate: appliedFPS
        ) else {
            showError("Couldn’t set the Slo-Mo quality.")
            return false
        }

        previewPipeline = abs(appliedFPS - requestedFPS) > 0.5 ? .slowMotionProxy : .native
        guard configureMovieOutputSettings() else { return false }

        let lensResolutions = CameraFormatSelector.slowMotionResolutions(devices: [desiredDevice], codec: selectedVideoCodec)
        let lensRates = CameraFormatSelector.slowMotionFrameRates(devices: [desiredDevice], resolution: resolution, codec: selectedVideoCodec)
        let zoomDomain = publishedZoomDomain(legalDevices: recordingDevices, currentDevice: desiredDevice)
        publish {
            let wasSuppressing = self.suppressPreferencePersistence
            self.suppressPreferencePersistence = true
            self.supportedSlowMotionResolutions = lensResolutions.isEmpty ? allResolutions : lensResolutions
            self.selectedSlowMotionResolution = resolution
            self.supportedSlowMotionFrameRates = lensRates.isEmpty ? allRates : lensRates
            self.selectedSlowMotionFrameRate = selectedRate
            self.suppressPreferencePersistence = wasSuppressing
            self.minimumZoomFactor = zoomDomain.lowerBound
            self.maximumZoomFactor = zoomDomain.upperBound
            self.zoomFactor = result.displayedZoom
            self.zoomLabel = CameraZoomController.formattedLabel(for: result.displayedZoom)
            self.torchAvailable = desiredDevice.hasTorch && desiredDevice.isTorchAvailable
            self.isTorchOn = desiredDevice.hasTorch && desiredDevice.torchMode == .on
        }
        if result.requiresFocusReset { resetFocusAndExposureState() }
        if synchronizeWhiteBalance { synchronizeWhiteBalanceAfterConfiguration() }
        return true
    }

    @discardableResult
    private func configureMovieOutputSettings() -> Bool {
        guard let connection = movieOutput.connection(with: .video) else { return false }

        let shouldMirror = cameraPosition == .front && captureSettingsStore.mirrorSelfies
        if connection.isVideoMirroringSupported {
            connection.automaticallyAdjustsVideoMirroring = false
            if connection.isVideoMirrored != shouldMirror { connection.isVideoMirrored = shouldMirror }
        }

        let shouldStabilize = captureMode == .video && isVideoStabilizationEnabled
        if connection.isVideoStabilizationSupported {
            let requestedMode: AVCaptureVideoStabilizationMode = shouldStabilize ? .auto : .off
            if connection.preferredVideoStabilizationMode != requestedMode {
                connection.preferredVideoStabilizationMode = requestedMode
            }
        }

        let supportedKeys = Set(movieOutput.supportedOutputSettingsKeys(for: connection))
        let preferred: AVVideoCodecType = selectedVideoCodec == "H264" ? .h264 : .hevc
        let codecAvailable = movieOutput.availableVideoCodecTypes.contains(preferred) && supportedKeys.contains(AVVideoCodecKey)
        let message: String? = codecAvailable ? nil : (preferred == .h264 && movieOutput.availableVideoCodecTypes.contains(.hevc)
            ? "This camera configuration requires HEVC / H.265. Select HEVC, or lower the resolution or frame rate to use H.264."
            : "The selected codec is unavailable for this camera configuration.")
        publish { self.codecAvailabilityMessage = message }
        guard codecAvailable else { return false }

        let expectedBitrate = estimatedVideoBitsPerSecond
        if videoCompression != .high && !supportedKeys.contains(AVVideoCompressionPropertiesKey) {
            publish { self.codecAvailabilityMessage = "This camera configuration can’t apply the selected bitrate profile." }
            return false
        }

        var requestedSettings: [String: Any] = [AVVideoCodecKey: preferred]
        if videoCompression != .high {
            requestedSettings[AVVideoCompressionPropertiesKey] = [
                AVVideoAverageBitRateKey: Int(expectedBitrate)
            ]
        }

        func settingsMatch(_ applied: [String: Any]) -> Bool {
            guard (applied[AVVideoCodecKey] as? String) == preferred.rawValue else { return false }
            if videoCompression != .high {
                guard let compression = applied[AVVideoCompressionPropertiesKey] as? [String: Any],
                      let bitrate = compression[AVVideoAverageBitRateKey] as? NSNumber else { return false }
                if abs(bitrate.doubleValue - expectedBitrate) > max(expectedBitrate * 0.20, 1_000_000) {
                    return false
                }
            }
            return true
        }

        // Do not clear/reapply output settings on an unchanged ready pipeline. This avoids extra
        // encoder/connection churn at Record and Stop.
        let requestedSignature = videoCompression == .high
            ? "\(preferred.rawValue)|high"
            : "\(preferred.rawValue)|\(videoCompression.rawValue)|\(Int(expectedBitrate))"
        var applied = movieOutput.outputSettings(for: connection)
        if lastAppliedMovieSettingsSignature != requestedSignature || !settingsMatch(applied) {
            movieOutput.setOutputSettings(nil, for: connection)
            movieOutput.setOutputSettings(requestedSettings, for: connection)
            applied = movieOutput.outputSettings(for: connection)
        }

        guard settingsMatch(applied) else { return false }
        lastAppliedMovieSettingsSignature = requestedSignature
        if connection.isVideoMirroringSupported, connection.isVideoMirrored != shouldMirror { return false }
        if connection.isVideoStabilizationSupported {
            let expected: AVCaptureVideoStabilizationMode = shouldStabilize ? .auto : .off
            if connection.preferredVideoStabilizationMode != expected { return false }
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

        // Only wait for AF/AE when the sensor/input/format actually changed recently. Pressing
        // Record on an unchanged native 4K60/HFR pipeline starts immediately instead of polling
        // for up to a second every time.
        let changedRecently = lastHardwareConfigurationChangeAt.map {
            Date().timeIntervalSince($0) < 0.45
        } ?? false
        startMovieOutputWhenReady(
            deadline: changedRecently ? Date().addingTimeInterval(0.70) : .distantPast,
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

        if let device = videoInput?.device {
            let devices = capabilityDevices(for: cameraPosition.avPosition)
            switch captureMode {
            case .video:
                let available = CameraFormatSelector.availableResolutions(devices: devices, codec: selectedVideoCodec)
                if !available.isEmpty {
                    let expected = validSelection(for: devices, availableResolutions: available)
                    if previewPipeline == .native && CameraFormatSelector.activeVideoFormatMatches(
                        device: device,
                        resolution: expected.resolution,
                        frameRate: expected.frameRate,
                        codec: selectedVideoCodec
                    ) {
                        let legal = legalZoomDevicesForCurrentMode()
                        let domain = CameraZoomController.displayedZoomDomain(for: legal.isEmpty ? [device] : legal)
                        publish {
                            self.minimumZoomFactor = domain.lowerBound
                            self.maximumZoomFactor = domain.upperBound
                        }
                        return
                    }
                }

            case .sloMo:
                let resolutions = CameraFormatSelector.slowMotionResolutions(devices: devices, codec: selectedVideoCodec)
                if !resolutions.isEmpty {
                    let resolution = resolutions.contains(selectedSlowMotionResolution)
                        ? selectedSlowMotionResolution
                        : (resolutions.contains(.p1080) ? .p1080 : resolutions[0])
                    let rates = CameraFormatSelector.slowMotionFrameRates(devices: devices, resolution: resolution, codec: selectedVideoCodec)
                    if !rates.isEmpty {
                        let rate = rates.contains(selectedSlowMotionFrameRate) ? selectedSlowMotionFrameRate : (rates.last ?? .fps120)
                        if cameraPosition == .back,
                           previewPipeline == .native && CameraFormatSelector.activeSlowMotionFormatMatches(
                            device: device,
                            resolution: resolution,
                            frameRate: rate,
                            codec: selectedVideoCodec
                        ) {
                            let legal = legalZoomDevicesForCurrentMode()
                            let domain = CameraZoomController.displayedZoomDomain(for: legal.isEmpty ? [device] : legal)
                            publish {
                                self.minimumZoomFactor = domain.lowerBound
                                self.maximumZoomFactor = domain.upperBound
                            }
                            return
                        }
                    }
                }

            case .photo:
                break
            }
        }
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
