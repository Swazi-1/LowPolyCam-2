import Foundation

enum CameraRecoveryStore {
    private static let photoExtensions: Set<String> = ["heic", "jpg", "jpeg"]

    private static var directory: URL {
        let fileManager = FileManager.default
        let base = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? fileManager.temporaryDirectory
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

    private static func photoURLs(sorted: Bool) -> [URL] {
        let fm = FileManager.default
        guard let files = try? fm.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        ) else { return [] }
        let photos = files.filter { photoExtensions.contains($0.pathExtension.lowercased()) }
        return sorted ? photos.sorted { $0.lastPathComponent < $1.lastPathComponent } : photos
    }

    private static func recoveryURLs(sorted: Bool) -> [URL] {
        let urls = recordingURLs(sorted: false) + photoURLs(sorted: false)
        return sorted ? urls.sorted { $0.lastPathComponent < $1.lastPathComponent } : urls
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

    static func photoRecoveryFiles() -> [URL] {
        let result = photoURLs(sorted: true)
        AppEventLog.deepEvent("RECOVERY PHOTOS ENUMERATED", category: .save, fields: ["count": String(result.count)])
        return result
    }

    static func photoRecoveryCount() -> Int {
        photoURLs(sorted: false).count
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

    @discardableResult
    static func preservePhotoData(_ data: Data, named filename: String) -> URL? {
        let fm = FileManager.default
        let requestedURL = URL(fileURLWithPath: filename).standardizedFileURL
        let safeName = requestedURL.lastPathComponent.isEmpty ? "recovered-photo.jpg" : requestedURL.lastPathComponent
        let traceID = AppEventLog.extremeDiagnosticsEnabled ? AppEventLog.makeTraceID("PHOTO-RECOVERY") : nil
        do {
            try fm.createDirectory(at: directory, withIntermediateDirectories: true)
            var destination = directory.appendingPathComponent(safeName)
            if fm.fileExists(atPath: destination.path) {
                let stem = destination.deletingPathExtension().lastPathComponent
                let ext = destination.pathExtension.isEmpty ? "jpg" : destination.pathExtension
                destination = directory.appendingPathComponent("\(stem)_\(UUID().uuidString).\(ext)")
            }
            try data.write(to: destination, options: [.atomic])
            AppEventLog.deepEvent("PHOTO RECOVERY PRESERVE COMPLETE", category: .save, traceID: traceID, fields: [
                "destination": destination.lastPathComponent,
                "bytes": String(data.count)
            ])
            return destination
        } catch {
            AppEventLog.log(error: error, prefix: "PHOTO RECOVERY PRESERVE FAILED", category: .save, traceID: traceID)
            return nil
        }
    }

    @discardableResult
    static func delete(_ url: URL) -> Bool {
        let root = directory.standardizedFileURL.path
        let target = url.standardizedFileURL.path
        guard target.hasPrefix(root + "/") else {
            AppEventLog.guardRejected("recovery delete", reason: "file is outside recovery directory", fields: ["file": url.lastPathComponent])
            return false
        }
        do {
            try FileManager.default.removeItem(at: url)
            AppEventLog.event("Recovery file deleted: \(url.lastPathComponent)", category: .save)
            return true
        } catch {
            AppEventLog.log(error: error, prefix: "RECOVERY DELETE FAILED", category: .save)
            return false
        }
    }

    static func removeAll() {
        let urls = recoveryURLs(sorted: false)
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
