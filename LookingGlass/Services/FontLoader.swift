import SwiftUI
import AppKit
import CoreText
import MarkdownUI

/// The chat "voice" — a sans prose font picked in Settings (applied to message
/// prose + the input) paired with a monospace family for code. Each prose font
/// brings its natural mono companion; fonts without a first-party mono fall back
/// to the system monospace (SF Mono).
///
/// `system` is San Francisco (SF Pro Text at chat sizes) → SF Mono. The bundled
/// families live in `Resources/fonts/` and are registered at launch by
/// `ChatFont.registerBundled()`. Add a candidate: drop its .ttf(s) in that
/// folder, add a case here.
enum ChatFontChoice: String, CaseIterable, Identifiable {
    case system        // SF Pro        → SF Mono (system)
    case inter         // Inter         → SF Mono (no first-party mono)
    case ibmPlexSans   // IBM Plex Sans → IBM Plex Mono
    case roboto        // Roboto        → Roboto Mono

    var id: String { rawValue }

    var label: String {
        switch self {
        case .system:      return "SF Pro (System)"
        case .inter:       return "Inter"
        case .ibmPlexSans: return "IBM Plex Sans"
        case .roboto:      return "Roboto"
        }
    }

    /// Prose family; nil → system font (San Francisco).
    var family: String? {
        switch self {
        case .system:      return nil
        case .inter:       return "Inter"
        case .ibmPlexSans: return "IBM Plex Sans"
        case .roboto:      return "Roboto"
        }
    }

    /// Monospace pairing for code; nil → system monospace (SF Mono).
    var codeFamily: String? {
        switch self {
        case .system, .inter: return nil
        case .ibmPlexSans:    return "IBM Plex Mono"
        case .roboto:         return "Roboto Mono"
        }
    }

    /// SwiftUI font at a fixed size (chat uses the Settings size, no Dynamic Type).
    func font(_ size: CGFloat) -> Font {
        family.map { Font.custom($0, fixedSize: size) } ?? .system(size: size)
    }

    /// AppKit font for the NSTextView input (falls back to system on a miss).
    func nsFont(_ size: CGFloat) -> NSFont {
        guard let family,
              let f = NSFont(descriptor: NSFontDescriptor(fontAttributes: [.family: family]), size: size)
        else { return .systemFont(ofSize: size) }
        return f
    }

    /// MarkdownUI family for message prose.
    var markdownFamily: FontProperties.Family {
        family.map { .custom($0) } ?? .system()
    }
}

enum ChatFont {
    /// UserDefaults / @AppStorage key for the selected chat font.
    static let storageKey = "chatFontChoice"

    /// Extra letter-spacing for chat prose & input — a touch beyond default,
    /// scaled to the font size. Points; applies to SwiftUI `.tracking`, NSFont
    /// `.kern`, and MarkdownUI `TextTracking`. Tune the multiplier to taste.
    static func tracking(_ size: CGFloat) -> CGFloat { size * 0.03 }

    /// Register every bundled .ttf (process scope — no install). Must run before
    /// the first view renders; called from the AppDelegate.
    static func registerBundled() {
        guard let urls = Bundle.module.urls(
            forResourcesWithExtension: "ttf", subdirectory: "Resources/fonts"
        ) else {
            print("[font] no bundled fonts found")
            return
        }
        for url in urls {
            var error: Unmanaged<CFError>?
            if !CTFontManagerRegisterFontsForURL(url as CFURL, .process, &error),
               let err = error?.takeRetainedValue() {
                // Re-registration on a hot relaunch is harmless; log the rest.
                print("[font] register \(url.lastPathComponent): \(err)")
            }
        }
    }
}
