import SwiftUI

@main
struct LowPolyCamApp: App {
    @StateObject private var permissionManager = PermissionManager()
    private var accent = CameraAccent()

    init() {
        DiagnosticLogger.shared.start()
        DiagnosticLogger.shared.info("LowPolyCam app initialized", category: "App")
        // Set the haptics-during-recording policy before AVCaptureSession can activate audio.
        CameraHaptics.prepareSystemPolicy()
    }

    var body: some Scene {
        WindowGroup {
            ContentView(permissionManager: permissionManager)
                .environment(\.cameraTint, accent.color)
                .tint(accent.color)
                .accentColor(accent.color)
        }
    }
}
