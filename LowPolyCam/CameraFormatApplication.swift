import AVFoundation
import UIKit

extension CameraRecorder {

    private struct ActiveFormatIntent {
        var dimensions: (w: Int, h: Int)
        let fullFPS: Double
        var targetFPS: Double
        let isSlowMotion: Bool
    }

    /// Applies the active camera format + frame rate.
    /// Returns `true` only when the sensor format/fps actually changed.
    @discardableResult
    func applyActiveFormat(forRecording: Bool = false,
                           forceLowestIdlePreview: Bool = false) -> Bool {
        Task { @MainActor in self.volumeObserver?.ignoreTemporarily() }
        ensureCorrectCameraDevice(for: settings.cameraMode)
        guard var device = cameraInput?.device,
              var intent = resolveActiveFormatIntent(forRecording: forRecording,
                                                     forceLowestIdlePreview: forceLowestIdlePreview) else {
            return false
        }

        let policy = CaptureModePolicy(cameraMode: settings.cameraMode)
        let request = CaptureFormatRequest(width: intent.dimensions.w,
                                           height: intent.dimensions.h,
                                           fps: intent.targetFPS,
                                           policy: policy)
        var format = CaptureModeFormatRouter.selectFormat(device: device, request: request)

        guard routeUnsupportedVirtualVideoFormatIfNeeded(device: &device,
                                                         format: &format,
                                                         request: request,
                                                         targetFPS: intent.targetFPS) else {
            return false
        }

        if format == nil && intent.targetFPS == 60 {
            format = CameraFormatSelector.bestVideoFormat(for: device,
                                                          width: intent.dimensions.w,
                                                          height: intent.dimensions.h,
                                                          fps: 30)
            if format != nil {
                intent.targetFPS = 30
                Task { @MainActor in
                    self.settings.frameRate = .fps30
                    self.notice = "60 fps unavailable · Switched to 30 fps"
                }
            }
        }

        guard let finalFormat = format else {
            return applySlowMotionFallbackIfAvailable(device: device, intent: intent)
        }

        let changed = applyFormatIfNeeded(device: device,
                                          format: finalFormat,
                                          targetFPS: intent.targetFPS)
        Task { @MainActor in self.volumeObserver?.ignoreTemporarily() }
        return changed
    }

    private func resolveActiveFormatIntent(forRecording: Bool,
                                           forceLowestIdlePreview: Bool) -> ActiveFormatIntent? {
        let isSlow = settings.cameraMode == .slowMo && isSlowMoSupportedOnCurrentLens
        var dimensions: (w: Int, h: Int)
        let fullFPS: Double

        if settings.cameraMode == .photo {
            dimensions = (1920, 1080)
            fullFPS = 30
        } else if isSlow {
            let selectedRate: SlowMoFrameRate
            if !availableSlowMoRates.contains(settings.slowMoFrameRate) {
                let fallback = availableSlowMoRates.first ?? .fps120
                selectedRate = fallback
                Task { @MainActor in self.settings.slowMoFrameRate = fallback }
            } else {
                selectedRate = settings.slowMoFrameRate
            }
            fullFPS = Double(selectedRate.value)
            dimensions = settings.slowMoResolution.captureDimensions
        } else {
            dimensions = settings.resolution.captureDimensions
            if let locked = settings.resolution.lockedFrameRate,
               settings.frameRate != locked {
                Task { @MainActor in
                    self.settings.frameRate = locked
                    self.notice = "\(self.settings.resolution.label) locked to \(locked.label)"
                }
            }
            fullFPS = Double((settings.resolution.lockedFrameRate ?? settings.frameRate).value)
        }

        var targetFPS: Double
        if forRecording || isSlow {
            targetFPS = fullFPS
        } else {
            let profile = PerformanceProfile.current(settings: settings, thermalState: thermalState)
            let cap = profile.idlePreviewCap(forceLowest: forceLowestIdlePreview)
            if let capRes = cap.resolution,
               dimensions.h > capRes.captureDimensions.h {
                dimensions = capRes.captureDimensions
            }
            targetFPS = min(fullFPS, cap.fps)
        }

        return ActiveFormatIntent(dimensions: dimensions,
                                  fullFPS: fullFPS,
                                  targetFPS: targetFPS,
                                  isSlowMotion: isSlow)
    }

    private func routeUnsupportedVirtualVideoFormatIfNeeded(device: inout AVCaptureDevice,
                                                             format: inout AVCaptureDevice.Format?,
                                                             request: CaptureFormatRequest,
                                                             targetFPS: Double) -> Bool {
        guard format == nil,
              position == .back,
              settings.cameraMode == .video,
              targetFPS >= 59,
              let routedDevice = physicalDevice(for: zoomFactor > 0 ? zoomFactor : 1),
              let physicalFormat = CaptureModeFormatRouter.selectFormat(device: routedDevice, request: request) else {
            return true
        }

        switchCameraInput(to: routedDevice)
        guard cameraInput?.device.uniqueID == routedDevice.uniqueID else { return false }
        device = routedDevice
        format = physicalFormat
        return true
    }

    private func applySlowMotionFallbackIfAvailable(device: AVCaptureDevice,
                                                     intent: ActiveFormatIntent) -> Bool {
        guard intent.isSlowMotion,
              let fallbackFormat = CameraFormatSelector.bestSlowMoFormat(for: device, fps: intent.fullFPS) else {
            Task { @MainActor in self.notice = "Format adjusted for this lens" }
            return false
        }

        let changed = applyFormatIfNeeded(device: device,
                                          format: fallbackFormat,
                                          targetFPS: intent.fullFPS)
        if changed {
            Task { @MainActor in
                let dims = CMVideoFormatDescriptionGetDimensions(fallbackFormat.formatDescription)
                let closestRes: Resolution = dims.height >= 1080 ? .p1080 : .p720
                self.settings.slowMoResolution = closestRes
                self.notice = "\(self.settings.slowMoFrameRate.label) set to \(closestRes.label)"
            }
        }
        Task { @MainActor in self.volumeObserver?.ignoreTemporarily() }
        return changed
    }

    private func applyFormatIfNeeded(device: AVCaptureDevice,
                                     format: AVCaptureDevice.Format,
                                     targetFPS: Double) -> Bool {
        let newKey = Self.formatKey(device: device, format: format, fps: targetFPS)
        guard newKey != lastAppliedFormatKey else { return false }
        guard applyUnifiedHardwareConfiguration(to: device, format: format, targetFPS: targetFPS) else {
            return false
        }
        refreshZoomLimits()
        lastAppliedFormatKey = newKey
        return true
    }

    @discardableResult
    func applyUnifiedHardwareConfiguration(to device: AVCaptureDevice,
                                           format: AVCaptureDevice.Format,
                                           targetFPS: Double) -> Bool {
        guard isSupportedFrameRate(targetFPS, by: format) else {
            Task { @MainActor in self.notice = "This camera format does not support the requested frame rate" }
            return false
        }

        session.beginConfiguration()
        defer { session.commitConfiguration() }

        do {
            try device.lockForConfiguration()
            defer { device.unlockForConfiguration() }

            applySensorFormatAndFrameRate(device: device, format: format, targetFPS: targetFPS)
            applyContinuousFocusAndExposure(device: device)
            applyProCaptureSettings(device: device)
            preserveZoomAcrossFormatChange(device: device)
            return true
        } catch {
            DebugLog.write("❌ applyActiveFormat() lockForConfiguration failed: \(error.localizedDescription)")
            Task { @MainActor in self.notice = "Camera settings busy" }
            return false
        }
    }

    private func isSupportedFrameRate(_ targetFPS: Double,
                                      by format: AVCaptureDevice.Format) -> Bool {
        targetFPS.isFinite && targetFPS > 0 &&
            format.videoSupportedFrameRateRanges.contains {
                $0.minFrameRate - 0.5 <= targetFPS && targetFPS <= $0.maxFrameRate + 0.5
            }
    }

    private func applySensorFormatAndFrameRate(device: AVCaptureDevice,
                                               format: AVCaptureDevice.Format,
                                               targetFPS: Double) {
        device.activeFormat = format
        if format.supportedColorSpaces.contains(.sRGB) {
            device.activeColorSpace = .sRGB
        }
        focusGeneration += 1
        exposureGeneration += 1
        configurePhotoOutput(for: device)

        let desiredFPS = max(1.0, targetFPS.rounded())
        if format.isAutoVideoFrameRateSupported {
            device.isAutoVideoFrameRateEnabled = false
        }

        let fpsInt = max(Int(desiredFPS), 1)
        var duration = CMTime(value: 1, timescale: CMTimeScale(fpsInt))
        if let range = format.videoSupportedFrameRateRanges.first(where: {
            $0.minFrameRate - 0.5 <= desiredFPS && desiredFPS <= $0.maxFrameRate + 0.5
        }) {
            let fastest = range.minFrameDuration
            let slowest = range.maxFrameDuration
            if CMTimeCompare(duration, fastest) < 0 { duration = fastest }
            if CMTimeCompare(duration, slowest) > 0 { duration = slowest }
        }
        device.activeVideoMinFrameDuration = duration
        device.activeVideoMaxFrameDuration = duration

        let actualDuration = device.activeVideoMinFrameDuration.seconds
        let actualFPS = actualDuration > 0 ? 1.0 / actualDuration : 0
        DebugLog.write(String(format: "[sensor] requested %.2ffps, active %.2ffps", desiredFPS, actualFPS))
        Task { @MainActor in
            self.activeSensorFPS = actualFPS
            if abs(actualFPS - desiredFPS) > 0.75 {
                self.notice = String(format: "Camera negotiated %.0f fps", actualFPS)
            }
        }
    }

    private func applyContinuousFocusAndExposure(device: AVCaptureDevice) {
        if device.isSmoothAutoFocusSupported {
            device.isSmoothAutoFocusEnabled = true
        }
        if device.isFocusModeSupported(.continuousAutoFocus) {
            device.focusMode = .continuousAutoFocus
        }
        if device.isExposureModeSupported(.continuousAutoExposure) {
            device.exposureMode = .continuousAutoExposure
        }
        Task { @MainActor in
            self.focusLocked = false
            self.exposureLocked = false
        }
        device.isSubjectAreaChangeMonitoringEnabled = true
    }

    private func applyProCaptureSettings(device: AVCaptureDevice) {
        let minBias = device.minExposureTargetBias
        let maxBias = device.maxExposureTargetBias
        let clampedBias = max(minBias, min(settings.exposureBias, maxBias))
        device.setExposureTargetBias(clampedBias, completionHandler: nil)

        if let values = settings.whiteBalance.kelvin {
            guard device.isLockingWhiteBalanceWithCustomDeviceGainsSupported else { return }
            let tempAndTint = AVCaptureDevice.WhiteBalanceTemperatureAndTintValues(temperature: values.temp,
                                                                                   tint: values.tint)
            var gains = device.deviceWhiteBalanceGains(for: tempAndTint)
            let maxGain = device.maxWhiteBalanceGain
            gains.redGain = max(1.0, min(gains.redGain.isFinite ? gains.redGain : 1.0, maxGain))
            gains.greenGain = max(1.0, min(gains.greenGain.isFinite ? gains.greenGain : 1.0, maxGain))
            gains.blueGain = max(1.0, min(gains.blueGain.isFinite ? gains.blueGain : 1.0, maxGain))
            device.setWhiteBalanceModeLocked(with: gains, completionHandler: nil)
        } else if device.isWhiteBalanceModeSupported(.continuousAutoWhiteBalance) {
            device.whiteBalanceMode = .continuousAutoWhiteBalance
        }
    }

    private func preserveZoomAcrossFormatChange(device: AVCaptureDevice) {
        let baseline = CameraFormatSelector.wideAngleBaseline(for: device)
        let ceiling = device.activeFormat.videoMaxZoomFactor
        let floor = device.minAvailableVideoZoomFactor
        let desiredRaw: CGFloat
        if zoomBaselineSnapshot > 0, zoomFactor > 0 {
            desiredRaw = zoomFactor * baseline
        } else {
            desiredRaw = max(baseline, floor)
        }
        device.videoZoomFactor = min(max(desiredRaw, floor), ceiling)
    }

}
