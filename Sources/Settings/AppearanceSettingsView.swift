import SwiftUI
import UIKit

struct AppearanceSettingsView: View {
  @AppStorage("iconAppearance") private var appearance = "Ice"
  @AppStorage("iconCustomRed") private var red = 0.55
  @AppStorage("iconCustomGreen") private var green = 0.85
  @AppStorage("iconCustomBlue") private var blue = 1.0
  @Environment(\.cameraTint) private var theme
  @Environment(\.cameraReadableTint) private var readableTheme
  @Environment(\.colorScheme) private var colorScheme
  private var accent = CameraAccent()
  private let names = ["Ice", "Sunset", "Mint", "Lavender", "Coral", "Custom"]

  init() {}

  var body: some View {
    SettingsPage {
      SettingsSectionHeader(title: "Accent Preview")
      accentPreview

      SettingsSectionHeader(title: "Accent Color")
      LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 12) {
        ForEach(names, id: \.self) { name in
          Button {
            DiagnosticLogger.shared.action("Accent color selected", metadata: ["accent": name])
            guard appearance != name else { return }
            appearance = name
          } label: {
            VStack(alignment: .leading, spacing: 13) {
              HStack(spacing: 6) {
                Circle().fill(color(for: name)).frame(width: 22, height: 22)
                Circle().fill(color(for: name).opacity(0.66)).frame(width: 22, height: 22)
                Circle().fill(color(for: name).opacity(0.35)).frame(width: 22, height: 22)
                Spacer(minLength: 0)
                if appearance == name {
                  Image(systemName: "checkmark.circle.fill")
                    .foregroundStyle(readableColor(for: name))
                }
              }
              Text(name)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.primary)
            }
            .padding(14)
            .frame(maxWidth: .infinity, minHeight: 92, alignment: .leading)
            .background(
              appearance == name
                ? color(for: name).opacity(colorScheme == .dark ? 0.16 : 0.10)
                : Color(uiColor: .secondarySystemGroupedBackground).opacity(0.96),
              in: RoundedRectangle(cornerRadius: 18, style: .continuous)
            )
            .overlay {
              RoundedRectangle(cornerRadius: 18, style: .continuous)
                .stroke(
                  appearance == name ? readableColor(for: name).opacity(0.78) : Color.primary.opacity(0.05),
                  lineWidth: appearance == name ? 1.5 : 1
                )
                .allowsHitTesting(false)
            }
            .contentShape(Rectangle())
          }
          .buttonStyle(.plain)
          .accessibilityAddTraits(appearance == name ? .isSelected : [])
        }
      }

      if appearance == "Custom" {
        SettingsCard {
          HStack(spacing: 12) {
            SettingsSymbolBox(symbol: "paintpalette.fill")
            VStack(alignment: .leading, spacing: 3) {
              Text("Custom Accent")
                .font(.subheadline.weight(.semibold))
              Text("Choose your own LowPolyCam accent color")
                .font(.caption)
                .foregroundStyle(.secondary)
            }
            Spacer()
            ColorPicker("Custom Accent", selection: customColorBinding, supportsOpacity: false)
              .labelsHidden()
          }
        }
        .transition(.opacity.combined(with: .move(edge: .top)))
      }
    }
    .animation(.easeInOut(duration: 0.18), value: appearance)
    .tint(readableTheme)
    .accentColor(readableTheme)
    .navigationTitle("Appearance")
    .navigationBarTitleDisplayMode(.inline)
  }

  private var accentPreview: some View {
    VStack(spacing: 15) {
      Image(systemName: "camera.aperture")
        .font(.system(size: 44, weight: .light))
        .foregroundStyle(theme)
        .shadow(color: theme.opacity(0.40), radius: 16)

      Text(appearance.uppercased())
        .font(.system(.headline, design: .rounded).weight(.semibold))
        .tracking(3.5)

      HStack(spacing: 16) {
        ForEach(["bolt.fill", "viewfinder", "gearshape.fill"], id: \.self) { symbol in
          Image(systemName: symbol)
            .font(.system(size: 16, weight: .semibold))
            .foregroundStyle(readableTheme)
            .frame(width: 46, height: 46)
            .background(theme.opacity(colorScheme == .dark ? 0.20 : 0.15), in: Circle())
        }
      }

      Text("Your camera, your color")
        .font(.caption)
        .foregroundStyle(.secondary)
    }
    .frame(maxWidth: .infinity)
    .padding(.vertical, 20)
    .background(
      LinearGradient(
        colors: [
          theme.opacity(colorScheme == .dark ? 0.22 : 0.18),
          Color(uiColor: .secondarySystemGroupedBackground).opacity(0.98),
        ],
        startPoint: .topLeading,
        endPoint: .bottomTrailing
      ),
      in: RoundedRectangle(cornerRadius: 22, style: .continuous)
    )
    .overlay {
      RoundedRectangle(cornerRadius: 22, style: .continuous)
        .stroke(readableTheme.opacity(0.22), lineWidth: 1)
        .allowsHitTesting(false)
    }
  }

  private var customColorBinding: Binding<Color> {
    Binding(
      get: { accent.color },
      set: { value in
        var r: CGFloat = 0
        var g: CGFloat = 0
        var b: CGFloat = 0
        var a: CGFloat = 0
        guard UIColor(value).getRed(&r, green: &g, blue: &b, alpha: &a) else { return }
        let values = [Double(r), Double(g), Double(b)]
        guard values.allSatisfy({ $0.isFinite }) else { return }
        red = min(max(values[0], 0), 1)
        green = min(max(values[1], 0), 1)
        blue = min(max(values[2], 0), 1)
      }
    )
  }

  private func color(for name: String) -> Color {
    CameraThemePalette.color(
      for: name,
      customRed: red,
      customGreen: green,
      customBlue: blue
    )
  }

  private func readableColor(for name: String) -> Color {
    CameraThemePalette.readableTextColor(
      for: name,
      customRed: red,
      customGreen: green,
      customBlue: blue,
      colorScheme: colorScheme
    )
  }
}
