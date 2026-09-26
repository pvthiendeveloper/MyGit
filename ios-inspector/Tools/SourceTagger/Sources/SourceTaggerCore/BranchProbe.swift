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
/// Where there's room, the returned expression keeps its line *and column*
/// — `return` moves left into the indentation. Elsewhere (`case .a: return
/// x`, `{ return x }`, an implicit `switch` branch) the expression is wrapped
/// in place: same line, columns shifted, which the index lookup tolerates
/// (it takes the nearest same-named occurrence on the line).
///
/// While a token probe (`__mT`, see `TokenProbe`) evaluates a view's
/// argument, `__mB` also adds its `"<path>:<line>"` to that evaluation's
/// trace, so the inspector learns which `return`s produced *this* view's
/// value — not only which ran somewhere.
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
        guard let expr = statement.expression, probeable(expr) else { return nil }
        return inPlace(statement, expr, converter) ?? wrapping(expr)
    }

    /// `__mB(expr)` where it stands: an implicit branch, or a `return` with
    /// no room to its left.
    static func wrapping(_ expr: ExprSyntax) -> [Insertion]? {
        guard probeable(expr) else { return nil }
        return [
            Insertion(offset: expr.positionAfterSkippingLeadingTrivia.utf8Offset, text: "__mB("),
            Insertion(offset: expr.endPositionBeforeTrailingTrivia.utf8Offset, text: ")"),
        ]
    }

    /// `try`/`await` read oddly inside a call; skip rather than risk it.
    private static func probeable(_ expr: ExprSyntax) -> Bool {
        guard let first = expr.firstToken(viewMode: .sourceAccurate) else { return false }
        return first.tokenKind != .keyword(.try) && first.tokenKind != .keyword(.await)
    }

    /// `return x` → `return __mB(x)` with `x` unmoved, or nil without room.
    private static func inPlace(_ statement: ReturnStmtSyntax, _ expr: ExprSyntax,
                                _ converter: SourceLocationConverter) -> [Insertion]? {
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
            // Inside a token probe: part of that argument's trace.
            (Thread.main.threadDictionary["MyGitInspector.trace"] as? NSMutableArray)?.lastObject
                .flatMap { $0 as? NSMutableArray }?.add(key)
            return v
        }

        """
    }
}

/// Records what each token argument of a tagged view evaluated to, per view
/// instance:
///
///     .foregroundColor(tokenProvider.labelColor(state.labelColor))
///       .preference(key: __MyGitSourceKey.self, value: "F.swift:69:9")
///  →  .foregroundColor(__mT(tokenProvider.labelColor(state.labelColor), "F.swift:69:9", 1))
///       .preference(key: __MyGitSourceKey.self, value: __mS("F.swift:69:9"))
///
/// `__mT` evaluates the argument (an autoclosure), collecting the branch
/// probes it passes through, and parks `{value, branches}` under the tag;
/// `__mS` — evaluated after every argument of the chain — takes them and
/// appends them to the tag as JSON after a U+001F. Lines never change.
enum TokenProbe {
    static let separator = "\u{1F}"

    /// Callbacks, not values: `@MainActor () -> Void` doesn't pass through a
    /// generic, and what a button does isn't a design token anyway.
    static let callbackLabels: Set<String> = [
        "action", "perform", "onDismiss", "onCommit", "onEditingChanged", "onChange", "completion", "handler",
        "onTap", "onSubmit", "onAppear", "onDisappear",
    ]

    /// Arguments worth probing: a value read at run time, not a binding
    /// (`$x`), `inout` (`&x`), closure or `try`/`await` expression.
    static func probeable(_ expr: ExprSyntax) -> Bool {
        if expr.is(ClosureExprSyntax.self) || expr.is(InOutExprSyntax.self) { return false }
        if let ref = expr.as(DeclReferenceExprSyntax.self), ref.baseName.text.hasPrefix("$") { return false }
        guard let first = expr.firstToken(viewMode: .sourceAccurate) else { return false }
        if first.tokenKind == .keyword(.try) || first.tokenKind == .keyword(.await) { return false }
        // `.leading ? …` / `.init(…)`: no type to infer through a generic.
        if expr.is(MemberAccessExprSyntax.self), expr.as(MemberAccessExprSyntax.self)?.base == nil { return false }
        return true
    }

    static func edits(for expr: ExprSyntax, tag: String, index: Int) -> [Insertion] {
        [
            Insertion(offset: expr.positionAfterSkippingLeadingTrivia.utf8Offset, text: "__mT("),
            Insertion(offset: expr.endPositionBeforeTrailingTrivia.utf8Offset, text: ", \"\(tag)\", \(index))"),
        ]
    }

    /// Appended to a file with probed arguments. Main thread only.
    static let declaration = """
    fileprivate func __mT<T>(_ v: @autoclosure () -> T, _ k: String, _ i: Int) -> T { // MyGit UI Inspector token probe
        guard Thread.isMainThread else { return v() }
        let d = Thread.main.threadDictionary
        let stack: NSMutableArray
        if let s = d["MyGitInspector.trace"] as? NSMutableArray { stack = s } else { stack = NSMutableArray(); d["MyGitInspector.trace"] = stack }
        let frame = NSMutableArray()
        stack.add(frame)
        let value = v()
        stack.removeLastObject()
        (stack.lastObject as? NSMutableArray)?.addObjects(from: frame as [AnyObject])
        let pending: NSMutableDictionary
        if let p = d["MyGitInspector.pending"] as? NSMutableDictionary { pending = p } else { pending = NSMutableDictionary(); d["MyGitInspector.pending"] = pending }
        let record = pending[k] as? NSMutableDictionary ?? NSMutableDictionary()
        pending[k] = record
        let m = Mirror(reflecting: value)
        var text = m.displayStyle == .optional ? (m.children.first.map { "\\($0.value)" } ?? "nil") : "\\(value)"
        if text.count > 160 { text = String(text.prefix(160)) }
        record["\\(i)"] = ["v": text, "b": frame]
        return value
    }
    fileprivate func __mS(_ k: String) -> String { // MyGit UI Inspector token probe
        guard Thread.isMainThread, let pending = Thread.main.threadDictionary["MyGitInspector.pending"] as? NSMutableDictionary,
              let record = pending[k] as? NSDictionary else { return k }
        pending.removeObject(forKey: k)
        guard let data = try? JSONSerialization.data(withJSONObject: record) else { return k }
        return k + "\\u{1F}" + String(decoding: data, as: UTF8.self)
    }

    """
}
