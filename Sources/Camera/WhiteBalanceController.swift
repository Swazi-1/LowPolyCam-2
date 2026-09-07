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
        // A verified no-op avoids the first unnecessary device write when Auto is already active.
        if preset == .auto,
           device.isWhiteBalanceModeSupported(.continuousAutoWhiteBalance),
           device.whiteBalanceMode == .continuousAutoWhiteBalance {
            completion?(true)
            return true
        }

        do {
            try device.lockForConfiguration()

            if preset == .auto {
                if device.isWhiteBalanceModeSupported(.continuousAutoWhiteBalance) {
                    if device.whiteBalanceMode != .continuousAutoWhiteBalance {
                        device.whiteBalanceMode = .continuousAutoWhiteBalance
                    }
                    device.unlockForConfiguration()
                    completion?(true)
                    return true
                }
                if device.isWhiteBalanceModeSupported(.autoWhiteBalance) {
                    if device.whiteBalanceMode != .autoWhiteBalance {
                        device.whiteBalanceMode = .autoWhiteBalance
                    }
                    device.unlockForConfiguration()
                    completion?(true)
                    return true
                }
                device.unlockForConfiguration()
                return false
            }

            guard let temperature = preset.temperature,
                  device.isWhiteBalanceModeSupported(.locked),
                  device.isLockingWhiteBalanceWithCustomDeviceGainsSupported else {
                device.unlockForConfiguration()
                return false
            }

            let values = AVCaptureDevice.WhiteBalanceTemperatureAndTintValues(
                temperature: temperature,
                tint: preset.tint
            )

            // Temperature/tint can convert to gains outside this sensor's legal range. Keep the
            // finite validation and clamping; never send unchecked gains to AVFoundation.
            var gains = device.deviceWhiteBalanceGains(for: values)
            let maximum = device.maxWhiteBalanceGain
            guard maximum.isFinite, maximum >= 1,
                  gains.redGain.isFinite, gains.greenGain.isFinite, gains.blueGain.isFinite else {
                device.unlockForConfiguration()
                return false
            }
            gains.redGain = min(max(gains.redGain, 1), maximum)
            gains.greenGain = min(max(gains.greenGain, 1), maximum)
            gains.blueGain = min(max(gains.blueGain, 1), maximum)

            let current = device.deviceWhiteBalanceGains
            let alreadyLockedToRequestedGains = device.whiteBalanceMode == .locked &&
                abs(current.redGain - gains.redGain) < 0.01 &&
                abs(current.greenGain - gains.greenGain) < 0.01 &&
                abs(current.blueGain - gains.blueGain) < 0.01
            if alreadyLockedToRequestedGains {
                device.unlockForConfiguration()
                completion?(true)
                return true
            }

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
