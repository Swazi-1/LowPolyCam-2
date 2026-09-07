import Foundation

enum CameraRecoveryStore {
    private static var directory: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        return base.appendingPathComponent("LowPolyCam/Recovery", isDirectory: true)
    }

    static func recordings() -> [URL] {
        let fm = FileManager.default
        guard let files = try? fm.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles]
        ) else { return [] }
        return files.filter {
            $0.pathExtension.lowercased() == "mov" &&
            (try? $0.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true
        }.sorted { $0.lastPathComponent < $1.lastPathComponent }
    }

    @discardableResult
    static func preserve(_ source: URL) -> URL? {
        let fm = FileManager.default
        guard (try? source.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true else {
            return nil
        }
        // A failed Photos retry already has a durable recovery file. Keep its identity stable
        // instead of renaming it on every attempt (and confusing in-flight retry tracking).
        if source.deletingLastPathComponent().standardizedFileURL == directory.standardizedFileURL {
            return source
        }
        do {
            try fm.createDirectory(at: directory, withIntermediateDirectories: true)
            var destination = directory.appendingPathComponent(source.lastPathComponent)
            if fm.fileExists(atPath: destination.path) {
                let stem = source.deletingPathExtension().lastPathComponent
                destination = directory.appendingPathComponent("\(stem)_\(UUID().uuidString.prefix(6)).mov")
            }
            try fm.moveItem(at: source, to: destination)
            return destination
        } catch {
            return nil
        }
    }

    static func removeAll() {
        for url in recordings() {
            try? FileManager.default.removeItem(at: url)
        }
    }
}
