import AVFoundation
import CoreMedia
import Foundation
import ImageIO

struct MediaValidationResult {
    let mediaType: String
    let isValid: Bool
    let summary: String
    let fields: [String: String]
}

enum MediaValidator {
    static func validateVideo(at url: URL) -> MediaValidationResult {
        let fileSize = (try? url.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? 0
        guard FileManager.default.fileExists(atPath: url.path), fileSize > 0 else {
            return MediaValidationResult(
                mediaType: "video",
                isValid: false,
                summary: "recording file is missing or empty",
                fields: ["file": url.lastPathComponent, "fileBytes": String(fileSize)]
            )
        }

        let asset = AVURLAsset(url: url)
        guard let track = asset.tracks(withMediaType: .video).first else {
            return MediaValidationResult(
                mediaType: "video",
                isValid: false,
                summary: "recording has no video track",
                fields: ["file": url.lastPathComponent, "fileBytes": String(fileSize)]
            )
        }

        let duration = asset.duration.seconds
        guard duration.isFinite, duration > 0 else {
            return MediaValidationResult(
                mediaType: "video",
                isValid: false,
                summary: "recording duration is invalid",
                fields: ["file": url.lastPathComponent, "duration": String(duration)]
            )
        }

        // AVAssetTrack exposes format descriptions as Any, but each video description is
        // guaranteed to be a CMFormatDescription. A conditional cast triggers Swift 6's
        // "always succeeds" diagnostic for this CoreFoundation type.
        let formatDescription = track.formatDescriptions.first.map { $0 as! CMFormatDescription }
        let dimensions = formatDescription.map(CMVideoFormatDescriptionGetDimensions)
        guard let dimensions, dimensions.width > 0, dimensions.height > 0 else {
            return MediaValidationResult(
                mediaType: "video",
                isValid: false,
                summary: "recording video dimensions are invalid",
                fields: ["file": url.lastPathComponent, "duration": String(format: "%.3f", duration)]
            )
        }

        let codec = formatDescription.map(codecName) ?? "unknown"
        let audioPresent = !asset.tracks(withMediaType: .audio).isEmpty
        let fields: [String: String] = [
            "file": url.lastPathComponent,
            "fileBytes": String(fileSize),
            "duration": String(format: "%.3f", duration),
            "codec": codec,
            "dimensions": "\(dimensions.width)x\(dimensions.height)",
            "nominalFPS": String(format: "%.3f", track.nominalFrameRate),
            "audioPresent": String(audioPresent),
            "transform": transformString(track.preferredTransform)
        ]
        return MediaValidationResult(
            mediaType: "video",
            isValid: true,
            summary: "readable video track with duration and dimensions",
            fields: fields
        )
    }

    static func validatePhoto(
        data: Data,
        expectedAspect: String,
        requestedMegapixels: Int
    ) -> MediaValidationResult {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let type = CGImageSourceGetType(source),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [String: Any],
              let width = (properties[kCGImagePropertyPixelWidth as String] as? NSNumber)?.intValue,
              let height = (properties[kCGImagePropertyPixelHeight as String] as? NSNumber)?.intValue,
              width > 0,
              height > 0 else {
            return MediaValidationResult(
                mediaType: "photo",
                isValid: false,
                summary: "photo data or dimensions are unreadable",
                fields: ["bytes": String(data.count)]
            )
        }

        let ratio = Double(width) / Double(height)
        let targetRatio = expectedAspect == "1:1"
            ? 1.0
            : (width >= height ? 4.0 / 3.0 : 3.0 / 4.0)
        let aspectMatches = abs(ratio - targetRatio) <= 0.02
        let megapixels = Double(width * height) / 1_000_000
        let targetMatches = requestedMegapixels <= 0 || megapixels <= Double(requestedMegapixels) + 0.75
        let orientation = (properties[kCGImagePropertyOrientation as String] as? NSNumber)?.intValue ?? 1
        let fields: [String: String] = [
            "bytes": String(data.count),
            "type": String(describing: type),
            "dimensions": "\(width)x\(height)",
            "megapixels": String(format: "%.2f", megapixels),
            "expectedAspect": expectedAspect,
            "aspectMatches": String(aspectMatches),
            "targetMatches": String(targetMatches),
            "orientation": String(orientation)
        ]
        return MediaValidationResult(
            mediaType: "photo",
            isValid: aspectMatches && targetMatches,
            summary: aspectMatches && targetMatches
                ? "readable photo with expected aspect and target size"
                : "photo does not match expected aspect or target size",
            fields: fields
        )
    }

    static func validatePhotoFile(at url: URL) -> MediaValidationResult {
        guard let data = try? Data(contentsOf: url), !data.isEmpty else {
            return MediaValidationResult(
                mediaType: "photo",
                isValid: false,
                summary: "photo file is missing or empty",
                fields: ["file": url.lastPathComponent]
            )
        }
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let type = CGImageSourceGetType(source),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [String: Any],
              let width = (properties[kCGImagePropertyPixelWidth as String] as? NSNumber)?.intValue,
              let height = (properties[kCGImagePropertyPixelHeight as String] as? NSNumber)?.intValue,
              width > 0,
              height > 0 else {
            return MediaValidationResult(
                mediaType: "photo",
                isValid: false,
                summary: "photo file data or dimensions are unreadable",
                fields: ["file": url.lastPathComponent, "bytes": String(data.count)]
            )
        }
        let megapixels = Double(width * height) / 1_000_000
        return MediaValidationResult(
            mediaType: "photo",
            isValid: true,
            summary: "readable photo file",
            fields: [
                "file": url.lastPathComponent,
                "bytes": String(data.count),
                "type": String(describing: type),
                "dimensions": "\(width)x\(height)",
                "megapixels": String(format: "%.2f", megapixels)
            ]
        )
    }

    private static func codecName(_ description: CMFormatDescription) -> String {
        switch CMFormatDescriptionGetMediaSubType(description) {
        case kCMVideoCodecType_H264:
            return "H264"
        case kCMVideoCodecType_HEVC:
            return "HEVC"
        default:
            return fourCharacterCode(CMFormatDescriptionGetMediaSubType(description))
        }
    }

    private static func fourCharacterCode(_ code: FourCharCode) -> String {
        let bytes: [UInt8] = [
            UInt8((code >> 24) & 0xff),
            UInt8((code >> 16) & 0xff),
            UInt8((code >> 8) & 0xff),
            UInt8(code & 0xff)
        ]
        return String(bytes: bytes, encoding: .ascii) ?? String(code)
    }

    private static func transformString(_ transform: CGAffineTransform) -> String {
        String(format: "%.2f,%.2f,%.2f,%.2f,%.2f,%.2f", transform.a, transform.b, transform.c, transform.d, transform.tx, transform.ty)
    }
}
