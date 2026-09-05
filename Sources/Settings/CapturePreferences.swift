import SwiftUI
import UIKit

private struct CameraTintKey: EnvironmentKey {
    static let defaultValue = Color(red: 0.65, green: 0.88, blue: 1)
}
extension EnvironmentValues {
    var cameraTint: Color {
        get { self[CameraTintKey.self] }
        set { self[CameraTintKey.self] = newValue }
    }
}

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
    init(camera: CameraManager) { self.camera = camera }
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
    @AppStorage("zoomSpeed") private var zoomSpeed = 1.0
    @AppStorage("tapZoomReset") private var tapZoomReset = true
    @AppStorage("recordingLock") private var recordingLock = false
    @AppStorage("lowStorageWarning") private var lowStorageWarning = true
    @AppStorage("thermalHUD") private var thermalHUD = false

    var body: some View {
        Form {
            Section("Shutter") {
                ThemeMenu(title: "Timer", selection: $shutterDelay, options: [(0, "Off"), (3, "3 seconds"), (10, "10 seconds")])
            }
            if camera.captureMode != .photo {
                Section {
                    LabeledContent("Video Codec", value: "HEVC (H.265)")
                    ThemeMenu(title: "Compression", selection: $camera.videoCompression, options: VideoCompression.allCases.map { ($0, $0.rawValue) })
                    ThemeMenu(title: "Split Recording", selection: $splitMinutes, options: [(0, "Off"), (15, "Every 15 minutes"), (30, "Every 30 minutes"), (60, "Every hour"), (120, "Every 2 hours")])
                } footer: {
                    Text("Each segment saves separately. Starting the next file introduces a brief gap. HEVC is used when supported; otherwise H.264 is used.")
                }
            }
            Section("Haptic Feedback") {
                Toggle("Enabled", isOn: $haptics)
                ThemeMenu(title: "Strength", selection: $strength, options: ["Low", "Medium", "Strong"].map { ($0, $0) }).disabled(!haptics)
                Button("Test Haptics") { CameraHaptics.fire() }.disabled(!haptics)
            }
            Section("Zoom & Recording") {
                ThemeMenu(title: "Zoom Speed", selection: $zoomSpeed, options: [(0.5, "Slow"), (1.0, "Normal"), (1.5, "Fast")])
                Toggle("Tap Zoom to Reset to 1×", isOn: $tapZoomReset)
                Toggle("Lock Recording Controls", isOn: $recordingLock)
                Text("When locked, hold the shutter for one second to stop.")
                    .font(.caption).foregroundStyle(.secondary)
                Toggle("Low Storage Warning", isOn: $lowStorageWarning)
                Toggle("Thermal Status in HUD", isOn: $thermalHUD)
            }
            Section("Extras") {
                Toggle("Center Crosshair", isOn: $crosshair)
                Toggle("Mirror Saved Selfies", isOn: $mirrorSelfies)
            }
        }
        .tint(accent.color)
        .accentColor(accent.color)
        .navigationTitle("Capture Controls")
        .navigationBarTitleDisplayMode(.inline)
    }
}

struct ThemeMenu<Value: Hashable>: View {
    @Environment(\.cameraTint) private var theme
    let title: String
    @Binding var selection: Value
    let options: [(Value, String)]
    var body: some View {
        Menu {
            ForEach(options, id: \.0) { value, label in
                Button { selection = value } label: {
                    if selection == value { Label(label, systemImage: "checkmark") } else { Text(label) }
                }
            }
        } label: {
            HStack {
                Text(title).foregroundStyle(.primary)
                Spacer(minLength: 12)
                Text(options.first { $0.0 == selection }?.1 ?? "—")
                    .foregroundStyle(theme).multilineTextAlignment(.trailing)
                Image(systemName: "chevron.up.chevron.down").font(.caption).foregroundStyle(theme)
            }.frame(minHeight: 32).contentShape(Rectangle())
        }.tint(theme)
    }
}
