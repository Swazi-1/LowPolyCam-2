import CoreGraphics
import Foundation

enum CompressionMode: String, CaseIterable, Codable, Identifiable {
    case auto = "Auto"
    case manual = "Manual"

    var id: String { rawValue }
}

enum AudioLevelMeterMode: String, CaseIterable, Codable, Identifiable {
    case off = "Off"
    case bars = "Bars"
    case decibels = "dB"

    var id: String { rawValue }

    /// Keep the historical stored value (`dB`) so existing installs migrate safely, while the
    /// user-facing name accurately describes the normalized digital audio measurement.
    var displayName: String {
        self == .decibels ? "dBFS" : rawValue
    }
}

enum CaptureOrientationPreference: String, CaseIterable, Codable, Identifiable {
    case auto = "Auto"
    case portrait = "Portrait"
    case landscapeLeft = "Landscape Left"
    case landscapeRight = "Landscape Right"

    var id: String { rawValue }
}

enum GridStyle: String, CaseIterable, Codable, Identifiable {
    case ruleOfThirds = "Rule of Thirds"
    case square = "Square"
    case diagonal = "Diagonal"
    case goldenRatio = "Golden Ratio"

    var id: String { rawValue }
}

enum CleanPreviewGesture: String, CaseIterable, Codable, Identifiable {
    case twoFingerTap = "Two-Finger Tap"
    case doubleTap = "Double Tap"
    case off = "Off"

    var id: String { rawValue }
}

enum RecordingStartCountdown: Int, CaseIterable, Codable, Identifiable {
    case off = 0
    case oneSecond = 1
    case threeSeconds = 3
    case fiveSeconds = 5

    var id: Int { rawValue }

    var label: String {
        rawValue == 0 ? "Off" : "\(rawValue) second\(rawValue == 1 ? "" : "s")"
    }
}

struct ManualBitrateRecommendation: Equatable {
    let minimumMbps: Double
    let recommendedMbps: Double
    let maximumMbps: Double
}

enum ManualBitratePolicy {
    static let minimumMbps = 1.0
    static let maximumMbps = 200.0
    static let defaultMbps = 50.0

    static func validatedMbps(_ value: Double, fallback: Double = defaultMbps) -> Double {
        let safeFallback = fallback.isFinite ? fallback : defaultMbps
        let candidate = value.isFinite ? value : safeFallback
        return min(max(candidate, minimumMbps), maximumMbps)
    }

    static func recommendation(
        resolution: VideoResolution,
        fps: Double,
        isSlowMotion: Bool,
        codec: String
    ) -> ManualBitrateRecommendation {
        let normalizedFPS = fps.isFinite ? max(fps, 0) : 30
        let base: (recommended: Double, maximum: Double)

        if isSlowMotion {
            switch resolution {
            case .p720:
                base = normalizedFPS >= 240 ? (30, 60) : (20, 40)
            case .p1080:
                base = normalizedFPS >= 240 ? (70, 140) : (45, 90)
            case .p4k:
                base = normalizedFPS >= 240 ? (100, 200) : (80, 160)
            }
        } else {
            switch resolution {
            case .p720:
                base = normalizedFPS >= 60 ? (10, 18) : (6, 12)
            case .p1080:
                base = normalizedFPS >= 60 ? (20, 40) : (12, 24)
            case .p4k:
                base = normalizedFPS >= 60 ? (70, 140) : (45, 80)
            }
        }

        // H.264 generally needs a little more bitrate than HEVC for the same visual
        // target. Keep the stored request untouched; this only shapes the effective range.
        let codecScale = codec.uppercased() == "H264" ? 1.12 : 1.0
        let maximum = min(
            Self.maximumMbps,
            max(Self.minimumMbps, (base.maximum * codecScale).rounded())
        )
        let recommended = min(
            maximum,
            max(Self.minimumMbps, (base.recommended * codecScale).rounded())
        )
        return ManualBitrateRecommendation(
            minimumMbps: Self.minimumMbps,
            recommendedMbps: recommended,
            maximumMbps: maximum
        )
    }

    static func effectiveMbps(
        requested: Double,
        resolution: VideoResolution,
        fps: Double,
        isSlowMotion: Bool,
        codec: String
    ) -> Double {
        let validated = validatedMbps(requested)
        let range = recommendation(
            resolution: resolution,
            fps: fps,
            isSlowMotion: isSlowMotion,
            codec: codec
        )
        return min(validated, range.maximumMbps)
    }

    static func bitsPerSecond(forMbps value: Double) -> Double {
        let bitsPerSecond = validatedMbps(value) * 1_000_000
        return bitsPerSecond.isFinite ? min(bitsPerSecond, Self.maximumMbps * 1_000_000) : defaultMbps * 1_000_000
    }
}

enum WhiteBalancePreferencePolicy {
    static let minimumTemperature = 2_500.0
    static let maximumTemperature = 10_000.0
    static let defaultTemperature = 5_200.0
    static let minimumTint = -150.0
    static let maximumTint = 150.0

    static func validatedTemperature(_ value: Double) -> Double {
        let candidate = value.isFinite ? value : defaultTemperature
        return min(max(candidate, minimumTemperature), maximumTemperature)
    }

    static func validatedTint(_ value: Double) -> Double {
        let candidate = value.isFinite ? value : 0
        return min(max(candidate, minimumTint), maximumTint)
    }
}

/// Normalized torch intensity policy. Apple's maximum torch-level value is a sentinel intended to
/// be passed directly to the API; it is not a physical multiplier. All
/// user-controlled intensity values therefore stay in the documented normalized 0...1 domain.
enum TorchLevelPolicy {
    static let minimumNormalizedLevel = 0.05
    static let maximumNormalizedLevel = 1.0
    static let defaultNormalizedLevel = 0.35

    static func validatedNormalized(_ value: Double, fallback: Double = defaultNormalizedLevel) -> Double {
        let safeFallback = fallback.isFinite ? fallback : defaultNormalizedLevel
        let candidate = value.isFinite ? value : safeFallback
        return min(max(candidate, minimumNormalizedLevel), maximumNormalizedLevel)
    }
}

struct CustomWhiteBalanceSubmission: Equatable {
    let temperature: Double
    let tint: Double
    let isFinal: Bool
}

/// Latest-value semantics used by the UI slider coalescer. The camera queue consumes one value,
/// so stale intermediate slider positions never become a hardware request.
struct CustomWhiteBalanceSubmissionQueue: Equatable {
    private(set) var pending: CustomWhiteBalanceSubmission?

    mutating func submit(_ value: CustomWhiteBalanceSubmission) {
        pending = value
    }

    mutating func consumeLatest() -> CustomWhiteBalanceSubmission? {
        defer { pending = nil }
        return pending
    }
}

enum AudioLevelMeterPolicy {
    static let minimumDBFS = -60.0
    static let clippingDBFS = -1.0
    static let defaultBarCount = 4

    static func barCount(
        forAveragePowerDBFS value: Double,
        barCount: Int = defaultBarCount
    ) -> Int {
        let count = max(barCount, 0)
        guard count > 0 else { return 0 }
        let safeValue = value.isFinite ? value : minimumDBFS
        let normalized = min(max((safeValue + 48.0) / 48.0, 0), 1)
        return min(count, max(0, Int((normalized * Double(count)).rounded(.up))))
    }
}

/// Fixed-slot contract shared by normal and Clean Preview shutter rows. The SwiftUI view keeps
/// the shutter in the center slot and swaps only the side-slot content as camera state changes.
enum ShutterRowLayoutPolicy {
    static let sideSlotWidth: CGFloat = 48
    static let shutterSlotWidth: CGFloat = 76
    static let rowHeight: CGFloat = 80

    static func shutterCenterX(in containerWidth: CGFloat) -> CGFloat {
        max(containerWidth, 0) / 2
    }
}

enum ZoomShortcutPolicy {
    static let defaultValues: [Double] = [0.5, 1.0, 2.0, 4.0]

    static func validated(_ values: [Double], minimum: Double = 0.5, maximum: Double = 100) -> [Double] {
        var result: [Double] = []
        for value in values {
            guard value.isFinite else { continue }
            let clamped = min(max(value, minimum), maximum)
            guard !result.contains(where: { abs($0 - clamped) < 0.01 }) else { continue }
            result.append(clamped)
        }
        return result
    }
}

enum RecordingPauseState: String, Codable, Equatable {
    case idle
    case recording
    case pausing
    case paused
    case resuming
    case stopping
}

/// Pure state transitions for the native AVCaptureFileOutput pause/resume lifecycle.
struct RecordingPauseMachine: Equatable {
    private(set) var state: RecordingPauseState = .idle

    mutating func start() -> Bool {
        guard state == .idle else { return false }
        state = .recording
        return true
    }

    mutating func requestPause() -> Bool {
        guard state == .recording else { return false }
        state = .pausing
        return true
    }

    mutating func confirmPaused() -> Bool {
        guard state == .pausing else { return false }
        state = .paused
        return true
    }

    mutating func requestResume() -> Bool {
        guard state == .paused else { return false }
        state = .resuming
        return true
    }

    mutating func confirmResumed() -> Bool {
        guard state == .resuming else { return false }
        state = .recording
        return true
    }

    mutating func requestStop() -> Bool {
        guard state == .recording || state == .pausing || state == .paused || state == .resuming else {
            return false
        }
        state = .stopping
        return true
    }

    mutating func completeStop() -> Bool {
        guard state == .stopping else { return false }
        state = .idle
        return true
    }

    mutating func reset() {
        state = .idle
    }
}

enum RecordingSplitTimingPolicy {
    static func remainingDuration(splitDuration: Double, recordedDuration: Double) -> Double {
        guard splitDuration.isFinite, splitDuration > 0 else { return 0 }
        let recorded = recordedDuration.isFinite ? max(recordedDuration, 0) : 0
        return max(splitDuration - recorded, 0)
    }

    static func shouldSplit(
        splitDuration: Double,
        recordedDuration: Double,
        pauseState: RecordingPauseState
    ) -> Bool {
        guard pauseState == .recording else { return false }
        return remainingDuration(splitDuration: splitDuration, recordedDuration: recordedDuration) <= 0.05
    }
}

enum RecordingCountdownState: Equatable {
    case idle
    case countingDown(remaining: Int)
}

struct RecordingCountdownMachine: Equatable {
    private(set) var state: RecordingCountdownState = .idle

    mutating func start(seconds: Int) -> Bool {
        guard [1, 3, 5].contains(seconds), state == .idle else { return false }
        state = .countingDown(remaining: seconds)
        return true
    }

    mutating func tick() -> Bool {
        guard case .countingDown(let remaining) = state else { return false }
        if remaining <= 1 {
            state = .idle
        } else {
            state = .countingDown(remaining: remaining - 1)
        }
        return true
    }

    mutating func cancel() -> Bool {
        guard state != .idle else { return false }
        state = .idle
        return true
    }
}

struct CameraPreset: Codable, Identifiable, Equatable {
    static let currentVersion = 1

    var id: UUID
    var name: String
    var version: Int
    var captureMode: String
    var videoResolution: String
    var videoFrameRate: Int
    var slowMotionResolution: String
    var slowMotionFrameRate: Int
    var codec: String
    var videoCompressionMode: String
    var videoCompressionLevel: String
    var videoManualBitrateMbps: Double
    var slowMotionCompressionMode: String
    var slowMotionCompressionLevel: String
    var slowMotionManualBitrateMbps: Double
    var zoom: Double
    var stabilization: Bool
    var whiteBalance: String
    var customWhiteBalanceTemperature: Double
    var customWhiteBalanceTint: Double
    var cameraPosition: String

    init(
        id: UUID = UUID(),
        name: String,
        captureMode: String,
        videoResolution: String,
        videoFrameRate: Int,
        slowMotionResolution: String,
        slowMotionFrameRate: Int,
        codec: String,
        videoCompressionMode: String,
        videoCompressionLevel: String,
        videoManualBitrateMbps: Double,
        slowMotionCompressionMode: String,
        slowMotionCompressionLevel: String,
        slowMotionManualBitrateMbps: Double,
        zoom: Double,
        stabilization: Bool,
        whiteBalance: String,
        customWhiteBalanceTemperature: Double,
        customWhiteBalanceTint: Double,
        cameraPosition: String,
        version: Int = currentVersion
    ) {
        self.id = id
        self.name = name
        self.version = version
        self.captureMode = captureMode
        self.videoResolution = videoResolution
        self.videoFrameRate = videoFrameRate
        self.slowMotionResolution = slowMotionResolution
        self.slowMotionFrameRate = slowMotionFrameRate
        self.codec = codec
        self.videoCompressionMode = videoCompressionMode
        self.videoCompressionLevel = videoCompressionLevel
        self.videoManualBitrateMbps = videoManualBitrateMbps
        self.slowMotionCompressionMode = slowMotionCompressionMode
        self.slowMotionCompressionLevel = slowMotionCompressionLevel
        self.slowMotionManualBitrateMbps = slowMotionManualBitrateMbps
        self.zoom = zoom
        self.stabilization = stabilization
        self.whiteBalance = whiteBalance
        self.customWhiteBalanceTemperature = customWhiteBalanceTemperature
        self.customWhiteBalanceTint = customWhiteBalanceTint
        self.cameraPosition = cameraPosition
    }

    func migrated() -> CameraPreset {
        var result = self
        result.version = Self.currentVersion
        result.name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        if result.name.isEmpty { result.name = "Custom Preset" }
        if !["VIDEO", "PHOTO", "SLO-MO"].contains(result.captureMode) { result.captureMode = "VIDEO" }
        if !["4K", "1080p", "720p"].contains(result.videoResolution) { result.videoResolution = "1080p" }
        if ![24, 30, 60].contains(result.videoFrameRate) { result.videoFrameRate = 60 }
        if !["4K", "1080p", "720p"].contains(result.slowMotionResolution) { result.slowMotionResolution = "1080p" }
        if ![120, 240].contains(result.slowMotionFrameRate) { result.slowMotionFrameRate = 240 }
        if !["HEVC", "H264"].contains(result.codec) { result.codec = "HEVC" }
        if ![CompressionMode.auto.rawValue, CompressionMode.manual.rawValue].contains(result.videoCompressionMode) {
            result.videoCompressionMode = CompressionMode.auto.rawValue
        }
        if !VideoCompression.allCases.map(\.rawValue).contains(result.videoCompressionLevel) {
            result.videoCompressionLevel = VideoCompression.high.rawValue
        }
        if ![CompressionMode.auto.rawValue, CompressionMode.manual.rawValue].contains(result.slowMotionCompressionMode) {
            result.slowMotionCompressionMode = CompressionMode.auto.rawValue
        }
        if !VideoCompression.allCases.map(\.rawValue).contains(result.slowMotionCompressionLevel) {
            result.slowMotionCompressionLevel = VideoCompression.high.rawValue
        }
        result.videoManualBitrateMbps = ManualBitratePolicy.validatedMbps(result.videoManualBitrateMbps)
        result.slowMotionManualBitrateMbps = ManualBitratePolicy.validatedMbps(result.slowMotionManualBitrateMbps)
        result.zoom = result.zoom.isFinite ? min(max(result.zoom, 0.5), 100) : 1
        if !CameraManager.WhiteBalancePreset.allCases.map(\.rawValue).contains(result.whiteBalance) {
            result.whiteBalance = CameraManager.WhiteBalancePreset.auto.rawValue
        }
        result.customWhiteBalanceTemperature = WhiteBalancePreferencePolicy.validatedTemperature(result.customWhiteBalanceTemperature)
        result.customWhiteBalanceTint = WhiteBalancePreferencePolicy.validatedTint(result.customWhiteBalanceTint)
        if !["back", "front"].contains(result.cameraPosition) { result.cameraPosition = "back" }
        return result
    }

    private enum CodingKeys: String, CodingKey {
        case id, name, version, captureMode, videoResolution, videoFrameRate
        case slowMotionResolution, slowMotionFrameRate, codec
        case videoCompressionMode, videoCompressionLevel, videoManualBitrateMbps
        case slowMotionCompressionMode, slowMotionCompressionLevel, slowMotionManualBitrateMbps
        case zoom, stabilization, whiteBalance, customWhiteBalanceTemperature
        case customWhiteBalanceTint, cameraPosition
    }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            id: try values.decodeIfPresent(UUID.self, forKey: .id) ?? UUID(),
            name: try values.decodeIfPresent(String.self, forKey: .name) ?? "Custom Preset",
            captureMode: try values.decodeIfPresent(String.self, forKey: .captureMode) ?? "VIDEO",
            videoResolution: try values.decodeIfPresent(String.self, forKey: .videoResolution) ?? "1080p",
            videoFrameRate: try values.decodeIfPresent(Int.self, forKey: .videoFrameRate) ?? 60,
            slowMotionResolution: try values.decodeIfPresent(String.self, forKey: .slowMotionResolution) ?? "1080p",
            slowMotionFrameRate: try values.decodeIfPresent(Int.self, forKey: .slowMotionFrameRate) ?? 240,
            codec: try values.decodeIfPresent(String.self, forKey: .codec) ?? "HEVC",
            videoCompressionMode: try values.decodeIfPresent(String.self, forKey: .videoCompressionMode) ?? CompressionMode.auto.rawValue,
            videoCompressionLevel: try values.decodeIfPresent(String.self, forKey: .videoCompressionLevel) ?? VideoCompression.high.rawValue,
            videoManualBitrateMbps: try values.decodeIfPresent(Double.self, forKey: .videoManualBitrateMbps) ?? ManualBitratePolicy.defaultMbps,
            slowMotionCompressionMode: try values.decodeIfPresent(String.self, forKey: .slowMotionCompressionMode) ?? CompressionMode.auto.rawValue,
            slowMotionCompressionLevel: try values.decodeIfPresent(String.self, forKey: .slowMotionCompressionLevel) ?? VideoCompression.high.rawValue,
            slowMotionManualBitrateMbps: try values.decodeIfPresent(Double.self, forKey: .slowMotionManualBitrateMbps) ?? ManualBitratePolicy.defaultMbps,
            zoom: try values.decodeIfPresent(Double.self, forKey: .zoom) ?? 1,
            stabilization: try values.decodeIfPresent(Bool.self, forKey: .stabilization) ?? true,
            whiteBalance: try values.decodeIfPresent(String.self, forKey: .whiteBalance) ?? CameraManager.WhiteBalancePreset.auto.rawValue,
            customWhiteBalanceTemperature: try values.decodeIfPresent(Double.self, forKey: .customWhiteBalanceTemperature) ?? WhiteBalancePreferencePolicy.defaultTemperature,
            customWhiteBalanceTint: try values.decodeIfPresent(Double.self, forKey: .customWhiteBalanceTint) ?? 0,
            cameraPosition: try values.decodeIfPresent(String.self, forKey: .cameraPosition) ?? "back",
            version: try values.decodeIfPresent(Int.self, forKey: .version) ?? 0
        )
    }
}

enum CameraPresetStore {
    private static let key = "customCameraPresets"

    static func load(from defaults: UserDefaults = .standard) -> [CameraPreset] {
        guard let data = defaults.data(forKey: key) else { return [] }
        do {
            return try JSONDecoder().decode([CameraPreset].self, from: data).map { preset in
                let migrated = preset.migrated()
                if migrated != preset {
                    AppEventLog.event("CUSTOM PRESET MIGRATED", category: .settings, fields: [
                        "name": migrated.name,
                        "fromVersion": String(preset.version),
                        "toVersion": String(migrated.version)
                    ])
                }
                return migrated
            }
        } catch {
            AppEventLog.log(error: error, prefix: "CUSTOM PRESET MIGRATION FAILED", category: .settings)
            return []
        }
    }

    static func save(_ presets: [CameraPreset], to defaults: UserDefaults = .standard) {
        do {
            let data = try JSONEncoder().encode(presets.map { $0.migrated() })
            defaults.set(data, forKey: key)
        } catch {
            AppEventLog.log(error: error, prefix: "CUSTOM PRESET SAVE FAILED", category: .settings)
        }
    }
}
