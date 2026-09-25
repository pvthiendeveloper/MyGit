import SwiftSyntax

/// Makes a getter/function with several `return`s report which one ran, so
/// the inspector can name the branch behind a value instead of listing every
/// possible root:
///
///         return value.isEmpty ? nil : value
///  →  return __mB(value.isEmpty ? nil : value)
///
/// `__mB` (file-private, appended to the file) passes the value through and
/// records its description under `"<path>:<line>"` in the main thread's
/// dictionary, where MyGitInspector picks it up with the hierarchy.
///
/// The returned expression keeps its line *and column* — `return` moves
/// left into the indentation — because the compiler's index is looked up at
/// the original positions. A `return` without room for that (`{ return x }`,
/// `case .a: return x`, shallow indentation) is left alone; the inspector
/// only trusts a branch when every alternative was probed.
enum BranchProbe {
    static let head = "return __mB("

    /// Value-returning bodies only: views are the tagger's business, and an
    /// opaque/builder body can't be wrapped safely.
    static func worthProbing(_ type: TypeSyntax, _ attributes: AttributeListSyntax) -> Bool {
        if type.is(SomeOrAnyTypeSyntax.self) { return false }
        let name = type.trimmedDescription
        if ["Never", "Void", "()"].contains(name) || name.hasSuffix("View") { return false }
        for attribute in attributes {
            guard case let .attribute(attr) = attribute else { continue }
            if attr.attributeName.trimmedDescription.hasSuffix("Builder") { return false }
        }
        return true
    }

    /// The two edits for one `return`, or nil when it can't be probed
    /// without moving the returned expression.
    static func edits(for statement: ReturnStmtSyntax, _ converter: SourceLocationConverter) -> [Insertion]? {
        guard let expr = statement.expression else { return nil }
        // `try`/`await` read oddly inside a call; skip rather than risk it.
        if let first = expr.firstToken(viewMode: .sourceAccurate),
           first.tokenKind == .keyword(.try) || first.tokenKind == .keyword(.await) { return nil }
        let keyword = statement.returnKeyword
        guard converter.location(for: keyword.positionAfterSkippingLeadingTrivia).line
                == converter.location(for: expr.positionAfterSkippingLeadingTrivia).line else { return nil }

        // Only whitespace between the line start and `return`.
        var indent = 0
        var lineStartFound = false
        for piece in keyword.leadingTrivia.pieces.reversed() {
            switch piece {
            case let .spaces(n), let .tabs(n):
                indent += n
            case .newlines, .carriageReturns, .carriageReturnLineFeeds:
                lineStartFound = true
            default:
                return nil
            }
            if lineStartFound { break }
        }
        guard lineStartFound else { return nil }

        let lineStart = keyword.positionAfterSkippingLeadingTrivia.utf8Offset - indent
        let exprStart = expr.positionAfterSkippingLeadingTrivia.utf8Offset
        let room = exprStart - lineStart
        guard room >= head.utf8.count else { return nil }
        return [
            Insertion(offset: lineStart, text: String(repeating: " ", count: room - head.utf8.count) + head, length: room),
            Insertion(offset: expr.endPositionBeforeTrailingTrivia.utf8Offset, text: ")"),
        ]
    }

    /// Appended to a probed file. Main thread only (SwiftUI evaluates views
    /// there; elsewhere the dictionary isn't safe), newest value last, a few
    /// per `return`.
    static func declaration(path: String) -> String {
        """
        fileprivate func __mB<T>(_ v: T, _ l: Int = #line) -> T { // MyGit UI Inspector branch probe
            guard Thread.isMainThread else { return v }
            let all: NSMutableDictionary
            if let d = Thread.main.threadDictionary["MyGitInspector.branches"] as? NSMutableDictionary { all = d }
            else { all = NSMutableDictionary(); Thread.main.threadDictionary["MyGitInspector.branches"] = all }
            let m = Mirror(reflecting: v)
            var text = m.displayStyle == .optional ? (m.children.first.map { "\\($0.value)" } ?? "nil") : "\\(v)"
            if text.count > 200 { text = String(text.prefix(200)) }
            let key = "\(path):\\(l)"
            let seen = all[key] as? NSMutableArray ?? NSMutableArray()
            all[key] = seen
            seen.remove(text)
            seen.add(text)
            if seen.count > 8 { seen.removeObject(at: 0) }
            return v
        }

        """
    }
}
