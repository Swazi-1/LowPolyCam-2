import SwiftUI
import UIKit

struct AppearanceSettingsView: View {
    @AppStorage("iconAppearance") private var appearance = "Ice"
    @AppStorage("iconCustomRed") private var red = 0.55
    @AppStorage("iconCustomGreen") private var green = 0.85
    @AppStorage("iconCustomBlue") private var blue = 1.0
    private var accent = CameraAccent()

    var body: some View {
        Form {
            Section("App Theme") {
                ForEach(["Ice", "Sunset", "Mint", "Lavender", "Custom"], id: \.self) { name in
                    Button { appearance = name } label: {
                        HStack {
                            Text(name).foregroundStyle(.primary)
                            Spacer()
                            if appearance == name { Image(systemName: "checkmark.circle.fill").foregroundStyle(accent.color) }
                        }.frame(minHeight: 44).contentShape(Rectangle())
                    }.buttonStyle(.plain)
                }
                if appearance == "Custom" {
                    ColorPicker("Accent Color", selection: Binding(get: { accent.color }, set: { value in
                        var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
                        UIColor(value).getRed(&r, green: &g, blue: &b, alpha: &a)
                        red = Double(r); green = Double(g); blue = Double(b)
                    }), supportsOpacity: false)
                }
            }
            Section("Preview") {
                Label("Camera • Settings • HUD", systemImage: "camera.fill").foregroundStyle(accent.color)
                Text("Accents follow your theme. Recording stays red; body text stays readable.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .tint(accent.color)
        .accentColor(accent.color)
        .navigationTitle("Appearance")
        .navigationBarTitleDisplayMode(.inline)
    }
}

struct VideoPresetsView: View {
    @ObservedObject var camera: CameraManager
    @Environment(\.cameraTint) private var theme
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        List(VideoQuickPreset.allCases) { preset in
            Button {
                camera.applyQuickPreset(preset)
                dismiss()
            } label: {
                HStack {
                    VStack(alignment: .leading, spacing: 5) {
                        Text(preset.rawValue).foregroundStyle(.primary)
                        Text(preset.detail).font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                    Image(systemName: "arrow.down.circle.fill").foregroundStyle(theme)
                }.padding(.vertical, 5)
            }
        }
        .tint(theme)
        .navigationTitle("Video Presets")
        .navigationBarTitleDisplayMode(.inline)
    }
}
