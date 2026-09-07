//
//  CameraRecorderVolume.swift
//  LowPolyCam
//
//  Responsibility split from CameraRecorder.swift. Behavior intentionally
//  preserved; these helpers still operate on the same CameraRecorder state.
//

import Foundation

extension CameraRecorder {

    func pauseVolumeMonitoring() {
        Task { @MainActor in
            self.volumeObserver?.stop()
        }
    }

    func suppressVolumeTriggerBriefly(duration: TimeInterval = 1.0) {
        Task { @MainActor in
            self.volumeObserver?.ignoreTemporarily(duration: duration)
        }
    }

    func resumeVolumeMonitoring() {
        // Native AVCaptureEventInteraction is installed by CameraScreen.
        // Output-volume KVO cannot distinguish hardware presses from route,
        // Control Center, or shutter-sound volume changes.
        volumeObserver?.stop()
    }

    private func performVolumeButtonAction() {
        switch settings.volumeButtonAction {
        case .shutter:
            if settings.cameraMode == .photo {
                capturePhoto()
            } else {
                toggleRecording()
            }
        case .burst:
            // Burst capture rides on AVCapturePhotoOutput, so it works from
            // any mode; its own guards (not already recording/bursting/etc.)
            // make this a no-op if a burst isn't currently possible.
            startBurstCapture()
        case .recording:
            toggleRecording()
        }
    }
}
