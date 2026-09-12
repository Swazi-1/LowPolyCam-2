import AVFoundation
import Combine
import Foundation
import Photos
import UIKit

// CameraManager keeps shared observable/session state in one place. Behavior is split by
// responsibility across CameraManager+*.swift so camera features can evolve independently
// without turning this file back into an 8,000-line dependency hub. Members used by those
// extensions are module-internal; the app UI still interacts with the same CameraManager API.
final class CameraManager: NSObject, ObservableObject {
    enum CaptureMode: String, CaseIterable, Identifiable {
        case video = "VIDEO"
        case photo = "PHOTO"
        case sloMo = "SLO-MO"

        var id: String { rawValue }
    }

    enum PhotoFlashMode: String, CaseIterable, Identifiable {
        case off = "Off"
        case auto = "Auto"
        case on = "On"

        var id: String { rawValue }

        var avMode: AVCaptureDevice.FlashMode {
            switch self {
            case .off: return .off
            case .auto: return .auto
            case .on: return .on
            }
        }

        var accessibilityLabel: String { "Photo Flash \(rawValue)" }
    }

    static let photoMegapixelPresets = [12, 8, 4, 2, 1]
    static let photoBurstCountOptions = [15, 10, 5]
    static let defaultPhotoBurstCount = 10

    enum SlowMotionFrameRate: Int, CaseIterable, Identifiable {
        case fps120 = 120
        case fps240 = 240

        var id: Int { rawValue }
        var label: String { "\(rawValue) fps" }
    }

    enum CameraPosition: String {
        case back
        case front

        var avPosition: AVCaptureDevice.Position {
            self == .back ? .back : .front
        }
    }

    struct SlowMotionQualityRequest {
        let id: UInt64
        let resolution: VideoResolution
        let frameRate: SlowMotionFrameRate
        let position: CameraPosition
        let codec: String
    }

    struct PendingVideoConfiguration {
        let id: UInt64
        let qualityRequestID: UInt64
        let compressionRequestID: UInt64
        let resolution: VideoResolution
        let frameRate: VideoFrameRate
        let slowMotionResolution: VideoResolution
        let slowMotionFrameRate: SlowMotionFrameRate
        let codec: String
        let compression: VideoCompression
        let compressionMode: CompressionMode
        let manualBitrateMbps: Double
        let position: CameraPosition
        let mode: CaptureMode
        let configurationGenerationID: UInt64
        let whiteBalanceRequestID: UInt64
        let preferVirtualCamera: Bool
        let formatAffecting: Bool
        let transitionID: UInt64?
    }

    struct HighOutputReadbackSignature: Equatable {
        let codec: String
        let compressionPropertiesPresent: Bool
        let averageBitrate: Double?
    }

    final class VerifiedHighOutputProvenance {
        weak var videoInput: AVCaptureDeviceInput?
        weak var movieConnection: AVCaptureConnection?
        weak var activeFormat: AVCaptureDevice.Format?
        let epoch: UInt64
        let deviceUniqueID: String
        let mode: String
        let isBackCamera: Bool
        let resolution: String
        let frameRate: Double
        let codec: String
        let dimensions: CMVideoDimensions
        let minFrameDuration: CMTime
        let maxFrameDuration: CMTime
        let mirroringSupported: Bool
        let mirrored: Bool
        let stabilizationSupported: Bool
        let stabilizationModeRawValue: Int
        let readback: HighOutputReadbackSignature

        init(
            videoInput: AVCaptureDeviceInput,
            movieConnection: AVCaptureConnection,
            activeFormat: AVCaptureDevice.Format,
            epoch: UInt64,
            deviceUniqueID: String,
            mode: String,
            isBackCamera: Bool,
            resolution: String,
            frameRate: Double,
            codec: String,
            dimensions: CMVideoDimensions,
            minFrameDuration: CMTime,
            maxFrameDuration: CMTime,
            mirroringSupported: Bool,
            mirrored: Bool,
            stabilizationSupported: Bool,
            stabilizationModeRawValue: Int,
            readback: HighOutputReadbackSignature
        ) {
            self.videoInput = videoInput
            self.movieConnection = movieConnection
            self.activeFormat = activeFormat
            self.epoch = epoch
            self.deviceUniqueID = deviceUniqueID
            self.mode = mode
            self.isBackCamera = isBackCamera
            self.resolution = resolution
            self.frameRate = frameRate
            self.codec = codec
            self.dimensions = dimensions
            self.minFrameDuration = minFrameDuration
            self.maxFrameDuration = maxFrameDuration
            self.mirroringSupported = mirroringSupported
            self.mirrored = mirrored
            self.stabilizationSupported = stabilizationSupported
            self.stabilizationModeRawValue = stabilizationModeRawValue
            self.readback = readback
        }
    }

    struct OutputConfigurationRequestSnapshot {
        let qualityRequestID: UInt64
        let compressionRequestID: UInt64
        let captureConfigurationGenerationID: UInt64
        let videoConfigurationRequestID: UInt64
        let cameraSwitchRequestID: UInt64
        let modeChangeRequestID: UInt64
        let whiteBalanceRequestID: UInt64
    }

    struct CodecSupportKey: Equatable {
        let isBackCamera: Bool
        let resolution: String
        let frameRate: Int
        let deviceIDs: [String]
        let generation: UInt64
    }

    struct CodecSupportSnapshot {
        let key: CodecSupportKey
        let hevcSupported: Bool
        let h264Supported: Bool

        func supports(_ codec: String) -> Bool {
            switch codec {
            case "HEVC": return hevcSupported
            case "H264": return h264Supported
            default: return false
            }
        }
    }

    enum WhiteBalancePreset: String, CaseIterable, Identifiable {
        case auto = "Auto"
        case daylight = "Daylight"
        case cloudy = "Cloudy"
        case tungsten = "Tungsten"
        case fluorescent = "Fluorescent"
        case custom = "Custom"

        var id: String { rawValue }

        var temperature: Float? {
            switch self {
            case .auto: return nil
            case .daylight: return 5_500
            case .cloudy: return 6_500
            case .tungsten: return 3_200
            case .fluorescent: return 4_200
            case .custom: return nil
            }
        }

        var tint: Float {
            switch self {
            case .fluorescent: return 8
            case .custom: return 0
            default: return 0
            }
        }
    }

    @Published var isSessionRunning = false
    @Published var isRecording = false
    @Published var isRecordingStarting = false
    @Published var isFinalizingRecording = false
    @Published var recordingPauseState: RecordingPauseState = .idle
    @Published var isCapturingPhoto = false
    @Published var captureMode: CaptureMode = .video
    @Published var isFocusExposureLocked = false
    @Published var focusExposureLockLabel = "AE/AF • FOCUS + EXPOSURE"
    @Published var exposureBias: Float = 0
    @Published var whiteBalancePreset: WhiteBalancePreset = .auto
    @Published var isPreviewTransitioning = false
    @Published var isLensTransitioning = false
    @Published var availableStorageBytes: Int64 = 0
    @Published var currentPhotoResolutionLabel = "12 MP"
    @Published var currentPhotoPixelCount: Int64 = 12_000_000
    @Published var selectedPhotoMegapixels = 12
    @Published var supportedPhotoMegapixels = CameraManager.photoMegapixelPresets
    @Published var supportedResolutions: [VideoResolution] = []
    @Published var supportedFrameRates: [VideoFrameRate] = []
    @Published var isVideoAvailabilityKnown = false
    @Published var isVideoAvailable = true
    @Published var supportedSlowMotionResolutions: [VideoResolution] = []
    @Published var supportedSlowMotionFrameRates: [SlowMotionFrameRate] = []
    @Published var isSlowMotionAvailabilityKnown = false
    @Published var isSlowMotionAvailable = true
    @Published var cameraPosition: CameraPosition = .back
    @Published var activeLensLabel = "Lens —"
    @Published var torchAvailable = false
    @Published var isTorchOn = false
    @Published var photoFlashAvailable = false
    @Published var minimumZoomFactor: CGFloat = 1
    @Published var maximumZoomFactor: CGFloat = 1
    @Published var zoomFactor: CGFloat = 1
    @Published var zoomLabel = "1×"
    @Published var statusMessage: String?
    @Published var statusMessageID: UInt64 = 0
    @Published var lastFrameGaps: Int?
    @Published var codecAvailabilityMessage: String?
    @Published var recoverableRecordingCount = 0
    @Published var recoverablePhotoCount = 0
    @Published var recoverableRecordingFiles: [URL] = []
    @Published var recoverablePhotoFiles: [URL] = []
    @Published var audioStatusLabel = "Checking microphone"
    @Published var audioMeterSnapshot = AudioLevelMeterSnapshot.unavailable
    @Published var audioLevelMeterMode: AudioLevelMeterMode = .bars
    @Published var captureOrientation: CaptureOrientationPreference = .auto
    @Published var customWhiteBalanceTemperature = WhiteBalancePreferencePolicy.defaultTemperature
    @Published var customWhiteBalanceTint = 0.0
    @Published var torchBrightnessLevel = TorchLevelPolicy.defaultNormalizedLevel
    @Published var torchBrightnessSupported = false
    @Published var videoCompressionMode: CompressionMode = .auto
    @Published var videoManualBitrateMbps = ManualBitratePolicy.defaultMbps
    @Published var slowMotionCompression = VideoCompression.high
    @Published var slowMotionCompressionMode: CompressionMode = .auto
    @Published var slowMotionManualBitrateMbps = ManualBitratePolicy.defaultMbps
    @Published var zoomShortcutValues = ZoomShortcutPolicy.defaultValues
    @Published var capabilitySnapshot = CameraCapabilitySnapshot.empty
    @Published var isCapabilitySnapshotLoading = false
    @Published var selectedVideoCodec = UserDefaults.standard.string(forKey: "selectedVideoCodec") ?? "HEVC" {
        didSet {
            guard selectedVideoCodec != oldValue else { return }
            invalidateCodecSupportCache()
            let qualityRequestID = qualityRequests.next()
            codecAvailabilityMessage = nil
            isVideoAvailabilityKnown = false
            isVideoAvailable = true
            UserDefaults.standard.set(selectedVideoCodec, forKey: "selectedVideoCodec")
            scheduleCapabilitySnapshotRefresh(reason: "codec changed")
            guard captureMode == .video, !suppressAutomaticReconfiguration else { return }
            scheduleVideoConfiguration(
                formatAffecting: true,
                qualityRequestID: qualityRequestID,
                compressionRequestID: compressionRequests.current()
            )
        }
    }
    @Published var photoFlashMode = PhotoFlashMode(rawValue: UserDefaults.standard.string(forKey: "photoFlashMode") ?? "") ?? .auto {
        didSet {
            guard photoFlashMode != oldValue else { return }
            UserDefaults.standard.set(photoFlashMode.rawValue, forKey: "photoFlashMode")
            AppEventLog.event("Photo flash preference changed: \(oldValue.rawValue) -> \(photoFlashMode.rawValue)")
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
            let compressionRequestID = compressionRequests.next()
            UserDefaults.standard.set(videoCompression.rawValue, forKey: "videoCompression")
            guard captureMode == .video, !suppressAutomaticReconfiguration else { return }
            scheduleVideoConfiguration(
                formatAffecting: false,
                qualityRequestID: qualityRequests.current(),
                compressionRequestID: compressionRequestID
            )
        }
    }

    @Published var selectedResolution: VideoResolution {
        didSet {
            if selectedResolution != oldValue {
                invalidateCodecSupportCache()
                _ = captureConfigurationGeneration.next()
                if !suppressPreferencePersistence {
                    persistCameraPreference(Self.resolutionKey, value: selectedResolution.rawValue)
                }
                scheduleCapabilitySnapshotRefresh(reason: "video resolution changed")
            }
        }
    }
    @Published var selectedFrameRate: VideoFrameRate {
        didSet {
            if selectedFrameRate != oldValue {
                invalidateCodecSupportCache()
                _ = captureConfigurationGeneration.next()
                if !suppressPreferencePersistence {
                    persistCameraPreference(Self.frameRateKey, value: selectedFrameRate.rawValue)
                }
                scheduleCapabilitySnapshotRefresh(reason: "video frame rate changed")
            }
        }
    }
    @Published var selectedSlowMotionResolution: VideoResolution {
        didSet {
            if selectedSlowMotionResolution != oldValue {
                _ = captureConfigurationGeneration.next()
                if !suppressPreferencePersistence {
                    persistCameraPreference(Self.slowMotionResolutionKey, value: selectedSlowMotionResolution.rawValue)
                }
                scheduleCapabilitySnapshotRefresh(reason: "slow motion resolution changed")
            }
        }
    }
    @Published var selectedSlowMotionFrameRate: SlowMotionFrameRate {
        didSet {
            if selectedSlowMotionFrameRate != oldValue {
                _ = captureConfigurationGeneration.next()
                if !suppressPreferencePersistence {
                    persistCameraPreference(Self.slowMotionFrameRateKey, value: selectedSlowMotionFrameRate.rawValue)
                }
                scheduleCapabilitySnapshotRefresh(reason: "slow motion frame rate changed")
            }
        }
    }
    @Published var isVideoStabilizationEnabled: Bool {
        didSet { UserDefaults.standard.set(isVideoStabilizationEnabled, forKey: Self.videoStabilizationKey) }
    }

    let session = AVCaptureSession()
    let sessionQueue = DispatchQueue(label: "com.swazi.lowpolycam.camera")
    let storageQueue = DispatchQueue(label: "com.swazi.lowpolycam.storage", qos: .utility)
    let storageGuard = StorageGuard()
    let movieOutput = AVCaptureMovieFileOutput()
    // Owned only on sessionQueue. The epoch is separate from desired-request and recording-state
    // generations so a normal Record transition cannot invalidate settled hardware proof.
    var highOutputProvenanceEpoch: UInt64 = 0
    var verifiedHighOutputProvenance: VerifiedHighOutputProvenance?
    let photoOutput = AVCapturePhotoOutput()
    let liveMetrics = LiveCaptureMetrics()
    let audioMeter = AudioLevelMeter()
    let liveStats = LiveRecordingStatsState()
    let recordingClock = RecordingClockState()
    @Published var liveMetricsAvailable = false
    var metricsTimer: DispatchSourceTimer?
    var previousMetricBytes: Int64 = 0
    var previousMetricDuration: Double = 0
    // Deep recording-forensics state; sessionQueue only.
    var activeRecordingTraceID: String?
    var recordingRequestStartedAt: TimeInterval = 0
    var movieStartCallAt: TimeInterval = 0
    var recordingSegmentIndex: Int = 0
    var activeRecordingSessionID: String?
    var lastExtremeRecordingHealthSecond: Int = -1
    struct PhotoCaptureContext {
        let aspect: String
        let megapixels: Int
        let filename: String
        let isBurst: Bool
        let requestedFlash: String
        let appliedFlash: String
        let traceID: String
        let startedAt: TimeInterval
        let burstOrdinal: Int?
    }

    var burstRemaining = 0
    var burstRequestedCount = 0
    var activeBurstTraceID: String?
    var burstStopRequested = false
    var burstAspect = "4:3"
    var burstMegapixels = 12
    var nativePhotoDimensions = CMVideoDimensions(width: 0, height: 0)
    var preferredPhotoMegapixels = 12
    var photoCaptureContexts: [Int64: PhotoCaptureContext] = [:]
    var activePhotoCaptureID: Int64?
    var activePhotoCaptureIsBurst = false
    var pendingPhotoSaves = 0
    var inFlightPhotoFileSaves: Set<URL> = []

    var videoInput: AVCaptureDeviceInput?
    var audioInput: AVCaptureDeviceInput?
    var requestedZoom: CGFloat = 1
    var requestedExposureBias: Float = 0
    var requestedWhiteBalancePreset: WhiteBalancePreset = .auto
    struct DeferredWhiteBalanceRequest {
        let id: UInt64
        let preset: WhiteBalancePreset
        let previousPreset: WhiteBalancePreset
    }
    // Accessed only on sessionQueue. WB changes must wait for an interrupted/stopped
    // AVCaptureSession instead of trying to swap inputs while the video device is unavailable.
    var deferredWhiteBalanceRequest: DeferredWhiteBalanceRequest?
    var pendingFocusLockWorkItem: DispatchWorkItem?
    var pendingFocusReturnWorkItem: DispatchWorkItem?
    // sessionQueue-owned hardware state. Do not use @Published lock state for queue decisions.
    var focusLockedInHardware = false
    var exposureLockedInHardware = false
    struct ZoomSubmission {
        let factor: CGFloat
        let requestID: UInt64
    }
    let zoomSubmissionLock = NSLock()
    var pendingZoomSubmission: ZoomSubmission?
    var isZoomSubmissionScheduled = false
    let torchBrightnessSubmissionLock = NSLock()
    var pendingTorchBrightness: Double?
    var isTorchBrightnessSubmissionScheduled = false
    var torchBrightnessInteractionActive = false
    var torchBrightnessCoalescedCount = 0
    let customWhiteBalanceSubmissionLock = NSLock()
    var customWhiteBalanceSubmissionQueue = CustomWhiteBalanceSubmissionQueue()
    var isCustomWhiteBalanceSubmissionScheduled = false
    var customWhiteBalanceInteractionActive = false
    var customWhiteBalanceCoalescedCount = 0
    var didLogRecordingLensClamp = false
    // Extreme diagnostics zoom interaction state; owned by sessionQueue.
    var diagnosticZoomInteractionTraceID: String?
    var diagnosticZoomProbeStarted = false
    let zoomRequests = RequestToken("zoomRequests")
    let cameraSwitchRequests = RequestToken("cameraSwitchRequests")
    let whiteBalanceRequests = RequestToken("whiteBalanceRequests")
    let modeChangeRequests = RequestToken("modeChangeRequests")
    let qualityRequests = RequestToken("qualityRequests")
    let compressionRequests = RequestToken("compressionRequests")
    let captureConfigurationGeneration = RequestToken("captureConfigurationGeneration")
    let videoConfigurationRequests = RequestToken("videoConfigurationRequests")
    let qualityPreviewTransitions = RequestToken("qualityPreviewTransitions")
    let exposureRequests = RequestToken("exposureRequests")
    let focusExposureRequests = RequestToken("focusExposureRequests")
    let torchRequests = RequestToken("torchRequests")
    let recordingStartRequests = RequestToken("recordingStartRequests")
    let recordingPauseRequests = RequestToken("recordingPauseRequests")
    let microphonePermissionRequests = RequestToken("microphonePermissionRequests")
    let mediaSaveTaskRequests = RequestToken("mediaSaveTaskRequests")
    let capabilityRequests = RequestToken("capabilityRequests")
    let codecSupportCacheLock = NSLock()
    var codecSupportCacheGeneration: UInt64 = 0
    var codecSupportSnapshot: CodecSupportSnapshot?
    var audioMeterCancellable: AnyCancellable?

    var activeVideoCodec: String {
        captureMode == .sloMo ? "HEVC" : selectedVideoCodec
    }

    var formatSelector: CameraFormatSelector {
        CameraFormatSelector(
            selectedVideoCodec: activeVideoCodec,
            selectedResolution: selectedResolution,
            selectedFrameRate: selectedFrameRate
        )
    }
    lazy var lensTransitionCoordinator = LensTransitionCoordinator(
        sessionQueue: self.sessionQueue,
        zoomRequests: self.zoomRequests,
        onTransitioningChanged: { [weak self] transitioning in
            guard let self else { return }
            self.publish { self.isLensTransitioning = transitioning }
        }
    )
    enum RecordingState: Equatable {
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

        var isIdle: Bool {
            if case .idle = self { return true }
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

    var recordingState: RecordingState = .idle
    var recordingPauseMachine = RecordingPauseMachine()
    struct RecordingPauseRequest {
        enum Operation {
            case pause
            case resume
        }

        let id: UInt64
        let operation: Operation
        let stateBefore: RecordingPauseState
        let traceID: String?
        let requestedAt: TimeInterval
    }
    var pendingRecordingPauseRequest: RecordingPauseRequest?
    var segmentTimer: DispatchWorkItem?
    var segmentTimerGeneration: UInt64 = 0
    var pendingVideoSaves = 0
    var inFlightVideoSaves: Set<URL> = []
    var backgroundSaveTask: UIBackgroundTaskIdentifier = .invalid
    var awaitingMicrophonePermission = false
    // iOS can deliver an inactive/active lifecycle bounce around the system microphone
    // permission sheet. Keep that transient bounce from cancelling the very recording
    // request that caused the permission prompt. Backgrounding is never suppressed.
    var microphonePermissionPromptLifecyclePending = false
    var storageProtectionStopIssued = false
    var storageWarningEpisodeActive = false
    var activeCriticalStorageReserveBytes = StorageGuard.minimumCriticalReserveBytes
    var rotationCoordinator: AVCaptureDevice.RotationCoordinator?
    var sessionObserverTokens: [NSObjectProtocol] = []
    var suppressPreferencePersistence = false
    var suppressAutomaticReconfiguration = false
    // These are accessed only on sessionQueue. Property observers enqueue immutable snapshots.
    var pendingVideoConfiguration: PendingVideoConfiguration?
    var pendingVideoConfigurationWorkItem: DispatchWorkItem?
    var slowMotionAvailabilityKey: String?

    enum AppLifecyclePhase: String {
        case active
        case inactive
        case background
    }

    var appLifecyclePhase: AppLifecyclePhase = .active

    static let resolutionKey = LowPolyCamPreferences.Key.selectedVideoResolution
    static let frameRateKey = LowPolyCamPreferences.Key.selectedVideoFrameRate
    static let slowMotionResolutionKey = LowPolyCamPreferences.Key.selectedSlowMotionResolution
    static let slowMotionFrameRateKey = LowPolyCamPreferences.Key.selectedSlowMotionFrameRate
    static let videoStabilizationKey = LowPolyCamPreferences.Key.videoStabilizationEnabled
    static let photoMegapixelsKey = LowPolyCamPreferences.Key.selectedPhotoMegapixels
    static let mediaSequenceKey = LowPolyCamPreferences.Key.mediaSequence

    override init() {
        let defaults = UserDefaults.standard
        let rememberCameraSetup = defaults.bool(forKey: "rememberCaptureMode")
        let restoredPosition: CameraPosition
        if rememberCameraSetup,
           let savedPosition = defaults.string(forKey: "lastCameraPosition"),
           let position = CameraPosition(rawValue: savedPosition) {
            restoredPosition = position
        } else {
            restoredPosition = .back
        }
        cameraPosition = restoredPosition

        let positionSuffix = restoredPosition == .front ? ".front" : ""
        let savedResolution = defaults.string(forKey: Self.resolutionKey + positionSuffix)
        selectedResolution = VideoResolution(rawValue: savedResolution ?? "") ?? .p1080
        let savedFrameRate = defaults.integer(forKey: Self.frameRateKey + positionSuffix)
        selectedFrameRate = VideoFrameRate(rawValue: savedFrameRate) ?? .fps60
        let savedSlowMotionResolution = defaults.string(forKey: Self.slowMotionResolutionKey + positionSuffix)
        selectedSlowMotionResolution = VideoResolution(rawValue: savedSlowMotionResolution ?? "") ?? .p1080
        let savedSlowMotionFrameRate = defaults.integer(forKey: Self.slowMotionFrameRateKey + positionSuffix)
        selectedSlowMotionFrameRate = SlowMotionFrameRate(rawValue: savedSlowMotionFrameRate) ?? (restoredPosition == .front ? .fps120 : .fps240)
        isVideoStabilizationEnabled = defaults.object(forKey: Self.videoStabilizationKey) as? Bool ?? true
        super.init()

        videoCompressionMode = CompressionMode(
            rawValue: defaults.string(forKey: LowPolyCamPreferences.Key.videoCompressionMode) ?? ""
        ) ?? .auto
        videoManualBitrateMbps = ManualBitratePolicy.validatedMbps(
            (defaults.object(forKey: LowPolyCamPreferences.Key.videoManualBitrateMbps) as? NSNumber)?.doubleValue
                ?? ManualBitratePolicy.defaultMbps
        )
        slowMotionCompression = VideoCompression(
            rawValue: defaults.string(forKey: LowPolyCamPreferences.Key.slowMotionCompressionLevel) ?? ""
        ) ?? .high
        slowMotionCompressionMode = CompressionMode(
            rawValue: defaults.string(forKey: LowPolyCamPreferences.Key.slowMotionCompressionMode) ?? ""
        ) ?? .auto
        slowMotionManualBitrateMbps = ManualBitratePolicy.validatedMbps(
            (defaults.object(forKey: LowPolyCamPreferences.Key.slowMotionManualBitrateMbps) as? NSNumber)?.doubleValue
                ?? ManualBitratePolicy.defaultMbps
        )
        captureOrientation = CaptureOrientationPreference(
            rawValue: defaults.string(forKey: LowPolyCamPreferences.Key.captureOrientation) ?? ""
        ) ?? .auto
        customWhiteBalanceTemperature = WhiteBalancePreferencePolicy.validatedTemperature(
            (defaults.object(forKey: LowPolyCamPreferences.Key.customWhiteBalanceTemperature) as? NSNumber)?.doubleValue
                ?? WhiteBalancePreferencePolicy.defaultTemperature
        )
        customWhiteBalanceTint = WhiteBalancePreferencePolicy.validatedTint(
            (defaults.object(forKey: LowPolyCamPreferences.Key.customWhiteBalanceTint) as? NSNumber)?.doubleValue
                ?? 0
        )
        let storedTorchBrightness = (defaults.object(forKey: LowPolyCamPreferences.Key.torchBrightness) as? NSNumber)?.doubleValue ?? TorchLevelPolicy.defaultNormalizedLevel
        torchBrightnessLevel = TorchLevelPolicy.validatedNormalized(storedTorchBrightness)
        requestedWhiteBalancePreset = WhiteBalancePreset(
            rawValue: defaults.string(forKey: LowPolyCamPreferences.Key.whiteBalancePreset) ?? ""
        ) ?? .auto
        whiteBalancePreset = requestedWhiteBalancePreset
        audioLevelMeterMode = AudioLevelMeterMode(
            rawValue: defaults.string(forKey: LowPolyCamPreferences.Key.audioLevelMeter) ?? ""
        ) ?? .bars
        zoomShortcutValues = Self.loadZoomShortcutValues(from: defaults)
        audioMeterCancellable = audioMeter.$snapshot
            .receive(on: DispatchQueue.main)
            .sink { [weak self] snapshot in self?.audioMeterSnapshot = snapshot }

        let savedPhotoMegapixels = defaults.integer(forKey: Self.photoMegapixelsKey)
        preferredPhotoMegapixels = Self.normalizedPhotoMegapixels(savedPhotoMegapixels)
        defaults.set(preferredPhotoMegapixels, forKey: Self.photoMegapixelsKey)
        selectedPhotoMegapixels = preferredPhotoMegapixels
        currentPhotoResolutionLabel = "\(selectedPhotoMegapixels) MP"
        currentPhotoPixelCount = Int64(selectedPhotoMegapixels) * 1_000_000

        if rememberCameraSetup,
           let saved = defaults.string(forKey: "lastCaptureMode"),
           let mode = CaptureMode(rawValue: saved) {
            captureMode = mode
        }

        installSessionObservers()
        if captureMode == .video {
            _ = autoPromoteH264ForUnsupportedVideoSelection(
                position: cameraPosition,
                resolution: selectedResolution,
                frameRate: selectedFrameRate
            )
        }
        AppEventLog.event(
            "CAMERA SETUP INITIALIZED: remember=\(rememberCameraSetup), mode=\(captureMode.rawValue), position=\(cameraPosition.rawValue)"
        )
        refreshRecoveryCount()
    }

    deinit {
        sessionObserverTokens.forEach(NotificationCenter.default.removeObserver)
        storageGuard.stopMonitoring()
        if backgroundSaveTask != .invalid {
            let task = backgroundSaveTask
            DispatchQueue.main.async { UIApplication.shared.endBackgroundTask(task) }
        }
    }

}
