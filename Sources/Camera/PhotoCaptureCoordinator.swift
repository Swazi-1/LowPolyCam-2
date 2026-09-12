import AVFoundation
import Foundation

/// Bridges Apple's photo-output readiness model into LowPolyCam's existing session-queue state.
/// The AVFoundation delegate is always invoked on the main queue; the lock makes readiness reads
/// safe from CameraManager.sessionQueue without moving camera work onto the UI thread.
final class PhotoCaptureCoordinator: NSObject, AVCapturePhotoOutputReadinessCoordinatorDelegate {
    private let readinessCoordinator: AVCapturePhotoOutputReadinessCoordinator
    private let stateLock = NSLock()
    private var readiness: AVCapturePhotoOutput.CaptureReadiness

    var onReadinessChanged: ((AVCapturePhotoOutput.CaptureReadiness) -> Void)?

    init(photoOutput: AVCapturePhotoOutput) {
        readinessCoordinator = AVCapturePhotoOutputReadinessCoordinator(photoOutput: photoOutput)
        readiness = photoOutput.captureReadiness
        super.init()
        readinessCoordinator.delegate = self
    }

    var captureReadiness: AVCapturePhotoOutput.CaptureReadiness {
        stateLock.lock()
        defer { stateLock.unlock() }
        return readiness
    }

    var isReady: Bool { captureReadiness == .ready }

    func startTracking(_ settings: AVCapturePhotoSettings) {
        readinessCoordinator.startTrackingCaptureRequest(using: settings)
        updateCachedReadiness(readinessCoordinator.captureReadiness)
    }

    func stopTracking(_ uniqueID: Int64) {
        readinessCoordinator.stopTrackingCaptureRequest(using: uniqueID)
        updateCachedReadiness(readinessCoordinator.captureReadiness)
    }

    private func updateCachedReadiness(_ value: AVCapturePhotoOutput.CaptureReadiness) {
        stateLock.lock()
        readiness = value
        stateLock.unlock()
    }

    func readinessCoordinator(
        _ coordinator: AVCapturePhotoOutputReadinessCoordinator,
        captureReadinessDidChange captureReadiness: AVCapturePhotoOutput.CaptureReadiness
    ) {
        updateCachedReadiness(captureReadiness)
        onReadinessChanged?(captureReadiness)
    }
}
