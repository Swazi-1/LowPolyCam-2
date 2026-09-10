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

    private struct SlowMotionQualityRequest {
        let id: UInt64
        let resolution: VideoResolution
        let frameRate: SlowMotionFrameRate
        let position: CameraPosition
        let codec: String
    }

    private struct PendingVideoConfiguration {
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

    private struct HighOutputReadbackSignature: Equatable {
        let codec: String
        let compressionPropertiesPresent: Bool
        let averageBitrate: Double?
    }

    private final class VerifiedHighOutputProvenance {
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

    private struct OutputConfigurationRequestSnapshot {
        let qualityRequestID: UInt64
        let compressionRequestID: UInt64
        let captureConfigurationGenerationID: UInt64
        let videoConfigurationRequestID: UInt64
        let cameraSwitchRequestID: UInt64
        let modeChangeRequestID: UInt64
        let whiteBalanceRequestID: UInt64
    }

    private struct CodecSupportKey: Equatable {
        let isBackCamera: Bool
        let resolution: String
        let frameRate: Int
        let deviceIDs: [String]
        let generation: UInt64
    }

    private struct CodecSupportSnapshot {
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

    @Published private(set) var isSessionRunning = false
    @Published private(set) var isRecording = false
    @Published private(set) var isRecordingStarting = false
    @Published private(set) var isFinalizingRecording = false
    @Published private(set) var recordingPauseState: RecordingPauseState = .idle
    @Published private(set) var isCapturingPhoto = false
    @Published private(set) var captureMode: CaptureMode = .video
    @Published private(set) var isFocusExposureLocked = false
    @Published private(set) var focusExposureLockLabel = "AE/AF LOCK"
    @Published private(set) var exposureBias: Float = 0
    @Published private(set) var whiteBalancePreset: WhiteBalancePreset = .auto
    @Published private(set) var isPreviewTransitioning = false
    @Published private(set) var isLensTransitioning = false
    @Published private(set) var availableStorageBytes: Int64 = 0
    @Published private(set) var currentPhotoResolutionLabel = "12 MP"
    @Published private(set) var currentPhotoPixelCount: Int64 = 12_000_000
    @Published private(set) var selectedPhotoMegapixels = 12
    @Published private(set) var supportedPhotoMegapixels = CameraManager.photoMegapixelPresets
    @Published private(set) var supportedResolutions: [VideoResolution] = []
    @Published private(set) var supportedFrameRates: [VideoFrameRate] = []
    @Published private(set) var isVideoAvailabilityKnown = false
    @Published private(set) var isVideoAvailable = true
    @Published private(set) var supportedSlowMotionResolutions: [VideoResolution] = []
    @Published private(set) var supportedSlowMotionFrameRates: [SlowMotionFrameRate] = []
    @Published private(set) var isSlowMotionAvailabilityKnown = false
    @Published private(set) var isSlowMotionAvailable = true
    @Published private(set) var cameraPosition: CameraPosition = .back
    @Published private(set) var torchAvailable = false
    @Published private(set) var isTorchOn = false
    @Published private(set) var photoFlashAvailable = false
    @Published private(set) var minimumZoomFactor: CGFloat = 1
    @Published private(set) var maximumZoomFactor: CGFloat = 1
    @Published private(set) var zoomFactor: CGFloat = 1
    @Published private(set) var zoomLabel = "1×"
    @Published private(set) var statusMessage: String?
    @Published private(set) var statusMessageID: UInt64 = 0
    @Published private(set) var lastFrameGaps: Int?
    @Published private(set) var codecAvailabilityMessage: String?
    @Published private(set) var recoverableRecordingCount = 0
    @Published private(set) var recoverablePhotoCount = 0
    @Published private(set) var recoverableRecordingFiles: [URL] = []
    @Published private(set) var recoverablePhotoFiles: [URL] = []
    @Published private(set) var audioStatusLabel = "Checking microphone"
    @Published private(set) var audioMeterSnapshot = AudioLevelMeterSnapshot.unavailable
    @Published private(set) var audioLevelMeterMode: AudioLevelMeterMode = .bars
    @Published private(set) var isZebraExposureWarningEnabled = false
    @Published private(set) var isZebraAvailableForCurrentConfiguration = false
    @Published private(set) var zebraExposureMask = ZebraMask.empty
    @Published private(set) var captureOrientation: CaptureOrientationPreference = .auto
    @Published private(set) var customWhiteBalanceTemperature = WhiteBalancePreferencePolicy.defaultTemperature
    @Published private(set) var customWhiteBalanceTint = 0.0
    @Published private(set) var torchBrightnessLevel = 0.35
    @Published private(set) var torchBrightnessSupported = false
    @Published private(set) var videoCompressionMode: CompressionMode = .auto
    @Published private(set) var videoManualBitrateMbps = ManualBitratePolicy.defaultMbps
    @Published private(set) var slowMotionCompression = VideoCompression.high
    @Published private(set) var slowMotionCompressionMode: CompressionMode = .auto
    @Published private(set) var slowMotionManualBitrateMbps = ManualBitratePolicy.defaultMbps
    @Published private(set) var zoomShortcutValues = ZoomShortcutPolicy.defaultValues
    @Published private(set) var capabilitySnapshot = CameraCapabilitySnapshot.empty
    @Published private(set) var isCapabilitySnapshotLoading = false
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
    private let sessionQueue = DispatchQueue(label: "com.swazi.lowpolycam.camera")
    private let storageQueue = DispatchQueue(label: "com.swazi.lowpolycam.storage", qos: .utility)
    private let storageGuard = StorageGuard()
    private let movieOutput = AVCaptureMovieFileOutput()
    // Owned only on sessionQueue. The epoch is separate from desired-request and recording-state
    // generations so a normal Record transition cannot invalidate settled hardware proof.
    private var highOutputProvenanceEpoch: UInt64 = 0
    private var verifiedHighOutputProvenance: VerifiedHighOutputProvenance?
    private let photoOutput = AVCapturePhotoOutput()
    private let liveMetrics = LiveCaptureMetrics()
    let audioMeter = AudioLevelMeter()
    let zebraExposureState = ZebraExposureState()
    private var zebraAnalysisActive = false
    private var zebraAvailabilityKnown = false
    private var zebraAvailableForCurrentConfiguration = false
    let liveStats = LiveRecordingStatsState()
    let recordingClock = RecordingClockState()
    @Published private(set) var liveMetricsAvailable = false
    private var metricsTimer: DispatchSourceTimer?
    private var previousMetricBytes: Int64 = 0
    private var previousMetricDuration: Double = 0
    // Deep recording-forensics state; sessionQueue only.
    private var activeRecordingTraceID: String?
    private var recordingRequestStartedAt: TimeInterval = 0
    private var movieStartCallAt: TimeInterval = 0
    private var recordingSegmentIndex: Int = 0
    private var activeRecordingSessionID: String?
    private var lastExtremeRecordingHealthSecond: Int = -1
    private struct PhotoCaptureContext {
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

    private var burstRemaining = 0
    private var burstRequestedCount = 0
    private var activeBurstTraceID: String?
    private var burstStopRequested = false
    private var burstAspect = "4:3"
    private var burstMegapixels = 12
    private var nativePhotoDimensions = CMVideoDimensions(width: 0, height: 0)
    private var preferredPhotoMegapixels = 12
    private var photoCaptureContexts: [Int64: PhotoCaptureContext] = [:]
    private var activePhotoCaptureID: Int64?
    private var activePhotoCaptureIsBurst = false
    private var pendingPhotoSaves = 0
    private var inFlightPhotoFileSaves: Set<URL> = []

    private var videoInput: AVCaptureDeviceInput?
    private var audioInput: AVCaptureDeviceInput?
    private var requestedZoom: CGFloat = 1
    private var requestedExposureBias: Float = 0
    private var requestedWhiteBalancePreset: WhiteBalancePreset = .auto
    private struct DeferredWhiteBalanceRequest {
        let id: UInt64
        let preset: WhiteBalancePreset
        let previousPreset: WhiteBalancePreset
    }
    // Accessed only on sessionQueue. WB changes must wait for an interrupted/stopped
    // AVCaptureSession instead of trying to swap inputs while the video device is unavailable.
    private var deferredWhiteBalanceRequest: DeferredWhiteBalanceRequest?
    private var pendingFocusLockWorkItem: DispatchWorkItem?
    private var pendingFocusReturnWorkItem: DispatchWorkItem?
    // sessionQueue-owned hardware state. Do not use @Published lock state for queue decisions.
    private var focusLockedInHardware = false
    private var exposureLockedInHardware = false
    private struct ZoomSubmission {
        let factor: CGFloat
        let requestID: UInt64
    }
    private let zoomSubmissionLock = NSLock()
    private var pendingZoomSubmission: ZoomSubmission?
    private var isZoomSubmissionScheduled = false
    private var didLogRecordingLensClamp = false
    // Extreme diagnostics zoom interaction state; owned by sessionQueue.
    private var diagnosticZoomInteractionTraceID: String?
    private var diagnosticZoomProbeStarted = false
    private let zoomRequests = RequestToken("zoomRequests")
    private let cameraSwitchRequests = RequestToken("cameraSwitchRequests")
    private let whiteBalanceRequests = RequestToken("whiteBalanceRequests")
    private let modeChangeRequests = RequestToken("modeChangeRequests")
    private let qualityRequests = RequestToken("qualityRequests")
    private let compressionRequests = RequestToken("compressionRequests")
    private let captureConfigurationGeneration = RequestToken("captureConfigurationGeneration")
    private let videoConfigurationRequests = RequestToken("videoConfigurationRequests")
    private let qualityPreviewTransitions = RequestToken("qualityPreviewTransitions")
    private let exposureRequests = RequestToken("exposureRequests")
    private let focusExposureRequests = RequestToken("focusExposureRequests")
    private let torchRequests = RequestToken("torchRequests")
    private let recordingStartRequests = RequestToken("recordingStartRequests")
    private let recordingPauseRequests = RequestToken("recordingPauseRequests")
    private let microphonePermissionRequests = RequestToken("microphonePermissionRequests")
    private let mediaSaveTaskRequests = RequestToken("mediaSaveTaskRequests")
    private let capabilityRequests = RequestToken("capabilityRequests")
    private let codecSupportCacheLock = NSLock()
    private var codecSupportCacheGeneration: UInt64 = 0
    private var codecSupportSnapshot: CodecSupportSnapshot?
    private var audioMeterCancellable: AnyCancellable?
    private var zebraMaskCancellable: AnyCancellable?

    private var activeVideoCodec: String {
        captureMode == .sloMo ? "HEVC" : selectedVideoCodec
    }

    private var formatSelector: CameraFormatSelector {
        CameraFormatSelector(
            selectedVideoCodec: activeVideoCodec,
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
    private enum RecordingState: Equatable {
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

    private var recordingState: RecordingState = .idle
    private var recordingPauseMachine = RecordingPauseMachine()
    private struct RecordingPauseRequest {
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
    private var pendingRecordingPauseRequest: RecordingPauseRequest?
    private var segmentTimer: DispatchWorkItem?
    private var segmentTimerGeneration: UInt64 = 0
    private var pendingVideoSaves = 0
    private var inFlightVideoSaves: Set<URL> = []
    private var backgroundSaveTask: UIBackgroundTaskIdentifier = .invalid
    private var awaitingMicrophonePermission = false
    // iOS can deliver an inactive/active lifecycle bounce around the system microphone
    // permission sheet. Keep that transient bounce from cancelling the very recording
    // request that caused the permission prompt. Backgrounding is never suppressed.
    private var microphonePermissionPromptLifecyclePending = false
    private var storageProtectionStopIssued = false
    private var storageWarningEpisodeActive = false
    private var activeCriticalStorageReserveBytes = StorageGuard.minimumCriticalReserveBytes
    private var rotationCoordinator: AVCaptureDevice.RotationCoordinator?
    private var sessionObserverTokens: [NSObjectProtocol] = []
    private var suppressPreferencePersistence = false
    private var suppressAutomaticReconfiguration = false
    // These are accessed only on sessionQueue. Property observers enqueue immutable snapshots.
    private var pendingVideoConfiguration: PendingVideoConfiguration?
    private var pendingVideoConfigurationWorkItem: DispatchWorkItem?
    private var slowMotionAvailabilityKey: String?

    private enum AppLifecyclePhase: String {
        case active
        case inactive
        case background
    }

    private var appLifecyclePhase: AppLifecyclePhase = .active

    private static let resolutionKey = LowPolyCamPreferences.Key.selectedVideoResolution
    private static let frameRateKey = LowPolyCamPreferences.Key.selectedVideoFrameRate
    private static let slowMotionResolutionKey = LowPolyCamPreferences.Key.selectedSlowMotionResolution
    private static let slowMotionFrameRateKey = LowPolyCamPreferences.Key.selectedSlowMotionFrameRate
    private static let videoStabilizationKey = LowPolyCamPreferences.Key.videoStabilizationEnabled
    private static let photoMegapixelsKey = LowPolyCamPreferences.Key.selectedPhotoMegapixels
    private static let mediaSequenceKey = LowPolyCamPreferences.Key.mediaSequence

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
        let storedTorchBrightness = (defaults.object(forKey: LowPolyCamPreferences.Key.torchBrightness) as? NSNumber)?.doubleValue ?? 0.35
        torchBrightnessLevel = min(max(storedTorchBrightness, 0.05), 1.0)
        requestedWhiteBalancePreset = WhiteBalancePreset(
            rawValue: defaults.string(forKey: LowPolyCamPreferences.Key.whiteBalancePreset) ?? ""
        ) ?? .auto
        whiteBalancePreset = requestedWhiteBalancePreset
        audioLevelMeterMode = AudioLevelMeterMode(
            rawValue: defaults.string(forKey: LowPolyCamPreferences.Key.audioLevelMeter) ?? ""
        ) ?? .bars
        isZebraExposureWarningEnabled = defaults.bool(forKey: LowPolyCamPreferences.Key.zebraExposureWarning)
        zoomShortcutValues = Self.loadZoomShortcutValues(from: defaults)
        audioMeterCancellable = audioMeter.$snapshot
            .receive(on: DispatchQueue.main)
            .sink { [weak self] snapshot in self?.audioMeterSnapshot = snapshot }
        zebraMaskCancellable = zebraExposureState.$mask
            .receive(on: DispatchQueue.main)
            .sink { [weak self] mask in self?.zebraExposureMask = mask }

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

    func isVideoResolutionSupported(_ resolution: VideoResolution) -> Bool {
        supportedResolutions.contains(resolution)
    }

    func isVideoFrameRateSupported(_ frameRate: VideoFrameRate) -> Bool {
        if isKnownUnsupportedH264VideoSelection(
            codec: selectedVideoCodec,
            resolution: selectedResolution,
            frameRate: frameRate
        ) {
            return false
        }
        guard supportedFrameRates.contains(frameRate) else { return false }
        if codecAvailabilityMessage != nil,
           selectedVideoCodec == "H264",
           selectedFrameRate == frameRate {
            return false
        }
        return true
    }

    func isVideoCodecSupported(_ codec: String) -> Bool {
        guard codec == "HEVC" || codec == "H264" else { return false }
        if isKnownUnsupportedH264VideoSelection(
            codec: codec,
            resolution: selectedResolution,
            frameRate: selectedFrameRate
        ) {
            return false
        }
        if codec == selectedVideoCodec {
            return codecAvailabilityMessage == nil &&
                (!isVideoAvailabilityKnown ||
                (isVideoResolutionSupported(selectedResolution) &&
                        isVideoFrameRateSupported(selectedFrameRate)))
        }

        let devices = capabilityDevices(for: cameraPosition.avPosition)
        let cacheKey: CodecSupportKey
        let cachedSnapshot: CodecSupportSnapshot?
        codecSupportCacheLock.lock()
        let generation = codecSupportCacheGeneration
        cacheKey = CodecSupportKey(
            isBackCamera: cameraPosition == .back,
            resolution: selectedResolution.rawValue,
            frameRate: selectedFrameRate.rawValue,
            deviceIDs: devices.map(\.uniqueID),
            generation: generation
        )
        cachedSnapshot = codecSupportSnapshot?.key == cacheKey ? codecSupportSnapshot : nil
        codecSupportCacheLock.unlock()

        if let cachedSnapshot {
            return cachedSnapshot.supports(codec)
        }

        let hevcSelector = CameraFormatSelector(
            selectedVideoCodec: "HEVC",
            selectedResolution: selectedResolution,
            selectedFrameRate: selectedFrameRate
        )
        let h264Selector = CameraFormatSelector(
            selectedVideoCodec: "H264",
            selectedResolution: selectedResolution,
            selectedFrameRate: selectedFrameRate
        )
        var hevcSupported = false
        var h264Supported = false
        for device in devices {
            for format in device.formats {
                if !hevcSupported,
                   hevcSelector.format(format, supports: selectedResolution, at: selectedFrameRate),
                   hevcSelector.formatSupportsSelectedCodec(format) {
                    hevcSupported = true
                }
                if !h264Supported,
                   h264Selector.format(format, supports: selectedResolution, at: selectedFrameRate),
                   h264Selector.formatSupportsSelectedCodec(format) {
                    h264Supported = true
                }
                if hevcSupported && h264Supported {
                    break
                }
            }
            if hevcSupported && h264Supported { break }
        }

        let snapshot = CodecSupportSnapshot(
            key: cacheKey,
            hevcSupported: hevcSupported,
            h264Supported: h264Supported
        )
        codecSupportCacheLock.lock()
        if codecSupportCacheGeneration == generation {
            codecSupportSnapshot = snapshot
        }
        codecSupportCacheLock.unlock()
        return snapshot.supports(codec)
    }

    private func invalidateCodecSupportCache() {
        codecSupportCacheLock.lock()
        codecSupportCacheGeneration &+= 1
        codecSupportSnapshot = nil
        codecSupportCacheLock.unlock()
    }

    /// Refreshes the Settings-facing capability answer away from SwiftUI body evaluation. The
    /// existing synchronous helpers remain available for guarded user actions and hardware
    /// configuration, but the UI reads this published snapshot so format scans do not repeat on
    /// every render.
    private func scheduleCapabilitySnapshotRefresh(reason: String) {
        let requestID = capabilityRequests.next(reason: reason)
        publish {
            self.isCapabilitySnapshotLoading = true
        }
        sessionQueue.async { [weak self] in
            guard let self, self.capabilityRequests.isLatest(requestID) else { return }
            let snapshot = self.makeCapabilitySnapshot()
            guard self.capabilityRequests.isLatest(requestID) else { return }
            self.publish {
                guard self.capabilityRequests.isLatest(requestID) else { return }
                self.capabilitySnapshot = snapshot
                self.isCapabilitySnapshotLoading = false
            }
        }
    }

    private func makeCapabilitySnapshot() -> CameraCapabilitySnapshot {
        let devices = capabilityDevices(for: cameraPosition.avPosition)
        let resolutions: [VideoResolution] = [.p720, .p1080, .p4k]
        let position = cameraPosition.rawValue

        let videoPairs = resolutions.flatMap { resolution in
            VideoFrameRate.allCases.compactMap { frameRate -> CameraVideoFormatPair? in
                let effectiveCodec = isKnownUnsupportedH264VideoSelection(
                    codec: selectedVideoCodec,
                    resolution: resolution,
                    frameRate: frameRate
                ) ? "HEVC" : selectedVideoCodec
                let selector = CameraFormatSelector(
                    selectedVideoCodec: effectiveCodec,
                    selectedResolution: resolution,
                    selectedFrameRate: frameRate
                )
                let supported = devices.contains { device in
                    selector.preferredRecordingFormat(for: device, resolution: resolution, rate: frameRate) != nil
                }
                return supported ? CameraVideoFormatPair(resolution: resolution, frameRate: frameRate) : nil
            }
        }

        let slowMotionSelector = CameraFormatSelector(
            selectedVideoCodec: "HEVC",
            selectedResolution: selectedResolution,
            selectedFrameRate: selectedFrameRate
        )
        let slowMotionPairs = resolutions.flatMap { resolution in
            SlowMotionFrameRate.allCases.compactMap { frameRate -> CameraSlowMotionFormatPair? in
                let supported = devices.contains { device in
                    device.formats.contains {
                        slowMotionSelector.supportsSlowMotion($0, resolution: resolution, frameRate: frameRate)
                    }
                }
                return supported
                    ? CameraSlowMotionFormatPair(resolution: resolution, frameRate: frameRate)
                    : nil
            }
        }

        let availableCodecs = ["HEVC", "H264"].filter { codec in
            guard !isKnownUnsupportedH264VideoSelection(
                codec: codec,
                resolution: selectedResolution,
                frameRate: selectedFrameRate
            ) else { return false }
            let selector = CameraFormatSelector(
                selectedVideoCodec: codec,
                selectedResolution: selectedResolution,
                selectedFrameRate: selectedFrameRate
            )
            return devices.contains { device in
                selector.preferredRecordingFormat(
                    for: device,
                    resolution: selectedResolution,
                    rate: selectedFrameRate
                ) != nil
            }
        }

        return CameraCapabilitySnapshot(
            position: position,
            deviceIDs: devices.map(\.uniqueID),
            videoPairs: videoPairs,
            slowMotionPairs: slowMotionPairs,
            availableVideoCodecs: availableCodecs,
            photoMegapixelOptions: supportedPhotoMegapixels,
            isReady: !devices.isEmpty
        )
    }

    static func normalizedVideoCodec(
        _ codec: String,
        resolution: VideoResolution,
        frameRate: VideoFrameRate
    ) -> String {
        // AVCaptureMovieFileOutput on the supported iPhone 11 paths exposes HEVC, not AVC, for
        // 4K60. Treat this as a state invariant, not merely a Settings/UI restriction: camera
        // preferences can be restored while Photo/Slo-Mo is active and then carried into Video.
        if codec == "H264", resolution == .p4k, frameRate == .fps60 {
            return "HEVC"
        }
        return codec
    }

    private func isKnownUnsupportedH264VideoSelection(
        codec: String,
        resolution: VideoResolution,
        frameRate: VideoFrameRate
    ) -> Bool {
        Self.normalizedVideoCodec(codec, resolution: resolution, frameRate: frameRate) != codec
    }

    /// Keeps the requested 4K60 quality when AVC cannot encode the selection. This deliberately
    /// does NOT depend on the currently visible capture mode: per-camera Video preferences may be
    /// loaded while Photo/Slo-Mo is active, and the codec must already be valid before a later
    /// transition into Video schedules its hardware transaction.
    @discardableResult
    private func autoPromoteH264ForUnsupportedVideoSelection(
        position: CameraPosition,
        resolution: VideoResolution,
        frameRate: VideoFrameRate
    ) -> Bool {
        let normalizedCodec = Self.normalizedVideoCodec(
            selectedVideoCodec,
            resolution: resolution,
            frameRate: frameRate
        )
        guard normalizedCodec != selectedVideoCodec,
              position == cameraPosition else { return false }

        let previousCodec = selectedVideoCodec
        let wasSuppressing = suppressAutomaticReconfiguration
        suppressAutomaticReconfiguration = true
        selectedVideoCodec = normalizedCodec
        suppressAutomaticReconfiguration = wasSuppressing
        codecAvailabilityMessage = nil
        AppEventLog.event(
            "Video codec promoted automatically: \(previousCodec) -> \(normalizedCodec) for \(position == .back ? "rear" : "front") \(resolution.rawValue)\(frameRate.rawValue)"
        )
        return true
    }

    func isSlowMotionResolutionSupported(_ resolution: VideoResolution) -> Bool {
        supportedSlowMotionResolutions.contains(resolution)
    }

    func isSlowMotionFrameRateSupported(_ frameRate: SlowMotionFrameRate) -> Bool {
        supportedSlowMotionFrameRates.contains(frameRate)
    }

    func isCaptureModeSupported(_ mode: CaptureMode) -> Bool {
        switch mode {
        case .photo:
            return true
        case .video:
            return !isVideoAvailabilityKnown || isVideoAvailable
        case .sloMo:
            return !isSlowMotionAvailabilityKnown || isSlowMotionAvailable
        }
    }

    private func publishVideoAvailability(_ available: Bool) {
        publish {
            if self.isVideoAvailabilityKnown != true {
                self.isVideoAvailabilityKnown = true
            }
            if self.isVideoAvailable != available {
                self.isVideoAvailable = available
            }
        }
    }

    private func publishSlowMotionAvailability(_ available: Bool) {
        publish {
            if self.isSlowMotionAvailabilityKnown != true {
                self.isSlowMotionAvailabilityKnown = true
            }
            if self.isSlowMotionAvailable != available {
                self.isSlowMotionAvailable = available
            }
        }
    }

    private func updateSlowMotionAvailability(
        for devices: [AVCaptureDevice],
        selector: CameraFormatSelector? = nil,
        position: CameraPosition? = nil,
        codec: String? = nil,
        validation: (() -> Bool)? = nil
    ) {
        let targetPosition = position ?? cameraPosition
        let targetCodec = codec ?? activeVideoCodec
        let targetSelector = selector ?? formatSelector
        let key = [
            targetPosition == .back ? "back" : "front",
            targetCodec,
            devices.map(\.uniqueID).joined(separator: ",")
        ].joined(separator: "|")
        guard slowMotionAvailabilityKey != key else { return }
        let available = !targetSelector.slowMotionResolutions(for: devices).isEmpty
        if let validation, !validation() { return }
        slowMotionAvailabilityKey = key
        publishSlowMotionAvailability(available)
    }

    private func transitionRecordingState(
        to newState: RecordingState,
        resetClock: Bool = false,
        startClock: Bool = false,
        clearLastFrameGaps: Bool = false
    ) {
        let previousState = recordingState
        let previousFlags = recordingState.uiFlags
        let resetPauseState = newState.isIdle
        if resetPauseState {
            let hadPauseActivity = pendingRecordingPauseRequest != nil || recordingPauseMachine.state != .idle
            pendingRecordingPauseRequest = nil
            if hadPauseActivity {
                _ = recordingPauseRequests.next(reason: "recording state returned to idle")
            }
            recordingPauseMachine.reset()
        }
        recordingState = newState
        if newState.isIdle {
            storageGuard.stopMonitoring()
            cancelSplitTimer()
        }
        if previousState != newState {
            invalidatePendingVideoConfiguration()
            _ = qualityRequests.next()
            _ = captureConfigurationGeneration.next()
            AppEventLog.event("Recording state: \(String(describing: previousState)) -> \(String(describing: newState))")
        }
        let flags = newState.uiFlags
        let flagsChanged = previousFlags.starting != flags.starting ||
            previousFlags.recording != flags.recording ||
            previousFlags.finalizing != flags.finalizing
        guard flagsChanged || resetClock || startClock || clearLastFrameGaps || resetPauseState else { return }

        publish {
            if resetClock {
                self.recordingClock.stopAndReset()
            } else if startClock {
                self.recordingClock.startIfNeeded()
            }
            self.isRecordingStarting = flags.starting
            self.isRecording = flags.recording
            self.isFinalizingRecording = flags.finalizing
            if resetPauseState {
                self.recordingPauseState = .idle
            }
            if clearLastFrameGaps {
                self.lastFrameGaps = nil
            }
        }
    }

    private func scheduleVideoConfiguration(
        formatAffecting: Bool,
        qualityRequestID: UInt64,
        compressionRequestID: UInt64,
        transitionID: UInt64? = nil
    ) {
        let request = PendingVideoConfiguration(
            id: videoConfigurationRequests.next(),
            qualityRequestID: qualityRequestID,
            compressionRequestID: compressionRequestID,
            resolution: selectedResolution,
            frameRate: selectedFrameRate,
            slowMotionResolution: selectedSlowMotionResolution,
            slowMotionFrameRate: selectedSlowMotionFrameRate,
            codec: selectedVideoCodec,
            compression: videoCompression,
            compressionMode: videoCompressionMode,
            manualBitrateMbps: videoManualBitrateMbps,
            position: cameraPosition,
            mode: captureMode,
            configurationGenerationID: captureConfigurationGeneration.current(),
            whiteBalanceRequestID: whiteBalanceRequests.current(),
            preferVirtualCamera: !requiresPhysicalWhiteBalanceInput,
            formatAffecting: formatAffecting,
            transitionID: transitionID
        )
        AppEventLog.event(
            "VIDEO CONFIG REQUEST SCHEDULED: reason=\(formatAffecting ? "format" : "output"), " +
            "resolution=\(request.resolution.rawValue), fps=\(request.frameRate.rawValue), " +
            "codec=\(request.codec), compression=\(request.compression.rawValue)"
        )

        sessionQueue.async { [weak self] in
            guard let self else { return }
            if let pending = self.pendingVideoConfiguration {
                self.pendingVideoConfiguration = PendingVideoConfiguration(
                    id: request.id,
                    qualityRequestID: request.qualityRequestID,
                    compressionRequestID: request.compressionRequestID,
                    resolution: request.resolution,
                    frameRate: request.frameRate,
                    slowMotionResolution: request.slowMotionResolution,
                    slowMotionFrameRate: request.slowMotionFrameRate,
                    codec: request.codec,
                    compression: request.compression,
                    compressionMode: request.compressionMode,
                    manualBitrateMbps: request.manualBitrateMbps,
                    position: request.position,
                    mode: request.mode,
                    configurationGenerationID: request.configurationGenerationID,
                    whiteBalanceRequestID: request.whiteBalanceRequestID,
                    preferVirtualCamera: request.preferVirtualCamera,
                    formatAffecting: pending.formatAffecting || request.formatAffecting,
                    transitionID: request.transitionID ?? pending.transitionID
                )
                AppEventLog.event(
                    "VIDEO CONFIG REQUEST COALESCED: previous=\(pending.id), latest=\(request.id), " +
                    "formatAffecting=\(pending.formatAffecting || request.formatAffecting)"
                )
            } else {
                self.pendingVideoConfiguration = request
            }

            guard self.pendingVideoConfigurationWorkItem == nil else { return }
            let workItem = DispatchWorkItem { [weak self] in
                self?.applyPendingVideoConfiguration()
            }
            self.pendingVideoConfigurationWorkItem = workItem
            self.sessionQueue.asyncAfter(deadline: .now() + 0.07, execute: workItem)
        }
    }

    /// Invalidates queued idle Video-setting work. This must run on sessionQueue so the pending
    /// request and its timer cannot race an input/mode/recording transition.
    private func invalidatePendingVideoConfiguration() {
        _ = videoConfigurationRequests.next()
        let pending = pendingVideoConfiguration
        pendingVideoConfiguration = nil
        pendingVideoConfigurationWorkItem?.cancel()
        pendingVideoConfigurationWorkItem = nil
        guard let pending else { return }
        if pending.transitionID != nil {
            _ = qualityPreviewTransitions.next()
            publish { self.isPreviewTransitioning = false }
        }
        AppEventLog.event("VIDEO CONFIG REQUEST DROPPED: invalidated by camera state transition")
    }

    private func isCurrentVideoConfiguration(_ request: PendingVideoConfiguration) -> Bool {
        videoConfigurationRequests.isLatest(request.id) &&
            qualityRequests.isLatest(request.qualityRequestID) &&
            compressionRequests.isLatest(request.compressionRequestID) &&
            captureConfigurationGeneration.isLatest(request.configurationGenerationID) &&
            whiteBalanceRequests.isLatest(request.whiteBalanceRequestID) &&
            selectedResolution == request.resolution &&
            selectedFrameRate == request.frameRate &&
            selectedVideoCodec == request.codec &&
            videoCompression == request.compression &&
            videoCompressionMode == request.compressionMode &&
            abs(videoManualBitrateMbps - request.manualBitrateMbps) < 0.000_001 &&
            cameraPosition == request.position &&
            captureMode == request.mode &&
            request.mode == .video &&
            appLifecyclePhase == .active &&
            !suppressAutomaticReconfiguration &&
            recordingState.isIdle &&
            !movieOutput.isRecording &&
            !session.isInterrupted &&
            session.isRunning
    }

    private func applyPendingVideoConfiguration() {
        let request = pendingVideoConfiguration
        pendingVideoConfiguration = nil
        pendingVideoConfigurationWorkItem = nil
        guard let request else { return }

        guard isCurrentVideoConfiguration(request) else {
            AppEventLog.event(
                "VIDEO CONFIG REQUEST DROPPED: stale or invalid state, " +
                "resolution=\(request.resolution.rawValue), fps=\(request.frameRate.rawValue), " +
                "codec=\(request.codec), compression=\(request.compression.rawValue)"
            )
            if let transitionID = request.transitionID {
                finishQualityPreviewTransition(transitionID)
            }
            return
        }

        let success: Bool
        if request.formatAffecting {
            lensTransitionCoordinator.cancel()
            switch request.mode {
            case .video:
                success = applySelectedFormat(
                    preferVirtualCamera: request.preferVirtualCamera,
                    requestedResolution: request.resolution,
                    requestedFrameRate: request.frameRate,
                    requestedCodec: request.codec,
                    requestedCompression: request.compression,
                    requestedCompressionMode: request.compressionMode,
                    requestedManualBitrateMbps: request.manualBitrateMbps,
                    qualityRequestID: request.qualityRequestID,
                    requestedPosition: request.position,
                    requestValidation: { self.isCurrentVideoConfiguration(request) }
                )
            case .sloMo:
                success = applySlowMotionFormat(
                    requestedResolution: request.slowMotionResolution,
                    requestedFrameRate: request.slowMotionFrameRate,
                    qualityRequestID: request.qualityRequestID,
                    requestedPosition: request.position
                )
            case .photo:
                success = applyBestPhotoFormat(preferVirtualCamera: request.preferVirtualCamera)
            }
        } else {
            success = configureMovieOutputSettings(
                requestedCodec: request.codec,
                requestedCompression: request.compression,
                requestedCompressionMode: request.compressionMode,
                requestedManualBitrateMbps: request.manualBitrateMbps,
                requestedResolution: request.resolution,
                requestedFrameRate: request.frameRate,
                requestedPosition: request.position,
                requestedMode: request.mode
            )
        }

        AppEventLog.event(
            "VIDEO CONFIG APPLY: formatApply=\(request.formatAffecting), " +
            "outputOnly=\(!request.formatAffecting), resolution=\(request.resolution.rawValue), " +
            "fps=\(request.frameRate.rawValue), codec=\(request.codec), " +
            "compression=\(request.compression.rawValue), success=\(success)"
        )
        if let transitionID = request.transitionID {
            finishQualityPreviewTransition(transitionID)
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

    private func persistCameraPreference(_ base: String, value: Any) {
        UserDefaults.standard.set(value, forKey: preferenceKey(base, for: cameraPosition))
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
        selectedFrameRate = VideoFrameRate(rawValue: fps) ?? .fps60
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
            center.addObserver(forName: AVCaptureSession.wasInterruptedNotification, object: session, queue: nil) { [weak self] note in
                self?.sessionQueue.async { self?.handleSessionInterrupted(note) }
            },
            center.addObserver(forName: AVCaptureSession.interruptionEndedNotification, object: session, queue: nil) { [weak self] _ in
                self?.sessionQueue.async { self?.handleSessionInterruptionEnded() }
            }
        ]
    }

    private func handleSessionRuntimeError(_ notification: Notification) {
        invalidateVerifiedHighOutputProvenance()
        invalidatePendingVideoConfiguration()
        storageGuard.stopMonitoring()
        _ = recordingStartRequests.next()
        _ = microphonePermissionRequests.next()
        awaitingMicrophonePermission = false
        microphonePermissionPromptLifecyclePending = false
        _ = qualityRequests.next()
        _ = captureConfigurationGeneration.next()
        stopLiveMetrics()
        let nsError = notification.userInfo?[AVCaptureSessionErrorKey] as? NSError
        AppEventLog.event(
            "SESSION RUNTIME ERROR: domain=\(nsError?.domain ?? "unknown"), code=\(nsError?.code ?? -1), " +
            "description=\(nsError?.localizedDescription ?? "unknown")"
        )
        if nsError?.code == AVError.Code.mediaServicesWereReset.rawValue {
            AppEventLog.event("Session recovery: media services reset; rebuilding camera session")
            rebuildSessionAfterMediaServicesReset()
        } else {
            AppEventLog.event("Session recovery: forcing camera session rebuild")
            showError("Camera session error. Trying to recover…")
            configureSessionIfNeeded(forceRebuild: true)
            if !session.isRunning { session.startRunning() }
            publish { self.isSessionRunning = self.session.isRunning }
        }
    }

    private func handleSessionInterrupted(_ notification: Notification) {
        invalidateVerifiedHighOutputProvenance()
        _ = torchRequests.next()
        storageGuard.stopMonitoring()
        _ = recordingStartRequests.next()
        _ = microphonePermissionRequests.next()
        awaitingMicrophonePermission = false
        microphonePermissionPromptLifecyclePending = false
        let reason = (notification.userInfo?[AVCaptureSessionInterruptionReasonKey] as? NSNumber)?.intValue ?? -1
        AppEventLog.event("SESSION INTERRUPTED: reason=\(reason), running=\(session.isRunning), recording=\(movieOutput.isRecording), requestedRecording=\(recordingState.requestsRecording)")
        invalidatePendingVideoConfiguration()
        _ = qualityRequests.next()
        _ = captureConfigurationGeneration.next()
        let currentWhiteBalanceRequestID = whiteBalanceRequests.current()
        if deferredWhiteBalanceRequest == nil ||
            !whiteBalanceRequests.isLatest(deferredWhiteBalanceRequest?.id ?? 0) {
            deferredWhiteBalanceRequest = DeferredWhiteBalanceRequest(
                id: currentWhiteBalanceRequestID,
                preset: requestedWhiteBalancePreset,
                previousPreset: requestedWhiteBalancePreset
            )
        }
        stopLiveMetrics()
        lensTransitionCoordinator.cancel()
        burstRemaining = 0
        burstStopRequested = true
        synchronizeTorchState()
        let sessionAvailable = session.isRunning && !session.isInterrupted
        publish {
            self.isSessionRunning = sessionAvailable
        }
        guard recordingState.requestsRecording || movieOutput.isRecording else { return }

        cancelSplitTimer()

        if movieOutput.isRecording {
            requestNativeRecordingStop(reason: "session interruption")
            transitionRecordingToFinalizing(resetClock: true)
            postStatus("Recording interrupted · saving…")
            movieOutput.stopRecording()
        } else {
            resetNativeRecordingPauseState(reason: "session interruption without active movie output")
            transitionRecordingToDiscard(resetClock: true)
        }
    }

    private func handleSessionInterruptionEnded() {
        AppEventLog.event("SESSION INTERRUPTION ENDED; restoring camera session")
        invalidatePendingVideoConfiguration()
        _ = qualityRequests.next()
        _ = captureConfigurationGeneration.next()
        configureSessionIfNeeded()
        if !session.isRunning { session.startRunning() }
        applyDeferredWhiteBalanceIfPossible()
        synchronizeTorchState()
        publish { self.isSessionRunning = self.session.isRunning }
        logSessionSnapshot("after interruption recovery")
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
        storageGuard.checkNow(criticalReserveBytes: criticalStorageReserveBytes) { [weak self] snapshot in
            guard let self, let snapshot else { return }
            self.sessionQueue.async {
                self.applyStorageSnapshot(snapshot, source: "refresh")
            }
        }
    }

    private var criticalStorageReserveBytes: Int64 {
        StorageGuard.criticalReserveBytes(forVideoBitrate: estimatedVideoBitsPerSecond)
    }

    /// Called on sessionQueue for both the idle HUD refresh and the active recording monitor.
    private func applyStorageSnapshot(_ snapshot: StorageSnapshot, source: String) {
        publish {
            if self.availableStorageBytes != snapshot.availableBytes {
                self.availableStorageBytes = snapshot.availableBytes
            }
        }

        if snapshot.availableBytes > StorageGuard.warningThresholdBytes {
            storageWarningEpisodeActive = false
        } else if snapshot.isWarning, !storageWarningEpisodeActive {
            storageWarningEpisodeActive = true
            if UserDefaults.standard.object(forKey: "lowStorageWarning") as? Bool ?? true {
                postStatus("Storage is below 1 GB. Long recordings may stop early.")
            }
            AppEventLog.event("Storage warning threshold crossed: available=\(snapshot.availableBytes), source=\(source)")
        }

        guard snapshot.isCritical,
              recordingState.requestsRecording || movieOutput.isRecording else { return }
        issueStorageProtectionStop(snapshot: snapshot, source: source)
    }

    private func issueStorageProtectionStop(snapshot: StorageSnapshot, source: String) {
        guard !storageProtectionStopIssued else { return }
        storageProtectionStopIssued = true
        _ = recordingStartRequests.next()
        _ = microphonePermissionRequests.next()
        awaitingMicrophonePermission = false
        microphonePermissionPromptLifecyclePending = false
        cancelSplitTimer()
        storageGuard.stopMonitoring()
        AppEventLog.event(
            "STORAGE CRITICAL: available=\(snapshot.availableBytes), reserve=\(activeCriticalStorageReserveBytes), " +
            "bitrate=\(Int(estimatedVideoBitsPerSecond)), source=\(source), stopReason=low-storage protection"
        )

        if movieOutput.isRecording {
            requestNativeRecordingStop(reason: "critical storage protection")
            transitionRecordingToFinalizing(resetClock: true)
            postStatus("Recording stopped to protect the file because storage is critically low.")
            movieOutput.stopRecording()
        } else if recordingState.requestsRecording {
            resetNativeRecordingPauseState(reason: "critical storage before movie output start")
            transitionRecordingState(to: .idle, resetClock: true)
            restoreIdleCaptureConfigurationAfterRecording()
            postStatus("Not enough free storage to safely start recording.")
        }
    }

    private func rejectRecordingStartForStorage(snapshot: StorageSnapshot) {
        storageProtectionStopIssued = true
        _ = recordingStartRequests.next()
        storageGuard.stopMonitoring()
        AppEventLog.event(
            "Recording start rejected: critically low storage, available=\(snapshot.availableBytes), " +
            "reserve=\(activeCriticalStorageReserveBytes), bitrate=\(Int(estimatedVideoBitsPerSecond))"
        )
        transitionRecordingState(to: .idle, resetClock: true)
        restoreIdleCaptureConfigurationAfterRecording()
        showError("Not enough free storage to safely start recording.")
    }


    private var estimatedVideoBitsPerSecond: Double {
        let resolution = captureMode == .sloMo ? selectedSlowMotionResolution : selectedResolution
        let fps: Double = captureMode == .sloMo
            ? Double(selectedSlowMotionFrameRate.rawValue)
            : Double(selectedFrameRate.rawValue)
        let compression = compressionSelection(for: captureMode)
        return estimatedVideoBitsPerSecond(
            resolution: resolution,
            fps: fps,
            codec: activeVideoCodec,
            compression: compression.level,
            compressionMode: compression.mode,
            manualBitrateMbps: compression.manualBitrateMbps,
            isSlowMotion: captureMode == .sloMo
        )
    }

    private func estimatedVideoBitsPerSecond(
        resolution: VideoResolution,
        fps: Double,
        codec: String,
        compression: VideoCompression,
        compressionMode: CompressionMode = .auto,
        manualBitrateMbps: Double = ManualBitratePolicy.defaultMbps,
        isSlowMotion: Bool = false
    ) -> Double {
        if compressionMode == .manual {
            let effective = ManualBitratePolicy.effectiveMbps(
                requested: manualBitrateMbps,
                resolution: resolution,
                fps: fps,
                isSlowMotion: isSlowMotion,
                codec: codec
            )
            return max(ManualBitratePolicy.bitsPerSecond(forMbps: effective), 2_000_000)
        }
        let pixels = Double(resolution.dimensions.width) * Double(resolution.dimensions.height)
        let codecFactor = codec == "H264" ? 1.0 : 0.72
        return max(pixels * fps * compression.bitsPerPixel * codecFactor, 2_000_000)
    }

    private var estimatedBytesPerPhoto: Double {
        let pixels = max(Double(currentPhotoPixelCount), 1)
        let bytesPerPixel = photoFileFormat == "HEIC" ? 0.22 : 0.48
        return max(pixels * bytesPerPixel, photoFileFormat == "HEIC" ? 250_000 : 500_000)
    }

    func start() {
        sessionQueue.async { [weak self] in
            guard let self else { return }
            AppEventLog.event("Camera start requested")
            self.requestedZoom = 1
            self.configureSessionIfNeeded()
            self.scheduleCapabilitySnapshotRefresh(reason: "camera start")
            guard self.session.isRunning == false else {
                self.publish { self.isSessionRunning = true }
                self.applyDeferredWhiteBalanceIfPossible()
                return
            }
            self.session.startRunning()
            AppEventLog.event("Camera session running")
            try? AVAudioSession.sharedInstance().setAllowHapticsAndSystemSoundsDuringRecording(true)
            self.publish { self.isSessionRunning = true }
            self.applyDeferredWhiteBalanceIfPossible()
            self.configureAudioMeterOutput()
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
            AppEventLog.event("Camera stop requested")
            self.invalidateVerifiedHighOutputProvenance()
            _ = self.torchRequests.next()
            _ = self.recordingStartRequests.next()
            _ = self.microphonePermissionRequests.next()
            self.awaitingMicrophonePermission = false
            self.microphonePermissionPromptLifecyclePending = false
            self.storageGuard.stopMonitoring()
            self.invalidatePendingVideoConfiguration()
            _ = self.qualityRequests.next()
            _ = self.captureConfigurationGeneration.next()
            self.stopLiveMetrics()
            self.lensTransitionCoordinator.cancel()
            self.burstRemaining = 0
            self.burstStopRequested = true
            self.cancelSplitTimer()
            if self.movieOutput.isRecording {
                self.requestNativeRecordingStop(reason: "camera stop")
                self.transitionRecordingToFinalizing(resetClock: true)
                self.movieOutput.stopRecording()
            } else if self.recordingState.requestsRecording {
                self.requestNativeRecordingStop(reason: "camera stop without active movie output")
                self.transitionRecordingState(to: .idle, resetClock: true)
            }
            if self.session.isRunning {
                self.session.stopRunning()
                AppEventLog.event("Camera session stopped")
                self.publish { self.isSessionRunning = false }
            }
        }
    }

    func appDidBecomeInactive(isBackground: Bool = false) {
        AppEventLog.flush()
        let requestedPhase: AppLifecyclePhase = isBackground ? .background : .inactive
        sessionQueue.async { [weak self] in
            guard let self else { return }

            // The system microphone permission UI can emit a short .inactive transition even
            // after requestAccess has completed. Treat only that one permission-sheet bounce as
            // transient so a just-started first recording is not discarded. A real background
            // transition still performs the full cleanup below.
            if requestedPhase == .inactive && self.microphonePermissionPromptLifecyclePending {
                AppEventLog.event("App lifecycle inactive ignored during microphone permission prompt")
                return
            }
            if requestedPhase == .background {
                self.microphonePermissionPromptLifecyclePending = false
            }

            guard self.appLifecyclePhase != requestedPhase else {
                AppEventLog.event("App lifecycle ignored: \(requestedPhase.rawValue) already handled")
                return
            }
            let previousPhase = self.appLifecyclePhase
            self.appLifecyclePhase = requestedPhase
            AppEventLog.event("App lifecycle transition: \(previousPhase.rawValue) -> \(requestedPhase.rawValue)")
            self.invalidatePendingVideoConfiguration()
            _ = self.recordingStartRequests.next()
            _ = self.microphonePermissionRequests.next()
            self.awaitingMicrophonePermission = false
            self.microphonePermissionPromptLifecyclePending = false
            self.storageGuard.stopMonitoring()
            // ACTIVE -> INACTIVE/BACKGROUND owns the cleanup. INACTIVE -> BACKGROUND is a
            // distinct lifecycle transition, but has no additional camera work today.
            guard previousPhase == .active else { return }

            _ = self.qualityRequests.next()
            _ = self.captureConfigurationGeneration.next()
            self.invalidateVerifiedHighOutputProvenance()
            _ = self.torchRequests.next()
            self.stopLiveMetrics()
            self.lensTransitionCoordinator.cancel()
            self.burstRemaining = 0
            self.burstStopRequested = true
            self.cancelSplitTimer()

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
                self.requestNativeRecordingStop(reason: "app became inactive")
                self.transitionRecordingToFinalizing(resetClock: true)
                self.movieOutput.stopRecording()
            } else if self.recordingState.requestsRecording {
                self.resetNativeRecordingPauseState(reason: "app became inactive without active movie output")
                self.transitionRecordingState(to: .idle, resetClock: true)
            }

            self.publish {
                if self.isTorchOn { self.isTorchOn = false }
                if self.torchBrightnessSupported { self.torchBrightnessSupported = false }
            }
        }
    }

    func appDidBecomeActive() {
        sessionQueue.async { [weak self] in
            guard let self else { return }
            if self.microphonePermissionPromptLifecyclePending {
                self.microphonePermissionPromptLifecyclePending = false
                AppEventLog.event("Microphone permission lifecycle bounce completed")
            }
            guard self.appLifecyclePhase != .active else {
                AppEventLog.event("App lifecycle ignored: active already handled")
                return
            }
            let previousPhase = self.appLifecyclePhase
            self.appLifecyclePhase = .active
            AppEventLog.event("App lifecycle transition: \(previousPhase.rawValue) -> active")
            self.invalidatePendingVideoConfiguration()
            self.configureSessionIfNeeded()
            self.scheduleCapabilitySnapshotRefresh(reason: "app became active")
            if !self.session.isRunning {
                self.session.startRunning()
            }
            try? AVAudioSession.sharedInstance().setAllowHapticsAndSystemSoundsDuringRecording(true)
            self.publish { self.isSessionRunning = self.session.isRunning }
            self.applyDeferredWhiteBalanceIfPossible()
            self.synchronizeTorchState()
        }
    }

    func toggleTorch() {
        sessionQueue.async { [weak self] in
            guard let self else { return }
            guard self.captureMode != .photo else { return }
            _ = self.torchRequests.next()
            guard let device = self.videoInput?.device, device.hasTorch else { return }
            if device.torchMode != .on && !device.isTorchAvailable {
                self.synchronizeTorchState()
                self.showError("Torch is temporarily unavailable.")
                return
            }
            self.setTorchEnabledOnCurrentDevice(device.torchMode != .on, showErrorOnFailure: true)
        }
    }

    func cyclePhotoFlashMode() {
        guard captureMode == .photo, photoFlashAvailable else { return }
        sessionQueue.async { [weak self] in
            guard let self, self.captureMode == .photo, self.photoFlashAvailable else { return }
            let next: PhotoFlashMode
            switch self.photoFlashMode {
            case .off: next = .auto
            case .auto: next = .on
            case .on: next = .off
            }
            self.publish {
                guard self.captureMode == .photo else { return }
                self.photoFlashMode = next
            }
            AppEventLog.event("Photo flash mode selected: \(next.rawValue)")
        }
    }

    /// Applies the requested torch state to whichever camera input is currently active.
    /// Mode changes can replace the AVCaptureDevice even though the user did not touch Flash,
    /// so this is also used immediately after a successful mode reconfiguration.
    private func setTorchEnabledOnCurrentDevice(_ enabled: Bool, showErrorOnFailure: Bool = false) {
        guard let device = videoInput?.device, device.hasTorch else {
            publish {
                if self.torchAvailable { self.torchAvailable = false }
                if self.isTorchOn { self.isTorchOn = false }
                if self.torchBrightnessSupported { self.torchBrightnessSupported = false }
            }
            return
        }

        do {
            if enabled && !device.isTorchAvailable {
                publish {
                    if self.torchAvailable { self.torchAvailable = false }
                    if self.isTorchOn { self.isTorchOn = false }
                    if self.torchBrightnessSupported { self.torchBrightnessSupported = false }
                }
                if showErrorOnFailure { showError("Torch is temporarily unavailable.") }
                return
            }
            try device.lockForConfiguration()
            if enabled {
                let maximumTorchLevel = max(device.maxAvailableTorchLevel, 0.05)
                let requestedTorchLevel = min(
                    max(Float(torchBrightnessLevel) * maximumTorchLevel, min(0.05, maximumTorchLevel)),
                    maximumTorchLevel
                )
                do {
                    try device.setTorchModeOn(level: requestedTorchLevel)
                } catch {
                    // Some compatible torch implementations expose only on/off. Preserve the
                    // normal tap behavior while recording the level fallback for diagnostics.
                    device.torchMode = .on
                    AppEventLog.event("Torch brightness level unavailable; fell back to full on",
                                      category: .torch, fields: ["requestedLevel": String(format: "%.3f", torchBrightnessLevel)])
                }
            } else {
                device.torchMode = .off
            }
            let actualState = device.torchMode == .on
            let actualTorchLevel = device.torchLevel
            let torchAvailable = device.isTorchAvailable
            device.unlockForConfiguration()
            publish {
                if self.torchAvailable != torchAvailable {
                    self.torchAvailable = torchAvailable
                }
                if self.isTorchOn != actualState {
                    self.isTorchOn = actualState
                }
                let supportsIntensity = device.hasTorch && device.maxAvailableTorchLevel > 0
                if self.torchBrightnessSupported != supportsIntensity {
                    self.torchBrightnessSupported = supportsIntensity
                }
            }
            AppEventLog.event("Torch applied: \(actualState ? "on" : "off") on \(device.localizedName)")
            AppEventLog.event("TORCH BRIGHTNESS APPLIED", category: .torch, fields: [
                "requestedLevel": String(format: "%.3f", torchBrightnessLevel),
                "actualLevel": String(format: "%.3f", actualTorchLevel),
                "maxAvailableLevel": String(format: "%.3f", device.maxAvailableTorchLevel),
                "device": device.localizedName
            ])
        } catch {
            synchronizeTorchState()
            if showErrorOnFailure { showError("Couldn’t change the torch.") }
        }
    }

    func setZoomFactor(_ requestedFactor: CGFloat) {
        let requestID = zoomRequests.next(reason: "zoom factor requested")
        let requestTraceID = "ZOOM-\(requestID)"
        AppEventLog.deepEvent("ZOOM REQUEST SUBMITTED", category: .zoom, traceID: requestTraceID, fields: [
            "requestedDisplayedZoom": String(format: "%.3f", Double(requestedFactor)),
            "publishedZoom": String(format: "%.3f", Double(zoomFactor)),
            "hudZoom": zoomLabel
        ])
        // A 60 Hz drag can outpace an expensive 4K60 lens handoff. Retain only the newest value
        // instead of leaving obsolete device/format scans queued behind the current camera work.
        zoomSubmissionLock.lock()
        pendingZoomSubmission = ZoomSubmission(factor: requestedFactor, requestID: requestID)
        let shouldSchedule = !isZoomSubmissionScheduled
        if shouldSchedule { isZoomSubmissionScheduled = true }
        zoomSubmissionLock.unlock()

        guard shouldSchedule else {
            AppEventLog.deepEvent("ZOOM REQUEST COALESCED", category: .zoom, traceID: requestTraceID)
            return
        }
        let ticket = AppEventLog.queueScheduled("drainZoomSubmissions", category: .zoom, traceID: requestTraceID)
        sessionQueue.async { [weak self] in
            AppEventLog.queueStarted(ticket)
            self?.drainZoomSubmissions()
        }
    }

    func beginZoomInteraction() {
        let trace = AppEventLog.extremeDiagnosticsEnabled ? AppEventLog.makeTraceID("ZOOM-INTERACTION") : nil
        sessionQueue.async { [weak self] in
            guard let self else { return }
            self.didLogRecordingLensClamp = false
            if let previousTrace = self.diagnosticZoomInteractionTraceID,
               self.diagnosticZoomProbeStarted {
                self.liveMetrics.endZoomTransitionProbe(traceID: previousTrace, reason: "zoom interaction superseded")
            }
            self.diagnosticZoomInteractionTraceID = trace
            self.diagnosticZoomProbeStarted = false
            AppEventLog.deepEvent("ZOOM GESTURE BEGIN", category: .zoom, traceID: trace, fields: [
                "requestedZoom": String(format: "%.3f", Double(self.requestedZoom)),
                "hudZoom": self.zoomLabel,
                "device": self.videoInput?.device.localizedName ?? "none"
            ])
        }
    }

    func endZoomInteraction() {
        sessionQueue.async { [weak self] in
            guard let self else { return }
            let trace = self.diagnosticZoomInteractionTraceID
            AppEventLog.deepEvent("ZOOM GESTURE END", category: .zoom, traceID: trace, fields: [
                "requestedZoom": String(format: "%.3f", Double(self.requestedZoom)),
                "hudZoom": self.zoomLabel,
                "deviceZoom": self.videoInput.map { String(format: "%.3f", Double($0.device.videoZoomFactor)) } ?? "none"
            ])
            if let trace {
                self.sessionQueue.asyncAfter(deadline: .now() + 1.0) { [weak self] in
                    guard let self, self.diagnosticZoomInteractionTraceID == trace else { return }
                    self.liveMetrics.endZoomTransitionProbe(traceID: trace, reason: "zoom interaction settled")
                    self.diagnosticZoomInteractionTraceID = nil
                    self.diagnosticZoomProbeStarted = false
                }
            }
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
            let requestTraceID = "ZOOM-\(requestID)"
            let startedAt = ProcessInfo.processInfo.systemUptime
            guard zoomRequests.isLatest(requestID) else { return }
            guard let currentDevice = videoInput?.device else {
                AppEventLog.guardRejected("applyZoomSubmission", reason: "no active video input", traceID: requestTraceID)
                return
            }
            guard session.isRunning else {
                AppEventLog.guardRejected("applyZoomSubmission", reason: "session not running", traceID: requestTraceID)
                return
            }
            guard !session.isInterrupted else {
                AppEventLog.guardRejected("applyZoomSubmission", reason: "session interrupted", traceID: requestTraceID)
                return
            }
            AppEventLog.deepEvent("ZOOM APPLY BEGIN", category: .zoom, traceID: requestTraceID, fields: [
                "requested": String(format: "%.3f", Double(submission.factor)),
                "currentRequested": String(format: "%.3f", Double(requestedZoom)),
                "device": currentDevice.localizedName,
                "actualDeviceZoom": String(format: "%.3f", Double(currentDevice.videoZoomFactor)),
                "lensTransitionActive": String(lensTransitionCoordinator.hasActiveTransition)
            ])

            var requested = min(max(submission.factor, minimumZoomFactor), maximumZoomFactor)
            if !lensTransitionCoordinator.hasActiveTransition,
               abs(requested - requestedZoom) < 0.0005 {
                AppEventLog.deepEvent("ZOOM APPLY NO-OP", category: .zoom, traceID: requestTraceID,
                                      fields: ["reason": "already at requested zoom"])
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
                    self.beginExtremeZoomTransitionProbeIfPossible(
                        device: currentDevice,
                        targetDisplayedZoom: requested,
                        requestTraceID: requestTraceID,
                        reason: "virtual lens boundary"
                    )
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
                    if recordingOrStarting {
                        // Recording keeps the physical input fixed. There is no physical
                        // handoff to probe here, and the optional video-data diagnostics
                        // output is intentionally disabled for protected capture paths.
                        AppEventLog.deepEvent("FRAME-LEVEL ZOOM PROBE SKIPPED WHILE RECORDING",
                                              category: .zoom,
                                              traceID: diagnosticZoomInteractionTraceID ?? requestTraceID,
                                              fields: [
                                                "reason": "recording keeps the current physical lens; zoom is digital only",
                                                "mode": self.captureMode.rawValue,
                                                "device": currentDevice.localizedName,
                                                "requestedDisplayedZoom": String(format: "%.3f", Double(requested))
                                              ])
                    } else {
                        self.beginExtremeZoomTransitionProbeIfPossible(
                            device: currentDevice,
                            targetDisplayedZoom: requested,
                            requestTraceID: requestTraceID,
                            reason: "physical lens handoff",
                            probeExpectedDeviceZoom: currentDevice.videoZoomFactor
                        )
                    }
                    if recordingOrStarting && self.captureMode != .video {
                        // HFR recording must keep its physical input for the whole file. Do not
                        // reject the zoom gesture when it crosses the optical boundary; keep the
                        // active sensor and apply the part of the request that it can provide
                        // digitally. This is what lets rear Slo-Mo zoom from 0.5× while recording
                        // without rebuilding the 120/240 fps capture input mid-file.
                        let currentLensMinimum = self.minimumSupportedZoom(for: currentDevice)
                        let currentLensMaximum = self.maximumSupportedZoom(for: currentDevice)
                        let fixedLensZoom = min(max(requested, currentLensMinimum), currentLensMaximum)
                        if !self.didLogRecordingLensClamp {
                            self.didLogRecordingLensClamp = true
                            AppEventLog.event(
                                "Recording zoom kept on current physical lens: " +
                                "requested=\(String(format: "%.2f", requested))×, " +
                                "applied=\(String(format: "%.2f", fixedLensZoom))×, " +
                                "device=\(currentDevice.localizedName)"
                            )
                        }
                        requested = fixedLensZoom
                    }

                    // While recording, keep the physical input fixed and digitally zoom that
                    // sensor. Rebuilding AVCaptureDeviceInput mid-file can interrupt recording.
                    // Idle 4K60 and rear Slo-Mo use the covered physical-lens handoff below.
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
                                        self.applyPublishedZoomIfNeeded(actualZoom)
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
                let lockStart = ProcessInfo.processInfo.systemUptime
                try device.lockForConfiguration()
                let lockWaitMs = (ProcessInfo.processInfo.systemUptime - lockStart) * 1000
                let deviceFactor = self.deviceZoomFactor(for: factor, device: device)
                AppEventLog.deepEvent("ZOOM DEVICE LOCK ACQUIRED", category: .device, traceID: requestTraceID, fields: [
                    "waitMs": String(format: "%.2f", lockWaitMs),
                    "targetDeviceZoom": String(format: "%.3f", Double(deviceFactor))
                ])

                let usedImmediateSet = self.lensTransitionCoordinator.hasActiveTransition
                if usedImmediateSet {
                    // A newer drag returned to the currently active lens while a covered switch
                    // was pending/settling. Keep the cover up, commit the newest zoom immediately
                    // (no post-transition ramp), then let this newest request own the reveal.
                    self.lensTransitionCoordinator.takeOwnership(of: requestID)
                    device.cancelVideoZoomRamp()
                    device.videoZoomFactor = deviceFactor
                } else {
                    device.ramp(toVideoZoomFactor: deviceFactor, withRate: 12)
                }
                let readbackZoom = device.videoZoomFactor
                device.unlockForConfiguration()
                guard self.zoomRequests.isLatest(requestID) else { return }
                self.requestedZoom = factor

                if usedImmediateSet {
                    AppEventLog.deepEvent("ZOOM HARDWARE SET", category: .zoom, traceID: requestTraceID, fields: [
                        "displayedTarget": String(format: "%.3f", Double(factor)),
                        "deviceTarget": String(format: "%.3f", Double(deviceFactor)),
                        "deviceReadback": String(format: "%.3f", Double(readbackZoom)),
                        "durationMs": String(format: "%.2f", (ProcessInfo.processInfo.systemUptime - startedAt) * 1000)
                    ])
                } else {
                    // ramp(toVideoZoomFactor:) is asynchronous. The previous diagnostic event called
                    // this state "HARDWARE APPLIED" even though immediate readback was usually still
                    // at the old zoom. Record scheduling separately and verify the eventual settle.
                    AppEventLog.deepEvent("ZOOM RAMP SCHEDULED", category: .zoom, traceID: requestTraceID, fields: [
                        "displayedTarget": String(format: "%.3f", Double(factor)),
                        "deviceTarget": String(format: "%.3f", Double(deviceFactor)),
                        "initialReadback": String(format: "%.3f", Double(readbackZoom)),
                        "durationMs": String(format: "%.2f", (ProcessInfo.processInfo.systemUptime - startedAt) * 1000)
                    ])
                    self.monitorZoomRamp(
                        requestID: requestID,
                        traceID: requestTraceID,
                        device: device,
                        targetDeviceZoom: deviceFactor,
                        displayedTarget: factor
                    )
                }

                self.publish {
                    self.applyPublishedZoomIfNeeded(factor)
                }

                if usedImmediateSet, self.lensTransitionCoordinator.isActive(requestID) {
                    self.lensTransitionCoordinator.finishWhenDeviceSettled(
                        requestID,
                        device: device,
                        minimumHold: 0.08,
                        maximumHold: 0.30
                    )
                }
            } catch {
                AppEventLog.log(error: error, prefix: "ZOOM APPLY FAILED", category: .zoom, traceID: requestTraceID)
                self.showError("Couldn’t change the zoom.")
            }
    }

    private func monitorZoomRamp(
        requestID: UInt64,
        traceID: String,
        device: AVCaptureDevice,
        targetDeviceZoom: CGFloat,
        displayedTarget: CGFloat,
        startedAt: TimeInterval = ProcessInfo.processInfo.systemUptime
    ) {
        sessionQueue.asyncAfter(deadline: .now() + 0.025) { [weak self, weak device] in
            guard let self, let device,
                  self.zoomRequests.isLatest(requestID),
                  self.videoInput?.device.uniqueID == device.uniqueID else { return }

            let now = ProcessInfo.processInfo.systemUptime
            let readback = device.videoZoomFactor
            let delta = abs(readback - targetDeviceZoom)
            let tolerance = max(CGFloat(0.02), abs(targetDeviceZoom) * 0.005)
            if delta <= tolerance {
                AppEventLog.deepEvent("ZOOM RAMP SETTLED", category: .zoom, traceID: traceID, fields: [
                    "displayedTarget": String(format: "%.3f", Double(displayedTarget)),
                    "deviceTarget": String(format: "%.3f", Double(targetDeviceZoom)),
                    "deviceReadback": String(format: "%.3f", Double(readback)),
                    "elapsedMs": String(format: "%.2f", (now - startedAt) * 1000)
                ])
                return
            }

            if !device.isRampingVideoZoom, now - startedAt > 0.075 {
                AppEventLog.event("ZOOM RAMP STOPPED BEFORE TARGET", category: .zoom, level: .warning, traceID: traceID, fields: [
                    "displayedTarget": String(format: "%.3f", Double(displayedTarget)),
                    "deviceTarget": String(format: "%.3f", Double(targetDeviceZoom)),
                    "deviceReadback": String(format: "%.3f", Double(readback)),
                    "delta": String(format: "%.3f", Double(delta)),
                    "elapsedMs": String(format: "%.2f", (now - startedAt) * 1000)
                ])
                return
            }

            if now - startedAt >= 0.80 {
                AppEventLog.event("ZOOM RAMP SETTLE TIMEOUT", category: .zoom, level: .warning, traceID: traceID, fields: [
                    "displayedTarget": String(format: "%.3f", Double(displayedTarget)),
                    "deviceTarget": String(format: "%.3f", Double(targetDeviceZoom)),
                    "deviceReadback": String(format: "%.3f", Double(readback)),
                    "delta": String(format: "%.3f", Double(delta))
                ])
                return
            }

            self.monitorZoomRamp(
                requestID: requestID,
                traceID: traceID,
                device: device,
                targetDeviceZoom: targetDeviceZoom,
                displayedTarget: displayedTarget,
                startedAt: startedAt
            )
        }
    }

    private func beginExtremeZoomTransitionProbeIfPossible(
        device: AVCaptureDevice,
        targetDisplayedZoom: CGFloat,
        requestTraceID: String,
        reason: String,
        probeExpectedDeviceZoom: CGFloat? = nil
    ) {
        guard AppEventLog.extremeDiagnosticsEnabled else { return }
        let interactionTrace = diagnosticZoomInteractionTraceID ?? requestTraceID
        let targetDeviceZoom = deviceZoomFactor(for: snappedZoomFactor(targetDisplayedZoom, for: device), device: device)
        // During a physical handoff the callback stream still belongs to the old input until
        // commitConfiguration() succeeds. Compare those frames with the old input's current
        // zoom; after commit, applyPreparedLensHardware retargets the probe to the new device
        // and its committed zoom. Comparing the old stream with the future target creates false
        // flicker warnings for every frame while the cover is up.
        let expectedDeviceZoom = probeExpectedDeviceZoom ?? targetDeviceZoom
        let canObserveFrames = session.outputs.contains { $0 === liveMetrics.output } &&
            liveMetrics.output.connection(with: .video)?.isEnabled == true
        AppEventLog.deepEvent("EXTREME ZOOM TRANSITION MONITOR", category: .zoom, traceID: interactionTrace, fields: [
            "reason": reason,
            "requestTrace": requestTraceID,
            "frameProbeAvailable": String(canObserveFrames),
            "device": device.localizedName,
            "actualDeviceZoomBefore": String(format: "%.3f", Double(device.videoZoomFactor)),
            "targetDisplayedZoom": String(format: "%.3f", Double(targetDisplayedZoom)),
            "targetDeviceZoom": String(format: "%.3f", Double(targetDeviceZoom)),
            "probeExpectedDeviceZoom": String(format: "%.3f", Double(expectedDeviceZoom)),
            "probeExpectation": probeExpectedDeviceZoom == nil ? "future target" : "current device until handoff commit"
        ])
        guard canObserveFrames else {
            AppEventLog.deepEvent("FRAME-LEVEL ZOOM PROBE UNAVAILABLE", category: .zoom, traceID: interactionTrace,
                                  fields: ["reason": "video-data diagnostics output intentionally unavailable/disabled for this capture configuration"])
            return
        }
        if diagnosticZoomProbeStarted {
            liveMetrics.updateZoomTransitionProbe(
                traceID: interactionTrace,
                device: device,
                expectedDeviceZoom: expectedDeviceZoom,
                expectedDisplayedZoom: targetDisplayedZoom,
                hudZoom: formattedZoomLabel(for: targetDisplayedZoom)
            )
        } else {
            diagnosticZoomProbeStarted = true
            liveMetrics.beginZoomTransitionProbe(
                traceID: interactionTrace,
                device: device,
                expectedDeviceZoom: expectedDeviceZoom,
                expectedDisplayedZoom: targetDisplayedZoom,
                hudZoom: formattedZoomLabel(for: targetDisplayedZoom)
            )
        }
    }

    private func applyVirtualLensZoom(_ request: LensTransitionCoordinator.Request, device: AVCaptureDevice) -> Bool {
        let factor = snappedZoomFactor(request.requestedZoom, for: device)
        let traceID = "ZOOM-\(request.id)"
        do {
            let lockStart = ProcessInfo.processInfo.systemUptime
            try device.lockForConfiguration()
            let lockWait = (ProcessInfo.processInfo.systemUptime - lockStart) * 1000
            let target = deviceZoomFactor(for: factor, device: device)
            let before = device.videoZoomFactor
            device.cancelVideoZoomRamp()
            device.videoZoomFactor = target
            let after = device.videoZoomFactor
            device.unlockForConfiguration()
            AppEventLog.deepEvent("VIRTUAL LENS ZOOM SET", category: .zoom, traceID: traceID, fields: [
                "lockWaitMs": String(format: "%.2f", lockWait),
                "before": String(format: "%.3f", Double(before)),
                "target": String(format: "%.3f", Double(target)),
                "readback": String(format: "%.3f", Double(after)),
                "displayedTarget": String(format: "%.3f", Double(factor))
            ])
            if let interactionTrace = diagnosticZoomInteractionTraceID, diagnosticZoomProbeStarted {
                liveMetrics.updateZoomTransitionProbe(
                    traceID: interactionTrace,
                    device: device,
                    expectedDeviceZoom: target,
                    expectedDisplayedZoom: factor,
                    hudZoom: formattedZoomLabel(for: factor)
                )
            }
        } catch {
            AppEventLog.log(error: error, prefix: "VIRTUAL LENS ZOOM FAILED", category: .zoom, traceID: traceID)
            return false
        }

        // The hardware zoom succeeded. If a newer request took ownership during the device call,
        // leave publishing/reveal to that request exactly as the previous inlined path did.
        guard lensTransitionCoordinator.isActive(request.id),
              zoomRequests.isLatest(request.id) else { return true }
        requestedZoom = factor
        publish {
            self.applyPublishedZoomIfNeeded(factor)
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
        // This handoff keeps the same mode, resolution and frame rate, so the published zoom
        // range is already correct. Re-scanning every format on every lens after the blocking
        // hardware commit only extends the visible transition.
        let torchAvailable = prepared.device.hasTorch && prepared.device.isTorchAvailable
        let torchOn = prepared.device.hasTorch && prepared.device.torchMode == .on
        publish {
            self.applyPublishedZoomIfNeeded(displayed)
            if self.torchAvailable != torchAvailable {
                self.torchAvailable = torchAvailable
            }
            if self.isTorchOn != torchOn {
                self.isTorchOn = torchOn
            }
        }
        resetFocusAndExposureState()
        synchronizeWhiteBalanceAfterConfiguration()
        logCaptureConfiguration("Lens handoff")

        if let interactionTrace = diagnosticZoomInteractionTraceID,
           diagnosticZoomProbeStarted {
            liveMetrics.retargetZoomTransitionProbe(
                traceID: interactionTrace,
                device: prepared.device,
                expectedDeviceZoom: prepared.device.videoZoomFactor,
                expectedDisplayedZoom: displayed,
                hudZoom: formattedZoomLabel(for: displayed),
                reason: "physical lens handoff committed"
            )
        }

        // applyAtomicCaptureConfiguration has already validated the input replacement, locked the
        // target device, applied the requested format/FPS/zoom, and successfully committed the
        // capture-session transaction. Do not fail the transition on an immediate post-commit
        // read-back: AVFoundation can report transient duration/zoom state while the new 4K60/HFR
        // stream is still settling, which produced the false “Couldn’t finish…” message even though
        // the lens switch itself completed correctly.
        return true
    }



    func setRememberCameraSetupEnabled(_ enabled: Bool) {
        UserDefaults.standard.set(enabled, forKey: "rememberCaptureMode")
        if enabled {
            persistRememberedCameraSetup()
            AppEventLog.event(
                "CAMERA SETUP MEMORY ENABLED: mode=\(captureMode.rawValue), position=\(cameraPosition.rawValue)"
            )
        } else {
            AppEventLog.event("CAMERA SETUP MEMORY DISABLED")
        }
    }

    private func persistRememberedCameraSetup() {
        guard UserDefaults.standard.bool(forKey: "rememberCaptureMode") else { return }
        UserDefaults.standard.set(captureMode.rawValue, forKey: "lastCaptureMode")
        UserDefaults.standard.set(cameraPosition.rawValue, forKey: "lastCameraPosition")
    }

    func switchCamera() {
        guard !isRecording, !isRecordingStarting, !isFinalizingRecording, !isCapturingPhoto, !isLensTransitioning else {
            AppEventLog.guardRejected("switchCamera", reason: "camera busy", fields: [
                "recording": String(isRecording), "recordingStarting": String(isRecordingStarting),
                "finalizing": String(isFinalizingRecording), "capturingPhoto": String(isCapturingPhoto),
                "lensTransition": String(isLensTransitioning)
            ])
            return
        }
        let previous = cameraPosition
        let target: CameraPosition = previous == .back ? .front : .back
        let switchTraceID = AppEventLog.makeTraceID("CAMSWITCH")
        let switchStartedAt = ProcessInfo.processInfo.systemUptime
        let beforeDevice = videoInput?.device
        AppEventLog.event("========== CAMERA SWITCH START =========", category: .device, traceID: switchTraceID, fields: [
            "from": previous.rawValue, "to": target.rawValue,
            "device": beforeDevice?.localizedName ?? "none",
            "deviceID": beforeDevice?.uniqueID ?? "none",
            "mode": captureMode.rawValue,
            "requestedZoom": String(format: "%.3f", requestedZoom),
            "actualDeviceZoom": beforeDevice.map { String(format: "%.3f", $0.videoZoomFactor) } ?? "none"
        ])
        let previousCodec = selectedVideoCodec
        let previousSupportedResolutions = supportedResolutions
        let previousSupportedFrameRates = supportedFrameRates
        let previousVideoAvailabilityKnown = isVideoAvailabilityKnown
        let previousVideoAvailable = isVideoAvailable
        let previousSupportedSlowMotionResolutions = supportedSlowMotionResolutions
        let previousSupportedSlowMotionFrameRates = supportedSlowMotionFrameRates
        let previousSlowMotionAvailabilityKnown = isSlowMotionAvailabilityKnown
        let previousSlowMotionAvailable = isSlowMotionAvailable
        AppEventLog.event("Camera switch requested: \(previous == .back ? "back" : "front") to \(target == .back ? "back" : "front")", category: .device, traceID: switchTraceID)
        invalidateCodecSupportCache()
        codecAvailabilityMessage = nil
        isVideoAvailabilityKnown = false
        isVideoAvailable = true
        supportedResolutions.removeAll(keepingCapacity: true)
        supportedFrameRates.removeAll(keepingCapacity: true)
        supportedSlowMotionResolutions.removeAll(keepingCapacity: true)
        supportedSlowMotionFrameRates.removeAll(keepingCapacity: true)
        isSlowMotionAvailabilityKnown = false
        isSlowMotionAvailable = true
        _ = capabilityRequests.next(reason: "camera switch invalidated capability snapshot")
        publish {
            self.capabilitySnapshot = .empty
            self.isCapabilitySnapshotLoading = true
        }
        let requestID = cameraSwitchRequests.next(reason: "camera switch \(previous.rawValue) -> \(target.rawValue)")
        let switchQueueTicket = AppEventLog.queueScheduled("camera switch", category: .device, traceID: switchTraceID)
        _ = zoomRequests.next() // Drop any drag command that belongs to the old camera.
        _ = qualityRequests.next() // Do not apply an old quality request to the new input.
        _ = captureConfigurationGeneration.next() // Drop output work captured for the old input.
        _ = videoConfigurationRequests.next() // Drop pending Video-setting work for the old input.
        _ = exposureRequests.next() // Do not apply a queued slider value to the new input.

        cameraPosition = target
        loadCameraPreferences(for: target)
        _ = autoPromoteH264ForUnsupportedVideoSelection(
            position: target,
            resolution: selectedResolution,
            frameRate: selectedFrameRate
        )

        sessionQueue.async { [weak self] in
            AppEventLog.queueStarted(switchQueueTicket)
            guard let self else { return }
            guard self.cameraSwitchRequests.isLatest(requestID) else {
                AppEventLog.staleRequest(token: "cameraSwitchRequests", requestID: requestID, latestID: self.cameraSwitchRequests.current(), operation: "camera switch", traceID: switchTraceID)
                return
            }
            self.invalidatePendingVideoConfiguration()
            self.lensTransitionCoordinator.cancel()
            guard self.applyActiveModeFormat(preferVirtualCamera: !self.requiresPhysicalWhiteBalanceInput) else {
                AppEventLog.event("CAMERA SWITCH FORMAT/APPLY FAILED", category: .device, level: .warning, traceID: switchTraceID,
                                  fields: ["elapsedMs": String(format: "%.2f", (ProcessInfo.processInfo.systemUptime - switchStartedAt) * 1000)])
                guard self.cameraSwitchRequests.isLatest(requestID) else {
                    AppEventLog.staleRequest(token: "cameraSwitchRequests", requestID: requestID, latestID: self.cameraSwitchRequests.current(), operation: "camera switch rollback", traceID: switchTraceID)
                    return
                }
                self.publish {
                    self.cameraPosition = previous
                    self.loadCameraPreferences(for: previous)
                    let wasSuppressing = self.suppressAutomaticReconfiguration
                    self.suppressAutomaticReconfiguration = true
                    if self.selectedVideoCodec != previousCodec {
                        self.selectedVideoCodec = previousCodec
                    }
                    self.suppressAutomaticReconfiguration = wasSuppressing
                    self.supportedResolutions = previousSupportedResolutions
                    self.supportedFrameRates = previousSupportedFrameRates
                    self.isVideoAvailabilityKnown = previousVideoAvailabilityKnown
                    self.isVideoAvailable = previousVideoAvailable
                    self.supportedSlowMotionResolutions = previousSupportedSlowMotionResolutions
                    self.supportedSlowMotionFrameRates = previousSupportedSlowMotionFrameRates
                    self.isSlowMotionAvailabilityKnown = previousSlowMotionAvailabilityKnown
                    self.isSlowMotionAvailable = previousSlowMotionAvailable
                    self.codecAvailabilityMessage = nil
                    self.capabilitySnapshot = .empty
                    self.isCapabilitySnapshotLoading = false
                    self.scheduleCapabilitySnapshotRefresh(reason: "camera switch rolled back")
                }
                self.showError("That camera is unavailable.")
                AppEventLog.event("========== CAMERA SWITCH END =========", category: .device, level: .warning, traceID: switchTraceID,
                                  fields: ["result": "failed", "totalMs": String(format: "%.2f", (ProcessInfo.processInfo.systemUptime - switchStartedAt) * 1000)])
                return
            }
            guard self.cameraSwitchRequests.isLatest(requestID) else {
                AppEventLog.staleRequest(token: "cameraSwitchRequests", requestID: requestID, latestID: self.cameraSwitchRequests.current(), operation: "camera switch post-apply", traceID: switchTraceID)
                return
            }
            self.synchronizeTorchState()
            self.persistRememberedCameraSetup()
            self.scheduleCapabilitySnapshotRefresh(reason: "camera switch applied")
            let afterDevice = self.videoInput?.device
            AppEventLog.event("Camera switch applied: \(target == .back ? "back" : "front")", category: .device, traceID: switchTraceID, fields: [
                "device": afterDevice?.localizedName ?? "none",
                "deviceID": afterDevice?.uniqueID ?? "none",
                "actualDeviceZoom": afterDevice.map { String(format: "%.3f", $0.videoZoomFactor) } ?? "none",
                "totalMs": String(format: "%.2f", (ProcessInfo.processInfo.systemUptime - switchStartedAt) * 1000)
            ])
            AppEventLog.stateDiff("CAMERA SWITCH", before: ["position": previous.rawValue, "device": beforeDevice?.localizedName ?? "none"],
                                  after: ["position": target.rawValue, "device": afterDevice?.localizedName ?? "none"], traceID: switchTraceID, category: .device)
            AppEventLog.event("========== CAMERA SWITCH END =========", category: .device, traceID: switchTraceID,
                              fields: ["result": "success", "totalMs": String(format: "%.2f", (ProcessInfo.processInfo.systemUptime - switchStartedAt) * 1000)])
        }
    }

    func selectCaptureMode(_ mode: CaptureMode) {
        guard !isRecording, !isRecordingStarting, !isFinalizingRecording, !isCapturingPhoto, !isPreviewTransitioning, !isLensTransitioning, captureMode != mode else {
            AppEventLog.guardRejected("selectCaptureMode", reason: "busy or already selected", fields: [
                "requested": mode.rawValue, "current": captureMode.rawValue,
                "recording": String(isRecording), "capturingPhoto": String(isCapturingPhoto),
                "previewTransition": String(isPreviewTransitioning), "lensTransition": String(isLensTransitioning)
            ])
            return
        }
        guard isCaptureModeSupported(mode) else {
            AppEventLog.guardRejected("selectCaptureMode", reason: "unsupported mode", fields: ["requested": mode.rawValue])
            return
        }
        let previousMode = captureMode
        let modeTraceID = AppEventLog.makeTraceID("MODE")
        let modeStartedAt = ProcessInfo.processInfo.systemUptime
        AppEventLog.event("========== MODE CHANGE START =========", category: .session, traceID: modeTraceID,
                          fields: ["from": previousMode.rawValue, "to": mode.rawValue, "camera": cameraPosition.rawValue])
        AppEventLog.event("Capture mode requested: \(previousMode.rawValue) to \(mode.rawValue)", category: .session, traceID: modeTraceID)
        codecAvailabilityMessage = nil
        let requestID = modeChangeRequests.next(reason: "capture mode \(previousMode.rawValue) -> \(mode.rawValue)")
        let modeQueueTicket = AppEventLog.queueScheduled("capture mode change", category: .session, traceID: modeTraceID)
        _ = zoomRequests.next() // A queued old-mode zoom must not reconfigure the new mode.
        _ = qualityRequests.next() // Drop quality work that belonged to the previous mode.
        _ = captureConfigurationGeneration.next() // Drop output work captured for the previous mode.
        _ = videoConfigurationRequests.next() // Drop pending Video-setting work for the previous mode.
        _ = exposureRequests.next() // The new mode reapplies the current requested EV itself.
        isPreviewTransitioning = true
        captureMode = mode
        if mode == .video {
            _ = autoPromoteH264ForUnsupportedVideoSelection(
                position: cameraPosition,
                resolution: selectedResolution,
                frameRate: selectedFrameRate
            )
        }
        sessionQueue.async { [weak self] in
            AppEventLog.queueStarted(modeQueueTicket)
            guard let self else { return }
            guard self.modeChangeRequests.isLatest(requestID) else {
                AppEventLog.staleRequest(token: "modeChangeRequests", requestID: requestID, latestID: self.modeChangeRequests.current(), operation: "capture mode change", traceID: modeTraceID)
                return
            }
            self.invalidatePendingVideoConfiguration()
            self.lensTransitionCoordinator.cancel()
            let success = self.applyActiveModeFormat(preferVirtualCamera: !self.requiresPhysicalWhiteBalanceInput)
            if success {
                self.configureAudioMeterOutput()
                if mode == .photo {
                    self.setTorchEnabledOnCurrentDevice(false)
                }
                self.synchronizeTorchState()
            }
            AppEventLog.event("Capture mode \(success ? "applied" : "failed"): \(mode.rawValue)", category: .session,
                              level: success ? .info : .warning, traceID: modeTraceID,
                              fields: ["totalMs": String(format: "%.2f", (ProcessInfo.processInfo.systemUptime - modeStartedAt) * 1000),
                                       "device": self.videoInput?.device.localizedName ?? "none"])

            self.publish {
                self.isPreviewTransitioning = false
                if success {
                    self.persistRememberedCameraSetup()
                    self.scheduleCapabilitySnapshotRefresh(reason: "capture mode applied")
                } else {
                    self.captureMode = previousMode
                    self.sessionQueue.async {
                        _ = self.applyActiveModeFormat(preferVirtualCamera: !self.requiresPhysicalWhiteBalanceInput)
                        self.synchronizeTorchState()
                    }
                    self.scheduleCapabilitySnapshotRefresh(reason: "capture mode rolled back")
                }
                AppEventLog.event("========== MODE CHANGE END =========", category: .session,
                                  level: success ? .info : .warning, traceID: modeTraceID,
                                  fields: ["result": success ? "success" : "rolled-back",
                                           "publishedMode": self.captureMode.rawValue,
                                           "totalMs": String(format: "%.2f", (ProcessInfo.processInfo.systemUptime - modeStartedAt) * 1000)])
            }
        }
    }

    private func scheduleTorchRestoreAfterLensHandoff(
        on device: AVCaptureDevice,
        requestID: UInt64,
        attempt: Int = 0
    ) {
        let delay = attempt == 0 ? 0.02 : 0.04
        sessionQueue.asyncAfter(deadline: .now() + delay) { [weak self, weak device] in
            guard let self, let device,
                  self.torchRequests.isLatest(requestID),
                  self.videoInput?.device.uniqueID == device.uniqueID,
                  self.session.isRunning,
                  !self.session.isInterrupted,
                  self.captureMode == .video,
                  self.cameraPosition == .back,
                  self.selectedResolution == .p4k,
                  self.selectedFrameRate == .fps60,
                  !self.recordingState.requestsRecording,
                  !self.movieOutput.isRecording else { return }

            guard device.hasTorch else {
                self.synchronizeTorchState()
                return
            }
            if device.torchMode == .on {
                self.synchronizeTorchState()
                return
            }
            guard attempt <= 3 else {
                self.synchronizeTorchState()
                AppEventLog.event("Torch remained off after rear 4K60 lens handoff")
                return
            }

            self.setTorchEnabledOnCurrentDevice(true)
            guard self.torchRequests.isLatest(requestID),
                  self.videoInput?.device.uniqueID == device.uniqueID,
                  device.torchMode != .on else { return }
            self.scheduleTorchRestoreAfterLensHandoff(
                on: device,
                requestID: requestID,
                attempt: attempt + 1
            )
        }
    }

    func refreshLiveMetrics() {
        sessionQueue.async { [weak self] in
            guard let self, !self.recordingState.requestsRecording, !self.movieOutput.isRecording,
                   !self.lensTransitionCoordinator.hasActiveTransition,
                   self.videoInput != nil else { return }

            let wanted = self.liveMetricsAttachmentWanted()
            let attached = self.liveMetricsOutputIsAttached()
            let connectionNeedsDisable = self.liveMetrics.output.connection(with: .video)?.isEnabled == true &&
                !AppEventLog.extremeDiagnosticsEnabled
            let publishedStateNeedsSync = self.liveMetricsAvailable != attached
            guard wanted != attached || connectionNeedsDisable || publishedStateNeedsSync else { return }

            // If the actual output state is already correct, synchronize only the published
            // snapshot. Do not open a no-op AVCaptureSession configuration transaction.
            if wanted == attached && !connectionNeedsDisable {
                self.configureZebraAnalysis()
                self.publish {
                    if self.liveMetricsAvailable != attached {
                        self.liveMetricsAvailable = attached
                    }
                }
                return
            }

            self.session.beginConfiguration()
            self.configureLiveMetrics()
            self.session.commitConfiguration()
        }
    }

    // Called inside the same transaction as the input/format change.
    private func configureLiveMetrics() {
        let wanted = liveMetricsAttachmentWanted()
        let attached = liveMetricsOutputIsAttached()
        let previewFramesWanted = (isZebraExposureWarningEnabled || AppEventLog.extremeDiagnosticsEnabled) &&
            captureMode != .photo
        let connectionNeedsDisable = liveMetrics.output.connection(with: .video)?.isEnabled == true &&
            !recordingState.requestsRecording &&
            !movieOutput.isRecording &&
            !previewFramesWanted

        if wanted == attached && !connectionNeedsDisable {
            configureZebraAnalysis()
            setLiveMetricsConnectionEnabled(previewFramesWanted)
            publish {
                if self.liveMetricsAvailable != attached {
                    self.liveMetricsAvailable = attached
                }
            }
            return
        }

        if wanted && !attached && session.canAddOutput(liveMetrics.output) {
            session.addOutput(liveMetrics.output)
        } else if !wanted && attached {
            stopLiveMetrics()
            session.removeOutput(liveMetrics.output)
        }

        let available = session.outputs.contains { $0 === liveMetrics.output }
        if available && !movieOutput.isRecording {
            setLiveMetricsConnectionEnabled(
                previewFramesWanted
            )
        }
        configureZebraAnalysis()
        publish {
            if self.liveMetricsAvailable != available {
                self.liveMetricsAvailable = available
            }
        }
        AppEventLog.event(
            "LIVE METRICS CONFIGURED: requested=\(wanted), attached=\(available), mode=\(captureMode.rawValue)"
        )
    }

    private func liveMetricsAttachmentWanted() -> Bool {
        let isRear4K60 = isProtectedRear4K60Configuration
        // A second video-data stream can push multi-camera 4K60 beyond the device's sustainable
        // capture budget and trigger a runtime-error rebuild loop. File bitrate remains available
        // without this optional output; only measured FPS/drop counters are omitted in rear 4K60.
        let requestedByUser = UserDefaults.standard.bool(forKey: "liveRecordingStats")
        let requestedByExtremeDiagnostics = AppEventLog.extremeDiagnosticsEnabled
        return (requestedByUser || requestedByExtremeDiagnostics || isZebraExposureWarningEnabled) &&
            captureMode != .photo &&
            !isRear4K60
    }

    private var isProtectedRear4K60Configuration: Bool {
        captureMode == .video &&
            cameraPosition == .back &&
            selectedResolution == .p4k &&
            selectedFrameRate == .fps60
    }

    private func zebraCapabilityForCurrentConfiguration() -> Bool {
        guard ZebraAvailabilityPolicy.isAvailable(
            isPhotoMode: captureMode == .photo,
            isProtectedRear4K60: isProtectedRear4K60Configuration
        ) else { return false }
        return liveMetricsOutputIsAttached() || session.canAddOutput(liveMetrics.output)
    }

    private func updateZebraAvailability(_ available: Bool) {
        let previous = zebraAvailabilityKnown ? zebraAvailableForCurrentConfiguration : nil
        zebraAvailableForCurrentConfiguration = available
        zebraAvailabilityKnown = true
        publish {
            if self.isZebraAvailableForCurrentConfiguration != available {
                self.isZebraAvailableForCurrentConfiguration = available
            }
        }
        guard let previous, previous != available else { return }
        AppEventLog.event(
            available ? "ZEBRA RESTORED" : "ZEBRA TEMPORARILY UNAVAILABLE",
            category: .exposure,
            fields: [
                "mode": captureMode.rawValue,
                "resolution": hudResolutionLabel,
                "fps": hudFrameRateLabel ?? "none",
                "protectedRear4K60": String(isProtectedRear4K60Configuration)
            ]
        )
    }

    private func configureZebraAnalysis() {
        let available = zebraCapabilityForCurrentConfiguration()
        updateZebraAvailability(available)
        let enabled = ZebraAvailabilityPolicy.isActive(
            requested: isZebraExposureWarningEnabled,
            available: available
        ) && liveMetricsOutputIsAttached()
        if enabled != zebraAnalysisActive {
            zebraAnalysisActive = enabled
            AppEventLog.event(enabled ? "ZEBRA ANALYSIS START" : "ZEBRA ANALYSIS STOP", category: .exposure)
        }
        liveMetrics.setZebraAnalysis(enabled: enabled) { [weak self] mask in
            self?.sessionQueue.async { [weak self] in
                guard let self, self.zebraAnalysisActive else { return }
                self.zebraExposureState.update(mask)
            }
        }
        if !enabled { zebraExposureState.reset() }
    }

    private func liveMetricsOutputIsAttached() -> Bool {
        session.outputs.contains { $0 === liveMetrics.output }
    }

    private func setLiveMetricsConnectionEnabled(_ enabled: Bool) {
        guard let connection = liveMetrics.output.connection(with: .video),
              connection.isEnabled != enabled else { return }
        connection.isEnabled = enabled
    }

    private func stopLiveMetrics() {
        let wasRunning = metricsTimer != nil
        metricsTimer?.cancel()
        metricsTimer = nil
        liveMetrics.setRunning(false)
        configureZebraAnalysis()
        setLiveMetricsConnectionEnabled(
            ((AppEventLog.extremeDiagnosticsEnabled || isZebraExposureWarningEnabled) &&
                liveMetricsOutputIsAttached() && captureMode != .photo)
        )
        if wasRunning {
            AppEventLog.event("Live metrics stopped")
        }
    }

    private func startLiveMetrics() {
        stopLiveMetrics()
        previousMetricBytes = 0
        previousMetricDuration = 0
        lastExtremeRecordingHealthSecond = -1
        let userStatsEnabled = UserDefaults.standard.bool(forKey: "liveRecordingStats")
        let extremeEnabled = AppEventLog.extremeDiagnosticsEnabled
        if userStatsEnabled { publish { self.liveStats.reset() } }
        guard userStatsEnabled || extremeEnabled else {
            AppEventLog.event("Live metrics not started: setting disabled")
            return
        }

        let captureMetricsAvailable = session.outputs.contains { $0 === liveMetrics.output }
        if captureMetricsAvailable {
            setLiveMetricsConnectionEnabled(true)
            liveMetrics.setRunning(true)
        }
        let initialDuration = videoInput?.device.activeVideoMinFrameDuration.seconds ?? 0
        let initialFPS: Double? = initialDuration > 0 ? 1 / initialDuration : nil
        if userStatsEnabled { publish { self.liveStats.update(fps: initialFPS, mbps: nil, drops: nil) } }
        AppEventLog.event("Live metrics started: captureMetricsAvailable=\(captureMetricsAvailable), mode=\(captureMode.rawValue)", category: .performance,
                          traceID: activeRecordingTraceID, fields: ["userStats": String(userStatsEnabled), "extreme": String(extremeEnabled)])

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

            let activeDuration = self.videoInput?.device.activeVideoMinFrameDuration.seconds ?? 0
            let activeFPS: Double? = activeDuration > 0 ? 1 / activeDuration : nil
            let monitoredStreamRepresentsCaptureRate: Bool
            if let measuredFPS = fps, let activeFPS {
                monitoredStreamRepresentsCaptureRate = measuredFPS >= activeFPS * 0.75
            } else {
                monitoredStreamRepresentsCaptureRate = false
            }
            // AVCaptureVideoDataOutput can be capped below the movie stream (notably rear 240 fps
            // and front 120 fps), and is intentionally detached for rear 4K60. The active device
            // duration is the recording frame rate; only expose drop counts when the monitoring
            // stream is actually keeping up closely enough to make that counter meaningful.
            let displayedFPS = activeFPS ?? fps
            let displayedDrops = attached && monitoredStreamRepresentsCaptureRate ? drops : nil

            let fpsText = fps.map { String(format: "%.1f", $0) } ?? "unavailable"
            let activeFPSText = activeFPS.map { String(format: "%.1f", $0) } ?? "unavailable"
            let bitrateText = mbps.map { String(format: "%.2f Mbps", $0) } ?? "unavailable"
            let dropsText = drops.map { String($0) } ?? "unavailable"
            if userStatsEnabled {
                AppEventLog.event(
                    "LIVE METRICS: duration=\(String(format: "%.1f", duration))s, bytes=\(bytes), bitrate=\(bitrateText), " +
                    "monitoredFPS=\(fpsText), activeFPS=\(activeFPSText), monitoredDrops=\(dropsText), " +
                    "dropsAvailable=\(displayedDrops != nil), captureMetricsAttached=\(attached)",
                    category: .performance, traceID: self.activeRecordingTraceID
                )
                self.publish {
                    self.liveStats.update(fps: displayedFPS, mbps: mbps, drops: displayedDrops)
                }
            }
            if AppEventLog.extremeDiagnosticsEnabled {
                let second = Int(duration.rounded(.down))
                if second == 0 || second >= self.lastExtremeRecordingHealthSecond + 5 {
                    self.lastExtremeRecordingHealthSecond = second
                    let device = self.videoInput?.device
                    AppEventLog.deepEvent("RECORDING HEALTH", category: .recording, traceID: self.activeRecordingTraceID, fields: [
                        "elapsedSeconds": String(format: "%.2f", duration),
                        "fileBytes": String(bytes),
                        "bitrateMbps": mbps.map { String(format: "%.2f", $0) } ?? "unavailable",
                        "activeFPS": activeFPSText,
                        "monitoredFPS": fpsText,
                        "drops": dropsText,
                        "metricsOutputAttached": String(attached),
                        "device": device?.localizedName ?? "none",
                        "deviceZoom": device.map { String(format: "%.3f", $0.videoZoomFactor) } ?? "none",
                        "thermal": String(describing: ProcessInfo.processInfo.thermalState),
                        "lowPowerMode": String(ProcessInfo.processInfo.isLowPowerModeEnabled)
                    ])
                }
            }
        }
        metricsTimer = timer
        timer.resume()
    }

    func applyLongevityMode(_ enabled: Bool) {
        guard !isRecording, !isRecordingStarting, !isFinalizingRecording else {
            AppEventLog.event("Longevity Mode ignored: recording is active")
            return
        }
        AppEventLog.event("Longevity Mode requested: \(enabled)")
        let defaults = UserDefaults.standard
        _ = videoConfigurationRequests.next()
        _ = qualityRequests.next()
        _ = captureConfigurationGeneration.next()
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
            videoCompressionMode = .auto
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
            self.invalidatePendingVideoConfiguration()
            self.lensTransitionCoordinator.cancel()
            let success = self.applyActiveModeFormat(preferVirtualCamera: !self.requiresPhysicalWhiteBalanceInput)
            AppEventLog.event("Longevity Mode \(success ? "applied" : "failed"): enabled=\(enabled)")
        }
    }

    func selectPhotoMegapixels(_ megapixels: Int) {
        guard supportedPhotoMegapixels.contains(megapixels), selectedPhotoMegapixels != megapixels else { return }
        AppEventLog.event("Photo megapixels requested: \(selectedPhotoMegapixels) MP -> \(megapixels) MP")
        preferredPhotoMegapixels = megapixels
        UserDefaults.standard.set(megapixels, forKey: Self.photoMegapixelsKey)
        selectedPhotoMegapixels = megapixels
        currentPhotoResolutionLabel = "\(megapixels) MP"
        currentPhotoPixelCount = Int64(megapixels) * 1_000_000
        refreshAvailableStorage()
        AppEventLog.event("Photo megapixels applied: \(megapixels) MP")
    }

    func updatePhotoAspectSelection(_ aspect: String) {
        AppEventLog.event("Photo aspect requested: \(aspect)")
        sessionQueue.async { [weak self] in
            guard let self,
                  self.nativePhotoDimensions.width > 0,
                  self.nativePhotoDimensions.height > 0 else { return }
            self.updatePhotoMegapixelAvailability(for: self.nativePhotoDimensions, aspect: aspect)
            AppEventLog.event("Photo aspect applied: \(aspect), supported megapixels=\(self.supportedPhotoMegapixels.map { String($0) }.joined(separator: ","))")
        }
    }

    @discardableResult
    func captureBurst() -> Bool {
        guard captureMode == .photo, !isCapturingPhoto, !isRecordingStarting, !isFinalizingRecording else {
            AppEventLog.guardRejected("captureBurst", reason: "camera busy or not in Photo mode", fields: [
                "mode": captureMode.rawValue,
                "isCapturingPhoto": String(isCapturingPhoto),
                "recordingStarting": String(isRecordingStarting),
                "finalizing": String(isFinalizingRecording)
            ])
            return false
        }
        let savedCount = UserDefaults.standard.integer(forKey: "burstCount")
        let count = Self.photoBurstCountOptions.contains(savedCount) ? savedCount : Self.defaultPhotoBurstCount
        let burstTrace = AppEventLog.extremeDiagnosticsEnabled ? AppEventLog.makeTraceID("BURST") : "BURST"
        AppEventLog.event("========== BURST CAPTURE START =========", category: .burst, traceID: burstTrace,
                          fields: ["requestedCount": String(count)])
        isCapturingPhoto = true
        sessionQueue.async { [weak self] in
            guard let self else { return }
            self.activeBurstTraceID = burstTrace
            self.burstRequestedCount = count
            self.burstRemaining = count
            self.burstStopRequested = false
            self.burstAspect = UserDefaults.standard.string(forKey: "photoAspect") ?? "4:3"
            self.burstMegapixels = self.selectedPhotoMegapixels
            AppEventLog.deepEvent("BURST SETTINGS SNAPSHOT", category: .burst, traceID: burstTrace, fields: [
                "aspect": self.burstAspect,
                "megapixels": String(self.burstMegapixels),
                "camera": self.videoInput?.device.localizedName ?? "none"
            ])
            self.refreshAvailableStorage()
            self.beginPhotoCapture()
        }
        return true
    }

    func stopBurst() {
        sessionQueue.async { [weak self] in
            guard let self, self.burstRemaining > 0 else { return }
            self.burstStopRequested = true
            AppEventLog.event("Burst capture stop requested: remaining=\(self.burstRemaining)", category: .burst,
                              traceID: self.activeBurstTraceID)
        }
    }

    @discardableResult
    func capturePhoto() -> Bool {
        guard captureMode == .photo, !isRecording, !isRecordingStarting, !isFinalizingRecording, !isCapturingPhoto else {
            AppEventLog.guardRejected("capturePhoto", reason: "camera busy or not in Photo mode", fields: [
                "mode": captureMode.rawValue,
                "recording": String(isRecording),
                "recordingStarting": String(isRecordingStarting),
                "finalizing": String(isFinalizingRecording),
                "capturingPhoto": String(isCapturingPhoto)
            ])
            return false
        }
        isCapturingPhoto = true
        sessionQueue.async { [weak self] in
            guard let self else { return }
            self.burstRemaining = 0
            self.burstRequestedCount = 0
            self.activeBurstTraceID = nil
            self.burstStopRequested = false
            self.beginPhotoCapture()
        }
        return true
    }

    func focusAndExpose(at point: CGPoint) {
        let requestID = focusExposureRequests.next(reason: "tap focus/exposure")
        sessionQueue.async { [weak self] in
            guard let self, self.focusExposureRequests.isLatest(requestID) else { return }
            self.configureFocusAndExposure(at: point, lockAfterFocusing: false, requestID: requestID)
        }
    }

    func lockFocusAndExposure(at point: CGPoint) {
        let requestID = focusExposureRequests.next(reason: "lock focus/exposure")
        sessionQueue.async { [weak self] in
            guard let self, self.focusExposureRequests.isLatest(requestID) else { return }
            self.configureFocusAndExposure(at: point, lockAfterFocusing: true, requestID: requestID)
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
        let requestID = whiteBalanceRequests.next(reason: "white balance -> \(preset.rawValue)")
        let traceID = "WB-\(requestID)"
        let ticket = AppEventLog.queueScheduled("white balance apply", category: .whiteBalance, traceID: traceID)
        AppEventLog.event("White balance requested: \(preset.rawValue)", category: .whiteBalance, traceID: traceID, fields: [
            "currentPreset": requestedWhiteBalancePreset.rawValue,
            "camera": cameraPosition.rawValue,
            "device": videoInput?.device.localizedName ?? "none"
        ])
        sessionQueue.async { [weak self] in
            AppEventLog.queueStarted(ticket)
            guard let self else { return }
            guard self.whiteBalanceRequests.isLatest(requestID) else {
                AppEventLog.staleRequest(token: "whiteBalanceRequests", requestID: requestID, latestID: self.whiteBalanceRequests.current(),
                                         operation: "white balance selection", traceID: traceID)
                return
            }
            guard !self.movieOutput.isRecording, !self.recordingState.requestsRecording,
                  !self.lensTransitionCoordinator.hasActiveTransition else {
                AppEventLog.guardRejected("white balance selection", reason: "camera busy", traceID: traceID, fields: [
                    "movieRecording": String(self.movieOutput.isRecording),
                    "recordingRequested": String(self.recordingState.requestsRecording),
                    "lensTransition": String(self.lensTransitionCoordinator.hasActiveTransition)
                ])
                return
            }

            let previousPreset = self.requestedWhiteBalancePreset
            self.requestedWhiteBalancePreset = preset
            UserDefaults.standard.set(preset.rawValue, forKey: LowPolyCamPreferences.Key.whiteBalancePreset)

            guard self.session.isRunning, !self.session.isInterrupted else {
                self.deferWhiteBalanceRequest(
                    id: requestID,
                    preset: preset,
                    previousPreset: previousPreset
                )
                return
            }

            self.applyWhiteBalanceRequest(
                preset,
                previousPreset: previousPreset,
                requestID: requestID
            )
        }
    }

    private func deferWhiteBalanceRequest(
        id: UInt64,
        preset: WhiteBalancePreset,
        previousPreset: WhiteBalancePreset
    ) {
        guard whiteBalanceRequests.isLatest(id) else { return }
        deferredWhiteBalanceRequest = DeferredWhiteBalanceRequest(
            id: id,
            preset: preset,
            previousPreset: previousPreset
        )
        let state = session.isInterrupted ? "interrupted" : "not running"
        AppEventLog.event("White balance deferred: camera session is \(state)", category: .whiteBalance, traceID: "WB-\(id)", fields: [
            "preset": preset.rawValue, "previousPreset": previousPreset.rawValue
        ])
    }

    private func applyDeferredWhiteBalanceIfPossible() {
        guard let deferred = deferredWhiteBalanceRequest else { return }
        guard whiteBalanceRequests.isLatest(deferred.id) else {
            deferredWhiteBalanceRequest = nil
            return
        }
        guard session.isRunning, !session.isInterrupted else { return }
        deferredWhiteBalanceRequest = nil
        applyWhiteBalanceRequest(
            deferred.preset,
            previousPreset: deferred.previousPreset,
            requestID: deferred.id
        )
    }

    private func applyWhiteBalanceRequest(
        _ preset: WhiteBalancePreset,
        previousPreset: WhiteBalancePreset,
        requestID: UInt64
    ) {
        let traceID = "WB-\(requestID)"
        let wbStartedAt = ProcessInfo.processInfo.systemUptime
        guard whiteBalanceRequests.isLatest(requestID),
              !movieOutput.isRecording, !recordingState.requestsRecording,
              !lensTransitionCoordinator.hasActiveTransition else {
            AppEventLog.guardRejected("applyWhiteBalanceRequest", reason: "stale or camera busy", traceID: traceID, fields: [
                "latestID": String(whiteBalanceRequests.current()), "requestID": String(requestID),
                "movieRecording": String(movieOutput.isRecording), "recordingRequested": String(recordingState.requestsRecording),
                "lensTransition": String(lensTransitionCoordinator.hasActiveTransition)
            ])
            return
        }
        guard session.isRunning, !session.isInterrupted else {
            deferWhiteBalanceRequest(
                id: requestID,
                preset: preset,
                previousPreset: previousPreset
            )
            return
        }

        deferredWhiteBalanceRequest = nil
        requestedWhiteBalancePreset = preset
        let currentDevice = videoInput?.device
        // Slo-Mo always uses a physical HFR camera. Rear 4K60 may use Apple's
        // Dual-Wide/Triple virtual camera while WB is Auto, but manual WB must move to a
        // physical constituent so locked temperature/tint is applied to the real capture input.
        let modeRequiresPhysicalInput = cameraPosition == .back && captureMode == .sloMo
        let needsInputSwap = cameraPosition == .back && !modeRequiresPhysicalInput && (
            (preset != .auto && currentDevice?.isVirtualDevice == true) ||
            (preset == .auto && currentDevice?.isVirtualDevice == false)
        )
        AppEventLog.deepEvent("WB APPLY DECISION", category: .whiteBalance, traceID: traceID, fields: [
            "preset": preset.rawValue, "previousPreset": previousPreset.rawValue,
            "device": currentDevice?.localizedName ?? "none", "virtualDevice": String(currentDevice?.isVirtualDevice ?? false),
            "needsInputSwap": String(needsInputSwap), "mode": captureMode.rawValue
        ])

        // Manual-to-manual (or any front-camera WB change) only needs a device WB update.
        // Do not rebuild/reapply the whole capture format for a color-temperature change.
        if !needsInputSwap {
            if applyWhiteBalancePresetToCurrentCamera(preset) {
                publish {
                    self.whiteBalancePreset = preset
                    self.isPreviewTransitioning = false
                }
                let device = self.videoInput?.device
                let gains = device?.deviceWhiteBalanceGains
                AppEventLog.event("White balance applied: \(preset.rawValue)", category: .whiteBalance, traceID: traceID, fields: [
                    "device": device?.localizedName ?? "none",
                    "mode": device.map { String(describing: $0.whiteBalanceMode) } ?? "none",
                    "redGain": gains.map { String(format: "%.3f", $0.redGain) } ?? "none",
                    "greenGain": gains.map { String(format: "%.3f", $0.greenGain) } ?? "none",
                    "blueGain": gains.map { String(format: "%.3f", $0.blueGain) } ?? "none",
                    "totalMs": String(format: "%.2f", (ProcessInfo.processInfo.systemUptime - wbStartedAt) * 1000)
                ])
            } else {
                requestedWhiteBalancePreset = previousPreset
                _ = applyWhiteBalancePresetToCurrentCamera(previousPreset)
                publish {
                    self.whiteBalancePreset = previousPreset
                    self.isPreviewTransitioning = false
                }
                showError(preset == .auto
                    ? "Couldn’t enable Auto white balance."
                    : "Manual white balance isn’t available on this lens.")
            }
            return
        }

        // Rear Auto <-> manual requires a virtual/physical input handoff. Freeze the
        // current preview first, then perform exactly one atomic input+format change.
        publish { self.isPreviewTransitioning = true }
        sessionQueue.asyncAfter(deadline: .now() + 0.045) { [weak self] in
            guard let self, self.whiteBalanceRequests.isLatest(requestID) else { return }
            guard self.session.isRunning, !self.session.isInterrupted else {
                self.deferWhiteBalanceRequest(
                    id: requestID,
                    preset: preset,
                    previousPreset: previousPreset
                )
                return
            }

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
            } else {
                let device = self.videoInput?.device
                AppEventLog.event("White balance applied after camera handoff: \(preset.rawValue)", category: .whiteBalance, traceID: traceID, fields: [
                    "device": device?.localizedName ?? "none",
                    "virtualDevice": String(device?.isVirtualDevice ?? false),
                    "mode": device.map { String(describing: $0.whiteBalanceMode) } ?? "none",
                    "totalMs": String(format: "%.2f", (ProcessInfo.processInfo.systemUptime - wbStartedAt) * 1000)
                ])
            }

            DispatchQueue.main.asyncAfter(deadline: .now() + 0.12) { [weak self] in
                guard let self, self.whiteBalanceRequests.isLatest(requestID) else { return }
                self.isPreviewTransitioning = false
            }
        }
    }



    /// Returns whether a specific resolution/FPS pair is available on the currently selected
    /// front/rear camera. The Settings UI uses this instead of combining two independent support
    /// lists, which could otherwise display a pair that no single AVCaptureDevice.Format supports.
    func supportedVideoFormatPairs() -> [(VideoResolution, VideoFrameRate)] {
        let devices = capabilityDevices(for: cameraPosition.avPosition)
        let resolutions: [VideoResolution] = [.p720, .p1080, .p4k]
        return resolutions.flatMap { resolution in
            VideoFrameRate.allCases.compactMap { frameRate in
                let needsHEVCPromotion = isKnownUnsupportedH264VideoSelection(
                    codec: selectedVideoCodec,
                    resolution: resolution,
                    frameRate: frameRate
                )
                let effectiveCodec = needsHEVCPromotion ? "HEVC" : selectedVideoCodec
                let selector = CameraFormatSelector(
                    selectedVideoCodec: effectiveCodec,
                    selectedResolution: resolution,
                    selectedFrameRate: frameRate
                )
                let supported = devices.contains { device in
                    selector.preferredRecordingFormat(
                        for: device,
                        resolution: resolution,
                        rate: frameRate
                    ) != nil
                }
                return supported ? (resolution, frameRate) : nil
            }
        }
    }

    func isVideoFormatSupported(resolution: VideoResolution, frameRate: VideoFrameRate) -> Bool {
        supportedVideoFormatPairs().contains {
            $0.0 == resolution && $0.1 == frameRate
        }
    }

    /// Applies a Video resolution and FPS as one user request. This prevents the new Settings list
    /// from producing an unnecessary intermediate camera configuration (for example 4K30 before
    /// the requested 4K60). When Video is not the active capture mode, the choice is saved for the
    /// next time Video is opened without reconfiguring the active Photo/Slo-Mo pipeline.
    func selectVideoFormat(resolution: VideoResolution, frameRate: VideoFrameRate) {
        guard !isRecording,
              !isRecordingStarting,
              !isFinalizingRecording,
              !isCapturingPhoto,
              !isLensTransitioning else { return }
        guard isVideoFormatSupported(resolution: resolution, frameRate: frameRate) else { return }

        var promotedCodec = false
        if isKnownUnsupportedH264VideoSelection(
            codec: selectedVideoCodec,
            resolution: resolution,
            frameRate: frameRate
        ) {
            let wasSuppressing = suppressAutomaticReconfiguration
            suppressAutomaticReconfiguration = true
            selectedVideoCodec = "HEVC"
            suppressAutomaticReconfiguration = wasSuppressing
            codecAvailabilityMessage = nil
            promotedCodec = true
            AppEventLog.event("Video codec promoted automatically: H264 -> HEVC for Settings format selection \(resolution.rawValue) \(frameRate.rawValue) fps")
        }

        guard selectedResolution != resolution || selectedFrameRate != frameRate || promotedCodec else { return }
        AppEventLog.event(
            "Video format requested from Settings: \(selectedResolution.rawValue)/\(selectedFrameRate.rawValue) fps -> \(resolution.rawValue)/\(frameRate.rawValue) fps"
        )
        codecAvailabilityMessage = nil

        let wasSuppressingPersistence = suppressPreferencePersistence
        suppressPreferencePersistence = true
        selectedResolution = resolution
        selectedFrameRate = frameRate
        suppressPreferencePersistence = wasSuppressingPersistence
        persistCameraPreferences()

        guard captureMode == .video else {
            AppEventLog.event("Video format saved for later; active mode=\(captureMode.rawValue)")
            return
        }

        let transitionID = qualityPreviewTransitions.next()
        isPreviewTransitioning = true
        scheduleVideoConfiguration(
            formatAffecting: true,
            qualityRequestID: qualityRequests.next(),
            compressionRequestID: compressionRequests.current(),
            transitionID: transitionID
        )
    }

    /// Pair-aware Slo-Mo capability check used by the Settings UI. Slo-Mo always uses HEVC in
    /// LowPolyCam, so this deliberately ignores the saved normal-Video codec preference.
    func supportedSlowMotionFormatPairs() -> [(VideoResolution, SlowMotionFrameRate)] {
        let devices = capabilityDevices(for: cameraPosition.avPosition)
        let selector = CameraFormatSelector(
            selectedVideoCodec: "HEVC",
            selectedResolution: selectedResolution,
            selectedFrameRate: selectedFrameRate
        )
        let resolutions: [VideoResolution] = [.p720, .p1080, .p4k]
        return resolutions.flatMap { resolution in
            SlowMotionFrameRate.allCases.compactMap { frameRate in
                let selection = selector.slowMotionFormatSelection(
                    for: devices,
                    requestedResolution: resolution,
                    requestedFrameRate: frameRate
                )
                let supported = selection.resolution == resolution &&
                    selection.frameRate == frameRate &&
                    !selection.supportedDevices.isEmpty
                return supported ? (resolution, frameRate) : nil
            }
        }
    }

    func isSlowMotionFormatSupported(
        resolution: VideoResolution,
        frameRate: SlowMotionFrameRate
    ) -> Bool {
        supportedSlowMotionFormatPairs().contains {
            $0.0 == resolution && $0.1 == frameRate
        }
    }

    /// Applies a Slo-Mo resolution/FPS pair as a single request. Like the Video equivalent, this
    /// only touches active capture hardware when Slo-Mo is currently open; otherwise it persists
    /// the preference for the next Slo-Mo session.
    func selectSlowMotionFormat(
        resolution: VideoResolution,
        frameRate: SlowMotionFrameRate
    ) {
        guard !isRecording,
              !isRecordingStarting,
              !isFinalizingRecording,
              !isCapturingPhoto,
              !isLensTransitioning else { return }
        guard isSlowMotionFormatSupported(resolution: resolution, frameRate: frameRate) else { return }
        guard selectedSlowMotionResolution != resolution || selectedSlowMotionFrameRate != frameRate else { return }

        AppEventLog.event(
            "Slo-Mo format requested from Settings: \(selectedSlowMotionResolution.rawValue)/\(selectedSlowMotionFrameRate.rawValue) fps -> \(resolution.rawValue)/\(frameRate.rawValue) fps"
        )

        let wasSuppressingPersistence = suppressPreferencePersistence
        suppressPreferencePersistence = true
        selectedSlowMotionResolution = resolution
        selectedSlowMotionFrameRate = frameRate
        suppressPreferencePersistence = wasSuppressingPersistence
        persistCameraPreferences()

        guard captureMode == .sloMo else {
            AppEventLog.event("Slo-Mo format saved for later; active mode=\(captureMode.rawValue)")
            return
        }

        let transitionID = qualityPreviewTransitions.next()
        isPreviewTransitioning = true
        let request = SlowMotionQualityRequest(
            id: qualityRequests.next(),
            resolution: resolution,
            frameRate: frameRate,
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



    func selectResolution(_ resolution: VideoResolution) {
        guard captureMode == .video, !isRecording, !isRecordingStarting, !isFinalizingRecording, !isLensTransitioning else { return }
        guard isVideoResolutionSupported(resolution) else { return }
        let promotedCodec = autoPromoteH264ForUnsupportedVideoSelection(
            position: cameraPosition,
            resolution: resolution,
            frameRate: selectedFrameRate
        )
        guard selectedResolution != resolution || promotedCodec else { return }
        AppEventLog.event("Video resolution requested: \(selectedResolution.rawValue) to \(resolution.rawValue)")
        codecAvailabilityMessage = nil
        selectedResolution = resolution
        let transitionID = qualityPreviewTransitions.next()
        isPreviewTransitioning = true
        scheduleVideoConfiguration(
            formatAffecting: true,
            qualityRequestID: qualityRequests.next(),
            compressionRequestID: compressionRequests.current(),
            transitionID: transitionID
        )
    }

    func selectFrameRate(_ frameRate: VideoFrameRate) {
        guard captureMode == .video, !isRecording, !isRecordingStarting, !isFinalizingRecording, !isLensTransitioning else { return }
        guard isVideoFrameRateSupported(frameRate) else { return }
        guard selectedFrameRate != frameRate else { return }
        AppEventLog.event("Video frame rate requested: \(selectedFrameRate.rawValue) to \(frameRate.rawValue)")
        codecAvailabilityMessage = nil
        selectedFrameRate = frameRate
        let transitionID = qualityPreviewTransitions.next()
        isPreviewTransitioning = true
        scheduleVideoConfiguration(
            formatAffecting: true,
            qualityRequestID: qualityRequests.next(),
            compressionRequestID: compressionRequests.current(),
            transitionID: transitionID
        )
    }

    func selectSlowMotionResolution(_ resolution: VideoResolution) {
        guard captureMode == .sloMo, !isRecording, !isRecordingStarting, !isFinalizingRecording, !isLensTransitioning else { return }
        guard isSlowMotionResolutionSupported(resolution) else { return }
        guard selectedSlowMotionResolution != resolution else { return }
        AppEventLog.event("Slo-Mo resolution requested: \(selectedSlowMotionResolution.rawValue) to \(resolution.rawValue)")
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
        guard isSlowMotionFrameRateSupported(frameRate) else { return }
        guard selectedSlowMotionFrameRate != frameRate else { return }
        AppEventLog.event("Slo-Mo frame rate requested: \(selectedSlowMotionFrameRate.rawValue) to \(frameRate.rawValue)")
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
        AppEventLog.event("Video stabilization requested: \(isVideoStabilizationEnabled) -> \(enabled)")
        isVideoStabilizationEnabled = enabled
        guard captureMode == .video else {
            AppEventLog.event("Video stabilization saved; no active Video format to reconfigure")
            return
        }
        sessionQueue.async { [weak self] in self?.configureMovieOutputSettings() }
    }

    func refreshMovieOutputSettings() {
        sessionQueue.async { [weak self] in
            guard let self, !self.movieOutput.isRecording else { return }
            _ = self.configureMovieOutputSettings()
        }
    }

    func toggleRecordingPause() {
        sessionQueue.async { [weak self] in
            guard let self else { return }
            self.toggleRecordingPauseOnSessionQueue()
        }
    }

    private func toggleRecordingPauseOnSessionQueue() {
        guard captureMode == .video || captureMode == .sloMo else {
            AppEventLog.guardRejected("toggleRecordingPause", reason: "capture mode is not recordable", traceID: activeRecordingTraceID)
            return
        }
        guard case .recording(_) = recordingState, movieOutput.isRecording else {
            AppEventLog.guardRejected("toggleRecordingPause", reason: "recording is not actively writing", traceID: activeRecordingTraceID, fields: [
                "recordingState": String(describing: recordingState),
                "movieOutput.isRecording": String(movieOutput.isRecording),
                "movieOutput.isRecordingPaused": String(movieOutput.isRecordingPaused),
                "pauseState": recordingPauseMachine.state.rawValue
            ])
            return
        }

        switch recordingPauseMachine.state {
        case .recording:
            guard !movieOutput.isRecordingPaused else {
                AppEventLog.guardRejected("toggleRecordingPause", reason: "native output is already paused", traceID: activeRecordingTraceID)
                return
            }
            guard recordingPauseMachine.requestPause() else {
                AppEventLog.guardRejected("toggleRecordingPause", reason: "pause transition rejected", traceID: activeRecordingTraceID)
                return
            }
            let requestID = recordingPauseRequests.next(reason: "native pause requested")
            let requestedAt = ProcessInfo.processInfo.systemUptime
            pendingRecordingPauseRequest = RecordingPauseRequest(
                id: requestID,
                operation: .pause,
                stateBefore: .recording,
                traceID: activeRecordingTraceID,
                requestedAt: requestedAt
            )
            publish { self.recordingPauseState = .pausing }
            AppEventLog.event(
                "RECORDING PAUSE REQUEST",
                category: .recording,
                traceID: activeRecordingTraceID,
                fields: recordingPauseLogFields(
                    requestID: requestID,
                    traceID: activeRecordingTraceID,
                    stateBefore: .recording,
                    stateAfter: recordingPauseMachine.state,
                    recordingStateBefore: String(describing: recordingState),
                    recordingStateAfter: String(describing: recordingState),
                    recordedDuration: movieOutput.recordedDuration.seconds,
                    recordingClockElapsed: recordingClock.elapsedSeconds,
                    movieIsRecording: movieOutput.isRecording,
                    movieIsPaused: movieOutput.isRecordingPaused,
                    requestedAt: requestedAt
                )
            )
            movieOutput.pauseRecording()

        case .paused:
            guard movieOutput.isRecordingPaused else {
                AppEventLog.guardRejected("toggleRecordingPause", reason: "native output is not paused", traceID: activeRecordingTraceID)
                return
            }
            guard recordingPauseMachine.requestResume() else {
                AppEventLog.guardRejected("toggleRecordingPause", reason: "resume transition rejected", traceID: activeRecordingTraceID)
                return
            }
            let requestID = recordingPauseRequests.next(reason: "native resume requested")
            let requestedAt = ProcessInfo.processInfo.systemUptime
            pendingRecordingPauseRequest = RecordingPauseRequest(
                id: requestID,
                operation: .resume,
                stateBefore: .paused,
                traceID: activeRecordingTraceID,
                requestedAt: requestedAt
            )
            publish { self.recordingPauseState = .resuming }
            AppEventLog.event(
                "RECORDING RESUME REQUEST",
                category: .recording,
                traceID: activeRecordingTraceID,
                fields: recordingPauseLogFields(
                    requestID: requestID,
                    traceID: activeRecordingTraceID,
                    stateBefore: .paused,
                    stateAfter: recordingPauseMachine.state,
                    recordingStateBefore: String(describing: recordingState),
                    recordingStateAfter: String(describing: recordingState),
                    recordedDuration: movieOutput.recordedDuration.seconds,
                    recordingClockElapsed: recordingClock.elapsedSeconds,
                    movieIsRecording: movieOutput.isRecording,
                    movieIsPaused: movieOutput.isRecordingPaused,
                    requestedAt: requestedAt
                )
            )
            movieOutput.resumeRecording()

        case .idle, .pausing, .resuming, .stopping:
            AppEventLog.guardRejected("toggleRecordingPause", reason: "pause/resume transition already in flight or stopping", traceID: activeRecordingTraceID, fields: [
                "pauseState": recordingPauseMachine.state.rawValue
            ])
        }
    }

    private func handleNativeRecordingPaused(_ output: AVCaptureFileOutput, fileURL: URL) {
        guard output === movieOutput,
              let request = pendingRecordingPauseRequest,
              case .pause = request.operation,
              recordingPauseRequests.isLatest(request.id),
              recordingPauseMachine.state == .pausing,
              movieOutput.isRecording,
              movieOutput.isRecordingPaused else {
            AppEventLog.guardRejected("didPauseRecording", reason: "stale or invalid native pause callback", traceID: activeRecordingTraceID, fields: [
                "file": fileURL.lastPathComponent,
                "requestID": pendingRecordingPauseRequest.map { String($0.id) } ?? "none",
                "latestID": String(recordingPauseRequests.current()),
                "pauseState": recordingPauseMachine.state.rawValue,
                "movieOutput.isRecording": String(movieOutput.isRecording),
                "movieOutput.isRecordingPaused": String(movieOutput.isRecordingPaused)
            ])
            return
        }

        let stateBefore = recordingPauseMachine.state
        guard recordingPauseMachine.confirmPaused() else { return }
        pendingRecordingPauseRequest = nil
        cancelSplitTimer()
        let fields = recordingPauseLogFields(
            requestID: request.id,
            traceID: request.traceID,
            stateBefore: stateBefore,
            stateAfter: recordingPauseMachine.state,
            recordingStateBefore: String(describing: recordingState),
            recordingStateAfter: String(describing: recordingState),
            recordedDuration: movieOutput.recordedDuration.seconds,
            recordingClockElapsed: recordingClock.elapsedSeconds,
            movieIsRecording: movieOutput.isRecording,
            movieIsPaused: movieOutput.isRecordingPaused,
            requestedAt: request.requestedAt,
            file: fileURL.lastPathComponent
        )
        publish {
            self.recordingClock.pause()
            var actualFields = fields
            actualFields["recordingClockElapsed"] = String(format: "%.0f", self.recordingClock.elapsedSeconds)
            self.recordingPauseState = .paused
            AppEventLog.event("RECORDING PAUSED", category: .recording, traceID: request.traceID, fields: actualFields)
        }
    }

    private func handleNativeRecordingResumed(_ output: AVCaptureFileOutput, fileURL: URL) {
        guard output === movieOutput,
              let request = pendingRecordingPauseRequest,
              case .resume = request.operation,
              recordingPauseRequests.isLatest(request.id),
              recordingPauseMachine.state == .resuming,
              movieOutput.isRecording,
              !movieOutput.isRecordingPaused else {
            AppEventLog.guardRejected("didResumeRecording", reason: "stale or invalid native resume callback", traceID: activeRecordingTraceID, fields: [
                "file": fileURL.lastPathComponent,
                "requestID": pendingRecordingPauseRequest.map { String($0.id) } ?? "none",
                "latestID": String(recordingPauseRequests.current()),
                "pauseState": recordingPauseMachine.state.rawValue,
                "movieOutput.isRecording": String(movieOutput.isRecording),
                "movieOutput.isRecordingPaused": String(movieOutput.isRecordingPaused)
            ])
            return
        }

        let stateBefore = recordingPauseMachine.state
        guard recordingPauseMachine.confirmResumed() else { return }
        pendingRecordingPauseRequest = nil
        let fields = recordingPauseLogFields(
            requestID: request.id,
            traceID: request.traceID,
            stateBefore: stateBefore,
            stateAfter: recordingPauseMachine.state,
            recordingStateBefore: String(describing: recordingState),
            recordingStateAfter: String(describing: recordingState),
            recordedDuration: movieOutput.recordedDuration.seconds,
            recordingClockElapsed: recordingClock.elapsedSeconds,
            movieIsRecording: movieOutput.isRecording,
            movieIsPaused: movieOutput.isRecordingPaused,
            requestedAt: request.requestedAt,
            file: fileURL.lastPathComponent
        )
        publish {
            self.recordingClock.resume()
            var actualFields = fields
            actualFields["recordingClockElapsed"] = String(format: "%.0f", self.recordingClock.elapsedSeconds)
            self.recordingPauseState = .recording
            AppEventLog.event("RECORDING RESUMED", category: .recording, traceID: request.traceID, fields: actualFields)
        }
        let splitDuration = recordingState.splitDuration
        if splitDuration > 0 {
            scheduleSplitTimer(splitDuration: splitDuration)
        }
    }

    private func requestNativeRecordingStop(reason: String) {
        pendingRecordingPauseRequest = nil
        _ = recordingPauseRequests.next(reason: reason)
        if recordingPauseMachine.state != .idle && recordingPauseMachine.state != .stopping {
            _ = recordingPauseMachine.requestStop()
        }
        let state = recordingPauseMachine.state
        publish { self.recordingPauseState = state }
    }

    private func completeNativeRecordingStop(reason: String) {
        pendingRecordingPauseRequest = nil
        _ = recordingPauseRequests.next(reason: reason)
        _ = recordingPauseMachine.completeStop()
        recordingPauseMachine.reset()
        publish { self.recordingPauseState = .idle }
    }

    private func resetNativeRecordingPauseState(reason: String) {
        pendingRecordingPauseRequest = nil
        _ = recordingPauseRequests.next(reason: reason)
        recordingPauseMachine.reset()
        publish { self.recordingPauseState = .idle }
    }

    private func recordingPauseLogFields(
        requestID: UInt64,
        traceID: String?,
        stateBefore: RecordingPauseState,
        stateAfter: RecordingPauseState,
        recordingStateBefore: String,
        recordingStateAfter: String,
        recordedDuration: Double,
        recordingClockElapsed: Double,
        movieIsRecording: Bool,
        movieIsPaused: Bool,
        requestedAt: TimeInterval,
        file: String? = nil
    ) -> [String: String] {
        var fields: [String: String] = [
            "requestID": String(requestID),
            "traceID": traceID ?? "none",
            "recordingTraceID": traceID ?? "none",
            "stateBefore": stateBefore.rawValue,
            "stateAfter": stateAfter.rawValue,
            "recordingPauseStateBefore": stateBefore.rawValue,
            "recordingPauseStateAfter": stateAfter.rawValue,
            "recordingStateBefore": recordingStateBefore,
            "recordingStateAfter": recordingStateAfter,
            "movieOutput.isRecording": String(movieIsRecording),
            "movieOutput.isRecordingPaused": String(movieIsPaused),
            "recordedDuration": String(format: "%.3f", max(recordedDuration.isFinite ? recordedDuration : 0, 0)),
            "recordingClockElapsed": String(format: "%.0f", max(recordingClockElapsed.isFinite ? recordingClockElapsed : 0, 0)),
            "requestElapsedMs": String(format: "%.2f", max(0, ProcessInfo.processInfo.systemUptime - requestedAt) * 1000)
        ]
        if let file { fields["file"] = file }
        return fields
    }

    private func cancelSplitTimer() {
        segmentTimerGeneration &+= 1
        segmentTimer?.cancel()
        segmentTimer = nil
    }

    private func scheduleSplitTimer(splitDuration: Double) {
        cancelSplitTimer()
        guard splitDuration.isFinite, splitDuration > 0,
              recordingState.requestsRecording,
              movieOutput.isRecording else { return }

        let remaining = RecordingSplitTimingPolicy.remainingDuration(
            splitDuration: splitDuration,
            recordedDuration: movieOutput.recordedDuration.seconds
        )
        let delay = remaining > 0.05 ? remaining : 0.25
        let generation = segmentTimerGeneration
        let timer = DispatchWorkItem { [weak self] in
            guard let self, self.segmentTimerGeneration == generation else { return }
            self.handleSplitTimer(splitDuration: splitDuration)
        }
        segmentTimer = timer
        sessionQueue.asyncAfter(deadline: .now() + delay, execute: timer)
    }

    private func handleSplitTimer(splitDuration: Double) {
        guard recordingState.requestsRecording, movieOutput.isRecording else { return }
        guard recordingPauseMachine.state == .recording else {
            scheduleSplitTimer(splitDuration: splitDuration)
            return
        }

        let recordedDuration = movieOutput.recordedDuration.seconds
        guard RecordingSplitTimingPolicy.shouldSplit(
            splitDuration: splitDuration,
            recordedDuration: recordedDuration,
            pauseState: recordingPauseMachine.state
        ) else {
            scheduleSplitTimer(splitDuration: splitDuration)
            return
        }

        requestNativeRecordingStop(reason: "recording split timer")
        transitionRecordingState(to: .stoppingToContinueSegment(splitDuration: splitDuration))
        movieOutput.stopRecording()
    }

    private func compressionSelection(for mode: CaptureMode) -> (mode: CompressionMode, level: VideoCompression, manualBitrateMbps: Double) {
        if mode == .sloMo {
            return (slowMotionCompressionMode, slowMotionCompression, slowMotionManualBitrateMbps)
        }
        return (videoCompressionMode, videoCompression, videoManualBitrateMbps)
    }

    func compressionDescription(for mode: CaptureMode) -> String {
        let selection = compressionSelection(for: mode)
        if selection.mode == .manual {
            return "Manual \(String(format: "%.1f", selection.manualBitrateMbps)) Mbps"
        }
        return "Auto \(selection.level.rawValue)"
    }

    private func refreshCompressionOutputIfNeeded() {
        guard captureMode == .video || captureMode == .sloMo else { return }
        guard !isRecording, !isRecordingStarting, !isFinalizingRecording else { return }
        sessionQueue.async { [weak self] in
            guard let self, self.session.isRunning, !self.movieOutput.isRecording else { return }
            _ = self.configureMovieOutputSettings()
        }
    }

    func setVideoCompressionMode(_ mode: CompressionMode) {
        guard videoCompressionMode != mode else { return }
        videoCompressionMode = mode
        UserDefaults.standard.set(mode.rawValue, forKey: LowPolyCamPreferences.Key.videoCompressionMode)
        _ = compressionRequests.next(reason: "video compression mode")
        AppEventLog.event("Video compression mode changed: \(mode.rawValue)")
        refreshCompressionOutputIfNeeded()
    }

    func setVideoCompressionLevel(_ level: VideoCompression) {
        guard videoCompression != level else { return }
        videoCompression = level
        // Keep the historical key current for older installs and diagnostics.
        UserDefaults.standard.set(level.rawValue, forKey: LowPolyCamPreferences.Key.videoCompression)
    }

    func setVideoManualBitrateMbps(_ value: Double) {
        let validated = ManualBitratePolicy.validatedMbps(value, fallback: videoManualBitrateMbps)
        guard abs(videoManualBitrateMbps - validated) > 0.000_001 else { return }
        videoManualBitrateMbps = validated
        UserDefaults.standard.set(validated, forKey: LowPolyCamPreferences.Key.videoManualBitrateMbps)
        _ = compressionRequests.next(reason: "video manual bitrate")
        refreshCompressionOutputIfNeeded()
    }

    func setSlowMotionCompressionMode(_ mode: CompressionMode) {
        guard slowMotionCompressionMode != mode else { return }
        slowMotionCompressionMode = mode
        UserDefaults.standard.set(mode.rawValue, forKey: LowPolyCamPreferences.Key.slowMotionCompressionMode)
        _ = compressionRequests.next(reason: "Slo-Mo compression mode")
        refreshCompressionOutputIfNeeded()
    }

    func setSlowMotionCompressionLevel(_ level: VideoCompression) {
        guard slowMotionCompression != level else { return }
        slowMotionCompression = level
        UserDefaults.standard.set(level.rawValue, forKey: LowPolyCamPreferences.Key.slowMotionCompressionLevel)
        refreshCompressionOutputIfNeeded()
    }

    func setSlowMotionManualBitrateMbps(_ value: Double) {
        let validated = ManualBitratePolicy.validatedMbps(value, fallback: slowMotionManualBitrateMbps)
        guard abs(slowMotionManualBitrateMbps - validated) > 0.000_001 else { return }
        slowMotionManualBitrateMbps = validated
        UserDefaults.standard.set(validated, forKey: LowPolyCamPreferences.Key.slowMotionManualBitrateMbps)
        _ = compressionRequests.next(reason: "Slo-Mo manual bitrate")
        refreshCompressionOutputIfNeeded()
    }

    func setAudioLevelMeterMode(_ mode: AudioLevelMeterMode) {
        guard audioLevelMeterMode != mode else { return }
        let previousMode = audioLevelMeterMode
        audioLevelMeterMode = mode
        UserDefaults.standard.set(mode.rawValue, forKey: LowPolyCamPreferences.Key.audioLevelMeter)
        AppEventLog.event("Audio level meter mode changed: \(previousMode.rawValue) -> \(mode.rawValue)", category: .audio)
        sessionQueue.async { [weak self] in
            guard let self else { return }
            self.configureAudioMeterOutput()
            self.refreshLiveMetrics()
        }
    }

    func setZebraExposureWarningEnabled(_ enabled: Bool) {
        guard isZebraExposureWarningEnabled != enabled else { return }
        isZebraExposureWarningEnabled = enabled
        UserDefaults.standard.set(enabled, forKey: LowPolyCamPreferences.Key.zebraExposureWarning)
        AppEventLog.event(enabled ? "ZEBRA ENABLED" : "ZEBRA DISABLED", category: .exposure)
        sessionQueue.async { [weak self] in
            guard let self else { return }
            self.refreshLiveMetrics()
        }
    }

    func setCaptureOrientation(_ preference: CaptureOrientationPreference) {
        guard captureOrientation != preference else { return }
        captureOrientation = preference
        UserDefaults.standard.set(preference.rawValue, forKey: LowPolyCamPreferences.Key.captureOrientation)
        sessionQueue.async { [weak self] in
            guard let self else { return }
            let movieConnection = self.movieOutput.connection(with: .video)
            self.applyCaptureRotation(to: movieConnection)
            let photoConnection = self.photoOutput.connection(with: .video)
            self.applyCaptureRotation(to: photoConnection)
            AppEventLog.event("Capture orientation applied", category: .session, fields: [
                "requested": preference.rawValue,
                "movieRotationAngle": movieConnection.map { String(format: "%.1f", $0.videoRotationAngle) } ?? "unavailable",
                "photoRotationAngle": photoConnection.map { String(format: "%.1f", $0.videoRotationAngle) } ?? "unavailable"
            ])
        }
    }

    func setCustomWhiteBalance(temperature: Double, tint: Double) {
        let nextTemperature = WhiteBalancePreferencePolicy.validatedTemperature(temperature)
        let nextTint = WhiteBalancePreferencePolicy.validatedTint(tint)
        customWhiteBalanceTemperature = nextTemperature
        customWhiteBalanceTint = nextTint
        let defaults = UserDefaults.standard
        defaults.set(nextTemperature, forKey: LowPolyCamPreferences.Key.customWhiteBalanceTemperature)
        defaults.set(nextTint, forKey: LowPolyCamPreferences.Key.customWhiteBalanceTint)
        guard requestedWhiteBalancePreset == .custom else { return }
        selectWhiteBalancePreset(.custom)
    }

    func setTorchBrightness(_ level: Double) {
        let validated = min(max(level.isFinite ? level : 0.35, 0.05), 1.0)
        guard abs(torchBrightnessLevel - validated) > 0.000_001 else { return }
        torchBrightnessLevel = validated
        UserDefaults.standard.set(validated, forKey: LowPolyCamPreferences.Key.torchBrightness)
        AppEventLog.event("TORCH BRIGHTNESS REQUEST", category: .torch, fields: [
            "requestedLevel": String(format: "%.3f", validated),
            "device": videoInput?.device.localizedName ?? "none"
        ])
        sessionQueue.async { [weak self] in
            guard let self, self.isTorchOn else { return }
            self.setTorchEnabledOnCurrentDevice(true)
        }
    }

    var zoomShortcuts: [Double] {
        zoomShortcutValues
    }

    func setZoomShortcuts(_ values: [Double], count requestedCount: Int? = nil) {
        var validated = ZoomShortcutPolicy.validated(values)
        let targetCount = min(max(requestedCount ?? validated.count, 3), 5)
        for fallback in ZoomShortcutPolicy.defaultValues + [8.0] where validated.count < targetCount {
            guard !validated.contains(where: { abs($0 - fallback) < 0.0001 }) else { continue }
            validated.append(fallback)
        }
        let padded = Array(validated.prefix(targetCount))
        let defaults = UserDefaults.standard
        let keys = [
            LowPolyCamPreferences.Key.zoomButton1,
            LowPolyCamPreferences.Key.zoomButton2,
            LowPolyCamPreferences.Key.zoomButton3,
            LowPolyCamPreferences.Key.zoomButton4,
            LowPolyCamPreferences.Key.zoomButton5
        ]
        for (index, key) in keys.enumerated() {
            let fallback = ZoomShortcutPolicy.defaultValues.indices.contains(index)
                ? ZoomShortcutPolicy.defaultValues[index]
                : 8.0
            defaults.set(padded.indices.contains(index) ? padded[index] : fallback, forKey: key)
        }
        defaults.set(targetCount, forKey: LowPolyCamPreferences.Key.zoomButtonCount)
        zoomShortcutValues = padded.isEmpty ? Array(ZoomShortcutPolicy.defaultValues.prefix(targetCount)) : padded
        AppEventLog.event("Zoom shortcut buttons updated", category: .zoom, fields: [
            "values": padded.map { String(format: "%.2f", $0) }.joined(separator: ",")
        ])
    }

    private static func loadZoomShortcutValues(from defaults: UserDefaults) -> [Double] {
        let storedCount = defaults.integer(forKey: LowPolyCamPreferences.Key.zoomButtonCount)
        let count = [3, 4, 5].contains(storedCount) ? storedCount : 4
        let values = [
            defaults.object(forKey: LowPolyCamPreferences.Key.zoomButton1) as? NSNumber,
            defaults.object(forKey: LowPolyCamPreferences.Key.zoomButton2) as? NSNumber,
            defaults.object(forKey: LowPolyCamPreferences.Key.zoomButton3) as? NSNumber,
            defaults.object(forKey: LowPolyCamPreferences.Key.zoomButton4) as? NSNumber,
            defaults.object(forKey: LowPolyCamPreferences.Key.zoomButton5) as? NSNumber
        ].prefix(count).compactMap { $0?.doubleValue }
        var validated = ZoomShortcutPolicy.validated(values)
        for fallback in ZoomShortcutPolicy.defaultValues + [8.0] where validated.count < count {
            guard !validated.contains(where: { abs($0 - fallback) < 0.0001 }) else { continue }
            validated.append(fallback)
        }
        return validated.isEmpty ? Array(ZoomShortcutPolicy.defaultValues.prefix(count)) : Array(validated.prefix(count))
    }

    func resetTemporaryCameraControls() {
        AppEventLog.event("Quick camera reset requested", category: .session, fields: [
            "exposureBiasBefore": String(format: "%.2f", exposureBias),
            "zoomBefore": String(format: "%.2f", Double(zoomFactor)),
            "whiteBalanceBefore": requestedWhiteBalancePreset.rawValue,
            "torchBefore": String(isTorchOn)
        ])
        setExposureBias(0)
        setZoomFactor(1)
        selectWhiteBalancePreset(.auto)
        sessionQueue.async { [weak self] in
            guard let self else { return }
            self.resetFocusAndExposureState()
            self.setTorchEnabledOnCurrentDevice(false)
            self.postStatus("Temporary camera controls reset")
        }
    }

    func makeCameraPreset(named name: String) -> CameraPreset {
        CameraPreset(
            name: name,
            captureMode: captureMode.rawValue,
            videoResolution: selectedResolution.rawValue,
            videoFrameRate: selectedFrameRate.rawValue,
            slowMotionResolution: selectedSlowMotionResolution.rawValue,
            slowMotionFrameRate: selectedSlowMotionFrameRate.rawValue,
            codec: selectedVideoCodec,
            videoCompressionMode: videoCompressionMode.rawValue,
            videoCompressionLevel: videoCompression.rawValue,
            videoManualBitrateMbps: videoManualBitrateMbps,
            slowMotionCompressionMode: slowMotionCompressionMode.rawValue,
            slowMotionCompressionLevel: slowMotionCompression.rawValue,
            slowMotionManualBitrateMbps: slowMotionManualBitrateMbps,
            zoom: Double(requestedZoom),
            stabilization: isVideoStabilizationEnabled,
            whiteBalance: requestedWhiteBalancePreset.rawValue,
            customWhiteBalanceTemperature: customWhiteBalanceTemperature,
            customWhiteBalanceTint: customWhiteBalanceTint,
            cameraPosition: cameraPosition.rawValue
        )
    }

    func applyCameraPreset(_ preset: CameraPreset, completion: ((Bool) -> Void)? = nil) {
        let migrated = preset.migrated()
        guard !isRecording, !isRecordingStarting, !isFinalizingRecording,
              !isCapturingPhoto, !isLensTransitioning else {
            completion?(false)
            return
        }
        let targetPosition = CameraPosition(rawValue: migrated.cameraPosition) ?? cameraPosition
        if targetPosition != cameraPosition {
            switchCamera()
            sessionQueue.asyncAfter(deadline: .now() + 0.6) { [weak self] in
                self?.applyCameraPresetOnSessionQueue(migrated, completion: completion)
            }
        } else {
            sessionQueue.async { [weak self] in
                self?.applyCameraPresetOnSessionQueue(migrated, completion: completion)
            }
        }
    }

    private func applyCameraPresetOnSessionQueue(_ preset: CameraPreset, completion: ((Bool) -> Void)?) {
        guard cameraPosition.rawValue == preset.cameraPosition || preset.cameraPosition.isEmpty else {
            completion?(false)
            return
        }
        guard let targetMode = CaptureMode(rawValue: preset.captureMode) else {
            completion?(false)
            return
        }

        invalidatePendingVideoConfiguration()
        lensTransitionCoordinator.cancel()
        _ = qualityRequests.next(reason: "custom camera preset")
        _ = captureConfigurationGeneration.next(reason: "custom camera preset")
        let previousSuppression = suppressAutomaticReconfiguration
        let previousPersistenceSuppression = suppressPreferencePersistence
        suppressAutomaticReconfiguration = true
        suppressPreferencePersistence = true
        captureMode = targetMode
        selectedResolution = VideoResolution(rawValue: preset.videoResolution) ?? .p1080
        selectedFrameRate = VideoFrameRate(rawValue: preset.videoFrameRate) ?? .fps60
        selectedSlowMotionResolution = VideoResolution(rawValue: preset.slowMotionResolution) ?? .p1080
        selectedSlowMotionFrameRate = SlowMotionFrameRate(rawValue: preset.slowMotionFrameRate) ?? .fps240
        selectedVideoCodec = preset.codec == "H264" ? "H264" : "HEVC"
        videoCompressionMode = CompressionMode(rawValue: preset.videoCompressionMode) ?? .auto
        videoCompression = VideoCompression(rawValue: preset.videoCompressionLevel) ?? .high
        videoManualBitrateMbps = ManualBitratePolicy.validatedMbps(preset.videoManualBitrateMbps)
        slowMotionCompressionMode = CompressionMode(rawValue: preset.slowMotionCompressionMode) ?? .auto
        slowMotionCompression = VideoCompression(rawValue: preset.slowMotionCompressionLevel) ?? .high
        slowMotionManualBitrateMbps = ManualBitratePolicy.validatedMbps(preset.slowMotionManualBitrateMbps)
        isVideoStabilizationEnabled = preset.stabilization
        customWhiteBalanceTemperature = WhiteBalancePreferencePolicy.validatedTemperature(preset.customWhiteBalanceTemperature)
        customWhiteBalanceTint = WhiteBalancePreferencePolicy.validatedTint(preset.customWhiteBalanceTint)
        requestedWhiteBalancePreset = WhiteBalancePreset(rawValue: preset.whiteBalance) ?? .auto
        whiteBalancePreset = requestedWhiteBalancePreset
        requestedZoom = CGFloat(preset.zoom.isFinite ? max(preset.zoom, 0.5) : 1)
        suppressAutomaticReconfiguration = previousSuppression
        suppressPreferencePersistence = previousPersistenceSuppression

        let defaults = UserDefaults.standard
        defaults.set(videoCompressionMode.rawValue, forKey: LowPolyCamPreferences.Key.videoCompressionMode)
        defaults.set(videoCompression.rawValue, forKey: LowPolyCamPreferences.Key.videoCompression)
        defaults.set(videoManualBitrateMbps, forKey: LowPolyCamPreferences.Key.videoManualBitrateMbps)
        defaults.set(slowMotionCompressionMode.rawValue, forKey: LowPolyCamPreferences.Key.slowMotionCompressionMode)
        defaults.set(slowMotionCompression.rawValue, forKey: LowPolyCamPreferences.Key.slowMotionCompressionLevel)
        defaults.set(slowMotionManualBitrateMbps, forKey: LowPolyCamPreferences.Key.slowMotionManualBitrateMbps)
        defaults.set(selectedVideoCodec, forKey: LowPolyCamPreferences.Key.selectedVideoCodec)
        defaults.set(isVideoStabilizationEnabled, forKey: LowPolyCamPreferences.Key.videoStabilizationEnabled)
        defaults.set(requestedWhiteBalancePreset.rawValue, forKey: LowPolyCamPreferences.Key.whiteBalancePreset)
        defaults.set(customWhiteBalanceTemperature, forKey: LowPolyCamPreferences.Key.customWhiteBalanceTemperature)
        defaults.set(customWhiteBalanceTint, forKey: LowPolyCamPreferences.Key.customWhiteBalanceTint)
        persistCameraPreferences()

        let success = applyActiveModeFormat(preferVirtualCamera: !requiresPhysicalWhiteBalanceInput)
        if success {
            synchronizeTorchState()
            synchronizeWhiteBalanceAfterConfiguration()
            persistRememberedCameraSetup()
            AppEventLog.event("Custom camera preset applied", category: .settings, fields: [
                "name": preset.name, "mode": preset.captureMode, "position": preset.cameraPosition
            ])
        } else {
            AppEventLog.event("Custom camera preset failed to apply", category: .settings, level: .warning, fields: [
                "name": preset.name, "mode": preset.captureMode, "position": preset.cameraPosition
            ])
        }
        publish { completion?(success) }
    }

    private func prepareMicrophoneAndBeginRecording() {
        guard recordingState.requestsRecording else { return }
        let requestID = microphonePermissionRequests.next(reason: "prepare microphone for recording")
        let authorization = AVCaptureDevice.authorizationStatus(for: .audio)
        AppEventLog.deepEvent("MICROPHONE PREPARATION", category: .audio, traceID: activeRecordingTraceID, fields: [
            "requestID": String(requestID), "authorization": String(authorization.rawValue),
            "audioInputAttached": String(audioInput != nil)
        ])

        if authorization == .notDetermined {
            awaitingMicrophonePermission = true
            microphonePermissionPromptLifecyclePending = true
            publishAudioStatus()
            AppEventLog.event("Microphone permission requested lazily before recording")
            AVCaptureDevice.requestAccess(for: .audio) { [weak self] granted in
                self?.sessionQueue.async { [weak self] in
                    self?.finishMicrophonePermission(
                        granted: granted,
                        requestID: requestID
                    )
                }
            }
            return
        }

        let attached = authorization == .authorized && attachAudioInputIfAuthorized()
        publishAudioStatus()
        AppEventLog.event(
            "Microphone authorization before recording: state=\(authorization.rawValue), attached=\(attached)"
        )
        if authorization != .authorized {
            postStatus("Recording without audio · microphone access is off")
        } else if !attached {
            postStatus("Microphone unavailable · recording without audio")
        }
        beginRecording()
    }

    private func finishMicrophonePermission(granted: Bool, requestID: UInt64) {
        guard microphonePermissionRequests.isLatest(requestID),
              awaitingMicrophonePermission,
              recordingState.requestsRecording,
              appLifecyclePhase == .active,
              session.isRunning,
              captureMode == .video || captureMode == .sloMo else {
            AppEventLog.event("Stale microphone permission completion dropped: granted=\(granted)")
            return
        }

        awaitingMicrophonePermission = false

        // Keep the lifecycle suppression armed briefly after the permission callback because
        // iOS may enqueue the permission sheet's .inactive notification after this callback.
        // If no lifecycle bounce arrives, expire the guard so an unrelated later inactive event
        // is never suppressed.
        let permissionLifecycleRequestID = requestID
        sessionQueue.asyncAfter(deadline: .now() + 1.0) { [weak self] in
            guard let self,
                  self.microphonePermissionPromptLifecyclePending,
                  self.microphonePermissionRequests.isLatest(permissionLifecycleRequestID) else { return }
            self.microphonePermissionPromptLifecyclePending = false
            AppEventLog.deepEvent("MICROPHONE PERMISSION LIFECYCLE GUARD EXPIRED", category: .audio, fields: [
                "requestID": String(permissionLifecycleRequestID)
            ])
        }

        let attached = granted && attachAudioInputIfAuthorized()
        publishAudioStatus()
        AppEventLog.event("Microphone permission result: granted=\(granted), audioInputAttached=\(attached)")
        if !granted {
            postStatus("Microphone access denied · recording without audio")
        } else if !attached {
            postStatus("Microphone unavailable · recording without audio")
        }
        beginRecording()
    }

    func startOrStopRecording() {
        guard captureMode == .video || captureMode == .sloMo else {
            AppEventLog.guardRejected("startOrStopRecording", reason: "capture mode is not recordable", fields: ["mode": captureMode.rawValue])
            return
        }
        let queueTicket = AppEventLog.queueScheduled("record button action", category: .recording, traceID: activeRecordingTraceID)
        sessionQueue.async { [weak self] in
            AppEventLog.queueStarted(queueTicket)
            guard let self else { return }
            guard !self.recordingState.isFinalizing else {
                AppEventLog.guardRejected("startOrStopRecording", reason: "recording is finalizing", traceID: self.activeRecordingTraceID)
                return
            }

            if self.recordingState.requestsRecording {
                AppEventLog.event("Recording stop requested", category: .recording, traceID: self.activeRecordingTraceID,
                                  fields: ["movieOutputRecording": String(self.movieOutput.isRecording),
                                           "state": String(describing: self.recordingState)])
                self.requestNativeRecordingStop(reason: "user requested recording stop")
                let wasWaitingForMicrophone = self.awaitingMicrophonePermission
                _ = self.recordingStartRequests.next(reason: "user requested recording stop")
                _ = self.microphonePermissionRequests.next(reason: "recording stop invalidates microphone request")
                self.awaitingMicrophonePermission = false
                self.microphonePermissionPromptLifecyclePending = false
                self.storageGuard.stopMonitoring()
                self.stopLiveMetrics()
                self.cancelSplitTimer()

                if self.movieOutput.isRecording {
                    self.transitionRecordingState(to: .finalizing, resetClock: true)
                    self.postStatus("Saving to Photos…")
                    self.movieOutput.stopRecording()
                } else if wasWaitingForMicrophone {
                    self.transitionRecordingState(to: .idle, resetClock: true)
                    self.closeRecordingDiagnostics(reason: "cancelled while waiting for microphone", result: "cancelled")
                } else {
                    // A second tap arrived while AVCaptureMovieFileOutput was still starting.
                    // If didStart arrives later, stop and discard that canceled startup clip.
                    self.transitionRecordingToDiscard(resetClock: true)
                }
                return
            }

            guard !self.isCapturingPhoto, !self.lensTransitionCoordinator.hasActiveTransition else {
                AppEventLog.guardRejected("recording start", reason: "camera busy", fields: [
                    "capturingPhoto": String(self.isCapturingPhoto),
                    "lensTransition": String(self.lensTransitionCoordinator.hasActiveTransition)
                ])
                return
            }
            self.resetNativeRecordingPauseState(reason: "new recording session")
            self.activeRecordingTraceID = AppEventLog.makeTraceID("RECORD")
            self.activeRecordingSessionID = UUID().uuidString
            self.recordingRequestStartedAt = ProcessInfo.processInfo.systemUptime
            self.recordingSegmentIndex = 1
            self.lastExtremeRecordingHealthSecond = -1
            let traceID = self.activeRecordingTraceID
            AppEventLog.event("========== RECORDING START REQUEST =========", category: .recording, traceID: traceID, fields: [
                "mode": self.captureMode.rawValue,
                "resolution": self.hudResolutionLabel,
                "fps": self.hudFrameRateLabel ?? "unknown",
                "codec": self.activeVideoCodec,
                "compression": self.compressionDescription(for: self.captureMode),
                "camera": self.cameraPosition.rawValue,
                "device": self.videoInput?.device.localizedName ?? "none",
                "requestedZoom": String(format: "%.3f", self.requestedZoom)
            ])
            let splitDuration = Double(UserDefaults.standard.integer(forKey: "splitMinutes")) * 60
            self.storageProtectionStopIssued = false
            self.transitionRecordingState(
                to: .starting(splitDuration: splitDuration),
                resetClock: true,
                clearLastFrameGaps: true
            )
            self.prepareMicrophoneAndBeginRecording()
        }
    }

    func applyQuickPreset(_ preset: VideoQuickPreset, completion: ((Bool) -> Void)? = nil) {
        guard captureMode == .video, !isRecording, !isRecordingStarting, !isCapturingPhoto, !isLensTransitioning else {
            AppEventLog.event("Quick preset ignored: \(preset.rawValue), camera busy or not in Video mode")
            completion?(false)
            return
        }

        AppEventLog.event("Quick preset requested: \(preset.rawValue), \(preset.resolution.rawValue) \(preset.frameRate.rawValue) fps, codec=HEVC, compression=\(preset.compression.rawValue)")

        sessionQueue.async { [weak self] in
            guard let self else { return }
            self.invalidatePendingVideoConfiguration()
            self.lensTransitionCoordinator.cancel()
            let devices = self.capabilityDevices(for: self.cameraPosition.avPosition)
            let presetSelector = CameraFormatSelector(
                selectedVideoCodec: "HEVC",
                selectedResolution: preset.resolution,
                selectedFrameRate: preset.frameRate
            )
            let supported = devices.contains { device in
                presetSelector.preferredRecordingFormat(
                    for: device,
                    resolution: preset.resolution,
                    rate: preset.frameRate
                ) != nil
            }
            let hevcAvailable = self.movieOutput.connection(with: .video).map {
                self.movieOutputSupportsCodec(.hevc, on: $0)
            } ?? false
            guard supported && hevcAvailable else {
                let message = hevcAvailable
                    ? "This preset isn’t supported by the current camera."
                    : "HEVC is unavailable for the current camera configuration."
                self.publish { self.codecAvailabilityMessage = message }
                self.showError(message)
                self.publish { completion?(false) }
                return
            }

            _ = self.qualityRequests.next()
            _ = self.captureConfigurationGeneration.next()

            self.publish {
                self.suppressPreferencePersistence = true
                self.suppressAutomaticReconfiguration = true
                self.selectedResolution = preset.resolution
                self.selectedFrameRate = preset.frameRate
                self.videoCompressionMode = .auto
                self.videoCompression = preset.compression
                self.selectedVideoCodec = "HEVC"
                self.suppressPreferencePersistence = false
                self.suppressAutomaticReconfiguration = false
                self.persistCameraPreferences()

                self.sessionQueue.async {
                    let success = self.applySelectedFormat(
                        preferVirtualCamera: !self.requiresPhysicalWhiteBalanceInput
                    )
                    AppEventLog.event("Quick preset \(success ? "applied" : "failed"): \(preset.rawValue)")
                    self.publish { completion?(success) }
                }
            }
        }
    }

    private func makeAuthorizedAudioInput() -> AVCaptureDeviceInput? {
        guard AVCaptureDevice.authorizationStatus(for: .audio) == .authorized,
              let audioDevice = AVCaptureDevice.default(for: .audio) else { return nil }
        return try? AVCaptureDeviceInput(device: audioDevice)
    }

    private func currentAudioStatusLabel() -> String {
        if audioInput != nil { return "Microphone" }
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .notDetermined: return "Checking microphone"
        case .denied, .restricted: return "Microphone off"
        case .authorized: return "Microphone unavailable"
        @unknown default: return "Microphone unavailable"
        }
    }

    private func publishAudioStatus() {
        let label = currentAudioStatusLabel()
        publish {
            guard self.audioStatusLabel != label else { return }
            self.audioStatusLabel = label
            if label != "Microphone" {
                AppEventLog.event("Audio unavailable state: \(label)", category: .audio)
            }
        }
    }

    /// Called only on sessionQueue. Lazy microphone permission can grant audio after the initial
    /// camera session has already been built, so the input can be attached in a small transaction.
    @discardableResult
    private func attachAudioInputIfAuthorized() -> Bool {
        guard AVCaptureDevice.authorizationStatus(for: .audio) == .authorized else {
            publishAudioStatus()
            return false
        }
        if let existingAudioInput = audioInput,
           session.inputs.contains(where: { $0 === existingAudioInput }) {
            configureAudioMeterOutput()
            publishAudioStatus()
            return true
        }
        guard let newInput = makeAuthorizedAudioInput(), session.canAddInput(newInput) else {
            AppEventLog.event("Microphone audio input attach failed: unavailable or session rejected input")
            publishAudioStatus()
            return false
        }
        session.beginConfiguration()
        session.addInput(newInput)
        session.commitConfiguration()
        audioInput = newInput
        configureAudioMeterOutput()
        AppEventLog.event("Microphone audio input attached: \(newInput.device.localizedName)")
        publishAudioStatus()
        return true
    }

    private func audioMeterOutputIsAttached() -> Bool {
        session.outputs.contains { $0 === audioMeter.output }
    }

    private func audioMeterShouldBeEnabled() -> Bool {
        audioMeterOutputIsAttached() &&
            audioInput != nil &&
            captureMode != .photo &&
            audioLevelMeterMode != .off &&
            recordingState.requestsRecording &&
            movieOutput.isRecording
    }

    /// The audio-data output is optional and disabled outside an active recording. It reads the
    /// same authorized microphone input as the movie output and never creates a parallel recorder.
    private func configureAudioMeterOutput() {
        let wanted = audioInput != nil && captureMode != .photo && audioLevelMeterMode != .off
        let attached = audioMeterOutputIsAttached()
        if wanted != attached {
            session.beginConfiguration()
            if wanted, session.canAddOutput(audioMeter.output) {
                session.addOutput(audioMeter.output)
            } else if !wanted, attached {
                audioMeter.setEnabled(false)
                session.removeOutput(audioMeter.output)
            }
            session.commitConfiguration()
        }
        let available = audioMeterOutputIsAttached()
        let enabled = available && audioMeterShouldBeEnabled()
        audioMeter.output.connection(with: .audio)?.isEnabled = enabled
        audioMeter.setEnabled(enabled)
        AppEventLog.deepEvent("AUDIO LEVEL METER OUTPUT", category: .audio, fields: [
            "wanted": String(wanted), "attached": String(available), "enabled": String(enabled)
        ])
    }

    private func configureSessionIfNeeded(forceRebuild: Bool = false) {
        let hasVideo = videoInput.map { current in
            session.inputs.contains(where: { $0 === current })
        } ?? false
        let hasMovie = session.outputs.contains(where: { $0 === movieOutput })
        let hasPhoto = session.outputs.contains(where: { $0 === photoOutput })
        if !forceRebuild, hasVideo, hasMovie, hasPhoto {
            publishAudioStatus()
            configureAudioMeterOutput()
            configureZebraAnalysis()
            return
        }

        invalidateVerifiedHighOutputProvenance()
        invalidateCodecSupportCache()
        AppEventLog.event("Configuring camera session\(forceRebuild ? " rebuild" : "")")

        invalidatePendingVideoConfiguration()
        lensTransitionCoordinator.cancel()
        _ = qualityRequests.next()
        _ = captureConfigurationGeneration.next()
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
        audioInput = nil
        audioMeter.setEnabled(false)
        publishAudioStatus()

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
        if let input = makeAuthorizedAudioInput(), session.canAddInput(input) {
            session.addInput(input)
            audioInput = input
            AppEventLog.event("Microphone audio input attached during session configuration")
            publishAudioStatus()
        } else {
            AppEventLog.event("Microphone audio input not attached during session configuration: authorization=\(AVCaptureDevice.authorizationStatus(for: .audio).rawValue)")
            publishAudioStatus()
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
        configureAudioMeterOutput()

        let formatApplied = applyActiveModeFormat(preferVirtualCamera: !requiresPhysicalWhiteBalanceInput)
        if formatApplied {
            deferredWhiteBalanceRequest = nil
        }
        synchronizeTorchState()
        AppEventLog.event("Camera session configured")
        logSessionSnapshot("after session configuration")
    }







    @discardableResult
    private func applyAtomicCaptureConfiguration(
        device desiredDevice: AVCaptureDevice,
        format: AVCaptureDevice.Format,
        frameRate: Double,
        photoDimensions: CMVideoDimensions? = nil,
        preparedReplacementInput: AVCaptureDeviceInput? = nil,
        refreshAuxiliaryOutputs: Bool = true,
        requestedCodec: String? = nil
    ) -> CGFloat? {
        let transactionTrace = AppEventLog.extremeDiagnosticsEnabled ? AppEventLog.makeTraceID("CAPTURE-TX") : nil
        let transactionStart = ProcessInfo.processInfo.systemUptime
        let oldDeviceForTrace = videoInput?.device
        let oldDimensionsForTrace = oldDeviceForTrace.map { CMVideoFormatDescriptionGetDimensions($0.activeFormat.formatDescription) }
        let oldFPSForTrace: Double = oldDeviceForTrace.map {
            let duration = $0.activeVideoMinFrameDuration.seconds
            return duration > 0 ? 1 / duration : 0
        } ?? 0
        let beforeTraceState: [String: String] = [
            "device": oldDeviceForTrace?.localizedName ?? "none",
            "format": oldDimensionsForTrace.map { "\($0.width)x\($0.height)" } ?? "none",
            "fps": String(format: "%.2f", oldFPSForTrace),
            "deviceZoom": oldDeviceForTrace.map { String(format: "%.3f", Double($0.videoZoomFactor)) } ?? "none",
            "requestedZoom": String(format: "%.3f", Double(requestedZoom)),
            "inputs": String(session.inputs.count),
            "outputs": String(session.outputs.count)
        ]
        let targetDimensionsForTrace = CMVideoFormatDescriptionGetDimensions(format.formatDescription)
        AppEventLog.deepEvent("CAPTURE TRANSACTION REQUEST", category: .session, traceID: transactionTrace, fields: [
            "targetDevice": desiredDevice.localizedName,
            "targetFormat": "\(targetDimensionsForTrace.width)x\(targetDimensionsForTrace.height)",
            "targetFPS": String(format: "%.2f", frameRate),
            "photoDimensions": photoDimensions.map { "\($0.width)x\($0.height)" } ?? "none",
            "requestedCodec": requestedCodec ?? activeVideoCodec,
            "refreshAuxiliaryOutputs": String(refreshAuxiliaryOutputs)
        ])
        let effectiveCodec = requestedCodec ?? activeVideoCodec
        let currentInput = videoInput
        let displayedZoomCandidate = snappedZoomFactor(requestedZoom, for: desiredDevice)
        let targetDeviceZoomCandidate = deviceZoomFactor(for: displayedZoomCandidate, device: desiredDevice)
        let activeMinDuration = desiredDevice.activeVideoMinFrameDuration.seconds
        let activeMaxDuration = desiredDevice.activeVideoMaxFrameDuration.seconds
        let activeMinFrameRate = activeMinDuration > 0 ? 1 / activeMinDuration : 0
        let activeMaxFrameRate = activeMaxDuration > 0 ? 1 / activeMaxDuration : 0
        let sameInput = currentInput?.device.uniqueID == desiredDevice.uniqueID
        let sameFormat = desiredDevice.activeFormat === format
        // A fixed requested rate requires BOTH AVFoundation duration bounds to match. Checking only
        // activeVideoMinFrameDuration can mistake a variable-FPS range for a settled fixed rate.
        let sameFrameRate = abs(activeMinFrameRate - frameRate) < 0.5 &&
            abs(activeMaxFrameRate - frameRate) < 0.5
        let samePhotoDimensions = photoDimensions.map { dimensions in
            photoOutput.maxPhotoDimensions.width == dimensions.width &&
                photoOutput.maxPhotoDimensions.height == dimensions.height
        } ?? true
        let auxiliaryGraphChangeNeeded = refreshAuxiliaryOutputs &&
            liveMetricsAttachmentWanted() != liveMetricsOutputIsAttached()
        let baseOutputsPresent = session.outputs.contains(where: { $0 === movieOutput }) &&
            session.outputs.contains(where: { $0 === photoOutput })

        // Most AVFoundation latency in the diagnostic session came from commitConfiguration().
        // If the capture graph/format/FPS is already exactly what was requested, do not open a
        // no-op session transaction just to re-assert zoom/HDR device properties. Those properties
        // can be updated directly under the AVCaptureDevice configuration lock.
        if sameInput, sameFormat, sameFrameRate, samePhotoDimensions,
           !auxiliaryGraphChangeNeeded, baseOutputsPresent {
            let desiredAutoHDR = effectiveCodec != "H264"
            let needsDeviceUpdate =
                abs(desiredDevice.videoZoomFactor - targetDeviceZoomCandidate) >= 0.005 ||
                desiredDevice.automaticallyAdjustsVideoHDREnabled != desiredAutoHDR ||
                (effectiveCodec == "H264" && desiredDevice.isVideoHDREnabled) ||
                (desiredDevice.isGeometricDistortionCorrectionSupported &&
                    !desiredDevice.isGeometricDistortionCorrectionEnabled)

            if needsDeviceUpdate {
                do {
                    try desiredDevice.lockForConfiguration()
                    desiredDevice.automaticallyAdjustsVideoHDREnabled = desiredAutoHDR
                    if effectiveCodec == "H264", desiredDevice.isVideoHDREnabled {
                        desiredDevice.isVideoHDREnabled = false
                    }
                    if desiredDevice.isGeometricDistortionCorrectionSupported {
                        desiredDevice.isGeometricDistortionCorrectionEnabled = true
                    }
                    desiredDevice.cancelVideoZoomRamp()
                    desiredDevice.videoZoomFactor = targetDeviceZoomCandidate
                    desiredDevice.unlockForConfiguration()
                } catch {
                    AppEventLog.log(error: error, prefix: "CAPTURE FAST PATH DEVICE UPDATE FAILED", category: .device, traceID: transactionTrace)
                    // Fall through to the normal atomic transaction, which retains the existing
                    // rollback/error behavior for a device that could not be updated directly.
                }
            }

            let zoomMatches = abs(desiredDevice.videoZoomFactor - targetDeviceZoomCandidate) < 0.02
            let hdrMatches = desiredDevice.automaticallyAdjustsVideoHDREnabled == desiredAutoHDR &&
                (effectiveCodec != "H264" || !desiredDevice.isVideoHDREnabled)
            let distortionMatches = !desiredDevice.isGeometricDistortionCorrectionSupported ||
                desiredDevice.isGeometricDistortionCorrectionEnabled
            if zoomMatches, hdrMatches, distortionMatches {
                setLiveMetricsConnectionEnabled(
                    (recordingState.requestsRecording && movieOutput.isRecording) ||
                    ((AppEventLog.extremeDiagnosticsEnabled || isZebraExposureWarningEnabled) &&
                        liveMetricsOutputIsAttached() && captureMode != .photo)
                )
                rotationCoordinator = AVCaptureDevice.RotationCoordinator(device: desiredDevice, previewLayer: nil)
                requestedZoom = displayedZoomCandidate
                AppEventLog.deepEvent("CAPTURE TRANSACTION FAST PATH", category: .session, traceID: transactionTrace, fields: [
                    "device": desiredDevice.localizedName,
                    "format": "\(targetDimensionsForTrace.width)x\(targetDimensionsForTrace.height)",
                    "fps": String(format: "%.2f", activeMinFrameRate),
                    "displayedZoom": String(format: "%.3f", Double(displayedZoomCandidate)),
                    "reason": "capture graph already matched request",
                    "totalMs": String(format: "%.2f", (ProcessInfo.processInfo.systemUptime - transactionStart) * 1000)
                ])
                return displayedZoomCandidate
            }
        }

        // A real input/format/output transaction makes proof from the previous capture graph
        // unusable, including attempts that fail before AVFoundation accepts the replacement.
        invalidateVerifiedHighOutputProvenance()
        let oldInput = currentInput
        let shouldPreserveTorch = oldInput?.device.hasTorch == true && oldInput?.device.torchMode == .on
        let isSwitchingInput = oldInput?.device.uniqueID != desiredDevice.uniqueID
        let torchRequestID = torchRequests.next(reason: "capture configuration transaction")
        let shouldRetryTorchAfterPreviewHandoff = shouldPreserveTorch &&
            isSwitchingInput &&
            captureMode == .video &&
            cameraPosition == .back &&
            selectedResolution == .p4k &&
            selectedFrameRate == .fps60 &&
            !recordingState.requestsRecording &&
            !movieOutput.isRecording
        var replacementInput: AVCaptureDeviceInput?
        var torchRestoreDevice: AVCaptureDevice?

        func restoreSuspendedTorchIfPossible() {
            guard let device = torchRestoreDevice else { return }
            do {
                try device.lockForConfiguration()
                defer { device.unlockForConfiguration() }
                guard device.hasTorch, device.isTorchAvailable else {
                    AppEventLog.event("Torch could not be restored after camera input switch: unavailable on \(device.localizedName)")
                    return
                }
                do {
                    let maximumTorchLevel = max(device.maxAvailableTorchLevel, 0.05)
                    let requestedTorchLevel = min(
                        max(Float(self.torchBrightnessLevel) * maximumTorchLevel, min(0.05, maximumTorchLevel)),
                        maximumTorchLevel
                    )
                    try device.setTorchModeOn(level: requestedTorchLevel)
                } catch {
                    device.torchMode = .on
                }
                AppEventLog.event("Torch restored after camera input switch on \(device.localizedName)", category: .torch, fields: [
                    "requestedLevel": String(format: "%.3f", self.torchBrightnessLevel),
                    "actualLevel": String(format: "%.3f", device.torchLevel),
                    "device": device.localizedName
                ])
            } catch {
                AppEventLog.event("Torch could not be restored after camera input switch: \(error.localizedDescription)")
            }
        }

        if isSwitchingInput {
            if let preparedReplacementInput,
               preparedReplacementInput.device.uniqueID == desiredDevice.uniqueID {
                replacementInput = preparedReplacementInput
            } else {
                do {
                    let inputStart = ProcessInfo.processInfo.systemUptime
                    replacementInput = try AVCaptureDeviceInput(device: desiredDevice)
                    AppEventLog.deepEvent("CAPTURE TX REPLACEMENT INPUT CREATED", category: .device, traceID: transactionTrace, fields: [
                        "device": desiredDevice.localizedName,
                        "durationMs": String(format: "%.2f", (ProcessInfo.processInfo.systemUptime - inputStart) * 1000)
                    ])
                } catch {
                    AppEventLog.log(error: error, prefix: "CAPTURE TX REPLACEMENT INPUT FAILED", category: .device, traceID: transactionTrace)
                    showError("Couldn’t access the selected camera.")
                    return nil
                }
            }
        }

        // Keeping the old device's torch active while removing that input can leave the physical
        // camera resource occupied as the replacement input starts. Device logs showed that exact
        // sequence interrupting the session during rear 4K60 lens handoffs. Suspend the torch
        // before the transaction and restore it only after commit, on whichever input survived.
        if isSwitchingInput, shouldPreserveTorch, let oldDevice = oldInput?.device {
            do {
                try oldDevice.lockForConfiguration()
                defer { oldDevice.unlockForConfiguration() }
                oldDevice.torchMode = .off
                torchRestoreDevice = oldDevice
                AppEventLog.event("Torch suspended before camera input switch from \(oldDevice.localizedName) to \(desiredDevice.localizedName)")
            } catch {
                AppEventLog.event("Camera input switch cancelled because the active torch could not be suspended: \(error.localizedDescription)")
                showError("Couldn’t safely switch cameras while the torch is on.")
                return nil
            }
        }

        let beginConfigurationAt = ProcessInfo.processInfo.systemUptime
        session.beginConfiguration()
        AppEventLog.deepEvent("SESSION beginConfiguration", category: .session, traceID: transactionTrace, fields: [
            "elapsedMs": String(format: "%.2f", (ProcessInfo.processInfo.systemUptime - transactionStart) * 1000),
            "switchingInput": String(isSwitchingInput)
        ])
        var committed = false
        if refreshAuxiliaryOutputs {
            configureLiveMetrics()
        }
        defer {
            if !committed {
                let fallbackCommitStart = ProcessInfo.processInfo.systemUptime
                session.commitConfiguration()
                AppEventLog.deepEvent("SESSION fallback commitConfiguration", category: .session, level: .warning, traceID: transactionTrace, fields: [
                    "durationMs": String(format: "%.2f", (ProcessInfo.processInfo.systemUptime - fallbackCommitStart) * 1000)
                ])
            }
            restoreSuspendedTorchIfPossible()
            if committed, shouldRetryTorchAfterPreviewHandoff {
                scheduleTorchRestoreAfterLensHandoff(on: desiredDevice, requestID: torchRequestID)
            }
        }

        if isSwitchingInput {
            if let oldInput { session.removeInput(oldInput) }
            guard let replacementInput, session.canAddInput(replacementInput) else {
                AppEventLog.guardRejected("capture transaction input replacement", reason: "session cannot add replacement input", traceID: transactionTrace, fields: [
                    "targetDevice": desiredDevice.localizedName,
                    "oldDevice": oldInput?.device.localizedName ?? "none"
                ])
                if let oldInput, session.canAddInput(oldInput) {
                    session.addInput(oldInput)
                    videoInput = oldInput
                } else {
                    torchRestoreDevice = nil
                }
                return nil
            }
            session.addInput(replacementInput)
            videoInput = replacementInput
        }

        let displayedZoom = snappedZoomFactor(requestedZoom, for: desiredDevice)
        do {
            let lockRequestedAt = ProcessInfo.processInfo.systemUptime
            try desiredDevice.lockForConfiguration()
            let lockWaitMs = (ProcessInfo.processInfo.systemUptime - lockRequestedAt) * 1000
            AppEventLog.deepEvent("DEVICE LOCK ACQUIRED", category: .device, traceID: transactionTrace, fields: [
                "device": desiredDevice.localizedName,
                "waitMs": String(format: "%.2f", lockWaitMs)
            ])
            if lockWaitMs > 100 {
                AppEventLog.event("SLOW DEVICE LOCK", category: .performance, level: .warning, traceID: transactionTrace,
                                  fields: ["waitMs": String(format: "%.2f", lockWaitMs), "device": desiredDevice.localizedName])
            }
            do {
                let lockHeldAt = ProcessInfo.processInfo.systemUptime
                defer {
                    let heldMs = (ProcessInfo.processInfo.systemUptime - lockHeldAt) * 1000
                    desiredDevice.unlockForConfiguration()
                    AppEventLog.deepEvent("DEVICE LOCK RELEASED", category: .device, traceID: transactionTrace,
                                          fields: ["heldMs": String(format: "%.2f", heldMs)])
                }

                desiredDevice.activeFormat = format
                desiredDevice.automaticallyAdjustsVideoHDREnabled = effectiveCodec != "H264"
                if effectiveCodec == "H264", desiredDevice.isVideoHDREnabled {
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

                desiredDevice.cancelVideoZoomRamp()
                desiredDevice.videoZoomFactor = deviceZoomFactor(for: displayedZoom, device: desiredDevice)
                if shouldPreserveTorch, !isSwitchingInput,
                   desiredDevice.hasTorch, desiredDevice.isTorchAvailable {
                    do {
                        let maximumTorchLevel = max(desiredDevice.maxAvailableTorchLevel, 0.05)
                        let requestedTorchLevel = min(
                            max(Float(torchBrightnessLevel) * maximumTorchLevel, min(0.05, maximumTorchLevel)),
                            maximumTorchLevel
                        )
                        try desiredDevice.setTorchModeOn(level: requestedTorchLevel)
                    } catch {
                        desiredDevice.torchMode = .on
                    }
                }
            }

            if let photoDimensions,
               (photoOutput.maxPhotoDimensions.width != photoDimensions.width ||
                photoOutput.maxPhotoDimensions.height != photoDimensions.height) {
                photoOutput.maxPhotoDimensions = photoDimensions
            }

            let commitStart = ProcessInfo.processInfo.systemUptime
            session.commitConfiguration()
            let commitMs = (ProcessInfo.processInfo.systemUptime - commitStart) * 1000
            committed = true
            AppEventLog.deepEvent("SESSION commitConfiguration", category: .session, traceID: transactionTrace, fields: [
                "commitMs": String(format: "%.2f", commitMs),
                "transactionMs": String(format: "%.2f", (ProcessInfo.processInfo.systemUptime - transactionStart) * 1000),
                "beginToCommitMs": String(format: "%.2f", (ProcessInfo.processInfo.systemUptime - beginConfigurationAt) * 1000)
            ])
            if commitMs > 250 {
                AppEventLog.event("SLOW SESSION COMMIT", category: .performance, level: .warning, traceID: transactionTrace,
                                  fields: ["commitMs": String(format: "%.2f", commitMs)])
            }
            setLiveMetricsConnectionEnabled(
                (recordingState.requestsRecording && movieOutput.isRecording) ||
                ((AppEventLog.extremeDiagnosticsEnabled || isZebraExposureWarningEnabled) &&
                    liveMetricsOutputIsAttached() && captureMode != .photo)
            )
            rotationCoordinator = AVCaptureDevice.RotationCoordinator(device: desiredDevice, previewLayer: nil)
            requestedZoom = displayedZoom
            if shouldPreserveTorch, isSwitchingInput {
                torchRestoreDevice = desiredDevice
            }
            let afterDimensions = CMVideoFormatDescriptionGetDimensions(desiredDevice.activeFormat.formatDescription)
            let afterDuration = desiredDevice.activeVideoMinFrameDuration.seconds
            let afterFPS = afterDuration > 0 ? 1 / afterDuration : 0
            let afterTraceState: [String: String] = [
                "device": desiredDevice.localizedName,
                "format": "\(afterDimensions.width)x\(afterDimensions.height)",
                "fps": String(format: "%.2f", afterFPS),
                "deviceZoom": String(format: "%.3f", Double(desiredDevice.videoZoomFactor)),
                "requestedZoom": String(format: "%.3f", Double(displayedZoom)),
                "inputs": String(session.inputs.count),
                "outputs": String(session.outputs.count)
            ]
            AppEventLog.stateDiff("CAPTURE TRANSACTION", before: beforeTraceState, after: afterTraceState,
                                  traceID: transactionTrace, category: .session)
            AppEventLog.deepEvent("CAPTURE TRANSACTION COMPLETE", category: .session, traceID: transactionTrace, fields: [
                "totalMs": String(format: "%.2f", (ProcessInfo.processInfo.systemUptime - transactionStart) * 1000),
                "displayedZoom": String(format: "%.3f", Double(displayedZoom))
            ])
            return displayedZoom
        } catch {
            if isSwitchingInput {
                if let replacementInput, session.inputs.contains(where: { $0 === replacementInput }) {
                    session.removeInput(replacementInput)
                }
                if let oldInput, session.canAddInput(oldInput) {
                    session.addInput(oldInput)
                    videoInput = oldInput
                } else {
                    torchRestoreDevice = nil
                }
            }
            AppEventLog.log(error: error, prefix: "CAPTURE TRANSACTION FAILED", category: .session, traceID: transactionTrace)
            showError("Couldn’t configure the selected camera format.")
            return nil
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

    private func resetFocusAndExposureState() {
        _ = focusExposureRequests.next(reason: "focus/exposure reset")
        pendingFocusLockWorkItem?.cancel()
        pendingFocusLockWorkItem = nil
        pendingFocusReturnWorkItem?.cancel()
        pendingFocusReturnWorkItem = nil
        focusLockedInHardware = false
        exposureLockedInHardware = false
        guard let device = videoInput?.device else {
            publish { self.isFocusExposureLocked = false }
            return
        }

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
        let traceID = AppEventLog.extremeDiagnosticsEnabled ? AppEventLog.makeTraceID("WBHW") : nil
        let lockRequestedAt = ProcessInfo.processInfo.systemUptime
        do {
            try device.lockForConfiguration()
            let lockAcquiredAt = ProcessInfo.processInfo.systemUptime
            let beforeGains = device.deviceWhiteBalanceGains
            AppEventLog.deepEvent("WB DEVICE LOCK ACQUIRED", category: .whiteBalance, traceID: traceID, fields: [
                "device": device.localizedName,
                "waitMs": String(format: "%.3f", (lockAcquiredAt - lockRequestedAt) * 1000),
                "modeBefore": String(describing: device.whiteBalanceMode),
                "beforeR": String(format: "%.3f", beforeGains.redGain),
                "beforeG": String(format: "%.3f", beforeGains.greenGain),
                "beforeB": String(format: "%.3f", beforeGains.blueGain)
            ])
            defer {
                let afterGains = device.deviceWhiteBalanceGains
                device.unlockForConfiguration()
                AppEventLog.deepEvent("WB DEVICE UNLOCK", category: .whiteBalance, traceID: traceID, fields: [
                    "heldMs": String(format: "%.3f", (ProcessInfo.processInfo.systemUptime - lockAcquiredAt) * 1000),
                    "modeAfter": String(describing: device.whiteBalanceMode),
                    "afterR": String(format: "%.3f", afterGains.redGain),
                    "afterG": String(format: "%.3f", afterGains.greenGain),
                    "afterB": String(format: "%.3f", afterGains.blueGain)
                ])
            }

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

            guard device.isWhiteBalanceModeSupported(.locked),
                  device.isLockingWhiteBalanceWithCustomDeviceGainsSupported else {
                return false
            }

            let temperature: Float
            let tint: Float
            if preset == .custom {
                temperature = Float(WhiteBalancePreferencePolicy.validatedTemperature(customWhiteBalanceTemperature))
                tint = Float(WhiteBalancePreferencePolicy.validatedTint(customWhiteBalanceTint))
            } else if let presetTemperature = preset.temperature {
                temperature = presetTemperature
                tint = preset.tint
            } else {
                return false
            }

            // Convert to device gains and clamp before applying. The temperature/tint setter can
            // raise an Objective-C range exception for values a particular lens rejects; Swift
            // do/catch cannot recover from that exception. iPhone 11 supports custom gains.
            let values = AVCaptureDevice.WhiteBalanceTemperatureAndTintValues(temperature: temperature, tint: tint)
            var gains = device.deviceWhiteBalanceGains(for: values)
            let maximum = device.maxWhiteBalanceGain
            gains.redGain = min(max(gains.redGain, 1), maximum)
            gains.greenGain = min(max(gains.greenGain, 1), maximum)
            gains.blueGain = min(max(gains.blueGain, 1), maximum)
            AppEventLog.deepEvent("WB LOCKED GAINS TARGET", category: .whiteBalance, traceID: traceID, fields: [
                "preset": preset.rawValue,
                "temperature": String(format: "%.1f", temperature),
                "tint": String(format: "%.1f", tint),
                "red": String(format: "%.3f", gains.redGain),
                "green": String(format: "%.3f", gains.greenGain),
                "blue": String(format: "%.3f", gains.blueGain),
                "maxGain": String(format: "%.3f", maximum)
            ])
            device.setWhiteBalanceModeLocked(with: gains, completionHandler: nil)
            return true
        } catch {
            AppEventLog.log(error: error, prefix: "White balance device configuration failed", category: .whiteBalance, traceID: traceID)
            return false
        }
    }

    private func configureFocusAndExposure(at point: CGPoint, lockAfterFocusing: Bool, requestID: UInt64) {
        guard focusExposureRequests.isLatest(requestID),
              let device = videoInput?.device else { return }
        pendingFocusLockWorkItem?.cancel()
        pendingFocusReturnWorkItem?.cancel()
        pendingFocusLockWorkItem = nil
        pendingFocusReturnWorkItem = nil
        focusLockedInHardware = false
        exposureLockedInHardware = false

        let clampedPoint = CGPoint(
            x: min(max(point.x, 0), 1),
            y: min(max(point.y, 0), 1)
        )
        let defaults = UserDefaults.standard
        let lockPreference = defaults.string(forKey: LowPolyCamPreferences.Key.focusExposureLockMode) ?? "AE/AF"
        let wantsFocusLock = lockPreference != "AE Only"
        let wantsExposureLock = lockPreference != "AF Only"

        do {
            try device.lockForConfiguration()
            defer { device.unlockForConfiguration() }

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
        } catch {
            showError("Couldn’t set focus and exposure.")
            return
        }

        publish { self.isFocusExposureLocked = false }
        AppEventLog.event(
            "Focus/exposure applied: point=(\(String(format: "%.3f", clampedPoint.x)), \(String(format: "%.3f", clampedPoint.y))), lock requested=\(lockAfterFocusing), preference=\(lockPreference)"
        )

        let deviceID = device.uniqueID

        if lockAfterFocusing {
            // Wait only for controls we can and actually intend to lock. On fixed-focus cameras
            // (for example an ultra-wide without AF), AE can still lock independently.
            let deadline = ProcessInfo.processInfo.systemUptime + 1.5

            func attemptLock() {
                guard self.focusExposureRequests.isLatest(requestID),
                      let current = self.videoInput?.device,
                      current.uniqueID == deviceID else { return }

                let canLockFocus = wantsFocusLock && current.isFocusModeSupported(.locked)
                let canLockExposure = wantsExposureLock &&
                    (current.isExposureModeSupported(.locked) || current.isExposureModeSupported(.custom))
                let focusStillSettling = canLockFocus && current.isAdjustingFocus
                let exposureStillSettling = canLockExposure && current.isAdjustingExposure

                if (focusStillSettling || exposureStillSettling), ProcessInfo.processInfo.systemUptime < deadline {
                    let retry = DispatchWorkItem { [weak self] in
                        guard let self else { return }
                        self.sessionQueue.async { attemptLock() }
                    }
                    self.pendingFocusLockWorkItem = retry
                    self.sessionQueue.asyncAfter(deadline: .now() + 0.06, execute: retry)
                    return
                }

                var focusApplied = false
                var exposureApplied = false
                do {
                    try current.lockForConfiguration()
                    defer { current.unlockForConfiguration() }

                    if canLockFocus {
                        // The current-position sentinel works even when arbitrary manual lens
                        // positions are unavailable; it freezes the position AF just reached.
                        current.setFocusModeLocked(
                            lensPosition: AVCaptureDevice.currentLensPosition,
                            completionHandler: nil
                        )
                        focusApplied = true
                    }

                    if canLockExposure {
                        if current.isExposureModeSupported(.locked) {
                            current.exposureMode = .locked
                        } else {
                            // Some devices expose custom exposure but not the simple locked mode.
                            // Preserve the current auto-selected values using AVFoundation's
                            // current-value sentinels instead of copying values that could race a frame.
                            current.setExposureModeCustom(
                                duration: AVCaptureDevice.currentExposureDuration,
                                iso: AVCaptureDevice.currentISO,
                                completionHandler: nil
                            )
                        }
                        exposureApplied = true
                    }
                } catch {
                    self.showError("Couldn’t lock focus and exposure.")
                    return
                }

                // Verify the modes after configuration instead of claiming a lock just because the
                // setters did not throw. This keeps the HUD truthful on lenses with partial support.
                let verify = DispatchWorkItem { [weak self, weak current] in
                    guard let self,
                          self.focusExposureRequests.isLatest(requestID),
                          let current,
                          self.videoInput?.device.uniqueID == deviceID else { return }

                    let focusVerified = focusApplied && current.focusMode == .locked
                    let exposureVerified = exposureApplied &&
                        (current.exposureMode == .locked || current.exposureMode == .custom)
                    self.focusLockedInHardware = focusVerified
                    self.exposureLockedInHardware = exposureVerified

                    let label: String
                    if focusVerified && exposureVerified {
                        label = "AE/AF LOCK"
                    } else if focusVerified {
                        label = "AF LOCK"
                    } else if exposureVerified {
                        label = "AE LOCK"
                    } else {
                        label = "AE/AF LOCK"
                    }
                    self.publish {
                        self.isFocusExposureLocked = focusVerified || exposureVerified
                        self.focusExposureLockLabel = label
                    }

                    AppEventLog.event(
                        "Focus/exposure lock verified: requested=\(lockPreference), focus=\(focusVerified), exposure=\(exposureVerified), " +
                        "focusMode=\(String(describing: current.focusMode)), exposureMode=\(String(describing: current.exposureMode))"
                    )

                    guard !focusVerified && !exposureVerified else { return }
                    switch lockPreference {
                    case "AF Only":
                        self.showError("AF lock isn’t supported on this lens.")
                    case "AE Only":
                        self.showError("AE lock isn’t supported on this lens.")
                    default:
                        self.showError("AE/AF lock isn’t supported by this camera configuration.")
                    }
                }
                self.pendingFocusLockWorkItem = verify
                self.sessionQueue.asyncAfter(deadline: .now() + 0.05, execute: verify)
            }
            attemptLock()
        } else {
            let resetSeconds = defaults.integer(forKey: LowPolyCamPreferences.Key.tapFocusResetSeconds)
            guard resetSeconds > 0 else {
                AppEventLog.event("Tap focus auto-reset disabled")
                return
            }

            let returnWork = DispatchWorkItem { [weak self] in
                guard let self,
                      self.focusExposureRequests.isLatest(requestID),
                      let current = self.videoInput?.device,
                      current.uniqueID == deviceID,
                      !self.focusLockedInHardware,
                      !self.exposureLockedInHardware else { return }
                do {
                    try current.lockForConfiguration()
                    defer { current.unlockForConfiguration() }
                    let center = CGPoint(x: 0.5, y: 0.5)
                    if current.isFocusPointOfInterestSupported {
                        current.focusPointOfInterest = center
                    }
                    if current.isExposurePointOfInterestSupported {
                        current.exposurePointOfInterest = center
                    }
                    if current.isFocusModeSupported(.continuousAutoFocus) {
                        current.focusMode = .continuousAutoFocus
                    }
                    if current.isExposureModeSupported(.continuousAutoExposure) {
                        current.exposureMode = .continuousAutoExposure
                    }
                    AppEventLog.event("Tap focus returned to continuous auto after \(resetSeconds)s")
                } catch {
                    // A later focus interaction, camera switch, or mode change will safely reset it.
                }
            }
            pendingFocusReturnWorkItem = returnWork
            sessionQueue.asyncAfter(deadline: .now() + .seconds(resetSeconds), execute: returnWork)
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
        guard width > 0, height > 0 else { return Self.photoMegapixelPresets }

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
        let maximum = max(1, min(Self.photoMegapixelPresets.first ?? 12, maximumNative))
        return Self.photoMegapixelPresets.filter { $0 <= maximum }
    }

    private static func normalizedPhotoMegapixels(_ value: Int) -> Int {
        guard value > 0 else { return photoMegapixelPresets.first ?? 12 }
        return photoMegapixelPresets.first(where: { $0 <= value }) ?? photoMegapixelPresets.last ?? 1
    }

    private func updatePhotoMegapixelAvailability(for dimensions: CMVideoDimensions, aspect: String) {
        let options = photoMegapixelOptions(for: dimensions, aspect: aspect)
        let effective = options.contains(preferredPhotoMegapixels) ? preferredPhotoMegapixels : (options.first ?? 1)
        publish {
            if self.supportedPhotoMegapixels != options {
                self.supportedPhotoMegapixels = options
            }
            if self.selectedPhotoMegapixels != effective {
                self.selectedPhotoMegapixels = effective
            }
            let label = "\(effective) MP"
            if self.currentPhotoResolutionLabel != label {
                self.currentPhotoResolutionLabel = label
            }
            let pixelCount = Int64(effective) * 1_000_000
            if self.currentPhotoPixelCount != pixelCount {
                self.currentPhotoPixelCount = pixelCount
            }
        }
    }

    @discardableResult
    private func applyBestPhotoFormat(preferVirtualCamera: Bool = true) -> Bool {
        let devices = capabilityDevices(for: cameraPosition.avPosition)
        updateSlowMotionAvailability(for: devices)
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
        let minimum = minimumSupportedZoom(for: desiredDevice)
        let maximum = maximumSupportedZoom(for: desiredDevice)
        publish {
            if abs(self.minimumZoomFactor - minimum) >= 0.0005 {
                self.minimumZoomFactor = minimum
            }
            if abs(self.maximumZoomFactor - maximum) >= 0.0005 {
                self.maximumZoomFactor = maximum
            }
            self.applyPublishedZoomIfNeeded(displayedZoom)
            let torchAvailable = desiredDevice.hasTorch && desiredDevice.isTorchAvailable
            let torchOn = desiredDevice.hasTorch && desiredDevice.torchMode == .on
            if self.torchAvailable != torchAvailable {
                self.torchAvailable = torchAvailable
            }
            if self.isTorchOn != torchOn {
                self.isTorchOn = torchOn
            }
        }
        updatePhotoMegapixelAvailability(
            for: photoChoice.dimensions,
            aspect: UserDefaults.standard.string(forKey: "photoAspect") ?? "4:3"
        )
        resetFocusAndExposureState()
        synchronizeWhiteBalanceAfterConfiguration()
        logCaptureConfiguration("Photo")
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

    /// Runs on the main queue inside an existing publish block. Avoiding identical assignments
    /// prevents ObservableObject redraws when a drag request resolves to the current zoom.
    private func applyPublishedZoomIfNeeded(_ factor: CGFloat) {
        if abs(zoomFactor - factor) >= 0.0005 {
            zoomFactor = factor
        }
        let label = formattedZoomLabel(for: factor)
        if zoomLabel != label {
            zoomLabel = label
        }
    }

    /// Captures only immutable primitive values on sessionQueue. AppEventLog formats and writes
    /// the detailed message on its own utility queue so record start is not held by interpolation.
    private func captureConfigurationLogSnapshot(
        _ context: String,
        label: String = "CAPTURE FORMAT/INPUT APPLIED"
    ) -> AppEventLog.CaptureConfigurationLogSnapshot? {
        guard let device = videoInput?.device else { return nil }

        let dimensions = CMVideoFormatDescriptionGetDimensions(device.activeFormat.formatDescription)
        let duration = device.activeVideoMinFrameDuration.seconds
        let frameRate = duration > 0 ? 1 / duration : 0
        let connection = movieOutput.connection(with: .video)
        let settings = connection.map { movieOutput.outputSettings(for: $0) } ?? [:]
        let codec = settings[AVVideoCodecKey] as? String ?? "system default"
        let compression = settings[AVVideoCompressionPropertiesKey] as? [String: Any]
        let bitRate = (compression?[AVVideoAverageBitRateKey] as? NSNumber)?.intValue
        return AppEventLog.CaptureConfigurationLogSnapshot(
            label: label,
            context: context,
            isBackCamera: cameraPosition == .back,
            isVirtualDevice: device.isVirtualDevice,
            deviceName: device.localizedName,
            width: dimensions.width,
            height: dimensions.height,
            frameRate: frameRate,
            codec: codec,
            bitRate: bitRate,
            zoomFactor: Double(requestedZoom),
            whiteBalance: requestedWhiteBalancePreset.rawValue,
            torchOn: device.hasTorch && device.torchMode == .on,
            photoFlashMode: photoFlashMode.rawValue
        )
    }

    private func enqueueCaptureConfigurationLog(
        _ snapshot: AppEventLog.CaptureConfigurationLogSnapshot?,
        context: String,
        label: String
    ) {
        if let snapshot {
            AppEventLog.event(snapshot)
        } else {
            AppEventLog.event("\(label) [\(context)]: failed — no active camera input")
        }
    }

    /// Records the pieces AVFoundation does not expose in the normal format trace. The primitive
    /// snapshot is collected on sessionQueue; formatting and disk I/O stay on AppEventLog.queue.
    private func captureSessionLogSnapshot(_ context: String) -> AppEventLog.SessionLogSnapshot {
        let inputNames = session.inputs.map { input -> String in
            if let deviceInput = input as? AVCaptureDeviceInput {
                return "camera:\(deviceInput.device.localizedName)"
            }
            if input is AVCaptureDeviceInput { return "device input" }
            return String(describing: type(of: input))
        }
        let outputNames = session.outputs.map { String(describing: type(of: $0)) }
        let torchOn = videoInput.map { $0.device.hasTorch && $0.device.torchMode == .on } ?? false
        return AppEventLog.SessionLogSnapshot(
            context: context,
            isRunning: session.isRunning,
            preset: session.sessionPreset.rawValue,
            mode: captureMode.rawValue,
            isBackCamera: cameraPosition == .back,
            recordingState: String(describing: recordingState),
            inputNames: inputNames,
            outputNames: outputNames,
            photoResponsive: photoOutput.isResponsiveCaptureEnabled,
            liveMetricsAttached: session.outputs.contains { $0 === liveMetrics.output },
            availableStorageBytes: availableStorageBytes,
            requestedResolution: hudResolutionLabel,
            requestedFrameRate: Int(hudFrameRateLabel ?? "0") ?? 0,
            selectedCodec: activeVideoCodec,
            compression: compressionDescription(for: captureMode),
            torchOn: torchOn,
            photoFlashMode: photoFlashMode.rawValue,
            zoomFactor: Double(requestedZoom),
            exposureBias: requestedExposureBias,
            whiteBalance: requestedWhiteBalancePreset.rawValue,
            focusExposureLocked: isFocusExposureLocked,
            microphoneAuthorized: String(AVCaptureDevice.authorizationStatus(for: .audio).rawValue),
            microphoneAttached: audioInput != nil
        )
    }

    private func logCaptureConfiguration(
        _ context: String,
        label: String = "CAPTURE FORMAT/INPUT APPLIED"
    ) {
        enqueueCaptureConfigurationLog(
            captureConfigurationLogSnapshot(context, label: label),
            context: context,
            label: label
        )
    }

    private func logSessionSnapshot(_ context: String) {
        AppEventLog.event(captureSessionLogSnapshot(context))
    }



    @discardableResult
    private func applySelectedFormat(
        preferVirtualCamera: Bool = true,
        requestedResolution: VideoResolution? = nil,
        requestedFrameRate: VideoFrameRate? = nil,
        requestedCodec: String? = nil,
        requestedCompression: VideoCompression? = nil,
        requestedCompressionMode: CompressionMode? = nil,
        requestedManualBitrateMbps: Double? = nil,
        qualityRequestID: UInt64? = nil,
        requestedPosition: CameraPosition? = nil,
        requestValidation: (() -> Bool)? = nil
    ) -> Bool {
        if let qualityRequestID, !qualityRequests.isLatest(qualityRequestID) { return false }
        if let requestValidation, !requestValidation() { return false }
        let targetPosition = requestedPosition ?? cameraPosition
        let effectiveCodec = requestedCodec ?? activeVideoCodec
        let currentCompressionSelection = compressionSelection(for: .video)
        let effectiveCompression = requestedCompression ?? currentCompressionSelection.level
        let effectiveCompressionMode = requestedCompressionMode ?? currentCompressionSelection.mode
        let effectiveManualBitrateMbps = requestedManualBitrateMbps ?? currentCompressionSelection.manualBitrateMbps
        let requestSelector = CameraFormatSelector(
            selectedVideoCodec: effectiveCodec,
            selectedResolution: requestedResolution ?? selectedResolution,
            selectedFrameRate: requestedFrameRate ?? selectedFrameRate
        )
        let devices = capabilityDevices(for: targetPosition.avPosition)
        let videoSelection = requestSelector.videoFormatSelection(
            for: devices,
            requestedResolution: requestedResolution,
            requestedFrameRate: requestedFrameRate
        )
        if let requestValidation, !requestValidation() { return false }
        publishVideoAvailability(
            !videoSelection.availableResolutions.isEmpty &&
                !videoSelection.supportedFrameRates.isEmpty
        )
        updateSlowMotionAvailability(
            for: devices,
            selector: requestSelector,
            position: targetPosition,
            codec: effectiveCodec,
            validation: requestValidation
        )
        if let requestValidation, !requestValidation() { return false }
        let available = videoSelection.availableResolutions
        guard !available.isEmpty else {
            if qualityRequests.isCurrent(qualityRequestID) {
                showError("Video isn’t available on this camera with the selected codec.")
            }
            return false
        }
        let selection = videoSelection
        let supportedDevices = selection.supportedDevices

        publish {
            if let qualityRequestID {
                guard self.qualityRequests.isLatest(qualityRequestID),
                      self.captureMode == .video,
                      self.cameraPosition == targetPosition else { return }
            }
            let wasSuppressing = self.suppressPreferencePersistence
            self.suppressPreferencePersistence = true
            if self.selectedResolution != selection.resolution {
                self.selectedResolution = selection.resolution
            }
            if self.selectedFrameRate != selection.frameRate {
                self.selectedFrameRate = selection.frameRate
            }
            if self.supportedResolutions != available {
                self.supportedResolutions = available
            }
            if self.supportedFrameRates != selection.supportedFrameRates {
                self.supportedFrameRates = selection.supportedFrameRates
            }
            self.suppressPreferencePersistence = wasSuppressing
        }

        // Rear 4K60 stays on the real selected 4K60 format while idle so Record never needs a
        // proxy-to-recording rebuild. When Apple's Dual-Wide/Triple virtual device itself exposes
        // this exact 4K60 + codec combination, keep that one input attached and let AVFoundation
        // switch its physical constituents while zooming. Manual WB still deliberately chooses a
        // physical input because locked custom gains are not equivalent on virtual cameras.
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
              let selectedFormat = videoSelection.selectedFormatByDeviceID[desiredDevice.uniqueID] else {
            if qualityRequests.isCurrent(qualityRequestID) {
                showError("This video quality isn’t available on this lens.")
            }
            return false
        }

        if let requestValidation, !requestValidation() { return false }
        guard let displayed = applyAtomicCaptureConfiguration(
            device: desiredDevice,
            format: selectedFormat,
            frameRate: Double(selection.frameRate.rawValue),
            requestedCodec: effectiveCodec
        ) else {
            if qualityRequests.isCurrent(qualityRequestID) {
                showError("Couldn’t set the video quality.")
            }
            return false
        }

        let outputConfigured = configureMovieOutputSettings(
            requestedCodec: effectiveCodec,
            requestedCompression: effectiveCompression,
            requestedCompressionMode: effectiveCompressionMode,
            requestedManualBitrateMbps: effectiveManualBitrateMbps,
            requestedResolution: selection.resolution,
            requestedFrameRate: selection.frameRate,
            requestedPosition: targetPosition,
            requestedMode: .video
        )
        if requestedCodec != nil || requestedCompression != nil ||
            requestedCompressionMode != nil || requestedManualBitrateMbps != nil {
            guard outputConfigured else { return false }
        }
        let zoomDevices = forcePhysical4K60 ? physicalSupportedDevices : [desiredDevice]
        let minZoom = zoomDevices.map { minimumSupportedZoom(for: $0) }.min() ?? minimumSupportedZoom(for: desiredDevice)
        let maxZoom = zoomDevices.map { maximumSupportedZoom(for: $0) }.max() ?? maximumSupportedZoom(for: desiredDevice)
        publish {
            if let qualityRequestID {
                guard self.qualityRequests.isLatest(qualityRequestID),
                      self.captureMode == .video,
                      self.cameraPosition == targetPosition else { return }
            }
            if abs(self.minimumZoomFactor - minZoom) >= 0.0005 {
                self.minimumZoomFactor = minZoom
            }
            if abs(self.maximumZoomFactor - maxZoom) >= 0.0005 {
                self.maximumZoomFactor = maxZoom
            }
            self.applyPublishedZoomIfNeeded(displayed)
            let torchAvailable = desiredDevice.hasTorch && desiredDevice.isTorchAvailable
            let torchOn = desiredDevice.hasTorch && desiredDevice.torchMode == .on
            if self.torchAvailable != torchAvailable {
                self.torchAvailable = torchAvailable
            }
            if self.isTorchOn != torchOn {
                self.isTorchOn = torchOn
            }
        }
        resetFocusAndExposureState()
        synchronizeWhiteBalanceAfterConfiguration()
        logCaptureConfiguration("Video")
        return true
    }

    private func activeVideoFormatMatchesSelection() -> Bool {
        guard let device = videoInput?.device else { return false }
        let dimensions = CMVideoFormatDescriptionGetDimensions(device.activeFormat.formatDescription)
        guard dimensions.width == selectedResolution.dimensions.width,
              dimensions.height == selectedResolution.dimensions.height else { return false }

        let requestedRate = Double(selectedFrameRate.rawValue)
        let duration = device.activeVideoMinFrameDuration.seconds
        return duration > 0 &&
            abs(1 / duration - requestedRate) < 0.5 &&
            formatSelector.formatSupportsSelectedCodec(device.activeFormat)
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
        requestedResolution: VideoResolution? = nil,
        requestedFrameRate: SlowMotionFrameRate? = nil,
        qualityRequestID: UInt64? = nil,
        requestedPosition: CameraPosition? = nil
    ) -> Bool {
        if let qualityRequestID, !qualityRequests.isLatest(qualityRequestID) { return false }
        let targetPosition = requestedPosition ?? cameraPosition
        let devices = capabilityDevices(for: targetPosition.avPosition)
        let slowMotionSelection = formatSelector.slowMotionFormatSelection(
            for: devices,
            requestedResolution: requestedResolution ?? selectedSlowMotionResolution,
            requestedFrameRate: requestedFrameRate ?? selectedSlowMotionFrameRate
        )
        let allResolutions = slowMotionSelection.availableResolutions
        slowMotionAvailabilityKey = [
            cameraPosition == .back ? "back" : "front",
            activeVideoCodec,
            devices.map(\.uniqueID).joined(separator: ",")
        ].joined(separator: "|")
        publishSlowMotionAvailability(!allResolutions.isEmpty)
        guard !allResolutions.isEmpty else {
            if qualityRequests.isCurrent(qualityRequestID) {
                showError("Slo-Mo isn’t available on this camera with the selected codec.")
            }
            return false
        }

        let resolution = slowMotionSelection.resolution
        let allRates = slowMotionSelection.supportedFrameRates
        guard !allRates.isEmpty else {
            if qualityRequests.isCurrent(qualityRequestID) {
                showError("Slo-Mo isn’t available at this resolution.")
            }
            return false
        }
        let selectedRate = slowMotionSelection.frameRate

        let supportedDevices = slowMotionSelection.supportedDevices
        guard !supportedDevices.isEmpty else {
            if qualityRequests.isCurrent(qualityRequestID) {
                showError("\(selectedRate.rawValue) fps Slo-Mo isn’t available on this camera.")
            }
            return false
        }

        // Slo-Mo stays on the actual selected HFR physical format while idle. This moves the
        // expensive input/format work away from the Record button. The preview and recording now
        // use the same 120/240 fps configuration; physical lens changes are covered separately.
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
              let hfrFormat = slowMotionSelection.selectedFormatByDeviceID[desiredDevice.uniqueID] else {
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

        _ = configureMovieOutputSettings()

        let lensResolutions = slowMotionSelection.availableResolutionsByDeviceID[desiredDevice.uniqueID] ?? []
        let lensRates = slowMotionSelection.supportedFrameRatesByDeviceID[desiredDevice.uniqueID] ?? []
        publish {
            if let qualityRequestID {
                guard self.qualityRequests.isLatest(qualityRequestID),
                      self.captureMode == .sloMo,
                      self.cameraPosition == targetPosition else { return }
            }
            let wasSuppressing = self.suppressPreferencePersistence
            self.suppressPreferencePersistence = true
            let resolvedResolutions = lensResolutions.isEmpty ? allResolutions : lensResolutions
            let resolvedRates = lensRates.isEmpty ? allRates : lensRates
            if self.supportedSlowMotionResolutions != resolvedResolutions {
                self.supportedSlowMotionResolutions = resolvedResolutions
            }
            if self.selectedSlowMotionResolution != resolution {
                self.selectedSlowMotionResolution = resolution
            }
            if self.supportedSlowMotionFrameRates != resolvedRates {
                self.supportedSlowMotionFrameRates = resolvedRates
            }
            if self.selectedSlowMotionFrameRate != selectedRate {
                self.selectedSlowMotionFrameRate = selectedRate
            }
            self.suppressPreferencePersistence = wasSuppressing
            if abs(self.minimumZoomFactor - sloMoMinimumZoom) >= 0.0005 {
                self.minimumZoomFactor = sloMoMinimumZoom
            }
            if abs(self.maximumZoomFactor - sloMoMaximumZoom) >= 0.0005 {
                self.maximumZoomFactor = sloMoMaximumZoom
            }
            self.applyPublishedZoomIfNeeded(displayed)
            let torchAvailable = desiredDevice.hasTorch && desiredDevice.isTorchAvailable
            let torchOn = desiredDevice.hasTorch && desiredDevice.torchMode == .on
            if self.torchAvailable != torchAvailable {
                self.torchAvailable = torchAvailable
            }
            if self.isTorchOn != torchOn {
                self.isTorchOn = torchOn
            }
        }
        resetFocusAndExposureState()
        synchronizeWhiteBalanceAfterConfiguration()
        logCaptureConfiguration("Slo-Mo")
        return true
    }





    private func currentOutputConfigurationRequestSnapshot() -> OutputConfigurationRequestSnapshot {
        OutputConfigurationRequestSnapshot(
            qualityRequestID: qualityRequests.current(),
            compressionRequestID: compressionRequests.current(),
            captureConfigurationGenerationID: captureConfigurationGeneration.current(),
            videoConfigurationRequestID: videoConfigurationRequests.current(),
            cameraSwitchRequestID: cameraSwitchRequests.current(),
            modeChangeRequestID: modeChangeRequests.current(),
            whiteBalanceRequestID: whiteBalanceRequests.current()
        )
    }

    private func outputConfigurationRequestIsUnchanged(
        _ snapshot: OutputConfigurationRequestSnapshot
    ) -> Bool {
        qualityRequests.isLatest(snapshot.qualityRequestID) &&
            compressionRequests.isLatest(snapshot.compressionRequestID) &&
            captureConfigurationGeneration.isLatest(snapshot.captureConfigurationGenerationID) &&
            videoConfigurationRequests.isLatest(snapshot.videoConfigurationRequestID) &&
            cameraSwitchRequests.isLatest(snapshot.cameraSwitchRequestID) &&
            modeChangeRequests.isLatest(snapshot.modeChangeRequestID) &&
            whiteBalanceRequests.isLatest(snapshot.whiteBalanceRequestID)
    }

    private func invalidateVerifiedHighOutputProvenance() {
        highOutputProvenanceEpoch &+= 1
        verifiedHighOutputProvenance = nil
    }

    private func highOutputReadbackSignature(
        from settings: [String: Any]
    ) -> HighOutputReadbackSignature? {
        let codec = settings[AVVideoCodecKey] as? String ?? ""
        guard !codec.isEmpty else { return nil }

        guard let compressionValue = settings[AVVideoCompressionPropertiesKey] else {
            return HighOutputReadbackSignature(
                codec: codec,
                compressionPropertiesPresent: false,
                averageBitrate: nil
            )
        }
        guard let compression = compressionValue as? [String: Any] else { return nil }
        guard let bitrateValue = compression[AVVideoAverageBitRateKey] else {
            return HighOutputReadbackSignature(
                codec: codec,
                compressionPropertiesPresent: true,
                averageBitrate: nil
            )
        }
        guard let bitrate = bitrateValue as? NSNumber,
              bitrate.doubleValue.isFinite else {
            return nil
        }
        return HighOutputReadbackSignature(
            codec: codec,
            compressionPropertiesPresent: true,
            averageBitrate: bitrate.doubleValue
        )
    }

    private func frameDurationMatchesFPS(_ duration: CMTime, fps: Double) -> Bool {
        let seconds = duration.seconds
        guard seconds.isFinite, seconds > 0, fps > 0 else { return false }
        let tolerance = fps >= 100 ? 1.0 : 0.5
        return abs((1.0 / seconds) - fps) < tolerance
    }

    private func installVerifiedHighOutputProvenance(
        requestSnapshot: OutputConfigurationRequestSnapshot,
        connection: AVCaptureConnection,
        settings: [String: Any],
        mode: CaptureMode,
        position: CameraPosition,
        resolution: VideoResolution,
        frameRate: Double,
        codec: String,
        shouldMirror: Bool,
        expectedStabilization: AVCaptureVideoStabilizationMode
    ) {
        guard outputConfigurationRequestIsUnchanged(requestSnapshot),
              !session.isInterrupted,
              session.outputs.contains(where: { $0 === movieOutput }),
              let input = videoInput,
              session.inputs.contains(where: { $0 === input }),
              let device = videoInput?.device,
              device.position == position.avPosition,
              let currentConnection = movieOutput.connection(with: .video),
              currentConnection === connection,
              let readback = highOutputReadbackSignature(from: settings),
              readback.codec == codec else { return }

        let dimensions = CMVideoFormatDescriptionGetDimensions(device.activeFormat.formatDescription)
        guard dimensions.width == resolution.dimensions.width,
              dimensions.height == resolution.dimensions.height,
              frameDurationMatchesFPS(device.activeVideoMinFrameDuration, fps: frameRate),
              frameDurationMatchesFPS(device.activeVideoMaxFrameDuration, fps: frameRate),
              connection.isVideoMirroringSupported == false ||
                  connection.isVideoMirrored == shouldMirror,
              connection.isVideoStabilizationSupported == false ||
                  connection.preferredVideoStabilizationMode == expectedStabilization else {
            return
        }

        verifiedHighOutputProvenance = VerifiedHighOutputProvenance(
            videoInput: input,
            movieConnection: connection,
            activeFormat: device.activeFormat,
            epoch: highOutputProvenanceEpoch,
            deviceUniqueID: device.uniqueID,
            mode: mode.rawValue,
            isBackCamera: position == .back,
            resolution: resolution.rawValue,
            frameRate: frameRate,
            codec: codec,
            dimensions: dimensions,
            minFrameDuration: device.activeVideoMinFrameDuration,
            maxFrameDuration: device.activeVideoMaxFrameDuration,
            mirroringSupported: connection.isVideoMirroringSupported,
            mirrored: connection.isVideoMirrored,
            stabilizationSupported: connection.isVideoStabilizationSupported,
            stabilizationModeRawValue: connection.preferredVideoStabilizationMode.rawValue,
            readback: readback
        )
    }

    private func verifiedHighOutputProvenanceMatchesCurrentConfiguration(
        connection: AVCaptureConnection,
        applied: [String: Any],
        preferredCodec: AVVideoCodecType
    ) -> Bool {
        guard let provenance = verifiedHighOutputProvenance,
              provenance.epoch == highOutputProvenanceEpoch,
              !session.isInterrupted,
              session.outputs.contains(where: { $0 === movieOutput }),
              let input = videoInput,
              session.inputs.contains(where: { $0 === input }),
              let device = videoInput?.device,
              let provenInput = provenance.videoInput,
              provenInput === input,
              let provenConnection = provenance.movieConnection,
              provenConnection === connection,
              let provenFormat = provenance.activeFormat,
              provenFormat === device.activeFormat,
              device.uniqueID == provenance.deviceUniqueID,
              device.position == (provenance.isBackCamera ? .back : .front),
              provenance.mode == captureMode.rawValue,
              provenance.isBackCamera == (cameraPosition == .back),
              provenance.resolution == (captureMode == .sloMo
                  ? selectedSlowMotionResolution.rawValue
                  : selectedResolution.rawValue),
              abs(provenance.frameRate - (captureMode == .sloMo
                  ? Double(selectedSlowMotionFrameRate.rawValue)
                  : Double(selectedFrameRate.rawValue))) < 0.0001,
              provenance.codec == preferredCodec.rawValue else {
            return false
        }

        let currentCompression = compressionSelection(for: captureMode)
        guard currentCompression.mode == .auto,
              currentCompression.level == .high else {
            return false
        }

        let dimensions = CMVideoFormatDescriptionGetDimensions(device.activeFormat.formatDescription)
        guard dimensions.width == provenance.dimensions.width,
              dimensions.height == provenance.dimensions.height,
              CMTimeCompare(device.activeVideoMinFrameDuration, provenance.minFrameDuration) == 0,
              CMTimeCompare(device.activeVideoMaxFrameDuration, provenance.maxFrameDuration) == 0,
              connection.isVideoMirroringSupported == provenance.mirroringSupported,
              connection.isVideoStabilizationSupported == provenance.stabilizationSupported else {
            return false
        }
        if provenance.mirroringSupported, connection.isVideoMirrored != provenance.mirrored {
            return false
        }
        if provenance.stabilizationSupported,
           connection.preferredVideoStabilizationMode.rawValue != provenance.stabilizationModeRawValue {
            return false
        }

        guard let readback = highOutputReadbackSignature(from: applied),
              readback == provenance.readback,
              readback.codec == preferredCodec.rawValue else {
            return false
        }
        return true
    }

    private func movieOutputSettingsMatchCurrentConfiguration(
        allowVerifiedHighDefault: Bool = false
    ) -> Bool {
        guard let connection = movieOutput.connection(with: .video) else { return false }
        let preferred: AVVideoCodecType = activeVideoCodec == "H264" ? .h264 : .hevc
        let applied = movieOutput.outputSettings(for: connection)
        guard (applied[AVVideoCodecKey] as? String) == preferred.rawValue else { return false }

        let shouldMirror = cameraPosition == .front && UserDefaults.standard.bool(forKey: "mirrorSelfies")
        if connection.isVideoMirroringSupported, connection.isVideoMirrored != shouldMirror { return false }

        if connection.isVideoStabilizationSupported {
            let expected: AVCaptureVideoStabilizationMode = captureMode == .video && isVideoStabilizationEnabled ? .auto : .off
            if connection.preferredVideoStabilizationMode != expected { return false }
        }

        let compression = compressionSelection(for: captureMode)
        let usesCustomBitrate = compression.mode == .manual || compression.level != .high
        if usesCustomBitrate {
            guard let compression = applied[AVVideoCompressionPropertiesKey] as? [String: Any],
                  let bitrate = compression[AVVideoAverageBitRateKey] as? NSNumber else { return false }
            let expected = estimatedVideoBitsPerSecond
            if abs(bitrate.doubleValue - expected) > max(expected * 0.20, 1_000_000) { return false }
        } else if allowVerifiedHighDefault {
            guard verifiedHighOutputProvenanceMatchesCurrentConfiguration(
                connection: connection,
                applied: applied,
                preferredCodec: preferred
            ) else { return false }
        } else if applied[AVVideoCompressionPropertiesKey] != nil {
            // High means the system/default compression path. A previous custom bitrate must
            // not be mistaken for the current setting when a non-Record caller reconciles work.
            return false
        }
        return true
    }

    @discardableResult
    private func configureMovieOutputSettings(
        requestedCodec: String? = nil,
        requestedCompression: VideoCompression? = nil,
        requestedCompressionMode: CompressionMode? = nil,
        requestedManualBitrateMbps: Double? = nil,
        requestedResolution: VideoResolution? = nil,
        requestedFrameRate: VideoFrameRate? = nil,
        requestedPosition: CameraPosition? = nil,
        requestedMode: CaptureMode? = nil
    ) -> Bool {
        invalidateVerifiedHighOutputProvenance()
        let outputTraceID = activeRecordingTraceID ?? (AppEventLog.extremeDiagnosticsEnabled ? AppEventLog.makeTraceID("OUTPUT") : nil)
        let outputStartedAt = ProcessInfo.processInfo.systemUptime
        let requestSnapshot = currentOutputConfigurationRequestSnapshot()
        guard let connection = movieOutput.connection(with: .video) else {
            AppEventLog.guardRejected("configureMovieOutputSettings", reason: "movie output video connection missing", traceID: outputTraceID)
            return false
        }

        let effectiveMode = requestedMode ?? captureMode
        let effectivePosition = requestedPosition ?? cameraPosition
        let effectiveCodec = effectiveMode == .sloMo ? "HEVC" : (requestedCodec ?? activeVideoCodec)
        let currentCompression = compressionSelection(for: effectiveMode)
        let effectiveCompression = requestedCompression ?? currentCompression.level
        let effectiveCompressionMode = requestedCompressionMode ?? currentCompression.mode
        let requestedBitrateMbps = ManualBitratePolicy.validatedMbps(
            requestedManualBitrateMbps ?? currentCompression.manualBitrateMbps
        )
        let effectiveResolution = effectiveMode == .sloMo
            ? selectedSlowMotionResolution
            : (requestedResolution ?? selectedResolution)
        let effectiveFPS: Double = effectiveMode == .sloMo
            ? Double(selectedSlowMotionFrameRate.rawValue)
            : Double((requestedFrameRate ?? selectedFrameRate).rawValue)
        let effectiveManualBitrateMbps = ManualBitratePolicy.effectiveMbps(
            requested: requestedBitrateMbps,
            resolution: effectiveResolution,
            fps: effectiveFPS,
            isSlowMotion: effectiveMode == .sloMo,
            codec: effectiveCodec
        )
        let expectedBitRate = estimatedVideoBitsPerSecond(
            resolution: effectiveResolution,
            fps: effectiveFPS,
            codec: effectiveCodec,
            compression: effectiveCompression,
            compressionMode: effectiveCompressionMode,
            manualBitrateMbps: requestedBitrateMbps,
            isSlowMotion: effectiveMode == .sloMo
        )
        AppEventLog.deepEvent("MOVIE OUTPUT CONFIG REQUEST", category: .video, traceID: outputTraceID, fields: [
            "mode": effectiveMode.rawValue,
            "Video/Slo-Mo": effectiveMode.rawValue,
            "position": effectivePosition.rawValue,
            "resolution": effectiveResolution.rawValue,
            "fps": String(format: "%.1f", effectiveFPS),
            "FPS": String(format: "%.1f", effectiveFPS),
            "codec": effectiveCodec,
            "requestedManualBitrateMbps": String(format: "%.1f", requestedBitrateMbps),
            "effectiveManualBitrateMbps": String(format: "%.1f", effectiveManualBitrateMbps),
            "compression": effectiveCompressionMode == .manual
                ? "Manual \(String(format: "%.1f", effectiveManualBitrateMbps)) Mbps"
                : "Auto \(effectiveCompression.rawValue)",
            "expectedBitrate": String(Int(expectedBitRate)),
            "availableCodecs": movieOutput.availableVideoCodecTypes.map(\.rawValue).joined(separator: ",")
        ])

        let shouldMirror = effectivePosition == .front && UserDefaults.standard.bool(forKey: "mirrorSelfies")
        if connection.isVideoMirroringSupported {
            if connection.automaticallyAdjustsVideoMirroring {
                connection.automaticallyAdjustsVideoMirroring = false
            }
            if connection.isVideoMirrored != shouldMirror {
                connection.isVideoMirrored = shouldMirror
            }
        }

        let shouldStabilize = effectiveMode == .video && isVideoStabilizationEnabled
        let expectedStabilization: AVCaptureVideoStabilizationMode = shouldStabilize ? .auto : .off
        if connection.isVideoStabilizationSupported {
            if connection.preferredVideoStabilizationMode != expectedStabilization {
                connection.preferredVideoStabilizationMode = expectedStabilization
            }
        }

        let supportedKeys = Set(movieOutput.supportedOutputSettingsKeys(for: connection))
        let preferred: AVVideoCodecType = effectiveCodec == "H264" ? .h264 : .hevc
        let codecAvailable = movieOutputSupportsCodec(preferred, on: connection, supportedKeys: supportedKeys)
        let message: String? = codecAvailable ? nil : (preferred == .h264 && movieOutput.availableVideoCodecTypes.contains(.hevc)
            ? "This camera configuration requires HEVC / H.265. Select HEVC, or lower the resolution or frame rate to use H.264."
            : "The selected codec is unavailable for this camera configuration.")
        publish {
            if requestedCodec != nil, self.selectedVideoCodec != effectiveCodec { return }
            if self.codecAvailabilityMessage != message {
                self.codecAvailabilityMessage = message
            }
        }
        guard codecAvailable else {
            AppEventLog.event("MOVIE OUTPUT CODEC REJECTED", category: .video, level: .warning, traceID: outputTraceID, fields: [
                "requestedCodec": preferred.rawValue,
                "availableCodecs": movieOutput.availableVideoCodecTypes.map(\.rawValue).joined(separator: ","),
                "supportedKeys": supportedKeys.sorted().joined(separator: ",")
            ])
            return false
        }

        let needsCompressionProperties = effectiveCompressionMode == .manual || effectiveCompression != .high
        guard !needsCompressionProperties || supportedKeys.contains(AVVideoCompressionPropertiesKey) else {
            AppEventLog.event("MOVIE OUTPUT COMPRESSION REJECTED: compression properties are unsupported",
                              category: .video, level: .warning, traceID: outputTraceID,
                              fields: ["mode": effectiveMode.rawValue, "compression": effectiveCompressionMode == .manual
                                       ? "manual" : effectiveCompression.rawValue])
            return false
        }

        var settings: [String: Any] = [AVVideoCodecKey: preferred]
        if needsCompressionProperties {
            settings[AVVideoCompressionPropertiesKey] = [
                AVVideoAverageBitRateKey: Int(expectedBitRate)
            ]
        }

        movieOutput.setOutputSettings(nil, for: connection)
        movieOutput.setOutputSettings(settings, for: connection)

        let applied = movieOutput.outputSettings(for: connection)
        let appliedCompression = applied[AVVideoCompressionPropertiesKey] as? [String: Any]
        AppEventLog.deepEvent("MOVIE OUTPUT CONFIG READBACK", category: .video, traceID: outputTraceID, fields: [
            "codec": applied[AVVideoCodecKey] as? String ?? "missing",
            "bitrate": (appliedCompression?[AVVideoAverageBitRateKey] as? NSNumber).map { String($0.int64Value) } ?? "default",
            "mirrored": String(connection.isVideoMirrored),
            "stabilization": String(describing: connection.preferredVideoStabilizationMode),
            "totalMs": String(format: "%.2f", (ProcessInfo.processInfo.systemUptime - outputStartedAt) * 1000)
        ])
        guard (applied[AVVideoCodecKey] as? String) == preferred.rawValue else {
            let message = preferred == .h264 && movieOutput.availableVideoCodecTypes.contains(.hevc)
                ? "This camera configuration requires HEVC / H.265. Select HEVC, or lower the resolution or frame rate to use H.264."
                : "The selected codec is unavailable for this camera configuration."
            publish {
                if requestedCodec != nil, self.selectedVideoCodec != effectiveCodec { return }
                if self.codecAvailabilityMessage != message {
                    self.codecAvailabilityMessage = message
                }
            }
            return false
        }
        if connection.isVideoMirroringSupported, connection.isVideoMirrored != shouldMirror { return false }
        if connection.isVideoStabilizationSupported {
            let expected: AVCaptureVideoStabilizationMode = shouldStabilize ? .auto : .off
            if connection.preferredVideoStabilizationMode != expected { return false }
        }
        if needsCompressionProperties {
            guard let compression = applied[AVVideoCompressionPropertiesKey] as? [String: Any],
                  let bitrate = compression[AVVideoAverageBitRateKey] as? NSNumber else {
                AppEventLog.event("MOVIE OUTPUT COMPRESSION READBACK REJECTED: bitrate missing",
                                  category: .video, level: .warning, traceID: outputTraceID)
                return false
            }
            if abs(bitrate.doubleValue - expectedBitRate) > max(expectedBitRate * 0.20, 1_000_000) {
                return false
            }
        }
        logMovieOutputConfigurationReadback(
            connection: connection,
            settings: applied,
            mode: effectiveMode,
            position: effectivePosition,
            compression: effectiveCompression,
            compressionMode: effectiveCompressionMode,
            manualBitrateMbps: effectiveManualBitrateMbps
        )
        if effectiveCompressionMode == .auto, effectiveCompression == .high {
            installVerifiedHighOutputProvenance(
                requestSnapshot: requestSnapshot,
                connection: connection,
                settings: applied,
                mode: effectiveMode,
                position: effectivePosition,
                resolution: effectiveResolution,
                frameRate: effectiveFPS,
                codec: preferred.rawValue,
                shouldMirror: shouldMirror,
                expectedStabilization: expectedStabilization
            )
        }
        AppEventLog.deepEvent("MOVIE OUTPUT CONFIG COMPLETE", category: .video, traceID: outputTraceID, fields: [
            "result": "success",
            "totalMs": String(format: "%.2f", (ProcessInfo.processInfo.systemUptime - outputStartedAt) * 1000)
        ])
        return true
    }

    private func movieOutputSupportsCodec(
        _ codec: AVVideoCodecType,
        on connection: AVCaptureConnection,
        supportedKeys: Set<String>? = nil
    ) -> Bool {
        let keys = supportedKeys ?? Set(movieOutput.supportedOutputSettingsKeys(for: connection))
        return movieOutput.availableVideoCodecTypes.contains(codec) && keys.contains(AVVideoCodecKey)
    }

    private func logMovieOutputConfigurationReadback(
        connection: AVCaptureConnection,
        settings: [String: Any],
        mode: CaptureMode,
        position: CameraPosition,
        compression configuredCompression: VideoCompression,
        compressionMode: CompressionMode = .auto,
        manualBitrateMbps: Double = ManualBitratePolicy.defaultMbps
    ) {
        let codec = settings[AVVideoCodecKey] as? String ?? "system default"
        let compression = settings[AVVideoCompressionPropertiesKey] as? [String: Any]
        let bitRate = (compression?[AVVideoAverageBitRateKey] as? NSNumber)?.intValue
        let bitRateText = bitRate.map { "\($0)" } ?? "default"
        let compressionText = compressionMode == .manual
            ? "Manual \(String(format: "%.1f", manualBitrateMbps)) Mbps"
            : "Auto \(configuredCompression.rawValue)"
        AppEventLog.event(
            "MOVIE OUTPUT READBACK: mode=\(mode.rawValue), " +
            "position=\(position == .back ? "back" : "front"), codec=\(codec), " +
            "compression=\(compressionText), averageBitrate=\(bitRateText), " +
            "mirrored=\(connection.isVideoMirrored), " +
            "stabilization=\(String(describing: connection.preferredVideoStabilizationMode))"
        )
    }






    private func applyCaptureRotation(to connection: AVCaptureConnection?) {
        guard let connection else { return }
        let automaticAngle = rotationCoordinator?.videoRotationAngleForHorizonLevelCapture
        let requestedAngle: CGFloat?
        switch captureOrientation {
        case .auto:
            requestedAngle = automaticAngle
        case .portrait:
            requestedAngle = 90
        case .landscapeLeft:
            requestedAngle = 180
        case .landscapeRight:
            requestedAngle = 0
        }
        let angle = requestedAngle.flatMap { connection.isVideoRotationAngleSupported($0) ? $0 : nil }
            ?? automaticAngle.flatMap { connection.isVideoRotationAngleSupported($0) ? $0 : nil }
        guard let angle else { return }
        connection.videoRotationAngle = angle
    }

    private func resolvedPhotoFlashMode() -> AVCaptureDevice.FlashMode {
        guard let device = videoInput?.device,
              device.hasFlash else { return .off }
        let supportedModes = photoOutput.supportedFlashModes
        guard supportedModes.contains(photoFlashMode.avMode) else { return .off }
        guard photoFlashMode == .auto, cameraPosition == .front else {
            return photoFlashMode.avMode
        }

        // Front-camera Auto is resolved from the current preview scene instead of delegating
        // the final decision to the capture moment. The extra exposure gate keeps ordinary
        // rooms and a nearby lamp from being treated as flash-dark by the front sensor.
        let sceneNeedsFlash = photoOutput.isFlashScene
        let shouldUseFlash = shouldUseFrontAutoFlash(on: device)
        let resolved = shouldUseFlash ? AVCaptureDevice.FlashMode.on : .off
        AppEventLog.event(
            "Front Auto flash decision: sceneNeedsFlash=\(sceneNeedsFlash), " +
            "applied=\(shouldUseFlash), ISO=\(String(format: "%.0f", device.iso)), " +
            "exposure=\(String(format: "%.4f", device.exposureDuration.seconds))s"
        )
        return supportedModes.contains(resolved) ? resolved : .off
    }

    private func shouldUseFrontAutoFlash(on device: AVCaptureDevice) -> Bool {
        guard photoOutput.isFlashScene else { return false }

        let isoThreshold = max(device.activeFormat.minISO * 8, 500)
        let iso = device.iso
        guard iso.isFinite else { return true }
        if iso >= isoThreshold { return true }

        let exposureSeconds = device.exposureDuration.seconds
        let maximumExposureSeconds = device.activeMaxExposureDuration.seconds
        let isNearAutoExposureLimit = exposureSeconds.isFinite &&
            exposureSeconds >= (1.0 / 30.0) &&
            (!maximumExposureSeconds.isFinite || maximumExposureSeconds <= 0 ||
             exposureSeconds >= maximumExposureSeconds * 0.9)
        return isNearAutoExposureLimit && iso >= isoThreshold * 0.7
    }

    private func configurePhotoSceneMonitoring() {
        guard photoOutput.supportedFlashModes.contains(.auto) else { return }
        let monitoringSettings = AVCapturePhotoSettings()
        monitoringSettings.flashMode = .auto
        monitoringSettings.isAutoStillImageStabilizationEnabled = true
        photoOutput.photoSettingsForSceneMonitoring = monitoringSettings
    }

    private func beginPhotoCapture() {
        guard activePhotoCaptureID == nil else {
            AppEventLog.guardRejected("beginPhotoCapture", reason: "another hardware photo capture is active",
                                      fields: ["activeCaptureID": String(activePhotoCaptureID ?? -1)])
            return
        }
        guard session.isRunning else {
            AppEventLog.event("PHOTO CAPTURE REJECTED", category: .photo, level: .warning,
                              fields: ["reason": "session not running"])

            burstRemaining = 0
            burstStopRequested = false
            publish { self.isCapturingPhoto = false }
            showError("Camera isn’t ready yet.")
            return
        }

        let isBurst = burstRemaining > 0
        let burstOrdinal = isBurst ? max(1, burstRequestedCount - burstRemaining + 1) : nil
        let traceID: String
        if isBurst, let parent = activeBurstTraceID {
            traceID = "\(parent)-P\(burstOrdinal ?? 0)"
        } else {
            traceID = AppEventLog.makeTraceID("PHOTO")
        }
        let captureStartedAt = ProcessInfo.processInfo.systemUptime
        let aspect = isBurst ? burstAspect : (UserDefaults.standard.string(forKey: "photoAspect") ?? "4:3")
        let megapixels = isBurst ? burstMegapixels : selectedPhotoMegapixels
        let useHEIC = photoFileFormat == "HEIC" && photoOutput.availablePhotoCodecTypes.contains(.hevc)
        let mirrored = cameraPosition == .front && UserDefaults.standard.bool(forKey: "mirrorSelfies")
        if let connection = photoOutput.connection(with: .video) {
            if connection.isVideoMirroringSupported {
                connection.automaticallyAdjustsVideoMirroring = false
                connection.isVideoMirrored = mirrored
            }
            applyCaptureRotation(to: connection)
        }

        let settings = useHEIC
            ? AVCapturePhotoSettings(format: [AVVideoCodecKey: AVVideoCodecType.hevc])
            : AVCapturePhotoSettings(format: [AVVideoCodecKey: AVVideoCodecType.jpeg])

        let requestedFlash = photoFlashMode
        let appliedFlash = resolvedPhotoFlashMode()
        let appliedFlashLabel: String
        switch appliedFlash {
        case .off: appliedFlashLabel = "Off"
        case .auto: appliedFlashLabel = "Auto"
        case .on: appliedFlashLabel = "On"
        @unknown default: appliedFlashLabel = "Unknown"
        }
        settings.flashMode = appliedFlash

        // AVFoundation may override a locked device exposure for multi-image processing when
        // photo quality is .balanced/.quality. When AE is locked, use .speed so the saved photo
        // honors the device's locked exposure. Normal captures keep the existing balanced path.
        settings.photoQualityPrioritization = exposureLockedInHardware ? .speed : .balanced
        let dimensions = photoOutput.maxPhotoDimensions
        if dimensions.width > 0, dimensions.height > 0 {
            settings.maxPhotoDimensions = dimensions
        }

        let captureID = settings.uniqueID
        photoCaptureContexts[captureID] = PhotoCaptureContext(
            aspect: aspect,
            megapixels: megapixels,
            filename: nextMediaFilename(fileExtension: useHEIC ? "heic" : "jpg"),
            isBurst: isBurst,
            requestedFlash: requestedFlash.rawValue,
            appliedFlash: appliedFlashLabel,
            traceID: traceID,
            startedAt: captureStartedAt,
            burstOrdinal: burstOrdinal
        )
        activePhotoCaptureID = captureID
        activePhotoCaptureIsBurst = isBurst
        let activeDevice = videoInput?.device
        let activeDimensions = activeDevice.map { CMVideoFormatDescriptionGetDimensions($0.activeFormat.formatDescription) }
        AppEventLog.event("PHOTO CAPTURE REQUEST", category: isBurst ? .burst : .photo, traceID: traceID, fields: [
            "captureID": String(captureID),
            "burstOrdinal": burstOrdinal.map(String.init) ?? "none",
            "requestedMP": String(megapixels),
            "codec": useHEIC ? "HEIC" : "JPEG",
            "aspect": aspect,
            "mirrored": String(mirrored),
            "flashRequested": requestedFlash.rawValue,
            "flashApplied": appliedFlashLabel,
            "photoQualityPriority": exposureLockedInHardware ? "speed (AE locked)" : "balanced",
            "responsive": String(photoOutput.isResponsiveCaptureEnabled),
            "device": activeDevice?.localizedName ?? "none",
            "activePreviewFormat": activeDimensions.map { "\($0.width)x\($0.height)" } ?? "none",
            "maxPhotoDimensions": "\(dimensions.width)x\(dimensions.height)",
            "filename": photoCaptureContexts[captureID]?.filename ?? "unknown"
        ])
        if !isBurst { refreshAvailableStorage() }
        let submitAt = ProcessInfo.processInfo.systemUptime
        photoOutput.capturePhoto(with: settings, delegate: self)
        AppEventLog.deepEvent("capturePhoto() RETURNED", category: .photo, traceID: traceID, fields: [
            "callMs": String(format: "%.3f", (ProcessInfo.processInfo.systemUptime - submitAt) * 1000),
            "elapsedFromRequestMs": String(format: "%.3f", (ProcessInfo.processInfo.systemUptime - captureStartedAt) * 1000)
        ])
    }

    private func beginRecording() {
        let traceID = activeRecordingTraceID
        guard recordingState.requestsRecording, session.isRunning, movieOutput.isRecording == false else {
            AppEventLog.guardRejected("beginRecording", reason: "recording preconditions failed", traceID: traceID, fields: [
                "requestsRecording": String(recordingState.requestsRecording),
                "sessionRunning": String(session.isRunning),
                "movieOutputRecording": String(movieOutput.isRecording)
            ])
            transitionRecordingState(to: .idle, resetClock: true)
            return
        }
        AppEventLog.deepEvent("RECORDING PREPARATION BEGIN", category: .recording, traceID: traceID, fields: [
            "elapsedFromUserRequestMs": String(format: "%.2f", (ProcessInfo.processInfo.systemUptime - recordingRequestStartedAt) * 1000)
        ])

        var reconfiguredForRecording = false
        if captureMode == .video {
            if !activeVideoFormatMatchesSelection() {
                reconfiguredForRecording = true
                guard applySelectedFormat(
                    preferVirtualCamera: !requiresPhysicalWhiteBalanceInput
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
                } == true

            if !activeSloMoReady {
                reconfiguredForRecording = true
                guard applySlowMotionFormat(),
                      activeSlowMotionFormatMatchesSelection(),
                      let device = videoInput?.device,
                      formatSelector.supportsSlowMotion(
                          device.activeFormat,
                          resolution: selectedSlowMotionResolution,
                          frameRate: selectedSlowMotionFrameRate
                      ) else {
                    transitionRecordingState(to: .idle, resetClock: true)
                    showError("Couldn’t start the selected Slo-Mo frame rate.")
                    return
                }
            }
        }

        guard movieOutputSettingsMatchCurrentConfiguration(allowVerifiedHighDefault: true) ||
              configureMovieOutputSettings() else {
            transitionRecordingState(to: .idle, resetClock: true)
            showError("\(activeVideoCodec == "H264" ? "H.264" : "HEVC") isn’t available at this resolution/FPS on this lens.")
            return
        }

        applyCaptureRotation(to: movieOutput.connection(with: .video))
        movieOutput.metadata = CameraMovieMetadata.items(isSlowMotion: captureMode == .sloMo)

        // When the idle preview is already the exact recording configuration (the normal case for
        // rear 4K60 and Slo-Mo now), start immediately instead of imposing the old AF/AE wait. Only
        // keep the settle window for the recovery path that actually had to reconfigure hardware.
        let readinessDeadline = reconfiguredForRecording ? Date().addingTimeInterval(1.0) : Date()
        let storageStartRequestID = recordingStartRequests.next(reason: "recording storage safety check")
        let reserve = criticalStorageReserveBytes
        activeCriticalStorageReserveBytes = reserve
        AppEventLog.event("Recording storage check requested: reserve=\(reserve), bitrate=\(Int(estimatedVideoBitsPerSecond))", category: .storage, traceID: traceID,
                          fields: ["reconfiguredForRecording": String(reconfiguredForRecording)])
        storageGuard.checkNow(criticalReserveBytes: reserve) { [weak self] snapshot in
            guard let self else { return }
            self.sessionQueue.async {
                guard self.recordingStartRequests.isLatest(storageStartRequestID),
                      self.recordingState.requestsRecording,
                      self.appLifecyclePhase == .active,
                      self.session.isRunning else {
                    AppEventLog.staleRequest(token: "recordingStartRequests", requestID: storageStartRequestID,
                                                latestID: self.recordingStartRequests.current(), operation: "recording storage completion", traceID: self.activeRecordingTraceID)
                    return
                }
                guard let snapshot else {
                    self.transitionRecordingState(to: .idle, resetClock: true)
                    self.showError("Couldn’t check free storage before recording.")
                    return
                }

                self.applyStorageSnapshot(snapshot, source: "recording start")
                guard self.recordingStartRequests.isLatest(storageStartRequestID),
                      self.recordingState.requestsRecording,
                      !snapshot.isCritical else { return }

                let preparationCaptureSnapshot = self.captureConfigurationLogSnapshot(
                    "before start",
                    label: "RECORDING PREPARATION READBACK"
                )
                let preparationSessionSnapshot = self.captureSessionLogSnapshot("recording preparation")
                let enqueuePreparationDiagnostics: () -> Void = { [weak self] in
                    guard let self else { return }
                    self.enqueueCaptureConfigurationLog(
                        preparationCaptureSnapshot,
                        context: "before start",
                        label: "RECORDING PREPARATION READBACK"
                    )
                    AppEventLog.event(preparationSessionSnapshot)
                }
                self.startMovieOutputWhenReady(
                    deadline: readinessDeadline,
                    storageStartRequestID: storageStartRequestID,
                    afterStart: enqueuePreparationDiagnostics
                )
            }
        }
    }

    private func startMovieOutputWhenReady(
        deadline: Date,
        storageStartRequestID: UInt64,
        afterStart: @escaping () -> Void = {}
    ) {
        guard recordingStartRequests.isLatest(storageStartRequestID),
              recordingState.requestsRecording,
              !movieOutput.isRecording else {
            AppEventLog.guardRejected("startMovieOutputWhenReady", reason: "request/state changed", traceID: activeRecordingTraceID, fields: [
                "requestID": String(storageStartRequestID), "latestID": String(recordingStartRequests.current()),
                "requestsRecording": String(recordingState.requestsRecording), "movieOutputRecording": String(movieOutput.isRecording)
            ])
            return
        }
        if let device = videoInput?.device,
           (device.isAdjustingFocus || device.isAdjustingExposure),
            Date() < deadline {
            sessionQueue.asyncAfter(deadline: .now() + 0.06) { [weak self] in
                self?.startMovieOutputWhenReady(
                    deadline: deadline,
                    storageStartRequestID: storageStartRequestID,
                    afterStart: afterStart
                )
            }
            return
        }

        guard recordingStartRequests.isLatest(storageStartRequestID), recordingState.requestsRecording else {
            AppEventLog.staleRequest(token: "recordingStartRequests", requestID: storageStartRequestID,
                                     latestID: recordingStartRequests.current(), operation: "movie output start", traceID: activeRecordingTraceID)
            return
        }
        let filename = nextMediaFilename(fileExtension: "mov")
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(filename)
        movieStartCallAt = ProcessInfo.processInfo.systemUptime
        AppEventLog.event("MOVIE OUTPUT startRecording()", category: .recording, traceID: activeRecordingTraceID, fields: [
            "filename": filename,
            "segment": String(recordingSegmentIndex),
            "elapsedFromUserRequestMs": String(format: "%.2f", (movieStartCallAt - recordingRequestStartedAt) * 1000),
            "focusAdjusting": String(videoInput?.device.isAdjustingFocus ?? false),
            "exposureAdjusting": String(videoInput?.device.isAdjustingExposure ?? false)
        ])
        storageGuard.startMonitoring(criticalReserveBytes: activeCriticalStorageReserveBytes) { [weak self] snapshot in
            self?.sessionQueue.async { [weak self] in
                self?.applyStorageSnapshot(snapshot, source: "recording monitor")
            }
        }
        movieOutput.startRecording(to: url, recordingDelegate: self)
        AppEventLog.deepEvent("MOVIE OUTPUT startRecording() RETURNED", category: .recording, traceID: activeRecordingTraceID, fields: [
            "callMs": String(format: "%.3f", (ProcessInfo.processInfo.systemUptime - movieStartCallAt) * 1000)
        ])
        afterStart()
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
                if self.torchAvailable { self.torchAvailable = false }
                if self.isTorchOn { self.isTorchOn = false }
                if self.photoFlashAvailable { self.photoFlashAvailable = false }
                if self.torchBrightnessSupported { self.torchBrightnessSupported = false }
            }
            return
        }
        var torchOn = device.hasTorch && device.torchMode == .on
        if captureMode == .photo, torchOn {
            do {
                try device.lockForConfiguration()
                device.torchMode = .off
                device.unlockForConfiguration()
                torchOn = false
                AppEventLog.event("Torch forced off while Photo mode became active")
            } catch {
                AppEventLog.log(error: error, prefix: "Torch could not be disabled for Photo mode")
            }
        }
        let torchAvailable = device.hasTorch && device.isTorchAvailable
        let torchLevelSupported = device.hasTorch && device.maxAvailableTorchLevel > 0
        configurePhotoSceneMonitoring()
        let flashAvailable = device.hasFlash && !photoOutput.supportedFlashModes.isEmpty
        publish {
            if self.torchAvailable != torchAvailable {
                self.torchAvailable = torchAvailable
            }
            if self.isTorchOn != torchOn {
                self.isTorchOn = torchOn
            }
            if self.photoFlashAvailable != flashAvailable {
                self.photoFlashAvailable = flashAvailable
            }
            if self.torchBrightnessSupported != torchLevelSupported {
                self.torchBrightnessSupported = torchLevelSupported
            }
        }
    }

    private func publish(_ update: @escaping () -> Void) {
        DispatchQueue.main.async(execute: update)
    }

    private func refreshRecoveryCount() {
        let recordings = CameraRecoveryStore.recordings()
        let photos = CameraRecoveryStore.photoRecoveryFiles()
        publish {
            self.recoverableRecordingCount = recordings.count
            self.recoverableRecordingFiles = recordings
            self.recoverablePhotoCount = photos.count
            self.recoverablePhotoFiles = photos
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
    private func savePhotoFileToPhotos(_ fileURL: URL, recoveryRetry: Bool = true) -> Bool {
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

    private var hasPendingMediaSaves: Bool {
        pendingVideoSaves > 0 || pendingPhotoSaves > 0
    }

    private func beginBackgroundMediaSaveIfNeeded() {
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

    private func endBackgroundMediaSaveIfPossible() {
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

    private func finishFinalizingIfPossible() {
        guard pendingVideoSaves == 0 else { return }
        closeRecordingDiagnostics(reason: "finalization complete", result: "success")
        transitionRecordingState(to: .idle, resetClock: true)
        storageProtectionStopIssued = false
        endBackgroundMediaSaveIfPossible()
    }

    private func closeRecordingDiagnostics(reason: String, result: String) {
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

    private func restoreIdleCaptureConfigurationAfterRecording() {
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

    private func finishVideoSaveValidationFailure(
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
    private func saveVideoResourceToPhotos(
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

    private func showError(_ message: String) {
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

extension CameraManager: AVCaptureFileOutputRecordingDelegate {
    func fileOutput(_ output: AVCaptureFileOutput, didStartRecordingTo fileURL: URL, from connections: [AVCaptureConnection]) {
        sessionQueue.async { [weak self] in
            guard let self else { return }

            if !self.recordingState.requestsRecording {
                self.transitionRecordingToDiscard()
                if self.movieOutput.isRecording {
                    self.requestNativeRecordingStop(reason: "stale recording start callback")
                    self.movieOutput.stopRecording()
                }
                return
            }

            guard self.recordingPauseMachine.start() else {
                AppEventLog.guardRejected("didStartRecording", reason: "pause state machine was not idle", traceID: self.activeRecordingTraceID, fields: [
                    "pauseState": self.recordingPauseMachine.state.rawValue
                ])
                self.transitionRecordingToDiscard()
                self.requestNativeRecordingStop(reason: "pause state machine rejected recording start")
                self.movieOutput.stopRecording()
                return
            }
            self.publish { self.recordingPauseState = .recording }

            self.startLiveMetrics()
            self.configureAudioMeterOutput()
            let callbackAt = ProcessInfo.processInfo.systemUptime
            AppEventLog.event("RECORDING DID START CALLBACK", category: .recording, traceID: self.activeRecordingTraceID, fields: [
                "file": fileURL.lastPathComponent,
                "segment": String(self.recordingSegmentIndex),
                "startCallToCallbackMs": self.movieStartCallAt > 0 ? String(format: "%.2f", (callbackAt - self.movieStartCallAt) * 1000) : "unknown",
                "userRequestToCallbackMs": self.recordingRequestStartedAt > 0 ? String(format: "%.2f", (callbackAt - self.recordingRequestStartedAt) * 1000) : "unknown",
                "microphoneAuthorized": String(AVCaptureDevice.authorizationStatus(for: .audio).rawValue),
                "audioInputAttached": String(self.audioInput != nil)
            ])
            let splitDuration = self.recordingState.splitDuration

            self.transitionRecordingState(
                to: .recording(splitDuration: splitDuration),
                startClock: true
            )
            self.scheduleSplitTimer(splitDuration: splitDuration)

            // Validate and publish the recording state before collecting detailed diagnostics.
            // Snapshot formatting and disk I/O are handled asynchronously by AppEventLog.
            AppEventLog.event("Recording started: \(fileURL.lastPathComponent)", category: .recording, traceID: self.activeRecordingTraceID)
            self.logCaptureConfiguration(
                "delegate callback",
                label: "RECORDING START CALLBACK"
            )
            self.logSessionSnapshot("recording started")
        }
    }

    func fileOutput(_ output: AVCaptureFileOutput, didPauseRecordingTo fileURL: URL, from connections: [AVCaptureConnection]) {
        sessionQueue.async { [weak self] in
            self?.handleNativeRecordingPaused(output, fileURL: fileURL)
        }
    }

    func fileOutput(_ output: AVCaptureFileOutput, didResumeRecordingTo fileURL: URL, from connections: [AVCaptureConnection]) {
        sessionQueue.async { [weak self] in
            self?.handleNativeRecordingResumed(output, fileURL: fileURL)
        }
    }

    func fileOutput(_ output: AVCaptureFileOutput, didFinishRecordingTo outputFileURL: URL, from connections: [AVCaptureConnection], error: Error?) {
        let successful = error == nil || (error as NSError?)?.userInfo[AVErrorRecordingSuccessfullyFinishedKey] as? Bool == true

        sessionQueue.async { [weak self] in
            guard let self else { return }
            let errorDetail = error.map { " error=\($0.localizedDescription)" } ?? ""
            AppEventLog.event("RECORDING DID FINISH CALLBACK", category: .recording, level: successful ? .info : .warning,
                              traceID: self.activeRecordingTraceID, fields: [
                                "file": outputFileURL.lastPathComponent,
                                "success": String(successful),
                                "segment": String(self.recordingSegmentIndex),
                                "recordedDuration": String(format: "%.3f", self.movieOutput.recordedDuration.seconds),
                                "recordedBytes": String(self.movieOutput.recordedFileSize),
                                "error": error?.localizedDescription ?? "none"
                              ])
            AppEventLog.event("Recording finished: \(outputFileURL.lastPathComponent), success=\(successful)\(errorDetail)", category: .recording, traceID: self.activeRecordingTraceID)
            if let error { AppEventLog.log(error: error, prefix: "Recording delegate error", category: .recording, traceID: self.activeRecordingTraceID) }
            self.stopLiveMetrics()
            self.configureAudioMeterOutput()
            self.storageGuard.stopMonitoring()
            self.cancelSplitTimer()
            self.completeNativeRecordingStop(reason: "native recording finished")

            if self.recordingState.shouldDiscardWhenFinished {
                try? FileManager.default.removeItem(at: outputFileURL)
                self.transitionRecordingState(to: .idle, resetClock: true)
                self.storageProtectionStopIssued = false
                self.restoreIdleCaptureConfigurationAfterRecording()
                self.closeRecordingDiagnostics(reason: "recording discarded/cancelled", result: "cancelled")
                return
            }

            if successful, let sessionID = self.activeRecordingSessionID {
                let isSlowMotion = self.captureMode == .sloMo
                RecordingSessionStore.record(RecordingSessionSegment(
                    sessionID: sessionID,
                    segmentIndex: self.recordingSegmentIndex,
                    filename: outputFileURL.lastPathComponent,
                    mode: self.captureMode.rawValue,
                    cameraPosition: self.cameraPosition.rawValue,
                    resolution: (isSlowMotion ? self.selectedSlowMotionResolution : self.selectedResolution).rawValue,
                    frameRate: Double((isSlowMotion ? self.selectedSlowMotionFrameRate.rawValue : self.selectedFrameRate.rawValue)),
                    codec: self.activeVideoCodec,
                    compression: self.compressionDescription(for: self.captureMode),
                    duration: max(self.movieOutput.recordedDuration.seconds, 0),
                    recordedAt: Date()
                ))
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
                self.storageProtectionStopIssued = false
                self.restoreIdleCaptureConfigurationAfterRecording()
                let suffix = retained == nil ? "" : " It is kept in Recovery."
                self.showError("Recording stopped: \(error?.localizedDescription ?? "Unknown error").\(suffix)")
                self.closeRecordingDiagnostics(reason: "recording delegate failure", result: "failed")
                return
            }

            let diagnosticsEnabled = UserDefaults.standard.bool(forKey: "cameraHUDDroppedFrames")
            // Avoid decoding a completed split segment while the next HFR/4K segment is recording.
            self.saveVideoResourceToPhotos(
                outputFileURL,
                runDiagnostics: diagnosticsEnabled && !shouldContinue
            )

            if shouldContinue {
                self.recordingSegmentIndex += 1
                AppEventLog.event("RECORDING SPLIT CONTINUE", category: .recording, traceID: self.activeRecordingTraceID,
                                  fields: ["nextSegment": String(self.recordingSegmentIndex)])
                self.transitionRecordingState(to: .starting(splitDuration: splitDuration))
                self.beginRecording()
            } else {
                AppEventLog.event("========== RECORDING CAPTURE COMPLETE =========", category: .recording, traceID: self.activeRecordingTraceID,
                                  fields: ["segments": String(self.recordingSegmentIndex),
                                           "totalRequestLifetimeMs": self.recordingRequestStartedAt > 0 ? String(format: "%.2f", (ProcessInfo.processInfo.systemUptime - self.recordingRequestStartedAt) * 1000) : "unknown"])
                self.transitionRecordingState(to: .finalizing, resetClock: true)
                self.restoreIdleCaptureConfigurationAfterRecording()
                self.finishFinalizingIfPossible()
            }
        }
    }
}


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
                self.photoCaptureContexts.removeValue(forKey: captureID)
                self.burstStopRequested = true
            }
            showError(error.localizedDescription)
            return
        }
        guard let data = photo.fileDataRepresentation() else {
            sessionQueue.async {
                let trace = self.photoCaptureContexts[captureID]?.traceID
                AppEventLog.event("PHOTO FILE REPRESENTATION MISSING", category: .photo, level: .error, traceID: trace,
                                  fields: ["captureID": String(captureID)])
                self.photoCaptureContexts.removeValue(forKey: captureID)
                self.burstStopRequested = true
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

    private func completePhotoSave(captureID: Int64, context: PhotoCaptureContext, success: Bool) {
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
                self.burstStopRequested = true
                AppEventLog.event("Photo save failed: \(context.filename)")
            } else if !context.isBurst {
                self.postStatus("Photo saved to Photos")
                AppEventLog.event("Photo saved to Photos: \(context.filename)")
            } else if self.pendingPhotoSaves == 0,
                      self.activePhotoCaptureID == nil,
                      self.burstRemaining == 0 {
                self.postStatus("Photos saved to Photos")
            }

            if self.pendingPhotoSaves == 0 {
                self.refreshAvailableStorage()
            }
            self.refreshRecoveryCount()
            self.endBackgroundMediaSaveIfPossible()
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
            let context = self.photoCaptureContexts[captureID]
            self.activePhotoCaptureID = nil
            self.activePhotoCaptureIsBurst = false

            if let context {
                AppEventLog.event("PHOTO HARDWARE CAPTURE COMPLETE", category: wasBurst ? .burst : .photo, traceID: context.traceID, fields: [
                    "captureID": String(captureID),
                    "elapsedMs": String(format: "%.2f", (ProcessInfo.processInfo.systemUptime - context.startedAt) * 1000),
                    "error": error?.localizedDescription ?? "none"
                ])
            }

            if let error {
                self.photoCaptureContexts.removeValue(forKey: captureID)
                self.burstRemaining = 0
                self.burstStopRequested = false
                self.publish { self.isCapturingPhoto = false }
                if let context { AppEventLog.log(error: error, prefix: "PHOTO HARDWARE CAPTURE FAILED", category: .photo, traceID: context.traceID) }
                self.showError("Photo capture failed: \(error.localizedDescription)")
                return
            }

            if wasBurst {
                self.burstRemaining = max(0, self.burstRemaining - 1)
                if self.burstRemaining > 0 && !self.burstStopRequested && self.session.isRunning {
                    self.beginPhotoCapture()
                } else {
                    let captured = self.burstRequestedCount - self.burstRemaining
                    self.burstRemaining = 0
                    self.burstStopRequested = false
                    self.publish { self.isCapturingPhoto = false }
                    AppEventLog.event("========== BURST HARDWARE COMPLETE =========", category: .burst,
                                      traceID: self.activeBurstTraceID, fields: [
                        "requested": String(self.burstRequestedCount),
                        "captured": String(max(0, captured)),
                        "pendingSaves": String(self.pendingPhotoSaves)
                    ])
                    self.activeBurstTraceID = nil
                    self.burstRequestedCount = 0
                }
            } else {
                // The hardware capture is finished. Cropping, resizing and Photos-library
                // saving can continue on storageQueue without making the shutter feel stuck.
                self.publish { self.isCapturingPhoto = false }
            }
        }
    }
}
