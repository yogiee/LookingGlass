import Foundation

/// Decides how much of a reply is worth *hearing*, as opposed to reading.
///
/// The obvious rule — speak the first N words — is wrong, and the chat history
/// says so. Measured across a real twelve-turn conversation: **six of Alice's
/// twelve replies were pure prose with no structure at all**, running 117 to 228
/// words, and 64% of all words written were prose. A 150-word cap would have
/// truncated half of the replies that were perfectly good spoken, mid-thought,
/// for no reason at all.
///
/// **Form is the signal, not length.** Flowing prose is speech. A bulleted
/// comparison is a reading construct — something you scan, not something you
/// hear — and stays on screen no matter how short it is.
///
/// This also ages well against a better engine. A word cap has to be re-tuned
/// every time the voice improves, because 150 words of `AVSpeechSynthesizer` and
/// 150 words of a neural voice are different experiences. A form-based split
/// never needs retuning: it isn't judging tolerance, it's routing content to the
/// sense it was written for.
enum SpokenLayer {

    /// The speakable reduction of a reply, with a short note when structure was
    /// deliberately left behind.
    static func make(from markdown: String) -> String {
        // ⚠ Not `let blocks = blocks(in:)` — naming the local after the function
        // it calls compiles cleanly and then traps at runtime.
        let parsed = blocks(in: markdown)

        // A horizontal rule marks the boundary between what's said and what's
        // shown. Form detection alone leaves prose *after* a dropped list
        // orphaned — it refers back to something the listener never heard, which
        // is what made the reading jump. An explicit boundary lets Alice keep
        // the spoken half continuous instead.
        //
        // Safe to honour unconditionally: 1 assistant message in 205 of real
        // history uses a rule at all, and that one already separates a spoken
        // lead-in from a data block.
        var screenOnly = false
        var prose: [Block] = []
        var structure: [Block] = []
        for block in parsed {
            if block.isRule { screenOnly.toggle(); continue }
            if screenOnly || block.isStructure { structure.append(block) } else { prose.append(block) }
        }

        // Nothing but structure — a bare list or a lone code block. Saying only
        // "it's on screen" would be useless, so fall back to reading what there
        // is; the reducer already strips the syntax.
        guard !prose.isEmpty else { return SpeechText.make(from: markdown) }

        let spoken = SpeechText.make(from: prose.map(\.text).joined(separator: "\n\n"))
        guard !spoken.isEmpty else { return SpeechText.make(from: markdown) }

        // Small asides get dropped silently; a substantial block gets
        // acknowledged. Prose before a list usually ends on a colon ("here's how
        // those break down:"), and trailing off into silence there sounds like
        // she lost her thread rather than chose not to read it out.
        let omitted = structure.reduce(0) { $0 + $1.wordCount }
        guard omitted >= Self.acknowledgeThreshold else { return spoken }
        return spoken + " " + note(for: structure)
    }

    /// Named by kind — "the code is on screen" is more use than "the details
    /// are" when what's waiting is a code block.
    private static func note(for structure: [Block]) -> String {
        if structure.contains(where: \.isCode) { return "The code is on screen." }
        if structure.contains(where: \.isTable) { return "The table is on screen." }
        return "The details are on screen."
    }

    /// Below this many omitted words, silence is fine — a two-item list isn't
    /// worth interrupting the flow to mention.
    private static let acknowledgeThreshold = 25

    // MARK: - Blocks

    struct Block {
        let text: String
        let isCode: Bool
        let isTable: Bool
        let isList: Bool
        /// A horizontal rule — the spoken/shown boundary marker.
        let isRule: Bool

        var isStructure: Bool { isCode || isTable || isList }
        var wordCount: Int { text.split { !$0.isLetter && !$0.isNumber }.count }
    }

    /// Split into paragraph-sized blocks. Fenced code is held together even
    /// though it contains blank lines, or a code sample would be shredded into
    /// fragments that each look like prose.
    static func blocks(in markdown: String) -> [Block] {
        var blocks: [Block] = []
        var current: [String] = []
        var inFence = false

        func flush() {
            guard !current.isEmpty else { return }
            blocks.append(classify(current))
            current = []
        }

        for raw in markdown.components(separatedBy: .newlines) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("```") || line.hasPrefix("~~~") {
                inFence.toggle()
                current.append(raw)
                // A closing fence ends the block; an opening one starts it.
                if !inFence { flush() }
                continue
            }
            if inFence {
                current.append(raw)
            } else if line.isEmpty {
                flush()
            } else {
                current.append(raw)
            }
        }
        flush()
        return blocks
    }

    private static func classify(_ lines: [String]) -> Block {
        let text = lines.joined(separator: "\n")
        let trimmed = lines.map { $0.trimmingCharacters(in: .whitespaces) }

        let isCode = trimmed.contains { $0.hasPrefix("```") || $0.hasPrefix("~~~") }
        // A table needs at least a couple of cells on a line; a single stray
        // pipe in prose shouldn't condemn the paragraph.
        let isTable = trimmed.contains { $0.filter { $0 == "|" }.count >= 2 }
        // One list marker is enough — a "prose + bullets" block is exactly the
        // shape we want to route to the screen.
        let isList = trimmed.contains { isListMarker($0) }
        let isRule = trimmed.count == 1 && isThematicBreak(trimmed[0])

        return Block(text: text, isCode: isCode, isTable: isTable, isList: isList, isRule: isRule)
    }

    /// `---`, `***`, `___` — three or more of one mark, nothing else.
    private static func isThematicBreak(_ line: String) -> Bool {
        let stripped = line.filter { !$0.isWhitespace }
        guard stripped.count >= 3 else { return false }
        return stripped.allSatisfy { $0 == "-" } || stripped.allSatisfy { $0 == "*" }
            || stripped.allSatisfy { $0 == "_" }
    }

    private static func isListMarker(_ line: String) -> Bool {
        guard let first = line.first else { return false }
        if first == "*" || first == "-" || first == "•" || first == "+" {
            // "- item" is a bullet; "-- something" or "*emphasis*" is not.
            let rest = line.dropFirst()
            return rest.first == " "
        }
        // "1. " / "2) "
        let digits = line.prefix { $0.isNumber }
        guard !digits.isEmpty, digits.count <= 2 else { return false }
        let after = line.dropFirst(digits.count)
        guard let mark = after.first, mark == "." || mark == ")" else { return false }
        return after.dropFirst().first == " "
    }
}
