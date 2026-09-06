import Foundation

/// Pure storage math used by the HUD. Keeping estimates outside CameraManager avoids mixing
/// display calculations with AVCaptureSession lifecycle code.
enum CaptureStorageEstimator {
    private static let reservedBytes: Int64 = 500 * 1_024 * 1_024

    static func photoRemainingLabel(availableBytes: Int64, pixelCount: Int64, fileFormat: String) -> String {
        let usable = usableBytes(from: availableBytes)
        guard usable > 0 else { return "~0" }

        let pixels = max(Double(pixelCount), 1)
        let estimatedBytes: Double
        if fileFormat == "HEIC" {
            estimatedBytes = 80_000 + pixels * 0.22
        } else {
            estimatedBytes = 140_000 + pixels * 0.42
        }

        guard estimatedBytes > 0 else { return "—" }
        let count = Int64(Double(usable) / estimatedBytes)
        return count >= 10_000 ? "~10k+" : "~\(max(count, 0))"
    }

    static func videoRemainingLabel(
        availableBytes: Int64,
        resolution: VideoResolution,
        frameRate: Double,
        compression: VideoCompression,
        codec: String
    ) -> String {
        let usable = usableBytes(from: availableBytes)
        guard usable > 0 else { return "~0m" }

        let bitsPerSecond = videoBitsPerSecond(
            resolution: resolution,
            frameRate: frameRate,
            compression: compression,
            codec: codec
        )
        guard bitsPerSecond > 0 else { return "—" }

        let seconds = Int(Double(usable) * 8.0 / bitsPerSecond)
        if seconds >= 3_600 {
            return String(format: "~%dh%02dm", seconds / 3_600, (seconds % 3_600) / 60)
        }
        return "~\(max(seconds / 60, 0))m"
    }


    static func videoBitsPerSecond(
        resolution: VideoResolution,
        frameRate: Double,
        compression: VideoCompression,
        codec: String
    ) -> Double {
        let pixels = Double(resolution.dimensions.width) * Double(resolution.dimensions.height)
        let codecFactor = codec == "H264" ? 1.0 : 0.72
        return max(pixels * frameRate * compression.bitsPerPixel * codecFactor, 2_000_000)
    }

    private static func usableBytes(from availableBytes: Int64) -> Int64 {
        max(availableBytes - reservedBytes, 0)
    }
}
