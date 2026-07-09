import SwiftUI

/// Splits a heavy response into Alice's short conversational preamble ("plating")
/// and the document body, cutting at the first document-shaped line — a heading,
/// table row, or code fence. Returns nil when there is no useful split: content
/// that IS the document from its first line, or prose too long to be a preamble.
/// Used both mid-stream (freeze the preamble, tick a composing card) and on
/// completion (preamble bubble + document card).
enum DocumentSplit {
    static let maxProseLength = 800

    static func split(_ content: String) -> (prose: String, document: String)? {
        // Only scan the head — a preamble longer than maxProseLength wouldn't
        // split anyway, and this keeps the per-token cost during streaming flat.
        let head = content.prefix(maxProseLength + 200)
        var offset = 0
        for line in head.split(separator: "\n", omittingEmptySubsequences: false) {
            if offset > maxProseLength { return nil }
            let t = line.drop(while: { $0 == " " })
            if t.first == "#" || t.first == "|" || t.hasPrefix("```") {
                guard offset > 0 else { return nil }   // document from line one → no preamble
                let cut = content.index(content.startIndex, offsetBy: offset)
                let prose = String(content[..<cut]).trimmingCharacters(in: .whitespacesAndNewlines)
                guard !prose.isEmpty else { return nil }
                return (prose, String(content[cut...]))
            }
            offset += line.count + 1
        }
        return nil
    }
}

/// Live placeholder while a document streams in: the raw markdown never floods
/// the bubble — a counter ticks up until the finished card takes over.
struct ComposingDocumentCard: View {
    let charCount: Int

    var body: some View {
        HStack(spacing: 9) {
            ProgressView().controlSize(.small)
            Text("Composing document…")
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(.primary)
            Text(charCount >= 1000 ? String(format: "%.1fk chars", Double(charCount) / 1000)
                                   : "\(charCount) chars")
                .font(.system(size: 10))
                .monospacedDigit()
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .glassEffect(.regular, in: .rect(cornerRadius: 14, style: .continuous))
    }
}

/// Stand-in bubble for heavy markdown (huge docs, table-dumps): the chat scroll
/// path never mounts MarkdownUI for these — LazyVStack re-instantiates bubbles on
/// every viewport crossing, so a heavy mount re-pays full layout on each scroll
/// past. Instead this lightweight preview card opens the WKWebView report panel,
/// where WebKit lays the document out off-process. Replaces the old
/// plain-monospace fallback (see decision_report_viewer_webview).
struct HeavyMarkdownCard: View {
    let content: String
    let onOpen: () -> Void

    @State private var hovering = false

    var body: some View {
        Button(action: onOpen) {
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 7) {
                    Image(systemName: "doc.richtext")
                        .font(.system(size: 13))
                        .foregroundStyle(Color.accentColor)
                    Text("Formatted response")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(.primary)
                    Spacer(minLength: 12)
                    Text(stats)
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                }
                if !preview.isEmpty {
                    Text(preview)
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                        .multilineTextAlignment(.leading)
                }
                HStack(spacing: 4) {
                    Text("Open in viewer")
                    Image(systemName: "arrow.up.forward")
                        .font(.system(size: 9, weight: .semibold))
                }
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(Color.accentColor)
            }
            .padding(14)
            .frame(maxWidth: 520, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .glassEffect(.regular, in: .rect(cornerRadius: 14, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .strokeBorder(hovering ? Color.accentColor.opacity(0.45) : Color.primary.opacity(0.10),
                              lineWidth: 1)
        )
        .onHover { hovering = $0 }
        .animation(.easeInOut(duration: 0.15), value: hovering)
        .help("Open the full formatted response in the report viewer")
    }

    /// "8.2k chars · 14 table rows · 2 code blocks" — single cheap pass.
    private var stats: String {
        let chars = content.count
        var parts = [chars >= 1000 ? String(format: "%.1fk chars", Double(chars) / 1000)
                                   : "\(chars) chars"]
        var tableRows = 0
        var fences = 0
        for line in content.split(separator: "\n") {
            let t = line.drop(while: { $0 == " " })
            if t.first == "|" { tableRows += 1 }
            if t.hasPrefix("```") { fences += 1 }
        }
        if tableRows > 0 { parts.append("\(tableRows) table rows") }
        if fences >= 2 { parts.append("\(fences / 2) code block\(fences / 2 == 1 ? "" : "s")") }
        return parts.joined(separator: " · ")
    }

    /// First two content-bearing lines, markdown chrome stripped — enough to
    /// recognize the response without rendering anything.
    private var preview: String {
        var lines: [String] = []
        for raw in content.split(separator: "\n", omittingEmptySubsequences: true) {
            var s = raw.replacingOccurrences(of: "|", with: " ")
            while let f = s.first, "#>*-`+ ".contains(f) { s.removeFirst() }
            s = s.replacingOccurrences(of: "**", with: "")
                 .trimmingCharacters(in: .whitespaces)
            // Skip table separator rows, horizontal rules, and emptied lines.
            if s.isEmpty || s.allSatisfy({ "-=:_ ".contains($0) }) { continue }
            lines.append(s)
            if lines.count == 2 { break }
        }
        return lines.joined(separator: "\n")
    }
}
