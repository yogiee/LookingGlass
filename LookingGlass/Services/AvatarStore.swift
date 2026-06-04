import AppKit

/// Stores the user's custom avatar as a PNG in Application Support and serves
/// it back with a small version-keyed cache so views don't hit disk every render.
@MainActor
enum AvatarStore {
    static var avatarURL: URL {
        let dir = FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("LookingGlass", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("user-avatar.png")
    }

    private static var cached: NSImage?
    private static var cachedVersion = -1

    /// Returns the user avatar for a given version token. Reads disk only when
    /// the version changes (bumped on save/clear via @AppStorage).
    static func userAvatar(version: Int) -> NSImage? {
        if version != cachedVersion {
            cached = NSImage(contentsOf: avatarURL)
            cachedVersion = version
        }
        return cached
    }

    /// Copies and re-encodes a chosen image to PNG at the fixed path. Returns
    /// success; caller should bump the version token to refresh views.
    @discardableResult
    static func saveUserAvatar(from source: URL) -> Bool {
        guard let img = NSImage(contentsOf: source),
              let tiff = img.tiffRepresentation,
              let rep = NSBitmapImageRep(data: tiff),
              let png = rep.representation(using: .png, properties: [:])
        else { return false }
        do {
            try png.write(to: avatarURL)
            cached = nil
            cachedVersion = -1
            return true
        } catch {
            return false
        }
    }

    static func clearUserAvatar() {
        try? FileManager.default.removeItem(at: avatarURL)
        cached = nil
        cachedVersion = -1
    }
}
