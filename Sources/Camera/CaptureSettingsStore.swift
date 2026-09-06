import Foundation

/// Typed read-side access to capture settings owned by SwiftUI/AppStorage. This keeps raw
/// UserDefaults keys out of CameraManager's capture code without changing where settings live.
struct CaptureSettingsStore {
    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    var liveRecordingStatsEnabled: Bool {
        defaults.bool(forKey: "liveRecordingStats")
    }

    var audioMeterEnabled: Bool {
        let hudEnabled = defaults.object(forKey: "cameraHUDEnabled") as? Bool ?? true
        return hudEnabled && defaults.bool(forKey: "cameraHUDAudioMeter")
    }

    var burstCount: Int {
        let stored = defaults.integer(forKey: "burstCount")
        return [5, 10, 15].contains(stored) ? stored : 5
    }

    var photoAspect: String {
        defaults.string(forKey: "photoAspect") == "1:1" ? "1:1" : "4:3"
    }

    var splitDurationSeconds: Double {
        Double(defaults.integer(forKey: "splitMinutes")) * 60
    }

    var mirrorSelfies: Bool {
        defaults.bool(forKey: "mirrorSelfies")
    }

    var droppedFrameDiagnosticsEnabled: Bool {
        let hudEnabled = defaults.object(forKey: "cameraHUDEnabled") as? Bool ?? true
        return hudEnabled && defaults.bool(forKey: "cameraHUDDroppedFrames")
    }
}
