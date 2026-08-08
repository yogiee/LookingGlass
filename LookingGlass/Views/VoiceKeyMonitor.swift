import AppKit
import SwiftUI

/// Watches the SPACE bar while voice mode is armed.
///
/// Voice mode arms the mic; this decides when it actually captures. A physical
/// key is the one channel that can't be confused with speech content — which is
/// why it beats both silence-detection (background conversation means the mic
/// never hears silence, so auto-stop never fires) and wake-words (any phrase can
/// occur naturally in dictation).
///
/// Uses a local `NSEvent` monitor rather than `.onKeyPress` because the composer
/// has no focusable text field in voice mode, so there is nothing for SwiftUI's
/// key handling to attach to.
@MainActor
final class VoiceKeyMonitor: ObservableObject {
    /// SPACE has been held past the threshold — start capturing.
    var onHoldBegan: (() -> Void)?
    /// A held SPACE was released — stop and deliver.
    var onHoldEnded: (() -> Void)?
    /// Two quick taps — latch capture on, or off if already latched.
    var onDoubleTap: (() -> Void)?
    /// Gate. Nothing fires, and no key is swallowed, unless this is true.
    var isActive: () -> Bool = { false }

    private var monitor: Any?
    private var isDown = false
    private var didStartHold = false
    private var holdTask: Task<Void, Never>?
    private var lastTapAt: Date?

    /// Past this, a press is a hold rather than a tap.
    private static let holdThreshold: Duration = .milliseconds(220)
    /// Two taps inside this window are a double tap.
    private static let doubleTapWindow: TimeInterval = 0.38
    private static let spaceKeyCode: UInt16 = 49

    func install() {
        guard monitor == nil else { return }
        monitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .keyUp]) { [weak self] event in
            guard let self else { return event }
            // Returning nil swallows the key; returning the event passes it on.
            return self.handle(event) ? nil : event
        }
    }

    func remove() {
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
        holdTask?.cancel()
        isDown = false
        didStartHold = false
    }

    /// Returns true when the event was consumed.
    private func handle(_ event: NSEvent) -> Bool {
        guard event.keyCode == Self.spaceKeyCode, isActive() else { return false }
        // Never swallow SPACE while anything is being typed into — the review
        // field, the sidebar search, a sheet. `NSTextView` and the field editor
        // both descend from `NSText`.
        if NSApp.keyWindow?.firstResponder is NSText { return false }

        switch event.type {
        case .keyDown:
            // Auto-repeat fires continuously while held; only the first matters.
            guard !event.isARepeat else { return true }
            keyDown()
        case .keyUp:
            keyUp()
        default:
            return false
        }
        return true
    }

    private func keyDown() {
        isDown = true
        didStartHold = false

        if let last = lastTapAt, Date().timeIntervalSince(last) < Self.doubleTapWindow {
            lastTapAt = nil
            onDoubleTap?()
            return
        }

        // Deliberately does NOT start capturing yet. A tap might be the first
        // half of a double tap, and starting then cancelling the audio session
        // twice in quick succession races its own async setup.
        holdTask?.cancel()
        holdTask = Task { [weak self] in
            try? await Task.sleep(for: Self.holdThreshold)
            guard let self, !Task.isCancelled, self.isDown else { return }
            self.didStartHold = true
            self.onHoldBegan?()
        }
    }

    private func keyUp() {
        isDown = false
        holdTask?.cancel()
        if didStartHold {
            didStartHold = false
            lastTapAt = nil
            onHoldEnded?()
        } else {
            // Too short to be a hold — remember it in case a second tap follows.
            lastTapAt = Date()
        }
    }
}
