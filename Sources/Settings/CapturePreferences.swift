import SwiftUI
import UIKit

enum VideoCompression: String, CaseIterable, Identifiable {
    case dataSaver = "Data Saver", medium = "Medium", high = "High"
    var id: String { rawValue }
    var bitsPerPixel: Double {
        switch self { case .dataSaver: return 0.055; case .medium: return 0.10; case .high: return 0.18 }
    }
}

enum VideoQuickPreset: String, CaseIterable, Identifiable {
    case balanced = "Balanced", highQuality = "High Quality", allRounder = "All Rounder", allDay = "All Day", social = "Social"
    var id: String { rawValue }
    var resolution: VideoResolution { self == .highQuality ? .p4k : self == .allDay ? .p720 : .p1080 }
    var frameRate: VideoFrameRate { self == .allRounder ? .fps60 : .fps30 }
    var compression: VideoCompression {
        switch self { case .highQuality, .allRounder: return .high; case .allDay: return .dataSaver; default: return .medium }
    }
    var detail: String { "\(resolution.rawValue) · \(compression.rawValue) · \(frameRate.rawValue) fps · HEVC" }
}

enum CameraHaptics {
    static func fire() {
        let defaults = UserDefaults.standard
        guard defaults.object(forKey: "hapticCaptureEnabled") as? Bool ?? true else { return }
        let strength = defaults.string(forKey: "hapticStrength") ?? "Medium"
        let style: UIImpactFeedbackGenerator.FeedbackStyle = strength == "Low" ? .light : strength == "Strong" ? .heavy : .medium
        UIImpactFeedbackGenerator(style: style).impactOccurred()
    }
}

struct CameraAccent: DynamicProperty {
    @AppStorage("iconAppearance") private var preset = "Ice"
    @AppStorage("iconCustomRed") private var red = 0.55
    @AppStorage("iconCustomGreen") private var green = 0.85
    @AppStorage("iconCustomBlue") private var blue = 1.0
    var color: Color {
        switch preset {
        case "Sunset": return Color(red: 1, green: 0.58, blue: 0.3)
        case "Mint": return Color(red: 0.4, green: 0.95, blue: 0.7)
        case "Lavender": return Color(red: 0.77, green: 0.64, blue: 1)
        case "Custom": return Color(red: red, green: green, blue: blue)
        default: return Color(red: 0.65, green: 0.88, blue: 1)
        }
    }
}

struct CapturePreferencesView: View {
    @ObservedObject var camera: CameraManager
    @AppStorage("shutterDelay") private var shutterDelay = 0
    @AppStorage("splitMinutes") private var splitMinutes = 0
    @AppStorage("hapticCaptureEnabled") private var haptics = true
    @AppStorage("hapticStrength") private var strength = "Medium"
    @AppStorage("iconAppearance") private var appearance = "Ice"
    @AppStorage("iconCustomRed") private var red = 0.55
    @AppStorage("iconCustomGreen") private var green = 0.85
    @AppStorage("iconCustomBlue") private var blue = 1.0
    @AppStorage("centerCrosshair") private var crosshair = false
    @AppStorage("mirrorSelfies") private var mirrorSelfies = false
    private var accent = CameraAccent()

    var body: some View {
        Form {
            Section("Shutter") {
                Picker("Timer", selection: $shutterDelay) {
                    Text("Off").tag(0); Text("3 seconds").tag(3); Text("10 seconds").tag(10)
                }
            }
            if camera.captureMode != .photo {
                Section {
                    LabeledContent("Video Codec", value: "HEVC (H.265)")
                    Picker("Compression", selection: $camera.videoCompression) {
                        ForEach(VideoCompression.allCases) { Text($0.rawValue).tag($0) }
                    }
                    Picker("Split Recording", selection: $splitMinutes) {
                        Text("Off").tag(0); Text("Every 15 minutes").tag(15)
                        Text("Every 30 minutes").tag(30); Text("Every hour").tag(60)
                        Text("Every 2 hours").tag(120)
                    }
                } footer: {
                    Text("Each segment saves separately. Starting the next file introduces a brief gap. HEVC is used when supported; otherwise H.264 is used.")
                }
            }
            Section("Haptic Feedback") {
                Toggle("Enabled", isOn: $haptics)
                Picker("Strength", selection: $strength) {
                    ForEach(["Low", "Medium", "Strong"], id: \.self) { Text($0).tag($0) }
                }.disabled(!haptics)
                Button("Test Haptics") { CameraHaptics.fire() }.disabled(!haptics)
            }
            Section("Icon Appearance") {
                Picker("Color", selection: $appearance) {
                    ForEach(["Ice", "Sunset", "Mint", "Lavender", "Custom"], id: \.self) { Text($0).tag($0) }
                }
                if appearance == "Custom" {
                    ColorPicker("Custom Color", selection: Binding(get: { accent.color }, set: { color in
                        var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
                        UIColor(color).getRed(&r, green: &g, blue: &b, alpha: &a)
                        red = Double(r); green = Double(g); blue = Double(b)
                    }), supportsOpacity: false)
                }
            }
            Section("Extras") {
                Toggle("Center Crosshair", isOn: $crosshair)
                Toggle("Mirror Saved Selfies", isOn: $mirrorSelfies)
            }
        }
        .tint(accent.color)
        .navigationTitle("Capture & Appearance")
        .navigationBarTitleDisplayMode(.inline)
    }
}
