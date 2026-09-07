import AVFoundation

extension CameraRecorder {

    func updateCaptureFormat(completion: (() -> Void)? = nil) {
        sessionQueue.async {
            self.refreshCapabilitiesThenApplyFormat(completion: completion)
        }
    }

    private struct CameraCapabilityScan {
        var rates = Set<FrameRate>()
        var widestPixels = 0
        var slowByResolution: [Resolution: Set<SlowMoFrameRate>] = [:]
        var slowResolutions = Set<Resolution>()
        var ratesByResolution: [Resolution: Set<FrameRate>] = [:]
    }

    private struct CameraCapabilitySnapshot {
        let frameRates: [FrameRate]
        let resolutions: [Resolution]
        let slowMoRates: [SlowMoFrameRate]
        let slowMoResolutions: [Resolution]
        let slowRatesByResolution: [Resolution: Set<SlowMoFrameRate>]
        let ratesByResolution: [Resolution: Set<FrameRate>]
        let slowMotionSupported: Bool
        let photoMegapixels: [PhotoMegapixels]
        let isFrontCamera: Bool
    }

    func refreshCapabilitiesThenApplyFormat(completion: (() -> Void)? = nil) {
        DebugLog.write("refreshCapabilitiesThenApplyFormat() mode=\(settings.cameraMode) position=\(position)")
        ensureCorrectCameraDevice(for: settings.cameraMode)
        guard let device = cameraInput?.device else {
            DebugLog.write("❌ refreshCapabilitiesThenApplyFormat() no cameraInput.device after ensureCorrectCameraDevice")
            Task { @MainActor in completion?() }
            return
        }

        let targetDims = settings.cameraMode == .slowMo
            ? settings.slowMoResolution.captureDimensions
            : settings.resolution.captureDimensions
        let scan = scanCameraCapabilities(device: device, targetDimensions: targetDims)
        let snapshot = makeCapabilitySnapshot(device: device, scan: scan)
        let previousPosition = lastCapabilitiesCameraPosition
        lastCapabilitiesCameraPosition = device.position
        publishCapabilitySnapshot(snapshot,
                                  previousPosition: previousPosition,
                                  completion: completion)
    }

    private func scanCameraCapabilities(device: AVCaptureDevice,
                                        targetDimensions: (w: Int, h: Int)) -> CameraCapabilityScan {
        var scan = CameraCapabilityScan()

        for format in device.formats {
            let dims = CMVideoFormatDescriptionGetDimensions(format.formatDescription)
            let height = Int(dims.height)
            scan.widestPixels = max(scan.widestPixels, Int(dims.width) * height)

            let videoRates = supportedVideoRates(for: format)
            let meetsCurrentResolution = Int(dims.width) >= targetDimensions.w && height >= targetDimensions.h
            if meetsCurrentResolution {
                scan.rates.formUnion(videoRates)
            }
            for resolution in coveredVideoResolutions(height: height) {
                scan.ratesByResolution[resolution, default: []].formUnion(videoRates)
            }

            let slowRates = supportedSlowMotionRates(for: format)
            guard !slowRates.isEmpty else { continue }
            for resolution in coveredSlowMotionResolutions(height: height) {
                scan.slowResolutions.insert(resolution)
                scan.slowByResolution[resolution, default: []].formUnion(slowRates)
            }
        }

        if settings.cameraMode != .slowMo {
            mergeConstituentVideoCapabilities(device: device, into: &scan)
            if let constituentRates = scan.ratesByResolution[settings.resolution] {
                scan.rates.formUnion(constituentRates)
            }
        }
        return scan
    }

    private func supportedVideoRates(for format: AVCaptureDevice.Format) -> Set<FrameRate> {
        Set(FrameRate.allCases.filter { rate in
            let fps = Double(rate.value)
            return format.videoSupportedFrameRateRanges.contains {
                $0.minFrameRate <= fps + 0.5 && fps - 0.5 <= $0.maxFrameRate
            }
        })
    }

    private func supportedSlowMotionRates(for format: AVCaptureDevice.Format) -> Set<SlowMoFrameRate> {
        var rates = Set<SlowMoFrameRate>()
        for range in format.videoSupportedFrameRateRanges {
            if range.maxFrameRate >= 119.0 { rates.insert(.fps120) }
            if range.maxFrameRate >= 239.0 { rates.insert(.fps240) }
        }
        return rates
    }

    private func coveredVideoResolutions(height: Int) -> [Resolution] {
        var resolutions: [Resolution] = []
        if height >= 2160 { resolutions.append(.p2160) }
        if height >= 1080 { resolutions.append(.p1080) }
        if height >= 720 { resolutions.append(.p720) }
        if height >= 480 { resolutions.append(.p480) }
        resolutions.append(contentsOf: [.p320, .p144])
        return resolutions
    }

    private func coveredSlowMotionResolutions(height: Int) -> [Resolution] {
        var resolutions: [Resolution] = []
        if height >= 1080 { resolutions.append(.p1080) }
        if height >= 720 { resolutions.append(.p720) }
        if height >= 480 { resolutions.append(.p480) }
        resolutions.append(contentsOf: [.p320, .p144])
        return resolutions
    }

    private func mergeConstituentVideoCapabilities(device: AVCaptureDevice,
                                                    into scan: inout CameraCapabilityScan) {
        for constituent in device.constituentDevices {
            for format in constituent.formats {
                let dims = CMVideoFormatDescriptionGetDimensions(format.formatDescription)
                let rates = supportedVideoRates(for: format)
                for resolution in coveredVideoResolutions(height: Int(dims.height)) {
                    scan.ratesByResolution[resolution, default: []].formUnion(rates)
                }
            }
        }
    }

    private func makeCapabilitySnapshot(device: AVCaptureDevice,
                                        scan: CameraCapabilityScan) -> CameraCapabilitySnapshot {
        let supportedRates = FrameRate.allCases.filter { scan.rates.contains($0) }
        let canDo1080 = scan.widestPixels >= 1920 * 1080
        let canDo4K = scan.widestPixels >= 3840 * 2160
        let supportedResolutions = Resolution.allCases.filter { resolution in
            switch resolution {
            case .p2160: return canDo4K
            case .p1080: return canDo1080
            default: return true
            }
        }

        let supportedSlowResolutions = Resolution.allCases.filter {
            $0 != .p2160 && scan.slowResolutions.contains($0)
        }
        let selectedSlowRates = scan.slowByResolution[settings.slowMoResolution] ?? []
        let supportedSlowRates = SlowMoFrameRate.allCases.filter { selectedSlowRates.contains($0) }

        let maxStillPixels = device.formats.map { format in
            let dimensions = format.largestStillDimensions
            return Int(dimensions.width) * Int(dimensions.height)
        }.max() ?? 0
        let maxMegapixels = Double(maxStillPixels) / 1_000_000.0
        let supportedPhotoMP = PhotoMegapixels.allCases.filter {
            $0.megapixels <= maxMegapixels + 0.5
        }

        return CameraCapabilitySnapshot(
            frameRates: supportedRates.isEmpty ? [.fps30] : supportedRates,
            resolutions: supportedResolutions.isEmpty ? [.p720] : supportedResolutions,
            slowMoRates: supportedSlowRates,
            slowMoResolutions: supportedSlowResolutions.isEmpty ? [.p720] : supportedSlowResolutions,
            slowRatesByResolution: scan.slowByResolution,
            ratesByResolution: scan.ratesByResolution,
            slowMotionSupported: !scan.slowByResolution.isEmpty,
            photoMegapixels: supportedPhotoMP.isEmpty ? [.mp2] : supportedPhotoMP,
            isFrontCamera: device.position == .front
        )
    }

    private func publishCapabilitySnapshot(_ snapshot: CameraCapabilitySnapshot,
                                           previousPosition: AVCaptureDevice.Position?,
                                           completion: (() -> Void)?) {
        Task { @MainActor in
            self.activeSensorFPS = 0
            self.availableFrameRates = snapshot.frameRates
            self.availableResolutions = snapshot.resolutions
            self.availableSlowMoRates = snapshot.slowMoRates
            self.availableSlowMoResolutions = snapshot.slowMoResolutions
            self.slowRatesByResolution = snapshot.slowRatesByResolution
            self.frameRatesByResolution = snapshot.ratesByResolution
            self.isSlowMoSupportedOnCurrentLens = snapshot.slowMotionSupported
            self.availablePhotoMegapixels = snapshot.photoMegapixels

            self.applyVideoCapabilityFallbacks()
            self.applyPhotoCapabilityFallbacks(previousPosition: previousPosition,
                                               isFront: snapshot.isFrontCamera)
            self.applySlowMotionCapabilityFallbacks()
            self.applyCapabilitiesAndWaitForPreview(completion: completion)
        }
    }

    @MainActor
    private func applyVideoCapabilityFallbacks() {
        if !availableFrameRates.contains(settings.frameRate) {
            let fallback: FrameRate = availableFrameRates.contains(.fps30)
                ? .fps30 : (availableFrameRates.first ?? .fps30)
            settings.frameRate = fallback
        }
        if !availableResolutions.contains(settings.resolution) {
            settings.resolution = availableResolutions.first ?? .p720
        }
    }

    @MainActor
    private func applyPhotoCapabilityFallbacks(previousPosition: AVCaptureDevice.Position?,
                                               isFront: Bool) {
        if previousPosition == .back && isFront {
            rearPhotoMegapixelsBeforeFront = settings.photoMegapixels
        }
        if previousPosition == .front && !isFront,
           let saved = rearPhotoMegapixelsBeforeFront,
           availablePhotoMegapixels.contains(saved) {
            settings.photoMegapixels = saved
            rearPhotoMegapixelsBeforeFront = nil
        } else if !availablePhotoMegapixels.contains(settings.photoMegapixels) {
            settings.photoMegapixels = availablePhotoMegapixels.max {
                $0.megapixels < $1.megapixels
            } ?? .mp2
        }
    }

    @MainActor
    private func applySlowMotionCapabilityFallbacks() {
        guard settings.cameraMode == .slowMo else { return }
        guard isSlowMoSupportedOnCurrentLens else {
            notice = "Slow-Mo unavailable on front camera"
            settings.cameraMode = .video
            return
        }

        if !availableSlowMoResolutions.contains(settings.slowMoResolution) {
            settings.slowMoResolution = availableSlowMoResolutions.first ?? .p720
        }
        let scoped = slowRatesByResolution[settings.slowMoResolution] ?? []
        let scopedList = SlowMoFrameRate.allCases.filter { scoped.contains($0) }
        availableSlowMoRates = scopedList
        if !scopedList.contains(settings.slowMoFrameRate) {
            settings.slowMoFrameRate = scopedList.first ?? .fps120
        }
    }

    @MainActor
    private func applyCapabilitiesAndWaitForPreview(completion: (() -> Void)?) {
        sessionQueue.async {
            self.applyActiveFormat(forRecording: false)
            let finish: () -> Void = {
                self.waitForPreviewFrame(completion: completion)
            }
            if let appliedDevice = self.cameraInput?.device {
                self.waitForExposureSettled(device: appliedDevice, timeout: 0.25, completion: finish)
            } else {
                finish()
            }
        }
    }

}
