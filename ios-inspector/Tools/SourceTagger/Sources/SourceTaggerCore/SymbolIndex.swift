import SwiftParser
import SwiftSyntax

/// A property whose value is simple enough to follow statically:
/// `var labelToValueSpacing: CGFloat { TymeXSwiftUI.patternGapGroupTextToGroupText }`
/// or `public static let patternGapGroupTextToGroupText: CGFloat = 4`.
/// The inspector chains these from a view's token to the design token at
/// the root (and its value).
public struct SymbolEntry: Codable, Equatable {
    public let name: String
    /// Enclosing type or extended type (`TymeXSwiftUI`, `SwiftUIInputTokenProviding`).
    public let owner: String?
    public let path: String
    public let line: Int
    /// The value expression (`TymeXSwiftUI.patternGap…`, `4`, `Color(hex: "#FFF")`).
    public let expr: String
    /// Set when `expr` is a literal: the root was reached.
    public let literal: String?
    /// A function's return value (`labelColor(_:)`), not a property.
    public var function: Bool? = nil
    /// Where the names in `expr` are (for the compiler's index), when it
    /// references something.
    public var refs: [[SourceRef]]? = nil
    /// Line of the declared name (`var title`, `func labelColor`) — what
    /// the compiler's index reports — when it differs from `line` (a
    /// getter's or function's `return` lines).
    public var declLine: Int? = nil
    /// This `return` reports itself at runtime (`__mB`): the inspector can
    /// tell which branch produced a value.
    public var probed: Bool? = nil
    /// A stored property without a value (`let verticalPadding: CGFloat`):
    /// its values are the initializer arguments given for it.
    public var stored: Bool? = nil
    /// An initializer argument (`Tokens(verticalPadding: x)`): a value of
    /// the stored property `name` of type `initOf`.
    public var initOf: String? = nil
    /// Where that initializer call starts — the line a `return` probe of it reports.
    public var callLine: Int? = nil
}

enum SymbolIndexBuilder {
    static func symbols(in tree: SourceFileSyntax, path: String) -> [SymbolEntry] {
        collect(in: tree, path: path, probe: false).symbols
    }

    /// The index, and with `probe` the edits that make multi-`return`
    /// getters/functions report which `return` ran (see `BranchProbe`).
    static func collect(in tree: SourceFileSyntax, path: String, probe: Bool) -> (symbols: [SymbolEntry], probes: [Insertion]) {
        let converter = SourceLocationConverter(fileName: path, tree: tree)
        let collector = SymbolCollector(converter: converter, path: path)
        collector.probe = probe
        collector.walk(tree)
        let arguments = InitArgumentCollector(converter: converter, path: path)
        arguments.walk(tree)
        return (collector.symbols + arguments.symbols, collector.probes)
    }
}

final class SymbolCollector: SyntaxVisitor {
    private let converter: SourceLocationConverter
    private let path: String
    private var owners: [String] = []
    private(set) var symbols: [SymbolEntry] = []
    /// Instrument multi-`return` bodies (see `BranchProbe`).
    var probe = false
    private(set) var probes: [Insertion] = []

    init(converter: SourceLocationConverter, path: String) {
        self.converter = converter
        self.path = path
        super.init(viewMode: .sourceAccurate)
    }

    // Track the enclosing type.
    override func visit(_ node: StructDeclSyntax) -> SyntaxVisitorContinueKind { owners.append(node.name.text); return .visitChildren }
    override func visitPost(_ node: StructDeclSyntax) { owners.removeLast() }
    override func visit(_ node: ClassDeclSyntax) -> SyntaxVisitorContinueKind { owners.append(node.name.text); return .visitChildren }
    override func visitPost(_ node: ClassDeclSyntax) { owners.removeLast() }
    override func visit(_ node: EnumDeclSyntax) -> SyntaxVisitorContinueKind { owners.append(node.name.text); return .visitChildren }
    override func visitPost(_ node: EnumDeclSyntax) { owners.removeLast() }
    override func visit(_ node: ActorDeclSyntax) -> SyntaxVisitorContinueKind { owners.append(node.name.text); return .visitChildren }
    override func visitPost(_ node: ActorDeclSyntax) { owners.removeLast() }
    override func visit(_ node: ProtocolDeclSyntax) -> SyntaxVisitorContinueKind { owners.append(node.name.text); return .visitChildren }
    override func visitPost(_ node: ProtocolDeclSyntax) { owners.removeLast() }
    override func visit(_ node: ExtensionDeclSyntax) -> SyntaxVisitorContinueKind {
        owners.append(node.extendedType.trimmedDescription)
        return .visitChildren
    }
    override func visitPost(_ node: ExtensionDeclSyntax) { owners.removeLast() }

    /// `func labelColor(_ role:) -> Color { switch role { case .a: return X … } }`:
    /// each returned value is one possible token for `labelColor(…)`.
    /// Locals inside aren't indexed.
    override func visit(_ node: FunctionDeclSyntax) -> SyntaxVisitorContinueKind {
        guard let returnClause = node.signature.returnClause, let body = node.body else { return .skipChildren }
        let probed = probe && BranchProbe.worthProbing(returnClause.type, node.attributes)
            ? probeReturns(in: body.statements) : []
        record(name: node.name.text, returns: Self.returnedValues(of: body.statements), function: true,
               declLine: converter.location(for: node.name.positionAfterSkippingLeadingTrivia).line, probed: probed)
        return .skipChildren
    }
    override func visit(_ node: InitializerDeclSyntax) -> SyntaxVisitorContinueKind { .skipChildren }
    override func visit(_ node: ClosureExprSyntax) -> SyntaxVisitorContinueKind { .skipChildren }

    override func visit(_ node: VariableDeclSyntax) -> SyntaxVisitorContinueKind {
        for binding in node.bindings {
            guard let name = binding.pattern.as(IdentifierPatternSyntax.self)?.identifier.text else { continue }
            // `let verticalPadding: CGFloat` in a type: set by its initializers.
            if binding.initializer == nil, binding.accessorBlock == nil, binding.typeAnnotation != nil, let owner = owners.last {
                let line = converter.location(for: binding.positionAfterSkippingLeadingTrivia).line
                var entry = SymbolEntry(name: name, owner: owner, path: path, line: line, expr: "", literal: nil)
                entry.stored = true
                symbols.append(entry)
                continue
            }
            if let value = valueExpression(binding), let simple = Self.simplified(value) {
                let line = converter.location(for: binding.positionAfterSkippingLeadingTrivia).line
                var entry = SymbolEntry(name: name, owner: owners.last, path: path, line: line,
                                        expr: simple.text, literal: simple.literal)
                let refs = RefExtractor.refs(value, converter)
                if !refs.isEmpty { entry.refs = refs }
                symbols.append(entry)
            } else if let body = getterBody(binding) {
                // `var title: String { switch self { case .toggle: return "Toggle" … } }`
                let declLine = converter.location(for: binding.pattern.positionAfterSkippingLeadingTrivia).line
                let probed = probe && binding.typeAnnotation.map({ BranchProbe.worthProbing($0.type, node.attributes) }) == true
                    ? probeReturns(in: body) : []
                record(name: name, returns: Self.returnedValues(of: body), declLine: declLine, probed: probed)
            }
        }
        return .skipChildren
    }

    private func getterBody(_ binding: PatternBindingSyntax) -> CodeBlockItemListSyntax? {
        switch binding.accessorBlock?.accessors {
        case let .getter(list)?: return list
        case let .accessors(list)?: return list.first { $0.accessorSpecifier.tokenKind == .keyword(.get) }?.body?.statements
        case nil: return nil
        }
    }

    /// Instruments a body's `return`s when it has several; the offsets of
    /// the returned expressions that now report themselves.
    /// `return`s and implicit `switch`/`if` branches alike.
    private func probeReturns(in body: CodeBlockItemListSyntax) -> Set<Int> {
        let values = Self.returnedValues(of: body)
        guard values.count > 1 else { return [] }
        var probed: Set<Int> = []
        for expr in values {
            let edits = expr.parent?.as(ReturnStmtSyntax.self).flatMap { BranchProbe.edits(for: $0, converter) }
                ?? BranchProbe.wrapping(expr)
            guard let edits else { continue }
            probes += edits
            probed.insert(expr.positionAfterSkippingLeadingTrivia.utf8Offset)
        }
        return probed
    }

    private func record(name: String, returns: [ExprSyntax], function: Bool = false, declLine: Int,
                        probed: Set<Int> = []) {
        for expr in returns.prefix(64) {
            guard let simple = Self.simplified(expr) else { continue }
            let line = converter.location(for: expr.positionAfterSkippingLeadingTrivia).line
            var entry = SymbolEntry(name: name, owner: owners.last, path: path, line: line,
                                    expr: simple.text, literal: simple.literal, function: function ? true : nil)
            let refs = RefExtractor.refs(expr, converter)
            if !refs.isEmpty { entry.refs = refs }
            if declLine != line { entry.declLine = declLine }
            if probed.contains(expr.positionAfterSkippingLeadingTrivia.utf8Offset) { entry.probed = true }
            symbols.append(entry)
        }
    }

    /// Every value a body can return: `return x` anywhere (not in nested
    /// closures/functions), or the branches of an implicit `switch`/`if`.
    static func returnedValues(of body: CodeBlockItemListSyntax) -> [ExprSyntax] {
        if body.count == 1, let expr = body.first?.expression, !expr.is(SwitchExprSyntax.self), !expr.is(IfExprSyntax.self) {
            return [expr]
        }
        let finder = ReturnFinder(viewMode: .sourceAccurate)
        finder.walk(body)
        if finder.returned.isEmpty, body.count == 1, let only = body.first?.expression {
            return BranchValues.values(of: only)
        }
        return finder.returned
    }

    /// `= expr`, or a getter that is a single expression / `return expr`.
    private func valueExpression(_ binding: PatternBindingSyntax) -> ExprSyntax? {
        if let initializer = binding.initializer { return initializer.value }
        guard let accessors = binding.accessorBlock?.accessors else { return nil }
        let items: CodeBlockItemListSyntax?
        switch accessors {
        case let .getter(list): items = list
        case let .accessors(list):
            items = list.first { $0.accessorSpecifier.tokenKind == .keyword(.get) }?.body?.statements
        }
        guard let items, items.count == 1, let item = items.first else { return nil }
        if let expr = item.item.as(ExprSyntax.self) { return expr }
        if let ret = item.item.as(ReturnStmtSyntax.self) { return ret.expression }
        return nil
    }

    /// References are followed (`literal` nil); anything else — literals,
    /// initializers, gradients, logic — is the chain's root, shown as written.
    static func simplified(_ expr: ExprSyntax) -> (text: String, literal: String?)? {
        if let reference = followable(expr) { return reference }
        let text = String(expr.trimmedDescription.split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespaces) }.joined(separator: " ").prefix(1000))
        return (text, text)
    }

    /// Literals and references (the only things `followable` returns with a
    /// nil `literal` are references to follow).
    /// `c ? a : b`, folded or as parsed.
    private static func ternaryBranches(_ expr: ExprSyntax) -> [ExprSyntax]? {
        if let ternary = expr.as(TernaryExprSyntax.self) { return [ternary.thenExpression, ternary.elseExpression] }
        if let seq = expr.as(SequenceExprSyntax.self), seq.elements.count == 3,
           let mid = Array(seq.elements)[1].as(UnresolvedTernaryExprSyntax.self) {
            return [mid.thenExpression, Array(seq.elements)[2]]
        }
        return nil
    }

    private static func followable(_ expr: ExprSyntax) -> (text: String, literal: String?)? {
        if expr.is(IntegerLiteralExprSyntax.self) || expr.is(FloatLiteralExprSyntax.self)
            || expr.is(BooleanLiteralExprSyntax.self) {
            return (expr.trimmedDescription, expr.trimmedDescription)
        }
        if let string = expr.as(StringLiteralExprSyntax.self), string.segments.count == 1 {
            return (string.trimmedDescription, string.trimmedDescription)
        }
        if let prefix = expr.as(PrefixOperatorExprSyntax.self), prefix.operator.text == "-",
           let inner = followable(prefix.expression), let literal = inner.literal {
            return ("-" + inner.text, "-" + literal)
        }
        if expr.is(MemberAccessExprSyntax.self) || expr.is(DeclReferenceExprSyntax.self) {
            // `TymeXSwiftUI.spacing2`, `Self.base`, `spacing`; `.leading` is a constant.
            if let member = expr.as(MemberAccessExprSyntax.self), member.base == nil {
                return (expr.trimmedDescription, expr.trimmedDescription)
            }
            return (expr.trimmedDescription, nil)
        }
        // `loading ? tokens.loadingPadding : tokens.padding`: two alternatives
        // to follow (the refs hold both), not a root.
        if let branches = ternaryBranches(expr), branches.allSatisfy({ followable($0) != nil }) {
            let text = expr.trimmedDescription.split(whereSeparator: \.isNewline)
                .map { $0.trimmingCharacters(in: .whitespaces) }.joined(separator: " ")
            return (text, branches.allSatisfy({ followable($0)?.literal != nil }) ? text : nil)
        }
        if let call = expr.as(FunctionCallExprSyntax.self), call.trailingClosure == nil {
            // `CGFloat(TymeXDimens.x)` → follow the argument; `Color(hex: "#FFF")` → a literal.
            let args = call.arguments
            if args.count == 1, let only = args.first, only.label == nil,
               let ref = call.calledExpression.as(DeclReferenceExprSyntax.self),
               ["CGFloat", "Double", "Float", "Int", "TimeInterval"].contains(ref.baseName.text) {
                return followable(only.expression)
            }
            // `RoundedRectangle(cornerRadius: circleCornerRadius, style: .circular)`:
            // the shape's design token is its radius, so follow that.
            if let ref = call.calledExpression.as(DeclReferenceExprSyntax.self),
               ["RoundedRectangle", "UnevenRoundedRectangle"].contains(ref.baseName.text),
               let radius = args.first(where: { $0.label?.text == "cornerRadius" }),
               let inner = followable(radius.expression), inner.literal == nil {
                let text = expr.trimmedDescription.split(whereSeparator: \.isNewline)
                    .map { $0.trimmingCharacters(in: .whitespaces) }.joined(separator: " ")
                return (text, nil)
            }
            // Only type initializers of constants are values (`Color(hex: 0xFFF)`,
            // `.custom("SF", size: 16)`); `rawValue.uppercased()` is logic.
            let callee = call.calledExpression
            let isInitializer: Bool
            if let ref = callee.as(DeclReferenceExprSyntax.self) {
                isInitializer = ref.baseName.text.first?.isUppercase == true
            } else if let member = callee.as(MemberAccessExprSyntax.self) {
                isInitializer = member.base == nil
                    || member.base?.as(DeclReferenceExprSyntax.self)?.baseName.text.first?.isUppercase == true
            } else {
                isInitializer = false
            }
            if isInitializer, args.allSatisfy({ followable($0.expression)?.literal != nil }) {
                let text = expr.trimmedDescription.split(whereSeparator: \.isNewline)
                    .map { $0.trimmingCharacters(in: .whitespaces) }.joined(separator: " ")
                return (text, text)
            }
        }
        return nil
    }
}

/// `return` expressions of a function body, not of nested closures/functions.
final class ReturnFinder: SyntaxVisitor {
    private(set) var returned: [ExprSyntax] = []
    private(set) var statements: [ReturnStmtSyntax] = []
    override func visit(_ node: ReturnStmtSyntax) -> SyntaxVisitorContinueKind {
        if let expr = node.expression { returned.append(expr); statements.append(node) }
        return .skipChildren
    }
    override func visit(_ node: ClosureExprSyntax) -> SyntaxVisitorContinueKind { .skipChildren }
    override func visit(_ node: FunctionDeclSyntax) -> SyntaxVisitorContinueKind { .skipChildren }
}

/// The values of `switch`/`if` expressions (Swift 5.9 implicit returns).
enum BranchValues {
    static func values(of expr: ExprSyntax) -> [ExprSyntax] {
        if let s = expr.as(SwitchExprSyntax.self) {
            return s.cases.flatMap { element -> [ExprSyntax] in
                guard case let .switchCase(c) = element, c.statements.count == 1,
                      let value = c.statements.first?.expression else { return [] }
                return values(of: value)
            }
        }
        if let i = expr.as(IfExprSyntax.self) {
            var out: [ExprSyntax] = []
            if i.body.statements.count == 1, let v = i.body.statements.first?.expression { out += values(of: v) }
            switch i.elseBody {
            case let .ifExpr(next)?: out += values(of: ExprSyntax(next))
            case let .codeBlock(block)?:
                if block.statements.count == 1, let v = block.statements.first?.expression { out += values(of: v) }
            case nil: break
            }
            return out
        }
        return [expr]
    }
}

/// Every `Type(label: value, …)` call in a file — function bodies and
/// closures included — as candidate values of `Type.label`: design tokens
/// are often handed to a tokens struct's memberwise initializer
/// (`SwiftUIChipStyleTokens(verticalPadding: Tokens.chipVerticalPadding)`).
final class InitArgumentCollector: SyntaxVisitor {
    private let converter: SourceLocationConverter
    private let path: String
    private(set) var symbols: [SymbolEntry] = []

    init(converter: SourceLocationConverter, path: String) {
        self.converter = converter
        self.path = path
        super.init(viewMode: .sourceAccurate)
    }

    override func visit(_ node: FunctionCallExprSyntax) -> SyntaxVisitorContinueKind {
        guard let type = Self.typeName(node.calledExpression), node.arguments.contains(where: { $0.label != nil }) else {
            return .visitChildren
        }
        let callLine = converter.location(for: node.positionAfterSkippingLeadingTrivia).line
        for arg in node.arguments {
            guard let label = arg.label?.text, !arg.expression.is(ClosureExprSyntax.self),
                  let simple = SymbolCollector.simplified(arg.expression) else { continue }
            let line = converter.location(for: arg.expression.positionAfterSkippingLeadingTrivia).line
            var entry = SymbolEntry(name: label, owner: type, path: path, line: line, expr: simple.text, literal: simple.literal)
            let refs = RefExtractor.refs(arg.expression, converter)
            if !refs.isEmpty { entry.refs = refs }
            entry.initOf = type
            entry.callLine = callLine
            symbols.append(entry)
        }
        return .visitChildren
    }

    /// `Tokens(…)`, `Module.Tokens(…)`: the type's own name; nil for calls.
    private static func typeName(_ callee: ExprSyntax) -> String? {
        let name: String?
        if let ref = callee.as(DeclReferenceExprSyntax.self) {
            name = ref.baseName.text
        } else if let member = callee.as(MemberAccessExprSyntax.self), member.base != nil {
            name = member.declName.baseName.text
        } else {
            name = nil
        }
        guard let name, name.first?.isUppercase == true, !swiftUIViews.contains(name) else { return nil }
        return name
    }

    /// Views and SDK values whose arguments aren't a type's stored properties.
    private static let swiftUIViews: Set<String> = [
        "VStack", "HStack", "ZStack", "LazyVStack", "LazyHStack", "Text", "Image", "Button", "Label", "Spacer",
        "RoundedRectangle", "Rectangle", "Capsule", "Circle", "Color", "Font", "EdgeInsets", "CGSize", "CGPoint",
        "CGRect", "LinearGradient", "RadialGradient", "ScrollView", "ForEach", "Group", "NavigationView", "Toggle",
        "TextField", "Picker", "Menu", "GeometryReader", "Divider", "Canvas", "UIImage", "UIColor", "UIFont",
    ]
}
