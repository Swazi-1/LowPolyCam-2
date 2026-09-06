import SwiftUI

/// Shared exclusive-choice control used throughout Settings.
/// Short lists are direct one-tap choices; longer lists use a native Menu with Button actions.
/// Both paths call the same setter exactly once and keep stable value identities.
struct SettingsSelectionControl<Value: Hashable>: View {
    @Environment(\.cameraTint) private var theme
    @Environment(\.isEnabled) private var isEnabled
    let title: String
    @Binding var selection: Value
    let options: [(Value, String)]
    var onSelect: ((Value) -> Void)? = nil

    private var currentLabel: String {
        options.first(where: { $0.0 == selection })?.1 ?? "—"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title)
                .font(.subheadline.weight(.semibold))

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
                .background(Color.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: 10))
            } else if options.count <= 3 {
                HStack(spacing: 8) {
                    ForEach(options, id: \.0) { value, label in
                        Button {
                            commit(value)
                        } label: {
                            Text(label)
                                .font(.caption.weight(.semibold))
                                .lineLimit(2)
                                .minimumScaleFactor(0.82)
                                .multilineTextAlignment(.center)
                                .frame(maxWidth: .infinity, minHeight: 44)
                                .padding(.horizontal, 8)
                                .foregroundStyle(isEnabled ? (value == selection ? theme : Color.primary) : Color.secondary)
                                .background(
                                    value == selection ? theme.opacity(0.18) : Color.primary.opacity(0.06),
                                    in: RoundedRectangle(cornerRadius: 10, style: .continuous)
                                )
                                .overlay {
                                    if value == selection {
                                        RoundedRectangle(cornerRadius: 10, style: .continuous)
                                            .stroke(theme.opacity(0.65), lineWidth: 1)
                                            .allowsHitTesting(false)
                                    }
                                }
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .accessibilityAddTraits(value == selection ? .isSelected : [])
                    }
                }
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
                            .font(.caption.weight(.semibold))
                            .lineLimit(2)
                            .minimumScaleFactor(0.82)
                        Spacer(minLength: 8)
                        Image(systemName: "chevron.up.chevron.down")
                            .font(.system(size: 10, weight: .bold))
                    }
                    .foregroundStyle(theme)
                    .padding(.horizontal, 11)
                    .frame(maxWidth: .infinity, minHeight: 44)
                    .background(Color.primary.opacity(0.07), in: RoundedRectangle(cornerRadius: 10))
                    .contentShape(Rectangle())
                }
            }
        }
    }

    private func commit(_ value: Value) {
        guard value != selection else { return }
        selection = value
        onSelect?(value)
    }
}

/// Compatibility wrapper retained for existing call sites. Its interaction semantics now come
/// from SettingsSelectionControl instead of Menu { Picker }, which was unreliable on the target
/// iOS beta for several settings and also made short 2/3-choice settings unnecessarily two-step.
struct ThemeMenu<Value: Hashable>: View {
    let title: String
    @Binding var selection: Value
    let options: [(Value, String)]
    var onSelect: ((Value) -> Void)? = nil

    var body: some View {
        SettingsSelectionControl(
            title: title,
            selection: $selection,
            options: options,
            onSelect: onSelect
        )
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
                .padding(.vertical, 14)
        }
        .background(Color(uiColor: .systemGroupedBackground))
        .tint(theme)
    }
}

struct SettingsCard<Content: View>: View {
    let title: String
    let symbol: String
    let content: Content

    init(title: String, symbol: String, @ViewBuilder content: () -> Content) {
        self.title = title
        self.symbol = symbol
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 13) {
            Label(title, systemImage: symbol)
                .font(.subheadline.weight(.bold))
                .foregroundStyle(.secondary)
            content
        }
        .padding(16)
        .background(
            Color(uiColor: .secondarySystemGroupedBackground),
            in: RoundedRectangle(cornerRadius: 18, style: .continuous)
        )
        .overlay {
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .stroke(.primary.opacity(0.05), lineWidth: 1)
                .allowsHitTesting(false)
        }
    }
}

struct SettingsDivider: View {
    var body: some View {
        Divider().opacity(0.55)
    }
}

struct SettingsToggleRow: View {
    @Environment(\.cameraTint) private var theme
    let title: String
    let subtitle: String
    @Binding var isOn: Bool

    var body: some View {
        Toggle(isOn: $isOn) {
            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(.subheadline.weight(.semibold))
                Text(subtitle)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .tint(theme)
        .frame(minHeight: 52)
    }
}
