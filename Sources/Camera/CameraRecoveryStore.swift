import Foundation

enum CameraRecoveryStore {
    enum MediaKind: String, Equatable {
        case recording
        case photo
    }

    struct Item: Equatable {
        let url: URL
        let kind: MediaKind
    }

    private static var baseDirectory: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        return base.appendingPathComponent("LowPolyCam", isDirectory: true)
    }

    private static var recoveryDirectory: URL {
        baseDirectory.appendingPathComponent("Recovery", isDirectory: true)
    }

    /// MovieFileOutput writes here instead of temporaryDirectory. Files only move into Recovery
    /// after AVFoundation reports completion, but leftovers are reconciled on the next launch.
    private static var inProgressRecordingDirectory: URL {
        baseDirectory.appendingPathComponent("PendingRecordings", isDirectory: true)
    }

    private static let photoExtensions: Set<String> = ["heic", "heif", "jpg", "jpeg"]

    static func items() -> [Item] {
        files(in: recoveryDirectory).compactMap { url in
            guard let kind = kind(for: url) else { return nil }
            return Item(url: url, kind: kind)
        }.sorted { $0.url.lastPathComponent < $1.url.lastPathComponent }
    }

    static func recordings() -> [URL] {
        items().filter { $0.kind == .recording }.map(\.url)
    }

    static func photos() -> [URL] {
        items().filter { $0.kind == .photo }.map(\.url)
    }

    static func containsFilename(_ filename: String) -> Bool {
        let fm = FileManager.default
        return fm.fileExists(atPath: recoveryDirectory.appendingPathComponent(filename).path) ||
            fm.fileExists(atPath: inProgressRecordingDirectory.appendingPathComponent(filename).path)
    }

    /// Returns a durable destination for a new recording. The file itself is created by AVFoundation.
    static func prepareRecordingDestination(filename: String) -> URL? {
        guard filename.lowercased().hasSuffix(".mov") else { return nil }
        do {
            try ensureDirectory(inProgressRecordingDirectory)
            let destination = uniqueDestination(
                in: inProgressRecordingDirectory,
                filename: filename
            )
            return destination
        } catch {
            return nil
        }
    }

    /// Moves any recording left by a previous process into the normal recovery inventory.
    /// A leftover may be incomplete if the app terminated mid-recording, so callers must not
    /// promise that every reconciled MOV is playable.
    @discardableResult
    static func reconcilePendingRecordings() -> [URL] {
        files(in: inProgressRecordingDirectory)
            .filter { $0.pathExtension.lowercased() == "mov" }
            .compactMap { preserve($0) }
    }

    /// Stages processed photo bytes before Photos import. Atomic writing prevents a half-written
    /// image from entering the recovery inventory.
    static func stagePhoto(_ data: Data, filename: String) -> URL? {
        guard photoExtensions.contains(URL(fileURLWithPath: filename).pathExtension.lowercased()) else {
            return nil
        }
        do {
            try ensureDirectory(recoveryDirectory)
            let destination = uniqueDestination(in: recoveryDirectory, filename: filename)
            let staging = recoveryDirectory.appendingPathComponent(".stage-\(UUID().uuidString)")
            defer { try? FileManager.default.removeItem(at: staging) }
            try data.write(to: staging, options: .atomic)
            try FileManager.default.moveItem(at: staging, to: destination)
            return destination
        } catch {
            return nil
        }
    }

    @discardableResult
    static func preserve(_ source: URL) -> URL? {
        let fm = FileManager.default
        guard (try? source.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true,
              kind(for: source) != nil else {
            return nil
        }

        if source.deletingLastPathComponent().standardizedFileURL == recoveryDirectory.standardizedFileURL {
            return source
        }

        do {
            try ensureDirectory(recoveryDirectory)
            let destination = uniqueDestination(in: recoveryDirectory, filename: source.lastPathComponent)
            try fm.moveItem(at: source, to: destination)
            return destination
        } catch {
            return nil
        }
    }

    static func removeAll() {
        for item in items() {
            try? FileManager.default.removeItem(at: item.url)
        }
    }

    static func remove(_ url: URL) {
        try? FileManager.default.removeItem(at: url)
    }

    private static func kind(for url: URL) -> MediaKind? {
        let ext = url.pathExtension.lowercased()
        if ext == "mov" { return .recording }
        if photoExtensions.contains(ext) { return .photo }
        return nil
    }

    private static func files(in directory: URL) -> [URL] {
        let fm = FileManager.default
        guard let files = try? fm.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles]
        ) else { return [] }
        return files.filter {
            (try? $0.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true
        }
    }

    private static func ensureDirectory(_ directory: URL) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    private static func uniqueDestination(in directory: URL, filename: String) -> URL {
        let fm = FileManager.default
        let requested = directory.appendingPathComponent(filename)
        guard fm.fileExists(atPath: requested.path) else { return requested }

        let source = URL(fileURLWithPath: filename)
        let stem = source.deletingPathExtension().lastPathComponent
        let ext = source.pathExtension
        let suffix = UUID().uuidString.prefix(6).lowercased()
        return directory.appendingPathComponent("\(stem)_\(suffix).\(ext)")
    }
}
