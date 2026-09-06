import AVFoundation
import CoreMedia
import CoreVideo

/// Pure AVFoundation format selection. The camera manager owns session mutations; this type owns
/// the rules for deciding which formats are legal/preferred for a requested quality.
enum CameraFormatSelector {
    static func format(
        _ format: AVCaptureDevice.Format,
        supports resolution: VideoResolution,
        frameRate: VideoFrameRate? = nil
    ) -> Bool {
        let dimensions = CMVideoFormatDescriptionGetDimensions(format.formatDescription)
        guard dimensions.width == resolution.dimensions.width,
              dimensions.height == resolution.dimensions.height else { return false }
        guard let frameRate else { return true }
        return supports(frameRate: Double(frameRate.rawValue), format: format)
    }

    static func supports(frameRate: Double, format: AVCaptureDevice.Format) -> Bool {
        format.videoSupportedFrameRateRanges.contains {
            $0.minFrameRate <= frameRate + 0.5 && $0.maxFrameRate >= frameRate - 0.5
        }
    }

    static func supports(codec: String, format: AVCaptureDevice.Format) -> Bool {
        guard codec == "H264" else { return true }
        let type = CMFormatDescriptionGetMediaSubType(format.formatDescription)
        return type == kCVPixelFormatType_420YpCbCr8BiPlanarFullRange ||
            type == kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange
    }

    static func availableResolutions(
        devices: [AVCaptureDevice],
        codec: String
    ) -> [VideoResolution] {
        VideoResolution.allCases.filter { resolution in
            devices.contains { device in
                device.formats.contains {
                    format($0, supports: resolution) && supports(codec: codec, format: $0)
                }
            }
        }
    }

    static func frameRates(
        for resolution: VideoResolution,
        devices: [AVCaptureDevice],
        codec: String
    ) -> [VideoFrameRate] {
        VideoFrameRate.allCases.filter { rate in
            devices.contains { device in
                device.formats.contains {
                    format($0, supports: resolution, frameRate: rate) && supports(codec: codec, format: $0)
                }
            }
        }
    }

    static func preferredRecordingFormat(
        for device: AVCaptureDevice,
        resolution: VideoResolution,
        frameRate: VideoFrameRate,
        codec: String
    ) -> AVCaptureDevice.Format? {
        let formats = device.formats.filter {
            format($0, supports: resolution, frameRate: frameRate)
        }
        if codec == "H264" {
            // An explicit H.264 request must resolve to a format that actually satisfies the
            // codec policy. Do not silently pick an unrelated fallback and advertise it as valid.
            return formats.first(where: { supports(codec: codec, format: $0) })
        }
        return formats.first
    }

    static func smoothPreviewFormat(
        for device: AVCaptureDevice,
        preferredFrameRate: VideoFrameRate
    ) -> AVCaptureDevice.Format? {
        let requestedRate = Double(preferredFrameRate.rawValue)
        for resolution in [VideoResolution.p1080, .p720] {
            if let candidate = device.formats.first(where: {
                format($0, supports: resolution, frameRate: preferredFrameRate)
            }) {
                return candidate
            }
        }
        return device.formats.first(where: { supports(frameRate: requestedRate, format: $0) })
    }

    static func slowMotionResolutions(
        devices: [AVCaptureDevice],
        codec: String
    ) -> [VideoResolution] {
        VideoResolution.allCases.filter { resolution in
            CameraManager.SlowMotionFrameRate.allCases.contains { rate in
                devices.contains {
                    bestSlowMotionFormat(
                        for: $0,
                        resolution: resolution,
                        frameRate: rate,
                        codec: codec
                    ) != nil
                }
            }
        }
    }

    static func slowMotionFrameRates(
        devices: [AVCaptureDevice],
        resolution: VideoResolution,
        codec: String
    ) -> [CameraManager.SlowMotionFrameRate] {
        CameraManager.SlowMotionFrameRate.allCases.filter { rate in
            devices.contains {
                bestSlowMotionFormat(
                    for: $0,
                    resolution: resolution,
                    frameRate: rate,
                    codec: codec
                ) != nil
            }
        }
    }

    static func bestSlowMotionFormat(
        for device: AVCaptureDevice,
        resolution: VideoResolution,
        frameRate: CameraManager.SlowMotionFrameRate,
        codec: String
    ) -> AVCaptureDevice.Format? {
        let requestedFPS = Double(frameRate.rawValue)
        let candidates = device.formats.filter { candidate in
            let dimensions = CMVideoFormatDescriptionGetDimensions(candidate.formatDescription)
            guard dimensions.width == resolution.dimensions.width,
                  dimensions.height == resolution.dimensions.height,
                  supports(codec: codec, format: candidate) else { return false }
            return supports(frameRate: requestedFPS, format: candidate)
        }

        // Prefer a sensor mode oriented around the requested HFR instead of needlessly choosing
        // a 240-fps-capable format for a 120-fps request when a closer one exists.
        return candidates.min { lhs, rhs in
            let lhsMax = lhs.videoSupportedFrameRateRanges.map { $0.maxFrameRate }.max() ?? .greatestFiniteMagnitude
            let rhsMax = rhs.videoSupportedFrameRateRanges.map { $0.maxFrameRate }.max() ?? .greatestFiniteMagnitude
            let lhsDistance = abs(lhsMax - requestedFPS)
            let rhsDistance = abs(rhsMax - requestedFPS)
            if abs(lhsDistance - rhsDistance) > 0.01 { return lhsDistance < rhsDistance }
            let lhsDimensions = CMVideoFormatDescriptionGetDimensions(lhs.formatDescription)
            let rhsDimensions = CMVideoFormatDescriptionGetDimensions(rhs.formatDescription)
            return Int64(lhsDimensions.width) * Int64(lhsDimensions.height) >
                Int64(rhsDimensions.width) * Int64(rhsDimensions.height)
        }
    }


    static func videoDevices(
        from devices: [AVCaptureDevice],
        resolution: VideoResolution,
        frameRate: VideoFrameRate,
        codec: String
    ) -> [AVCaptureDevice] {
        devices.filter {
            preferredRecordingFormat(for: $0, resolution: resolution, frameRate: frameRate, codec: codec) != nil
        }
    }

    static func slowMotionDevices(
        from devices: [AVCaptureDevice],
        resolution: VideoResolution,
        frameRate: CameraManager.SlowMotionFrameRate,
        codec: String
    ) -> [AVCaptureDevice] {
        devices.filter {
            bestSlowMotionFormat(for: $0, resolution: resolution, frameRate: frameRate, codec: codec) != nil
        }
    }

    static func activeFrameDurationsMatch(
        device: AVCaptureDevice,
        frameRate: Double,
        tolerance: Double
    ) -> Bool {
        let minSeconds = device.activeVideoMinFrameDuration.seconds
        let maxSeconds = device.activeVideoMaxFrameDuration.seconds
        guard minSeconds > 0, maxSeconds > 0 else { return false }
        let minFPS = 1 / minSeconds
        let maxFPS = 1 / maxSeconds
        return abs(minFPS - frameRate) < tolerance && abs(maxFPS - frameRate) < tolerance
    }

    static func activeVideoFormatMatches(
        device: AVCaptureDevice,
        resolution: VideoResolution,
        frameRate: VideoFrameRate,
        codec: String
    ) -> Bool {
        let active = device.activeFormat
        let dimensions = CMVideoFormatDescriptionGetDimensions(active.formatDescription)
        guard dimensions.width == resolution.dimensions.width,
              dimensions.height == resolution.dimensions.height,
              supports(codec: codec, format: active) else { return false }
        return activeFrameDurationsMatch(
            device: device,
            frameRate: Double(frameRate.rawValue),
            tolerance: 0.5
        )
    }

    static func activeSlowMotionFormatMatches(
        device: AVCaptureDevice,
        resolution: VideoResolution,
        frameRate: CameraManager.SlowMotionFrameRate,
        codec: String
    ) -> Bool {
        let active = device.activeFormat
        let dimensions = CMVideoFormatDescriptionGetDimensions(active.formatDescription)
        let requestedFPS = Double(frameRate.rawValue)
        guard dimensions.width == resolution.dimensions.width,
              dimensions.height == resolution.dimensions.height,
              supports(codec: codec, format: active),
              supports(frameRate: requestedFPS, format: active) else { return false }
        return activeFrameDurationsMatch(
            device: device,
            frameRate: requestedFPS,
            tolerance: 1
        )
    }
}
