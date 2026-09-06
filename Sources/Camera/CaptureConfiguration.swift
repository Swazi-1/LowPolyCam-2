import Foundation

/// Whether the camera is being prepared for an interactive preview or for the exact sensor
/// format that will be recorded. Keeping this explicit replaces several old preview booleans.
enum CaptureConfigurationPhase {
    case preview
    case recording
}

/// Records why the idle preview may intentionally differ from the eventual recording format.
enum CameraPreviewPipeline {
    case native
    case videoProxy
    case slowMotionProxy
}
