import SwiftUI

@main
struct LowPolyCamApp: App {
    @StateObject private var permissionManager = PermissionManager()
    private var accent = CameraAccent()

    init() {
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
