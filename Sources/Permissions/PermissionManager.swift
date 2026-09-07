import AVFoundation
import Photos

@MainActor
final class PermissionManager: ObservableObject {
    enum State: Equatable {
        case checking
        case requesting
        case ready
        case denied([String])
    }

    @Published private(set) var state: State = .checking
    private var hasRequestedThisLaunch = false
    private var isRequestingPermissions = false

    func requestRequiredPermissionsIfNeeded() async {
        guard !hasRequestedThisLaunch else { return }
        hasRequestedThisLaunch = true

        if allPermissionsGranted {
            state = .ready
            return
        }

        state = .requesting
        isRequestingPermissions = true
        defer {
            isRequestingPermissions = false
            refreshAuthorizationState()
        }

        if AVCaptureDevice.authorizationStatus(for: .video) == .notDetermined {
            _ = await AVCaptureDevice.requestAccess(for: .video)
        }

        if AVCaptureDevice.authorizationStatus(for: .audio) == .notDetermined {
            _ = await AVCaptureDevice.requestAccess(for: .audio)
        }

        if PHPhotoLibrary.authorizationStatus(for: .addOnly) == .notDetermined {
            _ = await PHPhotoLibrary.requestAuthorization(for: .addOnly)
        }
    }

    func refreshAuthorizationState() {
        // Permission alerts foreground the app between requests. Keep the camera gate stable
        // until the complete sequence finishes instead of creating/destroying CameraView.
        guard hasRequestedThisLaunch, !isRequestingPermissions else { return }
        let missing = missingPermissionNames
        let nextState: State = missing.isEmpty ? .ready : .denied(missing)
        if state != nextState { state = nextState }
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
