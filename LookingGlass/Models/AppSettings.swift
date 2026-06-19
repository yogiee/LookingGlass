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

// Background is always the desktop-vibrancy glass material — image backdrops were
// removed (they tested poorly and hurt readability). No user-facing option remains.

// Environment keys so font size + line height flow down to all chat content
struct ChatFontSizeKey: EnvironmentKey {
    static let defaultValue: Double = 14.0
}

struct ChatLineHeightKey: EnvironmentKey {
    static let defaultValue: Double = 1.2
}

extension EnvironmentValues {
    var chatFontSize: Double {
        get { self[ChatFontSizeKey.self] }
        set { self[ChatFontSizeKey.self] = newValue }
    }
    var chatLineHeight: Double {
        get { self[ChatLineHeightKey.self] }
        set { self[ChatLineHeightKey.self] = newValue }
    }
}
