import SwiftUI

/// In-chat search (the top pill's magnifier, ⌘F). Searches the open conversation's
/// messages in memory — no sidecar, no database — and is separate from the sidebar's
/// history-wide FTS search.
///
/// Highlighting rides on MarkdownUI, which has no highlight style of its own: matches
/// are wrapped in GFM strikethrough (`~~…~~`) and, while a search is open, the bubble's
/// theme renders strikethrough as a highlight instead of a line. Matches inside code,
/// link destinations and URLs are left alone, because wrapping them would break the
/// markup. A genuine strikethrough in a matching message also shows as highlighted
/// while the search is open; that's rare and only lasts as long as the search.
enum ChatSearch {
    static let highlightColor = Color.yellow.opacity(0.42)
    static let currentMatchColor = Color.orange

    private static let options: String.CompareOptions = [.caseInsensitive, .diacriticInsensitive]

    /// Non-overlapping occurrences of `query` in `text`.
    static func occurrences(of query: String, in text: String) -> Int {
        guard !query.isEmpty else { return 0 }
        var count = 0
        var searchRange = text.startIndex..<text.endIndex
        while let r = text.range(of: query, options: options, range: searchRange) {
            count += 1
            searchRange = r.upperBound..<text.endIndex
        }
        return count
    }

    /// The text a message is searched in: what the bubble shows, minus `[Image: …]` markers.
    static func searchableText(_ message: Message) -> String {
        ImagePathScanner.stripMarkers(message.content)
    }

    // MARK: - Marking

    /// Spans on a line that must not be touched: inline code, link destinations,
    /// autolinks / HTML tags, bare URLs, and entities.
    private static let protectedPattern: NSRegularExpression = {
        let parts = [
            #"(`+)[^`]*?\1"#,                 // inline code spans
            #"\]\([^)\n]*\)"#,                  // link / image destinations
            #"<[^>\n]+>"#,                      // autolinks and inline HTML
            #"(?:https?|ftp)://\S+|www\.\S+"#,  // bare URLs (GFM autolinks them)
            #"&#?\w+;"#,                        // HTML entities
            #"^\s*\[[^\]]+\]:\s*\S+"#,          // reference link definitions
        ]
        return try! NSRegularExpression(pattern: parts.joined(separator: "|"))
    }()

    /// `markdown` with every safe occurrence of `query` wrapped in `~~…~~`.
    static func mark(_ markdown: String, query: String) -> String {
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty, !q.contains("~"), !q.contains("\n") else { return markdown }

        var inFence = false
        let lines = markdown.components(separatedBy: "\n").map { line -> String in
            let t = line.trimmingCharacters(in: .whitespaces)
            if t.hasPrefix("```") || t.hasPrefix("~~~") {
                inFence.toggle()
                return line
            }
            return inFence ? line : markLine(line, query: q)
        }
        return lines.joined(separator: "\n")
    }

    private static func markLine(_ line: String, query: String) -> String {
        guard line.range(of: query, options: options) != nil else { return line }
        let ns = NSRange(line.startIndex..., in: line)
        let protected = protectedPattern.matches(in: line, range: ns)
            .compactMap { Range($0.range, in: line) }

        var out = ""
        var cursor = line.startIndex
        var searchRange = line.startIndex..<line.endIndex
        while let r = line.range(of: query, options: options, range: searchRange) {
            searchRange = r.upperBound..<line.endIndex
            if protected.contains(where: { $0.overlaps(r) }) { continue }
            // A neighbouring tilde would merge with our delimiter and break the strikethrough.
            if r.lowerBound > line.startIndex, line[line.index(before: r.lowerBound)] == "~" { continue }
            if r.upperBound < line.endIndex, line[r.upperBound] == "~" { continue }
            out += line[cursor..<r.lowerBound]
            out += "~~" + line[r] + "~~"
            cursor = r.upperBound
        }
        out += line[cursor...]
        return out
    }
}
