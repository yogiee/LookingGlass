import SwiftUI
import AppKit
import CoreText

/// Registers the bundled Roboto Mono variable fonts at launch and exposes
/// helpers for the chat voice. Roboto Mono is a humanist monospace — readable
/// like a terminal font but softer — used for message prose and the input.
/// Code blocks and inline code keep the system monospace on purpose.
enum ChatFont {
    static let family = "Roboto Mono"

    /// Register the bundled .ttf files (process scope — no install). Must run
    /// before the first view renders; called from the AppDelegate.
    static func registerBundled() {
        let files = [
            "RobotoMono-VariableFont_wght",
            "RobotoMono-Italic-VariableFont_wght",
        ]
        for file in files {
            guard let url = Bundle.module.url(
                forResource: file, withExtension: "ttf", subdirectory: "Resources/fonts"
            ) else {
                print("[font] missing \(file).ttf in bundle")
                continue
            }
            var error: Unmanaged<CFError>?
            if !CTFontManagerRegisterFontsForURL(url as CFURL, .process, &error),
               let err = error?.takeRetainedValue() {
                // Re-registration on a hot relaunch is harmless; log the rest.
                print("[font] register \(file): \(err)")
            }
        }
    }

    /// AppKit font for the NSTextView input. Falls back to system mono if the
    /// bundled family didn't register.
    static func ns(size: CGFloat) -> NSFont {
        NSFont(descriptor: NSFontDescriptor(fontAttributes: [.family: family]), size: size)
            ?? .monospacedSystemFont(ofSize: size, weight: .regular)
    }
}

extension Font {
    /// Roboto Mono at an explicit size (chat prose & input use fixed sizes from
    /// Settings, so no Dynamic Type scaling is wanted).
    static func chatProse(_ size: CGFloat) -> Font {
        .custom(ChatFont.family, fixedSize: size)
    }
}
