import AVFoundation
import Foundation
import Photos
import UIKit

/// Opt-in, ordered diagnostics. File I/O stays on its own utility queue and every session gets a
/// new numbered file so the log containing a crash is not destroyed by the next launch.
enum AppEventLog {
    struct CaptureConfigurationLogSnapshot {
        let label: String
        let context: String
        let isBackCamera: Bool
        let isVirtualDevice: Bool
        let deviceName: String
        let width: Int32
        let height: Int32
        let frameRate: Double
        let codec: String
        let bitRate: Int?
        let zoomFactor: Double
        let whiteBalance: String
        let torchOn: Bool = false
        let photoFlashMode: String = "Off"

        var formattedMessage: String {
            let bitRateText = bitRate.map { "\($0 / 1_000_000) Mbps target" } ?? "bitrate default"
            let lensKind = isVirtualDevice ? "virtual" : "physical"
            let zoomText = abs(zoomFactor.rounded() - zoomFactor) < 0.01
                ? "\(Int(zoomFactor.rounded()))×"
                : String(format: "%.1f×", zoomFactor)
            return "\(label) [\(context)]: \(isBackCamera ? "back" : "front") \(lensKind) \(deviceName), " +
                "\(width)x\(height) @ \(String(format: "%.1f", frameRate)) fps, " +
                "codec=\(codec), \(bitRateText), zoom=\(zoomText), WB=\(whiteBalance), " +
                "torch=\(torchOn), photoFlash=\(photoFlashMode)"
        }
    }

    struct SessionLogSnapshot {
        let context: String
        let isRunning: Bool
        let preset: String
        let mode: String
        let isBackCamera: Bool
        let recordingState: String
        let inputNames: [String]
        let outputNames: [String]
        let photoResponsive: Bool
        let liveMetricsAttached: Bool
        let availableStorageBytes: Int64 = -1
        let requestedResolution: String = "unknown"
        let requestedFrameRate: Int = 0
        let selectedCodec: String = "unknown"
        let compression: String = "unknown"
        let torchOn: Bool = false
        let photoFlashMode: String = "Off"
        let zoomFactor: Double = 1
        let exposureBias: Float = 0
        let whiteBalance: String = "Auto"
        let focusExposureLocked: Bool = false
        let microphoneAuthorized: String = "unknown"
        let microphoneAttached: Bool = false

        var formattedMessage: String {
            let storage = availableStorageBytes >= 0 ? "\(availableStorageBytes)" : "unknown"
            return "SESSION SNAPSHOT [\(context)]: running=\(isRunning), preset=\(preset), " +
                "mode=\(mode), position=\(isBackCamera ? "back" : "front"), recordingState=\(recordingState), " +
                "inputs=[\(inputNames.joined(separator: ", "))], outputs=[\(outputNames.joined(separator: ", "))], " +
                "photoResponsive=\(photoResponsive), liveMetricsAttached=\(liveMetricsAttached), " +
                "requested=\(requestedResolution)/\(requestedFrameRate)fps, codec=\(selectedCodec), " +
                "compression=\(compression), storage=\(storage), torch=\(torchOn), " +
                "photoFlash=\(photoFlashMode), zoom=\(String(format: "%.2f", zoomFactor)), " +
                "EV=\(String(format: "%.2f", exposureBias)), WB=\(whiteBalance), " +
                "AF/AE locked=\(focusExposureLocked), mic=\(microphoneAuthorized), " +
                "audioInput=\(microphoneAttached)"
        }
    }

    private static let diagnosticsKey = "diagnosticLoggingEnabled"
    private static let logFolderName = "LowPolyCam Logs"
    private static let logFilenamePrefix = "LowPolyCam-Log-"
    private static let queue = DispatchQueue(label: "com.swazi.lowpolycam.eventLog", qos: .utility)
    private static let timestampFormatter = ISO8601DateFormatter()
    private static var handle: FileHandle?
    private static var currentFilename: String?
    private static var hasStartedSession = false
    private static var loggingEnabledLocked = UserDefaults.standard.bool(forKey: diagnosticsKey)
    private static var defaultsObserver: NSObjectProtocol?
    private static var settingsSnapshot: [String: String] = [:]
    private static var settingsLogGeneration: UInt64 = 0
    private static var settingsLogScheduled = false
    private static let settingsLogDebounceNanoseconds: UInt64 = 100_000_000

    // Keep this list explicit. Dumping all of UserDefaults would include unrelated iOS framework
    // values while this records the preferences that can affect LowPolyCam behavior.
    private static let diagnosticSettings: [(key: String, defaultValue: String)] = [
        ("diagnosticLoggingEnabled", "false"),
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
        ("photoFlashMode", "Auto"),
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

    static var diagnosticsEnabled: Bool {
        UserDefaults.standard.bool(forKey: diagnosticsKey)
    }

    static func setDiagnosticsEnabled(_ enabled: Bool) {
        UserDefaults.standard.set(enabled, forKey: diagnosticsKey)
        queue.async {
            if enabled {
                loggingEnabledLocked = true
                beginNewSessionLocked()
            } else {
                disableLocked()
                loggingEnabledLocked = false
            }
        }
    }

    static func beginNewSession() {
        guard diagnosticsEnabled else { return }
        queue.async {
            loggingEnabledLocked = diagnosticsEnabled
            guard loggingEnabledLocked else { return }
            beginNewSessionLocked()
        }
    }

    static func event(_ message: String) {
        guard diagnosticsEnabled else { return }
        queue.async {
            guard loggingEnabledLocked else { return }
            beginNewSessionLocked()
            appendLocked(message)
        }
    }

    static func event(_ snapshot: CaptureConfigurationLogSnapshot) {
        guard diagnosticsEnabled else { return }
        queue.async {
            guard loggingEnabledLocked else { return }
            beginNewSessionLocked()
            appendLocked(snapshot.formattedMessage)
        }
    }

    static func event(_ snapshot: SessionLogSnapshot) {
        guard diagnosticsEnabled else { return }
        queue.async {
            guard loggingEnabledLocked else { return }
            beginNewSessionLocked()
            appendLocked(snapshot.formattedMessage)
        }
    }

    static func log(error: Error, prefix: String) {
        let nsError = error as NSError
        event("\(prefix): domain=\(nsError.domain), code=\(nsError.code), description=\(nsError.localizedDescription)")
    }

    static func flush() {
        guard diagnosticsEnabled else { return }
        queue.async {
            guard loggingEnabledLocked else { return }
            beginNewSessionLocked()
            flushPendingSettingsLogLocked()
            try? handle?.synchronize()
        }
    }

    private static func beginNewSessionLocked() {
        guard loggingEnabledLocked, !hasStartedSession else { return }
        let manager = FileManager.default
        guard let documents = manager.urls(for: .documentDirectory, in: .userDomainMask).first else { return }
        let folder = documents.appendingPathComponent(logFolderName, isDirectory: true)
        do {
            try manager.createDirectory(at: folder, withIntermediateDirectories: true)
        } catch {
            NSLog("LowPolyCam could not create its diagnostic log folder: %@", error.localizedDescription)
            return
        }

        let url = nextLogURLLocked(in: folder, manager: manager)
        guard manager.createFile(atPath: url.path, contents: nil) else {
            NSLog("LowPolyCam could not create its diagnostic log.")
            return
        }

        try? handle?.synchronize()
        try? handle?.close()
        handle = nil
        do {
            handle = try FileHandle(forWritingTo: url)
        } catch {
            NSLog("LowPolyCam could not open its diagnostic log: %@", error.localizedDescription)
            return
        }

        hasStartedSession = true
        currentFilename = url.lastPathComponent
        installDefaultsObserverLocked()
        settingsSnapshot = currentSettingsLocked()

        appendLocked("LowPolyCam diagnostic session started: file=\(url.lastPathComponent)")
        appendLocked("Environment: appVersion=\(Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "unknown"), build=\(Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "unknown")")
        appendLocked("Environment: device=\(UIDevice.current.model), iOS=\(UIDevice.current.systemVersion), locale=\(Locale.current.identifier), timezone=\(TimeZone.current.identifier)")
        appendLocked("Environment: thermal=\(thermalStateName(ProcessInfo.processInfo.thermalState)), lowPowerMode=\(ProcessInfo.processInfo.isLowPowerModeEnabled), physicalMemory=\(ProcessInfo.processInfo.physicalMemory)")
        let homeURL = URL(fileURLWithPath: NSHomeDirectory())
        let freeStorage = (try? homeURL.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey]))?.volumeAvailableCapacityForImportantUsage ?? -1
        appendLocked("Environment: freeStorageBytes=\(freeStorage)")
        appendLocked("Permissions: camera=\(authorizationName(AVCaptureDevice.authorizationStatus(for: .video))), microphone=\(authorizationName(AVCaptureDevice.authorizationStatus(for: .audio))), photosAddOnly=\(authorizationName(PHPhotoLibrary.authorizationStatus(for: .addOnly)))")
        appendLocked("Settings snapshot begin")
        for setting in diagnosticSettings {
            appendLocked("SETTING \(setting.key)=\(settingsSnapshot[setting.key] ?? setting.defaultValue)")
        }
        appendLocked("Settings snapshot end")
    }

    private static func disableLocked() {
        guard hasStartedSession || handle != nil else { return }
        appendLocked("LowPolyCam diagnostic logging disabled")
        flushPendingSettingsLogLocked()
        try? handle?.synchronize()
        try? handle?.close()
        handle = nil
        currentFilename = nil
        hasStartedSession = false
        settingsSnapshot = [:]
        settingsLogGeneration &+= 1
        settingsLogScheduled = false
    }

    private static func nextLogURLLocked(in folder: URL, manager: FileManager) -> URL {
        let existing = (try? manager.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)) ?? []
        let numbers = existing.compactMap { url -> Int? in
            let name = url.lastPathComponent
            guard name.hasPrefix(logFilenamePrefix), name.hasSuffix(".log") else { return nil }
            let start = name.index(name.startIndex, offsetBy: logFilenamePrefix.count)
            let end = name.index(name.endIndex, offsetBy: -4)
            return Int(name[start..<end])
        }
        var next = (numbers.max() ?? 0) + 1
        if next < 1 { next = 1 }
        while true {
            let filename = String(format: "%@%06d.log", logFilenamePrefix, next)
            let url = folder.appendingPathComponent(filename)
            if !manager.fileExists(atPath: url.path) { return url }
            next += 1
        }
    }

    private static func appendLocked(_ message: String) {
        guard let handle else { return }
        let timestamp = timestampFormatter.string(from: Date())
        guard let data = "[\(timestamp)] \(message)\n".data(using: .utf8) else { return }
        handle.write(data)
    }

    private static func installDefaultsObserverLocked() {
        guard defaultsObserver == nil else { return }
        defaultsObserver = NotificationCenter.default.addObserver(
            forName: UserDefaults.didChangeNotification,
            object: UserDefaults.standard,
            queue: nil
        ) { _ in
            queue.async {
                guard loggingEnabledLocked else { return }
                scheduleSettingsLogLocked()
            }
        }
    }

    /// UserDefaults can emit a notification for every intermediate value while a slider or color
    /// picker is being dragged. Coalesce that burst so diagnostics capture the final state.
    private static func scheduleSettingsLogLocked() {
        guard loggingEnabledLocked, hasStartedSession else { return }
        settingsLogGeneration &+= 1
        let generation = settingsLogGeneration
        settingsLogScheduled = true

        queue.asyncAfter(deadline: .now() + .nanoseconds(Int(settingsLogDebounceNanoseconds))) {
            guard loggingEnabledLocked, generation == settingsLogGeneration else { return }
            settingsLogScheduled = false
            logChangedSettingsLocked()
        }
    }

    private static func flushPendingSettingsLogLocked() {
        guard settingsLogScheduled else { return }
        settingsLogGeneration &+= 1
        settingsLogScheduled = false
        guard loggingEnabledLocked, hasStartedSession else { return }
        logChangedSettingsLocked()
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

    private static func authorizationName(_ status: AVAuthorizationStatus) -> String {
        switch status {
        case .authorized: return "authorized"
        case .denied: return "denied"
        case .restricted: return "restricted"
        case .notDetermined: return "notDetermined"
        @unknown default: return "unknown"
        }
    }

    private static func authorizationName(_ status: PHAuthorizationStatus) -> String {
        switch status {
        case .authorized: return "authorized"
        case .limited: return "limited"
        case .denied: return "denied"
        case .restricted: return "restricted"
        case .notDetermined: return "notDetermined"
        @unknown default: return "unknown"
        }
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
