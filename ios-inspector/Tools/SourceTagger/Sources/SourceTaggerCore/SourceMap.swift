import SwiftSyntax

/// What a tagged view expression was written with, so the inspector can
/// name the design tokens behind runtime values
/// (`spacing: 4` ← `tokenProvider.fieldToHelperSpacing`).
///
/// Written per source file as `<map dir>/<repo-relative path>.json`:
/// `{ "path:line:col": Entry }`, keyed exactly like the runtime tag.
public struct SourceMapEntry: Codable, Equatable {
    public struct Argument: Codable, Equatable {
        /// `spacing`, `alignment`, or nil for unlabeled (`.padding(.vertical, x)`).
        public let label: String?
        public let expr: String
        /// False for literals and plain constants (`8`, `.leading`,
        /// `.infinity`, `Color.red`) — "hardcoded"; true for anything that
        /// reads a value (`tokenProvider.spacing`, `TymeXSwiftUI.spacing2`).
        public let token: Bool
        /// Where the names it reads are, for the compiler's index:
        /// alternatives (`a ? x : y`) of ordered fallbacks (callee, then args).
        public var refs: [[SourceRef]]? = nil
        /// When the argument is a local (`uiImage`), what it was bound to
        /// (`UIImage(named: Constants.iconName, …)`); `refs` point into that.
        public var binding: String? = nil
        /// This argument's number in the tag's runtime record (`__mT`),
        /// when the tagged build reports what it evaluated to.
        public var probe: Int? = nil
        /// A corner radius written inside it (`RoundedRectangle(cornerRadius: r).fill(c)`,
        /// `x.cornerRadius(r)`): its own expression and refs, since the
        /// argument's refs lead to the fill first. At most one element.
        public var radius: [Argument]? = nil
    }

    /// The function / type the tagged view is written in, so a bare name
    /// (`style`, `label`) can be traced to the call that supplied it.
    public struct Scope: Codable, Equatable {
        public struct Parameter: Codable, Equatable {
            /// Name inside the body (`style`).
            public let name: String
            /// Label at call sites (`style`), nil for `_`.
            public let label: String?
        }
        public var function: String?
        public var parameters: [Parameter]?
        public var type: String?
    }

    public struct Modifier: Codable, Equatable {
        public let name: String
        public let args: [Argument]
    }

    /// The view the chain starts from: `VStack`, `Text`, `HelperRow`.
    public let call: String
    public let args: [Argument]
    /// Modifiers in source order (first = innermost).
    public let mods: [Modifier]
    public var scope: Scope? = nil
}

/// A name read at a place in the original source (1-based line/column).
public struct SourceRef: Codable, Equatable {
    public let name: String
    public let line: Int
    public let column: Int
}

enum RefExtractor {
    /// The names a value expression reads, as index lookup candidates:
    /// `[[alternative 1 fallbacks], [alternative 2 fallbacks]]`.
    static func refs(_ expr: ExprSyntax, _ converter: SourceLocationConverter, depth: Int = 0) -> [[SourceRef]] {
        guard depth < 4 else { return [] }
        if let ternary = expr.as(TernaryExprSyntax.self) {
            return refs(ternary.thenExpression, converter, depth: depth + 1)
                + refs(ternary.elseExpression, converter, depth: depth + 1)
        }
        if let seq = expr.as(SequenceExprSyntax.self), seq.elements.count == 3,
           seq.elements.dropFirst().first?.is(UnresolvedTernaryExprSyntax.self) == true {
            // Unfolded `c ? a : b`: [cond, `? a :`, b] as parsed.
            let elements = Array(seq.elements)
            if let mid = elements[1].as(UnresolvedTernaryExprSyntax.self) {
                return refs(mid.thenExpression, converter, depth: depth + 1)
                    + refs(elements[2], converter, depth: depth + 1)
            }
        }
        let chain = fallbacks(expr, converter, depth: depth)
        return chain.isEmpty ? [] : [chain]
    }

    /// Ordered candidates within one alternative.
    private static func fallbacks(_ expr: ExprSyntax, _ converter: SourceLocationConverter, depth: Int) -> [SourceRef] {
        func ref(_ token: TokenSyntax) -> SourceRef {
            let loc = converter.location(for: token.positionAfterSkippingLeadingTrivia)
            return SourceRef(name: token.text, line: loc.line, column: loc.column)
        }
        if let tuple = expr.as(TupleExprSyntax.self), tuple.elements.count == 1, let only = tuple.elements.first {
            return fallbacks(only.expression, converter, depth: depth)
        }
        if let force = expr.as(ForceUnwrapExprSyntax.self) { return fallbacks(force.expression, converter, depth: depth) }
        if let optional = expr.as(OptionalChainingExprSyntax.self) { return fallbacks(optional.expression, converter, depth: depth) }
        if let member = expr.as(MemberAccessExprSyntax.self) {
            guard let base = member.base else { return [] }               // `.leading`
            // `Constants.slotSize.width`: `width` is CGSize's (SDK); the
            // token is `slotSize`, so the base chain is the fallback.
            return [ref(member.declName.baseName)] + fallbacks(base, converter, depth: depth + 1)
        }
        if let decl = expr.as(DeclReferenceExprSyntax.self) { return [ref(decl.baseName)] }
        if let call = expr.as(FunctionCallExprSyntax.self) {
            // The function called first (`labelColor(…)` is the token), then
            // what it's built from (`RoundedRectangle(cornerRadius: X)`,
            // `Capsule().fill(X)`), then the receiver chain.
            var out: [SourceRef] = []
            var callee = call.calledExpression
            if let generic = callee.as(GenericSpecializationExprSyntax.self) { callee = generic.expression }
            if let member = callee.as(MemberAccessExprSyntax.self) {
                if member.base != nil { out.append(ref(member.declName.baseName)) }
            } else if let decl = callee.as(DeclReferenceExprSyntax.self), decl.baseName.text.first?.isLowercase == true {
                out.append(ref(decl.baseName))
            }
            for arg in call.arguments where !arg.expression.is(ClosureExprSyntax.self) {
                out += refs(arg.expression, converter, depth: depth + 1).flatMap { $0 }
            }
            if let member = callee.as(MemberAccessExprSyntax.self), let base = member.base {
                out += fallbacks(base, converter, depth: depth + 1)
            }
            return out
        }
        return []
    }
}

enum SourceMapBuilder {
    /// `VStack(spacing: s) { … }.padding(p).background(b)` → entry.
    static func entry(for expr: ExprSyntax, converter: SourceLocationConverter? = nil,
                      bindings: (String) -> ExprSyntax? = { _ in nil },
                      strip: Set<String> = [],
                      probe: (ExprSyntax) -> Int? = { _ in nil }) -> SourceMapEntry? {
        var mods: [SourceMapEntry.Modifier] = []
        var current = expr
        while true {
            guard let call = current.as(FunctionCallExprSyntax.self) else {
                // A chain on a value (`image.resizable()…`, `Self.icon.frame(…)`):
                // the value is the root, and its only "argument" is itself,
                // so the token behind it can still be traced.
                // A value's name starts lowercase (`image`, `Self.icon`); `SwiftUI`, `Color` are types.
                let name = current.as(DeclReferenceExprSyntax.self)?.baseName.text
                    ?? current.as(MemberAccessExprSyntax.self).flatMap { $0.base == nil ? nil : $0.declName.baseName.text }
                guard !mods.isEmpty, name?.first?.isLowercase == true else { return nil }
                let root = argument(current, label: nil, converter: converter, bindings: bindings, probe: probe)
                return SourceMapEntry(call: root.expr, args: [root], mods: mods.reversed())
            }
            var callee = call.calledExpression
            if let generic = callee.as(GenericSpecializationExprSyntax.self) { callee = generic.expression }
            // `SwiftUI.Toggle(…)`: a qualified type, not a modifier on `SwiftUI`.
            if let member = callee.as(MemberAccessExprSyntax.self), member.base != nil,
               member.declName.baseName.text.first?.isUppercase == true {
                let args = arguments(of: call, converter: converter, bindings: bindings, probe: probe)
                return SourceMapEntry(call: member.declName.baseName.text, args: args, mods: mods.reversed())
            }
            if let member = callee.as(MemberAccessExprSyntax.self), let base = member.base {
                // Stripped modifiers aren't in the built app, so not in the map.
                if !strip.contains(member.declName.baseName.text) {
                    let args = arguments(of: call, converter: converter, bindings: bindings, probe: probe)
                    mods.append(.init(name: member.declName.baseName.text, args: args))
                }
                current = base
                continue
            }
            guard let ref = callee.as(DeclReferenceExprSyntax.self) else { return nil }
            let args = arguments(of: call, converter: converter, bindings: bindings, probe: probe)
            return SourceMapEntry(call: ref.baseName.text, args: args, mods: mods.reversed())
        }
    }

    private static func arguments(of call: FunctionCallExprSyntax, converter: SourceLocationConverter?,
                                  bindings: (String) -> ExprSyntax?,
                                  probe: (ExprSyntax) -> Int?) -> [SourceMapEntry.Argument] {
        call.arguments.compactMap { arg in
            // Closures are content, not values.
            if arg.expression.is(ClosureExprSyntax.self) { return nil }
            return argument(arg.expression, label: arg.label?.text, converter: converter, bindings: bindings, probe: probe)
        }
    }

    private static func argument(_ expr: ExprSyntax, label: String?, converter: SourceLocationConverter?,
                                 bindings: (String) -> ExprSyntax?,
                                 probe: (ExprSyntax) -> Int?) -> SourceMapEntry.Argument {
        let text = expr.trimmedDescription
            .split(whereSeparator: \.isNewline).map { $0.trimmingCharacters(in: .whitespaces) }.joined(separator: " ")
        let token = isToken(expr)
        var argument = SourceMapEntry.Argument(label: label, expr: String(text.prefix(160)), token: token)
        if token, !TokenProbe.callbackLabels.contains(label ?? "") { argument.probe = probe(expr) }
        if token, label != "cornerRadius", let radius = cornerRadiusExpression(in: expr) {
            argument.radius = [self.argument(radius, label: "cornerRadius", converter: converter, bindings: bindings,
                                             probe: { _ in nil })]
        }
        if token, let converter {
            // A local (`uiImage`): what it was bound to, not the name.
            if let ref = expr.as(DeclReferenceExprSyntax.self), let bound = bindings(ref.baseName.text) {
                argument.binding = String(bound.trimmedDescription.split(whereSeparator: \.isNewline)
                    .map { $0.trimmingCharacters(in: .whitespaces) }.joined(separator: " ").prefix(200))
                let refs = RefExtractor.refs(bound, converter)
                if !refs.isEmpty { argument.refs = refs }
            } else {
                let refs = RefExtractor.refs(expr, converter)
                if !refs.isEmpty { argument.refs = refs }
            }
        }
        return argument
    }

    /// The first `cornerRadius:` argument or `.cornerRadius(x)` call inside an expression.
    private static func cornerRadiusExpression(in expr: ExprSyntax) -> ExprSyntax? {
        var stack: [Syntax] = [Syntax(expr)]
        while let node = stack.popLast() {
            if let call = node.as(FunctionCallExprSyntax.self) {
                if let arg = call.arguments.first(where: { $0.label?.text == "cornerRadius" }) { return arg.expression }
                if call.calledExpression.as(MemberAccessExprSyntax.self)?.declName.baseName.text == "cornerRadius",
                   let only = call.arguments.first { return only.expression }
            }
            if node.is(ClosureExprSyntax.self) { continue }
            stack += node.children(viewMode: .sourceAccurate).reversed()
        }
        return nil
    }

    /// Types whose static members are plain constants, not design tokens.
    private static let constantTypes: Set<String> = [
        "Color", "UIColor", "Font", "CGFloat", "Double", "Int", "Float", "Edge", "Alignment",
        "HorizontalAlignment", "VerticalAlignment", "Axis", "Angle", "UnitPoint", "EdgeInsets",
        "ContentMode", "TextAlignment", "Visibility", "ColorScheme", "Animation", "CGSize", "CGPoint",
    ]

    /// Hardcoded: literals, `.member`, `-8`, `Color.red`, `CGFloat(8)`,
    /// `EdgeInsets(top: 4, …)` of literals. Everything else reads a value.
    static func isToken(_ expr: ExprSyntax) -> Bool {
        if expr.is(IntegerLiteralExprSyntax.self) || expr.is(FloatLiteralExprSyntax.self)
            || expr.is(BooleanLiteralExprSyntax.self) || expr.is(StringLiteralExprSyntax.self)
            || expr.is(NilLiteralExprSyntax.self) {
            return false
        }
        if let prefix = expr.as(PrefixOperatorExprSyntax.self) { return isToken(prefix.expression) }
        if let member = expr.as(MemberAccessExprSyntax.self) {
            guard let base = member.base else { return false }                 // `.leading`
            if let ref = base.as(DeclReferenceExprSyntax.self) {
                return !constantTypes.contains(ref.baseName.text)               // `Color.red` vs `Tokens.x`
            }
            return true
        }
        if let call = expr.as(FunctionCallExprSyntax.self) {
            // `.init(8)`, `CGFloat(12)`, `EdgeInsets(top: 4, …)`, `Color(red: 1, …)` of constants.
            let calleeIsConstant: Bool
            if let member = call.calledExpression.as(MemberAccessExprSyntax.self) {
                calleeIsConstant = member.base == nil
                    || member.base.flatMap { $0.as(DeclReferenceExprSyntax.self) }.map { constantTypes.contains($0.baseName.text) } == true
            } else if let ref = call.calledExpression.as(DeclReferenceExprSyntax.self) {
                calleeIsConstant = constantTypes.contains(ref.baseName.text)
            } else {
                calleeIsConstant = false
            }
            if calleeIsConstant { return call.arguments.contains { isToken($0.expression) } }
            return true
        }
        if let tuple = expr.as(TupleExprSyntax.self), tuple.elements.count == 1, let only = tuple.elements.first {
            return isToken(only.expression)
        }
        return true
    }
}
