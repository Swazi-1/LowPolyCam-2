import CoreImage
import Foundation
import ImageIO

// Keeps photo sizing in one place so aspect-ratio cropping and MP resizing cannot drift apart.
enum PhotoAspectProcessor {
    private static let context = CIContext(options: [.cacheIntermediates: false])

    static func process(_ data: Data, aspect: String, megapixels: Int, traceID: String? = nil) -> Data? {
        let startedAt = ProcessInfo.processInfo.systemUptime
        let trace = traceID ?? (AppEventLog.extremeDiagnosticsEnabled ? AppEventLog.makeTraceID("PHOTO-PROCESS") : nil)
        AppEventLog.deepEvent("PHOTO PROCESSING BEGIN", category: .photo, traceID: trace, fields: [
            "inputBytes": String(data.count),
            "aspect": aspect,
            "requestedMP": String(megapixels)
        ])

        guard let source = CGImageSourceCreateWithData(data as CFData, nil) else {
            AppEventLog.event("PHOTO PROCESSING FAILED", category: .photo, level: .error, traceID: trace,
                              fields: ["stage": "CGImageSourceCreateWithData"])
            return nil
        }
        guard let type = CGImageSourceGetType(source) else {
            AppEventLog.event("PHOTO PROCESSING FAILED", category: .photo, level: .error, traceID: trace,
                              fields: ["stage": "CGImageSourceGetType"])
            return nil
        }
        guard let input = CIImage(data: data, options: [.applyOrientationProperty: true]) else {
            AppEventLog.event("PHOTO PROCESSING FAILED", category: .photo, level: .error, traceID: trace,
                              fields: ["stage": "CIImage decode"])
            return nil
        }

        let crop = cropRect(for: input.extent, aspect: aspect)
        guard crop.width >= 1, crop.height >= 1 else {
            AppEventLog.event("PHOTO PROCESSING FAILED", category: .photo, level: .error, traceID: trace,
                              fields: ["stage": "crop", "crop": String(describing: crop)])
            return nil
        }

        let sourceWidth = Int(crop.width.rounded(.down))
        let sourceHeight = Int(crop.height.rounded(.down))
        let target = targetDimensions(
            sourceWidth: sourceWidth,
            sourceHeight: sourceHeight,
            aspect: aspect,
            megapixels: megapixels
        )
        guard target.width > 0, target.height > 0 else {
            AppEventLog.event("PHOTO PROCESSING FAILED", category: .photo, level: .error, traceID: trace,
                              fields: ["stage": "target dimensions"])
            return nil
        }

        AppEventLog.deepEvent("PHOTO PROCESSING GEOMETRY", category: .photo, traceID: trace, fields: [
            "decodedExtent": "\(Int(input.extent.width))x\(Int(input.extent.height))",
            "crop": "x=\(Int(crop.minX)),y=\(Int(crop.minY)),w=\(sourceWidth),h=\(sourceHeight)",
            "target": "\(target.width)x\(target.height)",
            "targetMP": String(format: "%.2f", Double(target.width * target.height) / 1_000_000)
        ])

        let cropIsFullFrame = abs(crop.width - input.extent.width) < 0.5 &&
            abs(crop.height - input.extent.height) < 0.5
        if cropIsFullFrame, target.width == sourceWidth, target.height == sourceHeight {
            AppEventLog.deepEvent("PHOTO PROCESSING PASSTHROUGH", category: .photo, traceID: trace, fields: [
                "outputBytes": String(data.count),
                "durationMs": String(format: "%.2f", (ProcessInfo.processInfo.systemUptime - startedAt) * 1000)
            ])
            return data
        }

        let normalized = input
            .cropped(to: crop)
            .transformed(by: CGAffineTransform(translationX: -crop.minX, y: -crop.minY))

        let scale = min(
            CGFloat(target.width) / max(normalized.extent.width, 1),
            CGFloat(target.height) / max(normalized.extent.height, 1),
            1
        )
        let resized: CIImage
        if scale < 0.9999 {
            resized = normalized.applyingFilter(
                "CILanczosScaleTransform",
                parameters: [kCIInputScaleKey: scale, kCIInputAspectRatioKey: 1.0]
            )
        } else {
            resized = normalized
        }

        let outputRect = CGRect(x: 0, y: 0, width: CGFloat(target.width), height: CGFloat(target.height))
        guard let image = context.createCGImage(resized, from: outputRect) else {
            AppEventLog.event("PHOTO PROCESSING FAILED", category: .photo, level: .error, traceID: trace,
                              fields: ["stage": "CIContext.createCGImage"])
            return nil
        }

        var properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [String: Any] ?? [:]
        properties[kCGImagePropertyOrientation as String] = 1
        var tiff = properties[kCGImagePropertyTIFFDictionary as String] as? [String: Any] ?? [:]
        tiff[kCGImagePropertyTIFFOrientation as String] = 1
        properties[kCGImagePropertyTIFFDictionary as String] = tiff
        properties[kCGImagePropertyPixelWidth as String] = image.width
        properties[kCGImagePropertyPixelHeight as String] = image.height
        var exif = properties[kCGImagePropertyExifDictionary as String] as? [String: Any] ?? [:]
        exif[kCGImagePropertyExifPixelXDimension as String] = image.width
        exif[kCGImagePropertyExifPixelYDimension as String] = image.height
        properties[kCGImagePropertyExifDictionary as String] = exif
        properties[kCGImageDestinationLossyCompressionQuality as String] = 0.98

        let result = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(result, type, 1, nil) else {
            AppEventLog.event("PHOTO PROCESSING FAILED", category: .photo, level: .error, traceID: trace,
                              fields: ["stage": "CGImageDestinationCreateWithData"])
            return nil
        }
        CGImageDestinationAddImage(destination, image, properties as CFDictionary)
        guard CGImageDestinationFinalize(destination) else {
            AppEventLog.event("PHOTO PROCESSING FAILED", category: .photo, level: .error, traceID: trace,
                              fields: ["stage": "CGImageDestinationFinalize"])
            return nil
        }
        let output = result as Data
        AppEventLog.deepEvent("PHOTO PROCESSING COMPLETE", category: .photo, traceID: trace, fields: [
            "outputBytes": String(output.count),
            "outputDimensions": "\(image.width)x\(image.height)",
            "outputMP": String(format: "%.2f", Double(image.width * image.height) / 1_000_000),
            "scale": String(format: "%.4f", Double(scale)),
            "durationMs": String(format: "%.2f", (ProcessInfo.processInfo.systemUptime - startedAt) * 1000)
        ])
        return output
    }

    private static func cropRect(for bounds: CGRect, aspect: String) -> CGRect {
        let targetRatio: CGFloat = aspect == "1:1" ? 1 : (bounds.width >= bounds.height ? (4.0 / 3.0) : (3.0 / 4.0))
        let currentRatio = bounds.width / max(bounds.height, 1)
        if currentRatio > targetRatio {
            let width = bounds.height * targetRatio
            return CGRect(x: bounds.midX - width / 2, y: bounds.minY, width: width, height: bounds.height)
        }
        let height = bounds.width / targetRatio
        return CGRect(x: bounds.minX, y: bounds.midY - height / 2, width: bounds.width, height: height)
    }

    private static func targetDimensions(sourceWidth: Int, sourceHeight: Int, aspect: String, megapixels: Int) -> (width: Int, height: Int) {
        let requestedMegapixels = max(megapixels, 1)
        let sourcePixels = max(sourceWidth, 0) * max(sourceHeight, 0)
        let sourceMegapixels = Double(sourcePixels) / 1_000_000.0
        if abs(sourceMegapixels - Double(requestedMegapixels)) < 0.35 { return (sourceWidth, sourceHeight) }
        let requestedPixels = requestedMegapixels * 1_000_000
        if aspect == "1:1" {
            let requestedSide = Int(Double(requestedPixels).squareRoot().rounded(.down))
            let side = min(requestedSide, sourceWidth, sourceHeight)
            return (side, side)
        }
        let landscape = sourceWidth >= sourceHeight
        let requestedUnit = Int((Double(requestedPixels) / 12.0).squareRoot().rounded(.down))
        let sourceUnit = landscape ? min(sourceWidth / 4, sourceHeight / 3) : min(sourceWidth / 3, sourceHeight / 4)
        let unit = min(requestedUnit, sourceUnit)
        guard unit > 0 else { return (sourceWidth, sourceHeight) }
        return landscape ? (4 * unit, 3 * unit) : (3 * unit, 4 * unit)
    }
}
