import SwiftUI

@main
struct LowPolyCamApp: App {
    @StateObject private var permissionManager = PermissionManager()

    var body: some Scene {
        WindowGroup {
            ContentView(permissionManager: permissionManager)
        }
    }
}
