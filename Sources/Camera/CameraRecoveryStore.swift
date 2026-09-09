import Foundation

enum CameraRecoveryStore {
    private static var directory: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        return base.appendingPathComponent("LowPolyCam/Recovery", isDirectory: true)
    }

    private static func recordingURLs(sorted: Bool) -> [URL] {
        let fm = FileManager.default
        guard let files = try? fm.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        ) else { return [] }
        let recordings = files.filter { $0.pathExtension.lowercased() == "mov" }
        return sorted ? recordings.sorted { $0.lastPathComponent < $1.lastPathComponent } : recordings
    }

    static func recordings() -> [URL] {
        let result = recordingURLs(sorted: true)
        AppEventLog.deepEvent("RECOVERY RECORDINGS ENUMERATED", category: .save, fields: ["count": String(result.count)])
        return result
    }

    static func containsRecording(named filename: String) -> Bool {
        FileManager.default.fileExists(atPath: directory.appendingPathComponent(filename).path)
    }

    static func recordingCount() -> Int {
        recordingURLs(sorted: false).count
    }

    @discardableResult
    static func preserve(_ source: URL) -> URL? {
        let traceID = AppEventLog.extremeDiagnosticsEnabled ? AppEventLog.makeTraceID("RECOVERY") : nil
        let startedAt = ProcessInfo.processInfo.systemUptime
        AppEventLog.deepEvent("RECOVERY PRESERVE BEGIN", category: .save, traceID: traceID,
                              fields: ["source": source.lastPathComponent])
        let fm = FileManager.default
        let sourceURL = source.standardizedFileURL
        let recoveryDirectory = directory.standardizedFileURL
        guard fm.fileExists(atPath: sourceURL.path) else {
            AppEventLog.guardRejected("recovery preserve", reason: "source file does not exist", traceID: traceID,
                                      fields: ["source": sourceURL.lastPathComponent])
            return nil
        }
        if sourceURL.deletingLastPathComponent() == recoveryDirectory {
            AppEventLog.deepEvent("RECOVERY PRESERVE NO-OP", category: .save, traceID: traceID,
                                  fields: ["reason": "already in recovery"])
            return sourceURL
        }

        do {
            try fm.createDirectory(at: recoveryDirectory, withIntermediateDirectories: true)
            var destination = recoveryDirectory.appendingPathComponent(sourceURL.lastPathComponent)
            if fm.fileExists(atPath: destination.path) {
                let stem = sourceURL.deletingPathExtension().lastPathComponent
                destination = recoveryDirectory.appendingPathComponent("\(stem)_\(UUID().uuidString).mov")
            }
            try fm.moveItem(at: sourceURL, to: destination)
            AppEventLog.deepEvent("RECOVERY PRESERVE COMPLETE", category: .save, traceID: traceID, fields: [
                "destination": destination.lastPathComponent,
                "durationMs": String(format: "%.2f", (ProcessInfo.processInfo.systemUptime - startedAt) * 1000)
            ])
            return destination
        } catch {
            AppEventLog.log(error: error, prefix: "RECOVERY PRESERVE FAILED", category: .save, traceID: traceID)
            return nil
        }
    }

    static func removeAll() {
        let urls = recordingURLs(sorted: false)
        var failures = 0
        for url in urls {
            do { try FileManager.default.removeItem(at: url) }
            catch {
                failures += 1
                AppEventLog.log(error: error, prefix: "RECOVERY DELETE FAILED", category: .save)
            }
        }
        AppEventLog.event("RECOVERY REMOVE ALL", category: .save, level: failures == 0 ? .info : .warning,
                          fields: ["requested": String(urls.count), "failures": String(failures)])
    }
}
