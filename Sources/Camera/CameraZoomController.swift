import AVFoundation
import Foundation

/// Zoom/lens math only. Session reconfiguration remains in CameraManager, while all conversions
/// between LowPolyCam's displayed zoom and AVFoundation device zoom live here.
enum CameraZoomController {
    enum RequestPlan {
        case applyToCurrentDevice(CGFloat)
        case reconfigureLens(CGFloat)
        case blockedPhysicalSwitch
    }

    static func planRequest(
        displayedZoom: CGFloat,
        currentDevice: AVCaptureDevice,
        availableDevices: [AVCaptureDevice],
        mode: CameraManager.CaptureMode,
        recordingOrStarting: Bool
    ) -> RequestPlan {
        guard !currentDevice.isVirtualDevice, currentDevice.position == .back else {
            return .applyToCurrentDevice(displayedZoom)
        }

        let desired = desiredPhysicalDevice(in: availableDevices, displayedZoom: displayedZoom)
        let wantsDifferentLens = desired?.uniqueID != currentDevice.uniqueID
        guard wantsDifferentLens else { return .applyToCurrentDevice(displayedZoom) }

        if recordingOrStarting && mode != .video {
            return .blockedPhysicalSwitch
        }
        if !recordingOrStarting {
            return .reconfigureLens(displayedZoom)
        }
        // Normal Video stays on the sensor it started recording with and uses digital crop when
        // the displayed zoom crosses another optical lens boundary.
        return .applyToCurrentDevice(displayedZoom)
    }

    static func desiredPhysicalDevice(
        in devices: [AVCaptureDevice],
        displayedZoom: CGFloat
    ) -> AVCaptureDevice? {
        let physical = devices.filter { !$0.isVirtualDevice }
        if displayedZoom < 1 {
            return physical.first(where: { $0.deviceType == .builtInUltraWideCamera })
                ?? physical.first(where: { $0.deviceType == .builtInWideAngleCamera })
                ?? physical.first
        }
        if displayedZoom >= 1.75,
           let telephoto = physical.first(where: { $0.deviceType == .builtInTelephotoCamera }) {
            return telephoto
        }
        return physical.first(where: { $0.deviceType == .builtInWideAngleCamera }) ?? physical.first
    }

    static func minimumDisplayedZoom(for device: AVCaptureDevice) -> CGFloat {
        max(0.5, displayedZoom(forDeviceZoom: device.minAvailableVideoZoomFactor, device: device))
    }

    static func maximumDisplayedZoom(for device: AVCaptureDevice) -> CGFloat {
        min(8, displayedZoom(forDeviceZoom: device.maxAvailableVideoZoomFactor, device: device))
    }

    static func snappedDisplayedZoom(_ requested: CGFloat, for device: AVCaptureDevice) -> CGFloat {
        let minimum = minimumDisplayedZoom(for: device)
        let maximum = maximumDisplayedZoom(for: device)
        let clamped = min(max(requested, minimum), maximum)
        if minimum <= 0.5, abs(clamped - 0.5) < 0.10 { return 0.5 }
        if abs(clamped - 1) < 0.16 { return 1 }
        return clamped
    }

    static func displayedZoom(forDeviceZoom deviceZoom: CGFloat, device: AVCaptureDevice) -> CGFloat {
        deviceZoom / wideAngleDeviceZoomFactor(for: device)
    }

    static func deviceZoom(forDisplayedZoom displayedZoom: CGFloat, device: AVCaptureDevice) -> CGFloat {
        let requested = displayedZoom * wideAngleDeviceZoomFactor(for: device)
        return min(max(requested, device.minAvailableVideoZoomFactor), device.maxAvailableVideoZoomFactor)
    }

    static func formattedLabel(for displayedZoom: CGFloat) -> String {
        abs(displayedZoom.rounded() - displayedZoom) < 0.01
            ? "\(Int(displayedZoom.rounded()))×"
            : String(format: "%.1f×", displayedZoom)
    }

    private static func wideAngleDeviceZoomFactor(for device: AVCaptureDevice) -> CGFloat {
        if device.deviceType == .builtInUltraWideCamera { return 2 }
        if device.deviceType == .builtInTelephotoCamera {
            return 1 / max(telephotoOpticalFactor(for: device), 1)
        }
        let hasUltraWide = device.constituentDevices.contains { $0.deviceType == .builtInUltraWideCamera }
        guard hasUltraWide, let switchFactor = device.virtualDeviceSwitchOverVideoZoomFactors.first else {
            return 1
        }
        return CGFloat(switchFactor.doubleValue)
    }

    private static func telephotoOpticalFactor(for device: AVCaptureDevice) -> CGFloat {
        guard device.deviceType == .builtInTelephotoCamera,
              let wide = AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: device.position) else {
            return 1
        }
        let wideFOV = Double(wide.activeFormat.videoFieldOfView) * .pi / 180
        let teleFOV = Double(device.activeFormat.videoFieldOfView) * .pi / 180
        guard wideFOV > 0, teleFOV > 0 else { return 2 }
        let factor = tan(wideFOV / 2) / tan(teleFOV / 2)
        return CGFloat(min(max(factor, 1.5), 8))
    }
}
