import AVFoundation

/// Hardware-level white-balance application. CameraManager remains responsible for deciding when
/// a physical rear camera handoff is needed and for publishing user-visible state.
enum WhiteBalanceController {
    static func requiresPhysicalRearInput(
        preset: CameraManager.WhiteBalancePreset,
        position: CameraManager.CameraPosition
    ) -> Bool {
        preset != .auto && position == .back
    }

    static func apply(_ preset: CameraManager.WhiteBalancePreset, to device: AVCaptureDevice) -> Bool {
        do {
            try device.lockForConfiguration()
            defer { device.unlockForConfiguration() }

            if preset == .auto {
                if device.isWhiteBalanceModeSupported(.continuousAutoWhiteBalance) {
                    device.whiteBalanceMode = .continuousAutoWhiteBalance
                    return true
                }
                if device.isWhiteBalanceModeSupported(.autoWhiteBalance) {
                    device.whiteBalanceMode = .autoWhiteBalance
                    return true
                }
                return false
            }

            guard let temperature = preset.temperature,
                  device.isWhiteBalanceModeSupported(.locked) else { return false }

            let values = AVCaptureDevice.WhiteBalanceTemperatureAndTintValues(
                temperature: temperature,
                tint: preset.tint
            )
            if #available(iOS 26.0, *) {
                device.setWhiteBalanceModeLocked(whiteBalanceTemperatureAndTintValues: values, handler: nil)
                return true
            }

            guard device.isLockingWhiteBalanceWithCustomDeviceGainsSupported else { return false }
            var gains = device.deviceWhiteBalanceGains(for: values)
            let maximum = device.maxWhiteBalanceGain
            gains.redGain = min(max(gains.redGain, 1), maximum)
            gains.greenGain = min(max(gains.greenGain, 1), maximum)
            gains.blueGain = min(max(gains.blueGain, 1), maximum)
            device.setWhiteBalanceModeLocked(with: gains, completionHandler: nil)
            return true
        } catch {
            return false
        }
    }
}
