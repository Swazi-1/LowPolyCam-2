import SwiftUI

@main
struct LowPolyCamApp: App {
    @StateObject private var permissionManager = PermissionManager()
    private var accent = CameraAccent()
    @AppStorage("appColorScheme") private var appColorScheme = "dark"

    init() {
        LowPolyCamDefaults.register()
        AppEventLog.beginNewSession()
        AppEventLog.event("App initialized")
    }

    var body: some Scene {
        WindowGroup {
            ContentView(permissionManager: permissionManager)
                .environment(\.cameraTint, accent.color)
                .tint(accent.color)
                .accentColor(accent.color)
                .preferredColorScheme(resolvedColorScheme(appColorScheme))
        }
    }
}

private enum LowPolyCamDefaults {
    static func register() {
        UserDefaults.standard.register(defaults: [
            "appColorScheme": "dark",
            "iconAppearance": "Ice",
            "selectedVideoResolution": "1080p",
            "selectedVideoFrameRate": 60,
            "selectedVideoCodec": "HEVC",
            "videoCompression": "High",
            "videoStabilizationEnabled": true,
            "selectedSlowMotionResolution": "1080p",
            "selectedSlowMotionFrameRate": 240,
            "selectedPhotoMegapixels": 12,
            "photoFileFormat": "HEIC",
            "photoFlashMode": "Auto",
            "photoAspect": "4:3",
            "burstCount": 10,
            "shutterDelay": 0,
            "hapticCaptureEnabled": true,
            "hapticStrength": "Medium",
            "countdownHaptics": false,
            "zoomSpeed": 1.0,
            "tapZoomReset": true,
            "recordingLock": false,
            "lowStorageWarning": true,
            "rememberCaptureMode": false,
            "lastCaptureMode": "VIDEO",
            "lastCameraPosition": "back",
            "mirrorSelfies": false,
            "cameraGridEnabled": false,
            "gridOpacity": 1.0,
            "levelMeterEnabled": false,
            "centerCrosshair": false,
            "keepScreenAwakeEnabled": false,
            "cameraHUDEnabled": true,
            "cameraHUDResolution": true,
            "cameraHUDFPS": true,
            "cameraHUDRemaining": true,
            "cameraHUDWhiteBalance": false,
            "cameraHUDBattery": true,
            "cameraHUDStorage": false,
            "cameraHUDDroppedFrames": false,
            "thermalHUD": false,
            "hudTextSize": 10.0,
            "liveRecordingStats": false,
            "splitMinutes": 0,
            "longevityMode": false,
            "diagnosticLoggingEnabled": false
        ])
    }
}
