import Foundation
import CoreGraphics

/// Whether the camera is being prepared for an interactive preview or for the exact sensor
/// format that will be recorded.
enum CaptureConfigurationPhase {
    case preview
    case recording
}

/// Records why the idle preview may intentionally differ from the eventual recording format.
/// Rear 4K60 and rear HFR now stay native; slowMotionProxy remains only for a preserved front
/// camera fallback when the selected HFR sensor format is intentionally previewed at 60 fps.
enum CameraPreviewPipeline {
    case native
    case slowMotionProxy
}

/// Result of one capture-hardware application. Callers use this to avoid resetting AF/AE or
/// rebuilding UI state when the requested native configuration was already active.
struct CaptureConfigurationApplyResult {
    let displayedZoom: CGFloat
    let topologyChanged: Bool
    let deviceConfigurationChanged: Bool

    var requiresFocusReset: Bool { topologyChanged || deviceConfigurationChanged }
}

/// Immutable user intent consumed by one camera configuration operation. Keeping the dependent
/// quality/codec/zoom/WB tuple together prevents a queued operation from reading a mixture of
/// values after a newer main-thread edit has already changed part of the selection.
struct CaptureConfigurationRequest {
    let mode: CameraManager.CaptureMode
    let position: CameraManager.CameraPosition
    let resolution: VideoResolution
    let frameRate: VideoFrameRate
    let slowMotionResolution: VideoResolution
    let slowMotionFrameRate: CameraManager.SlowMotionFrameRate
    let codec: String
    let compression: VideoCompression
    let displayedZoom: CGFloat
    let whiteBalancePreset: CameraManager.WhiteBalancePreset
    let stabilizationEnabled: Bool
    let mirrorSelfies: Bool
    let photoAspect: String

    func replacingDisplayedZoom(_ displayedZoom: CGFloat) -> CaptureConfigurationRequest {
        CaptureConfigurationRequest(
            mode: mode,
            position: position,
            resolution: resolution,
            frameRate: frameRate,
            slowMotionResolution: slowMotionResolution,
            slowMotionFrameRate: slowMotionFrameRate,
            codec: codec,
            compression: compression,
            displayedZoom: displayedZoom,
            whiteBalancePreset: whiteBalancePreset,
            stabilizationEnabled: stabilizationEnabled,
            mirrorSelfies: mirrorSelfies,
            photoAspect: photoAspect
        )
    }
}
