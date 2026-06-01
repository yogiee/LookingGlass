import SwiftUI

enum AppColorScheme: String, CaseIterable {
    case system = "System"
    case light  = "Light"
    case dark   = "Dark"

    var colorScheme: ColorScheme? {
        switch self {
        case .system: return nil
        case .light:  return .light
        case .dark:   return .dark
        }
    }
}

enum BackgroundStyle: String, CaseIterable {
    case glass      // desktop-vibrancy glass (default)
    case wonderland // themed Wonderland backdrop, switches with light/dark

    var label: String {
        switch self {
        case .glass:      return "Glass"
        case .wonderland: return "Wonderland"
        }
    }
}

// Environment key so font size flows down to all chat content
struct ChatFontSizeKey: EnvironmentKey {
    static let defaultValue: Double = 14.0
}

extension EnvironmentValues {
    var chatFontSize: Double {
        get { self[ChatFontSizeKey.self] }
        set { self[ChatFontSizeKey.self] = newValue }
    }
}
