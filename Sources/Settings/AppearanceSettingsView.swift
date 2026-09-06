import SwiftUI
import UIKit

struct AppearanceSettingsView: View {
    @AppStorage("iconAppearance") private var appearance = "Ice"
    @AppStorage("iconCustomRed") private var red = 0.55
    @AppStorage("iconCustomGreen") private var green = 0.85
    @AppStorage("iconCustomBlue") private var blue = 1.0
    private var accent = CameraAccent()
    private let names = ["Ice", "Sunset", "Mint", "Lavender", "Coral", "Custom"]

    var body: some View {
        SettingsPage {
            VStack(spacing: 16) {
                Image(systemName: "camera.aperture")
                    .font(.system(size: 46, weight: .light))
                    .foregroundStyle(accent.color)
                    .shadow(color: accent.color.opacity(0.45), radius: 18)
                Text(appearance.uppercased())
                    .font(.system(.headline, design: .rounded)).tracking(4)
                HStack(spacing: 20) {
                    ForEach(["bolt.fill", "viewfinder", "gearshape.fill"], id: \.self) { symbol in
                        Image(systemName: symbol).foregroundStyle(accent.color)
                            .frame(width: 46, height: 46)
                            .background(accent.color.opacity(0.14), in: Circle())
                    }
                }
                Text("Your camera, your color").font(.caption).foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity).padding(.vertical, 16)
            .background(LinearGradient(colors: [accent.color.opacity(0.22), Color(uiColor: .secondarySystemGroupedBackground)], startPoint: .topLeading, endPoint: .bottomTrailing), in: RoundedRectangle(cornerRadius: 22))
            SettingsCard(title: "Choose a Theme", symbol: "paintpalette.fill") {
                LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 10) {
                    ForEach(names, id: \.self) { name in
                        Button { appearance = name } label: {
                            VStack(alignment: .leading, spacing: 12) {
                                HStack(spacing: 5) {
                                    ForEach([1.0, 0.7, 0.4], id: \.self) { opacity in
                                        Circle().fill(color(for: name).opacity(opacity)).frame(width: 20, height: 20)
                                    }
                                    Spacer(minLength: 0)
                                    if appearance == name {
                                        Image(systemName: "checkmark.circle.fill").foregroundStyle(color(for: name))
                                    }
                                }
                                Text(name).font(.subheadline.weight(.semibold)).foregroundStyle(.primary)
                            }
                            .padding(12).frame(maxWidth: .infinity, alignment: .leading)
                            .background(color(for: name).opacity(appearance == name ? 0.18 : 0.06), in: RoundedRectangle(cornerRadius: 12))
                            .overlay(RoundedRectangle(cornerRadius: 12).stroke(color(for: name).opacity(appearance == name ? 0.8 : 0.12)).allowsHitTesting(false))
                            .contentShape(Rectangle())
                        }.buttonStyle(.plain)
                    }
                }
                if appearance == "Custom" {
                    ColorPicker("Custom Accent", selection: Binding(get: { accent.color }, set: { value in
                        var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
                        guard UIColor(value).getRed(&r, green: &g, blue: &b, alpha: &a) else { return }
                        let values = [Double(r), Double(g), Double(b)]
                        guard values.allSatisfy({ $0.isFinite }) else { return }
                        red = min(max(values[0], 0), 1)
                        green = min(max(values[1], 0), 1)
                        blue = min(max(values[2], 0), 1)
                    }), supportsOpacity: false)
                }
            }
        }
        .tint(accent.color).accentColor(accent.color)
        .navigationTitle("Appearance").navigationBarTitleDisplayMode(.inline)
    }

    private func color(for name: String) -> Color {
        CameraThemePalette.color(
            for: name,
            customRed: red,
            customGreen: green,
            customBlue: blue
        )
    }
}

struct VideoPresetsView: View {
    @ObservedObject var camera: CameraManager
    @Environment(\.cameraTint) private var theme
    private var accent = CameraAccent()
    @Environment(\.dismiss) private var dismiss
    @State private var preview: VideoQuickPreset = .balanced

    init(camera: CameraManager) {
        self.camera = camera
    }

    var body: some View {
        SettingsPage {
            VStack(spacing: 18) {
                Image(systemName: "video.fill")
                    .font(.system(size: 38, weight: .light))
                    .foregroundStyle(theme).shadow(color: theme.opacity(0.4), radius: 14)
                Text(preview.rawValue).font(.title3.weight(.bold))
                VStack(spacing: 7) {
                    HStack(spacing: 6) {
                        Circle().fill(.red).frame(width: 6, height: 6)
                        Text("REC  00:00:12").font(.system(.caption, design: .monospaced).weight(.bold))
                    }
                    HStack(spacing: 12) {
                        Label(preview.resolution.rawValue, systemImage: "viewfinder")
                        Label("\(preview.frameRate.rawValue) fps", systemImage: "speedometer")
                        Text("HEVC")
                    }.font(.caption2.weight(.semibold)).foregroundStyle(theme)
                }
                .padding(14)
                .background(.black.opacity(0.85), in: RoundedRectangle(cornerRadius: 18))
                .overlay(RoundedRectangle(cornerRadius: 18).stroke(theme.opacity(0.4)).allowsHitTesting(false))
                Text("HUD preview · example recording timer").font(.caption2).foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity).padding(.vertical, 22)
            .background(LinearGradient(colors: [theme.opacity(0.22), Color(uiColor: .secondarySystemGroupedBackground)], startPoint: .topLeading, endPoint: .bottomTrailing), in: RoundedRectangle(cornerRadius: 22))
            SettingsCard(title: "Choose a Preset", symbol: "wand.and.stars") {
                ForEach(VideoQuickPreset.allCases) { preset in
                    Button { preview = preset } label: {
                        HStack {
                            VStack(alignment: .leading, spacing: 5) {
                                Text(preset.rawValue).font(.subheadline.weight(.semibold)).foregroundStyle(.primary)
                                Text(preset.detail).font(.caption).foregroundStyle(.secondary)
                            }
                            Spacer()
                            Image(systemName: preview == preset ? "checkmark.circle.fill" : "circle")
                                .foregroundStyle(theme)
                        }
                        .padding(12)
                        .background(theme.opacity(preview == preset ? 0.16 : 0.04), in: RoundedRectangle(cornerRadius: 12))
                        .contentShape(Rectangle())
                    }.buttonStyle(.plain)
                }
                Button {
                    camera.applyQuickPreset(preview) { success in
                        if success { dismiss() }
                    }
                } label: {
                    Text("Use \(preview.rawValue)").font(.subheadline.weight(.bold))
                        .frame(maxWidth: .infinity).padding(.vertical, 13)
                        .background(theme, in: RoundedRectangle(cornerRadius: 12)).foregroundStyle(accent.foregroundColor)
                }.buttonStyle(.plain)
            }
        }
        .onAppear {
            preview = VideoQuickPreset.allCases.first {
                $0.resolution == camera.selectedResolution &&
                $0.frameRate == camera.selectedFrameRate &&
                $0.compression == camera.videoCompression &&
                camera.selectedVideoCodec == "HEVC"
            } ?? .balanced
        }
        .navigationTitle("Video Presets").navigationBarTitleDisplayMode(.inline)
    }
}
