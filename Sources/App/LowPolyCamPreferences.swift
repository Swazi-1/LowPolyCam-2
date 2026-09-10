import Foundation

/// Centralized UserDefaults keys, defaults, and compatibility normalization.
///
/// The camera code still reads the historical string keys so existing installs keep their
/// settings. This layer makes the schema explicit and repairs values written by older betas before
/// the first CameraManager is created.
enum LowPolyCamPreferences {
    static let currentSchemaVersion = 2

    enum Key {
        static let schemaVersion = "lowPolyCamSettingsSchemaVersion"
        static let appColorScheme = "appColorScheme"
        static let iconAppearance = "iconAppearance"
        static let iconCustomRed = "iconCustomRed"
        static let iconCustomGreen = "iconCustomGreen"
        static let iconCustomBlue = "iconCustomBlue"
        static let selectedVideoResolution = "selectedVideoResolution"
        static let selectedVideoFrameRate = "selectedVideoFrameRate"
        static let selectedVideoCodec = "selectedVideoCodec"
        static let videoCompression = "videoCompression"
        static let videoStabilizationEnabled = "videoStabilizationEnabled"
        static let selectedSlowMotionResolution = "selectedSlowMotionResolution"
        static let selectedSlowMotionFrameRate = "selectedSlowMotionFrameRate"
        static let selectedPhotoMegapixels = "selectedPhotoMegapixels"
        static let photoFileFormat = "photoFileFormat"
        static let photoFlashMode = "photoFlashMode"
        static let photoAspect = "photoAspect"
        static let burstCount = "burstCount"
        static let shutterDelay = "shutterDelay"
        static let hapticCaptureEnabled = "hapticCaptureEnabled"
        static let hapticStrength = "hapticStrength"
        static let countdownHaptics = "countdownHaptics"
        static let zoomSpeed = "zoomSpeed"
        static let tapZoomReset = "tapZoomReset"
        static let focusExposureLockMode = "focusExposureLockMode"
        static let tapFocusResetSeconds = "tapFocusResetSeconds"
        static let recordingLock = "recordingLock"
        static let lowStorageWarning = "lowStorageWarning"
        static let rememberCaptureMode = "rememberCaptureMode"
        static let lastCaptureMode = "lastCaptureMode"
        static let lastCameraPosition = "lastCameraPosition"
        static let mirrorSelfies = "mirrorSelfies"
        static let cameraGridEnabled = "cameraGridEnabled"
        static let gridOpacity = "gridOpacity"
        static let levelMeterEnabled = "levelMeterEnabled"
        static let centerCrosshair = "centerCrosshair"
        static let keepScreenAwakeEnabled = "keepScreenAwakeEnabled"
        static let cameraHUDEnabled = "cameraHUDEnabled"
        static let cameraHUDResolution = "cameraHUDResolution"
        static let cameraHUDFPS = "cameraHUDFPS"
        static let cameraHUDRemaining = "cameraHUDRemaining"
        static let cameraHUDWhiteBalance = "cameraHUDWhiteBalance"
        static let cameraHUDBattery = "cameraHUDBattery"
        static let cameraHUDStorage = "cameraHUDStorage"
        static let cameraHUDDroppedFrames = "cameraHUDDroppedFrames"
        static let thermalHUD = "thermalHUD"
        static let hudTextSize = "hudTextSize"
        static let liveRecordingStats = "liveRecordingStats"
        static let liveStatsX = "liveStatsX"
        static let liveStatsY = "liveStatsY"
        static let liveStatsSize = "liveStatsSize"
        static let liveStatsShowFPS = "liveStatsShowFPS"
        static let liveStatsShowBitrate = "liveStatsShowBitrate"
        static let liveStatsShowDrops = "liveStatsShowDrops"
        static let splitMinutes = "splitMinutes"
        static let longevityMode = "longevityMode"
        static let diagnosticLoggingEnabled = "diagnosticLoggingEnabled"
        static let mediaSequence = "lowPolyCamMediaSequence"
    }

    static func registerAndMigrate(_ defaults: UserDefaults = .standard) {
        migrateLegacyKeys(in: defaults)
        defaults.register(defaults: [
            Key.appColorScheme: "dark",
            Key.iconAppearance: "Ice",
            Key.iconCustomRed: 0.55,
            Key.iconCustomGreen: 0.85,
            Key.iconCustomBlue: 1.0,
            Key.selectedVideoResolution: "1080p",
            Key.selectedVideoFrameRate: 60,
            Key.selectedVideoCodec: "HEVC",
            Key.videoCompression: "High",
            Key.videoStabilizationEnabled: true,
            Key.selectedSlowMotionResolution: "1080p",
            Key.selectedSlowMotionFrameRate: 240,
            Key.selectedPhotoMegapixels: 12,
            Key.photoFileFormat: "HEIC",
            Key.photoFlashMode: "Auto",
            Key.photoAspect: "4:3",
            Key.burstCount: 10,
            Key.shutterDelay: 0,
            Key.hapticCaptureEnabled: true,
            Key.hapticStrength: "Medium",
            Key.countdownHaptics: false,
            Key.zoomSpeed: 1.0,
            Key.tapZoomReset: true,
            Key.focusExposureLockMode: "AE/AF",
            Key.tapFocusResetSeconds: 1,
            Key.recordingLock: false,
            Key.lowStorageWarning: true,
            Key.rememberCaptureMode: false,
            Key.lastCaptureMode: "VIDEO",
            Key.lastCameraPosition: "back",
            Key.mirrorSelfies: false,
            Key.cameraGridEnabled: false,
            Key.gridOpacity: 1.0,
            Key.levelMeterEnabled: false,
            Key.centerCrosshair: false,
            Key.keepScreenAwakeEnabled: false,
            Key.cameraHUDEnabled: true,
            Key.cameraHUDResolution: true,
            Key.cameraHUDFPS: true,
            Key.cameraHUDRemaining: true,
            Key.cameraHUDWhiteBalance: false,
            Key.cameraHUDBattery: true,
            Key.cameraHUDStorage: false,
            Key.cameraHUDDroppedFrames: false,
            Key.thermalHUD: false,
            Key.hudTextSize: 10.0,
            Key.liveRecordingStats: false,
            Key.liveStatsX: 0.5,
            Key.liveStatsY: 0.28,
            Key.liveStatsSize: "Normal",
            Key.liveStatsShowFPS: true,
            Key.liveStatsShowBitrate: true,
            Key.liveStatsShowDrops: true,
            Key.splitMinutes: 0,
            Key.longevityMode: false,
            Key.diagnosticLoggingEnabled: false,
            Key.mediaSequence: 0
        ])

        normalizeString(Key.appColorScheme, allowed: ["system", "light", "dark"], fallback: "dark", in: defaults)
        normalizeString(Key.iconAppearance, allowed: ["Ice", "Sunset", "Mint", "Lavender", "Coral", "Custom"], fallback: "Ice", in: defaults)
        normalizeString(Key.selectedVideoResolution, allowed: ["4K", "1080p", "720p"], fallback: "1080p", in: defaults)
        normalizeInt(Key.selectedVideoFrameRate, allowed: [24, 30, 60], fallback: 60, in: defaults)
        normalizeString(Key.selectedVideoCodec, allowed: ["HEVC", "H264"], fallback: "HEVC", in: defaults)
        normalizeString(Key.videoCompression, allowed: ["High", "Medium", "Data Saver"], fallback: "High", in: defaults)
        normalizeString(Key.selectedSlowMotionResolution, allowed: ["4K", "1080p", "720p"], fallback: "1080p", in: defaults)
        normalizeInt(Key.selectedSlowMotionFrameRate, allowed: [120, 240], fallback: 240, in: defaults)
        normalizeInt(Key.selectedPhotoMegapixels, allowed: [1, 2, 4, 8, 12], fallback: 12, in: defaults)
        normalizeString(Key.photoFileFormat, allowed: ["HEIC", "JPEG"], fallback: "HEIC", in: defaults)
        normalizeString(Key.photoFlashMode, allowed: ["Off", "Auto", "On"], fallback: "Auto", in: defaults)
        normalizeString(Key.photoAspect, allowed: ["4:3", "1:1"], fallback: "4:3", in: defaults)
        normalizeInt(Key.burstCount, allowed: [5, 10, 15], fallback: 10, in: defaults)
        normalizeInt(Key.shutterDelay, allowed: [0, 3, 10], fallback: 0, in: defaults)
        normalizeString(Key.hapticStrength, allowed: ["Low", "Medium", "Strong"], fallback: "Medium", in: defaults)
        normalizeString(Key.focusExposureLockMode, allowed: ["AE/AF", "AE Only", "AF Only"], fallback: "AE/AF", in: defaults)
        normalizeInt(Key.tapFocusResetSeconds, allowed: [0, 1, 3, 5], fallback: 1, in: defaults)
        normalizeString(Key.lastCaptureMode, allowed: ["VIDEO", "PHOTO", "SLO-MO"], fallback: "VIDEO", in: defaults)
        normalizeString(Key.lastCameraPosition, allowed: ["back", "front"], fallback: "back", in: defaults)
        normalizeString(Key.liveStatsSize, allowed: ["Compact", "Normal"], fallback: "Normal", in: defaults)
        normalizeInt(Key.splitMinutes, allowed: [0, 15, 30, 60, 120], fallback: 0, in: defaults)

        normalizeDouble(Key.iconCustomRed, minimum: 0, maximum: 1, fallback: 0.55, in: defaults)
        normalizeDouble(Key.iconCustomGreen, minimum: 0, maximum: 1, fallback: 0.85, in: defaults)
        normalizeDouble(Key.iconCustomBlue, minimum: 0, maximum: 1, fallback: 1.0, in: defaults)
        normalizeDouble(Key.zoomSpeed, minimum: 0.5, maximum: 2.0, fallback: 1.0, in: defaults)
        normalizeDouble(Key.gridOpacity, minimum: 0.1, maximum: 1.0, fallback: 1.0, in: defaults)
        normalizeDouble(Key.liveStatsX, minimum: 0, maximum: 1, fallback: 0.5, in: defaults)
        normalizeDouble(Key.liveStatsY, minimum: 0, maximum: 1, fallback: 0.28, in: defaults)
        normalizeDouble(Key.hudTextSize, minimum: 8, maximum: 16, fallback: 10, in: defaults)

        let storedVersion = defaults.object(forKey: Key.schemaVersion) as? Int ?? 0
        if storedVersion < currentSchemaVersion {
            AppEventLog.event("Preferences migrated: schema \(storedVersion) -> \(currentSchemaVersion)")
        }
        defaults.set(currentSchemaVersion, forKey: Key.schemaVersion)
    }

    private static func migrateLegacyKeys(in defaults: UserDefaults) {
        // Earlier builds used this shorter key in a few local experiments. Preserve it if the
        // current key has never been written rather than resetting the user's choice.
        if defaults.object(forKey: Key.keepScreenAwakeEnabled) == nil,
           let legacy = defaults.object(forKey: "keepScreenAwake") as? Bool {
            defaults.set(legacy, forKey: Key.keepScreenAwakeEnabled)
        }
    }

    private static func normalizeString(
        _ key: String,
        allowed: [String],
        fallback: String,
        in defaults: UserDefaults
    ) {
        guard let value = defaults.string(forKey: key), allowed.contains(value) else {
            defaults.set(fallback, forKey: key)
            return
        }
    }

    private static func normalizeInt(
        _ key: String,
        allowed: [Int],
        fallback: Int,
        in defaults: UserDefaults
    ) {
        let value = defaults.object(forKey: key) as? NSNumber
        guard let value, allowed.contains(value.intValue) else {
            defaults.set(fallback, forKey: key)
            return
        }
    }

    private static func normalizeDouble(
        _ key: String,
        minimum: Double,
        maximum: Double,
        fallback: Double,
        in defaults: UserDefaults
    ) {
        let value = defaults.object(forKey: key) as? NSNumber
        guard let value else {
            defaults.set(fallback, forKey: key)
            return
        }
        let number = value.doubleValue
        guard number.isFinite else {
            defaults.set(fallback, forKey: key)
            return
        }
        let clamped = min(max(number, minimum), maximum)
        if abs(clamped - number) > 0.000_001 {
            defaults.set(clamped, forKey: key)
        }
    }
}
