import Foundation

enum VideoResolution: String, CaseIterable, Identifiable {
    case p4k = "4K"
    case p1080 = "1080p"
    case p720 = "720p"

    var id: String { rawValue }

    var dimensions: (width: Int32, height: Int32) {
        switch self {
        case .p4k: (3840, 2160)
        case .p1080: (1920, 1080)
        case .p720: (1280, 720)
        }
    }
}

enum VideoFrameRate: Int, CaseIterable, Identifiable {
    case fps30 = 30
    case fps60 = 60

    var id: Int { rawValue }
    var label: String { "\(rawValue) fps" }
}

enum VideoCompression: String, CaseIterable, Identifiable {
    case dataSaver = "Data Saver"
    case medium = "Medium"
    case high = "High"

    var id: String { rawValue }

    var bitsPerPixel: Double {
        switch self {
        case .dataSaver: return 0.055
        case .medium: return 0.10
        case .high: return 0.18
        }
    }
}

enum VideoQuickPreset: String, CaseIterable, Identifiable {
    case balanced = "Balanced"
    case highQuality = "High Quality"
    case allRounder = "All Rounder"
    case allDay = "All Day"
    case social = "Social"

    var id: String { rawValue }
    var resolution: VideoResolution { self == .highQuality ? .p4k : self == .allDay ? .p720 : .p1080 }
    var frameRate: VideoFrameRate { self == .allRounder ? .fps60 : .fps30 }

    var compression: VideoCompression {
        switch self {
        case .highQuality, .allRounder: return .high
        case .allDay, .social: return .dataSaver
        case .balanced: return .medium
        }
    }

    var detail: String { "\(resolution.rawValue) · \(compression.rawValue) · \(frameRate.rawValue) fps · HEVC" }
}

