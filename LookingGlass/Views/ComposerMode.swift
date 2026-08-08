import SwiftUI

/// What the composer is currently for.
///
/// Voice is a *mode*, not a button — the whole composer changes behaviour, so
/// the state lives here rather than being inferred from a mic icon. Slice 1 of
/// the composer rework uses it for tint; later slices hang the spectrograph,
/// the transcript line and the narration policy off the same value.
enum ComposerMode: Equatable {
    case text
    /// Latched on by clicking the mic. Survives sending, and Alice narrates
    /// her replies until it's switched off.
    case voice
    /// Mic held down — lasts only as long as the press, and Alice stays quiet.
    case voiceHeld

    var isVoice: Bool { self != .text }

    /// Only the latched mode narrates. A press-and-hold is a quick aside, and
    /// having Alice start talking after one would be startling rather than
    /// conversational.
    var narratesReplies: Bool { self == .voice }
}

/// The composer's mode wash.
///
/// Deliberately a *tint* and not a fill: the composer sits on glass, and the
/// point is a shift in temperature you notice at the edge of vision, not a
/// coloured box competing with the text.
enum ComposerTint {
    /// Alice's dress, sampled from the splash art (`alice-full-glow.png`) —
    /// #90CCF0.
    static let text = Color(red: 144 / 255, green: 204 / 255, blue: 240 / 255)

    /// The warm counterpart, and literally the same channels reversed —
    /// #F0CC90. Cream-apricot: unmistakably "not text mode" at a glance while
    /// staying in the same family, since a mode wash shouldn't feel like a
    /// different app.
    static let voice = Color(red: 240 / 255, green: 204 / 255, blue: 144 / 255)

    static func color(for mode: ComposerMode) -> Color {
        // Held and latched share a wash — the distinction between them is
        // behavioural, and a hold is over in well under a second, so a separate
        // colour would read as a flicker rather than information.
        mode.isVoice ? voice : text
    }

    /// Light enough to read as temperature rather than paint. Voice runs a
    /// touch stronger because it is the exceptional state and should be
    /// obvious that it's on.
    ///
    /// Text was 0.07 and Yogi couldn't see it — better than the flat grey it
    /// replaced, but not actually reading as a tint. 0.12 keeps it quiet while
    /// making it present.
    static func opacity(for mode: ComposerMode, scheme: ColorScheme) -> Double {
        let base: Double = mode.isVoice ? 0.16 : 0.12
        // Dark mode needs less: a light tint over a dark ground reads much
        // hotter than the same value over white.
        return scheme == .dark ? base * 0.72 : base
    }
}
