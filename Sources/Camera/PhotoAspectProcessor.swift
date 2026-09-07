import ImageIO
import CoreImage

enum PhotoAspectProcessor {
    private static let context = CIContext(options: [.cacheIntermediates: false])

    static func square(_ data: Data) -> Data? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let type = CGImageSourceGetType(source),
              let input = CIImage(data: data, options: [.applyOrientationProperty: true]) else { return nil }
        let bounds = input.extent
        let side = min(bounds.width, bounds.height)
        let crop = CGRect(x: bounds.midX - side / 2, y: bounds.midY - side / 2, width: side, height: side)
        guard let image = context.createCGImage(input.cropped(to: crop), from: crop) else { return nil }
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
        guard let destination = CGImageDestinationCreateWithData(result, type, 1, nil) else { return nil }
        CGImageDestinationAddImage(destination, image, properties as CFDictionary)
        guard CGImageDestinationFinalize(destination) else { return nil }
        return result as Data
    }
}
