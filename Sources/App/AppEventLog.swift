import AVFoundation
import Foundation
import Photos
import UIKit

/// Opt-in, ordered bug-forensics diagnostics. Callers never perform file I/O; records are formatted
/// at the call site, queued on a utility queue, and batch-written so camera/session work is not held
/// up by diagnostics. Extreme mode adds trace IDs, state/guard breadcrumbs, transition probes, and a
/// received/committed timing envelopes around normal events without changing normal diagnostics.
/// High-frequency per-frame evidence keeps its source record but uses a lightweight queue-delay
/// field instead of two extra envelope records, reducing observer pressure during bug probes.
enum AppEventLog {
    enum Level: String {
        case trace = "TRACE"
        case debug = "DEBUG"
        case info = "INFO"
        case warning = "WARN"
        case error = "ERROR"
    }

    enum Category: String {
        case app = "APP"
        case ui = "UI"
        case session = "SESSION"
        case device = "DEVICE"
        case format = "FORMAT"
        case zoom = "ZOOM"
        case lens = "LENS"
        case photo = "PHOTO"
        case burst = "BURST"
        case video = "VIDEO"
        case slowMotion = "SLOMO"
        case recording = "RECORDING"
        case audio = "AUDIO"
        case whiteBalance = "WB"
        case exposure = "EXPOSURE"
        case focus = "FOCUS"
        case flash = "FLASH"
        case torch = "TORCH"
        case storage = "STORAGE"
        case save = "SAVE"
        case settings = "SETTINGS"
        case request = "REQUEST"
        case performance = "PERFORMANCE"
        case traceContext = "TRACE_CTX"
        case thermal = "THERMAL"
        case error = "ERROR"
    }

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
        let torchOn: Bool
        let photoFlashMode: String

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
        let availableStorageBytes: Int64
        let requestedResolution: String
        let requestedFrameRate: Int
        let selectedCodec: String
        let compression: String
        let torchOn: Bool
        let photoFlashMode: String
        let zoomFactor: Double
        let exposureBias: Float
        let whiteBalance: String
        let focusExposureLocked: Bool
        let microphoneAuthorized: String
        let microphoneAttached: Bool

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

    final class TraceSpan {
        let id: String
        let category: Category
        let name: String
        private let startedAt = ProcessInfo.processInfo.systemUptime
        private var lastStepAt = ProcessInfo.processInfo.systemUptime
        private let lock = NSLock()
        private var ended = false

        fileprivate init(id: String, category: Category, name: String, fields: [String: String]) {
            self.id = id
            self.category = category
            self.name = name
            AppEventLog.structured(.trace, category, "BEGIN \(name)", traceID: id, fields: fields)
        }

        func step(_ message: String, fields: [String: String] = [:]) {
            lock.lock()
            guard !ended else { lock.unlock(); return }
            let now = ProcessInfo.processInfo.systemUptime
            let delta = (now - lastStepAt) * 1000
            let total = (now - startedAt) * 1000
            lastStepAt = now
            lock.unlock()
            var values = fields
            values["stepMs"] = String(format: "%.2f", delta)
            values["totalMs"] = String(format: "%.2f", total)
            AppEventLog.structured(.trace, category, "STEP \(name): \(message)", traceID: id, fields: values)
        }

        func end(result: String = "success", fields: [String: String] = [:]) {
            lock.lock()
            guard !ended else { lock.unlock(); return }
            ended = true
            let total = (ProcessInfo.processInfo.systemUptime - startedAt) * 1000
            lock.unlock()
            var values = fields
            values["result"] = result
            values["totalMs"] = String(format: "%.2f", total)
            AppEventLog.structured(result == "success" ? .trace : .warning, category, "END \(name)", traceID: id, fields: values)
        }
    }

    struct QueueTicket {
        let traceID: String
        let category: Category
        let name: String
        let scheduledAt: TimeInterval
    }

    private struct PendingRecord {
        let level: Level
        let category: Category
        let message: String
        let traceID: String?
        let fields: [String: String]
        let function: String
        let file: String
        let line: UInt
        let callerThread: String
        let callUptime: TimeInterval
    }

    private static let diagnosticsKey = "diagnosticLoggingEnabled"
    private static let extremeDiagnosticsKey = "diagnosticExtremeLoggingEnabled"
    private static let extremeDiagnosticsMigrationKey = "diagnosticExtremeLoggingDefaultMigrated"
    private static let logFolderName = "LowPolyCam Logs"
    private static let logFilenamePrefix = "LowPolyCam-Log-"
    private static let queue = DispatchQueue(label: "com.swazi.lowpolycam.eventLog", qos: .utility)
    private static let timestampFormatter = ISO8601DateFormatter()
    private static let startUptime = ProcessInfo.processInfo.systemUptime
    private static let traceLock = NSLock()
    private static var traceCounter: UInt64 = 0
    private static var handle: FileHandle?
    private static var currentFilename: String?
    private static var hasStartedSession = false
    private static var loggingEnabledLocked = UserDefaults.standard.bool(forKey: diagnosticsKey)
    private static var defaultsObserver: NSObjectProtocol?
    private static var systemObservers: [NSObjectProtocol] = []
    private static var settingsSnapshot: [String: String] = [:]
    private static var settingsLogGeneration: UInt64 = 0
    private static var settingsLogScheduled = false
    private static var settingsRevision: UInt64 = 0
    private static var lastSettingsChangeUptime: TimeInterval?
    private static let settingsLogDebounceNanoseconds: UInt64 = 100_000_000
    private static var eventCounter: UInt64 = 0
    private static var warningCount: UInt64 = 0
    private static var errorCount: UInt64 = 0
    private static var invariantCount: UInt64 = 0
    private static var staleRequestCount: UInt64 = 0
    private static var categoryCounts: [Category: UInt64] = [:]
    private static var writeBuffer = ""
    private static var writeFlushScheduled = false
    private static let writeFlushInterval = 0.20
    private static let writeFlushThreshold = 64 * 1024

    private static let diagnosticSettings: [(key: String, defaultValue: String)] = [
        ("diagnosticLoggingEnabled", "false"),
        ("diagnosticExtremeLoggingEnabled", "false"),
        ("appColorScheme", "dark"),
        ("iconAppearance", "Ice"),
        ("iconCustomRed", "0.55"), ("iconCustomGreen", "0.85"), ("iconCustomBlue", "1.0"),
        ("selectedVideoResolution", "1080p"), ("selectedVideoFrameRate", "60"),
        ("selectedVideoCodec", "HEVC"), ("videoCompression", "High"),
        ("videoCompressionMode", "Auto"), ("videoManualBitrateMbps", "50.0"),
        ("videoStabilizationEnabled", "true"),
        ("selectedSlowMotionResolution", "1080p"), ("selectedSlowMotionFrameRate", "240"),
        ("slowMotionCompressionMode", "Auto"), ("slowMotionCompressionLevel", "High"),
        ("slowMotionManualBitrateMbps", "50.0"),
        ("selectedPhotoMegapixels", "12"), ("photoFileFormat", "HEIC"),
        ("photoFlashMode", "Auto"), ("photoAspect", "4:3"), ("photoCaptureFlash", "true"),
        ("frontScreenFlash", "false"), ("burstCount", "10"),
        ("shutterDelay", "0"), ("hapticCaptureEnabled", "true"), ("hapticStrength", "Medium"),
        ("countdownHaptics", "false"), ("zoomSpeed", "1.0"), ("tapZoomReset", "true"),
        ("focusExposureLockMode", "AE/AF"), ("tapFocusResetSeconds", "1"),
        ("recordingLock", "false"), ("lowStorageWarning", "true"),
        ("rememberCaptureMode", "false"), ("lastCaptureMode", "VIDEO"), ("lastCameraPosition", "back"),
        ("mirrorSelfies", "false"), ("centerCrosshair", "false"), ("cameraGridEnabled", "false"),
        ("gridOpacity", "1.0"), ("gridStyle", "Rule of Thirds"), ("frameGuidesEnabled", "false"),
        ("levelMeterEnabled", "false"), ("audioLevelMeter", "Bars"), ("audioPeakHold", "true"),
        ("cleanPreviewGesture", "Double Tap"), ("captureOrientation", "Auto"),
        ("recordingStartCountdown", "0"), ("whiteBalancePreset", "Auto"),
        ("customWhiteBalanceTemperature", "5200.0"), ("customWhiteBalanceTint", "0.0"),
        ("torchBrightness", "0.4"), ("zoomButton1", "0.5"), ("zoomButton2", "1.0"),
        ("zoomButton3", "2.0"), ("zoomButton4", "4.0"), ("zoomButton5", "8.0"),
        ("zoomButtonCount", "4"), ("zoomButtonsEnabled", "false"), ("customCameraPresets", ""),
        ("keepScreenAwakeEnabled", "false"),
        ("cameraHUDEnabled", "true"), ("cameraHUDResolution", "true"), ("cameraHUDFPS", "true"),
        ("cameraHUDRemaining", "false"), ("cameraHUDWhiteBalance", "false"), ("cameraHUDLens", "false"), ("cameraHUDBattery", "true"),
        ("cameraHUDStorage", "false"), ("cameraHUDDroppedFrames", "false"), ("thermalHUD", "false"),
        ("hudTextSize", "10.0"), ("longevityMode", "false"), ("liveRecordingStats", "false"),
        ("liveStatsSize", "Normal"), ("liveStatsShowFPS", "true"), ("liveStatsShowBitrate", "true"),
        ("liveStatsShowDrops", "true"), ("liveStatsX", "0.5"), ("liveStatsY", "0.28"),
        ("splitMinutes", "0")
    ]

    static var diagnosticsEnabled: Bool {
        UserDefaults.standard.bool(forKey: diagnosticsKey)
    }

    /// Extreme is an explicit opt-in layer on top of normal diagnostics. It never activates while
    /// diagnostic logging is off, and a missing preference is always treated as false.
    static var extremeDiagnosticsEnabled: Bool {
        let defaults = UserDefaults.standard
        guard diagnosticsEnabled else { return false }
        return defaults.bool(forKey: extremeDiagnosticsKey)
    }

    /// v5.0.12 briefly treated a missing Extreme preference as enabled and wrote `true` when
    /// normal diagnostics were enabled. Clear that legacy auto-enabled value once so an existing
    /// install follows the new explicit opt-in contract. A user can enable Extreme again from
    /// Settings after this migration, and that deliberate choice is preserved.
    static func normalizeExtremeDiagnosticsPreference() {
        let defaults = UserDefaults.standard
        guard !defaults.bool(forKey: extremeDiagnosticsMigrationKey) else { return }
        defaults.set(false, forKey: extremeDiagnosticsKey)
        defaults.set(true, forKey: extremeDiagnosticsMigrationKey)
    }

    static func setDiagnosticsEnabled(_ enabled: Bool) {
        let defaults = UserDefaults.standard
        if enabled, defaults.object(forKey: extremeDiagnosticsKey) == nil {
            defaults.set(false, forKey: extremeDiagnosticsKey)
        }
        defaults.set(enabled, forKey: diagnosticsKey)
        queue.async {
            if enabled {
                loggingEnabledLocked = true
                beginNewSessionLocked()
                appendRecordWithDiagnosticsEnvelopeLocked(
                    PendingRecord(level: .info, category: .settings, message: "Diagnostic logging enabled", traceID: nil,
                                  fields: ["extreme": String(extremeDiagnosticsEnabled)], function: "setDiagnosticsEnabled", file: "AppEventLog.swift", line: 0,
                                  callerThread: "settings", callUptime: ProcessInfo.processInfo.systemUptime)
                )
            } else {
                disableLocked()
                loggingEnabledLocked = false
            }
        }
    }

    static func setExtremeDiagnosticsEnabled(_ enabled: Bool) {
        UserDefaults.standard.set(enabled, forKey: extremeDiagnosticsKey)
        event("Extreme bug trace \(enabled ? "enabled" : "disabled")", category: .settings, level: .info)
    }

    static func beginNewSession() {
        guard diagnosticsEnabled else { return }
        queue.async {
            loggingEnabledLocked = diagnosticsEnabled
            guard loggingEnabledLocked else { return }
            beginNewSessionLocked()
        }
    }

    static func logURLs() -> [URL] {
        let folder = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first?
            .appendingPathComponent(logFolderName, isDirectory: true)
        guard let folder else { return [] }
        return ((try? FileManager.default.contentsOfDirectory(
            at: folder,
            includingPropertiesForKeys: [.contentModificationDateKey],
            options: [.skipsHiddenFiles]
        )) ?? [])
            .filter { $0.lastPathComponent.hasPrefix(logFilenamePrefix) && $0.pathExtension.lowercased() == "log" }
            .sorted { lhs, rhs in
                lhs.lastPathComponent.localizedStandardCompare(rhs.lastPathComponent) == .orderedAscending
            }
    }

    static func latestLogURL() -> URL? {
        logURLs().last
    }

    static func deleteArchivedLogs() {
        queue.async {
            flushPendingSettingsLogLocked()
            flushWriteBufferLocked()
            try? handle?.synchronize()
            let current = currentFilename
            let files = logURLs()
            var deleted = 0
            var failures = 0
            for file in files where file.lastPathComponent != current {
                do {
                    try FileManager.default.removeItem(at: file)
                    deleted += 1
                } catch {
                    failures += 1
                    NSLog("LowPolyCam could not delete diagnostic log: %@", error.localizedDescription)
                }
            }
            event(
                "Archived diagnostic logs deleted",
                category: .settings,
                level: failures == 0 ? .info : .warning,
                fields: ["deleted": String(deleted), "failures": String(failures)]
            )
        }
    }

    /// Compatibility entry point used throughout the app. Existing calls now automatically receive
    /// event number, elapsed time, source file/function/line and caller-thread information.
    static func event(
        _ message: String,
        category: Category = .app,
        level: Level = .info,
        traceID: String? = nil,
        fields: [String: String] = [:],
        function: StaticString = #function,
        file: StaticString = #fileID,
        line: UInt = #line
    ) {
        structured(level, category, message, traceID: traceID, fields: fields, function: function, file: file, line: line)
    }

    static func deepEvent(
        _ message: String,
        category: Category,
        level: Level = .trace,
        traceID: String? = nil,
        fields: [String: String] = [:],
        function: StaticString = #function,
        file: StaticString = #fileID,
        line: UInt = #line
    ) {
        guard extremeDiagnosticsEnabled else { return }
        structured(level, category, message, traceID: traceID, fields: fields, function: function, file: file, line: line)
    }

    static func event(_ snapshot: CaptureConfigurationLogSnapshot) {
        structured(.info, .format, snapshot.formattedMessage)
    }

    static func event(_ snapshot: SessionLogSnapshot) {
        structured(.info, .session, snapshot.formattedMessage)
    }

    static func makeTraceID(_ prefix: String) -> String {
        traceLock.lock()
        traceCounter &+= 1
        let value = traceCounter
        traceLock.unlock()
        let normalized = prefix.uppercased().replacingOccurrences(of: " ", with: "-")
        return String(format: "%@-%06llu", normalized, value)
    }

    @discardableResult
    static func beginTrace(
        _ name: String,
        category: Category,
        traceID: String? = nil,
        fields: [String: String] = [:]
    ) -> TraceSpan? {
        guard extremeDiagnosticsEnabled else { return nil }
        return TraceSpan(id: traceID ?? makeTraceID(name), category: category, name: name, fields: fields)
    }

    static func guardRejected(
        _ operation: String,
        reason: String,
        traceID: String? = nil,
        fields: [String: String] = [:],
        function: StaticString = #function,
        file: StaticString = #fileID,
        line: UInt = #line
    ) {
        guard extremeDiagnosticsEnabled else { return }
        var values = fields
        values["reason"] = reason
        structured(.warning, .request, "REQUEST REJECTED: \(operation)", traceID: traceID, fields: values, function: function, file: file, line: line)
    }

    static func staleRequest(
        token: String,
        requestID: UInt64,
        latestID: UInt64,
        operation: String,
        traceID: String? = nil
    ) {
        guard extremeDiagnosticsEnabled else { return }
        structured(.trace, .request, "STALE REQUEST DROPPED: \(operation)", traceID: traceID, fields: [
            "token": token,
            "requestID": String(requestID),
            "latestID": String(latestID)
        ])
        queue.async { staleRequestCount &+= 1 }
    }

    static func invariant(
        _ name: String,
        expected: String,
        actual: String,
        traceID: String? = nil,
        fields: [String: String] = [:]
    ) {
        guard diagnosticsEnabled else { return }
        var values = fields
        values["expected"] = expected
        values["actual"] = actual
        structured(.error, .error, "!!! POSSIBLE BUG / INVARIANT VIOLATION !!! \(name)", traceID: traceID, fields: values)
        queue.async { invariantCount &+= 1 }
    }

    static func stateDiff(
        _ name: String,
        before: [String: String],
        after: [String: String],
        traceID: String? = nil,
        category: Category = .session
    ) {
        guard extremeDiagnosticsEnabled else { return }
        var changes: [String: String] = [:]
        for key in Set(before.keys).union(after.keys).sorted() {
            let old = before[key] ?? "<missing>"
            let new = after[key] ?? "<missing>"
            if old != new { changes[key] = "\(old) -> \(new)" }
        }
        if changes.isEmpty {
            deepEvent("STATE DIFF \(name): unchanged", category: category, traceID: traceID)
        } else {
            deepEvent("STATE DIFF \(name)", category: category, traceID: traceID, fields: changes)
        }
    }

    static func queueScheduled(_ name: String, category: Category, traceID: String? = nil) -> QueueTicket? {
        guard extremeDiagnosticsEnabled else { return nil }
        let id = traceID ?? makeTraceID(name)
        let ticket = QueueTicket(traceID: id, category: category, name: name, scheduledAt: ProcessInfo.processInfo.systemUptime)
        deepEvent("QUEUE SCHEDULED: \(name)", category: category, traceID: id)
        return ticket
    }

    static func queueStarted(_ ticket: QueueTicket?) {
        guard let ticket else { return }
        let wait = (ProcessInfo.processInfo.systemUptime - ticket.scheduledAt) * 1000
        deepEvent("QUEUE STARTED: \(ticket.name)", category: ticket.category, traceID: ticket.traceID,
                  fields: ["queueWaitMs": String(format: "%.2f", wait)])
        if wait > 100 {
            event("SLOW QUEUE WAIT: \(ticket.name)", category: .performance, level: .warning, traceID: ticket.traceID,
                  fields: ["queueWaitMs": String(format: "%.2f", wait)])
        }
    }

    static func log(error: Error, prefix: String, category: Category = .error, traceID: String? = nil) {
        let nsError = error as NSError
        var fields: [String: String] = [
            "domain": nsError.domain,
            "code": String(nsError.code),
            "description": nsError.localizedDescription
        ]
        if let reason = nsError.localizedFailureReason { fields["failureReason"] = reason }
        if let suggestion = nsError.localizedRecoverySuggestion { fields["recoverySuggestion"] = suggestion }
        if let underlying = nsError.userInfo[NSUnderlyingErrorKey] as? NSError {
            fields["underlying"] = "\(underlying.domain)/\(underlying.code): \(underlying.localizedDescription)"
        }
        if extremeDiagnosticsEnabled, !nsError.userInfo.isEmpty {
            fields["userInfoKeys"] = nsError.userInfo.keys.map { String(describing: $0) }.sorted().joined(separator: ",")
        }
        structured(.error, category, prefix, traceID: traceID, fields: fields)
    }

    static func flush() {
        guard diagnosticsEnabled else { return }
        queue.async {
            guard loggingEnabledLocked else { return }
            beginNewSessionLocked()
            flushPendingSettingsLogLocked()
            flushWriteBufferLocked()
            try? handle?.synchronize()
        }
    }

    static func emitSessionSummary(reason: String) {
        guard diagnosticsEnabled else { return }
        queue.async {
            guard loggingEnabledLocked else { return }
            beginNewSessionLocked()
            appendSessionSummaryLocked(reason: reason)
        }
    }

    private static func structured(
        _ level: Level,
        _ category: Category,
        _ message: String,
        traceID: String? = nil,
        fields: [String: String] = [:],
        function: StaticString = #function,
        file: StaticString = #fileID,
        line: UInt = #line
    ) {
        guard diagnosticsEnabled else { return }
        let thread = Thread.isMainThread ? "main" : (Thread.current.name?.isEmpty == false ? Thread.current.name! : "background")
        let record = PendingRecord(
            level: level,
            category: category,
            message: message,
            traceID: traceID,
            fields: fields,
            function: String(describing: function),
            file: String(describing: file),
            line: line,
            callerThread: thread,
            callUptime: ProcessInfo.processInfo.systemUptime
        )
        queue.async {
            guard loggingEnabledLocked else { return }
            beginNewSessionLocked()
            appendRecordWithDiagnosticsEnvelopeLocked(record)
        }
    }

    private static func appendRecordWithDiagnosticsEnvelopeLocked(_ record: PendingRecord) {
        let extreme = extremeDiagnosticsEnabled
        let receivedAt = ProcessInfo.processInfo.systemUptime
        let lightweight = extreme && isHighFrequencyExtremeRecord(record)
        if extreme && !lightweight {
            appendExtremeRecordLocked(
                "EXTREME EVENT RECEIVED",
                source: record,
                fields: [
                    "sourceLevel": record.level.rawValue,
                    "sourceCategory": record.category.rawValue,
                    "sourceMessage": record.message,
                    "callToLoggerMs": String(format: "%.2f", (receivedAt - record.callUptime) * 1000),
                    "settingsRevision": String(settingsRevision),
                    "settingsAgeMs": settingsAgeMilliseconds(now: receivedAt),
                    "thermal": thermalStateName(ProcessInfo.processInfo.thermalState),
                    "lowPowerMode": String(ProcessInfo.processInfo.isLowPowerModeEnabled)
                ]
            )
        }

        if lightweight {
            var fields = record.fields
            fields["loggerQueueDelayMs"] = String(format: "%.2f", (receivedAt - record.callUptime) * 1000)
            appendStructuredLocked(PendingRecord(
                level: record.level,
                category: record.category,
                message: record.message,
                traceID: record.traceID,
                fields: fields,
                function: record.function,
                file: record.file,
                line: record.line,
                callerThread: record.callerThread,
                callUptime: record.callUptime
            ))
        } else {
            appendStructuredLocked(record)
        }

        if extreme && !lightweight {
            appendExtremeRecordLocked(
                "EXTREME EVENT COMMITTED",
                source: record,
                fields: [
                    "sourceEventNumber": String(eventCounter),
                    "loggerCommitMs": String(format: "%.2f", (ProcessInfo.processInfo.systemUptime - receivedAt) * 1000),
                    "writeBufferBytes": String(writeBuffer.utf8.count),
                    "flushScheduled": String(writeFlushScheduled),
                    "settingsRevision": String(settingsRevision),
                    "settingsAgeMs": settingsAgeMilliseconds(now: ProcessInfo.processInfo.systemUptime)
                ]
            )
        }
    }

    private static func isHighFrequencyExtremeRecord(_ record: PendingRecord) -> Bool {
        record.message == "ZOOM TRANSITION FRAME" ||
            record.message == "CAPTURE CALLBACK FRAME DROPPED"
    }

    /// Extreme mode keeps the full received/committed envelope for ordinary events so queue delay,
    /// write-buffer pressure, thermal state and settings freshness remain visible. Per-frame probe
    /// records stay fully detailed but omit the duplicate envelope and carry loggerQueueDelayMs
    /// directly, avoiding a 3x expansion exactly where callback pressure is highest.
    private static func appendExtremeRecordLocked(
        _ message: String,
        source: PendingRecord,
        fields: [String: String]
    ) {
        appendStructuredLocked(PendingRecord(
            level: .trace,
            category: .traceContext,
            message: message,
            traceID: source.traceID,
            fields: fields,
            function: "AppEventLog.structured",
            file: "AppEventLog.swift",
            line: 0,
            callerThread: "event-log",
            callUptime: ProcessInfo.processInfo.systemUptime
        ))
    }

    private static func settingsAgeMilliseconds(now: TimeInterval) -> String {
        guard let lastSettingsChangeUptime else { return "never" }
        return String(format: "%.2f", max(0, now - lastSettingsChangeUptime) * 1000)
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

        flushWriteBufferLocked()
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
        eventCounter = 0
        warningCount = 0
        errorCount = 0
        invariantCount = 0
        staleRequestCount = 0
        categoryCounts = [:]
        settingsRevision = 0
        lastSettingsChangeUptime = nil
        writeBuffer = ""
        writeFlushScheduled = false
        installDefaultsObserverLocked()
        installSystemObserversLocked()
        settingsSnapshot = currentSettingsLocked()

        appendRawLocked("================ LOWPOLYCAM DIAGNOSTIC SESSION ================")
        appendRawLocked("LowPolyCam diagnostic session started: file=\(url.lastPathComponent)")
        appendRawLocked("Environment: appVersion=\(Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "unknown"), build=\(Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "unknown"), extremeDiagnostics=\(extremeDiagnosticsEnabled)")
        appendRawLocked("Environment: device=\(UIDevice.current.model), iOS=\(UIDevice.current.systemVersion), locale=\(Locale.current.identifier), timezone=\(TimeZone.current.identifier)")
        appendRawLocked("Environment: thermal=\(thermalStateName(ProcessInfo.processInfo.thermalState)), lowPowerMode=\(ProcessInfo.processInfo.isLowPowerModeEnabled), physicalMemory=\(ProcessInfo.processInfo.physicalMemory)")
        let homeURL = URL(fileURLWithPath: NSHomeDirectory())
        let freeStorage = (try? homeURL.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey]))?.volumeAvailableCapacityForImportantUsage ?? -1
        appendRawLocked("Environment: freeStorageBytes=\(freeStorage)")
        appendRawLocked("Permissions: camera=\(authorizationName(AVCaptureDevice.authorizationStatus(for: .video))), microphone=\(authorizationName(AVCaptureDevice.authorizationStatus(for: .audio))), photosAddOnly=\(authorizationName(PHPhotoLibrary.authorizationStatus(for: .addOnly)))")
        appendRawLocked("Settings snapshot begin")
        for setting in diagnosticSettings {
            appendRawLocked("SETTING \(setting.key)=\(settingsSnapshot[setting.key] ?? setting.defaultValue)")
        }
        appendRawLocked("Settings snapshot end")
        appendRawLocked("===============================================================")
    }

    private static func disableLocked() {
        guard hasStartedSession || handle != nil else { return }
        appendSessionSummaryLocked(reason: "diagnostics disabled")
        appendRawLocked("LowPolyCam diagnostic logging disabled")
        flushPendingSettingsLogLocked()
        flushWriteBufferLocked()
        try? handle?.synchronize()
        try? handle?.close()
        handle = nil
        currentFilename = nil
        hasStartedSession = false
        settingsSnapshot = [:]
        settingsLogGeneration &+= 1
        settingsLogScheduled = false
        writeBuffer = ""
        writeFlushScheduled = false
    }

    private static func appendSessionSummaryLocked(reason: String) {
        appendRawLocked("===== DIAGNOSTIC SESSION SUMMARY [\(reason)] =====")
        appendRawLocked("events=\(eventCounter), warnings=\(warningCount), errors=\(errorCount), staleRequests=\(staleRequestCount), invariantViolations=\(invariantCount)")
        let categories = categoryCounts.sorted { $0.key.rawValue < $1.key.rawValue }
            .map { "\($0.key.rawValue)=\($0.value)" }.joined(separator: ", ")
        appendRawLocked("categories: \(categories)")
        appendRawLocked("runtimeSeconds=\(String(format: "%.3f", ProcessInfo.processInfo.systemUptime - startUptime)), extremeDiagnostics=\(extremeDiagnosticsEnabled)")
        appendRawLocked("===============================================")
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

    private static func appendStructuredLocked(_ record: PendingRecord) {
        eventCounter &+= 1
        if record.level == .warning { warningCount &+= 1 }
        if record.level == .error { errorCount &+= 1 }
        categoryCounts[record.category, default: 0] &+= 1
        let timestamp = timestampFormatter.string(from: Date())
        let elapsed = max(0, record.callUptime - startUptime)
        let number = String(format: "%07llu", eventCounter)
        let trace = record.traceID.map { " trace=\($0)" } ?? ""
        let source = "src=\(record.file):\(record.line) fn=\(record.function) caller=\(record.callerThread)"
        let fields = record.fields.isEmpty ? "" : " " + record.fields.keys.sorted().map { key in
            "\(key)=\(sanitize(record.fields[key] ?? ""))"
        }.joined(separator: " ")
        appendLineLocked("[\(timestamp)] [#\(number)] [+\(String(format: "%.3f", elapsed))s] [\(record.level.rawValue)] [\(record.category.rawValue)]\(trace) \(record.message) | \(source)\(fields)")
    }

    private static func appendRawLocked(_ message: String) {
        let timestamp = timestampFormatter.string(from: Date())
        appendLineLocked("[\(timestamp)] \(message)")
    }

    private static func appendLineLocked(_ line: String) {
        guard handle != nil else { return }
        writeBuffer += line + "\n"
        if writeBuffer.utf8.count >= writeFlushThreshold {
            flushWriteBufferLocked()
            return
        }
        guard !writeFlushScheduled else { return }
        writeFlushScheduled = true
        queue.asyncAfter(deadline: .now() + writeFlushInterval) {
            writeFlushScheduled = false
            flushWriteBufferLocked()
        }
    }

    private static func flushWriteBufferLocked() {
        guard let handle, !writeBuffer.isEmpty else { return }
        let pending = writeBuffer
        writeBuffer = ""
        guard let data = pending.data(using: .utf8) else { return }
        handle.write(data)
    }

    private static func sanitize(_ value: String) -> String {
        if value.contains(" ") || value.contains("\n") || value.contains("\t") {
            return "\"\(value.replacingOccurrences(of: "\"", with: "'"))\""
        }
        return value
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

    private static func installSystemObserversLocked() {
        guard systemObservers.isEmpty else { return }
        let center = NotificationCenter.default
        systemObservers.append(center.addObserver(forName: ProcessInfo.thermalStateDidChangeNotification, object: nil, queue: nil) { _ in
            event("THERMAL STATE CHANGED", category: .thermal, level: .warning, fields: ["thermal": thermalStateName(ProcessInfo.processInfo.thermalState)])
        })
        systemObservers.append(center.addObserver(forName: Notification.Name.NSProcessInfoPowerStateDidChange, object: nil, queue: nil) { _ in
            event("LOW POWER MODE CHANGED", category: .performance, level: .info, fields: ["enabled": String(ProcessInfo.processInfo.isLowPowerModeEnabled)])
        })
        systemObservers.append(center.addObserver(forName: UIApplication.didReceiveMemoryWarningNotification, object: nil, queue: nil) { _ in
            event("MEMORY WARNING", category: .performance, level: .warning)
        })
    }

    private static func scheduleSettingsLogLocked() {
        guard loggingEnabledLocked, hasStartedSession else { return }
        settingsLogGeneration &+= 1
        let generation = settingsLogGeneration
        settingsLogScheduled = true
        let debounceNanoseconds = extremeDiagnosticsEnabled ? 20_000_000 : settingsLogDebounceNanoseconds
        queue.asyncAfter(deadline: .now() + .nanoseconds(Int(debounceNanoseconds))) {
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
        var changedSettings: [(key: String, before: String, after: String)] = []
        for setting in diagnosticSettings {
            let oldValue = settingsSnapshot[setting.key] ?? setting.defaultValue
            let newValue = current[setting.key] ?? setting.defaultValue
            guard oldValue != newValue else { continue }
            changedSettings.append((setting.key, oldValue, newValue))
        }
        settingsSnapshot = current
        guard !changedSettings.isEmpty else { return }

        // Advance the revision before writing the records so every Extreme envelope describes
        // the settings state that caused the batch, and its age starts at zero rather than at
        // the previous revision.
        settingsRevision &+= 1
        lastSettingsChangeUptime = ProcessInfo.processInfo.systemUptime
        for setting in changedSettings {
            appendRecordWithDiagnosticsEnvelopeLocked(PendingRecord(
                level: .info, category: .settings, message: "SETTING CHANGED \(setting.key)", traceID: nil,
                fields: ["before": setting.before, "after": setting.after], function: "UserDefaults.didChange", file: "UserDefaults", line: 0,
                callerThread: "notification", callUptime: ProcessInfo.processInfo.systemUptime
            ))
        }
    }

    private static let booleanSettingKeys: Set<String> = [
        "diagnosticLoggingEnabled", "diagnosticExtremeLoggingEnabled", "videoStabilizationEnabled", "hapticCaptureEnabled",
        "countdownHaptics", "tapZoomReset", "recordingLock", "lowStorageWarning", "rememberCaptureMode", "mirrorSelfies",
        "centerCrosshair", "cameraGridEnabled", "frameGuidesEnabled", "levelMeterEnabled", "keepScreenAwakeEnabled", "cameraHUDEnabled",
        "cameraHUDResolution", "cameraHUDFPS", "cameraHUDRemaining", "cameraHUDWhiteBalance", "cameraHUDBattery",
        "cameraHUDStorage", "cameraHUDDroppedFrames", "cameraHUDLens", "photoCaptureFlash", "frontScreenFlash", "audioPeakHold", "thermalHUD", "longevityMode", "liveRecordingStats",
        "liveStatsShowFPS", "liveStatsShowBitrate", "liveStatsShowDrops", "zoomButtonsEnabled"
    ]

    private static let decimalSettingKeys: Set<String> = [
        "iconCustomRed", "iconCustomGreen", "iconCustomBlue", "zoomSpeed", "gridOpacity",
        "hudTextSize", "liveStatsX", "liveStatsY", "videoManualBitrateMbps", "slowMotionManualBitrateMbps",
        "customWhiteBalanceTemperature", "customWhiteBalanceTint", "torchBrightness",
        "zoomButton1", "zoomButton2", "zoomButton3", "zoomButton4", "zoomButton5"
    ]

    private static func currentSettingsLocked() -> [String: String] {
        let defaults = UserDefaults.standard
        return Dictionary(uniqueKeysWithValues: diagnosticSettings.map { setting in
            let value = defaults.object(forKey: setting.key)
            return (setting.key, formattedSettingValue(value, setting: setting))
        })
    }

    private static func formattedSettingValue(_ value: Any?, setting: (key: String, defaultValue: String)) -> String {
        guard let value else { return setting.defaultValue }
        if booleanSettingKeys.contains(setting.key) {
            if let bool = value as? Bool { return bool ? "true" : "false" }
            if let number = value as? NSNumber { return number.boolValue ? "true" : "false" }
        }
        if decimalSettingKeys.contains(setting.key), let number = value as? NSNumber {
            var text = String(format: "%.4f", number.doubleValue)
            while text.last == "0" { text.removeLast() }
            if text.last == "." { text.append("0") }
            return text
        }
        if let string = value as? String { return string }
        if let number = value as? NSNumber { return String(describing: number) }
        return String(describing: value)
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
}
