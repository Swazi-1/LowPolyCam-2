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

enum CameraAccentPalette {
    static let names = ["Ice", "Sunset", "Mint", "Lavender", "Coral", "Custom"]

    static func color(for name: String, red: Double = 0.55, green: Double = 0.85, blue: Double = 1.0) -> Color {
        switch name {
        case "Sunset": return Color(red: 1, green: 0.58, blue: 0.3)
        case "Mint": return Color(red: 0.4, green: 0.95, blue: 0.7)
        case "Lavender": return Color(red: 0.77, green: 0.64, blue: 1)
        case "Coral": return Color(red: 1.0, green: 0.43, blue: 0.48)
        case "Custom": return Color(red: red, green: green, blue: blue)
        default: return Color(red: 0.65, green: 0.88, blue: 1)
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

    private static var isEnabled: Bool {
        let stored = UserDefaults.standard.object(forKey: "hapticCaptureEnabled")
        return (stored as? Bool) ?? true
    }

    /// Master entry point for every app-generated haptic. Keeping the preference check here
    /// guarantees controls, capture, countdown, and future haptics all respect the same switch.
    static func fire(strength selectedStrength: String? = nil) {
        let defaults = UserDefaults.standard
        let strength = selectedStrength ?? defaults.string(forKey: "hapticStrength") ?? "Medium"
        guard isEnabled else {
            AppEventLog.deepEvent("HAPTIC SUPPRESSED", category: .ui, fields: [
                "reason": "master disabled",
                "strength": strength
            ])
            return
        }
        AppEventLog.deepEvent("HAPTIC REQUEST", category: .ui, fields: ["strength": strength])
        try? AVAudioSession.sharedInstance().setAllowHapticsAndSystemSoundsDuringRecording(true)
        let generator = strength == "Low" ? light : strength == "Strong" ? heavy : medium
        generator.prepare()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.04) {
            // The user can disable haptics while this short prepared-feedback delay is pending.
            guard isEnabled else {
                AppEventLog.deepEvent("HAPTIC SUPPRESSED", category: .ui, fields: [
                    "reason": "master disabled during delay",
                    "strength": strength
                ])
                return
            }
            generator.impactOccurred(intensity: strength == "Low" ? 0.45 : strength == "Strong" ? 1 : 0.7)
            AppEventLog.deepEvent("HAPTIC FIRED", category: .ui, fields: ["strength": strength])
        }
    }
}

struct CameraAccent: DynamicProperty {
    @AppStorage("iconAppearance") private var preset = "Ice"
    @AppStorage("iconCustomRed") private var red = 0.55
    @AppStorage("iconCustomGreen") private var green = 0.85
    @AppStorage("iconCustomBlue") private var blue = 1.0

    var color: Color { CameraAccentPalette.color(for: preset, red: red, green: green, blue: blue) }
}

struct CapturePreferencesView: View {
    @ObservedObject var camera: CameraManager
    @AppStorage("shutterDelay") private var shutterDelay = 0
    @AppStorage("zoomSpeed") private var zoomSpeed = 1.0
    @AppStorage("tapZoomReset") private var tapZoomReset = true
    @AppStorage("focusExposureLockMode") private var focusExposureLockMode = "AE/AF"
    @AppStorage("tapFocusResetSeconds") private var tapFocusResetSeconds = 1
    @AppStorage("recordingLock") private var recordingLock = false
    @AppStorage("lowStorageWarning") private var lowStorageWarning = true
    @AppStorage("mirrorSelfies") private var mirrorSelfies = false
    @AppStorage("hapticCaptureEnabled") private var hapticCaptureEnabled = true
    @AppStorage("hapticStrength") private var hapticStrength = "Medium"
    @AppStorage("countdownHaptics") private var countdownHaptics = false

    var body: some View {
        List {
            Section("SHUTTER") {
                Picker("Timer", selection: $shutterDelay) {
                    Text("Off").tag(0)
                    Text("3 seconds").tag(3)
                    Text("10 seconds").tag(10)
                }
                .pickerStyle(.menu)
            }

            Section("ZOOM") {
                Picker("Zoom Speed", selection: $zoomSpeed) {
                    Text("Slow").tag(0.5)
                    Text("Normal").tag(1.0)
                    Text("Fast").tag(1.5)
                }
                .pickerStyle(.menu)
                HapticFreeSettingsToggle(isOn: $tapZoomReset) {
                    Text("Tap Zoom to Reset")
                }
            }

            Section {
                Picker("Lock Mode", selection: $focusExposureLockMode) {
                    Text("AE/AF").tag("AE/AF")
                    Text("AE Only").tag("AE Only")
                    Text("AF Only").tag("AF Only")
                }
                .pickerStyle(.menu)

                Picker("Tap Focus Reset", selection: $tapFocusResetSeconds) {
                    Text("1 second").tag(1)
                    Text("3 seconds").tag(3)
                    Text("5 seconds").tag(5)
                    Text("Never").tag(0)
                }
                .pickerStyle(.menu)
            } header: {
                Text("FOCUS & EXPOSURE")
            } footer: {
                Text("Long-press the preview to lock the selected controls. Lenses without adjustable focus automatically fall back to AE lock when AE/AF is selected.")
            }

            Section {
                HapticFreeSettingsToggle(isOn: $recordingLock) {
                    Text("Lock Recording Controls")
                }
                HapticFreeSettingsToggle(isOn: $lowStorageWarning) {
                    Text("Low Storage Warning")
                }
            } header: {
                Text("RECORDING SAFEGUARDS")
            } footer: {
                Text("The optional warning appears below 1 GB. Critical low-storage protection remains active even when the warning is off.")
            }

            Section("WHITE BALANCE") {
                Picker("White Balance", selection: whiteBalanceBinding) {
                    ForEach(CameraManager.WhiteBalancePreset.allCases) { preset in
                        Text(preset.rawValue).tag(preset)
                    }
                }
                .pickerStyle(.menu)

                if camera.whiteBalancePreset == .custom {
                    VStack(alignment: .leading, spacing: 8) {
                        HStack {
                            Text("Temperature")
                            Spacer()
                            Text(String(format: "%.0f K", camera.customWhiteBalanceTemperature))
                                .foregroundStyle(.secondary)
                                .monospacedDigit()
                        }
                        Slider(
                            value: Binding(
                                get: { camera.customWhiteBalanceTemperature },
                                set: {
                                    camera.setCustomWhiteBalance(
                                        temperature: $0,
                                        tint: camera.customWhiteBalanceTint,
                                        isFinal: false
                                    )
                                }
                            ),
                            in: WhiteBalancePreferencePolicy.minimumTemperature...WhiteBalancePreferencePolicy.maximumTemperature,
                            step: 50
                        )
                        .onEditingChanged { editing in
                            if editing {
                                camera.beginCustomWhiteBalanceInteraction()
                            } else {
                                camera.endCustomWhiteBalanceInteraction()
                            }
                        }

                        HStack {
                            Text("Tint")
                            Spacer()
                            Text(String(format: "%+.0f", camera.customWhiteBalanceTint))
                                .foregroundStyle(.secondary)
                                .monospacedDigit()
                        }
                        Slider(
                            value: Binding(
                                get: { camera.customWhiteBalanceTint },
                                set: {
                                    camera.setCustomWhiteBalance(
                                        temperature: camera.customWhiteBalanceTemperature,
                                        tint: $0,
                                        isFinal: false
                                    )
                                }
                            ),
                            in: WhiteBalancePreferencePolicy.minimumTint...WhiteBalancePreferencePolicy.maximumTint,
                            step: 1
                        )
                        .onEditingChanged { editing in
                            if editing {
                                camera.beginCustomWhiteBalanceInteraction()
                            } else {
                                camera.endCustomWhiteBalanceInteraction()
                            }
                        }

                        Button {
                            CameraHaptics.fire()
                            camera.setCustomWhiteBalance(
                                temperature: WhiteBalancePreferencePolicy.defaultTemperature,
                                tint: 0
                            )
                        } label: {
                            Label("Reset Custom WB", systemImage: "arrow.counterclockwise")
                        }
                    }
                }
            } footer: {
                Text("Custom White Balance uses 2,500–10,000 K and tint from −150 to +150. Reset returns to 5,200 K and 0 tint without switching to Auto.")
            }

            Section("TORCH") {
                HStack {
                    Label("Torch Brightness", systemImage: "bolt.fill")
                    Spacer()
                    Text(String(format: "%.0f%%", camera.torchBrightnessLevel * 100))
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                }
                Slider(
                    value: Binding(
                        get: { camera.torchBrightnessLevel },
                        set: { camera.setTorchBrightness($0, isFinal: false) }
                    ),
                    in: TorchLevelPolicy.minimumNormalizedLevel...TorchLevelPolicy.maximumNormalizedLevel,
                    step: 0.01
                )
                .disabled(!camera.torchAvailable || !camera.torchBrightnessSupported)
                .onEditingChanged { editing in
                    if editing {
                        camera.beginTorchBrightnessInteraction()
                    } else {
                        camera.endTorchBrightnessInteraction()
                    }
                }
                if !camera.torchAvailable {
                    Text("Torch unavailable for the current camera or configuration.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            } footer: {
                Text("Brightness is a normalized 5–100% request. The active camera may apply a lower thermal maximum or fall back to its supported torch level.")
            }

            Section("HAPTICS") {
                HapticFreeSettingsToggle(isOn: $hapticCaptureEnabled) {
                    SettingsToggleLabel(
                        symbol: "waveform.path.ecg",
                        color: .orange,
                        title: "Haptics",
                        subtitle: "Enable haptic feedback throughout LowPolyCam."
                    )
                }

                Picker("Haptic Strength", selection: $hapticStrength) {
                    Text("Low").tag("Low")
                    Text("Medium").tag("Medium")
                    Text("Strong").tag("Strong")
                }
                .pickerStyle(.menu)
                .disabled(!hapticCaptureEnabled)
                .onChange(of: hapticStrength) { _, newValue in
                    guard hapticCaptureEnabled else { return }
                    CameraHaptics.fire(strength: newValue)
                }

                HapticFreeSettingsToggle(isOn: $countdownHaptics) {
                    SettingsToggleLabel(
                        symbol: "timer",
                        color: .orange,
                        title: "Countdown Haptics",
                        subtitle: "Add feedback during the photo timer countdown."
                    )
                }
                .disabled(!hapticCaptureEnabled)
            }

            Section("CAMERA") {
                HapticFreeSettingsToggle(isOn: $mirrorSelfies) {
                    Text("Mirror Saved Selfies")
                }

                Button {
                    camera.setExposureBias(0)
                    camera.setCustomWhiteBalance(
                        temperature: WhiteBalancePreferencePolicy.defaultTemperature,
                        tint: 0
                    )
                } label: {
                    Label("Reset Exposure & White Balance", systemImage: "arrow.counterclockwise")
                }
            }
        }
        .listStyle(.insetGrouped)
        .navigationTitle("Preferences")
        .navigationBarTitleDisplayMode(.large)
        .tint(.blue)
    }

    private var whiteBalanceBinding: Binding<CameraManager.WhiteBalancePreset> {
        Binding(
            get: { camera.whiteBalancePreset },
            set: { camera.selectWhiteBalancePreset($0) }
        )
    }
}
