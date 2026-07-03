import SwiftUI
import AppKit
import UniformTypeIdentifiers

/// Extracts on-disk image file paths from a message so they can be rendered
/// inline. Two sources:
///   • Tool-call results — e.g. an image-gen tool returns the saved PNG path.
///   • Message content — `[Image: /path]` markers (user uploads) or any bare
///     absolute image path the model surfaced in prose.
/// Only paths that actually exist on disk are returned, de-duplicated in order.
enum ImagePathScanner {
    private static let regex: NSRegularExpression = {
        let pattern = #"(~|/)[^\s"'<>|\]]+\.(png|jpg|jpeg|gif|webp|heic|bmp|tiff)"#
        return try! NSRegularExpression(pattern: pattern, options: [.caseInsensitive])
    }()

    static func paths(in message: Message) -> [String] {
        var found: [String] = []
        for call in message.toolCalls where call.isComplete && call.success {
            found.append(contentsOf: matches(in: call.result))
        }
        found.append(contentsOf: matches(in: message.content))

        var seen = Set<String>()
        return found.filter { path in
            let resolved = (path as NSString).expandingTildeInPath
            guard FileManager.default.fileExists(atPath: resolved) else { return false }
            return seen.insert(resolved).inserted
        }
    }

    static func stripMarkers(_ text: String) -> String {
        let cleaned = text.replacingOccurrences(
            of: #"\[Image:\s*[^\]]+\]"#,
            with: "",
            options: .regularExpression
        )
        return cleaned.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func matches(in text: String) -> [String] {
        guard !text.isEmpty else { return [] }
        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        return regex.matches(in: text, range: range).compactMap {
            Range($0.range, in: text).map { String(text[$0]) }
        }
    }
}

/// Holds the image currently shown in the full-window lightbox. Lifted to the app
/// root (like ReportPanelState) so the lightbox can cover the whole window — a
/// `.sheet` can only float a small panel. Injected via `.environmentObject`.
@MainActor
final class ImageViewerState: ObservableObject {
    @Published var path: String? = nil
    /// The thumbnail's on-screen frame (global coords) at tap time — lets the
    /// lightbox hero-zoom the image up from its position in the chat.
    private(set) var sourceRect: CGRect = .zero
    func show(_ p: String, from rect: CGRect = .zero) { sourceRect = rect; path = p }
    func dismiss() { path = nil }
}

/// A rounded, size-constrained thumbnail for an on-disk image. Tapping opens the
/// full-window lightbox.
struct InlineImageView: View {
    let path: String
    @EnvironmentObject private var viewer: ImageViewerState
    @State private var frameInWindow: CGRect = .zero

    private var resolvedPath: String { (path as NSString).expandingTildeInPath }
    private var image: NSImage? { NSImage(contentsOfFile: resolvedPath) }

    var body: some View {
        Group {
            if let image {
                Button { viewer.show(resolvedPath, from: frameInWindow) } label: {
                    Image(nsImage: image)
                        .resizable()
                        .scaledToFit()
                        .frame(maxWidth: 360, maxHeight: 360)
                        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                        .overlay(
                            RoundedRectangle(cornerRadius: 12, style: .continuous)
                                .strokeBorder(Color.primary.opacity(0.08), lineWidth: 1)
                        )
                }
                .buttonStyle(.plain)
                .help("Click to view")
                // Track the thumbnail's on-screen rect so the lightbox can grow from it.
                .onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: { frameInWindow = $0 }
            }
        }
    }
}

/// Full-window lightbox: dark overlay over the whole app window, image centered and
/// scaled to fill the available area, bottom toolbar (zoom / fit / 1:1 / copy /
/// reveal), close button top-right. Click the dark backdrop (or Esc) to dismiss.
/// Pan by dragging when zoomed past fit.
struct LightboxView: View {
    let path: String
    /// The thumbnail's on-screen frame the image hero-zooms up from. (Declared
    /// before onClose so the trailing-closure call site stays clean.)
    var sourceRect: CGRect = .zero
    let onClose: () -> Void

    // `zoom` multiplies the fill-to-window scale: 1.0 = image fills the available
    // area (the default). 1:1 sets it so displayScale == 1.0 (native pixels).
    @State private var zoom: CGFloat = 1.0
    @State private var lastZoom: CGFloat = 1.0
    @State private var fitScale: CGFloat = 1.0
    @State private var offset: CGSize = .zero
    @State private var lastOffset: CGSize = .zero
    @State private var copied = false
    @State private var scrollMonitor: Any?
    @State private var cursorPushed = false
    @State private var dragging = false
    @State private var presented = false
    @State private var lightboxFrame: CGRect = .zero

    // Resize mode (Core Image editing) — Slice 2a.
    @State private var resizeMode = false
    @State private var sliderPos: CGFloat = 2.0          // 0…4; evenly-spaced ticks (see below)
    @State private var sharpen = false
    @State private var exportFormat: CoreImageService.ExportFormat = .png
    @State private var previewImage: NSImage?            // Core Image-rendered quality preview
    @State private var areaSize: CGSize = .zero
    @State private var originalPixelSize: CGSize = .zero

    private let minZoom: CGFloat = 0.1
    private let maxZoom: CGFloat = 16.0
    // Slider is a 0…4 position with EVEN ticks mapping to these scales (position 2 = 1×, center).
    private let resizeTickScales: [CGFloat] = [0.5, 2.0/3.0, 1.0, 1.5, 2.0]
    private let resizeTickLabels = ["½×", "⅔×", "1×", "1.5×", "2×"]

    // The bitmap actually drawn (Core Image render when ready, else the original file). LAYOUT
    // (fit/frame/1:1) is driven by `layoutSize`, NOT this bitmap's size — so a slider drag scales
    // the viewport live and the render just upgrades quality in place (no jump).
    private var image: NSImage? { previewImage ?? NSImage(contentsOfFile: path) }
    private var resizeScale: CGFloat {
        let p = min(max(sliderPos, 0), 4)
        let i = min(Int(p), resizeTickScales.count - 2)
        let f = p - CGFloat(i)
        return resizeTickScales[i] + f * (resizeTickScales[i + 1] - resizeTickScales[i])
    }
    /// Target on-screen dimensions — original × resize factor while editing. Drives fit/framing so
    /// the viewport scales in sync with the slider before the quality render lands.
    private var layoutSize: CGSize {
        if resizeMode, originalPixelSize != .zero {
            return CGSize(width: originalPixelSize.width * resizeScale,
                          height: originalPixelSize.height * resizeScale)
        }
        return image?.size ?? .zero
    }
    private var previewKey: String { "\(resizeMode)_\(sliderPos)_\(sharpen)" }
    private var displayScale: CGFloat { fitScale * zoom }
    private var isZoomed: Bool { zoom > 1.0001 }

    var body: some View {
        GeometryReader { geo in
            let hero = heroTransform(geo)
            ZStack {
                // Backdrop — fades in; click outside the image to dismiss.
                Color.black.opacity(0.78)
                    .opacity(presented ? 1 : 0)
                    .contentShape(Rectangle())
                    .onTapGesture { animatedClose() }

                if let image {
                    Image(nsImage: image)
                        .resizable()
                        .interpolation(.high)
                        .frame(width: layoutSize.width * displayScale,
                               height: layoutSize.height * displayScale)
                        .offset(offset)
                        // Hero: on open, grow from the thumbnail's on-screen frame to
                        // centered-fit; on close, shrink back. Only when at fit zoom.
                        .scaleEffect(presented ? 1 : hero.scale, anchor: .center)
                        .offset(presented ? .zero : hero.offset)
                        .opacity(hero.useHero ? 1 : (presented ? 1 : 0))
                        .gesture(
                            DragGesture()
                                .onChanged { v in
                                    guard isZoomed else { return }
                                    if !dragging { dragging = true; NSCursor.closedHand.set() }
                                    offset = CGSize(width: lastOffset.width + v.translation.width,
                                                    height: lastOffset.height + v.translation.height)
                                }
                                .onEnded { _ in
                                    lastOffset = offset
                                    dragging = false
                                    if isZoomed { NSCursor.openHand.set() }
                                }
                        )
                        .simultaneousGesture(
                            MagnificationGesture()
                                .onChanged { v in zoom = clamp(lastZoom * v) }
                                .onEnded { _ in lastZoom = zoom; if !isZoomed { resetPan() } }
                        )
                        .onHover { inside in updateCursor(hovering: inside) }
                }
            }
            // Force to the window size + clip, so a zoomed image overflows-and-clips
            // rather than expanding the ZStack.
            .frame(width: geo.size.width, height: geo.size.height)
            .clipped()
            // Controls are OVERLAYS on the fixed-size frame, NOT ZStack siblings of
            // the image — otherwise the huge zoomed image drives the ZStack's layout
            // size and shoves them off-screen. As overlays they pin to the WINDOW.
            .overlay(alignment: .topTrailing) {
                Button(action: animatedClose) {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 24))
                        .foregroundStyle(.white.opacity(0.85))
                        .shadow(radius: 3)
                }
                .buttonStyle(.plain)
                .help("Close (Esc)")
                .padding(18)
                .opacity(presented ? 1 : 0)
            }
            .overlay(alignment: .bottom) {
                VStack(spacing: 10) {
                    if resizeMode {
                        resizeControls
                            .transition(.move(edge: .bottom).combined(with: .opacity))
                    }
                    toolbar
                }
                .padding(.bottom, 22)
                .opacity(presented ? 1 : 0)
            }
            .onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: { lightboxFrame = $0 }
            .onAppear {
                areaSize = geo.size
                originalPixelSize = CoreImageService.pixelSize(path: path) ?? .zero
                fitScale = computeFit(geo.size)
                startScrollMonitor()
                // Defer so fitScale + lightboxFrame settle before measuring the hero
                // start-state, then animate to the resting (centered) state.
                DispatchQueue.main.async {
                    withAnimation(.spring(response: 0.26, dampingFraction: 0.85)) { presented = true }
                }
            }
            .onDisappear { stopScrollMonitor(); popCursor() }
            .onChange(of: geo.size) { _, s in areaSize = s; fitScale = computeFit(s) }
            .onChange(of: isZoomed) { _, zoomed in if !zoomed { popCursor() } }
            // Re-render the Core Image preview when the resize params change (debounced, off-main),
            // so 1:1 shows the real output pixels. Cleared when resize is a no-op.
            // Debounced Core Image quality render — swaps the bitmap in place (layout unchanged).
            .task(id: previewKey) {
                guard resizeMode, resizeScale != 1.0 || sharpen else { previewImage = nil; return }
                try? await Task.sleep(for: .milliseconds(120))
                guard !Task.isCancelled else { return }
                let p = path, s = resizeScale, sh = sharpen
                let rendered = await Task.detached { CoreImageService.preview(path: p, scale: s, sharpen: sh) }.value
                guard !Task.isCancelled else { return }
                previewImage = rendered
            }
            // Slider → scale. Click (no drag) jump-snaps to the nearest tick; a drag is fine-grained
            // and snaps only when it lands near a tick. refit() rescales the viewport live in sync.
            // Snap is handled in the slider's binding setter; here we just rescale the viewport
            // live in sync with the slider.
            .onChange(of: sliderPos) { _, _ in refit() }
            .onChange(of: resizeMode) { _, on in
                if !on { sliderPos = 2.0; sharpen = false }   // reset to 1× on close
                refit()
            }
        }
        .ignoresSafeArea()
        // Keyboard shortcuts (hidden buttons register them while the lightbox is up).
        .background {
            Group {
                Button("", action: animatedClose).keyboardShortcut(.cancelAction)     // Esc
                Button("") { setZoom(zoom * 1.25) }.keyboardShortcut("=", modifiers: [])
                Button("") { setZoom(zoom * 1.25) }.keyboardShortcut("+", modifiers: [])
                Button("") { setZoom(zoom / 1.25) }.keyboardShortcut("-", modifiers: [])
                Button("") { setZoom(zoom * 1.25) }.keyboardShortcut("=", modifiers: .command)
                Button("") { setZoom(zoom / 1.25) }.keyboardShortcut("-", modifiers: .command)
                Button("") { setZoom(1.0) }.keyboardShortcut("0", modifiers: .command)             // fit
                Button("") { setZoom(fitScale > 0 ? 1 / fitScale : 1) }.keyboardShortcut("1", modifiers: .command)  // 1:1
            }
            .opacity(0)
        }
    }

    // Hero open/close: scale + offset that grows the image from the thumbnail's
    // on-screen frame to centered-fit. Only when at fit zoom (a zoomed image just
    // fades). Falls back to a gentle scale when no source frame was captured.
    private func heroTransform(_ geo: GeometryProxy) -> (scale: CGFloat, offset: CGSize, useHero: Bool) {
        guard let image, sourceRect != .zero, lightboxFrame != .zero, abs(zoom - 1) < 0.001 else {
            return (0.92, .zero, false)
        }
        let fitW = image.size.width * computeFit(geo.size)
        let scale = fitW > 0 ? sourceRect.width / fitW : 0.3
        return (scale,
                CGSize(width: sourceRect.midX - lightboxFrame.midX,
                       height: sourceRect.midY - lightboxFrame.midY),
                true)
    }

    private func animatedClose() {
        popCursor()
        withAnimation(.easeIn(duration: 0.15)) { presented = false }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { onClose() }
    }

    private func updateCursor(hovering: Bool) {
        if hovering && isZoomed {
            if !cursorPushed { NSCursor.openHand.push(); cursorPushed = true }
        } else {
            popCursor()
        }
    }

    private func popCursor() {
        if cursorPushed { NSCursor.pop(); cursorPushed = false }
    }

    // CMD + scroll to zoom (Mac-native). Local monitor lives only while shown.
    private func startScrollMonitor() {
        scrollMonitor = NSEvent.addLocalMonitorForEvents(matching: .scrollWheel) { event in
            guard event.modifierFlags.contains(.command) else { return event }
            let delta = event.scrollingDeltaY
            if delta != 0 {
                setZoom(zoom * (1 + delta * 0.01))
            }
            return nil  // consume so the chat behind doesn't scroll
        }
    }

    private func stopScrollMonitor() {
        if let m = scrollMonitor { NSEvent.removeMonitor(m); scrollMonitor = nil }
    }

    private var toolbar: some View {
        HStack(spacing: 12) {
            Button { setZoom(zoom / 1.25) } label: { Image(systemName: "minus.magnifyingglass") }
                .help("Zoom out")
            Text("\(Int((displayScale * 100).rounded()))%")
                .font(.system(size: 11, design: .monospaced))
                .foregroundStyle(.secondary)
                .frame(width: 44)
            Button { setZoom(zoom * 1.25) } label: { Image(systemName: "plus.magnifyingglass") }
                .help("Zoom in")
            Button { setZoom(1.0) } label: { Image(systemName: "arrow.up.left.and.arrow.down.right") }
                .help("Scale to fit")
            Button { setZoom(fitScale > 0 ? 1 / fitScale : 1) } label: { Image(systemName: "1.square") }
                .help("Actual size (100%)")

            Divider().frame(height: 16)

            Button { copyImage() } label: {
                Label(copied ? "Copied" : "Copy", systemImage: copied ? "checkmark" : "doc.on.doc")
            }
            .help("Copy image to clipboard")
            Button {
                NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)])
            } label: { Image(systemName: "folder") }
                .help("Reveal in Finder")
            Button {
                withAnimation(.easeInOut(duration: 0.18)) { resizeMode.toggle() }
            } label: {
                Image(systemName: "slider.horizontal.3")
                    .foregroundStyle(resizeMode ? Color.accentColor : Color.primary)
            }
            .help("Resize & export")
        }
        .buttonStyle(.borderless)
        .font(.system(size: 13))
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(.ultraThinMaterial, in: Capsule())
        .overlay(Capsule().strokeBorder(Color.primary.opacity(0.12), lineWidth: 0.5))
    }

    // Resize control row (Slice 2a): ½×…2× snap-slider with ticks · dimensions+scale · sharpen ·
    // format · Export.
    private var resizeControls: some View {
        HStack(spacing: 14) {
            Image(systemName: "photo").foregroundStyle(.secondary)
            VStack(spacing: 2) {
                Slider(
                    value: Binding(
                        get: { sliderPos },
                        set: { v in
                            // Continuous; snap only when it lands near a tick.
                            let r = v.rounded()
                            sliderPos = abs(v - r) < 0.12 ? r : v
                        }
                    ),
                    in: 0...4
                )
                .frame(width: 210)
                // Tick labels aligned to the thumb stops (offset for the knob inset).
                GeometryReader { g in
                    let inset: CGFloat = 11
                    ForEach(0..<resizeTickLabels.count, id: \.self) { i in
                        Text(resizeTickLabels[i])
                            .font(.system(size: 9)).foregroundStyle(.secondary).fixedSize()
                            .position(x: inset + (g.size.width - inset * 2) * CGFloat(i) / 4, y: 5)
                    }
                }
                .frame(width: 210, height: 11)
            }
            Text(dimensionsText)
                .font(.system(size: 12, design: .monospaced))
                .foregroundStyle(.secondary)
                .frame(width: 150, alignment: .leading)
            Toggle("Sharpen", isOn: $sharpen).toggleStyle(.checkbox)
            Picker("", selection: $exportFormat) {
                ForEach(CoreImageService.ExportFormat.allCases, id: \.self) { Text($0.rawValue).tag($0) }
            }
            .labelsHidden()
            .frame(width: 84)
            Button("Export…") { exportImage() }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
        }
        .font(.system(size: 13))
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(.ultraThinMaterial, in: Capsule())
        .overlay(Capsule().strokeBorder(Color.primary.opacity(0.12), lineWidth: 0.5))
    }

    private var dimensionsText: String {
        guard originalPixelSize != .zero else { return "" }
        let w = Int((originalPixelSize.width * resizeScale).rounded())
        let h = Int((originalPixelSize.height * resizeScale).rounded())
        return "\(w) × \(h)  (\(scaleLabel))"
    }
    private var scaleLabel: String {
        let r = sliderPos.rounded()
        if abs(sliderPos - r) < 0.001, let i = Int(exactly: r), resizeTickLabels.indices.contains(i) {
            return resizeTickLabels[i]
        }
        return String(format: "%.2f×", resizeScale)
    }

    private func exportImage() {
        let ext: String
        switch exportFormat {
        case .png:  ext = "png"
        case .jpeg: ext = "jpg"
        case .heif: ext = "heic"
        }
        let panel = NSSavePanel()
        panel.allowedContentTypes = [UTType(filenameExtension: ext) ?? .png]
        panel.canCreateDirectories = true
        let base = ((path as NSString).lastPathComponent as NSString).deletingPathExtension
        let w = Int((originalPixelSize.width * resizeScale).rounded())
        panel.nameFieldStringValue = "\(base)_\(w)px.\(ext)"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        CoreImageService.export(path: path, scale: resizeScale, sharpen: sharpen, as: exportFormat, to: url)
    }

    // Fill the available window area (minus padding for the toolbar + close button),
    // so the image occupies ~95% of the height. The 1:1 button steps to native.
    private func computeFit(_ area: CGSize) -> CGFloat {
        let sz = layoutSize
        guard sz.width > 0, sz.height > 0, area.width > 80, area.height > 140 else { return 1 }
        let availW = area.width - 64
        let availH = area.height - 130
        return min(availW / sz.width, availH / sz.height)
    }

    /// Recompute the fit scale for the current (possibly resized) image. If the viewer was at
    /// 1:1 (displayScale ≈ 1.0), re-pin to 1:1 so the resized image stays at actual pixels
    /// without a manual click; "fit" and other zoom levels keep their multiplier.
    private func refit() {
        let wasOneToOne = abs(fitScale * zoom - 1.0) < 0.02
        let newFit = computeFit(areaSize)
        fitScale = newFit
        if wasOneToOne, newFit > 0 {
            zoom = 1.0 / newFit
            lastZoom = zoom
        }
    }

    private func setZoom(_ value: CGFloat) {
        zoom = clamp(value)
        lastZoom = zoom
        if !isZoomed { resetPan() }
    }

    private func resetPan() {
        offset = .zero
        lastOffset = .zero
    }

    private func clamp(_ value: CGFloat) -> CGFloat { min(max(value, minZoom), maxZoom) }

    private func copyImage() {
        guard let image else { return }
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.writeObjects([image])
        copied = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { copied = false }
    }
}
