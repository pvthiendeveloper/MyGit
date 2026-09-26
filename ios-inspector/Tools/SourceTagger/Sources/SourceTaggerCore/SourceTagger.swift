import SwiftParser
import SwiftSyntax

/// Tags every SwiftUI view expression in a file with its source location:
///
///     Text("Helper")
///  →  Text("Helper").preference(key: __MyGitSourceKey.self, value: "Sources/HelperRow.swift:19:13")
///
/// `.preference` with a file-private key is one of the few modifiers SwiftUI
/// keeps as a node in its view debug data (custom `ViewModifier`s and
/// `.environment` are inlined away), and nothing reads the key, so the app
/// behaves the same. Tags are inserted on the expression's own last line, so
/// every line number in the file stays where it was; the key type is appended
/// after the last line.
///
/// Only view-builder contexts are touched — `var body: some View`,
/// `@ViewBuilder` members, and closures handed to SwiftUI containers or
/// view-shaped labels — and within them only statements that are clearly
/// views (a chain rooted in a call to an uppercase type: `Text(…)`,
/// `HelperRow(…).padding()`). Anything unsure is left alone: a missed tag
/// only makes the inspector fall back to the enclosing one.
public enum SourceTagger {
    public struct Result {
        public let output: String
        public let tagCount: Int
        /// "path:line:col" → what the tagged expression was written with.
        public var sourceMap: [String: SourceMapEntry] = [:]
        /// Simple-valued properties declared in the file, for token chains.
        public var symbols: [SymbolEntry] = []
    }

    public static let keyName = "__MyGitSourceKey"
    /// Tags on chains that restyle an incoming view (`content.padding(…)`,
    /// `configuration.label.background(…)`): read for tokens, never as the
    /// place a view is written.
    public static let styleKeyName = "__MyGitStyleKey"

    /// Only the property index (for files that can't hold views).
    public static func symbols(source: String, path: String) -> [SymbolEntry] {
        SymbolIndexBuilder.symbols(in: Parser.parse(source: source), path: path)
    }

    /// Cheap byte scan before parsing: files that can't hold SwiftUI views
    /// are copied as they are.
    public static func mightContainViews(_ bytes: UnsafeBufferPointer<UInt8>) -> Bool {
        contains(bytes, "SwiftUI") && (contains(bytes, "View") || contains(bytes, "@ViewBuilder"))
    }

    /// - Parameter path: the file's path relative to the repository root, as
    ///   recorded in the tags (so the inspector opens the original file).
    /// - Parameter stripModifiers: modifier names whose calls are removed
    ///   from view chains (`debugLayoutBounds`): debug overlays that would
    ///   clutter the inspected tree. Lines are kept, so tags still match.
    /// - Parameter probeTokens: wrap token arguments so the app reports
    ///   what they evaluated to (see `TokenProbe`).
    public static func tag(source: String, path: String, stripModifiers: Set<String> = [],
                           probeTokens: Bool = true) -> Result {
        let tree = Parser.parse(source: source)
        let (symbols, probes) = SymbolIndexBuilder.collect(in: tree, path: path, probe: importsFoundation(tree))
        guard importsSwiftUI(tree) else {
            return Result(output: splice(source, probes, probes.isEmpty ? nil : BranchProbe.declaration(path: escaped(path))),
                          tagCount: 0, symbols: symbols)
        }

        let collector = Collector(converter: SourceLocationConverter(fileName: path, tree: tree),
                                  path: escaped(path), rawPath: path, stripModifiers: stripModifiers,
                                  probeTokens: probeTokens)
        collector.walk(tree)
        if !stripModifiers.isEmpty {
            // Anywhere in the file, not only where tags go: a custom
            // container's closure (`{ amount.debugLayoutBounds(…) }`) counts too.
            StripFinder(names: stripModifiers, collector: collector).walk(tree)
        }
        let tagCount = collector.insertions.filter { $0.length == 0 && $0.text.contains(".preference(key: \(keyName)") }.count
        guard !collector.insertions.isEmpty || !probes.isEmpty else { return Result(output: source, tagCount: 0, symbols: symbols) }

        var trailer = tagCount > 0 || collector.usesStyleTag ? keyDeclaration : ""
        if collector.usesTokenProbe { trailer += TokenProbe.declaration }
        if !probes.isEmpty { trailer += BranchProbe.declaration(path: escaped(path)) }
        return Result(output: splice(source, collector.insertions + probes, trailer.isEmpty ? nil : trailer),
                      tagCount: tagCount, sourceMap: collector.sourceMap, symbols: symbols)
    }

    /// Only the `return` probes (for files that can't hold views): the
    /// rewritten source, or nil when nothing was probed.
    public static func probe(source: String, path: String) -> (output: String, symbols: [SymbolEntry])? {
        let tree = Parser.parse(source: source)
        guard importsFoundation(tree) else { return nil }
        let (symbols, probes) = SymbolIndexBuilder.collect(in: tree, path: path, probe: true)
        guard !probes.isEmpty else { return nil }
        return (splice(source, probes, BranchProbe.declaration(path: escaped(path))), symbols)
    }

    /// One linear splice over the UTF-8 bytes, edits in offset order (a
    /// removal before an insertion at its end), then `trailer` after the
    /// last line.
    private static func splice(_ source: String, _ insertions: [Insertion], _ trailer: String?) -> String {
        guard !insertions.isEmpty || trailer != nil else { return source }
        let edits = insertions.sorted { ($0.offset, -$0.length) < ($1.offset, -$1.length) }
        let utf8 = Array(source.utf8)
        var out: [UInt8] = []
        out.reserveCapacity(utf8.count + edits.count * 96 + 1024)
        var cursor = 0
        for edit in edits where edit.offset >= cursor && edit.offset + edit.length <= utf8.count {
            out.append(contentsOf: utf8[cursor..<edit.offset])
            out.append(contentsOf: edit.text.utf8)
            cursor = edit.offset + edit.length
        }
        out.append(contentsOf: utf8[cursor...])
        if let trailer {
            if out.last != UInt8(ascii: "\n") { out.append(UInt8(ascii: "\n")) }
            out.append(contentsOf: trailer.utf8)
        }
        return String(decoding: out, as: UTF8.self)
    }

    static let keyDeclaration = """
    fileprivate struct \(keyName): SwiftUI.PreferenceKey { static var defaultValue: String? { nil }; \
    static func reduce(value: inout String?, nextValue: () -> String?) {} } // MyGit UI Inspector source tags
    fileprivate struct \(styleKeyName): SwiftUI.PreferenceKey { static var defaultValue: String? { nil }; \
    static func reduce(value: inout String?, nextValue: () -> String?) {} } // MyGit UI Inspector style tags

    """

    /// Whether `Thread` & co. are visible for the branch probe.
    private static func importsFoundation(_ tree: SourceFileSyntax) -> Bool {
        tree.statements.contains { item in
            guard let imp = item.item.as(ImportDeclSyntax.self), let module = imp.path.first?.name.text else { return false }
            return ["SwiftUI", "UIKit", "Foundation", "AppKit"].contains(module)
        }
    }

    private static func importsSwiftUI(_ tree: SourceFileSyntax) -> Bool {
        for item in tree.statements {
            if let imp = item.item.as(ImportDeclSyntax.self),
               imp.path.first?.name.text == "SwiftUI" { return true }
        }
        return false
    }

    private static func escaped(_ s: String) -> String {
        s.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
    }

    private static func contains(_ haystack: UnsafeBufferPointer<UInt8>, _ needle: StaticString) -> Bool {
        let n = needle.utf8CodeUnitCount
        guard n > 0, haystack.count >= n else { return false }
        let first = needle.utf8Start[0]
        var i = 0
        let last = haystack.count - n
        while i <= last {
            if haystack[i] == first {
                var j = 1
                while j < n, haystack[i + j] == needle.utf8Start[j] { j += 1 }
                if j == n { return true }
            }
            i += 1
        }
        return false
    }
}

// MARK: - Collection

/// Finds `.name(…)` calls (with a receiver) for the names being stripped.
final class StripFinder: SyntaxVisitor {
    private let names: Set<String>
    private let collector: Collector

    init(names: Set<String>, collector: Collector) {
        self.names = names
        self.collector = collector
        super.init(viewMode: .sourceAccurate)
    }

    override func visit(_ node: FunctionCallExprSyntax) -> SyntaxVisitorContinueKind {
        if let member = node.calledExpression.as(MemberAccessExprSyntax.self), member.base != nil,
           names.contains(member.declName.baseName.text) {
            collector.strip(member, node)
        }
        return .visitChildren
    }
}

/// Text to put at `offset`, replacing `length` bytes (0 = pure insertion).
struct Insertion {
    let offset: Int
    let text: String
    var length = 0
}

/// Finds view-builder contexts among declarations and records where tags go.
final class Collector: SyntaxVisitor {
    private let converter: SourceLocationConverter
    private let path: String
    private let rawPath: String
    private(set) var insertions: [Insertion] = []
    private(set) var sourceMap: [String: SourceMapEntry] = [:]
    /// Some tag's arguments are wrapped in `__mT` (see `TokenProbe`).
    private(set) var usesTokenProbe = false
    /// Some chain restyles an incoming view and got a style tag.
    private(set) var usesStyleTag = false

    private let stripModifiers: Set<String>
    private var stripped: Set<Int> = []

    private let probeTokens: Bool

    init(converter: SourceLocationConverter, path: String, rawPath: String, stripModifiers: Set<String> = [],
         probeTokens: Bool = true) {
        self.stripModifiers = stripModifiers
        self.probeTokens = probeTokens
        self.converter = converter
        self.path = path
        self.rawPath = rawPath
        super.init(viewMode: .sourceAccurate)
    }

    // `var body: some View { … }`, `@ViewBuilder var header: some View { … }`
    override func visit(_ node: VariableDeclSyntax) -> SyntaxVisitorContinueKind {
        let builderAttr = node.attributes.hasViewBuilder
        for binding in node.bindings {
            guard let type = binding.typeAnnotation?.type, Rules.isViewType(type) else { continue }
            let name = binding.pattern.as(IdentifierPatternSyntax.self)?.identifier.text
            let isBuilder = builderAttr || name == "body" || name == "previews"
            for block in getterBodies(binding) {
                if isBuilder { builderBody(block) } else { plainBody(block) }
            }
        }
        return .skipChildren
    }

    // `@ViewBuilder func row() -> some View`, `func body(content:) -> some View`
    override func visit(_ node: FunctionDeclSyntax) -> SyntaxVisitorContinueKind {
        guard let type = node.signature.returnClause?.type, Rules.isViewType(type),
              let body = node.body else { return .skipChildren }
        let isBuilder = node.attributes.hasViewBuilder || node.name.text == "body"
        let saved = function
        function = (node.name.text, node.signature.parameterClause.parameters.map { p in
            let label = p.firstName.text == "_" ? nil : p.firstName.text
            return .init(name: (p.secondName ?? p.firstName).text, label: label)
        })
        if isBuilder { builderBody(body.statements) } else { plainBody(body.statements) }
        function = saved
        return .skipChildren
    }

    /// Inside `extension View { … }`: helpers that restyle `self`.
    private var viewExtensionDepth = 0
    /// Enclosing type names and the function being tagged, for `Scope`.
    private var types: [String] = []
    private var function: (name: String, parameters: [SourceMapEntry.Scope.Parameter])?

    override func visit(_ node: ExtensionDeclSyntax) -> SyntaxVisitorContinueKind {
        let extended = node.extendedType.trimmedDescription
        if extended == "View" || extended == "SwiftUI.View" { viewExtensionDepth += 1 }
        types.append(extended)
        return .visitChildren
    }
    override func visitPost(_ node: ExtensionDeclSyntax) {
        let extended = node.extendedType.trimmedDescription
        if extended == "View" || extended == "SwiftUI.View" { viewExtensionDepth -= 1 }
        types.removeLast()
    }
    override func visit(_ node: StructDeclSyntax) -> SyntaxVisitorContinueKind { types.append(node.name.text); return .visitChildren }
    override func visitPost(_ node: StructDeclSyntax) { types.removeLast() }
    override func visit(_ node: ClassDeclSyntax) -> SyntaxVisitorContinueKind { types.append(node.name.text); return .visitChildren }
    override func visitPost(_ node: ClassDeclSyntax) { types.removeLast() }
    override func visit(_ node: EnumDeclSyntax) -> SyntaxVisitorContinueKind { types.append(node.name.text); return .visitChildren }
    override func visitPost(_ node: EnumDeclSyntax) { types.removeLast() }

    private func currentScope() -> SourceMapEntry.Scope {
        SourceMapEntry.Scope(function: function?.name,
                             parameters: function?.parameters.isEmpty == false ? function?.parameters : nil,
                             type: types.last)
    }

    // Macros like #Preview expand in their own context; leave them be.
    override func visit(_ node: MacroExpansionDeclSyntax) -> SyntaxVisitorContinueKind { .skipChildren }

    private func getterBodies(_ binding: PatternBindingSyntax) -> [CodeBlockItemListSyntax] {
        guard let accessors = binding.accessorBlock?.accessors else { return [] }
        switch accessors {
        case let .getter(items):
            return [items]
        case let .accessors(list):
            return list.compactMap { $0.accessorSpecifier.tokenKind == .keyword(.get) ? $0.body?.statements : nil }
        }
    }

    // MARK: Bodies

    /// A result-builder body — unless it uses `return`, which switches the
    /// builder off and makes it ordinary code.
    private func builderBody(_ items: CodeBlockItemListSyntax) {
        if items.containsTopLevelReturn { plainBody(items) } else { builderItems(items) }
    }

    /// Ordinary code returning a view: tag what's returned (or the single
    /// implicit-return expression) and look inside it.
    private func plainBody(_ items: CodeBlockItemListSyntax) {
        // Several statements, a view among them, and no `return` anywhere: only
        // a result builder compiles that — one inherited from a protocol
        // (`ButtonStyle.makeBody`, `ViewModifier.body(content:)`, …).
        if items.count > 1, items.contains(where: { $0.expression != nil }) {
            let finder = ReturnFinder(viewMode: .sourceAccurate)
            finder.walk(items)
            if finder.statements.isEmpty {
                builderItems(items)
                return
            }
        }
        withScope {
            // The function returns a view, so what it returns is one.
            if items.count == 1, let expr = items.first?.expression {
                viewExpression(expr, trusted: true)
                return
            }
            for item in items {
                recordBindings(item)
                if let ret = item.item.as(ReturnStmtSyntax.self), let expr = ret.expression {
                    viewExpression(expr, trusted: true)
                }
            }
        }
    }

    /// Each statement of a view builder is one child view.
    // MARK: Local bindings

    /// `let x = …`, `if let x = …`, `guard let x = …` visible at this point,
    /// innermost scope last. The index doesn't record locals, so an argument
    /// that's just `x` is mapped to its initializer instead.
    private var bindings: [[String: ExprSyntax]] = []

    private func lookupBinding(_ name: String) -> ExprSyntax? {
        for scope in bindings.reversed() { if let expr = scope[name] { return expr } }
        return nil
    }

    private func withScope(_ initial: [String: ExprSyntax] = [:], _ body: () -> Void) {
        bindings.append(initial)
        body()
        bindings.removeLast()
    }

    /// Record `let`/`guard let` bindings a statement introduces.
    private func recordBindings(_ item: CodeBlockItemSyntax) {
        if let decl = item.item.as(VariableDeclSyntax.self) {
            for binding in decl.bindings {
                if let name = binding.pattern.as(IdentifierPatternSyntax.self)?.identifier.text,
                   let value = binding.initializer?.value {
                    bindings[bindings.count - 1][name] = value
                }
            }
        } else if let guardStmt = item.item.as(GuardStmtSyntax.self) {
            for (name, value) in Self.conditionBindings(guardStmt.conditions) {
                bindings[bindings.count - 1][name] = value
            }
        }
    }

    /// `if let x = expr, let y = expr` → [x: expr, y: expr].
    private static func conditionBindings(_ conditions: ConditionElementListSyntax) -> [String: ExprSyntax] {
        var out: [String: ExprSyntax] = [:]
        for element in conditions {
            if case let .optionalBinding(binding) = element.condition,
               let name = binding.pattern.as(IdentifierPatternSyntax.self)?.identifier.text,
               let value = binding.initializer?.value {
                out[name] = value
            }
        }
        return out
    }

    /// `case let .icon(image)` / `case .icon(let image)` in `switch trailing`
    /// → [image: trailing]: the payload comes from the subject, which can
    /// be traced where a bare `image` can't.
    private static func caseBindings(_ label: SwitchCaseSyntax.Label, subject: ExprSyntax) -> [String: ExprSyntax] {
        guard case let .case(caseLabel) = label else { return [:] }
        var out: [String: ExprSyntax] = [:]
        func walk(_ node: Syntax) {
            if let id = node.as(IdentifierPatternSyntax.self) { out[id.identifier.text] = subject }
            for child in node.children(viewMode: .sourceAccurate) { walk(child) }
        }
        for item in caseLabel.caseItems { walk(Syntax(item.pattern)) }
        return out
    }

    private func builderItems(_ items: CodeBlockItemListSyntax) {
        withScope { builderItemsInScope(items) }
    }

    private func builderItemsInScope(_ items: CodeBlockItemListSyntax) {
        for item in items {
            recordBindings(item)
            if let expr = item.expression {
                builderStatement(expr)
            } else if let ifConfig = item.item.as(IfConfigDeclSyntax.self) {
                for clause in ifConfig.clauses {
                    if case let .statements(list)? = clause.elements { builderItems(list) }
                }
            }
        }
    }

    private func builderStatement(_ expr: ExprSyntax) {
        if let ifExpr = expr.as(IfExprSyntax.self) {
            builderIf(ifExpr)
        } else if let switchExpr = expr.as(SwitchExprSyntax.self) {
            for element in switchExpr.cases {
                if case let .switchCase(c) = element {
                    withScope(Self.caseBindings(c.label, subject: switchExpr.subject)) { builderItemsInScope(c.statements) }
                }
            }
        } else {
            // Every statement of a view builder has to be a view, so even
            // `labelText(style: …)` or `content` can carry a tag.
            viewExpression(expr, trusted: true)
        }
    }

    private func builderIf(_ ifExpr: IfExprSyntax) {
        withScope(Self.conditionBindings(ifExpr.conditions)) { builderItemsInScope(ifExpr.body.statements) }
        switch ifExpr.elseBody {
        case let .ifExpr(next)?: builderIf(next)
        case let .codeBlock(block)?: builderItems(block.statements)
        case nil: break
        }
    }

    /// Tag a view expression, then descend into the builder closures it
    /// passes along (`VStack { … }`, `.overlay { … }`).
    /// - Parameter trusted: the context guarantees a view (a builder
    ///   statement, a returned value); otherwise only view-shaped chains.
    private func viewExpression(_ expr: ExprSyntax, trusted: Bool = false) {
        // `content.overlay { Badge() }` outside a builder: the root isn't
        // taggable, but the closures along the chain still are.
        // `content.font(…)` in a ViewModifier, `modifier(…)` / `self.padding()`
        // in `extension View`: the same view, restyled. A tag there would
        // outrank the call site the user wrote, so only look inside.
        // Tagged anyway, with the style key: its padding, background, radius…
        // are the style's tokens, but it isn't where the view is written.
        let restyle = restylesIncomingView(expr)
        guard restyle || Rules.isViewLike(expr) || (trusted && Rules.canCarryTag(expr)) else {
            descend(expr)
            return
        }
        if restyle, !Rules.isPostfixChain(expr) || !expr.is(FunctionCallExprSyntax.self) {
            descend(expr)       // `content` alone: nothing to record
            return
        }
        let start = converter.location(for: expr.positionAfterSkippingLeadingTrivia)
        // `a ? B() : C()` / `x ?? y`: wrap, so the tag applies to the whole
        // expression — on the same line, so nothing moves.
        let wrap = !Rules.isPostfixChain(expr)
        if wrap {
            insertions.append(Insertion(offset: expr.positionAfterSkippingLeadingTrivia.utf8Offset, text: "("))
        }
        let tag = "\(path):\(start.line):\(start.column)"
        var probed = 0
        let probe: (ExprSyntax) -> Int? = { arg in
            guard self.probeTokens, TokenProbe.probeable(arg) else { return nil }
            probed += 1
            self.insertions += TokenProbe.edits(for: arg, tag: tag, index: probed)
            return probed
        }
        if var entry = SourceMapBuilder.entry(for: expr, converter: converter, bindings: lookupBinding,
                                              strip: stripModifiers, probe: probe) {
            entry.scope = currentScope()
            sourceMap["\(rawPath):\(start.line):\(start.column)"] = entry
        }
        if probed > 0 { usesTokenProbe = true }
        if restyle { usesStyleTag = true }
        let value = probed > 0 ? "__mS(\"\(tag)\")" : "\"\(tag)\""
        let key = restyle ? SourceTagger.styleKeyName : SourceTagger.keyName
        insertions.append(Insertion(
            offset: expr.endPositionBeforeTrailingTrivia.utf8Offset,
            text: (wrap ? ")" : "") + ".preference(key: \(key).self, value: \(value))"
        ))
        descend(expr)
    }

    private func restylesIncomingView(_ expr: ExprSyntax) -> Bool {
        var current = expr
        while true {
            if let call = current.as(FunctionCallExprSyntax.self) {
                if let member = call.calledExpression.as(MemberAccessExprSyntax.self) {
                    guard let base = member.base else { return false }        // `.init(…)`
                    current = base
                    continue
                }
                // An implicit-self call (`modifier(…)`) in `extension View`.
                if call.calledExpression.is(DeclReferenceExprSyntax.self) {
                    let name = call.calledExpression.as(DeclReferenceExprSyntax.self)!.baseName.text
                    return viewExtensionDepth > 0 && name.first?.isLowercase == true
                }
                return false
            }
            if let member = current.as(MemberAccessExprSyntax.self), let base = member.base {
                // `configuration.label` / `.content` in a style's `makeBody`.
                if base.as(DeclReferenceExprSyntax.self)?.baseName.text == "configuration",
                   ["label", "content"].contains(member.declName.baseName.text) { return true }
                current = base
                continue
            }
            if let ref = current.as(DeclReferenceExprSyntax.self) {
                return ref.baseName.text == "content" || ref.baseName.text == "self"
            }
            return current.is(SuperExprSyntax.self)
        }
    }

    /// Remove `.name(…)` from its chain, keeping its line breaks so every
    /// later line stays where it was.
    func strip(_ member: MemberAccessExprSyntax, _ call: FunctionCallExprSyntax) {
        let start = member.period.positionAfterSkippingLeadingTrivia.utf8Offset
        let end = call.endPositionBeforeTrailingTrivia.utf8Offset
        guard end > start, stripped.insert(start).inserted else { return }
        // Line breaks inside the removed span only (the base before `.` stays).
        let bytes = Array(call.description.utf8)
        let from = start - call.position.utf8Offset, to = end - call.position.utf8Offset
        guard from >= 0, to <= bytes.count else { return }
        let newlines = bytes[from..<to].filter { $0 == UInt8(ascii: "\n") }.count
        insertions.append(Insertion(offset: start, text: String(repeating: "\n", count: newlines), length: end - start))
    }

    /// Walk a modifier chain; every call in it may carry builder closures.
    private func descend(_ expr: ExprSyntax) {
        var current: ExprSyntax? = expr
        while let e = current {
            if let call = e.as(FunctionCallExprSyntax.self) {
                for closure in Rules.builderClosures(of: call) { builderBody(closure.statements) }
                current = call.calledExpression.as(MemberAccessExprSyntax.self)?.base
            } else if let member = e.as(MemberAccessExprSyntax.self) {
                current = member.base
            } else if let postfix = e.as(PostfixOperatorExprSyntax.self) {
                current = postfix.expression
            } else if let optional = e.as(OptionalChainingExprSyntax.self) {
                current = optional.expression
            } else if let force = e.as(ForceUnwrapExprSyntax.self) {
                current = force.expression
            } else {
                current = nil
            }
        }
    }
}

// MARK: - Rules

enum Rules {
    /// `some View`, `any View`, `AnyView`, `View`.
    static func isViewType(_ type: TypeSyntax) -> Bool {
        if let some = type.as(SomeOrAnyTypeSyntax.self) { return isPlainView(some.constraint) }
        if let ident = type.as(IdentifierTypeSyntax.self) {
            return ident.name.text == "AnyView" || ident.name.text == "View"
        }
        return false
    }

    private static func isPlainView(_ type: TypeSyntax) -> Bool {
        if let ident = type.as(IdentifierTypeSyntax.self) { return ident.name.text == "View" }
        if let member = type.as(MemberTypeSyntax.self) {
            return member.name.text == "View" && member.baseType.trimmedDescription == "SwiftUI"
        }
        return false
    }

    /// Uppercase calls that aren't views (only matter where we guess).
    private static let nonViewTypes: Set<String> = [
        "Self", "String", "Int", "Double", "Float", "CGFloat", "Bool", "Array", "Set", "Dictionary",
        "URL", "Date", "UUID", "Data", "Binding", "State", "Task", "DispatchQueue", "Animation",
        "Font", "Edge", "EdgeInsets", "CGSize", "CGPoint", "CGRect", "Angle", "UnitPoint", "Notification",
        "Error", "Result", "Optional", "Range", "IndexSet", "AttributedString", "LocalizedStringKey",
        "ToolbarItem", "ToolbarItemGroup", "ToolbarSpacer", "ToolbarTitleMenu", "TapGesture", "DragGesture",
        "LongPressGesture", "MagnifyGesture", "MagnificationGesture", "RotateGesture", "RotationGesture",
        "SimultaneousGesture", "SequenceGesture", "ExclusiveGesture", "SpatialTapGesture", "Transaction",
        "Timer", "AnyTransition", "CommandMenu", "CommandGroup", "WindowGroup", "Settings", "Scene",
    ]

    /// A chain rooted in a call to an uppercase type: `Text("a")`,
    /// `HelperRow(title: t).padding()`, `ForEach(items) { … }.id(x)`.
    static func isViewLike(_ expr: ExprSyntax) -> Bool {
        var current = expr
        while true {
            if let call = current.as(FunctionCallExprSyntax.self) {
                var callee = call.calledExpression
                // `Foo<Bar>(…)`
                if let generic = callee.as(GenericSpecializationExprSyntax.self) { callee = generic.expression }
                if let ref = callee.as(DeclReferenceExprSyntax.self) {
                    let name = ref.baseName.text
                    guard let first = name.unicodeScalars.first else { return false }
                    return first.properties.isUppercase && !nonViewTypes.contains(name)
                }
                if let member = callee.as(MemberAccessExprSyntax.self), let base = member.base {
                    current = base
                    continue
                }
                return false
            }
            return false
        }
    }

    /// `a.b(c).d` and friends: `.preference` appended binds to all of it.
    static func isPostfixChain(_ expr: ExprSyntax) -> Bool {
        expr.is(FunctionCallExprSyntax.self) || expr.is(MemberAccessExprSyntax.self)
            || expr.is(DeclReferenceExprSyntax.self) || expr.is(ForceUnwrapExprSyntax.self)
            || expr.is(OptionalChainingExprSyntax.self) || expr.is(TupleExprSyntax.self)
            || expr.is(GenericSpecializationExprSyntax.self)
    }

    /// Literals, closures and `nil` can't be views; anything else in a
    /// view-typed position is one.
    static func canCarryTag(_ expr: ExprSyntax) -> Bool {
        !(expr.is(StringLiteralExprSyntax.self) || expr.is(IntegerLiteralExprSyntax.self)
            || expr.is(FloatLiteralExprSyntax.self) || expr.is(BooleanLiteralExprSyntax.self)
            || expr.is(NilLiteralExprSyntax.self) || expr.is(ClosureExprSyntax.self)
            || expr.is(IfExprSyntax.self) || expr.is(SwitchExprSyntax.self))
    }

    /// SwiftUI views whose (first) trailing closure is view content.
    private static let containers: Set<String> = [
        "VStack", "HStack", "ZStack", "LazyVStack", "LazyHStack", "LazyVGrid", "LazyHGrid", "Grid",
        "GridRow", "Group", "List", "Form", "Section", "ScrollView", "ScrollViewReader", "NavigationStack",
        "NavigationSplitView", "NavigationView", "NavigationLink", "ForEach", "TabView", "GeometryReader",
        "ViewThatFits", "Menu", "DisclosureGroup", "GroupBox", "ControlGroup", "Picker", "LabeledContent",
        "Label", "Link", "ShareLink", "Toggle", "TimelineView", "Stepper", "Slider", "ProgressView",
        "ContentUnavailableView",
    ]

    /// Modifiers whose closures hold something other than plain views
    /// (toolbar items, commands, alert actions): never touched.
    private static let nonViewModifiers: Set<String> = [
        "toolbar", "commands", "alert", "confirmationDialog", "accessibilityRotor", "focusedSceneValue",
        "searchSuggestions", "swipeActions", "accessibilityActions", "menuItems", "dialogSuppressionToggle",
    ]

    /// Modifiers whose trailing closure is view content.
    private static let viewModifiers: Set<String> = [
        "overlay", "background", "mask", "sheet", "fullScreenCover", "popover", "safeAreaInset",
        "contextMenu", "navigationDestination", "clipShape", "listRowBackground", "badge",
    ]

    /// Argument labels that name view content in SwiftUI's own APIs.
    private static let viewLabels: Set<String> = [
        "content", "label", "header", "footer", "destination", "placeholder", "icon", "sidebar",
        "detail", "currentValueLabel", "minimumValueLabel", "maximumValueLabel",
    ]

    /// Closures in a call that hold view content.
    static func builderClosures(of call: FunctionCallExprSyntax) -> [ClosureExprSyntax] {
        var out: [ClosureExprSyntax] = []
        let callee: String?
        let isModifier: Bool
        if let ref = call.calledExpression.as(DeclReferenceExprSyntax.self) {
            callee = ref.baseName.text
            isModifier = false
        } else if let member = call.calledExpression.as(MemberAccessExprSyntax.self) {
            callee = member.declName.baseName.text
            isModifier = true
        } else {
            callee = nil
            isModifier = false
        }

        if isModifier, let callee, nonViewModifiers.contains(callee) { return [] }

        // Labelled closures: SwiftUI's view labels, or any label whose
        // closure is plainly views (a custom `leading: { Icon() }`).
        for arg in call.arguments {
            if let closure = arg.expression.as(ClosureExprSyntax.self), let label = arg.label?.text,
               viewLabels.contains(label) || looksLikeViewContent(closure) {
                out.append(closure)
            }
        }
        for extra in call.additionalTrailingClosures
        where viewLabels.contains(extra.label.text) || looksLikeViewContent(extra.closure) {
            out.append(extra.closure)
        }

        guard let trailing = call.trailingClosure, let callee else { return out }
        let hasActionArg = call.arguments.contains { $0.label?.text == "action" }
        if callee == "Button" {
            // `Button("x") { action }` vs `Button(action: f) { label }`.
            if hasActionArg || call.additionalTrailingClosures.contains(where: { $0.label.text == "action" }) {
                out.append(trailing)
            }
        } else if isModifier {
            if viewModifiers.contains(callee) { out.append(trailing) }
            else if looksLikeViewContent(trailing) { out.append(trailing) }
        } else if containers.contains(callee) {
            out.append(trailing)
        } else if looksLikeViewContent(trailing) {
            // A custom container: only when every statement is a view.
            out.append(trailing)
        }
        return out
    }

    /// Every statement is a view expression, including those inside
    /// `if`/`switch` branches, and there's at least one.
    static func looksLikeViewContent(_ closure: ClosureExprSyntax) -> Bool {
        var views = 0
        return allViews(closure.statements, &views) && views > 0
    }

    private static func allViews(_ items: CodeBlockItemListSyntax, _ views: inout Int) -> Bool {
        for item in items {
            guard let expr = item.expression else { return false }
            if let ifExpr = expr.as(IfExprSyntax.self) {
                var branch: IfExprSyntax? = ifExpr
                while let b = branch {
                    guard allViews(b.body.statements, &views) else { return false }
                    switch b.elseBody {
                    case let .ifExpr(next)?: branch = next
                    case let .codeBlock(block)?:
                        guard allViews(block.statements, &views) else { return false }
                        branch = nil
                    case nil: branch = nil
                    }
                }
            } else if let switchExpr = expr.as(SwitchExprSyntax.self) {
                for element in switchExpr.cases {
                    guard case let .switchCase(c) = element, allViews(c.statements, &views) else { return false }
                }
            } else if isViewLike(expr) {
                views += 1
            } else {
                return false
            }
        }
        return true
    }
}

// MARK: - Syntax helpers

extension CodeBlockItemSyntax {
    /// The statement's expression, whether it's stored as an expression or
    /// as an expression statement (`if`/`switch` used as statements).
    var expression: ExprSyntax? {
        if let expr = item.as(ExprSyntax.self) { return expr }
        if let stmt = item.as(ExpressionStmtSyntax.self) { return stmt.expression }
        return nil
    }
}

extension CodeBlockItemListSyntax {
    var containsTopLevelReturn: Bool {
        contains { $0.item.is(ReturnStmtSyntax.self) }
    }
}

extension AttributeListSyntax {
    var hasViewBuilder: Bool {
        contains {
            guard case let .attribute(attr) = $0 else { return false }
            let name = attr.attributeName.trimmedDescription
            return name == "ViewBuilder" || name == "SwiftUI.ViewBuilder"
        }
    }
}
