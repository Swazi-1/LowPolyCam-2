import SwiftUI
import UIKit

struct AppearanceSettingsView: View {
    @AppStorage("iconAppearance") private var appearance = "Ice"
    @AppStorage("iconCustomRed") private var red = 0.55
    @AppStorage("iconCustomGreen") private var green = 0.85
    @AppStorage("iconCustomBlue") private var blue = 1.0
    @AppStorage("appColorScheme") private var appColorScheme = "dark"

    private let accentNames = CameraAccentPalette.names

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
        CameraAccentPalette.color(for: name, red: red, green: green, blue: blue)
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
    @State private var customPresets: [CameraPreset] = []
    @State private var newPresetName = ""
    @State private var showingSavePresetAlert = false
    @State private var renamePresetName = ""
    @State private var renamePresetID: UUID?
    @State private var showingRenamePresetAlert = false

    var body: some View {
        List {
            builtInPresetsSection
            customPresetsSection
            selectedPresetSection
        }
        .listStyle(.insetGrouped)
        .navigationTitle("Video Presets")
        .navigationBarTitleDisplayMode(.inline)
        .tint(.blue)
        .onAppear(perform: loadPresets)
        .alert("Save Current Setup", isPresented: $showingSavePresetAlert) {
            TextField("Preset name", text: $newPresetName)
            Button("Cancel", role: .cancel) {}
            Button("Save") { savePreset() }
        } message: {
            Text("Give this camera setup a name.")
        }
        .alert("Rename Preset", isPresented: $showingRenamePresetAlert) {
            TextField("Preset name", text: $renamePresetName)
            Button("Cancel", role: .cancel) { renamePresetID = nil }
            Button("Save") { renamePreset() }
        } message: {
            Text("The updated name is saved locally with the preset.")
        }
    }

    @ViewBuilder
    private var builtInPresetsSection: some View {
        Section("PRESETS") {
            ForEach(VideoQuickPreset.allCases) { preset in
                builtInPresetRow(preset)
            }
        }
    }

    private func builtInPresetRow(_ preset: VideoQuickPreset) -> some View {
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

    @ViewBuilder
    private var customPresetsSection: some View {
        Section {
            if customPresets.isEmpty {
                Text("Save the current camera setup to create a reusable preset.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            } else {
                ForEach(customPresets) { preset in
                    customPresetRow(preset)
                }
            }

            Button {
                newPresetName = ""
                showingSavePresetAlert = true
            } label: {
                Label("Save Current Setup", systemImage: "plus.circle.fill")
            }
        } header: {
            Text("CUSTOM PRESETS")
        } footer: {
            Text("Presets store capture mode, formats, codec, independent compression, bitrate, zoom, stabilization, white balance and camera position. Applying one uses a single coordinated camera configuration.")
        }
    }

    private func customPresetRow(_ preset: CameraPreset) -> some View {
        HStack(spacing: 12) {
            Button {
                applyCustomPreset(preset)
            } label: {
                HStack(spacing: 12) {
                    SettingsListIcon(symbol: "slider.horizontal.3", color: .purple)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(preset.name)
                            .foregroundStyle(.primary)
                        Text(presetSummary(preset))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(2)
                    }
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            Menu {
                Button("Apply") { applyCustomPreset(preset) }
                Button("Rename") {
                    renamePresetID = preset.id
                    renamePresetName = preset.name
                    showingRenamePresetAlert = true
                }
                Button("Delete", role: .destructive) { deletePreset(preset) }
            } label: {
                Image(systemName: "ellipsis.circle")
                    .font(.title3)
                    .foregroundStyle(.secondary)
                    .frame(width: 34, height: 34)
            }
            .accessibilityLabel("Actions for \(preset.name)")
        }
        .swipeActions(edge: .trailing, allowsFullSwipe: false) {
            Button(role: .destructive) { deletePreset(preset) } label: {
                Label("Delete", systemImage: "trash")
            }
        }
    }

    @ViewBuilder
    private var selectedPresetSection: some View {
        Section {
            selectedPresetSummary
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
            Text(selectedPresetFooter)
        }
    }

    private var selectedPresetSummary: some View {
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
    }

    private var selectedPresetFooter: String {
        camera.captureMode == .video
            ? "Applying a preset changes Video resolution, frame rate, codec and compression together."
            : "Switch Camera Setup to Video before applying a Video preset."
    }

    private func loadPresets() {
        customPresets = CameraPresetStore.load()
        preview = VideoQuickPreset.allCases.first {
            $0.resolution == camera.selectedResolution &&
            $0.frameRate == camera.selectedFrameRate &&
            $0.compression == camera.videoCompression &&
            camera.selectedVideoCodec == "HEVC"
        } ?? .balanced
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

    private func applyCustomPreset(_ preset: CameraPreset) {
        CameraHaptics.fire()
        camera.applyCameraPreset(preset) { success in
            guard success else { return }
            DispatchQueue.main.async { dismiss() }
        }
    }

    private func savePreset() {
        let name = newPresetName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { return }
        let preset = camera.makeCameraPreset(named: name)
        customPresets.append(preset)
        CameraPresetStore.save(customPresets)
        newPresetName = ""
    }

    private func renamePreset() {
        let name = renamePresetName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, let renamePresetID,
              let index = customPresets.firstIndex(where: { $0.id == renamePresetID }) else { return }
        customPresets[index].name = name
        CameraPresetStore.save(customPresets)
        self.renamePresetID = nil
        renamePresetName = ""
    }

    private func deletePreset(_ preset: CameraPreset) {
        customPresets.removeAll { $0.id == preset.id }
        CameraPresetStore.save(customPresets)
    }

    private func presetSummary(_ preset: CameraPreset) -> String {
        let mode: String
        let resolution: String
        let frameRate: Int
        let compressionMode: String
        let compressionLevel: String
        let manualBitrate: Double

        switch preset.captureMode {
        case "PHOTO":
            mode = "Photo"
            resolution = "Still"
            frameRate = 0
            compressionMode = ""
            compressionLevel = ""
            manualBitrate = 0
        case "SLO-MO":
            mode = "Slo-Mo"
            resolution = preset.slowMotionResolution
            frameRate = preset.slowMotionFrameRate
            compressionMode = preset.slowMotionCompressionMode
            compressionLevel = preset.slowMotionCompressionLevel
            manualBitrate = preset.slowMotionManualBitrateMbps
        default:
            mode = "Video"
            resolution = preset.videoResolution
            frameRate = preset.videoFrameRate
            compressionMode = preset.videoCompressionMode
            compressionLevel = preset.videoCompressionLevel
            manualBitrate = preset.videoManualBitrateMbps
        }

        let compression = compressionMode == CompressionMode.manual.rawValue
            ? "Manual \(String(format: "%.1f", manualBitrate)) Mbps"
            : "Auto \(compressionLevel)"
        return frameRate > 0 ? "\(mode) · \(resolution) · \(frameRate) fps · \(compression)" : "\(mode) · \(compression)"
    }
}
