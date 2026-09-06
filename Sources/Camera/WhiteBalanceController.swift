import AVFoundation

/// Hardware-level white-balance application. CameraManager decides when an input handoff is
/// required; this type distinguishes a request being accepted from the lock operation completing.
enum WhiteBalanceController {
    static func requiresPhysicalRearInput(
        preset: CameraManager.WhiteBalancePreset,
        position: CameraManager.CameraPosition
    ) -> Bool {
        preset != .auto && position == .back
    }

    @discardableResult
    static func apply(
        _ preset: CameraManager.WhiteBalancePreset,
        to device: AVCaptureDevice,
        completion: ((Bool) -> Void)? = nil
    ) -> Bool {
        do {
            try device.lockForConfiguration()

            if preset == .auto {
                if device.isWhiteBalanceModeSupported(.continuousAutoWhiteBalance) {
                    device.whiteBalanceMode = .continuousAutoWhiteBalance
                    device.unlockForConfiguration()
                    completion?(true)
                    return true
                }
                if device.isWhiteBalanceModeSupported(.autoWhiteBalance) {
                    device.whiteBalanceMode = .autoWhiteBalance
                    device.unlockForConfiguration()
                    completion?(true)
                    return true
                }
                device.unlockForConfiguration()
                return false
            }

            guard let temperature = preset.temperature,
                  device.isWhiteBalanceModeSupported(.locked) else {
                device.unlockForConfiguration()
                return false
            }

            let values = AVCaptureDevice.WhiteBalanceTemperatureAndTintValues(
                temperature: temperature,
                tint: preset.tint
            )

            if #available(iOS 26.0, *) {
                device.setWhiteBalanceModeLocked(
                    whiteBalanceTemperatureAndTintValues: values
                ) { _ in
                    completion?(true)
                }
                device.unlockForConfiguration()
                return true
            }

            guard device.isLockingWhiteBalanceWithCustomDeviceGainsSupported else {
                device.unlockForConfiguration()
                return false
            }
            var gains = device.deviceWhiteBalanceGains(for: values)
            let maximum = device.maxWhiteBalanceGain
            gains.redGain = min(max(gains.redGain, 1), maximum)
            gains.greenGain = min(max(gains.greenGain, 1), maximum)
            gains.blueGain = min(max(gains.blueGain, 1), maximum)
            device.setWhiteBalanceModeLocked(with: gains) { _ in
                completion?(true)
            }
            device.unlockForConfiguration()
            return true
        } catch {
            return false
        }
    }
}
