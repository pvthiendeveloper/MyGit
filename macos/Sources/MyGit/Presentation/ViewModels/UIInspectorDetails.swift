import Foundation

/// The attributes panel's content for one node: what Figma's inspector
/// shows (layout, flow, padding, constraints) plus everything SwiftUI
/// reports about the modifiers applied to it.
struct InspectorDetailSection: Identifiable {
    struct Row: Identifiable {
        let key: String
        let value: String
        var monospaced = false
        /// The design token the value comes from (`tokenProvider.spacing`);
        /// nil when the source hardcodes it or isn't known.
        var token: String?
        /// The tags from where `token` was written outward (to trace
        /// parameters to call sites and find the property index) and the
        /// value on screen (to pick between overrides).
        var tokenStack: [InspectorSourceTag] = []
        var tokenValue: String?
        /// Where the token's names are in the source (for the compiler's index).
        var tokenRefs: [[InspectorRef]]?
        /// When the token is a local: what it was bound to.
        var tokenBinding: String?
        var id: String { key }
    }

    let title: String
    var rows: [Row]
    var id: String { title }
}

extension UIInspectorViewModel {
    /// Sections for the attributes panel, most useful first.
    func detailSections(for id: String) -> [InspectorDetailSection] {
        guard let node = rawNode(id) else { return [] }
        var sections: [InspectorDetailSection] = []
        let chain = modifierChain(of: id)

        // Identity
        var identity: [InspectorDetailSection.Row] = [
            .init(key: "Kind", value: node.kind == .swiftui ? (node.isModifier ? "SwiftUI modifier" : "SwiftUI view") : "UIKit view"),
            .init(key: "Type", value: node.className, monospaced: true),
        ]
        if let full = node.fullType, full != node.className { identity.append(.init(key: "Full Type", value: full, monospaced: true)) }
        if let vc = node.viewController { identity.append(.init(key: "View Controller", value: vc)) }
        if let text = chain.views.lazy.compactMap(\.text).first ?? node.text { identity.append(.init(key: "Text", value: text)) }
        let textColor = shownTextColor(id, views: chain.views)
        if let textColor { identity.append(.init(key: "Text Color", value: textColor, monospaced: true)) }
        if let a11y = node.accessibilityIdentifier { identity.append(.init(key: "Identifier", value: a11y, monospaced: true)) }
        if let label = node.accessibilityLabel { identity.append(.init(key: "Label", value: label)) }
        sections.append(.init(title: "View", rows: identity))

        // Layout: the box on screen, plus the frame modifiers that sized it.
        let f = node.frame
        // Only SwiftUI nodes sit under their own tag; a hosted UIKit view
        // borrows the enclosing view's, whose tokens aren't its own.
        let ownStack = node.kind == .swiftui ? sourceStack(for: id) : []
        let entry = ownStack.first.flatMap { sourceEntry(for: $0) }
        var layout: [InspectorDetailSection.Row] = [
            .init(key: "X", value: Self.fmt(f.minX)), .init(key: "Y", value: Self.fmt(f.minY)),
            .init(key: "Width", value: Self.fmt(f.width) + sizing(chain.modifiers, axis: "Width"),
                  token: Self.frameToken(entry, axis: "Width"), tokenStack: ownStack, tokenValue: Self.fmt(f.width),
                  tokenRefs: Self.frameRefs(entry, axis: "Width")),
            .init(key: "Height", value: Self.fmt(f.height) + sizing(chain.modifiers, axis: "Height"),
                  token: Self.frameToken(entry, axis: "Height"), tokenStack: ownStack, tokenValue: Self.fmt(f.height),
                  tokenRefs: Self.frameRefs(entry, axis: "Height")),
        ]
        if node.kind == .uikit {
            layout.append(.init(key: "Clips", value: node.clipsToBounds ? "Yes" : "No"))
        }
        sections.append(.init(title: "Layout", rows: layout))

        if let flow = flowSection(for: id) { sections.append(flow) }
        if let padding = paddingSection(chain.modifiers, entry: entry, stack: ownStack) { sections.append(padding) }

        if node.kind == .uikit {
            var appearance: [InspectorDetailSection.Row] = [
                .init(key: "Hidden", value: node.isHidden ? "Yes" : "No"),
                .init(key: "Alpha", value: Self.fmt(node.alpha)),
                .init(key: "Interaction", value: node.isInteractive ? "Enabled" : "Disabled"),
            ]
            if let bg = node.backgroundColor { appearance.append(.init(key: "Background", value: bg, monospaced: true)) }
            sections.append(.init(title: "Appearance", rows: appearance))
        }

        let shownText = chain.views.lazy.compactMap(\.text).first ?? node.text
        if let tokens = Self.tokensSection(entry, stack: ownStack, text: shownText, textColor: textColor) { sections.append(tokens) }

        // Public modifiers on the view, outermost first, with what SwiftUI
        // says about them; SwiftUI's internal ones only by name.
        var internalNames: [String] = []
        for modifier in chain.modifiers.reversed() {
            guard let name = Self.publicModifiers[modifier.shortName] else {
                if !internalNames.contains(modifier.shortName) { internalNames.append(modifier.shortName) }
                continue
            }
            sections.append(.init(title: "." + name, rows: Self.propRows(modifier.props)))
        }
        // Properties of public views in the same box (a Text's string, a shape's fill).
        for view in chain.views where Self.publicViews.contains(where: { view.className.hasPrefix($0) }) {
            let rows = Self.propRows(view.props)
            if !rows.isEmpty { sections.append(.init(title: view.shortName, rows: rows)) }
        }
        if !internalNames.isEmpty {
            sections.append(.init(title: "Other modifiers", rows: [
                .init(key: "\(internalNames.count)", value: internalNames.joined(separator: ", "), monospaced: true),
            ]))
        }
        return sections
    }

    /// A node's props as rows, minus caches and accessibility plumbing.
    private static func propRows(_ props: [String: String]) -> [InspectorDetailSection.Row] {
        props
            .filter { key, _ in
                let k = key.lowercased()
                return !k.contains("cache") && !k.contains("accessibility") && !k.hasSuffix("modifiers")
            }
            .sorted { $0.key < $1.key }
            .prefix(14)
            .map { InspectorDetailSection.Row(key: prettyKey($0.key), value: prettyValue($0.value), monospaced: true) }
    }

    /// Views whose own props are worth showing.
    private static let publicViews = [
        "Text", "Image", "Color", "_ShapeView", "Spacer", "Divider", "Rectangle", "RoundedRectangle",
        "Capsule", "Circle", "Toggle", "Button", "TextField", "SecureField", "ProgressView", "Label",
    ]

    // MARK: - Modifier chain

    /// Walk up from a node through everything that is the same box on screen:
    /// modifiers, wrappers (`ModifiedContent`, `_ViewModifier_Content`…), and
    /// single-child views sharing its frame (a `Text` above its
    /// `StyledTextContentView`). Stops at containers.
    func modifierChain(of id: String) -> (modifiers: [InspectorNode], views: [InspectorNode]) {
        var modifiers: [InspectorNode] = []
        var views: [InspectorNode] = []
        guard let start = rawNode(id) else { return ([], []) }
        if start.isModifier { modifiers.append(start) } else { views.append(start) }
        var current = start
        var steps = 0
        while let parentID = rawParent(current.id), let parent = rawNode(parentID), steps < 80 {
            steps += 1
            let sameBox = parent.frame.equalTo(current.frame, tolerance: 0.5) || !parent.hasOwnFrame
            let wrapper = Self.isWrapper(parent.className)
            if parent.isModifier {
                modifiers.append(parent)
            } else if wrapper || (sameBox && rawChildren(parentID).count == 1 && !Self.isStack(parent.className)) {
                if !wrapper { views.append(parent) }
            } else {
                break
            }
            current = parent
        }
        return (modifiers, views)
    }

    /// The color a Text was drawn in (`#595969FF`), from its resolved string
    /// (`StyledTextContentView.text.storage`): on the node, the views in its
    /// box, or the few levels below a selected `Text`.
    func shownTextColor(_ id: String, views: [InspectorNode]) -> String? {
        func color(_ node: InspectorNode) -> String? {
            node.props.first { $0.key.hasSuffix("storage.foregroundColor") }?.value
        }
        if let found = views.lazy.compactMap(color).first { return found }
        var level = [id]
        for _ in 0..<6 where !level.isEmpty {
            for nodeID in level { if let node = rawNode(nodeID), let found = color(node) { return found } }
            level = level.flatMap(rawChildren)
        }
        return nil
    }

    private static let wrapperPrefixes = [
        "ModifiedContent", "_ViewModifier_Content", "_ConditionalContent", "Optional<", "AnyView",
        "StaticIf", "_UnaryViewAdaptor", "PlaceholderContentView", "_ViewList_View", "Group<",
    ]

    static func isWrapper(_ className: String) -> Bool { wrapperPrefixes.contains { className.hasPrefix($0) } }

    static func isStack(_ className: String) -> Bool {
        stackAxis(className) != nil
    }

    /// VStack / LazyVStack / `_VariadicView.Tree<_VStackLayout, …>` → axis.
    static func stackAxis(_ className: String) -> String? {
        let head = className.hasPrefix("_VariadicView.Tree<")
            ? String(className.dropFirst("_VariadicView.Tree<".count))
            : className
        if head.hasPrefix("VStack") || head.hasPrefix("LazyVStack") || head.hasPrefix("_VStackLayout") { return "Vertical" }
        if head.hasPrefix("HStack") || head.hasPrefix("LazyHStack") || head.hasPrefix("_HStackLayout") { return "Horizontal" }
        if head.hasPrefix("ZStack") || head.hasPrefix("_ZStackLayout") { return "Overlay (ZStack)" }
        if head.hasPrefix("Grid") || head.hasPrefix("LazyVGrid") || head.hasPrefix("LazyHGrid") { return "Grid" }
        return nil
    }

    // MARK: - Flow

    /// For a stack (or a row that is one): direction, alignment, declared
    /// spacing and the gaps actually measured between its items.
    private func flowSection(for id: String) -> InspectorDetailSection? {
        // The stack may sit a few single-child levels below the selection.
        var candidate: String? = id
        var stackID: String?
        for _ in 0..<8 {
            guard let c = candidate, let node = rawNode(c) else { break }
            if Self.stackAxis(node.className) != nil { stackID = c; break }
            let kids = rawChildren(c)
            candidate = kids.count == 1 ? kids[0] : nil
        }
        guard let stackID, let stack = rawNode(stackID), let axis = Self.stackAxis(stack.className) else { return nil }
        // The layout's own props live on the stack or its `_VariadicView.Tree`.
        var props = stack.props
        var itemsParent = stackID
        for kid in rawChildren(stackID) where rawNode(kid)?.className.hasPrefix("_VariadicView.Tree") == true {
            props.merge(rawNode(kid)?.props ?? [:]) { a, _ in a }
            itemsParent = kid
        }
        let spacing = props.first { $0.key.hasSuffix("spacing") }?.value
        let alignment = props.first { $0.key.hasSuffix("root.alignment") || $0.key == "alignment" }?.value
        // The stack's own source line tells which token each came from.
        let stackTags = sourceStack(for: stackID)
        let stackEntry = stackTags.first.flatMap { sourceEntry(for: $0) }
        func token(_ label: String) -> String? {
            stackEntry?.args.first { $0.label == label && $0.token }?.expr
        }
        func refs(_ label: String) -> [[InspectorRef]]? {
            stackEntry?.args.first { $0.label == label && $0.token }?.refs
        }
        var rows: [InspectorDetailSection.Row] = [.init(key: "Direction", value: axis)]
        if let alignment {
            rows.append(.init(key: "Alignment", value: alignment, token: token("alignment"), tokenStack: stackTags,
                              tokenRefs: refs("alignment")))
        }
        rows.append(.init(key: "Gap (declared)", value: spacing.map(Self.prettyValue) ?? "default",
                          token: token("spacing"), tokenStack: stackTags, tokenValue: spacing, tokenRefs: refs("spacing")))

        // Measure: each item's first descendant with real geometry.
        let items = rawChildren(itemsParent).compactMap { geometry(of: $0) }
            .filter { $0.width > 0 || $0.height > 0 }
        rows.append(.init(key: "Items", value: "\(items.count)"))
        if items.count > 1, axis == "Vertical" || axis == "Horizontal" {
            let sorted = axis == "Vertical" ? items.sorted { $0.minY < $1.minY } : items.sorted { $0.minX < $1.minX }
            var gaps: [Double] = []
            for (a, b) in zip(sorted, sorted.dropFirst()) {
                gaps.append(axis == "Vertical" ? Double(b.minY - a.maxY) : Double(b.minX - a.maxX))
            }
            let unique = Array(Set(gaps.map { ($0 * 10).rounded() / 10 })).sorted()
            rows.append(.init(key: "Gap (measured)", value: unique.count <= 4
                ? unique.map(Self.fmt).joined(separator: ", ")
                : "\(Self.fmt(unique.first!)) – \(Self.fmt(unique.last!))"))
        }
        return .init(title: "Flow", rows: rows)
    }

    /// The first frame in a subtree that is the node's own (not inherited).
    private func geometry(of id: String) -> CGRect? {
        var current: String? = id
        for _ in 0..<40 {
            guard let c = current, let node = rawNode(c) else { return nil }
            if node.hasOwnFrame { return node.frame }
            current = rawChildren(c).first
        }
        return nil
    }

    // MARK: - Padding & sizing

    private func paddingSection(_ modifiers: [InspectorNode], entry: InspectorSourceMapEntry?,
                                stack: [InspectorSourceTag]) -> InspectorDetailSection? {
        let paddings = modifiers.filter { $0.shortName == "_PaddingLayout" }
        guard !paddings.isEmpty else { return nil }
        // `.padding(…)` calls in source order = runtime paddings innermost first.
        let sourcePaddings = entry?.mods.filter { $0.name == "padding" } ?? []
        var rows: [InspectorDetailSection.Row] = []
        for (index, p) in paddings.reversed().enumerated() {
            let prefix = paddings.count > 1 ? "#\(index + 1) " : ""
            let edges = p.props["edges"].map(Self.prettyValue) ?? "all"
            let sourceIndex = paddings.count - 1 - index
            let tokenArg = sourcePaddings.count == paddings.count
                ? sourcePaddings[sourceIndex].args.first(where: \.token) : nil
            let token = tokenArg?.expr
            // The padding's inset on its first edge, to match the token's value.
            let inset = ["top", "leading", "bottom", "trailing"].compactMap { p.props["insets.\($0)"] }.first
            rows.append(.init(key: prefix + "Edges", value: edges, token: token, tokenStack: stack, tokenValue: inset,
                              tokenRefs: tokenArg?.refs, tokenBinding: tokenArg?.binding))
            // Measured: the padding's box vs its content's.
            if let content = rawChildren(p.id).first.flatMap({ geometry(of: $0) }) {
                let outer = p.frame
                rows.append(.init(key: prefix + "Top", value: Self.fmt(content.minY - outer.minY)))
                rows.append(.init(key: prefix + "Leading", value: Self.fmt(content.minX - outer.minX)))
                rows.append(.init(key: prefix + "Bottom", value: Self.fmt(outer.maxY - content.maxY)))
                rows.append(.init(key: prefix + "Trailing", value: Self.fmt(outer.maxX - content.maxX)))
            }
        }
        return .init(title: "Padding", rows: rows)
    }

    /// The token behind a `.frame(…)` size on this axis, e.g.
    /// `minHeight: tokens.fieldHeight`.
    static func frameToken(_ entry: InspectorSourceMapEntry?, axis: String) -> String? {
        let labels = [axis.lowercased(), "min\(axis)", "ideal\(axis)", "max\(axis)"]
        let found = entry?.mods.filter { $0.name == "frame" }.flatMap(\.args)
            .filter { $0.token && labels.contains($0.label ?? "") } ?? []
        guard !found.isEmpty else { return nil }
        return found.map { "\($0.label!): \($0.expr)" }.joined(separator: ", ")
    }

    /// The `.frame` arguments on this axis, each an alternative.
    static func frameRefs(_ entry: InspectorSourceMapEntry?, axis: String) -> [[InspectorRef]]? {
        let labels = [axis.lowercased(), "min\(axis)", "ideal\(axis)", "max\(axis)"]
        let refs = entry?.mods.filter { $0.name == "frame" }.flatMap(\.args)
            .filter { $0.token && labels.contains($0.label ?? "") }
            .flatMap { $0.refs ?? [] } ?? []
        return refs.isEmpty ? nil : refs
    }

    /// Visual modifiers and SwiftUI views whose token arguments are worth
    /// naming; behavior modifiers (`onChange`, `task`) are left out.
    private static let tokenModifiers: Set<String> = [
        "background", "foregroundColor", "foregroundStyle", "fill", "stroke", "strokeBorder", "font",
        "cornerRadius", "clipShape", "shadow", "opacity", "tint", "border", "overlay", "offset",
        "lineSpacing", "kerning", "tracking", "fontWeight", "accentColor", "listRowBackground",
        "scaleEffect", "blur", "tymeXTextStyle",
    ]
    private static let textColorModifiers: Set<String> = ["foregroundColor", "foregroundStyle"]
    private static let tokenCalls: Set<String> = [
        "Text", "Image", "RoundedRectangle", "Rectangle", "Capsule", "Circle", "Spacer", "Divider", "Color",
        "Label", "LinearGradient", "RadialGradient",
    ]

    /// Every token the tagged expression reads that isn't shown elsewhere.
    static func tokensSection(_ entry: InspectorSourceMapEntry?, stack: [InspectorSourceTag],
                              text: String? = nil, textColor: String? = nil) -> InspectorDetailSection? {
        guard let entry else { return nil }
        var rows: [InspectorDetailSection.Row] = []
        if tokenCalls.contains(entry.call) {
            for arg in entry.args where arg.token {
                rows.append(.init(key: entry.call + (arg.label.map { "(\($0):)" } ?? "()"), value: "",
                                  monospaced: true, token: arg.expr, tokenStack: stack,
                                  tokenValue: entry.call == "Text" ? text : nil, tokenRefs: arg.refs,
                                  tokenBinding: arg.binding))
            }
        }
        for mod in entry.mods where tokenModifiers.contains(mod.name) || mod.name.hasPrefix("tymeX") {
            for arg in mod.args where arg.token {
                // A Text's color says which color token painted it.
                let shown = textColorModifiers.contains(mod.name) ? textColor : nil
                rows.append(.init(key: "." + mod.name + (arg.label.map { "(\($0):)" } ?? ""), value: "",
                                  monospaced: true, token: arg.expr, tokenStack: stack, tokenValue: shown,
                                  tokenRefs: arg.refs, tokenBinding: arg.binding))
            }
        }
        return rows.isEmpty ? nil : .init(title: "Tokens", rows: rows)
    }

    /// "(.frame: fixed 60)", "(.frame: fill)", "(.frame: min 44)".
    private func sizing(_ modifiers: [InspectorNode], axis: String) -> String {
        let key = axis.lowercased()
        var notes: [String] = []
        for m in modifiers {
            if m.shortName == "_FrameLayout", let v = m.props[key] { notes.append("fixed \(Self.prettyValue(v))") }
            if m.shortName == "_FlexFrameLayout" {
                if let max = m.props["max\(axis)"] { notes.append(max == "inf" ? "fill" : "max \(Self.prettyValue(max))") }
                if let min = m.props["min\(axis)"] { notes.append("min \(Self.prettyValue(min))") }
                if let ideal = m.props["ideal\(axis)"] { notes.append("ideal \(Self.prettyValue(ideal))") }
            }
        }
        // From `.frame` modifiers, which size a box around the view.
        return notes.isEmpty ? "" : "  (.frame: " + notes.joined(separator: ", ") + ")"
    }

    // MARK: - Formatting

    static func fmt(_ v: CGFloat) -> String { fmt(Double(v)) }

    static func fmt(_ v: Double) -> String {
        if v.isInfinite { return v > 0 ? "∞" : "-∞" }
        return abs(v - v.rounded()) < 0.01 ? String(Int(v.rounded())) : String(format: "%.1f", v)
    }

    /// `insets.top` → `insets › top`; `_tree.root.spacing` → `root › spacing`.
    static func prettyKey(_ key: String) -> String {
        key.split(separator: ".").filter { !$0.isEmpty && $0 != "_tree" }.joined(separator: " › ")
    }

    static func prettyValue(_ value: String) -> String {
        switch value {
        case "inf": return "∞"
        case "-inf": return "-∞"
        default:
            if let d = Double(value), value.contains(".") { return fmt(d) }
            return value.replacingOccurrences(of: "SwiftUI.", with: "")
        }
    }

    /// SwiftUI's types for public modifiers → the modifier's name.
    static let publicModifiers: [String: String] = [
            "_PaddingLayout": "padding", "_FrameLayout": "frame", "_FlexFrameLayout": "frame (flexible)",
            "_BackgroundModifier": "background", "_BackgroundStyleModifier": "background",
            "_ForegroundStyleModifier": "foregroundStyle", "_OverlayModifier": "overlay",
            "_OpacityEffect": "opacity", "_OffsetEffect": "offset", "_ClipEffect": "clipShape",
            "_ShadowEffect": "shadow", "_AspectRatioLayout": "aspectRatio", "_FixedSizeLayout": "fixedSize",
            "_EnvironmentKeyWritingModifier": "environment", "_TraitWritingModifier": "trait",
            "_ContentShapeModifier": "contentShape", "_RotationEffect": "rotationEffect",
            "_ScaleEffect": "scaleEffect", "_PositionLayout": "position", "_AlignmentWritingModifier": "alignmentGuide",
            "_BlurEffect": "blur", "_BrightnessEffect": "brightness", "_ClipShape": "clipShape",
            "_SafeAreaIgnoringLayout": "ignoresSafeArea", "_LayoutPriorityTraitKey": "layoutPriority",
            "_FlexFrameLayout ": "frame", "_MaskEffect": "mask", "_FontModifier": "font",
        ]
}

private extension CGRect {
    func equalTo(_ other: CGRect, tolerance: CGFloat) -> Bool {
        abs(minX - other.minX) <= tolerance && abs(minY - other.minY) <= tolerance
            && abs(width - other.width) <= tolerance && abs(height - other.height) <= tolerance
    }
}

// MARK: - Source tags

/// Where a view is written, from a tag MyGit's "Run with Inspector" build
/// puts on every SwiftUI view expression
/// (`.preference(key: __MyGitSourceKey.self, value: "path:line:col")`).
struct InspectorSourceTag: Hashable, Identifiable {
    let path: String   // repo-relative
    let line: Int
    let column: Int

    var id: String { "\(path):\(line):\(column)" }
    var fileName: String { (path as NSString).lastPathComponent }
    var label: String { "\(fileName):\(line)" }

    /// "Sources/A/HomeView.swift:132:21" (the path itself may hold colons).
    init?(_ value: String) {
        let parts = value.split(separator: ":", omittingEmptySubsequences: false)
        guard parts.count >= 3, let line = Int(parts[parts.count - 2]), let column = Int(parts[parts.count - 1]) else {
            return nil
        }
        path = parts.dropLast(2).joined(separator: ":")
        self.line = line
        self.column = column
    }
}

extension UIInspectorViewModel {
    static let sourceTagClass = "_PreferenceWritingModifier<__MyGitSourceKey>"

    /// The source locations above a node, nearest first — like a call
    /// stack: the `Text(…)` line, then the container it sits in, then the
    /// view that container belongs to…
    func sourceStack(for id: String, limit: Int = 12) -> [InspectorSourceTag] {
        var tags: [InspectorSourceTag] = []
        var cursor: String? = id
        while let current = cursor, tags.count < limit {
            if let node = rawNode(current), node.className == Self.sourceTagClass,
               let value = node.props["value"], let tag = InspectorSourceTag(value), tags.last != tag {
                tags.append(tag)
            }
            cursor = rawParent(current)
        }
        if tags.isEmpty, let node = rawNode(id), node.kind == .uikit {
            // A UIKit view SwiftUI hosts (a TextField's UITextField) hangs off
            // the hosting view, not the tagged SwiftUI node: take the
            // tightest tagged view around it.
            if let host = enclosingTag(of: node.frame) {
                return Array(sourceStack(for: host.nodeID, limit: limit))
            }
        }
        return tags
    }

    /// The nearest tag directly on a node (only modifiers/wrappers between),
    /// for the outline's `File.swift:12` hint.
    func ownSourceTag(for id: String) -> InspectorSourceTag? {
        var cursor = rawParent(id)
        for _ in 0..<24 {
            guard let current = cursor, let node = rawNode(current) else { return nil }
            if node.className == Self.sourceTagClass { return node.props["value"].flatMap(InspectorSourceTag.init) }
            guard node.isModifier || Self.isWrapper(node.className) else { return nil }
            cursor = rawParent(current)
        }
        return nil
    }

    /// Smallest tagged SwiftUI view whose box holds `frame`.
    private func enclosingTag(of frame: CGRect) -> (tag: InspectorSourceTag, nodeID: String)? {
        var best: (tag: InspectorSourceTag, nodeID: String, area: CGFloat)?
        for id in allTagNodeIDs() {
            guard let node = rawNode(id), let value = node.props["value"], let tag = InspectorSourceTag(value),
                  let child = rawChildren(id).first, let box = tagGeometry(child),
                  box.insetBy(dx: -1, dy: -1).contains(frame) else { continue }
            let area = box.width * box.height
            if best == nil || area < best!.area { best = (tag, id, area) }
        }
        return best.map { ($0.tag, $0.nodeID) }
    }

    private func tagGeometry(_ id: String) -> CGRect? {
        var current: String? = id
        for _ in 0..<40 {
            guard let c = current, let node = rawNode(c) else { return nil }
            if node.hasOwnFrame { return node.frame }
            current = rawChildren(c).first
        }
        return nil
    }
}

// MARK: - Token chains

extension UIInspectorViewModel {
    /// Resolve a token as far as the code allows. A bare name (`style`,
    /// `label`) is a parameter or stored property: the enclosing tags'
    /// calls say what was passed (`labelText(style: tokenProvider.x)`), and
    /// that expression is resolved in turn. Then properties are followed to
    /// a root value; where branches disagree (`labelColor(role)`), every
    /// possible root is listed unless the value on screen picks one.
    func resolveToken(_ expr: String, stack: [InspectorSourceTag], runtimeValue: String?) -> InspectorTokenResolution? {
        guard let first = stack.first else { return nil }
        var steps = [expr]
        var current = expr
        var level = 0
        // Trace parameters / stored properties outward.
        var hops = 0
        while Self.isIdentifier(current), hops < 8 {
            hops += 1
            var found: (expr: String, call: String, level: Int)?
            for index in (level + 1)..<max(level + 1, stack.count) {
                guard let entry = sourceEntry(for: stack[index]),
                      let arg = entry.args.first(where: { $0.label == current }) else { continue }
                found = (arg.expr, entry.call, index)
                break
            }
            guard let found else { break }
            steps.append("\(found.call)(\(current):) \(found.expr)")
            current = found.expr
            level = found.level
        }
        let tag = level < stack.count ? stack[level] : first

        let index = symbolIndex(near: tag)
        var chains: [[InspectorSymbol]] = []
        if !index.isEmpty {
            // `width: a, width: b` (from `.frame`) → each argument on its own;
            // otherwise the expression, or the `Type.member`s inside it.
            let parts = current.components(separatedBy: ", ").map { part -> String in
                guard let colon = part.range(of: ": ") else { return part }
                return String(part[colon.upperBound...])
            }
            let direct = parts.filter { Self.reference(in: $0) != nil }
            let candidates = !direct.isEmpty ? direct : Self.embeddedReferences(in: current)
            for candidate in candidates {
                // A value to match lets us weigh many more definitions.
                Self.follow(candidate, index: index, path: [], depth: 0, breadth: runtimeValue == nil ? 8 : 64,
                            near: tag.path, matchingAll: runtimeValue != nil, into: &chains)
                // With a value to match, weigh every candidate (`a ? x : y`);
                // without one, the first will do.
                if runtimeValue == nil, chains.contains(where: { $0.last?.literal != nil }) { break }
            }
        }
        let complete = chains.filter { $0.last?.literal != nil }
        // Among equals, the definition nearest the view's file (same
        // component folder) — `tokens.iconSize` in TopNavigation means
        // TopNavigation's, not CircleButton's.
        let nearness: ([InspectorSymbol]) -> Int = { chain in
            Self.sharedDirectoryDepth(chain.first?.path ?? "", tag.path)
        }
        if let runtimeValue {
            // Numbers by value; text by the string literal (`"Accordion"`).
            let matches = complete.filter { chain in
                let literal = chain.last!.literal!
                if let wanted = Double(runtimeValue), let value = Double(literal) { return value == wanted }
                return literal == "\"\(runtimeValue)\""
            }
            if let match = matches.max(by: { nearness($0) < nearness($1) }) {
                return InspectorTokenResolution(steps: steps, chain: InspectorTokenChain(hops: match), alternatives: [])
            }
            // Comparable candidates, none showing this value: another type's
            // same-named property. Better no answer than a wrong one.
            let comparable = complete.contains { chain in
                let literal = chain.last!.literal!
                return (Double(runtimeValue) != nil && Double(literal) != nil) || literal.hasPrefix("\"")
            }
            if comparable {
                return steps.count > 1 ? InspectorTokenResolution(steps: steps, chain: nil, alternatives: []) : nil
            }
        }
        // One name with several branches (a function's `switch`): list the roots.
        if let firstHop = complete.first?.first,
           complete.allSatisfy({ $0.first?.name == firstHop.name && $0.first?.owner == firstHop.owner }) {
            var roots: [InspectorSymbol] = []
            for chain in complete where !roots.contains(where: { $0.name == chain.last!.name && $0.owner == chain.last!.owner }) {
                roots.append(chain.last!)
            }
            if roots.count > 1, let ran = runtimeBranch(among: roots, value: runtimeValue),
               let chain = complete.first(where: { $0.last!.path == ran.path && $0.last!.line == ran.line }) {
                return InspectorTokenResolution(steps: steps, chain: InspectorTokenChain(hops: chain), alternatives: [],
                                                pickedBy: .runtimeBranch)
            }
            if roots.count > 1, let runtimeValue {
                // Roots that can't draw what's on screen are out.
                roots = InspectorBranchPruner.prune(roots, value: runtimeValue)
                if roots.count == 1,
                   let chain = complete.first(where: { $0.last!.path == roots[0].path && $0.last!.line == roots[0].line }) {
                    return InspectorTokenResolution(steps: steps, chain: InspectorTokenChain(hops: chain), alternatives: [],
                                                    pickedBy: .screenValue)
                }
            }
            if roots.count > 1 {
                return InspectorTokenResolution(steps: steps, chain: nil, alternatives: roots)
            }
        }
        let pool = complete.isEmpty ? chains : complete
        let best = pool.max { (nearness($0), $0.count) < (nearness($1), $1.count) }
        guard best != nil || steps.count > 1 else { return nil }
        return InspectorTokenResolution(steps: steps, chain: best.map(InspectorTokenChain.init(hops:)), alternatives: [])
    }

    /// How many leading folders two repo-relative paths share.
    static func sharedDirectoryDepth(_ a: String, _ b: String) -> Int {
        let x = a.split(separator: "/").dropLast(), y = b.split(separator: "/").dropLast()
        return zip(x, y).prefix { $0 == $1 }.count
    }

    /// Depth-first over definitions; a reference whose owner is named
    /// (`TymeXSwiftUI.x`) only matches definitions in that type.
    /// - Parameters:
    ///   - near: the view's file; definitions closest to it are tried first.
    ///   - matchingAll: a value will pick the winner, so the first step
    ///     weighs every definition of the name rather than the nearest few.
    private static func follow(_ expr: String, index: [String: [InspectorSymbol]], path: [InspectorSymbol],
                               depth: Int, breadth: Int, near: String, matchingAll: Bool,
                               into chains: inout [[InspectorSymbol]]) {
        // Inside a chain, a bare name (`static let a = b`) means the same type.
        let parsed = reference(in: expr) ?? (depth > 0 && isIdentifier(expr) ? (path.last?.owner, expr) : nil)
        guard depth < 10, chains.count < 2048, let (owner, name) = parsed,
              var candidates = index[name], !candidates.isEmpty else {
            if !path.isEmpty { chains.append(path) }
            return
        }
        if let owner {
            let owned = candidates.filter { $0.owner == owner }
            if !owned.isEmpty { candidates = owned }
        }
        // `x.labelColor(role)` calls a function; a same-named property
        // elsewhere (`state.labelColor`) is something else.
        if isCall(expr) {
            let functions = candidates.filter { $0.function == true }
            if !functions.isEmpty { candidates = functions }
        }
        candidates.sort { sharedDirectoryDepth($0.path, near) > sharedDirectoryDepth($1.path, near) }
        let width = depth == 0 && matchingAll ? 512 : breadth
        for symbol in candidates.prefix(width) where !path.contains(where: { $0.path == symbol.path && $0.line == symbol.line }) {
            let next = path + [symbol]
            if symbol.literal != nil {
                chains.append(next)
            } else {
                follow(symbol.expr, index: index, path: next, depth: depth + 1, breadth: breadth, near: near,
                       matchingAll: matchingAll, into: &chains)
            }
        }
    }

    private static func isCall(_ expr: String) -> Bool {
        let t = expr.trimmingCharacters(in: .whitespaces)
        guard t.hasSuffix(")"), let open = t.firstIndex(of: "(") else { return false }
        return t[..<open].allSatisfy { $0.isLetter || $0.isNumber || $0 == "_" || $0 == "." }
    }

    static func isIdentifier(_ s: String) -> Bool {
        guard let first = s.first, first.isLetter || first == "_" else { return false }
        return s.allSatisfy { $0.isLetter || $0.isNumber || $0 == "_" }
    }

    /// `Type.member` references inside a larger expression
    /// (`RoundedRectangle(cornerRadius: TymeXSwiftUI.cornerRadius3)`,
    /// `TymeXSwiftUI.surface.ignoresSafeArea()`). Instance references
    /// (`state.indicatorColor`) are arguments, not the token, so they're skipped.
    static func embeddedReferences(in expr: String) -> [String] {
        guard let regex = try? NSRegularExpression(pattern: "(?<![\\w.])[A-Z][A-Za-z0-9_]*(?:\\.[A-Za-z_][A-Za-z0-9_]*)+") else {
            return []
        }
        let ns = expr as NSString
        return regex.matches(in: expr, range: NSRange(location: 0, length: ns.length)).compactMap { match in
            var ref = ns.substring(with: match.range)
            // A trailing method call (`.ignoresSafeArea(`) isn't part of the token.
            let end = NSMaxRange(match.range)
            if end < ns.length, ns.character(at: end) == 40, let dot = ref.lastIndex(of: ".") { // "("
                ref = String(ref[..<dot])
            }
            return ref.contains(".") ? ref : nil
        }
    }

    /// `tokenProvider.labelToValueSpacing` → (nil, "labelToValueSpacing");
    /// `TymeXSwiftUI.spacing2` → ("TymeXSwiftUI", "spacing2"). Anything with
    /// calls or operators isn't a plain reference.
    static func reference(in expr: String) -> (owner: String?, name: String)? {
        var trimmed = expr.trimmingCharacters(in: .whitespaces)
        // `tokenProvider.labelColor(state.labelColor)` → the function `labelColor`.
        if trimmed.hasSuffix(")"), let open = trimmed.firstIndex(of: "("), trimmed[..<open].contains(".") {
            trimmed = String(trimmed[..<open])
        }
        guard !trimmed.isEmpty, trimmed.allSatisfy({ $0.isLetter || $0.isNumber || $0 == "_" || $0 == "." }) else {
            return nil
        }
        let parts = trimmed.split(separator: ".").map(String.init)
        // A bare name (`title`) is usually a local or parameter.
        guard parts.count >= 2, let name = parts.last, name.first.map({ $0.isLetter || $0 == "_" }) == true else {
            return nil
        }
        let owner = parts.count >= 2 ? parts[parts.count - 2] : nil
        let typeOwner = owner.flatMap { $0.first?.isUppercase == true && $0 != "Self" ? $0 : nil }
        return (typeOwner, name)
    }
}
