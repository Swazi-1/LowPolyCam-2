import AVFoundation
import Combine
import Photos

@MainActor
final class PermissionManager: ObservableObject {
    enum State: Equatable {
        case checking
        case requesting
        case ready
        case denied([String])
    }

    @Published private(set) var state: State
    private var hasRequestedThisLaunch = false

    init() {
        // Returning users already granted these permissions. Enter the camera immediately
        // instead of rendering the permission gate for one task cycle on every cold launch.
        let cameraReady = AVCaptureDevice.authorizationStatus(for: .video) == .authorized
        let photosReady = PHPhotoLibrary.authorizationStatus(for: .addOnly) == .authorized
        state = cameraReady && photosReady ? .ready : .checking
        let microphone = AVCaptureDevice.authorizationStatus(for: .audio)
        AppEventLog.event("Permissions initialized: camera=\(cameraReady), photos=\(photosReady), microphone=\(microphone.rawValue)")
    }

    func requestRequiredPermissionsIfNeeded() async {
        guard !hasRequestedThisLaunch else { return }
        hasRequestedThisLaunch = true

        if allPermissionsGranted {
            state = .ready
            AppEventLog.event("Permissions already granted")
            return
        }

        state = .requesting

        if AVCaptureDevice.authorizationStatus(for: .video) == .notDetermined {
            _ = await AVCaptureDevice.requestAccess(for: .video)
        }

        if PHPhotoLibrary.authorizationStatus(for: .addOnly) == .notDetermined {
            _ = await PHPhotoLibrary.requestAuthorization(for: .addOnly)
        }

        refreshAuthorizationState()
    }

    func refreshAuthorizationState() {
        let missing = missingPermissionNames
        state = missing.isEmpty ? .ready : .denied(missing)
        AppEventLog.event(missing.isEmpty ? "Permissions ready" : "Permissions missing: \(missing.joined(separator: ", "))")
    }

    private var allPermissionsGranted: Bool {
        missingPermissionNames.isEmpty
    }

    private var missingPermissionNames: [String] {
        var missing: [String] = []

        if AVCaptureDevice.authorizationStatus(for: .video) != .authorized {
            missing.append("Camera")
        }
        if PHPhotoLibrary.authorizationStatus(for: .addOnly) != .authorized {
            missing.append("Photos")
        }

        return missing
    }
}
