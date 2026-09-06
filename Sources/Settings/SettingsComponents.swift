import SwiftUI

struct ThemeMenu<Value: Hashable>: View {
    @Environment(\.cameraTint) private var theme
    let title: String
    @Binding var selection: Value
    let options: [(Value, String)]
    var onSelect: ((Value) -> Void)? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title)
                .font(.subheadline.weight(.semibold))

            LazyVGrid(
                columns: Array(repeating: GridItem(.flexible(), spacing: 8), count: min(3, max(1, options.count))),
                spacing: 8
            ) {
                ForEach(options, id: \.0) { value, label in
                    Button {
                        selection = value
                        onSelect?(value)
                    } label: {
                        Text(label)
                            .font(.caption.weight(.semibold))
                            .multilineTextAlignment(.center)
                            .frame(maxWidth: .infinity, minHeight: 36)
                            .padding(.horizontal, 4)
                            .background(
                                selection == value ? theme : Color.primary.opacity(0.07),
                                in: RoundedRectangle(cornerRadius: 10)
                            )
                            .foregroundStyle(selection == value ? Color.black : Color.primary)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityAddTraits(selection == value ? .isSelected : [])
                }
            }
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
