import Foundation

/// One place a symbol appears, as ⌘-click navigation sees it.
struct SymbolOccurrence: Identifiable, Hashable {
    let path: String
    let line: Int          // 1-based
    let preview: String
    let isDefinition: Bool

    var id: String { "\(path):\(line)" }
    var location: String { "\(path):\(line)" }
}

/// Decides whether a source line *declares* a symbol rather than using it.
///
/// There is no language server here — ⌘-click is backed by `git grep`, so this
/// is a deliberately shallow, language-agnostic heuristic: a declaration keyword
/// (Swift/Kotlin/Java/JS/TS/Python/Go/Rust/Ruby) immediately followed by the
/// symbol. It over-matches on `let x = other.foo` style lines only when the
/// symbol is what's being bound, which is still a definition of that name.
enum SymbolClassifier {
    private static let keywords = [
        "class", "struct", "enum", "protocol", "extension", "actor", "interface",
        "object", "record", "trait", "impl", "module", "namespace",
        "func", "fun", "function", "def", "fn", "sub", "method",
        "typealias", "associatedtype", "typedef", "type",
        "let", "var", "val", "const", "static", "case",
    ]

    /// `true` when `line` looks like a declaration of `symbol`.
    static func isDefinition(line: String, symbol: String) -> Bool {
        guard let regex = regex(for: symbol) else { return false }
        let range = NSRange(line.startIndex..., in: line)
        return regex.firstMatch(in: line, range: range) != nil
    }

    private static var cache: [String: NSRegularExpression] = [:]

    private static func regex(for symbol: String) -> NSRegularExpression? {
        if let cached = cache[symbol] { return cached }
        let escaped = NSRegularExpression.escapedPattern(for: symbol)
        // <keyword> [modifiers…] <symbol>, with the symbol not part of a longer word.
        let pattern = "(?:^|[^\\w.])(?:\(keywords.joined(separator: "|")))\\s+"
            + "(?:[\\w@\\[\\]]+\\s+)*\(escaped)\\b"
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return nil }
        cache[symbol] = regex
        return regex
    }
}

/// What a ⌘-click resolved to when it needs to ask the user to pick. Carries
/// *every* occurrence — the sheet switches between declarations and usages
/// itself, so a wrong guess doesn't cost another search.
struct SymbolLookup: Identifiable {
    enum Kind: String, Hashable { case definitions, usages }

    /// Where the occurrences came from: Xcode's index (real references to the
    /// one symbol) or a plain text search by name.
    enum Source: Hashable {
        case index(updated: Date?)
        case grep
    }

    let id = UUID()
    let symbol: String
    let initialKind: Kind
    let occurrences: [SymbolOccurrence]
    /// Where the ⌘-click happened, so that file can be listed first.
    let originPath: String
    let originLine: Int
    var source: Source = .grep

    var definitions: [SymbolOccurrence] { occurrences.filter { $0.isDefinition } }

    /// Usages, minus the line the user ⌘-clicked on.
    var usages: [SymbolOccurrence] {
        occurrences.filter {
            !$0.isDefinition && !($0.path == originPath && $0.line == originLine)
        }
    }

    func results(for kind: Kind) -> [SymbolOccurrence] {
        kind == .definitions ? definitions : usages
    }
}

/// Occurrences of one file, as the lookup sheet lists them.
struct SymbolFileGroup: Identifiable {
    let path: String
    let occurrences: [SymbolOccurrence]

    var id: String { path }
    var name: String { (path as NSString).lastPathComponent }
    var directory: String { (path as NSString).deletingLastPathComponent }

    /// Group by file, origin file first, then alphabetically; lines ascending.
    static func group(_ occurrences: [SymbolOccurrence], originPath: String) -> [SymbolFileGroup] {
        Dictionary(grouping: occurrences, by: { $0.path })
            .map { SymbolFileGroup(path: $0.key, occurrences: $0.value.sorted { $0.line < $1.line }) }
            .sorted {
                if ($0.path == originPath) != ($1.path == originPath) { return $0.path == originPath }
                return $0.path.localizedStandardCompare($1.path) == .orderedAscending
            }
    }
}
