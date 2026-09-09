import SwiftUI
import UIKit

struct AppearanceSettingsView: View {
    @AppStorage("iconAppearance") private var appearance = "Ice"
    @AppStorage("iconCustomRed") private var red = 0.55
    @AppStorage("iconCustomGreen") private var green = 0.85
    @AppStorage("iconCustomBlue") private var blue = 1.0
    @AppStorage("appColorScheme") private var appColorScheme = "system"

    private let accentNames = ["Ice", "Sunset", "Mint", "Lavender", "Coral", "Custom"]

    var body: some View {
        List {
            Section("APP APPEARANCE") {
                appearanceRow("system", title: "System")
                appearanceRow("light", title: "Light")
                appearanceRow("dark", title: "Dark")
            } footer: {
                Text("System follows your iPhone's current appearance.")
            }

            Section("CAMERA ACCENT") {
                ForEach(accentNames, id: \.self) { name in
                    Button {
                        appearance = name
                    } label: {
                        HStack(spacing: 12) {
                            Circle()
                                .fill(color(for: name))
                                .frame(width: 26, height: 26)
                            Text(name)
                                .foregroundStyle(.primary)
                            Spacer()
                            if appearance == name {
                                Image(systemName: "checkmark")
                                    .font(.body.weight(.semibold))
                                    .foregroundStyle(.blue)
                            }
                        }
                        .contentShape(Rectangle())
                    }
                }

                if appearance == "Custom" {
                    ColorPicker("Custom Accent", selection: customColorBinding, supportsOpacity: false)
                }
            } footer: {
                Text("Accent color changes LowPolyCam's camera controls. Settings itself stays system-styled for readability.")
            }
        }
        .listStyle(.insetGrouped)
        .navigationTitle("Appearance")
        .navigationBarTitleDisplayMode(.large)
        .tint(.blue)
        .preferredColorScheme(resolvedColorScheme(appColorScheme))
    }

    @ViewBuilder
    private func appearanceRow(_ value: String, title: String) -> some View {
        Button {
            appColorScheme = value
        } label: {
            SettingsCheckmarkRow(title: title, selected: appColorScheme == value)
        }
    }

    private var customColorBinding: Binding<Color> {
        Binding(
            get: { Color(red: red, green: green, blue: blue) },
            set: { value in
                var r: CGFloat = 0
                var g: CGFloat = 0
                var b: CGFloat = 0
                var a: CGFloat = 0
                UIColor(value).getRed(&r, green: &g, blue: &b, alpha: &a)
                red = Double(r)
                green = Double(g)
                blue = Double(b)
            }
        )
    }

    private func color(for name: String) -> Color {
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

struct VideoPresetsView: View {
    @ObservedObject var camera: CameraManager
    @Environment(\.dismiss) private var dismiss
    @AppStorage("appColorScheme") private var appColorScheme = "system"
    @State private var preview: VideoQuickPreset = .balanced

    var body: some View {
        List {
            Section("PRESETS") {
                ForEach(VideoQuickPreset.allCases) { preset in
                    Button {
                        preview = preset
                    } label: {
                        SettingsCheckmarkRow(
                            title: preset.rawValue,
                            subtitle: preset.detail,
                            selected: preview == preset
                        )
                    }
                }
            }

            Section("SELECTED PRESET") {
                HStack {
                    Text("Resolution")
                    Spacer()
                    Text(preview.resolution.rawValue).foregroundStyle(.secondary)
                }
                HStack {
                    Text("Frame Rate")
                    Spacer()
                    Text("\(preview.frameRate.rawValue) fps").foregroundStyle(.secondary)
                }
                HStack {
                    Text("Codec")
                    Spacer()
                    Text("HEVC").foregroundStyle(.secondary)
                }
                HStack {
                    Text("Compression")
                    Spacer()
                    Text(preview.compression.rawValue).foregroundStyle(.secondary)
                }
            }

            Section {
                Button {
                    camera.applyQuickPreset(preview) { success in
                        if success { dismiss() }
                    }
                } label: {
                    HStack {
                        Spacer()
                        Text("Use \(preview.rawValue)")
                            .fontWeight(.semibold)
                        Spacer()
                    }
                }
                .disabled(camera.captureMode != .video || camera.isPreviewTransitioning || camera.isLensTransitioning)
            } footer: {
                Text(camera.captureMode == .video
                     ? "Applying a preset changes Video resolution, frame rate, codec and compression together."
                     : "Switch Camera Setup to Video before applying a Video preset.")
            }
        }
        .listStyle(.insetGrouped)
        .navigationTitle("Video Presets")
        .navigationBarTitleDisplayMode(.large)
        .tint(.blue)
        .preferredColorScheme(resolvedColorScheme(appColorScheme))
        .onAppear {
            preview = VideoQuickPreset.allCases.first {
                $0.resolution == camera.selectedResolution &&
                $0.frameRate == camera.selectedFrameRate &&
                $0.compression == camera.videoCompression &&
                camera.selectedVideoCodec == "HEVC"
            } ?? .balanced
        }
    }
}
