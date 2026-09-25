import Foundation

/// Rules out the roots of a branching token that can't have produced the
/// value on screen, without guessing: `nil` can't draw "Available: R200",
/// `"\(count)/\(limit)"` can't either (no `/`), `4` isn't `8`. What's left is
/// every root that could have — one means the branch is known.
///
/// Anything the rules can't read (`value.isEmpty ? nil : value`, a call) is
/// kept: a pruned root must be impossible, not unlikely.
enum InspectorBranchPruner {
    enum Verdict: Equatable {
        /// Written so it yields exactly this value (a literal or a template that fits).
        case matches
        /// Can't yield this value.
        case excluded
        /// Depends on logic the rules don't read.
        case unknown
    }

    /// The roots that could have produced `value`, in their order — the ones
    /// that match outright first. Unchanged when nothing can be ruled out.
    static func prune(_ roots: [InspectorSymbol], value: String) -> [InspectorSymbol] {
        let judged = roots.map { ($0, verdict($0.literal ?? $0.expr, for: value)) }
        let kept = judged.filter { $0.1 != .excluded }
        guard !kept.isEmpty else { return roots }   // Nothing fits: the rules missed something.
        return kept.filter { $0.1 == .matches }.map(\.0) + kept.filter { $0.1 == .unknown }.map(\.0)
    }

    /// Whether the expression `expr` (as written) can evaluate to `value`.
    static func verdict(_ expr: String, for value: String) -> Verdict {
        let chars = Array(expr.trimmingCharacters(in: .whitespacesAndNewlines))
        return verdict(chars, value: value, depth: 0)
    }

    private static func verdict(_ s: [Character], value: String, depth: Int) -> Verdict {
        guard !s.isEmpty, depth < 8 else { return .unknown }
        let s = stripParentheses(s)

        // `c ? a : b` and `a ?? b`: either side may be what ran.
        if let (a, b) = splitTernary(s) {
            return either(verdict(a, value: value, depth: depth + 1), verdict(b, value: value, depth: depth + 1))
        }
        if let i = topLevelOperator(" ?? ", in: s) {
            return either(verdict(Array(s[..<i]), value: value, depth: depth + 1),
                          verdict(Array(s[(i + 4)...]), value: value, depth: depth + 1))
        }

        let text = String(s)
        if let shown = rgb(ofShownColor: value) { return colorVerdict(text, shown: shown) }
        if text == "nil" { return value.isEmpty ? .unknown : .excluded }
        if let number = Double(text.replacingOccurrences(of: "_", with: "")) {
            guard let shown = Double(value) else { return .excluded }
            return abs(number - shown) < 0.0001 ? .matches : .excluded
        }

        // `"Balance: " + amount`: a template of literal parts.
        let parts = topLevelSplit(s, on: " + ")
        guard let pattern = templatePattern(parts) else { return .unknown }
        guard let regex = try? NSRegularExpression(pattern: "^" + pattern.regex + "$",
                                                   options: [.dotMatchesLineSeparators]) else { return .unknown }
        let fits = regex.firstMatch(in: value, range: NSRange(value.startIndex..., in: value)) != nil
        if !fits { return .excluded }
        // `"\(x)"` fits anything: it says nothing.
        return pattern.hasFixedText ? .matches : .unknown
    }

    // MARK: - Colors

    /// A color the app reported (`#595969FF`) as its RGB digits; alpha is
    /// left out since `.opacity(…)` changes it without changing the token.
    private static func rgb(ofShownColor value: String) -> String? {
        guard value.hasPrefix("#"), value.count == 7 || value.count == 9,
              value.dropFirst().allSatisfy(\.isHexDigit) else { return nil }
        return String(value.dropFirst().prefix(6)).uppercased()
    }

    /// `Color(tymeXHex: 0x595969)`, `UIColor(hex: "#595969")`: a hex literal
    /// either is the color shown or isn't. No hex (`.red`, `Color("Brand")`):
    /// the rules can't say.
    private static func colorVerdict(_ expr: String, shown: String) -> Verdict {
        guard let regex = try? NSRegularExpression(pattern: "(?:0x|#)([0-9A-Fa-f]{6})(?:[0-9A-Fa-f]{2})?\\b") else {
            return .unknown
        }
        let found = regex.matches(in: expr, range: NSRange(expr.startIndex..., in: expr)).compactMap {
            Range($0.range(at: 1), in: expr).map { expr[$0].uppercased() }
        }
        guard !found.isEmpty else { return .unknown }
        return found.contains(shown) ? .matches : .excluded
    }

    private static func either(_ a: Verdict, _ b: Verdict) -> Verdict {
        if a == .matches || b == .matches { return .matches }
        if a == .excluded && b == .excluded { return .excluded }
        return .unknown
    }

    // MARK: - Templates

    /// A regex for `"a\(x)b" + y + "c"`, or nil when a part isn't a plain
    /// string literal / value (then the rules can't say).
    private static func templatePattern(_ parts: [[Character]]) -> (regex: String, hasFixedText: Bool)? {
        var regex = "", fixed = false, sawLiteral = false
        for part in parts {
            let part = stripParentheses(part)
            if part.first == "\"" {
                guard let literal = stringTemplate(part) else { return nil }
                regex += literal.regex
                fixed = fixed || literal.hasFixedText
                sawLiteral = true
            } else if parts.count > 1 {
                regex += "(?:.*)"          // `+ amount`: anything.
            } else {
                return nil
            }
        }
        return sawLiteral ? (regex, fixed) : nil
    }

    /// `"Available: \(amount)"` → `Available:\ (?:.*)`. nil for raw /
    /// multi-line literals or anything after the closing quote
    /// (`"x".uppercased()`).
    private static func stringTemplate(_ s: [Character]) -> (regex: String, hasFixedText: Bool)? {
        guard s.count >= 2, s[0] == "\"", !(s.count >= 3 && s[1] == "\"" && s[2] == "\"") else { return nil }
        var regex = "", literal = "", fixed = false
        func flush() {
            if !literal.isEmpty { regex += NSRegularExpression.escapedPattern(for: literal); fixed = true }
            literal = ""
        }
        var i = 1
        while i < s.count {
            let c = s[i]
            if c == "\"" {
                guard i == s.count - 1 else { return nil }
                flush()
                return (regex, fixed)
            }
            if c == "\\", i + 1 < s.count {
                let next = s[i + 1]
                switch next {
                case "(":
                    flush()
                    regex += "(?:.*)"
                    i = skipParentheses(s, from: i + 1)
                    continue
                case "n": literal.append("\n")
                case "t": literal.append("\t")
                case "r": literal.append("\r")
                case "0": literal.append("\0")
                case "u":
                    // `\u{00A0}`
                    guard i + 2 < s.count, s[i + 2] == "{",
                          let close = s[(i + 3)...].firstIndex(of: "}"),
                          let code = UInt32(String(s[(i + 3)..<close]), radix: 16),
                          let scalar = Unicode.Scalar(code) else { return nil }
                    literal.append(Character(scalar))
                    i = close + 1
                    continue
                default: literal.append(next)
                }
                i += 2
                continue
            }
            literal.append(c)
            i += 1
        }
        return nil
    }

    // MARK: - Scanning

    /// `(a ? b : c)` → `a ? b : c`, when the parentheses wrap all of it.
    private static func stripParentheses(_ s: [Character]) -> [Character] {
        var s = s
        while s.first == "(", skipParentheses(s, from: 0) == s.count {
            s = Array(String(s.dropFirst().dropLast()).trimmingCharacters(in: .whitespaces))
        }
        return s
    }

    /// `cond ? a : b` split at its top-level `?` and matching `:`.
    private static func splitTernary(_ s: [Character]) -> ([Character], [Character])? {
        guard let q = topLevelOperator(" ? ", in: s) else { return nil }
        var nested = 0
        var colon: Int?
        forEachTopLevel(s, from: q + 3) { i in
            if matches(" ? ", in: s, at: i) { nested += 1 }
            if matches(" : ", in: s, at: i) {
                if nested == 0 { colon = i; return false }
                nested -= 1
            }
            return true
        }
        guard let colon else { return nil }
        return (Array(s[(q + 3)..<colon]), Array(s[(colon + 3)...]))
    }

    private static func topLevelOperator(_ op: String, in s: [Character]) -> Int? {
        var found: Int?
        forEachTopLevel(s, from: 0) { i in
            if matches(op, in: s, at: i) { found = i; return false }
            return true
        }
        return found
    }

    private static func topLevelSplit(_ s: [Character], on op: String) -> [[Character]] {
        var parts: [[Character]] = []
        var start = 0
        forEachTopLevel(s, from: 0) { i in
            if i >= start, matches(op, in: s, at: i) {
                parts.append(Array(s[start..<i]))
                start = i + op.count
            }
            return true
        }
        parts.append(Array(s[min(start, s.count)...]))
        return parts
    }

    private static func matches(_ op: String, in s: [Character], at i: Int) -> Bool {
        let op = Array(op)
        guard i + op.count <= s.count else { return false }
        return Array(s[i..<(i + op.count)]) == op
    }

    /// Calls `visit` with every index outside brackets and string literals;
    /// `visit` returns false to stop.
    private static func forEachTopLevel(_ s: [Character], from start: Int, _ visit: (Int) -> Bool) {
        var i = start, depth = 0
        while i < s.count {
            let c = s[i]
            if c == "\"" { i = skipString(s, from: i); continue }
            if c == "(" || c == "[" || c == "{" {
                depth += 1
            } else if c == ")" || c == "]" || c == "}" {
                depth -= 1
            } else if depth == 0, !visit(i) {
                return
            }
            i += 1
        }
    }

    /// Index after the string literal starting at `i` (interpolations included).
    private static func skipString(_ s: [Character], from i: Int) -> Int {
        if i + 2 < s.count, s[i + 1] == "\"", s[i + 2] == "\"" {
            var j = i + 3
            while j + 2 < s.count {
                if s[j] == "\"", s[j + 1] == "\"", s[j + 2] == "\"" { return j + 3 }
                j += 1
            }
            return s.count
        }
        var j = i + 1
        while j < s.count {
            if s[j] == "\\", j + 1 < s.count {
                if s[j + 1] == "(" { j = skipParentheses(s, from: j + 1); continue }
                j += 2
                continue
            }
            if s[j] == "\"" { return j + 1 }
            j += 1
        }
        return s.count
    }

    /// Index after the `)` matching the `(` at `i`.
    private static func skipParentheses(_ s: [Character], from i: Int) -> Int {
        var j = i, depth = 0
        while j < s.count {
            let c = s[j]
            if c == "\"" { j = skipString(s, from: j); continue }
            if c == "(" { depth += 1 }
            if c == ")" {
                depth -= 1
                if depth == 0 { return j + 1 }
            }
            j += 1
        }
        return s.count
    }
}
