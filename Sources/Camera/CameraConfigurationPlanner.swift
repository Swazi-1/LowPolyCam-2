import Foundation

/// Pure decision policy for the AVFoundation capture graph. Keeping this free of AVCaptureDevice
/// objects makes the expensive routing rules unit-testable without camera hardware.
enum CameraConfigurationRoute: String, Equatable {
    case noChange
    case deviceOnlyUpdate
    case sameInputReconfigure
    case physicalInputReplacement
}

struct CameraConfigurationPlan: Equatable {
    let route: CameraConfigurationRoute
    let requestedFrameRate: Double
    /// Maximum frame rate the session actually needs to reserve for this input. A nil value means
    /// leave AVCaptureDeviceInput.videoMinFrameDurationOverride at its default `.invalid` value.
    let resourceFrameRateOverride: Double?
}

enum CameraConfigurationPlanner {
    static func plan(
        currentDeviceID: String?,
        targetDeviceID: String,
        sameFormat: Bool,
        sameFrameRate: Bool,
        samePhotoDimensions: Bool,
        auxiliaryGraphChangeNeeded: Bool,
        baseOutputsPresent: Bool,
        devicePropertiesNeedUpdate: Bool,
        requestedFrameRate: Double,
        formatMaximumFrameRate: Double
    ) -> CameraConfigurationPlan {
        let sameInput = currentDeviceID == targetDeviceID
        let route: CameraConfigurationRoute

        if sameInput,
           sameFormat,
           sameFrameRate,
           samePhotoDimensions,
           !auxiliaryGraphChangeNeeded,
           baseOutputsPresent {
            route = devicePropertiesNeedUpdate ? .deviceOnlyUpdate : .noChange
        } else if sameInput {
            route = .sameInputReconfigure
        } else {
            route = .physicalInputReplacement
        }

        return CameraConfigurationPlan(
            route: route,
            requestedFrameRate: requestedFrameRate,
            resourceFrameRateOverride: frameRateOverride(
                requestedFrameRate: requestedFrameRate,
                formatMaximumFrameRate: formatMaximumFrameRate
            )
        )
    }

    /// Apple recommends limiting AVCaptureSession's reserved maximum frame rate when a selected
    /// format is capable of substantially more FPS than the app intends to use. Do not install a
    /// redundant override when the selected format already tops out at the requested rate.
    static func frameRateOverride(
        requestedFrameRate: Double,
        formatMaximumFrameRate: Double
    ) -> Double? {
        guard requestedFrameRate.isFinite,
              formatMaximumFrameRate.isFinite,
              requestedFrameRate > 0,
              formatMaximumFrameRate > requestedFrameRate + 0.5 else { return nil }
        return requestedFrameRate
    }
}

/// Internal rollout switches. These are deliberately not user preferences; each switch preserves
/// the old proven path as an immediate fallback while the Apple-native routing is device-tested.
enum AppleCameraFeatureFlags {
    static let virtualRoutingV2 = true
    static let responsivePhotoPipelineV2 = true
    static let captureResourceManagementV2 = true
    static let fastCapturePrioritization = true
}
