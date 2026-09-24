import Foundation

/// The attributes panel's content for one node: what Figma's inspector
/// shows (layout, flow, padding, constraints) plus everything SwiftUI
/// reports about the modifiers applied to it.
struct InspectorDetailSection: Identifiable {
    struct Row: Identifiable {
        let key: String
        let value: String
        var monospaced = false
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
        if let a11y = node.accessibilityIdentifier { identity.append(.init(key: "Identifier", value: a11y, monospaced: true)) }
        if let label = node.accessibilityLabel { identity.append(.init(key: "Label", value: label)) }
        sections.append(.init(title: "View", rows: identity))

        // Layout: the box on screen, plus the frame modifiers that sized it.
        let f = node.frame
        var layout: [InspectorDetailSection.Row] = [
            .init(key: "X", value: Self.fmt(f.minX)), .init(key: "Y", value: Self.fmt(f.minY)),
            .init(key: "Width", value: Self.fmt(f.width) + sizing(chain.modifiers, axis: "Width")),
            .init(key: "Height", value: Self.fmt(f.height) + sizing(chain.modifiers, axis: "Height")),
        ]
        if node.kind == .uikit {
            layout.append(.init(key: "Clips", value: node.clipsToBounds ? "Yes" : "No"))
        }
        sections.append(.init(title: "Layout", rows: layout))

        if let flow = flowSection(for: id) { sections.append(flow) }
        if let padding = paddingSection(chain.modifiers) { sections.append(padding) }

        if node.kind == .uikit {
            var appearance: [InspectorDetailSection.Row] = [
                .init(key: "Hidden", value: node.isHidden ? "Yes" : "No"),
                .init(key: "Alpha", value: Self.fmt(node.alpha)),
                .init(key: "Interaction", value: node.isInteractive ? "Enabled" : "Disabled"),
            ]
            if let bg = node.backgroundColor { appearance.append(.init(key: "Background", value: bg, monospaced: true)) }
            sections.append(.init(title: "Appearance", rows: appearance))
        }

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
        var rows: [InspectorDetailSection.Row] = [.init(key: "Direction", value: axis)]
        if let alignment { rows.append(.init(key: "Alignment", value: alignment)) }
        rows.append(.init(key: "Gap (declared)", value: spacing.map(Self.prettyValue) ?? "default"))

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

    private func paddingSection(_ modifiers: [InspectorNode]) -> InspectorDetailSection? {
        let paddings = modifiers.filter { $0.shortName == "_PaddingLayout" }
        guard !paddings.isEmpty else { return nil }
        var rows: [InspectorDetailSection.Row] = []
        for (index, p) in paddings.reversed().enumerated() {
            let prefix = paddings.count > 1 ? "#\(index + 1) " : ""
            let edges = p.props["edges"].map(Self.prettyValue) ?? "all"
            rows.append(.init(key: prefix + "Edges", value: edges))
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
