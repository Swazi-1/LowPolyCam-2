import SwiftUI
import UIKit

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
        Image(systemName: resolvedSymbol)
            .font(.system(size: 15, weight: .semibold))
            .foregroundStyle(.white)
            .frame(width: 30, height: 30)
            .background(color, in: RoundedRectangle(cornerRadius: 7, style: .continuous))
            .accessibilityHidden(true)
    }

    /// Never leave a Settings icon as a blank colored tile if an SF Symbol name changes or is
    /// unavailable on the running iOS version.
    private var resolvedSymbol: String {
        if UIImage(systemName: symbol) != nil { return symbol }
        switch symbol {
        case "grid": return "square.grid.3x3"
        case "rectangle.inset.inset": return "viewfinder"
        default: return "questionmark"
        }
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

/// Native iOS Settings switch. Keeping this wrapper centralizes logging while allowing iOS 26/27
/// to provide the system switch appearance, animation, accessibility and interaction behavior.
struct HapticFreeSettingsToggle<Label: View>: View {
    @Binding var isOn: Bool
    @AppStorage("hapticCaptureEnabled") private var appHapticsEnabled = true
    private let label: Label

    init(isOn: Binding<Bool>, @ViewBuilder label: () -> Label) {
        self._isOn = isOn
        self.label = label()
    }

    @ViewBuilder
    var body: some View {
        if appHapticsEnabled {
            // Preserve the native iOS 26/27 switch while haptics are enabled.
            Toggle(isOn: $isOn) {
                label
            }
            .toggleStyle(.switch)
            .onChange(of: isOn) { _, newValue in
                logChange(newValue)
            }
        } else {
            // The native switch may provide system tactile feedback independently of CameraHaptics.
            // Once the app's master Haptics setting is off, use a visually equivalent button-backed
            // switch so changing settings cannot generate tactile feedback behind our back.
            Button {
                isOn.toggle()
                logChange(isOn)
            } label: {
                HStack(spacing: 12) {
                    label
                    Spacer(minLength: 12)
                    ZStack(alignment: isOn ? .trailing : .leading) {
                        Capsule()
                            .fill(isOn ? Color.accentColor : Color(uiColor: .systemGray4))
                            .frame(width: 51, height: 31)
                        Circle()
                            .fill(.white)
                            .frame(width: 27, height: 27)
                            .shadow(color: .black.opacity(0.15), radius: 1, y: 1)
                            .padding(2)
                    }
                    .animation(.easeInOut(duration: 0.18), value: isOn)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityValue(isOn ? "On" : "Off")
        }
    }

    private func logChange(_ newValue: Bool) {
        AppEventLog.event("SETTINGS TOGGLE CHANGED", category: .ui, fields: [
            "value": newValue ? "on" : "off"
        ])
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
