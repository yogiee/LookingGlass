import AppKit
import CryptoKit
import Foundation
import ImageIO

/// Downsampled, cached thumbnails for inline chat images — two tiers.
///
/// `NSImage(contentsOfFile:)` decodes at full resolution, so a 4096×4096 upscaler
/// output becomes a ~67MB bitmap even though the chat draws it into a 360pt box.
/// Worse, read from a computed property it re-decodes on every body pass — which is
/// what made opening a conversation with a generated image stall the main thread for
/// ~1s, every time, even after it had already loaded once.
///
/// **Tier 1 (memory):** an `NSCache` — kills re-decode within a session.
/// **Tier 2 (disk):** a small JPEG written to Application Support. Without it, every
/// *cold* open of a conversation still re-decodes the full-size PNGs from scratch;
/// that's the residual lag on image-heavy chats. A 720px JPEG is ~50–80KB and decodes
/// an order of magnitude faster than a multi-megabyte PNG, so re-opening becomes cheap.
///
/// The disk key embeds the source file's mtime + size, so a changed file (e.g. an
/// in-place upscale) misses automatically rather than serving a stale thumbnail.
enum ImageThumbnailCache {

    /// Longest edge in pixels. The inline frame caps at 360pt; 2× covers Retina,
    /// and the lightbox reloads at full resolution anyway.
    static let inlineMaxPixel = 720

    private static let jpegQuality: CGFloat = 0.82
    /// Prune trigger. ~60–80KB each, so 400 files ≈ 30MB worst case.
    private static let maxDiskEntries = 400

    private static let cache: NSCache<NSString, NSImage> = {
        let c = NSCache<NSString, NSImage>()
        c.countLimit = 60
        return c
    }()

    /// `~/Library/Application Support/LookingGlass/thumbnails/`
    /// User data, never the app bundle (Invariant #7) — an update replaces the bundle.
    private static var diskDir: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.homeDirectoryForCurrentUser
        return base.appendingPathComponent("LookingGlass", isDirectory: true)
                   .appendingPathComponent("thumbnails", isDirectory: true)
    }

    /// Cached thumbnail, if one was already built **in memory**. Main-thread safe and
    /// allocation free — lets a view show the image on first render with no flash.
    /// Deliberately does not touch the disk: this is called from `body`/`init`.
    static func cached(_ path: String, maxPixel: Int = inlineMaxPixel) -> NSImage? {
        cache.object(forKey: key(path, maxPixel))
    }

    /// Build (or fetch) the thumbnail. Decodes and touches the filesystem, so call it
    /// off the main thread.
    static func thumbnail(_ path: String, maxPixel: Int = inlineMaxPixel) -> NSImage? {
        let memKey = key(path, maxPixel)
        if let hit = cache.object(forKey: memKey) { return hit }

        // Tier 2 — disk. Cheap decode of an already-small file.
        if let diskURL = diskURL(for: path, maxPixel: maxPixel),
           let image = loadImage(at: diskURL) {
            cache.setObject(image, forKey: memKey)
            return image
        }

        // Miss on both tiers — downsample from the source.
        let url = URL(fileURLWithPath: path) as CFURL
        guard let source = CGImageSourceCreateWithURL(url, nil) else { return nil }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,   // honour EXIF orientation
            kCGImageSourceShouldCacheImmediately: true,         // decode here, not at draw time
            kCGImageSourceThumbnailMaxPixelSize: maxPixel,
        ]
        guard let cgImage = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary)
        else { return nil }

        if let diskURL = diskURL(for: path, maxPixel: maxPixel) {
            write(cgImage, to: diskURL)
        }

        let image = NSImage(
            cgImage: cgImage,
            size: NSSize(width: cgImage.width, height: cgImage.height)
        )
        cache.setObject(image, forKey: memKey)
        return image
    }

    /// Drop a path's entries from both tiers — call after the file on disk changes
    /// (e.g. an upscale overwrites it) so the stale thumbnail isn't served.
    ///
    /// The disk key already embeds mtime+size so a changed file misses anyway; this
    /// also reclaims the now-orphaned file instead of leaving it for the pruner.
    static func invalidate(_ path: String) {
        for size in [inlineMaxPixel] { cache.removeObject(forKey: key(path, size)) }
        let prefix = pathHash(path) + "-"
        let fm = FileManager.default
        guard let entries = try? fm.contentsOfDirectory(at: diskDir, includingPropertiesForKeys: nil)
        else { return }
        for url in entries where url.lastPathComponent.hasPrefix(prefix) {
            try? fm.removeItem(at: url)
        }
    }

    // MARK: - Disk tier

    /// Existing-or-intended location for this path's thumbnail. `nil` only when the
    /// source file can't be stat'd (missing/unreadable), in which case there is
    /// nothing sensible to key on.
    private static func diskURL(for path: String, maxPixel: Int) -> URL? {
        let fm = FileManager.default
        guard let attrs = try? fm.attributesOfItem(atPath: path) else { return nil }
        let mtime = (attrs[.modificationDate] as? Date)?.timeIntervalSince1970 ?? 0
        let size = (attrs[.size] as? NSNumber)?.int64Value ?? 0
        // mtime+size in the key: a changed source file lands on a different filename,
        // so staleness is impossible by construction rather than by remembering to invalidate.
        let name = "\(pathHash(path))-\(Int(mtime))-\(size)-\(maxPixel)"
        return diskDir.appendingPathComponent(name, isDirectory: false)
    }

    private static func loadImage(at url: URL) -> NSImage? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let cgImage = CGImageSourceCreateImageAtIndex(
                  source, 0, [kCGImageSourceShouldCacheImmediately: true] as CFDictionary)
        else { return nil }
        return NSImage(cgImage: cgImage, size: NSSize(width: cgImage.width, height: cgImage.height))
    }

    private static func write(_ cgImage: CGImage, to url: URL) {
        let fm = FileManager.default
        try? fm.createDirectory(at: diskDir, withIntermediateDirectories: true)

        // JPEG is the whole point (small + fast to decode), but it has no alpha —
        // a transparent PNG would get a black box behind it. Pasted screenshots and
        // logos do carry alpha, so those need a format that keeps it.
        let hasAlpha: Bool
        switch cgImage.alphaInfo {
        case .none, .noneSkipFirst, .noneSkipLast: hasAlpha = false
        default:                                   hasAlpha = true
        }

        // For alpha, prefer HEIC over PNG: same transparency, a fraction of the bytes
        // (an observed 720px PNG thumbnail was 816KB — 4× the JPEGs, which defeats the
        // point of the tier). PNG stays as the fallback if HEIC encoding isn't available.
        if hasAlpha {
            if encode(cgImage, to: url, type: "public.heic", props: [
                kCGImageDestinationLossyCompressionQuality: jpegQuality
            ]) || encode(cgImage, to: url, type: "public.png", props: [:]) {
                pruneIfNeeded()
            }
            return
        }

        if encode(cgImage, to: url, type: "public.jpeg",
                  props: [kCGImageDestinationLossyCompressionQuality: jpegQuality]) {
            pruneIfNeeded()
        }
    }

    /// Returns false (and leaves no partial file) when the container can't be written,
    /// so the caller can fall back to another format instead of caching a corrupt entry.
    private static func encode(_ cgImage: CGImage, to url: URL,
                               type: String, props: [CFString: Any]) -> Bool {
        guard let dest = CGImageDestinationCreateWithURL(url as CFURL, type as CFString, 1, nil)
        else { return false }
        CGImageDestinationAddImage(dest, cgImage, props as CFDictionary)
        guard CGImageDestinationFinalize(dest) else {
            try? FileManager.default.removeItem(at: url)
            return false
        }
        return true
    }

    /// Bounded, cheap, and best-effort: only runs when the directory is over budget,
    /// and drops the least-recently-modified quarter so it isn't re-triggered constantly.
    private static func pruneIfNeeded() {
        let fm = FileManager.default
        guard let entries = try? fm.contentsOfDirectory(
            at: diskDir, includingPropertiesForKeys: [.contentModificationDateKey]),
            entries.count > maxDiskEntries
        else { return }

        let sorted = entries.sorted {
            let a = (try? $0.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate ?? .distantPast
            let b = (try? $1.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate ?? .distantPast
            return a < b
        }
        for url in sorted.prefix(maxDiskEntries / 4) { try? fm.removeItem(at: url) }
    }

    // MARK: - Keys

    private static func key(_ path: String, _ maxPixel: Int) -> NSString {
        "\(path)@\(maxPixel)" as NSString
    }

    /// Short, stable, filesystem-safe stand-in for an arbitrary absolute path.
    private static func pathHash(_ path: String) -> String {
        let digest = SHA256.hash(data: Data(path.utf8))
        return digest.prefix(8).map { String(format: "%02x", $0) }.joined()
    }
}
