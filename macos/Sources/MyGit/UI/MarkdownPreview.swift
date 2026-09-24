import SwiftUI

/// Rendered view of a Markdown document — the right-hand pane of the editor for
/// `.md` files. Block structure comes from `MarkdownParser`; inline spans
/// (bold, code, links) go through `AttributedString`'s own Markdown parser.
struct MarkdownPreview: View {
    let text: String
    /// Scroll position to follow (0…1), or nil when this pane is driving.
    var scrollFraction: CGFloat?
    var onScrollFraction: ((CGFloat) -> Void)?
    @State private var position = ScrollPosition()
    @State private var scrollableHeight: CGFloat = 0
    /// Re-parsed off the keystroke path: in split mode the source pane fires a
    /// change per character, and reparsing a long README each time stutters.
    @State private var blocks: [MarkdownBlock] = []
    @State private var parsedText = ""

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                ForEach(Array(blocks.enumerated()), id: \.offset) { _, block in
                    view(for: block)
                }
            }
            .padding(.horizontal, 24)
            .padding(.vertical, 20)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .background(Color(NSColor.textBackgroundColor))
        .textSelection(.enabled)
        .scrollPosition($position)
        .onScrollGeometryChange(for: ScrollSnapshot.self) { geometry in
            ScrollSnapshot(
                offset: geometry.contentOffset.y,
                scrollable: max(0, geometry.contentSize.height - geometry.containerSize.height)
            )
        } action: { _, snapshot in
            scrollableHeight = snapshot.scrollable
            guard snapshot.scrollable > 1, scrollFraction == nil else { return }
            onScrollFraction?(max(0, min(1, snapshot.offset / snapshot.scrollable)))
        }
        .onChange(of: scrollFraction) { _, fraction in
            guard let fraction, scrollableHeight > 1 else { return }
            position.scrollTo(y: fraction * scrollableHeight)
        }
        .task(id: text) {
            guard text != parsedText else { return }
            try? await Task.sleep(nanoseconds: 150_000_000)
            guard !Task.isCancelled else { return }
            let source = text
            let parsed = await Task.detached(priority: .userInitiated) {
                MarkdownParser.parse(source)
            }.value
            guard !Task.isCancelled else { return }
            blocks = parsed
            parsedText = source
        }
    }

    @ViewBuilder
    private func view(for block: MarkdownBlock) -> some View {
        switch block {
        case .heading(let level, let text):
            Text(inline(text))
                .font(.system(size: headingSize(level), weight: level <= 2 ? .bold : .semibold))
                .padding(.top, level <= 2 ? 10 : 4)

        case .paragraph(let text):
            Text(inline(text))
                .font(.system(size: 13))
                .fixedSize(horizontal: false, vertical: true)

        case .bullet(let items):
            VStack(alignment: .leading, spacing: 5) {
                ForEach(Array(items.enumerated()), id: \.offset) { _, item in
                    listRow(marker: "•", text: item)
                }
            }

        case .numbered(let items):
            VStack(alignment: .leading, spacing: 5) {
                ForEach(Array(items.enumerated()), id: \.offset) { index, item in
                    listRow(marker: "\(index + 1).", text: item)
                }
            }

        case .code(let language, let code):
            CodeBlockView(language: language, code: code)

        case .quote(let text):
            HStack(alignment: .top, spacing: 8) {
                Rectangle()
                    .fill(Color.accentColor.opacity(0.5))
                    .frame(width: 3)
                Text(inline(text))
                    .font(.system(size: 13))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

        case .table(let header, let rows):
            VStack(alignment: .leading, spacing: 0) {
                tableRow(header, isHeader: true)
                ForEach(Array(rows.enumerated()), id: \.offset) { _, row in
                    Divider()
                    tableRow(row, isHeader: false)
                }
            }
            .background(RoundedRectangle(cornerRadius: 6).fill(Color.secondary.opacity(0.06)))

        case .divider:
            Divider()
        }
    }

    private func listRow(marker: String, text: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(marker)
                .font(.system(size: 13))
                .foregroundStyle(.secondary)
                .frame(minWidth: 16, alignment: .trailing)
            Text(inline(text))
                .font(.system(size: 13))
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
    }

    private func tableRow(_ cells: [String], isHeader: Bool) -> some View {
        HStack(alignment: .top, spacing: 0) {
            ForEach(Array(cells.enumerated()), id: \.offset) { _, cell in
                Text(inline(cell))
                    .font(.system(size: 12, weight: isHeader ? .semibold : .regular))
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
            }
        }
    }

    private func headingSize(_ level: Int) -> CGFloat {
        switch level {
        case 1: return 24
        case 2: return 19
        case 3: return 16
        case 4: return 14
        default: return 13
        }
    }

    /// Inline Markdown (bold/italic/code/links) via Foundation's own parser;
    /// falls back to the raw text when it can't parse the span.
    private func inline(_ text: String) -> AttributedString {
        (try? AttributedString(
            markdown: text,
            options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)
        )) ?? AttributedString(text)
    }
}

/// Fenced code block, syntax-highlighted with the same engine as the diff viewer.
private struct CodeBlockView: View {
    let language: String?
    let code: String

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            Text(highlighted)
                .font(.system(size: 12, design: .monospaced))
                .textSelection(.enabled)
                .padding(10)
        }
        .background(RoundedRectangle(cornerRadius: 6).fill(Color.secondary.opacity(0.10)))
        .overlay(alignment: .topTrailing) {
            if let language, !language.isEmpty {
                Text(language)
                    .font(.system(size: 9))
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 6).padding(.vertical, 2)
            }
        }
    }

    private var highlighted: AttributedString {
        guard let language,
              let attributed = SyntaxHighlighter.shared.attributed(code, ext: language, fontSize: 12)
        else { return AttributedString(code) }
        return AttributedString(attributed)
    }
}


/// Scroll geometry the preview reports back for pane syncing.
private struct ScrollSnapshot: Equatable {
    let offset: CGFloat
    let scrollable: CGFloat
}
