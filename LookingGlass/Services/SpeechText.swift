import Foundation

/// Turns chat markdown into something worth *hearing*.
///
/// TTS reads literally: asterisks, backticks and pipes get vocalised ("star star
/// Done star star"), URLs become "h t t p s colon slash slash", and emoji are read
/// out by name. So the spoken layer is a deliberate reduction of the written one —
/// structure, code and tables are dropped rather than narrated, because a listener
/// can't use them anyway.
///
/// Pure and side-effect free by design: the streaming path (Sprint 3B) will feed
/// sentence-sized chunks through the same reducer.
enum SpeechText {

    /// Speakable prose for a markdown message. Returns "" when there is nothing
    /// worth speaking (e.g. the message is entirely a fenced code block).
    static func make(from markdown: String) -> String {
        var lines: [String] = []
        var inFence = false

        for raw in markdown.components(separatedBy: .newlines) {
            let line = raw.trimmingCharacters(in: .whitespaces)

            // Fenced code — skip the fence markers and everything between them.
            if line.hasPrefix("```") || line.hasPrefix("~~~") {
                inFence.toggle()
                continue
            }
            if inFence { continue }

            // Table rows and thematic breaks carry no spoken meaning.
            if line.hasPrefix("|") || isThematicBreak(line) { continue }

            if line.isEmpty {
                lines.append("")
                continue
            }

            var text = stripBlockMarkers(line)
            text = inlineClean(text)
            text = text.trimmingCharacters(in: .whitespaces)
            guard !text.isEmpty else { continue }

            // Headings and list items get a full stop so the synthesiser pauses
            // instead of running them into the next line.
            lines.append(needsPause(line) ? withPause(text) : text)
        }

        return collapse(lines)
    }

    // MARK: - Block level

    /// `***`, `---`, `___` rules (three or more, nothing else on the line).
    private static func isThematicBreak(_ line: String) -> Bool {
        guard let first = line.first, "*-_".contains(first) else { return false }
        let stripped = line.filter { !$0.isWhitespace }
        return stripped.count >= 3 && stripped.allSatisfy { $0 == first }
    }

    /// True for lines whose spoken form should end in a pause — headings and list items.
    private static func needsPause(_ line: String) -> Bool {
        line.hasPrefix("#") || isListItem(line)
    }

    private static func isListItem(_ line: String) -> Bool {
        if let f = line.first, "-*+".contains(f) {
            // "- item", not "-5 degrees"
            return line.dropFirst().first == " "
        }
        return orderedItem.firstMatch(in: line, range: line.nsRange) != nil
    }

    /// Strip leading heading hashes, blockquote arrows and list bullets.
    private static func stripBlockMarkers(_ line: String) -> String {
        var s = line

        // Blockquotes can nest: "> > quoted"
        while s.hasPrefix(">") {
            s = String(s.dropFirst()).trimmingCharacters(in: .whitespaces)
        }
        // ATX headings
        if s.hasPrefix("#") {
            s = String(s.drop(while: { $0 == "#" })).trimmingCharacters(in: .whitespaces)
        }
        // Bullets
        if let f = s.first, "-*+".contains(f), s.dropFirst().first == " " {
            s = String(s.dropFirst()).trimmingCharacters(in: .whitespaces)
        }
        // Ordered items — drop the numeral, it's list scaffolding, not content.
        if let m = orderedItem.firstMatch(in: s, range: s.nsRange), let r = Range(m.range, in: s) {
            s = String(s[r.upperBound...])
        }
        // Task-list checkboxes
        if s.hasPrefix("[ ] ") { s = String(s.dropFirst(4)) }
        if s.hasPrefix("[x] ") || s.hasPrefix("[X] ") { s = String(s.dropFirst(4)) }

        return s
    }

    private static func withPause(_ s: String) -> String {
        guard let last = s.last, !".!?:;,".contains(last) else { return s }
        return s + "."
    }

    // MARK: - Inline level

    /// Order matters: images before links (else `![a](b)` leaves a stray "!"),
    /// links before bare-URL removal (else the URL inside `[a](b)` is eaten first).
    private static func inlineClean(_ input: String) -> String {
        var s = input
        s = image.stringByReplacingMatches(in: s, range: s.nsRange, withTemplate: "")
        s = imageMarker.stringByReplacingMatches(in: s, range: s.nsRange, withTemplate: "")
        s = footnote.stringByReplacingMatches(in: s, range: s.nsRange, withTemplate: "")
        s = link.stringByReplacingMatches(in: s, range: s.nsRange, withTemplate: "$1")
        s = autolink.stringByReplacingMatches(in: s, range: s.nsRange, withTemplate: "")
        s = bareURL.stringByReplacingMatches(in: s, range: s.nsRange, withTemplate: "")
        s = inlineCode.stringByReplacingMatches(in: s, range: s.nsRange, withTemplate: "$1")
        s = bold.stringByReplacingMatches(in: s, range: s.nsRange, withTemplate: "$1")
        s = boldAlt.stringByReplacingMatches(in: s, range: s.nsRange, withTemplate: "$1")
        s = strike.stringByReplacingMatches(in: s, range: s.nsRange, withTemplate: "$1")
        s = italic.stringByReplacingMatches(in: s, range: s.nsRange, withTemplate: "$1")
        s = italicAlt.stringByReplacingMatches(in: s, range: s.nsRange, withTemplate: "$1")
        s = htmlTag.stringByReplacingMatches(in: s, range: s.nsRange, withTemplate: "")
        s = stripEmoji(s)
        s = s.replacingOccurrences(of: "&nbsp;", with: " ")
        return s
    }

    /// Emoji read aloud as their CLDR names ("grinning face with smiling eyes"),
    /// which derails a sentence. Digits and `#`/`*` carry Emoji=Yes too, so they're
    /// excluded by the codepoint floor.
    private static func stripEmoji(_ s: String) -> String {
        var out = String.UnicodeScalarView()
        for scalar in s.unicodeScalars {
            let p = scalar.properties
            let isPictograph = p.isEmojiPresentation || (p.isEmoji && scalar.value >= 0x2000)
            let isModifier = p.isEmojiModifier || p.isEmojiModifierBase
                || scalar.value == 0xFE0F || scalar.value == 0xFE0E || scalar.value == 0x200D
            if isPictograph || isModifier { continue }
            out.append(scalar)
        }
        return String(out)
    }

    // MARK: - Assembly

    /// Join lines, collapsing runs of blank lines into a single paragraph break and
    /// squeezing the whitespace the strippers leave behind.
    private static func collapse(_ lines: [String]) -> String {
        var out: [String] = []
        for line in lines {
            if line.isEmpty {
                if out.last?.isEmpty == false { out.append("") }
            } else {
                out.append(line)
            }
        }
        while out.last?.isEmpty == true { out.removeLast() }
        while out.first?.isEmpty == true { out.removeFirst() }

        let joined = out.joined(separator: "\n")
        let squeezed = multiSpace.stringByReplacingMatches(
            in: joined, range: joined.nsRange, withTemplate: " "
        )
        return squeezed.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // MARK: - Patterns
    // Authored literals — a compile failure here is a programmer error, not runtime input.

    private static func rx(_ pattern: String) -> NSRegularExpression {
        try! NSRegularExpression(pattern: pattern)
    }

    private static let orderedItem  = rx(#"^\d{1,3}[.)]\s+"#)
    private static let image        = rx(#"!\[[^\]]*\]\([^)]*\)"#)
    private static let imageMarker  = rx(#"\[Image:[^\]]*\]"#)
    private static let footnote     = rx(#"\[\^[^\]]+\]"#)
    private static let link         = rx(#"\[([^\]]*)\]\([^)]*\)"#)
    private static let autolink     = rx(#"<https?://[^>]*>"#)
    private static let bareURL      = rx(#"\bhttps?://\S+"#)
    private static let inlineCode   = rx("`+([^`]*)`+")
    private static let bold         = rx(#"\*\*([^*]+)\*\*"#)
    private static let boldAlt      = rx(#"__([^_]+)__"#)
    private static let strike       = rx(#"~~([^~]+)~~"#)
    private static let italic       = rx(#"\*([^*]+)\*"#)
    // Underscore italics only outside words, so snake_case survives intact.
    private static let italicAlt    = rx(#"(?<![A-Za-z0-9_])_([^_]+)_(?![A-Za-z0-9_])"#)
    private static let htmlTag      = rx(#"</?[A-Za-z][^>]*>"#)
    private static let multiSpace   = rx(#"[ \t]{2,}"#)
}

private extension String {
    var nsRange: NSRange { NSRange(startIndex..., in: self) }
}
