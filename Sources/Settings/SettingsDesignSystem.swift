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

/// Settings-only switch that does not use the native UIKit Toggle control. UIKit can emit a
/// system selection tick even when the app's haptic preference is disabled; this reusable control
/// keeps the setting accessible while leaving all feedback under LowPolyCam's explicit haptic
/// helper.
struct HapticFreeSettingsToggle<Label: View>: View {
    @Environment(\.isEnabled) private var isEnabled
    @Binding var isOn: Bool
    private let label: Label

    init(isOn: Binding<Bool>, @ViewBuilder label: () -> Label) {
        self._isOn = isOn
        self.label = label()
    }

    var body: some View {
        Button {
            guard isEnabled else { return }
            isOn.toggle()
            AppEventLog.event("SETTINGS TOGGLE CHANGED", category: .ui, fields: [
                "value": isOn ? "on" : "off"
            ])
        } label: {
            HStack(spacing: 12) {
                label
                Spacer(minLength: 8)
                switchView
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .combine)
        .accessibilityValue(isOn ? "On" : "Off")
        .accessibilityAddTraits(.isButton)
        .accessibilityAction {
            guard isEnabled else { return }
            isOn.toggle()
        }
        .opacity(isEnabled ? 1 : 0.55)
    }

    private var switchView: some View {
        RoundedRectangle(cornerRadius: 16, style: .continuous)
            .fill(isOn ? Color.accentColor : Color.secondary.opacity(0.28))
            .frame(width: 52, height: 32)
            .overlay(alignment: isOn ? .trailing : .leading) {
                Circle()
                    .fill(.white)
                    .shadow(color: .black.opacity(0.18), radius: 1, y: 1)
                    .frame(width: 28, height: 28)
                    .padding(2)
            }
            .accessibilityHidden(true)
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
