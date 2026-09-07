import Foundation
import SwiftUI

private struct CameraTintKey: EnvironmentKey {
    static let defaultValue = Color(red: 0.65, green: 0.88, blue: 1)
}

private struct CameraReadableTintKey: EnvironmentKey {
    static let defaultValue = Color(red: 0.16, green: 0.49, blue: 0.66)
}

extension EnvironmentValues {
    var cameraTint: Color {
        get { self[CameraTintKey.self] }
        set { self[CameraTintKey.self] = newValue }
    }

    var cameraReadableTint: Color {
        get { self[CameraReadableTintKey.self] }
        set { self[CameraReadableTintKey.self] = newValue }
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
        return relativeLuminance(rgb) > 0.46 ? .black : .white
    }

    /// Accent colors are also used as ink for navigation actions, summary text and chevrons.
    /// Pale themes such as Ice are intentionally beautiful fills, but are too low-contrast as
    /// foreground text on a light Settings surface. Keep the user's raw accent unchanged for
    /// fills and derive a WCAG-style readable text variant only when the accent is used as ink.
    static func readableTextColor(
        for preset: String,
        customRed: Double,
        customGreen: Double,
        customBlue: Double,
        colorScheme: ColorScheme
    ) -> Color {
        var rgb = components(
            for: preset,
            customRed: customRed,
            customGreen: customGreen,
            customBlue: customBlue
        )
        let backgroundLuminance = colorScheme == .dark ? 0.0 : 1.0

        // Preserve the chosen hue as much as possible. Darken toward black on light surfaces,
        // lighten toward white on dark surfaces, stopping as soon as normal-size text reaches
        // at least 4.5:1 contrast against the conservative black/white reference background.
        for _ in 0..<12 {
            let foregroundLuminance = relativeLuminance(rgb)
            if contrastRatio(foregroundLuminance, backgroundLuminance) >= 4.5 { break }
            if colorScheme == .dark {
                rgb = (
                    red: rgb.red + (1 - rgb.red) * 0.18,
                    green: rgb.green + (1 - rgb.green) * 0.18,
                    blue: rgb.blue + (1 - rgb.blue) * 0.18
                )
            } else {
                rgb = (
                    red: rgb.red * 0.82,
                    green: rgb.green * 0.82,
                    blue: rgb.blue * 0.82
                )
            }
        }
        return Color(red: rgb.red, green: rgb.green, blue: rgb.blue)
    }

    private static func clamp(_ value: Double) -> Double {
        guard value.isFinite else { return 0.5 }
        return min(max(value, 0), 1)
    }

    private static func relativeLuminance(_ rgb: (red: Double, green: Double, blue: Double)) -> Double {
        0.2126 * linearized(rgb.red) + 0.7152 * linearized(rgb.green) + 0.0722 * linearized(rgb.blue)
    }

    private static func contrastRatio(_ first: Double, _ second: Double) -> Double {
        let brighter = max(first, second)
        let darker = min(first, second)
        return (brighter + 0.05) / (darker + 0.05)
    }

    private static func linearized(_ value: Double) -> Double {
        value <= 0.04045 ? value / 12.92 : pow((value + 0.055) / 1.055, 2.4)
    }
}

struct CameraAccent: DynamicProperty {
    @Environment(\.colorScheme) private var colorScheme
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

    var readableTextColor: Color { readableTextColor(for: colorScheme) }

    func readableTextColor(for colorScheme: ColorScheme) -> Color {
        CameraThemePalette.readableTextColor(
            for: preset,
            customRed: red,
            customGreen: green,
            customBlue: blue,
            colorScheme: colorScheme
        )
    }
}
