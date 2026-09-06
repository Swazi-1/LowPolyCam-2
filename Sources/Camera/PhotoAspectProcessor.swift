import AVFoundation
import CoreImage
import CoreImage.CIFilterBuiltins
import ImageIO

struct ProcessedPhoto {
    let data: Data
    let dimensions: CMVideoDimensions
}

enum PhotoAspectProcessor {
    private static let context = CIContext(options: [.cacheIntermediates: false])

    /// Normalizes orientation, center-crops to the selected aspect ratio, and downsizes to the
    /// chosen MP target. It never upscales, so a camera that unexpectedly returns a smaller still
    /// produces the largest honest image it can instead of inventing pixels.
    static func process(
        _ data: Data,
        aspect: String,
        targetDimensions: CMVideoDimensions?
    ) -> ProcessedPhoto? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let type = CGImageSourceGetType(source),
              let input = CIImage(data: data, options: [.applyOrientationProperty: true]) else { return nil }

        let bounds = input.extent.integral
        guard bounds.width >= 2, bounds.height >= 2 else { return nil }
        let isPortrait = bounds.height > bounds.width
        let crop = centeredPixelAlignedCrop(in: bounds, aspect: aspect, portrait: isPortrait)
        let requested = orientedTarget(targetDimensions, portrait: isPortrait)

        // Keep a true Max 4:3 capture byte-for-byte when no crop or resize is necessary. This
        // avoids needless JPEG/HEIC recompression at the camera's highest quality.
        if abs(crop.width - bounds.width) < 0.5,
           abs(crop.height - bounds.height) < 0.5,
           let requested,
           abs(CGFloat(requested.width) - bounds.width) < 0.5,
           abs(CGFloat(requested.height) - bounds.height) < 0.5 {
            return ProcessedPhoto(
                data: data,
                dimensions: CMVideoDimensions(width: Int32(requested.width), height: Int32(requested.height))
            )
        }

        var cropped = input.cropped(to: crop)
        cropped = cropped.transformed(by: CGAffineTransform(translationX: -crop.minX, y: -crop.minY))

        let maximumWidth = max(Int(crop.width.rounded(.down)), 2)
        let maximumHeight = max(Int(crop.height.rounded(.down)), 2)
        var outputWidth = requested?.width ?? maximumWidth
        var outputHeight = requested?.height ?? maximumHeight

        // Keep the selected ratio exact while clamping to what the actual captured still contains.
        let clampScale = min(
            1.0,
            min(CGFloat(maximumWidth) / CGFloat(max(outputWidth, 1)),
                CGFloat(maximumHeight) / CGFloat(max(outputHeight, 1)))
        )
        outputWidth = max(2, Int((CGFloat(outputWidth) * clampScale).rounded(.down)))
        outputHeight = max(2, Int((CGFloat(outputHeight) * clampScale).rounded(.down)))

        // Recalculate one dimension from the chosen ratio after clamping/rounding. This prevents
        // tiny integer-rounding drift from producing a non-4:3 file.
        if aspect == "1:1" {
            let side = max(2, min(outputWidth, outputHeight))
            outputWidth = side
            outputHeight = side
        } else if isPortrait {
            let unit = max(1, min(outputWidth / 3, outputHeight / 4))
            outputWidth = unit * 3
            outputHeight = unit * 4
        } else {
            let unit = max(1, min(outputWidth / 4, outputHeight / 3))
            outputWidth = unit * 4
            outputHeight = unit * 3
        }

        let scale = min(
            CGFloat(outputWidth) / crop.width,
            CGFloat(outputHeight) / crop.height
        )
        let rendered: CIImage
        if scale < 0.9995 {
            let lanczos = CIFilter.lanczosScaleTransform()
            lanczos.inputImage = cropped
            lanczos.scale = Float(scale)
            lanczos.aspectRatio = 1
            guard let scaled = lanczos.outputImage else { return nil }
            rendered = scaled.cropped(to: CGRect(x: 0, y: 0, width: outputWidth, height: outputHeight))
        } else {
            rendered = cropped.cropped(to: CGRect(x: 0, y: 0, width: outputWidth, height: outputHeight))
        }

        let outputColorSpace = input.colorSpace ?? CGColorSpace(name: CGColorSpace.sRGB)
        guard let image = context.createCGImage(
            rendered,
            from: CGRect(x: 0, y: 0, width: outputWidth, height: outputHeight),
            format: .RGBA8,
            colorSpace: outputColorSpace
        ) else { return nil }

        var properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [String: Any] ?? [:]
        properties[kCGImagePropertyOrientation as String] = 1
        properties[kCGImagePropertyPixelWidth as String] = outputWidth
        properties[kCGImagePropertyPixelHeight as String] = outputHeight

        var tiff = properties[kCGImagePropertyTIFFDictionary as String] as? [String: Any] ?? [:]
        tiff[kCGImagePropertyTIFFOrientation as String] = 1
        properties[kCGImagePropertyTIFFDictionary as String] = tiff

        var exif = properties[kCGImagePropertyExifDictionary as String] as? [String: Any] ?? [:]
        exif[kCGImagePropertyExifPixelXDimension as String] = outputWidth
        exif[kCGImagePropertyExifPixelYDimension as String] = outputHeight
        properties[kCGImagePropertyExifDictionary as String] = exif
        properties[kCGImageDestinationLossyCompressionQuality as String] = 0.98

        let result = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(result, type, 1, nil) else { return nil }
        CGImageDestinationAddImage(destination, image, properties as CFDictionary)
        guard CGImageDestinationFinalize(destination) else { return nil }

        return ProcessedPhoto(
            data: result as Data,
            dimensions: CMVideoDimensions(width: Int32(outputWidth), height: Int32(outputHeight))
        )
    }

    /// Returns an integer-pixel crop with an exact 4:3, 3:4 or 1:1 ratio. A floating-point
    /// center crop can land on half-pixel coordinates when the source has an odd extra row/column,
    /// which introduces an unnecessary resample/soft edge before the real resize.
    private static func centeredPixelAlignedCrop(
        in bounds: CGRect,
        aspect: String,
        portrait: Bool
    ) -> CGRect {
        let width = max(Int(bounds.width.rounded(.down)), 2)
        let height = max(Int(bounds.height.rounded(.down)), 2)

        let cropWidth: Int
        let cropHeight: Int
        if aspect == "1:1" {
            let side = min(width, height)
            cropWidth = side
            cropHeight = side
        } else if portrait {
            let unit = max(1, min(width / 3, height / 4))
            cropWidth = unit * 3
            cropHeight = unit * 4
        } else {
            let unit = max(1, min(width / 4, height / 3))
            cropWidth = unit * 4
            cropHeight = unit * 3
        }

        let x = Int(bounds.minX.rounded(.down)) + max((width - cropWidth) / 2, 0)
        let y = Int(bounds.minY.rounded(.down)) + max((height - cropHeight) / 2, 0)
        return CGRect(x: x, y: y, width: cropWidth, height: cropHeight)
    }

    private static func orientedTarget(
        _ dimensions: CMVideoDimensions?,
        portrait: Bool
    ) -> (width: Int, height: Int)? {
        guard let dimensions, dimensions.width > 0, dimensions.height > 0 else { return nil }
        let landscapeWidth = Int(max(dimensions.width, dimensions.height))
        let landscapeHeight = Int(min(dimensions.width, dimensions.height))
        return portrait
            ? (landscapeHeight, landscapeWidth)
            : (landscapeWidth, landscapeHeight)
    }
}
