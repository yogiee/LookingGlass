import AppKit
import CoreImage
import ImageIO

/// Core Image editing for the lightbox — Lanczos resize (up/down) + optional light sharpen +
/// export to PNG / JPEG / HEIF. GPU-accelerated, no Python. Tier-1 util (returns nil/false on
/// failure). This is the frontend "display-side editing" home; the generation-side PIL stays in
/// OllamaMCP (a relocation, not a swap). See WORKSPACE/apple-native/01-imaging-and-vision.md §B.
///
/// Resize policy (visually confirmed 2026-07-04): downscale unconstrained; upscale capped at 2×
/// Lanczos; sharpen is a light `CISharpenLuminance` (0.4) — no heavy halos. Real detail-adding
/// upscale of generated art is Slice 3 (`SuperResolutionService`, Apple 4×), not this.
enum CoreImageService {
    private static let colorSpace = CGColorSpace(name: CGColorSpace.sRGB)!
    private static let context = CIContext(options: [.workingColorSpace: colorSpace])

    enum ExportFormat: String, CaseIterable { case png = "PNG", jpeg = "JPEG", heif = "HEIF" }

    /// Full-image crop rect (a no-op default).
    static let fullCrop = CGRect(x: 0, y: 0, width: 1, height: 1)

    /// Crop (normalized, top-left origin) → Lanczos scale → optional light luminance sharpen.
    /// Returns the processed CIImage (cropped to integral extent).
    private static func process(path: String, crop: CGRect, scale: CGFloat, sharpen: Bool) -> CIImage? {
        guard let src = CIImage(contentsOf: URL(fileURLWithPath: path)) else { return nil }
        var img = src
        // Crop first. The UI rect is normalized with a TOP-left origin; CIImage is bottom-left, so
        // flip Y. Re-origin to (0,0) after cropping so the downstream scale/export is clean.
        if crop != fullCrop {
            let e = src.extent
            let px = CGRect(x: e.minX + crop.minX * e.width,
                            y: e.minY + (1 - crop.maxY) * e.height,
                            width: crop.width * e.width,
                            height: crop.height * e.height).integral
            img = img.cropped(to: px).transformed(by: CGAffineTransform(translationX: -px.minX, y: -px.minY))
        }
        if abs(scale - 1) > 0.001 {
            let f = CIFilter(name: "CILanczosScaleTransform")!
            f.setValue(img, forKey: kCIInputImageKey)
            f.setValue(scale, forKey: kCIInputScaleKey)
            f.setValue(1.0, forKey: kCIInputAspectRatioKey)
            img = f.outputImage ?? img
        }
        if sharpen {
            let f = CIFilter(name: "CISharpenLuminance")!
            f.setValue(img, forKey: kCIInputImageKey)
            f.setValue(0.5, forKey: kCIInputSharpnessKey)   // light — no heavy halos
            img = f.outputImage ?? img
        }
        return img.cropped(to: img.extent.integral)
    }

    /// The image's true pixel dimensions (for the resize dimensions readout).
    static func pixelSize(path: String) -> CGSize? {
        CIImage(contentsOf: URL(fileURLWithPath: path))?.extent.size
    }

    /// Linear blend of two same-size images (for the upscale review's Detail slider): `amount` 1.0 = all
    /// `top` (the fully sharpened upscale), 0.0 = all `base` (the plain upscale).
    static func blend(_ base: NSImage?, over top: NSImage?, amount t: Double) -> NSImage? {
        guard let top else { return base }
        guard let base, t < 0.999,
              let bcg = base.cgImage(forProposedRect: nil, context: nil, hints: nil),
              let tcg = top.cgImage(forProposedRect: nil, context: nil, hints: nil),
              let f = CIFilter(name: "CIDissolveTransition") else { return top }
        let bci = CIImage(cgImage: bcg)
        f.setValue(bci, forKey: kCIInputImageKey)                     // t=0 → base
        f.setValue(CIImage(cgImage: tcg), forKey: kCIInputTargetImageKey)  // t=1 → top
        f.setValue(max(0, t), forKey: kCIInputTimeKey)
        guard let out = f.outputImage, let cg = context.createCGImage(out, from: bci.extent) else { return top }
        return NSImage(cgImage: cg, size: bci.extent.size)
    }

    /// Encode an NSImage as PNG data.
    static func pngData(_ image: NSImage) -> Data? {
        guard let tiff = image.tiffRepresentation, let bm = NSBitmapImageRep(data: tiff) else { return nil }
        return bm.representation(using: .png, properties: [:])
    }

    /// A preview NSImage of the processed result — for live display in the lightbox while resizing.
    static func preview(path: String, crop: CGRect = fullCrop, scale: CGFloat, sharpen: Bool) -> NSImage? {
        guard let ci = process(path: path, crop: crop, scale: scale, sharpen: sharpen),
              let cg = context.createCGImage(ci, from: ci.extent) else { return nil }
        return NSImage(cgImage: cg, size: ci.extent.size)
    }

    /// Export the processed result to a new file (the original is never touched).
    @discardableResult
    static func export(path: String, crop: CGRect = fullCrop, scale: CGFloat, sharpen: Bool,
                       as format: ExportFormat, to url: URL) -> Bool {
        guard let ci = process(path: path, crop: crop, scale: scale, sharpen: sharpen) else { return false }
        // Highest quality — no additional compression beyond each format's nature. PNG is lossless;
        // JPEG/HEIF get an explicit 1.0 (Yogi's call: don't re-compress exports). The empty-options
        // defaults were an uncontrolled ~0.9 (JPEG) / ~0.8 (HEIF) — now pinned.
        let maxQuality: [CIImageRepresentationOption: Any] =
            [CIImageRepresentationOption(rawValue: kCGImageDestinationLossyCompressionQuality as String): 1.0]
        do {
            switch format {
            case .png:
                try context.writePNGRepresentation(of: ci, to: url, format: .RGBA8, colorSpace: colorSpace)
            case .jpeg:
                try context.writeJPEGRepresentation(of: ci, to: url, colorSpace: colorSpace, options: maxQuality)
            case .heif:
                try context.writeHEIFRepresentation(of: ci, to: url, format: .RGBA8, colorSpace: colorSpace, options: maxQuality)
            }
            return true
        } catch {
            return false
        }
    }
}
