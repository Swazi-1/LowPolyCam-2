import SwiftUI

enum SettingsInterfaceStyle: String, CaseIterable, Identifiable {
  case light = "Light"
  case dark = "Dark"
  case system = "System"

  var id: String { rawValue }

  var symbol: String {
    switch self {
    case .light: return "sun.max.fill"
    case .dark: return "moon.fill"
    case .system: return "rectangle.on.rectangle"
    }
  }

  var colorScheme: ColorScheme? {
    switch self {
    case .light: return .light
    case .dark: return .dark
    case .system: return nil
    }
  }

  static func scheme(for storedValue: String) -> ColorScheme? {
    (SettingsInterfaceStyle(rawValue: storedValue) ?? .system).colorScheme
  }
}
