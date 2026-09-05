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

    func requestRequiredPermissionsIfNeeded() async {
        guard !hasRequestedThisLaunch else { return }
        hasRequestedThisLaunch = true

        if allPermissionsGranted {
            state = .ready
            return
        }

        state = .requesting

        if AVCaptureDevice.authorizationStatus(for: .video) == .notDetermined {
            _ = await AVCaptureDevice.requestAccess(for: .video)
        }

        if AVCaptureDevice.authorizationStatus(for: .audio) == .notDetermined {
            _ = await AVCaptureDevice.requestAccess(for: .audio)
        }

        if PHPhotoLibrary.authorizationStatus(for: .addOnly) == .notDetermined {
            _ = await PHPhotoLibrary.requestAuthorization(for: .addOnly)
        }

        refreshAuthorizationState()
    }

    func refreshAuthorizationState() {
        let missing = missingPermissionNames
        state = missing.isEmpty ? .ready : .denied(missing)
    }

    private var allPermissionsGranted: Bool {
        missingPermissionNames.isEmpty
    }

    private var missingPermissionNames: [String] {
        var missing: [String] = []

        if AVCaptureDevice.authorizationStatus(for: .video) != .authorized {
            missing.append("Camera")
        }
        if AVCaptureDevice.authorizationStatus(for: .audio) != .authorized {
            missing.append("Microphone")
        }
        if PHPhotoLibrary.authorizationStatus(for: .addOnly) != .authorized {
            missing.append("Photos")
        }

        return missing
    }
}
