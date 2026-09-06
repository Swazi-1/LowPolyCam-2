import SwiftUI

struct ThemeMenu<Value: Hashable>: View {
    @Environment(\.cameraTint) private var theme
    let title: String
    @Binding var selection: Value
    let options: [(Value, String)]
    var onSelect: ((Value) -> Void)? = nil

    private var currentLabel: String {
        options.first(where: { $0.0 == selection })?.1 ?? "—"
    }

    private var nativeSelection: Binding<Value> {
        Binding(
            get: { selection },
            set: { value in
                guard value != selection else { return }
                selection = value
                onSelect?(value)
            }
        )
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title)
                .font(.subheadline.weight(.semibold))

            Menu {
                Picker(title, selection: nativeSelection) {
                    ForEach(options, id: \.0) { value, label in
                        Text(label).tag(value)
                    }
                }
            } label: {
                HStack(spacing: 8) {
                    Text(currentLabel)
                        .font(.caption.weight(.semibold))
                        .lineLimit(1)
                        .minimumScaleFactor(0.82)
                    Spacer(minLength: 8)
                    Image(systemName: "chevron.up.chevron.down")
                        .font(.system(size: 10, weight: .bold))
                }
                .foregroundStyle(theme)
                .padding(.horizontal, 11)
                .frame(maxWidth: .infinity, minHeight: 38)
                .background(Color.primary.opacity(0.07), in: RoundedRectangle(cornerRadius: 10))
                .contentShape(Rectangle())
            }
            .disabled(options.isEmpty)
        }
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
