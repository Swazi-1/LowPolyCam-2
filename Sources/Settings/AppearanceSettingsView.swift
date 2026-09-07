import SwiftUI
import UIKit

struct AppearanceSettingsView: View {
  @AppStorage("settingsInterfaceStyle") private var interfaceStyle = SettingsInterfaceStyle.system
    .rawValue
  @AppStorage("iconAppearance") private var appearance = "Ice"
  @AppStorage("iconCustomRed") private var red = 0.55
  @AppStorage("iconCustomGreen") private var green = 0.85
  @AppStorage("iconCustomBlue") private var blue = 1.0
  @Environment(\.cameraTint) private var theme
  private var accent = CameraAccent()
  private let names = ["Ice", "Sunset", "Mint", "Lavender", "Coral", "Custom"]

  init() {}

  var body: some View {
    SettingsPage {
      SettingsSectionHeader(title: "Interface Style")
      SettingsCard {
        HStack(spacing: 5) {
          ForEach(SettingsInterfaceStyle.allCases) { style in
            Button {
              guard interfaceStyle != style.rawValue else { return }
              interfaceStyle = style.rawValue
            } label: {
              VStack(spacing: 7) {
                Image(systemName: style.symbol)
                  .font(.system(size: 18, weight: .semibold))
                Text(style.rawValue)
                  .font(.caption.weight(.semibold))
              }
              .foregroundStyle(
                interfaceStyle == style.rawValue ? accent.foregroundColor : Color.primary
              )
              .frame(maxWidth: .infinity, minHeight: 66)
              .background(
                interfaceStyle == style.rawValue ? theme : Color.primary.opacity(0.035),
                in: RoundedRectangle(cornerRadius: 13, style: .continuous)
              )
              .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityAddTraits(interfaceStyle == style.rawValue ? .isSelected : [])
          }
        }
      }

      SettingsSectionHeader(title: "Accent Color")
      LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 12) {
        ForEach(names, id: \.self) { name in
          Button {
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
                    .foregroundStyle(color(for: name))
                }
              }
              Text(name)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.primary)
            }
            .padding(14)
            .frame(maxWidth: .infinity, minHeight: 92, alignment: .leading)
            .background(
              Color(uiColor: .secondarySystemGroupedBackground).opacity(0.96),
              in: RoundedRectangle(cornerRadius: 18, style: .continuous)
            )
            .overlay {
              RoundedRectangle(cornerRadius: 18, style: .continuous)
                .stroke(
                  appearance == name ? color(for: name).opacity(0.72) : Color.primary.opacity(0.05),
                  lineWidth: appearance == name ? 1.5 : 1
                )
                .allowsHitTesting(false)
            }
            .contentShape(Rectangle())
          }
          .buttonStyle(.plain)
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
    .tint(accent.color)
    .accentColor(accent.color)
    .navigationTitle("Appearance")
    .navigationBarTitleDisplayMode(.inline)
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
}
