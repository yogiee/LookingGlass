import SwiftUI
import AppKit

/// Loads bundled PNGs from the SPM resource bundle (Bundle.module).
///
/// `swift build` does not reliably compile `.xcassets` into an `Assets.car`,
/// so `Image("name")` (which expects a compiled catalog) fails. We ship the
/// avatar/background PNGs as loose resources and load them by hand instead.
enum Asset {
    private static var cache: [String: NSImage] = [:]

    static func nsImage(_ name: String) -> NSImage? {
        if let hit = cache[name] { return hit }
        guard let url = Bundle.module.url(
            forResource: name, withExtension: "png", subdirectory: "Resources"
        ), let img = NSImage(contentsOf: url) else {
            return nil
        }
        cache[name] = img
        return img
    }

    @ViewBuilder
    static func image(_ name: String) -> some View {
        if let ns = nsImage(name) {
            Image(nsImage: ns).resizable()
        } else {
            Color.clear
        }
    }
}
