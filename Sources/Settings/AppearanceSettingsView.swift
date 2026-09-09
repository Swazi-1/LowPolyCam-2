import SwiftUI
import UIKit

struct AppearanceSettingsView: View {
    @AppStorage("iconAppearance") private var appearance = "Ice"
    @AppStorage("iconCustomRed") private var red = 0.55
    @AppStorage("iconCustomGreen") private var green = 0.85
    @AppStorage("iconCustomBlue") private var blue = 1.0
    @AppStorage("appColorScheme") private var appColorScheme = "dark"

    private let accentNames = ["Ice", "Sunset", "Mint", "Lavender", "Coral", "Custom"]

    var body: some View {
        List {
            Section {
                Picker("Appearance", selection: $appColorScheme) {
                    Text("System").tag("system")
                    Text("Light").tag("light")
                    Text("Dark").tag("dark")
                }
                .pickerStyle(.menu)
            } header: {
                Text("APP APPEARANCE")
            } footer: {
                Text("System follows your iPhone's current appearance.")
            }

            Section {
                Menu {
                    ForEach(accentNames, id: \.self) { name in
                        Button {
                            appearance = name
                        } label: {
                            HStack(spacing: 10) {
                                Circle()
                                    .fill(color(for: name))
                                    .frame(width: 14, height: 14)
                                    .overlay {
                                        Circle().stroke(.white.opacity(0.28), lineWidth: 0.5)
                                    }
                                Text(name)
                                if appearance == name {
                                    Image(systemName: "checkmark")
                                        .foregroundStyle(.blue)
                                }
                            }
                        }
                    }
                } label: {
                    HStack {
                        Text("Camera Accent")
                            .foregroundStyle(.primary)
                        Spacer()
                        Circle()
                            .fill(color(for: appearance))
                            .frame(width: 18, height: 18)
                        Text(appearance)
                            .foregroundStyle(.secondary)
                        Image(systemName: "chevron.up.chevron.down")
                            .font(.caption2.weight(.semibold))
                            .foregroundStyle(.tertiary)
                    }
                    .contentShape(Rectangle())
                }

                if appearance == "Custom" {
                    ColorPicker("Custom Accent", selection: customColorBinding, supportsOpacity: false)
                }
            } header: {
                Text("CAMERA ACCENT")
            } footer: {
                Text("Accent color changes LowPolyCam's camera controls. Settings itself stays system-styled for readability.")
            }

            Section("PREVIEW") {
                CameraAccentPreview(accent: color(for: appearance))
                    .listRowInsets(EdgeInsets(top: 10, leading: 12, bottom: 10, trailing: 12))
            }
        }
        .listStyle(.insetGrouped)
        .navigationTitle("Appearance")
        .navigationBarTitleDisplayMode(.large)
        .tint(.blue)
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

private struct CameraAccentPreview: View {
    let accent: Color

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 20, style: .continuous)
                .fill(Color.black)

            VStack {
                HStack(spacing: 18) {
                    Image(systemName: "bolt.fill")
                    Spacer()
                    Text("4K · 60")
                        .font(.caption.weight(.semibold))
                        .padding(.horizontal, 10)
                        .padding(.vertical, 5)
                        .background(.black.opacity(0.55), in: Capsule())
                        .overlay(Capsule().stroke(accent.opacity(0.75)))
                    Spacer()
                    Image(systemName: "gearshape.fill")
                }
                .foregroundStyle(accent)
                .padding(.horizontal, 18)
                .padding(.top, 14)

                Spacer()

                HStack(spacing: 26) {
                    Text("0.5×")
                        .font(.caption.bold())
                        .foregroundStyle(.white)
                    ZStack {
                        Circle().fill(.white).frame(width: 52, height: 52)
                        Circle().stroke(accent, lineWidth: 4).frame(width: 62, height: 62)
                    }
                    Image(systemName: "arrow.triangle.2.circlepath.camera.fill")
                        .foregroundStyle(accent)
                        .font(.title3)
                }
                .padding(.bottom, 16)
            }
        }
        .frame(height: 180)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Camera accent preview")
    }
}

struct VideoPresetsView: View {
    @ObservedObject var camera: CameraManager
    @Environment(\.dismiss) private var dismiss
    @State private var preview: VideoQuickPreset = .balanced

    var body: some View {
        List {
            Section("PRESETS") {
                ForEach(VideoQuickPreset.allCases) { preset in
                    Button {
                        preview = preset
                    } label: {
                        HStack(spacing: 12) {
                            Image(systemName: icon(for: preset))
                                .font(.system(size: 16, weight: .semibold))
                                .foregroundStyle(iconColor(for: preset))
                                .frame(width: 24)

                            VStack(alignment: .leading, spacing: 1) {
                                Text(preset.rawValue)
                                    .foregroundStyle(.primary)
                                Text(preset.detail)
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                                    .lineLimit(1)
                                    .minimumScaleFactor(0.78)
                            }

                            Spacer(minLength: 6)
                            if preview == preset {
                                Image(systemName: "checkmark")
                                    .font(.body.weight(.semibold))
                                    .foregroundStyle(.blue)
                            }
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
            }

            Section {
                HStack(spacing: 8) {
                    Text(preview.resolution.rawValue)
                    Text("·")
                    Text("\(preview.frameRate.rawValue) fps")
                    Text("·")
                    Text("HEVC")
                    Text("·")
                    Text(preview.compression.rawValue)
                }
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .minimumScaleFactor(0.72)

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
            } header: {
                Text("SELECTED PRESET")
            } footer: {
                Text(camera.captureMode == .video
                     ? "Applying a preset changes Video resolution, frame rate, codec and compression together."
                     : "Switch Camera Setup to Video before applying a Video preset.")
            }
        }
        .listStyle(.insetGrouped)
        .navigationTitle("Video Presets")
        .navigationBarTitleDisplayMode(.inline)
        .tint(.blue)
        .onAppear {
            preview = VideoQuickPreset.allCases.first {
                $0.resolution == camera.selectedResolution &&
                $0.frameRate == camera.selectedFrameRate &&
                $0.compression == camera.videoCompression &&
                camera.selectedVideoCodec == "HEVC"
            } ?? .balanced
        }
    }

    private func icon(for preset: VideoQuickPreset) -> String {
        switch preset {
        case .balanced: return "slider.horizontal.3"
        case .highQuality: return "sparkles"
        case .allRounder: return "square.grid.2x2.fill"
        case .allDay: return "battery.100percent"
        case .social: return "person.2.fill"
        }
    }

    private func iconColor(for preset: VideoQuickPreset) -> Color {
        switch preset {
        case .balanced: return .blue
        case .highQuality: return .purple
        case .allRounder: return .green
        case .allDay: return .orange
        case .social: return .pink
        }
    }
}
