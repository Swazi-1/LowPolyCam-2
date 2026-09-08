import Foundation
import UIKit

/// Keeps one lightweight, user-readable log for the current app run.
/// The next cold launch replaces it so diagnostics never accumulate indefinitely.
enum AppEventLog {
    private static let filename = "LowPolyCam-Session.log"
    private static let queue = DispatchQueue(label: "com.swazi.lowpolycam.eventLog", qos: .utility)
    private static let timestampFormatter = ISO8601DateFormatter()
    private static var handle: FileHandle?
    private static var hasStartedSession = false
    private static var defaultsObserver: NSObjectProtocol?
    private static var settingsSnapshot: [String: String] = [:]

    // Keep this list explicit. Dumping all of UserDefaults would include unrelated iOS
    // framework values, while this records every preference that can affect LowPolyCam.
    private static let diagnosticSettings: [(key: String, defaultValue: String)] = [
        ("appColorScheme", "system"),
        ("iconAppearance", "Ice"),
        ("iconCustomRed", "0.55"),
        ("iconCustomGreen", "0.85"),
        ("iconCustomBlue", "1.0"),
        ("selectedVideoResolution", "1080p"),
        ("selectedVideoFrameRate", "30"),
        ("selectedVideoCodec", "HEVC"),
        ("videoCompression", "High"),
        ("videoStabilizationEnabled", "true"),
        ("selectedSlowMotionResolution", "1080p"),
        ("selectedSlowMotionFrameRate", "240"),
        ("selectedPhotoMegapixels", "12"),
        ("photoFileFormat", "HEIC"),
        ("photoAspect", "4:3"),
        ("burstCount", "5"),
        ("shutterDelay", "0"),
        ("hapticCaptureEnabled", "true"),
        ("hapticStrength", "Medium"),
        ("countdownHaptics", "false"),
        ("zoomSpeed", "1.0"),
        ("tapZoomReset", "true"),
        ("recordingLock", "false"),
        ("lowStorageWarning", "true"),
        ("rememberCaptureMode", "false"),
        ("mirrorSelfies", "false"),
        ("centerCrosshair", "false"),
        ("cameraGridEnabled", "false"),
        ("gridOpacity", "1.0"),
        ("levelMeterEnabled", "true"),
        ("keepScreenAwakeEnabled", "false"),
        ("cameraHUDEnabled", "true"),
        ("cameraHUDResolution", "true"),
        ("cameraHUDFPS", "true"),
        ("cameraHUDRemaining", "true"),
        ("cameraHUDWhiteBalance", "false"),
        ("cameraHUDBattery", "false"),
        ("cameraHUDStorage", "false"),
        ("cameraHUDDroppedFrames", "false"),
        ("thermalHUD", "false"),
        ("hudTextSize", "10.0"),
        ("longevityMode", "false"),
        ("liveRecordingStats", "false"),
        ("liveStatsSize", "Normal"),
        ("liveStatsShowFPS", "true"),
        ("liveStatsShowBitrate", "true"),
        ("liveStatsShowDrops", "true"),
        ("liveStatsX", "0.5"),
        ("liveStatsY", "0.28"),
        ("splitMinutes", "0")
    ]

    static func beginNewSession() {
        // File I/O must never delay the first camera frame. The serial queue also preserves
        // event order: the reset always finishes before the first appended event.
        queue.async {
            beginNewSessionLocked()
        }
    }

    static func event(_ message: String) {
        queue.async {
            beginNewSessionLocked()
            appendLocked(message)
        }
    }

    static func flush() {
        queue.async {
            beginNewSessionLocked()
            try? handle?.synchronize()
        }
    }

    private static func beginNewSessionLocked() {
        guard !hasStartedSession else { return }
        hasStartedSession = true

        let manager = FileManager.default
        guard let documents = manager.urls(for: .documentDirectory, in: .userDomainMask).first else { return }
        let url = documents.appendingPathComponent(filename)

        try? handle?.close()
        handle = nil
        try? manager.removeItem(at: url)
        guard manager.createFile(atPath: url.path, contents: nil) else {
            NSLog("LowPolyCam could not create its session log.")
            return
        }
        do {
            handle = try FileHandle(forWritingTo: url)
        } catch {
            NSLog("LowPolyCam could not open its session log: %@", error.localizedDescription)
        }
        appendLocked("LowPolyCam session started")
        appendLocked("Environment: device=\(UIDevice.current.model), iOS=\(UIDevice.current.systemVersion), locale=\(Locale.current.identifier)")
        appendLocked("Environment: thermal=\(thermalStateName(ProcessInfo.processInfo.thermalState)), lowPowerMode=\(ProcessInfo.processInfo.isLowPowerModeEnabled)")
        installDefaultsObserverLocked()
        settingsSnapshot = currentSettingsLocked()
        appendLocked("Settings snapshot begin")
        for setting in diagnosticSettings {
            appendLocked("SETTING \(setting.key)=\(settingsSnapshot[setting.key] ?? setting.defaultValue)")
        }
        appendLocked("Settings snapshot end")
    }

    private static func appendLocked(_ message: String) {
        let timestamp = timestampFormatter.string(from: Date())
        let line = "[\(timestamp)] \(message)\n"
        guard let data = line.data(using: .utf8) else { return }
        handle?.write(data)
    }

    private static func installDefaultsObserverLocked() {
        guard defaultsObserver == nil else { return }
        defaultsObserver = NotificationCenter.default.addObserver(
            forName: UserDefaults.didChangeNotification,
            object: UserDefaults.standard,
            queue: nil
        ) { _ in
            queue.async {
                beginNewSessionLocked()
                logChangedSettingsLocked()
            }
        }
    }

    private static func logChangedSettingsLocked() {
        let current = currentSettingsLocked()
        for setting in diagnosticSettings {
            let oldValue = settingsSnapshot[setting.key] ?? setting.defaultValue
            let newValue = current[setting.key] ?? setting.defaultValue
            guard oldValue != newValue else { continue }
            appendLocked("SETTING CHANGED \(setting.key): \(oldValue) -> \(newValue)")
        }
        settingsSnapshot = current
    }

    private static func currentSettingsLocked() -> [String: String] {
        let defaults = UserDefaults.standard
        return Dictionary(uniqueKeysWithValues: diagnosticSettings.map { setting in
            let value = defaults.object(forKey: setting.key)
            return (setting.key, value.map { String(describing: $0) } ?? setting.defaultValue)
        })
    }

    private static func thermalStateName(_ state: ProcessInfo.ThermalState) -> String {
        switch state {
        case .nominal: return "nominal"
        case .fair: return "fair"
        case .serious: return "serious"
        case .critical: return "critical"
        @unknown default: return "unknown"
        }
    }
}
