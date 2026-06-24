import Foundation

enum DiffLineKind {
    case context, addition, deletion, header, hunkHeader
}

struct DiffLine: Identifiable {
    let id = UUID()
    let kind: DiffLineKind
    let text: String
    let oldLine: Int?
    let newLine: Int?
}

struct FileDiff {
    let path: String
    let lines: [DiffLine]
    var isEmpty: Bool { lines.isEmpty }
}

enum GitDiffParser {
    static func parse(_ raw: String, path: String) -> FileDiff {
        var out: [DiffLine] = []
        var oldLine = 0
        var newLine = 0

        for rawLine in raw.components(separatedBy: "\n") {
            if rawLine.hasPrefix("diff ") || rawLine.hasPrefix("index ") ||
                rawLine.hasPrefix("--- ") || rawLine.hasPrefix("+++ ") ||
                rawLine.hasPrefix("new file") || rawLine.hasPrefix("deleted file") ||
                rawLine.hasPrefix("rename ") || rawLine.hasPrefix("similarity ") ||
                rawLine.hasPrefix("Binary ") {
                out.append(DiffLine(kind: .header, text: rawLine, oldLine: nil, newLine: nil))
                continue
            }
            if rawLine.hasPrefix("@@") {
                out.append(DiffLine(kind: .hunkHeader, text: rawLine, oldLine: nil, newLine: nil))
                if let h = parseHunkHeader(rawLine) {
                    oldLine = h.oldStart
                    newLine = h.newStart
                }
                continue
            }
            if rawLine.hasPrefix("+") {
                out.append(DiffLine(kind: .addition, text: String(rawLine.dropFirst()), oldLine: nil, newLine: newLine))
                newLine += 1
            } else if rawLine.hasPrefix("-") {
                out.append(DiffLine(kind: .deletion, text: String(rawLine.dropFirst()), oldLine: oldLine, newLine: nil))
                oldLine += 1
            } else if rawLine.hasPrefix(" ") {
                out.append(DiffLine(kind: .context, text: String(rawLine.dropFirst()), oldLine: oldLine, newLine: newLine))
                oldLine += 1
                newLine += 1
            } else if !rawLine.isEmpty {
                // "\ No newline at end of file" etc.
                out.append(DiffLine(kind: .context, text: rawLine, oldLine: nil, newLine: nil))
            }
        }
        return FileDiff(path: path, lines: out)
    }

    private static func parseHunkHeader(_ line: String) -> (oldStart: Int, newStart: Int)? {
        let scanner = Scanner(string: line)
        scanner.charactersToBeSkipped = nil
        guard scanner.scanString("@@ -") != nil,
              let oldStart = scanner.scanInt() else { return nil }
        _ = scanner.scanString(",")
        _ = scanner.scanInt()
        guard scanner.scanString(" +") != nil,
              let newStart = scanner.scanInt() else { return nil }
        return (oldStart, newStart)
    }
}
