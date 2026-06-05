import SwiftUI
import MarkdownUI

/// Slide-in overlay panel that renders a saved research report.
/// Appears over the chat area (sidebar/rail stay visible) when the user
/// taps "View Report" after a Deep Research run completes.
struct ResearchReportPanel: View {
    let path: String
    let fontSize: Double
    let lineHeight: Double
    let onClose: () -> Void

    @Environment(\.colorScheme) private var colorScheme

    @State private var content: String = ""
    @State private var isLoading = true
    /// Delayed flag so content only renders after the slide-in transition settles —
    /// prevents the jarring "text pops before panel" visual on open.
    @State private var contentVisible = false

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .trailing) {
                Color.black.opacity(0.35)
                    .ignoresSafeArea()
                    .onTapGesture { onClose() }

                // Panel — 65% of window width, slides in from the right
                VStack(spacing: 0) {
                    header
                    Divider()
                    if isLoading || !contentVisible {
                        Spacer()
                        ProgressView()
                        Spacer()
                    } else {
                        ScrollView {
                            Markdown(content)
                                .markdownTheme(reportTheme)
                                .markdownTextStyle {
                                    FontSize(CGFloat(fontSize))
                                }
                                .padding(.horizontal, 56)
                                .padding(.vertical, 36)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                    }
                }
                .frame(width: geo.size.width * 0.65)
                .background(.ultraThinMaterial)
            }
        }
        .ignoresSafeArea()
        .task { loadContent() }
    }

    // MARK: Header

    private var header: some View {
        HStack(spacing: 10) {
            Image(systemName: "doc.text.magnifyingglass")
                .font(.system(size: 13))
                .foregroundStyle(Color.accentColor)
            Spacer()
            // Export button
            Button {
                exportReport()
            } label: {
                Image(systemName: "square.and.arrow.up")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .help("Export report")
            // Close button
            Button { onClose() } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.secondary)
                    .frame(width: 22, height: 22)
                    .background(Color.secondary.opacity(0.12))
                    .clipShape(Circle())
            }
            .buttonStyle(.plain)
            .keyboardShortcut(.escape, modifiers: [])
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
    }

    // MARK: Loading

    private func loadContent() {
        // Read file immediately so it's ready, but hold the reveal until the
        // slide-in transition finishes (0.28s) — stops text from popping before panel.
        content = (try? String(contentsOfFile: path, encoding: .utf8)) ?? "_Could not load report._"
        isLoading = false
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(320))
            withAnimation(.easeIn(duration: 0.15)) { contentVisible = true }
        }
    }

    private func exportReport() {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = URL(fileURLWithPath: path).lastPathComponent
        panel.allowedContentTypes = [.plainText]
        if panel.runModal() == .OK, let url = panel.url {
            try? content.write(to: url, atomically: true, encoding: .utf8)
        }
    }

    // MARK: Theme

    private var reportTheme: Theme {
        // em spacing = lineHeight multiplier − 1 (e.g. 1.5 → 0.5em between lines)
        let lineSpacing = CGFloat(lineHeight) - 1.0
        return Theme.gitHub
            .text {
                ForegroundColor(.primary)
                FontSize(CGFloat(fontSize))
            }
            .code {
                FontFamilyVariant(.monospaced)
                FontSize(.em(0.87))
                BackgroundColor(.primary.opacity(0.08))
                TextTracking(0)
            }
            .strong { FontWeight(.semibold) }
            .link { ForegroundColor(.accentColor) }
            .heading1 { configuration in
                configuration.label
                    .markdownTextStyle {
                        FontSize(CGFloat(fontSize) + 10)
                        FontWeight(.bold)
                    }
                    .fixedSize(horizontal: false, vertical: true)
                    .markdownMargin(top: 0, bottom: 12)
            }
            .heading2 { configuration in
                configuration.label
                    .markdownTextStyle {
                        FontSize(CGFloat(fontSize) + 5)
                        FontWeight(.semibold)
                    }
                    .fixedSize(horizontal: false, vertical: true)
                    .markdownMargin(top: 24, bottom: 8)
            }
            .heading3 { configuration in
                configuration.label
                    .markdownTextStyle {
                        FontSize(CGFloat(fontSize) + 2)
                        FontWeight(.semibold)
                    }
                    .fixedSize(horizontal: false, vertical: true)
                    .markdownMargin(top: 20, bottom: 6)
            }
            .paragraph { configuration in
                configuration.label
                    .fixedSize(horizontal: false, vertical: true)
                    .lineSpacing(CGFloat(fontSize * (lineHeight - 1.0)))
                    .markdownMargin(top: 0, bottom: 14)
            }
            .codeBlock { configuration in
                configuration.label
                    .fixedSize(horizontal: false, vertical: true)
                    .relativeLineSpacing(.em(0.2))
                    .markdownTextStyle {
                        FontFamilyVariant(.monospaced)
                        FontSize(.em(0.87))
                        TextTracking(0)
                    }
                    .padding(14)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Color.primary.opacity(0.06))
                    .clipShape(RoundedRectangle(cornerRadius: 8))
                    .markdownMargin(top: 14, bottom: 14)
            }
            .blockquote { configuration in
                HStack(spacing: 0) {
                    RoundedRectangle(cornerRadius: 3)
                        .fill(Color.accentColor.opacity(0.5))
                        .frame(width: 3)
                    configuration.label
                        .markdownTextStyle { ForegroundColor(.secondary) }
                        .padding(.leading, 14)
                }
                .fixedSize(horizontal: false, vertical: true)
                .markdownMargin(top: 16, bottom: 16)
            }
            .table { configuration in
                configuration.label
                    .fixedSize(horizontal: false, vertical: true)
                    .markdownTableBorderStyle(.init(color: .primary.opacity(0.18)))
                    .markdownTableBackgroundStyle(
                        .alternatingRows(Color.clear, Color.primary.opacity(0.04))
                    )
                    .markdownMargin(top: 16, bottom: 16)
            }
            .tableCell { configuration in
                configuration.label
                    .markdownTextStyle {
                        if configuration.row == 0 { FontWeight(.semibold) }
                        BackgroundColor(nil)
                    }
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.vertical, 9)
                    .padding(.horizontal, 16)
            }
    }
}
