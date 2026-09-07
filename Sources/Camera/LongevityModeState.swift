import Foundation

/// Pure state for Longevity Mode. Normal camera preferences stay camera-specific and are never
/// overwritten by the temporary 720p/30/HEVC/Data Saver override.
struct LongevityModeState: Equatable {
    enum Camera: String, CaseIterable {
        case back
        case front
    }

    struct NormalVideoSelection: Equatable {
        let resolution: String
        let frameRate: Int
        let codec: String
        let compression: String
    }

    private(set) var enabled = false
    private(set) var normalSelections: [Camera: NormalVideoSelection] = [:]

    mutating func rememberNormalSelection(_ selection: NormalVideoSelection, for camera: Camera) {
        normalSelections[camera] = selection
    }

    func normalSelection(for camera: Camera) -> NormalVideoSelection? {
        normalSelections[camera]
    }

    mutating func commitEnabled(_ enabled: Bool) {
        self.enabled = enabled
    }
}
