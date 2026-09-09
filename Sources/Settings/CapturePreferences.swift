import SwiftUI
import UIKit
import AVFoundation

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
        switch self {
        case .dataSaver: return 0.055
        case .medium: return 0.10
        case .high: return 0.18
        }
    }
}

enum VideoQuickPreset: String, CaseIterable, Identifiable {
    case balanced = "Balanced", highQuality = "High Quality", allRounder = "All Rounder", allDay = "All Day", social = "Social"
    var id: String { rawValue }
    var resolution: VideoResolution { self == .highQuality ? .p4k : self == .allDay ? .p720 : .p1080 }
    var frameRate: VideoFrameRate { self == .allRounder ? .fps60 : .fps30 }
    var compression: VideoCompression {
        switch self {
        case .highQuality, .allRounder: return .high
        case .allDay, .social: return .dataSaver
        case .balanced: return .medium
        }
    }
    var detail: String { "\(resolution.rawValue) · \(compression.rawValue) · \(frameRate.rawValue) fps · HEVC" }
}

enum CameraHaptics {
    private static let light = UIImpactFeedbackGenerator(style: .light)
    private static let medium = UIImpactFeedbackGenerator(style: .medium)
    private static let heavy = UIImpactFeedbackGenerator(style: .heavy)

    static func fire(strength selectedStrength: String? = nil, captureOnly: Bool = false) {
        let defaults = UserDefaults.standard
        if captureOnly, !(defaults.object(forKey: "hapticCaptureEnabled") as? Bool ?? true) { return }
        let strength = selectedStrength ?? defaults.string(forKey: "hapticStrength") ?? "Medium"
        try? AVAudioSession.sharedInstance().setAllowHapticsAndSystemSoundsDuringRecording(true)
        let generator = strength == "Low" ? light : strength == "Strong" ? heavy : medium
        generator.prepare()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.04) {
            generator.impactOccurred(intensity: strength == "Low" ? 0.45 : strength == "Strong" ? 1 : 0.7)
        }
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
        case "Coral": return Color(red: 1.0, green: 0.43, blue: 0.48)
        case "Custom": return Color(red: red, green: green, blue: blue)
        default: return Color(red: 0.65, green: 0.88, blue: 1)
        }
    }
}

struct CapturePreferencesView: View {
    @ObservedObject var camera: CameraManager
    @AppStorage("shutterDelay") private var shutterDelay = 0
    @AppStorage("zoomSpeed") private var zoomSpeed = 1.0
    @AppStorage("tapZoomReset") private var tapZoomReset = true
    @AppStorage("recordingLock") private var recordingLock = false
    @AppStorage("lowStorageWarning") private var lowStorageWarning = true
    @AppStorage("mirrorSelfies") private var mirrorSelfies = false
    @AppStorage("hapticCaptureEnabled") private var hapticCaptureEnabled = true
    @AppStorage("hapticStrength") private var hapticStrength = "Medium"
    @AppStorage("countdownHaptics") private var countdownHaptics = false
    @AppStorage("appColorScheme") private var appColorScheme = "system"

    var body: some View {
        List {
            Section("SHUTTER") {
                SettingsFixedOptionPicker(
                    title: "Timer",
                    selection: $shutterDelay,
                    options: [
                        SettingsPickerOption(value: 0, title: "Off"),
                        SettingsPickerOption(value: 3, title: "3 seconds"),
                        SettingsPickerOption(value: 10, title: "10 seconds")
                    ]
                )
            }

            Section("ZOOM") {
                SettingsFixedOptionPicker(
                    title: "Zoom Speed",
                    selection: $zoomSpeed,
                    options: [
                        SettingsPickerOption(value: 0.5, title: "Slow"),
                        SettingsPickerOption(value: 1.0, title: "Normal"),
                        SettingsPickerOption(value: 1.5, title: "Fast")
                    ]
                )
                Toggle("Tap Zoom to Reset", isOn: $tapZoomReset)
            }

            Section {
                Toggle("Lock Recording Controls", isOn: $recordingLock)
                Toggle("Low Storage Warning", isOn: $lowStorageWarning)
            } header: {
                Text("RECORDING SAFEGUARDS")
            } footer: {
                Text("The optional warning appears below 1 GB. Critical low-storage protection remains active even when the warning is off.")
            }

            Section("HAPTICS") {
                Toggle(isOn: $hapticCaptureEnabled) {
                    SettingsToggleLabel(
                        symbol: "waveform.path.ecg",
                        color: .orange,
                        title: "Haptic Capture",
                        subtitle: "Feel feedback when the shutter starts or stops."
                    )
                }

                SettingsFixedOptionPicker(
                    title: "Haptic Strength",
                    selection: $hapticStrength,
                    options: [
                        SettingsPickerOption(value: "Low", title: "Low"),
                        SettingsPickerOption(value: "Medium", title: "Medium"),
                        SettingsPickerOption(value: "Strong", title: "Strong")
                    ]
                )
                .disabled(!hapticCaptureEnabled)
                .onChange(of: hapticStrength) { _, newValue in
                    guard hapticCaptureEnabled else { return }
                    CameraHaptics.fire(strength: newValue)
                }

                Toggle(isOn: $countdownHaptics) {
                    SettingsToggleLabel(
                        symbol: "timer",
                        color: .orange,
                        title: "Countdown Haptics",
                        subtitle: "Add feedback during the photo timer countdown."
                    )
                }
            }

            Section("CAMERA") {
                Toggle("Mirror Saved Selfies", isOn: $mirrorSelfies)

                Button {
                    camera.setExposureBias(0)
                    camera.selectWhiteBalancePreset(.auto)
                } label: {
                    Label("Reset Exposure & White Balance", systemImage: "arrow.counterclockwise")
                }
            }
        }
        .listStyle(.insetGrouped)
        .navigationTitle("Preferences")
        .navigationBarTitleDisplayMode(.large)
        .tint(.blue)
        .preferredColorScheme(resolvedColorScheme(appColorScheme))
    }
}
