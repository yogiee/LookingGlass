import SwiftUI
import AppKit

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

    private let minZoom: CGFloat = 0.1
    private let maxZoom: CGFloat = 16.0

    private var image: NSImage? { NSImage(contentsOfFile: path) }
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
                        .frame(width: image.size.width * displayScale,
                               height: image.size.height * displayScale)
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
                toolbar.padding(.bottom, 22).opacity(presented ? 1 : 0)
            }
            .onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: { lightboxFrame = $0 }
            .onAppear {
                fitScale = computeFit(geo.size)
                startScrollMonitor()
                // Defer so fitScale + lightboxFrame settle before measuring the hero
                // start-state, then animate to the resting (centered) state.
                DispatchQueue.main.async {
                    withAnimation(.spring(response: 0.26, dampingFraction: 0.85)) { presented = true }
                }
            }
            .onDisappear { stopScrollMonitor(); popCursor() }
            .onChange(of: geo.size) { _, s in fitScale = computeFit(s) }
            .onChange(of: isZoomed) { _, zoomed in if !zoomed { popCursor() } }
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
        }
        .buttonStyle(.borderless)
        .font(.system(size: 13))
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(.ultraThinMaterial, in: Capsule())
        .overlay(Capsule().strokeBorder(Color.primary.opacity(0.12), lineWidth: 0.5))
    }

    // Fill the available window area (minus padding for the toolbar + close button),
    // so the image occupies ~95% of the height. The 1:1 button steps to native.
    private func computeFit(_ area: CGSize) -> CGFloat {
        guard let image, image.size.width > 0, image.size.height > 0,
              area.width > 80, area.height > 140 else { return 1 }
        let availW = area.width - 64
        let availH = area.height - 130
        return min(availW / image.size.width, availH / image.size.height)
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
