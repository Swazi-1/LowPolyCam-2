import Foundation
import SwiftUI

private struct CameraTintKey: EnvironmentKey {
    static let defaultValue = Color(red: 0.65, green: 0.88, blue: 1)
}

extension EnvironmentValues {
    var cameraTint: Color {
        get { self[CameraTintKey.self] }
        set { self[CameraTintKey.self] = newValue }
    }
}

enum CameraThemePalette {
    static func components(
        for preset: String,
        customRed: Double,
        customGreen: Double,
        customBlue: Double
    ) -> (red: Double, green: Double, blue: Double) {
        switch preset {
        case "Sunset": return (1, 0.58, 0.3)
        case "Mint": return (0.4, 0.95, 0.7)
        case "Lavender": return (0.77, 0.64, 1)
        case "Coral": return (1, 0.43, 0.48)
        case "Custom": return (clamp(customRed), clamp(customGreen), clamp(customBlue))
        default: return (0.65, 0.88, 1)
        }
    }

    static func color(
        for preset: String,
        customRed: Double,
        customGreen: Double,
        customBlue: Double
    ) -> Color {
        let rgb = components(
            for: preset,
            customRed: customRed,
            customGreen: customGreen,
            customBlue: customBlue
        )
        return Color(red: rgb.red, green: rgb.green, blue: rgb.blue)
    }

    static func foregroundColor(
        for preset: String,
        customRed: Double,
        customGreen: Double,
        customBlue: Double
    ) -> Color {
        let rgb = components(
            for: preset,
            customRed: customRed,
            customGreen: customGreen,
            customBlue: customBlue
        )
        let luminance = 0.2126 * linearized(rgb.red) + 0.7152 * linearized(rgb.green) + 0.0722 * linearized(rgb.blue)
        return luminance > 0.46 ? .black : .white
    }

    private static func clamp(_ value: Double) -> Double {
        guard value.isFinite else { return 0.5 }
        return min(max(value, 0), 1)
    }

    private static func linearized(_ value: Double) -> Double {
        value <= 0.04045 ? value / 12.92 : pow((value + 0.055) / 1.055, 2.4)
    }
}

struct CameraAccent: DynamicProperty {
    @AppStorage("iconAppearance") private var preset = "Ice"
    @AppStorage("iconCustomRed") private var red = 0.55
    @AppStorage("iconCustomGreen") private var green = 0.85
    @AppStorage("iconCustomBlue") private var blue = 1.0

    var color: Color {
        CameraThemePalette.color(
            for: preset,
            customRed: red,
            customGreen: green,
            customBlue: blue
        )
    }

    var foregroundColor: Color {
        CameraThemePalette.foregroundColor(
            for: preset,
            customRed: red,
            customGreen: green,
            customBlue: blue
        )
    }
}
