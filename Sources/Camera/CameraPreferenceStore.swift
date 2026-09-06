import Foundation

/// Owns persisted camera choices. Keeping UserDefaults keys and migration-independent reads here
/// prevents CameraManager from duplicating persistence details throughout capture logic.
struct CameraPreferenceStore {
    struct Selection {
        let resolution: VideoResolution
        let frameRate: VideoFrameRate
        let slowMotionResolution: VideoResolution
        let slowMotionFrameRate: CameraManager.SlowMotionFrameRate
    }

    private enum Key {
        static let resolution = "selectedVideoResolution"
        static let frameRate = "selectedVideoFrameRate"
        static let slowMotionResolution = "selectedSlowMotionResolution"
        static let slowMotionFrameRate = "selectedSlowMotionFrameRate"
        static let videoStabilization = "videoStabilizationEnabled"
        static let photoResolution = "selectedPhotoResolution"
        static let rememberCaptureMode = "rememberCaptureMode"
        static let lastCaptureMode = "lastCaptureMode"
    }

    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    var initialSelection: Selection {
        Selection(
            resolution: VideoResolution(rawValue: defaults.string(forKey: Key.resolution) ?? "") ?? .p1080,
            frameRate: VideoFrameRate(rawValue: defaults.integer(forKey: Key.frameRate)) ?? .fps30,
            slowMotionResolution: VideoResolution(rawValue: defaults.string(forKey: Key.slowMotionResolution) ?? "") ?? .p1080,
            slowMotionFrameRate: CameraManager.SlowMotionFrameRate(rawValue: defaults.integer(forKey: Key.slowMotionFrameRate)) ?? .fps240
        )
    }

    var videoStabilizationEnabled: Bool {
        defaults.object(forKey: Key.videoStabilization) as? Bool ?? true
    }

    var photoResolutionID: String {
        defaults.string(forKey: Key.photoResolution) ?? "max"
    }

    func selection(for position: CameraManager.CameraPosition) -> Selection {
        let defaultSlowFPS: CameraManager.SlowMotionFrameRate = position == .front ? .fps120 : .fps240
        return Selection(
            resolution: VideoResolution(rawValue: defaults.string(forKey: positionKey(Key.resolution, position)) ?? "") ?? .p1080,
            frameRate: VideoFrameRate(rawValue: defaults.integer(forKey: positionKey(Key.frameRate, position))) ?? .fps30,
            slowMotionResolution: VideoResolution(rawValue: defaults.string(forKey: positionKey(Key.slowMotionResolution, position)) ?? "") ?? .p1080,
            slowMotionFrameRate: CameraManager.SlowMotionFrameRate(rawValue: defaults.integer(forKey: positionKey(Key.slowMotionFrameRate, position))) ?? defaultSlowFPS
        )
    }

    func save(_ selection: Selection, for position: CameraManager.CameraPosition) {
        defaults.set(selection.resolution.rawValue, forKey: positionKey(Key.resolution, position))
        defaults.set(selection.frameRate.rawValue, forKey: positionKey(Key.frameRate, position))
        defaults.set(selection.slowMotionResolution.rawValue, forKey: positionKey(Key.slowMotionResolution, position))
        defaults.set(selection.slowMotionFrameRate.rawValue, forKey: positionKey(Key.slowMotionFrameRate, position))
    }

    func saveVideoStabilization(_ enabled: Bool) {
        defaults.set(enabled, forKey: Key.videoStabilization)
    }

    func savePhotoResolutionID(_ id: String) {
        defaults.set(id, forKey: Key.photoResolution)
    }

    func rememberedCaptureMode() -> CameraManager.CaptureMode? {
        guard defaults.bool(forKey: Key.rememberCaptureMode),
              let raw = defaults.string(forKey: Key.lastCaptureMode) else { return nil }
        return CameraManager.CaptureMode(rawValue: raw)
    }

    func saveLastCaptureMode(_ mode: CameraManager.CaptureMode) {
        defaults.set(mode.rawValue, forKey: Key.lastCaptureMode)
    }

    private func positionKey(_ base: String, _ position: CameraManager.CameraPosition) -> String {
        position == .back ? base : "\(base).front"
    }
}
