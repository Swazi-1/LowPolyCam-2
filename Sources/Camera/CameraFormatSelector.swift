import AVFoundation
import Foundation

struct CameraFormatSelector {
    typealias SlowMotionFrameRate = CameraManager.SlowMotionFrameRate

    let selectedVideoCodec: String
    let selectedResolution: VideoResolution
    let selectedFrameRate: VideoFrameRate

    func bestPhotoFormat(for device: AVCaptureDevice) -> (format: AVCaptureDevice.Format, dimensions: CMVideoDimensions)? {
        struct Candidate {
            let format: AVCaptureDevice.Format
            let photoDimensions: CMVideoDimensions
            let photoPixels: Int64
            let previewPixels: Int64
            let supports30FPS: Bool
        }

        var best: Candidate?
        for format in device.formats {
            guard let photoDimensions = format.supportedMaxPhotoDimensions.max(by: { lhs, rhs in
                Int64(lhs.width) * Int64(lhs.height) < Int64(rhs.width) * Int64(rhs.height)
            }) else { continue }

            let videoDimensions = CMVideoFormatDescriptionGetDimensions(format.formatDescription)
            let candidate = Candidate(
                format: format,
                photoDimensions: photoDimensions,
                photoPixels: Int64(photoDimensions.width) * Int64(photoDimensions.height),
                previewPixels: Int64(videoDimensions.width) * Int64(videoDimensions.height),
                supports30FPS: format.videoSupportedFrameRateRanges.contains { $0.minFrameRate <= 30 && $0.maxFrameRate >= 30 }
            )

            guard let current = best else {
                best = candidate
                continue
            }

            // Max still-photo resolution always wins. When still resolution ties, prefer
            // the sharpest live-preview format first so Photo mode never chooses a softer
            // preview just because another format happens to include 30 fps.
            if candidate.photoPixels > current.photoPixels ||
                (candidate.photoPixels == current.photoPixels && candidate.previewPixels > current.previewPixels) ||
                (candidate.photoPixels == current.photoPixels && candidate.previewPixels == current.previewPixels && candidate.supports30FPS && !current.supports30FPS) {
                best = candidate
            }
        }

        guard let best else { return nil }
        return (best.format, best.photoDimensions)
    }

    func photoResolutionLabel(for dimensions: CMVideoDimensions) -> String {
        let megapixels = Double(dimensions.width) * Double(dimensions.height) / 1_000_000.0
        let rounded = megapixels.rounded()
        if abs(megapixels - rounded) < 0.35 {
            return "\(Int(rounded)) MP"
        }
        return String(format: "%.1f MP", megapixels)
    }

    func availableResolutions(for devices: [AVCaptureDevice]) -> [VideoResolution] {
        VideoResolution.allCases.filter { resolution in
            devices.contains { device in
                device.formats.contains { self.format($0, supports: resolution) && self.formatSupportsSelectedCodec($0) }
            }
        }
    }

    func validSelection(
        for devices: [AVCaptureDevice],
        availableResolutions: [VideoResolution],
        requestedResolution: VideoResolution? = nil,
        requestedFrameRate: VideoFrameRate? = nil
    ) -> (resolution: VideoResolution, frameRate: VideoFrameRate, supportedFrameRates: [VideoFrameRate]) {
        let wantedResolution = requestedResolution ?? selectedResolution
        let wantedFrameRate = requestedFrameRate ?? selectedFrameRate
        let resolution = availableResolutions.contains(wantedResolution) ? wantedResolution : (availableResolutions.first ?? .p1080)
        let rates = frameRates(for: resolution, devices: devices)
        let frameRate = rates.contains(wantedFrameRate) ? wantedFrameRate : (rates.first ?? .fps30)
        return (resolution, frameRate, rates)
    }

    func preferredRecordingFormat(for device: AVCaptureDevice, resolution: VideoResolution, rate: VideoFrameRate) -> AVCaptureDevice.Format? {
        let formats = device.formats.filter { format($0, supports: resolution, at: rate) }
        if selectedVideoCodec == "H264" {
            // H.264 needs an 8-bit source; a 10-bit/HDR first match can expose HEVC only.
            return formats.first {
                let type = CMFormatDescriptionGetMediaSubType($0.formatDescription)
                return type == kCVPixelFormatType_420YpCbCr8BiPlanarFullRange || type == kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange
            } ?? formats.first
        }
        return formats.first
    }

    func slowMotionResolutions(for devices: [AVCaptureDevice]) -> [VideoResolution] {
        VideoResolution.allCases.filter { resolution in
            SlowMotionFrameRate.allCases.contains { rate in
                devices.contains { device in
                    device.formats.contains { supportsSlowMotion($0, resolution: resolution, frameRate: rate) }
                }
            }
        }
    }

    func slowMotionFrameRates(for devices: [AVCaptureDevice], resolution: VideoResolution) -> [SlowMotionFrameRate] {
        SlowMotionFrameRate.allCases.filter { rate in
            devices.contains { device in
                device.formats.contains { supportsSlowMotion($0, resolution: resolution, frameRate: rate) }
            }
        }
    }

    func supportsSlowMotion(
        _ candidate: AVCaptureDevice.Format,
        resolution: VideoResolution,
        frameRate: SlowMotionFrameRate
    ) -> Bool {
        let dimensions = CMVideoFormatDescriptionGetDimensions(candidate.formatDescription)
        guard dimensions.width == resolution.dimensions.width,
              dimensions.height == resolution.dimensions.height,
              formatSupportsSelectedCodec(candidate) else { return false }
        let fps = Double(frameRate.rawValue)
        return candidate.videoSupportedFrameRateRanges.contains {
            $0.minFrameRate <= fps + 0.5 && $0.maxFrameRate >= fps - 0.5
        }
    }

    func bestSlowMotionFormat(for device: AVCaptureDevice, resolution: VideoResolution, frameRate: SlowMotionFrameRate) -> AVCaptureDevice.Format? {
        let requestedFPS = Double(frameRate.rawValue)
        let candidates = device.formats.filter {
            supportsSlowMotion($0, resolution: resolution, frameRate: frameRate)
        }

        // Prefer the format whose supported range is closest to the requested HFR. This keeps
        // 120 fps on a 120-oriented format when one exists instead of needlessly selecting a
        // 240-oriented sensor mode.
        return candidates.min { lhs, rhs in
            let lhsMax = lhs.videoSupportedFrameRateRanges.map { $0.maxFrameRate }.max() ?? .greatestFiniteMagnitude
            let rhsMax = rhs.videoSupportedFrameRateRanges.map { $0.maxFrameRate }.max() ?? .greatestFiniteMagnitude
            let lhsDistance = abs(lhsMax - requestedFPS)
            let rhsDistance = abs(rhsMax - requestedFPS)
            if abs(lhsDistance - rhsDistance) > 0.01 { return lhsDistance < rhsDistance }
            let lhsPixels = CMVideoFormatDescriptionGetDimensions(lhs.formatDescription)
            let rhsPixels = CMVideoFormatDescriptionGetDimensions(rhs.formatDescription)
            return Int64(lhsPixels.width) * Int64(lhsPixels.height) > Int64(rhsPixels.width) * Int64(rhsPixels.height)
        }
    }

    func format(_ format: AVCaptureDevice.Format, supports resolution: VideoResolution, at frameRate: VideoFrameRate? = nil) -> Bool {
        let dimensions = CMVideoFormatDescriptionGetDimensions(format.formatDescription)
        guard dimensions.width == resolution.dimensions.width, dimensions.height == resolution.dimensions.height else { return false }
        guard let frameRate else { return true }
        return format.videoSupportedFrameRateRanges.contains {
            let requestedRate = Double(frameRate.rawValue)
            return $0.minFrameRate <= requestedRate + 0.5 && $0.maxFrameRate >= requestedRate - 0.5
        }
    }

    func frameRates(for resolution: VideoResolution, devices: [AVCaptureDevice]) -> [VideoFrameRate] {
        VideoFrameRate.allCases.filter { rate in
            devices.contains { device in
                device.formats.contains { format($0, supports: resolution, at: rate) && formatSupportsSelectedCodec($0) }
            }
        }
    }

    func formatSupportsSelectedCodec(_ format: AVCaptureDevice.Format) -> Bool {
        guard selectedVideoCodec == "H264" else { return true }
        let type = CMFormatDescriptionGetMediaSubType(format.formatDescription)
        return type == kCVPixelFormatType_420YpCbCr8BiPlanarFullRange ||
            type == kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange
    }
}
