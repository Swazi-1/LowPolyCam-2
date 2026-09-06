import Foundation

/// Generates collision-safe media names without making CameraManager own sequence bookkeeping.
enum MediaFilenameGenerator {
    private static let sequenceKey = "lowPolyCamMediaSequence"

    static func nextFilename(fileExtension: String, defaults: UserDefaults = .standard) -> String {
        let ext = fileExtension.lowercased()
        let recoveryNames = Set(CameraRecoveryStore.recordings().map(\.lastPathComponent))
        var number = defaults.integer(forKey: sequenceKey)
        if number < 1 || number > 9_999 { number = 1 }

        for _ in 0..<9_999 {
            let filename = String(format: "img_%04d.%@", number, ext)
            let tempURL = FileManager.default.temporaryDirectory.appendingPathComponent(filename)
            let next = number == 9_999 ? 1 : number + 1
            defaults.set(next, forKey: sequenceKey)
            if !FileManager.default.fileExists(atPath: tempURL.path), !recoveryNames.contains(filename) {
                return filename
            }
            number = next
        }

        return "img_\(UUID().uuidString.prefix(8).lowercased()).\(ext)"
    }
}
