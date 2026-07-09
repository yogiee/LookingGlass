import SwiftUI
import AppKit
import cmark_gfm
import cmark_gfm_extensions

/// Markdown → themed HTML page for the report viewer's WKWebView.
///
/// Parsing/emission is cmark-gfm (already in the dependency graph underneath
/// MarkdownUI): C-fast on megabyte documents and GFM-complete. Model output is
/// untrusted input, so options stay at DEFAULT — raw HTML in the markdown is
/// stripped (never pass CMARK_OPT_UNSAFE).
///
/// The stylesheet is adapted from Typa's proven preview CSS (see the Typa
/// project's `MarkdownHTML.swift`), with LG-specific changes: a transparent
/// body so the panel's material shows through, and colors tuned per scheme.
enum MarkdownHTML {

    static func page(
        markdown: String,
        colorScheme: ColorScheme,
        fontSize: Double,
        lineHeight: Double,
        accentHex: String
    ) -> String {
        let body = bodyHTML(markdown)
        let css = stylesheet(colorScheme: colorScheme,
                             fontSize: fontSize,
                             lineHeight: lineHeight,
                             accentHex: accentHex)
        return """
        <!doctype html>
        <html>
        <head>
        <meta charset="utf-8">
        <meta name="viewport" content="width=device-width">
        <style>\(css)</style>
        </head>
        <body>
        <article class="markdown-body">
        \(body)
        </article>
        </body>
        </html>
        """
    }

    /// GFM markdown → HTML fragment. Tables, strikethrough, autolinks, and task
    /// lists enabled; raw HTML stripped (safe default).
    static func bodyHTML(_ markdown: String) -> String {
        cmark_gfm_core_extensions_ensure_registered()

        let options = CMARK_OPT_DEFAULT
        guard let parser = cmark_parser_new(options) else { return escapedFallback(markdown) }
        defer { cmark_parser_free(parser) }

        for name in ["table", "strikethrough", "autolink", "tasklist"] {
            if let ext = cmark_find_syntax_extension(name) {
                cmark_parser_attach_syntax_extension(parser, ext)
            }
        }

        var source = markdown
        source.withUTF8 { buffer in
            guard let base = buffer.baseAddress else { return }
            base.withMemoryRebound(to: CChar.self, capacity: buffer.count) { cstr in
                cmark_parser_feed(parser, cstr, buffer.count)
            }
        }

        guard let doc = cmark_parser_finish(parser) else { return escapedFallback(markdown) }
        defer { cmark_node_free(doc) }

        // The extension list must be passed to the renderer too, or tables etc.
        // fall back to raw paragraph output.
        guard let html = cmark_render_html(doc, options, cmark_parser_get_syntax_extensions(parser))
        else { return escapedFallback(markdown) }
        defer { free(html) }
        return String(cString: html)
    }

    /// If cmark ever fails, show the source escaped in a <pre> — never blank.
    private static func escapedFallback(_ s: String) -> String {
        var r = s
        r = r.replacingOccurrences(of: "&", with: "&amp;")
        r = r.replacingOccurrences(of: "<", with: "&lt;")
        r = r.replacingOccurrences(of: ">", with: "&gt;")
        return "<pre>\(r)</pre>"
    }

    // MARK: - Stylesheet (Typa-derived, LG glass adaptation)

    private static func stylesheet(
        colorScheme: ColorScheme,
        fontSize: Double,
        lineHeight: Double,
        accentHex: String
    ) -> String {
        let dark = colorScheme == .dark
        let fg, fgSoft, fgMute, line, codeBg, quoteBg: String
        if dark {
            fg      = "rgba(236,236,241,0.92)"
            fgSoft  = "rgba(236,236,241,0.72)"
            fgMute  = "rgba(236,236,241,0.45)"
            line    = "rgba(255,255,255,0.10)"
            codeBg  = "rgba(255,255,255,0.08)"
            quoteBg = "rgba(255,255,255,0.05)"
        } else {
            fg      = "rgba(28,28,30,0.92)"
            fgSoft  = "rgba(28,28,30,0.72)"
            fgMute  = "rgba(28,28,30,0.45)"
            line    = "rgba(0,0,0,0.10)"
            codeBg  = "rgba(0,0,0,0.06)"
            quoteBg = "rgba(0,0,0,0.04)"
        }
        // Reports read better with a little more air than chat bubbles.
        let lh = max(lineHeight, 1.5)

        return """
        :root {
            --fg: \(fg);
            --fg-soft: \(fgSoft);
            --fg-mute: \(fgMute);
            --line: \(line);
            --code-bg: \(codeBg);
            --quote-bg: \(quoteBg);
            --accent: \(accentHex);
        }
        * { box-sizing: border-box; }
        html, body {
            margin: 0;
            padding: 0;
            background: transparent;   /* panel material shows through */
            color: var(--fg);
            font-family: -apple-system, BlinkMacSystemFont, "SF Pro Text", "Helvetica Neue", sans-serif;
            font-size: \(Int(fontSize))px;
            line-height: \(String(format: "%.2f", lh));
            -webkit-font-smoothing: antialiased;
        }
        .markdown-body {
            max-width: 760px;
            margin: 0 auto;
            padding: 36px 56px 72px;
        }
        h1, h2, h3, h4, h5, h6 {
            font-weight: 600;
            line-height: 1.25;
            margin: 1.6em 0 0.5em;
        }
        h1 {
            font-size: 1.9em;
            font-weight: 700;
            padding-bottom: 0.3em;
            border-bottom: 0.5px solid var(--line);
            margin-top: 0.4em;
        }
        h2 { font-size: 1.45em; font-weight: 700; }
        h3 { font-size: 1.2em; }
        h4 { font-size: 1.05em; }
        h5 { font-size: 1.0em; color: var(--fg-soft); }
        h6 { font-size: 0.92em; color: var(--fg-mute); }
        p { margin: 0 0 1em; }
        a { color: var(--accent); text-decoration: none; border-bottom: 0.5px solid color-mix(in srgb, var(--accent) 40%, transparent); }
        a:hover { border-bottom-color: var(--accent); }
        strong { font-weight: 700; }
        em { font-style: italic; }
        code {
            font-family: ui-monospace, SFMono-Regular, Menlo, monospace;
            font-size: 0.9em;
            background: var(--code-bg);
            padding: 0.15em 0.35em;
            border-radius: 3px;
        }
        pre {
            background: var(--code-bg);
            padding: 14px 16px;
            border-radius: 8px;
            overflow-x: auto;
            margin: 0 0 1.2em;
            font-size: 0.9em;
            line-height: 1.55;
        }
        pre code { background: transparent; padding: 0; border-radius: 0; font-size: 1em; }
        blockquote {
            margin: 0 0 1em;
            padding: 12px 16px;
            background: var(--quote-bg);
            border-left: 2px solid var(--accent);
            border-radius: 0 4px 4px 0;
            color: var(--fg-soft);
        }
        blockquote p:last-child { margin-bottom: 0; }
        ul, ol { margin: 0 0 1em; padding-left: 1.6em; }
        ul ul, ol ol, ul ol, ol ul { margin-bottom: 0; }
        li { margin: 0.15em 0; }
        li > input[type="checkbox"] {
            margin-right: 0.4em;
            transform: translateY(1px);
            accent-color: var(--accent);
        }
        hr { border: none; border-top: 0.5px solid var(--line); margin: 2em 0; }
        /* Tables escape the prose measure: size to content, cap at the container,
           scroll horizontally when wider (GitHub/Obsidian approach — and the reason
           mega-tables can't cramp or blow up the layout). */
        table {
            display: block;
            width: max-content;
            max-width: 100%;
            overflow-x: auto;
            border-collapse: collapse;
            margin: 0 0 1.2em;
        }
        th, td {
            border: 0.5px solid var(--line);
            padding: 8px 12px;
            text-align: left;
            white-space: nowrap;
        }
        th { background: var(--code-bg); font-weight: 600; }
        del { color: var(--fg-mute); }
        ::selection { background: color-mix(in srgb, var(--accent) 30%, transparent); }
        """
    }
}

// MARK: - Accent color → CSS hex

extension NSColor {
    /// sRGB hex string for CSS injection (alpha dropped).
    var cssHexString: String {
        guard let rgb = usingColorSpace(.sRGB) else { return "#0a84ff" }
        let r = Int(round(rgb.redComponent * 255))
        let g = Int(round(rgb.greenComponent * 255))
        let b = Int(round(rgb.blueComponent * 255))
        return String(format: "#%02x%02x%02x", r, g, b)
    }
}
