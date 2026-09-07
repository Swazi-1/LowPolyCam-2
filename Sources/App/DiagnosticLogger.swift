import Foundation
import MetricKit
import UIKit

private func lowPolyCamUncaughtExceptionHandler(_ exception: NSException) {
    DiagnosticLogger.shared.recordUncaughtException(exception)
}

/// Persistent, user-readable diagnostics for LowPolyCam.
///
/// Logs are stored under Documents/LowPolyCam Logs so they are visible in the Files app.
/// Call sites are captured automatically with #fileID/#function/#line.
final class DiagnosticLogger {
    static let shared = DiagnosticLogger()

    enum Level: String {
        case trace = "TRACE"
        case action = "ACTION"
        case info = "INFO"
        case warning = "WARN"
        case error = "ERROR"
        case crash = "CRASH"
    }

    private let queue = DispatchQueue(label: "com.swazi.LowPolyCam.diagnostics", qos: .utility)
    private let queueKey = DispatchSpecificKey<UInt8>()
    private let fileManager = FileManager.default
    private let directoryURL: URL
    private let logURL: URL
    private var handle: FileHandle?
    private var crashCaptureInstalled = false
    private let dateFormatter: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()

    private init() {
        queue.setSpecific(key: queueKey, value: 1)
        let documents = fileManager.urls(for: .documentDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
        directoryURL = documents.appendingPathComponent("LowPolyCam Logs", isDirectory: true)

        let filenameFormatter = DateFormatter()
        filenameFormatter.locale = Locale(identifier: "en_US_POSIX")
        filenameFormatter.dateFormat = "yyyy-MM-dd_HH-mm-ss"
        let filename = "LowPolyCam-\(filenameFormatter.string(from: Date())).log"
        logURL = directoryURL.appendingPathComponent(filename, isDirectory: false)

        do {
            try fileManager.createDirectory(at: directoryURL, withIntermediateDirectories: true)
            trimOldSessionLogs()
            if !fileManager.fileExists(atPath: logURL.path) {
                fileManager.createFile(atPath: logURL.path, contents: nil)
            }
            handle = try FileHandle(forWritingTo: logURL)
            handle?.seekToEndOfFile()
            writeDirect("=== LowPolyCam diagnostic session ===\n")
            writeDirect("Log file: \(logURL.lastPathComponent)\n")
            writeDirect("App version: \(Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "unknown")\n")
            writeDirect("Build: \(Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "unknown")\n")
            writeDirect("iOS: \(UIDevice.current.systemVersion)\n")
            writeDirect("Device: \(UIDevice.current.model)\n")
            writeDirect("=====================================\n")
        } catch {
            handle = nil
        }
    }

    func start() {
        synchronized {
            guard !crashCaptureInstalled else { return }
            crashCaptureInstalled = true
            NSSetUncaughtExceptionHandler(lowPolyCamUncaughtExceptionHandler)
            writeEntry(
                level: .info,
                category: "App",
                message: "Persistent diagnostics started",
                metadata: ["filesPath": "On My iPhone/LowPolyCam/LowPolyCam Logs"],
                file: "DiagnosticLogger.swift",
                function: "start()",
                line: 0
            )
        }
        MetricKitDiagnosticCollector.shared.start()
    }

    func trace(
        _ message: String,
        category: String = "Code",
        metadata: [String: String] = [:],
        file: StaticString = #fileID,
        function: StaticString = #function,
        line: UInt = #line
    ) {
        log(.trace, category: category, message: message, metadata: metadata, file: file, function: function, line: line)
    }

    func action(
        _ message: String,
        metadata: [String: String] = [:],
        file: StaticString = #fileID,
        function: StaticString = #function,
        line: UInt = #line
    ) {
        log(.action, category: "UI", message: message, metadata: metadata, file: file, function: function, line: line)
    }

    func info(
        _ message: String,
        category: String,
        metadata: [String: String] = [:],
        file: StaticString = #fileID,
        function: StaticString = #function,
        line: UInt = #line
    ) {
        log(.info, category: category, message: message, metadata: metadata, file: file, function: function, line: line)
    }

    func warning(
        _ message: String,
        category: String,
        metadata: [String: String] = [:],
        file: StaticString = #fileID,
        function: StaticString = #function,
        line: UInt = #line
    ) {
        log(.warning, category: category, message: message, metadata: metadata, file: file, function: function, line: line)
    }

    func error(
        _ message: String,
        category: String,
        metadata: [String: String] = [:],
        file: StaticString = #fileID,
        function: StaticString = #function,
        line: UInt = #line
    ) {
        log(.error, category: category, message: message, metadata: metadata, file: file, function: function, line: line)
    }

    private func log(
        _ level: Level,
        category: String,
        message: String,
        metadata: [String: String],
        file: StaticString,
        function: StaticString,
        line: UInt
    ) {
        let fileName = String(describing: file)
        let functionName = String(describing: function)
        synchronized {
            writeEntry(
                level: level,
                category: category,
                message: message,
                metadata: metadata,
                file: fileName,
                function: functionName,
                line: line
            )
        }
    }

    func recordUncaughtException(_ exception: NSException) {
        let stack = exception.callStackSymbols.joined(separator: "\n")
        synchronized {
            writeEntry(
                level: .crash,
                category: "UncaughtException",
                message: exception.reason ?? "No Objective-C exception reason supplied",
                metadata: [
                    "name": exception.name.rawValue,
                    "stack": stack
                ],
                file: "Objective-C runtime",
                function: "NSSetUncaughtExceptionHandler",
                line: 0
            )
            handle?.synchronizeFile()
        }
    }

    func saveMetricKitDiagnosticPayload(_ data: Data, crashCount: Int, summary: String) {
        synchronized {
            let filenameFormatter = DateFormatter()
            filenameFormatter.locale = Locale(identifier: "en_US_POSIX")
            filenameFormatter.dateFormat = "yyyy-MM-dd_HH-mm-ss-SSS"
            let name = "MetricKit-Diagnostic-\(filenameFormatter.string(from: Date())).json"
            let url = directoryURL.appendingPathComponent(name)
            do {
                try data.write(to: url, options: .atomic)
                writeEntry(
                    level: crashCount > 0 ? .crash : .info,
                    category: "MetricKit",
                    message: summary,
                    metadata: ["report": name, "crashCount": String(crashCount)],
                    file: "DiagnosticLogger.swift",
                    function: "saveMetricKitDiagnosticPayload(_:crashCount:summary:)",
                    line: 0
                )
            } catch {
                writeEntry(
                    level: .error,
                    category: "MetricKit",
                    message: "Failed to save diagnostic report",
                    metadata: ["error": error.localizedDescription],
                    file: "DiagnosticLogger.swift",
                    function: "saveMetricKitDiagnosticPayload(_:crashCount:summary:)",
                    line: 0
                )
            }
        }
    }

    private func synchronized(_ operation: () -> Void) {
        if DispatchQueue.getSpecific(key: queueKey) == 1 {
            operation()
        } else {
            queue.sync(execute: operation)
        }
    }

    private func writeEntry(
        level: Level,
        category: String,
        message: String,
        metadata: [String: String],
        file: String,
        function: String,
        line: UInt
    ) {
        var text = "[\(dateFormatter.string(from: Date()))] [\(level.rawValue)] [\(category)] \(message)"
        text += " | code=\(file):\(line) \(function)"
        if !metadata.isEmpty {
            let details = metadata
                .sorted(by: { $0.key < $1.key })
                .map { "\($0.key)=\(sanitize($0.value))" }
                .joined(separator: " | ")
            text += " | \(details)"
        }
        writeDirect(text + "\n")
        if level == .action || level == .error || level == .crash {
            handle?.synchronizeFile()
        }
    }

    private func writeDirect(_ text: String) {
        guard let data = text.data(using: .utf8) else { return }
        handle?.write(data)
    }

    private func sanitize(_ value: String) -> String {
        value
            .replacingOccurrences(of: "\r", with: "\\r")
            .replacingOccurrences(of: "\n", with: "\\n")
    }

    private func trimOldSessionLogs() {
        guard let files = try? fileManager.contentsOfDirectory(
            at: directoryURL,
            includingPropertiesForKeys: [.contentModificationDateKey],
            options: [.skipsHiddenFiles]
        ) else { return }

        let sessionLogs = files
            .filter { $0.pathExtension == "log" && $0.lastPathComponent.hasPrefix("LowPolyCam-") }
            .sorted { lhs, rhs in
                let left = (try? lhs.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
                let right = (try? rhs.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
                return left > right
            }

        for stale in sessionLogs.dropFirst(9) {
            try? fileManager.removeItem(at: stale)
        }
    }
}

/// iOS 26-compatible MetricKit listener. On iOS 27 this remains available and delivers the
/// system crash/hang diagnostic payloads; the raw JSON is saved next to the human-readable log.
private final class MetricKitDiagnosticCollector: NSObject, MXMetricManagerSubscriber {
    static let shared = MetricKitDiagnosticCollector()
    private var isStarted = false

    func start() {
        guard !isStarted else { return }
        isStarted = true
        MXMetricManager.shared.add(self)
        DiagnosticLogger.shared.info("MetricKit diagnostics listener registered", category: "CrashDiagnostics")
    }

    func didReceive(_ payloads: [MXDiagnosticPayload]) {
        for payload in payloads {
            let crashes = payload.crashDiagnostics ?? []
            let hangs = payload.hangDiagnostics ?? []
            let cpuExceptions = payload.cpuExceptionDiagnostics ?? []
            let diskExceptions = payload.diskWriteExceptionDiagnostics ?? []

            var summaries: [String] = []
            for (index, crash) in crashes.enumerated() {
                var parts = ["crash #\(index + 1)"]
                if let reason = crash.terminationReason { parts.append("termination=\(reason)") }
                if let signal = crash.signal { parts.append("signal=\(signal)") }
                if let exceptionType = crash.exceptionType { parts.append("exceptionType=\(exceptionType)") }
                if let exceptionCode = crash.exceptionCode { parts.append("exceptionCode=\(exceptionCode)") }
                if let exceptionReason = crash.exceptionReason?.composedMessage, !exceptionReason.isEmpty {
                    parts.append("reason=\(exceptionReason)")
                }
                summaries.append(parts.joined(separator: ", "))
            }
            if !hangs.isEmpty { summaries.append("hangs=\(hangs.count)") }
            if !cpuExceptions.isEmpty { summaries.append("cpuExceptions=\(cpuExceptions.count)") }
            if !diskExceptions.isEmpty { summaries.append("diskWriteExceptions=\(diskExceptions.count)") }
            if summaries.isEmpty { summaries.append("MetricKit diagnostic payload received") }

            DiagnosticLogger.shared.saveMetricKitDiagnosticPayload(
                payload.jsonRepresentation(),
                crashCount: crashes.count,
                summary: summaries.joined(separator: " | ")
            )
        }
    }
}
