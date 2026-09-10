import Foundation

struct CameraVideoFormatPair: Identifiable {
    let resolution: VideoResolution
    let frameRate: VideoFrameRate

    var id: String { "\(resolution.rawValue)-\(frameRate.rawValue)" }
}

struct CameraSlowMotionFormatPair: Identifiable {
    let resolution: VideoResolution
    let frameRate: CameraManager.SlowMotionFrameRate

    var id: String { "\(resolution.rawValue)-\(frameRate.rawValue)" }
}

/// A complete capability answer for one camera-position/device set. The snapshot is built on the
/// camera queue and rendered by Settings without scanning AVFoundation formats during SwiftUI body
/// evaluation.
struct CameraCapabilitySnapshot {
    let position: String
    let deviceIDs: [String]
    let videoPairs: [CameraVideoFormatPair]
    let slowMotionPairs: [CameraSlowMotionFormatPair]
    let availableVideoCodecs: [String]
    let photoMegapixelOptions: [Int]
    let isReady: Bool

    static let empty = CameraCapabilitySnapshot(
        position: "",
        deviceIDs: [],
        videoPairs: [],
        slowMotionPairs: [],
        availableVideoCodecs: [],
        photoMegapixelOptions: [],
        isReady: false
    )
}
