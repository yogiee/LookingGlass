import SwiftUI
import AppKit

/// Controller the SwiftUI formatting toolbar uses to manipulate the live
/// NSTextView (wrap selection in markdown, focus). Avoids round-tripping
/// selection state through SwiftUI.
@MainActor
final class ChatInputController: ObservableObject {
    weak var textView: NSTextView?

    func wrap(prefix: String, suffix: String) {
        guard let tv = textView else { return }
        let range = tv.selectedRange()
        let ns = tv.string as NSString
        let selected = ns.substring(with: range)
        let replacement = prefix + selected + suffix

        guard tv.shouldChangeText(in: range, replacementString: replacement) else { return }
        tv.replaceCharacters(in: range, with: replacement)
        tv.didChangeText()

        // Selection had text → keep it selected inside the markers.
        // Empty selection → drop the cursor between the markers.
        let prefixLen = (prefix as NSString).length
        if selected.isEmpty {
            tv.setSelectedRange(NSRange(location: range.location + prefixLen, length: 0))
        } else {
            tv.setSelectedRange(NSRange(location: range.location + prefixLen, length: (selected as NSString).length))
        }
        tv.window?.makeFirstResponder(tv)
    }

    func focus() {
        guard let tv = textView else { return }
        tv.window?.makeFirstResponder(tv)
    }
}

/// NSTextView subclass: Enter sends, Shift+Enter inserts a newline.
/// Image paste is intercepted and routed to `onImagePaste` instead of being
/// embedded as an attachment in the text.
final class SendingTextView: NSTextView {
    var onSend: (() -> Void)?
    var onImagePaste: ((NSImage) -> Void)?

    override func keyDown(with event: NSEvent) {
        // keyCode 36 = Return. Plain Return sends; Shift+Return falls through to
        // the default (inserts a line break).
        if event.keyCode == 36, !event.modifierFlags.contains(.shift) {
            onSend?()
            return
        }
        super.keyDown(with: event)
    }

    override func paste(_ sender: Any?) {
        let pb = NSPasteboard.general
        if let image = NSImage(pasteboard: pb) {
            onImagePaste?(image)
            return   // don't embed as an attachment in the text
        }
        super.paste(sender)
    }
}

struct ChatInputEditor: NSViewRepresentable {
    @Binding var text: String
    @Binding var height: CGFloat
    let fontSize: CGFloat
    let lineHeight: CGFloat
    let fontChoice: ChatFontChoice
    let minHeight: CGFloat
    let maxHeight: CGFloat
    let controller: ChatInputController
    var onSend: () -> Void
    var onImagePaste: ((NSImage) -> Void)?
    var onFocusChange: (Bool) -> Void

    func makeNSView(context: Context) -> NSScrollView {
        let scroll = NSScrollView()
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = false
        scroll.hasHorizontalScroller = false
        scroll.borderType = .noBorder
        scroll.autohidesScrollers = true

        let tv = SendingTextView()
        tv.onSend = onSend
        tv.onImagePaste = onImagePaste
        tv.delegate = context.coordinator
        tv.drawsBackground = false
        tv.isRichText = false
        tv.allowsUndo = true
        tv.textContainerInset = NSSize(width: 4, height: 7)
        tv.isVerticallyResizable = true
        tv.isHorizontallyResizable = false
        tv.autoresizingMask = [.width]
        tv.textContainer?.widthTracksTextView = true
        tv.string = text

        controller.textView = tv
        context.coordinator.textView = tv
        applyAttributes(tv)

        scroll.documentView = tv
        DispatchQueue.main.async { context.coordinator.recomputeHeight() }
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        context.coordinator.parent = self   // refresh stale parent (AppKit/SwiftUI bridge)
        guard let tv = scroll.documentView as? SendingTextView else { return }
        tv.onSend = onSend
        tv.onImagePaste = onImagePaste
        if tv.string != text {
            tv.string = text
        }
        applyAttributes(tv)
        DispatchQueue.main.async { context.coordinator.recomputeHeight() }
    }

    private func applyAttributes(_ tv: NSTextView) {
        let para = NSMutableParagraphStyle()
        para.lineHeightMultiple = lineHeight
        let attrs: [NSAttributedString.Key: Any] = [
            .font: fontChoice.nsFont(fontSize),
            .paragraphStyle: para,
            .foregroundColor: NSColor.labelColor,
            .kern: ChatFont.tracking(fontSize),
        ]
        tv.typingAttributes = attrs
        let full = NSRange(location: 0, length: (tv.string as NSString).length)
        tv.textStorage?.setAttributes(attrs, range: full)
    }

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    final class Coordinator: NSObject, NSTextViewDelegate {
        var parent: ChatInputEditor
        weak var textView: NSTextView?

        init(_ parent: ChatInputEditor) { self.parent = parent }

        func textDidChange(_ notification: Notification) {
            guard let tv = notification.object as? NSTextView else { return }
            parent.text = tv.string
            recomputeHeight()
        }

        func textDidBeginEditing(_ notification: Notification) { parent.onFocusChange(true) }
        func textDidEndEditing(_ notification: Notification) { parent.onFocusChange(false) }

        func recomputeHeight() {
            guard let tv = textView, let lm = tv.layoutManager, let tc = tv.textContainer else { return }
            lm.ensureLayout(for: tc)
            let used = lm.usedRect(for: tc).height
            let target = min(max(used + tv.textContainerInset.height * 2, parent.minHeight), parent.maxHeight)
            if abs(target - parent.height) > 0.5 {
                parent.height = target
            }
        }
    }
}
