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
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        ) else { return [] }
        return files.filter { $0.pathExtension.lowercased() == "mov" }.sorted { $0.lastPathComponent < $1.lastPathComponent }
    }

    @discardableResult
    static func preserve(_ source: URL) -> URL? {
        let fm = FileManager.default
        do {
            try fm.createDirectory(at: directory, withIntermediateDirectories: true)
            var destination = directory.appendingPathComponent(source.lastPathComponent)
            if fm.fileExists(atPath: destination.path) {
                let stem = source.deletingPathExtension().lastPathComponent
                destination = directory.appendingPathComponent("\(stem)_\(UUID().uuidString.prefix(6)).mov")
            }
            if fm.fileExists(atPath: source.path) {
                try fm.moveItem(at: source, to: destination)
            }
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
