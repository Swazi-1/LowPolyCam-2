import SwiftUI

struct SettingsNavigationContainer<Content: View>: View {
  @AppStorage("settingsInterfaceStyle") private var interfaceStyle = SettingsInterfaceStyle.system
    .rawValue
  let content: Content

  init(@ViewBuilder content: () -> Content) {
    self.content = content()
  }

  var body: some View {
    NavigationStack { content }
      .preferredColorScheme(SettingsInterfaceStyle.scheme(for: interfaceStyle))
  }
}

extension View {
  func cameraSettingsSheetPresentation() -> some View {
    presentationDetents([.large])
      .presentationDragIndicator(.visible)
  }
}

struct SettingsPage<Content: View>: View {
  @Environment(\.cameraTint) private var theme
  let content: Content

  init(@ViewBuilder content: () -> Content) {
    self.content = content()
  }

  var body: some View {
    ScrollView {
      VStack(spacing: 18) { content }
        .padding(.horizontal, 16)
        .padding(.top, 12)
        .padding(.bottom, 28)
    }
    .background(
      LinearGradient(
        colors: [
          Color(uiColor: .systemGroupedBackground),
          theme.opacity(0.035),
          Color(uiColor: .systemGroupedBackground),
        ],
        startPoint: .topLeading,
        endPoint: .bottomTrailing
      )
      .ignoresSafeArea()
    )
    .tint(theme)
  }
}

struct SettingsSectionHeader: View {
  let title: String
  var subtitle: String? = nil

  var body: some View {
    VStack(alignment: .leading, spacing: 3) {
      Text(title.uppercased())
        .font(.caption.weight(.semibold))
        .tracking(0.5)
        .foregroundStyle(.secondary)
      if let subtitle {
        Text(subtitle)
          .font(.caption2)
          .foregroundStyle(.tertiary)
      }
    }
    .frame(maxWidth: .infinity, alignment: .leading)
    .padding(.horizontal, 4)
  }
}

struct SettingsCard<Content: View>: View {
  let title: String?
  let symbol: String?
  let content: Content

  init(title: String? = nil, symbol: String? = nil, @ViewBuilder content: () -> Content) {
    self.title = title
    self.symbol = symbol
    self.content = content()
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 13) {
      if let title {
        HStack(spacing: 8) {
          if let symbol {
            Image(systemName: symbol)
              .font(.system(size: 14, weight: .semibold))
          }
          Text(title)
            .font(.subheadline.weight(.semibold))
        }
        .foregroundStyle(.secondary)
      }
      content
    }
    .padding(16)
    .background(
      Color(uiColor: .secondarySystemGroupedBackground).opacity(0.96),
      in: RoundedRectangle(cornerRadius: 20, style: .continuous)
    )
    .overlay {
      RoundedRectangle(cornerRadius: 20, style: .continuous)
        .stroke(.primary.opacity(0.055), lineWidth: 1)
        .allowsHitTesting(false)
    }
    .shadow(color: .black.opacity(0.035), radius: 12, y: 5)
  }
}

struct SettingsDivider: View {
  var body: some View {
    Divider().opacity(0.48)
  }
}

struct SettingsSymbolBox: View {
  @Environment(\.cameraTint) private var theme
  let symbol: String
  var selected = false

  var body: some View {
    Image(systemName: symbol)
      .font(.system(size: 18, weight: .semibold))
      .foregroundStyle(selected ? theme : Color.primary)
      .frame(width: 38, height: 38)
      .background(
        selected ? theme.opacity(0.12) : Color.primary.opacity(0.045),
        in: RoundedRectangle(cornerRadius: 11, style: .continuous)
      )
  }
}

struct SettingsToggleRow: View {
  @Environment(\.cameraTint) private var theme
  let title: String
  let subtitle: String
  @Binding var isOn: Bool
  var symbol: String? = nil

  var body: some View {
    Toggle(isOn: $isOn) {
      HStack(spacing: 12) {
        if let symbol {
          SettingsSymbolBox(symbol: symbol)
        }
        VStack(alignment: .leading, spacing: 3) {
          Text(title)
            .font(.subheadline.weight(.medium))
          Text(subtitle)
            .font(.caption)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
        }
      }
    }
    .tint(theme)
    .frame(minHeight: 54)
  }
}

struct SettingsSliderChildRow: View {
  @Environment(\.cameraTint) private var theme
  let title: String
  let subtitle: String
  @Binding var value: Double
  let range: ClosedRange<Double>

  var body: some View {
    HStack(alignment: .center, spacing: 10) {
      Image(systemName: "arrow.turn.down.right")
        .font(.caption.weight(.semibold))
        .foregroundStyle(.tertiary)
        .frame(width: 24)

      VStack(alignment: .leading, spacing: 8) {
        VStack(alignment: .leading, spacing: 2) {
          Text(title).font(.subheadline.weight(.medium))
          Text(subtitle).font(.caption2).foregroundStyle(.secondary)
        }
        HStack(spacing: 10) {
          Slider(value: $value, in: range)
            .tint(theme)
            .accessibilityLabel(title)
          Text("\(Int((value * 100).rounded()))%")
            .font(.caption.monospacedDigit())
            .foregroundStyle(.secondary)
            .frame(width: 42, alignment: .trailing)
        }
      }
    }
    .padding(.vertical, 4)
    .transition(.opacity.combined(with: .move(edge: .top)))
  }
}

struct SettingsSelectionControl<Value: Hashable>: View {
  @Environment(\.cameraTint) private var theme
  private var accent = CameraAccent()
  @Environment(\.isEnabled) private var isEnabled
  let title: String
  @Binding var selection: Value
  let options: [(Value, String)]
  var onSelect: ((Value) -> Void)? = nil
  var firesActionOnReselect = false

  private var currentLabel: String {
    options.first(where: { $0.0 == selection })?.1 ?? "—"
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 10) {
      if !title.isEmpty {
        Text(title)
          .font(.subheadline.weight(.semibold))
      }

      choiceContent
    }
  }

  @ViewBuilder
  private var choiceContent: some View {
    if options.isEmpty {
      HStack {
        Text("Unavailable")
          .font(.caption.weight(.semibold))
          .foregroundStyle(.secondary)
        Spacer()
        ProgressView().controlSize(.small)
      }
      .frame(maxWidth: .infinity, minHeight: 44)
      .padding(.horizontal, 11)
      .background(Color.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: 11))
    } else if options.count <= 3 {
      HStack(spacing: 5) {
        optionButtons
      }
      .padding(4)
      .background(
        Color.primary.opacity(0.045), in: RoundedRectangle(cornerRadius: 13, style: .continuous))
    } else if options.count == 4 {
      LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 5) {
        optionButtons
      }
      .padding(4)
      .background(
        Color.primary.opacity(0.045), in: RoundedRectangle(cornerRadius: 13, style: .continuous))
    } else {
      Menu {
        ForEach(options, id: \.0) { value, label in
          Button {
            commit(value)
          } label: {
            if value == selection {
              Label(label, systemImage: "checkmark")
            } else {
              Text(label)
            }
          }
        }
      } label: {
        HStack(spacing: 8) {
          Text(currentLabel)
            .font(.subheadline.weight(.semibold))
            .lineLimit(1)
          Spacer(minLength: 8)
          Image(systemName: "chevron.up.chevron.down")
            .font(.system(size: 10, weight: .bold))
        }
        .foregroundStyle(theme)
        .padding(.horizontal, 12)
        .frame(maxWidth: .infinity, minHeight: 44)
        .background(Color.primary.opacity(0.055), in: RoundedRectangle(cornerRadius: 11))
        .contentShape(Rectangle())
      }
    }
  }

  @ViewBuilder
  private var optionButtons: some View {
    ForEach(options, id: \.0) { value, label in
      Button {
        commit(value)
      } label: {
        Text(label)
          .font(.caption.weight(.semibold))
          .lineLimit(2)
          .minimumScaleFactor(0.72)
          .multilineTextAlignment(.center)
          .frame(maxWidth: .infinity, minHeight: 42)
          .padding(.horizontal, 5)
          .foregroundStyle(
            !isEnabled
              ? Color.secondary : (value == selection ? accent.foregroundColor : Color.primary)
          )
          .background(
            value == selection ? theme : Color.clear,
            in: RoundedRectangle(cornerRadius: 10, style: .continuous)
          )
          .contentShape(Rectangle())
      }
      .buttonStyle(.plain)
      .accessibilityAddTraits(value == selection ? .isSelected : [])
    }
  }

  private func commit(_ value: Value) {
    if value == selection {
      if firesActionOnReselect { onSelect?(value) }
      return
    }
    selection = value
    onSelect?(value)
  }
}

struct ThemeMenu<Value: Hashable>: View {
  let title: String
  @Binding var selection: Value
  let options: [(Value, String)]
  var onSelect: ((Value) -> Void)? = nil
  var firesActionOnReselect = false

  var body: some View {
    SettingsSelectionControl(
      title: title,
      selection: $selection,
      options: options,
      onSelect: onSelect,
      firesActionOnReselect: firesActionOnReselect
    )
  }
}

struct SettingsOptionCard<Value: Hashable>: View {
  let title: String
  let subtitle: String
  let symbol: String
  @Binding var selection: Value
  let options: [(Value, String)]
  var onSelect: ((Value) -> Void)? = nil

  var body: some View {
    VStack(alignment: .leading, spacing: 13) {
      HStack(spacing: 10) {
        SettingsSymbolBox(symbol: symbol)
        VStack(alignment: .leading, spacing: 2) {
          Text(title)
            .font(.subheadline.weight(.semibold))
            .lineLimit(1)
            .minimumScaleFactor(0.82)
          Text(subtitle)
            .font(.caption2)
            .foregroundStyle(.secondary)
            .lineLimit(2)
        }
      }
      SettingsSelectionControl(
        title: "",
        selection: $selection,
        options: options,
        onSelect: onSelect
      )
    }
    .padding(13)
    .frame(maxWidth: .infinity, minHeight: 146, alignment: .topLeading)
    .background(
      Color(uiColor: .secondarySystemGroupedBackground).opacity(0.96),
      in: RoundedRectangle(cornerRadius: 20, style: .continuous)
    )
    .overlay {
      RoundedRectangle(cornerRadius: 20, style: .continuous)
        .stroke(.primary.opacity(0.055), lineWidth: 1)
        .allowsHitTesting(false)
    }
    .shadow(color: .black.opacity(0.03), radius: 10, y: 4)
  }
}

struct SettingsChoiceRow<Value: Hashable>: View {
  let title: String
  let subtitle: String
  let symbol: String
  @Binding var selection: Value
  let options: [(Value, String)]
  var onSelect: ((Value) -> Void)? = nil
  var firesActionOnReselect = false

  var body: some View {
    VStack(alignment: .leading, spacing: 11) {
      HStack(spacing: 12) {
        SettingsSymbolBox(symbol: symbol)
        VStack(alignment: .leading, spacing: 2) {
          Text(title).font(.subheadline.weight(.medium))
          Text(subtitle).font(.caption).foregroundStyle(.secondary)
        }
      }
      SettingsSelectionControl(
        title: "",
        selection: $selection,
        options: options,
        onSelect: onSelect,
        firesActionOnReselect: firesActionOnReselect
      )
    }
    .padding(.vertical, 2)
  }
}

struct SettingsMenuRow<Value: Hashable>: View {
  let title: String
  let subtitle: String
  let symbol: String
  @Binding var selection: Value
  let options: [(Value, String)]

  var body: some View {
    HStack(spacing: 12) {
      SettingsSymbolBox(symbol: symbol)
      VStack(alignment: .leading, spacing: 3) {
        Text(title).font(.subheadline.weight(.medium))
        Text(subtitle).font(.caption).foregroundStyle(.secondary)
      }
      Spacer(minLength: 8)
      Menu {
        ForEach(options, id: \.0) { value, label in
          Button {
            guard value != selection else { return }
            selection = value
          } label: {
            if value == selection {
              Label(label, systemImage: "checkmark")
            } else {
              Text(label)
            }
          }
        }
      } label: {
        HStack(spacing: 5) {
          Text(options.first(where: { $0.0 == selection })?.1 ?? "—")
            .font(.caption.weight(.semibold))
          Image(systemName: "chevron.up.chevron.down")
            .font(.system(size: 9, weight: .bold))
        }
        .padding(.horizontal, 11)
        .frame(minHeight: 40)
        .background(Color.primary.opacity(0.055), in: Capsule())
      }
    }
    .frame(minHeight: 56)
  }
}

struct SettingsNavigationTile: View {
  @Environment(\.cameraTint) private var theme
  let title: String
  let subtitle: String
  let symbol: String
  var fullWidth = false

  var body: some View {
    HStack(spacing: 12) {
      SettingsSymbolBox(symbol: symbol)
      VStack(alignment: .leading, spacing: 3) {
        Text(title)
          .font(.subheadline.weight(.semibold))
          .foregroundStyle(.primary)
          .lineLimit(2)
        Text(subtitle)
          .font(.caption2)
          .foregroundStyle(.secondary)
          .lineLimit(2)
      }
      Spacer(minLength: 5)
      Image(systemName: "chevron.right")
        .font(.caption.weight(.bold))
        .foregroundStyle(theme.opacity(0.7))
    }
    .padding(13)
    .frame(maxWidth: .infinity, minHeight: fullWidth ? 74 : 92, alignment: .leading)
    .background(
      Color(uiColor: .secondarySystemGroupedBackground).opacity(0.96),
      in: RoundedRectangle(cornerRadius: 19, style: .continuous)
    )
    .overlay {
      RoundedRectangle(cornerRadius: 19, style: .continuous)
        .stroke(.primary.opacity(0.05), lineWidth: 1)
        .allowsHitTesting(false)
    }
    .contentShape(Rectangle())
  }
}

struct SettingsNavigationRow: View {
  let title: String
  let subtitle: String
  let symbol: String

  var body: some View {
    SettingsNavigationTile(title: title, subtitle: subtitle, symbol: symbol, fullWidth: true)
  }
}

struct SettingsActionRow: View {
  @Environment(\.cameraTint) private var theme
  let title: String
  let subtitle: String
  let symbol: String
  var role: ButtonRole? = nil
  let action: () -> Void

  var body: some View {
    Button(role: role, action: action) {
      HStack(spacing: 12) {
        SettingsSymbolBox(symbol: symbol)
        VStack(alignment: .leading, spacing: 3) {
          Text(title).font(.subheadline.weight(.semibold))
          Text(subtitle).font(.caption).foregroundStyle(.secondary)
        }
        Spacer()
        Image(systemName: "chevron.right")
          .font(.caption.weight(.bold))
          .foregroundStyle(theme.opacity(0.65))
      }
      .frame(maxWidth: .infinity, minHeight: 54)
      .contentShape(Rectangle())
    }
    .buttonStyle(.plain)
  }
}
