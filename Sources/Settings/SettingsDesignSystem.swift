import SwiftUI

// MARK: - App appearance

/// Resolves the stored "appColorScheme" preference ("light" / "dark" / "system")
/// into a SwiftUI ColorScheme override. `nil` means follow iOS.
func resolvedColorScheme(_ raw: String) -> ColorScheme? {
    switch raw {
    case "light": return .light
    case "dark": return .dark
    default: return nil
    }
}

// MARK: - Native Settings-style building blocks

struct SettingsListIcon: View {
    let symbol: String
    let color: Color

    var body: some View {
        Image(systemName: symbol)
            .font(.system(size: 15, weight: .semibold))
            .foregroundStyle(.white)
            .frame(width: 30, height: 30)
            .background(color, in: RoundedRectangle(cornerRadius: 7, style: .continuous))
            .accessibilityHidden(true)
    }
}

struct SettingsNavigationLabel: View {
    let symbol: String
    let color: Color
    let title: String
    var value: String? = nil
    var subtitle: String? = nil

    var body: some View {
        HStack(spacing: 12) {
            SettingsListIcon(symbol: symbol, color: color)

            VStack(alignment: .leading, spacing: subtitle == nil ? 0 : 2) {
                Text(title)
                    .foregroundStyle(.primary)
                if let subtitle {
                    Text(subtitle)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }
            }

            Spacer(minLength: 8)

            if let value {
                Text(value)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.75)
            }
        }
        .contentShape(Rectangle())
    }
}

struct SettingsToggleLabel: View {
    let symbol: String
    let color: Color
    let title: String
    var subtitle: String? = nil

    var body: some View {
        HStack(spacing: 12) {
            SettingsListIcon(symbol: symbol, color: color)
            VStack(alignment: .leading, spacing: subtitle == nil ? 0 : 2) {
                Text(title)
                if let subtitle {
                    Text(subtitle)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }
}

struct SettingsCheckmarkRow: View {
    let title: String
    var subtitle: String? = nil
    let selected: Bool
    var enabled: Bool = true

    var body: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: subtitle == nil ? 0 : 2) {
                Text(title)
                if let subtitle {
                    Text(subtitle)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            Spacer(minLength: 8)
            if selected {
                Image(systemName: "checkmark")
                    .font(.body.weight(.semibold))
                    .foregroundStyle(.blue)
            }
        }
        .foregroundStyle(enabled ? Color.primary : Color.secondary)
        .contentShape(Rectangle())
    }
}

struct SettingsHeroButton: View {
    let title: String
    let line1: String
    let line2: String

    var body: some View {
        HStack(spacing: 16) {
            Image(systemName: "video.fill")
                .font(.system(size: 27, weight: .semibold))
                .foregroundStyle(.white)
                .frame(width: 68, height: 68)
                .background(Color.blue, in: RoundedRectangle(cornerRadius: 18, style: .continuous))

            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(.system(size: 19, weight: .semibold))
                    .foregroundStyle(.primary)
                Text(line1)
                    .font(.system(size: 15))
                    .foregroundStyle(.secondary)
                Text(line2)
                    .font(.system(size: 15))
                    .foregroundStyle(.secondary)
            }

            Spacer(minLength: 8)

            Image(systemName: "chevron.right")
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(.tertiary)
        }
        .padding(.horizontal, 18)
        .frame(maxWidth: .infinity, minHeight: 112, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 20, style: .continuous)
                .fill(Color(uiColor: .secondarySystemGroupedBackground))
        )
        .contentShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
    }
}

struct SettingsInfoRow: View {
    let symbol: String
    let color: Color
    let title: String
    let detail: String

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            SettingsListIcon(symbol: symbol, color: color)
            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                Text(detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}


// MARK: - Fixed option popover

/// A compact Settings-style picker that opens a fixed popover instead of a scroll-tracking Menu.
/// This is used for short option lists where dragging the system Menu would make the whole list move.
struct SettingsPickerOption<Value: Hashable>: Identifiable {
    let value: Value
    let title: String
    var id: Value { value }
}

struct SettingsFixedOptionPicker<Value: Hashable>: View {
    let title: String
    @Binding var selection: Value
    let options: [SettingsPickerOption<Value>]
    @State private var isPresented = false

    private var selectedTitle: String {
        options.first(where: { $0.value == selection })?.title ?? "—"
    }

    var body: some View {
        Button {
            isPresented = true
        } label: {
            HStack(spacing: 10) {
                Text(title)
                    .foregroundStyle(.primary)
                Spacer(minLength: 12)
                Text(selectedTitle)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                Image(systemName: "chevron.up.chevron.down")
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(.tertiary)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .popover(isPresented: $isPresented, attachmentAnchor: .rect(.bounds), arrowEdge: .top) {
            VStack(spacing: 0) {
                ForEach(options.indices, id: \.self) { index in
                    let option = options[index]
                    Button {
                        selection = option.value
                        isPresented = false
                    } label: {
                        HStack(spacing: 12) {
                            Text(option.title)
                                .foregroundStyle(.primary)
                            Spacer(minLength: 16)
                            if option.value == selection {
                                Image(systemName: "checkmark")
                                    .font(.body.weight(.semibold))
                                    .foregroundStyle(.blue)
                            }
                        }
                        .frame(minHeight: 42)
                        .padding(.horizontal, 16)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)

                    if index < options.count - 1 {
                        Divider().padding(.leading, 16)
                    }
                }
            }
            .padding(.vertical, 6)
            .frame(width: 250)
            .presentationCompactAdaptation(.popover)
        }
    }
}
