import AVFoundation
import Foundation

/// Pure photo-size math. It has no capture-session state, so MP/aspect calculations can be tested
/// without involving CameraManager or AVCaptureSession reconfiguration.
enum PhotoResolutionCatalog {
    private static let presets: [(id: String, megapixels: Double)] = [
        ("48", 48), ("24", 24), ("12", 12), ("10", 10),
        ("8", 8), ("5", 5), ("3", 3), ("2", 2),
        ("1", 1), ("0.5", 0.5), ("0.3", 0.3)
    ]

    static func options(
        maximumCaptureDimensions: CMVideoDimensions,
        aspect: String
    ) -> [CameraManager.PhotoResolutionOption] {
        let maximumOutput = maximumOutputDimensions(from: maximumCaptureDimensions, aspect: aspect)
        let maximumPixels = pixelCount(maximumOutput)
        guard maximumPixels > 0 else { return [] }

        var result = [CameraManager.PhotoResolutionOption(id: "max", label: "Max", dimensions: maximumOutput)]
        let maximumMP = Double(maximumPixels) / 1_000_000.0

        for preset in presets {
            // Max already represents the highest useful output for the selected aspect. Avoid a
            // duplicate preset such as Max (12.2 MP) + 12 MP.
            if abs(maximumMP - preset.megapixels) < 0.30 { continue }
            guard preset.megapixels < maximumMP else { continue }
            let dimensions = targetDimensions(
                megapixels: preset.megapixels,
                aspect: aspect,
                maximum: maximumOutput
            )
            guard dimensions.width > 0, dimensions.height > 0 else { continue }
            let actualMP = Double(pixelCount(dimensions)) / 1_000_000.0
            guard actualMP <= maximumMP + 0.001 else { continue }
            result.append(CameraManager.PhotoResolutionOption(
                id: "mp-\(preset.id)",
                label: formattedMegapixelValue(preset.megapixels) + " MP",
                dimensions: dimensions
            ))
        }
        return result
    }

    static func migratedID(
        fromLegacyID legacyID: String,
        options: [CameraManager.PhotoResolutionOption]
    ) -> String? {
        let payload = legacyID.dropFirst("photo-".count)
        let pieces = payload.split(separator: "x")
        guard pieces.count == 2,
              let width = Double(pieces[0]),
              let height = Double(pieces[1]),
              width > 0, height > 0 else { return nil }
        let legacyMP = width * height / 1_000_000.0
        let candidates = options.filter { $0.id != "max" }
        guard let closest = candidates.min(by: {
            abs(Double(pixelCount($0.dimensions)) / 1_000_000.0 - legacyMP) <
            abs(Double(pixelCount($1.dimensions)) / 1_000_000.0 - legacyMP)
        }) else { return "max" }
        let closestMP = Double(pixelCount(closest.dimensions)) / 1_000_000.0
        return abs(closestMP - legacyMP) <= 0.45 ? closest.id : "max"
    }

    static func replacementForRemovedPreset(
        _ requestedID: String,
        options: [CameraManager.PhotoResolutionOption]
    ) -> String? {
        switch requestedID {
        case "mp-11": return options.contains(where: { $0.id == "mp-10" }) ? "mp-10" : nil
        case "mp-1.6": return options.contains(where: { $0.id == "mp-2" }) ? "mp-2" : nil
        default: return nil
        }
    }

    static func pixelCount(_ dimensions: CMVideoDimensions) -> Int64 {
        Int64(dimensions.width) * Int64(dimensions.height)
    }

    static func label(for dimensions: CMVideoDimensions) -> String {
        let megapixels = Double(dimensions.width) * Double(dimensions.height) / 1_000_000.0
        let rounded = megapixels.rounded()
        // Preserve useful fractional labels at the low end. Max 12.2 MP still presents as 12 MP.
        if megapixels >= 10, abs(megapixels - rounded) < 0.30 {
            return "\(Int(rounded)) MP"
        }
        if megapixels >= 0.9, abs(megapixels - rounded) < 0.08 {
            return "\(Int(rounded)) MP"
        }
        return String(format: "%.1f MP", megapixels)
    }

    private static func maximumOutputDimensions(from source: CMVideoDimensions, aspect: String) -> CMVideoDimensions {
        let width = Int(max(source.width, source.height))
        let height = Int(min(source.width, source.height))
        guard width > 0, height > 0 else { return CMVideoDimensions(width: 0, height: 0) }

        if aspect == "1:1" {
            let side = max(2, min(width, height))
            return CMVideoDimensions(width: Int32(side), height: Int32(side))
        }

        // Exact 4:3 output: 4*k by 3*k prevents aspect drift at lower resolutions.
        var unit = min(width / 4, height / 3)
        unit = max(unit, 2)
        return CMVideoDimensions(width: Int32(unit * 4), height: Int32(unit * 3))
    }

    private static func targetDimensions(
        megapixels: Double,
        aspect: String,
        maximum: CMVideoDimensions
    ) -> CMVideoDimensions {
        let targetPixels = max(megapixels, 0.01) * 1_000_000.0

        if aspect == "1:1" {
            var side = Int(sqrt(targetPixels).rounded())
            side = min(side, Int(min(maximum.width, maximum.height)))
            side = max(side, 2)
            return CMVideoDimensions(width: Int32(side), height: Int32(side))
        }

        // 4*k × 3*k = 12*k² pixels: nearest integer k preserves exact 4:3 while staying close
        // to the requested megapixel label.
        var unit = Int(sqrt(targetPixels / 12.0).rounded())
        let maximumUnit = min(Int(maximum.width) / 4, Int(maximum.height) / 3)
        unit = min(max(unit, 2), maximumUnit)
        return CMVideoDimensions(width: Int32(unit * 4), height: Int32(unit * 3))
    }

    private static func formattedMegapixelValue(_ megapixels: Double) -> String {
        let rounded = megapixels.rounded()
        if abs(megapixels - rounded) < 0.001 { return "\(Int(rounded))" }
        return String(format: "%.1f", megapixels)
    }
}
