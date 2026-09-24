import Foundation

/// A block-level piece of a Markdown document, as the preview renders it.
///
/// A hand-rolled block parser rather than a dependency: the preview only needs
/// the structures that show up in READMEs, CHANGELOGs and SKILL.md files, and
/// inline spans are handed to `AttributedString(markdown:)`.
enum MarkdownBlock {
    case heading(level: Int, text: String)
    case paragraph(String)
    case bullet(items: [String])
    case numbered(items: [String])
    case code(language: String?, code: String)
    case quote(String)
    case table(header: [String], rows: [[String]])
    case divider

}

enum MarkdownParser {
    static func parse(_ text: String) -> [MarkdownBlock] {
        var blocks: [MarkdownBlock] = []
        var paragraph: [String] = []
        var bullets: [String] = []
        var numbers: [String] = []
        var lines = text.components(separatedBy: "\n")[...]

        func flushParagraph() {
            guard !paragraph.isEmpty else { return }
            blocks.append(.paragraph(paragraph.joined(separator: " ")))
            paragraph = []
        }
        func flushLists() {
            if !bullets.isEmpty { blocks.append(.bullet(items: bullets)); bullets = [] }
            if !numbers.isEmpty { blocks.append(.numbered(items: numbers)); numbers = [] }
        }
        func flushAll() { flushParagraph(); flushLists() }

        while let raw = lines.first {
            lines = lines.dropFirst()
            let line = raw.trimmingCharacters(in: .whitespaces)

            // Fenced code — take everything up to the closing fence verbatim.
            if line.hasPrefix("```") || line.hasPrefix("~~~") {
                flushAll()
                let fence = String(line.prefix(3))
                let language = String(line.dropFirst(3)).trimmingCharacters(in: .whitespaces)
                var body: [String] = []
                while let next = lines.first {
                    lines = lines.dropFirst()
                    if next.trimmingCharacters(in: .whitespaces).hasPrefix(fence) { break }
                    body.append(next)
                }
                blocks.append(.code(language: language.isEmpty ? nil : language,
                                    code: body.joined(separator: "\n")))
                continue
            }

            if line.isEmpty { flushAll(); continue }

            // Front matter / thematic break.
            if line == "---" || line == "***" || line == "___" {
                flushAll()
                blocks.append(.divider)
                continue
            }

            if line.hasPrefix("#") {
                let hashes = line.prefix { $0 == "#" }.count
                if hashes <= 6, line.dropFirst(hashes).first == " " {
                    flushAll()
                    blocks.append(.heading(level: hashes,
                                           text: String(line.dropFirst(hashes)).trimmingCharacters(in: .whitespaces)))
                    continue
                }
            }

            if line.hasPrefix("> ") || line == ">" {
                flushAll()
                blocks.append(.quote(String(line.dropFirst(1)).trimmingCharacters(in: .whitespaces)))
                continue
            }

            // Table: a header row followed by a |---|---| separator.
            if line.hasPrefix("|"), let separator = lines.first,
               isTableSeparator(separator) {
                flushAll()
                lines = lines.dropFirst()
                let header = cells(of: line)
                var rows: [[String]] = []
                while let next = lines.first, next.trimmingCharacters(in: .whitespaces).hasPrefix("|") {
                    lines = lines.dropFirst()
                    rows.append(cells(of: next))
                }
                blocks.append(.table(header: header, rows: rows))
                continue
            }

            if let item = bulletItem(line) {
                flushParagraph()
                if !numbers.isEmpty { blocks.append(.numbered(items: numbers)); numbers = [] }
                bullets.append(item)
                continue
            }
            if let item = numberedItem(line) {
                flushParagraph()
                if !bullets.isEmpty { blocks.append(.bullet(items: bullets)); bullets = [] }
                numbers.append(item)
                continue
            }

            // Continuation of a list item (indented wrap).
            if raw.hasPrefix("  "), !bullets.isEmpty {
                bullets[bullets.count - 1] += " " + line
                continue
            }
            if raw.hasPrefix("  "), !numbers.isEmpty {
                numbers[numbers.count - 1] += " " + line
                continue
            }

            flushLists()
            paragraph.append(line)
        }
        flushAll()
        return blocks
    }

    private static func bulletItem(_ line: String) -> String? {
        for marker in ["- ", "* ", "+ "] where line.hasPrefix(marker) {
            return String(line.dropFirst(marker.count))
        }
        return nil
    }

    private static func numberedItem(_ line: String) -> String? {
        let digits = line.prefix { $0.isNumber }
        guard !digits.isEmpty else { return nil }
        let rest = line.dropFirst(digits.count)
        guard rest.hasPrefix(". ") || rest.hasPrefix(") ") else { return nil }
        return String(rest.dropFirst(2))
    }

    private static func isTableSeparator(_ line: String) -> Bool {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        guard trimmed.hasPrefix("|") else { return false }
        return trimmed.allSatisfy { "|-: ".contains($0) } && trimmed.contains("-")
    }

    private static func cells(of line: String) -> [String] {
        line.trimmingCharacters(in: .whitespaces)
            .trimmingCharacters(in: CharacterSet(charactersIn: "|"))
            .components(separatedBy: "|")
            .map { $0.trimmingCharacters(in: .whitespaces) }
    }
}
