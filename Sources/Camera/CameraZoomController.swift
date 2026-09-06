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
        recordingOrStarting: Bool,
        preferCurrentDeviceWhenPossible: Bool = false,
        forcePhysicalOpticalRouting: Bool = false
    ) -> RequestPlan {
        guard currentDevice.position == .back else {
            return .applyToCurrentDevice(displayedZoom)
        }

        let desired = desiredPhysicalDevice(in: availableDevices, displayedZoom: displayedZoom)

        // During a continuous drag, do not exchange physical inputs if the current sensor can
        // already represent the requested field of view digitally. This keeps 4K60/HFR zoom
        // responsive under load and defers the optical handoff until the gesture settles.
        if preferCurrentDeviceWhenPossible,
           activeDisplayedZoomRange(for: currentDevice).contains(displayedZoom) {
            return .applyToCurrentDevice(displayedZoom)
        }

        if currentDevice.isVirtualDevice {
            // Photo/normal Video can let Apple's virtual camera perform constituent switching.
            // Rear native 4K60/HFR are different: when their validated route is physical, force
            // the matching optical input while idle so a virtual device cannot digitally crop
            // the Ultra Wide all the way past 1x without actually changing lenses.
            if forcePhysicalOpticalRouting, desired != nil {
                if recordingOrStarting { return .blockedPhysicalSwitch }
                return .reconfigureLens(displayedZoom)
            }
            // A virtual camera is not proof that every constituent lens participates in the
            // CURRENT active format. Stay virtual only when its real active zoom interval can
            // represent this request. Otherwise an idle request may hand off to a legal physical
            // lens (notably Ultra Wide at native 4K60).
            if activeDisplayedZoomRange(for: currentDevice).contains(displayedZoom) {
                return .applyToCurrentDevice(displayedZoom)
            }
            guard desired?.uniqueID != currentDevice.uniqueID else {
                return .applyToCurrentDevice(displayedZoom)
            }
            if recordingOrStarting {
                return .blockedPhysicalSwitch
            }
            return .reconfigureLens(displayedZoom)
        }
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
        // Physical optical routes have a stable displayed base independent of whichever format
        // happened to be active the last time that inactive device was used.
        if !device.isVirtualDevice {
            if device.deviceType == .builtInUltraWideCamera { return 0.5 }
            if device.deviceType == .builtInWideAngleCamera { return 1 }
        }
        return activeDisplayedZoomRange(for: device).lowerBound
    }

    static func maximumDisplayedZoom(for device: AVCaptureDevice) -> CGFloat {
        activeDisplayedZoomRange(for: device).upperBound
    }

    static func activeDisplayedZoomRange(for device: AVCaptureDevice) -> ClosedRange<CGFloat> {
        let minimum = max(0.5, displayedZoom(forDeviceZoom: device.minAvailableVideoZoomFactor, device: device))
        let maximum = min(8, displayedZoom(forDeviceZoom: device.maxAvailableVideoZoomFactor, device: device))
        return min(minimum, maximum)...max(minimum, maximum)
    }

    /// Idle navigation is a union across legal optical inputs, not the digital range of whichever
    /// physical sensor happens to be active right now. This is what keeps 0.5x reachable after a
    /// manual-WB handoff to the 1x wide camera.
    static func displayedZoomDomain(
        for devices: [AVCaptureDevice],
        currentDevice: AVCaptureDevice? = nil
    ) -> ClosedRange<CGFloat> {
        guard !devices.isEmpty else { return 1...1 }
        let ranges: [ClosedRange<CGFloat>] = devices.map { device in
            if device.uniqueID == currentDevice?.uniqueID {
                return activeDisplayedZoomRange(for: device)
            }
            let minimum = minimumDisplayedZoom(for: device)
            let maximum = maximumDisplayedZoom(for: device)
            return min(minimum, maximum)...max(minimum, maximum)
        }
        let minimum = ranges.map(\.lowerBound).min() ?? 1
        let maximum = ranges.map(\.upperBound).max() ?? 1
        return min(minimum, maximum)...max(minimum, maximum)
    }

    static func clampDisplayedZoom(_ requested: CGFloat, to domain: ClosedRange<CGFloat>) -> CGFloat {
        min(max(requested, domain.lowerBound), domain.upperBound)
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
