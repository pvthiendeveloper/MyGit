import Foundation

/// Fill and border of a view, from what its `.background` / `.overlay`
/// (and `.border`, which is an overlay) draw: the shape views inside those
/// modifiers' decoration content, which aren't on the view's modifier chain
/// — the chain is the box's own modifiers, the decoration hangs beside it.
extension UIInspectorViewModel {
    struct Decoration {
        enum Kind { case fill, border }
        let kind: Kind
        /// The `_ShapeView` / `Color` node that draws it.
        let node: InspectorNode
    }

    /// Fill/border sections for `id`'s box, innermost-first order kept stable.
    func decorationSections(for id: String, ownerEntry: InspectorSourceMapEntry?,
                            ownerStack: [InspectorSourceTag]) -> [InspectorDetailSection] {
        let found = decorations(of: id)
        var sections: [InspectorDetailSection] = []
        for decoration in found {
            let sameKind = found.filter { $0.kind == decoration.kind }
            let base = decoration.kind == .border ? "Border" : "Fill"
            let title = sameKind.count > 1
                ? "\(base) \(sameKind.firstIndex { $0.node.id == decoration.node.id }! + 1)"
                : base
            let rows = decorationRows(decoration, ownerEntry: ownerEntry, ownerStack: ownerStack)
            if !rows.isEmpty { sections.append(.init(title: title, rows: rows)) }
        }
        return sections
    }

    /// Every fill/border drawn over or under the box `id` is: decorations of
    /// the overlay/background modifiers on its chain, above it (outer
    /// modifiers) and below it (inner ones, down to where the box changes).
    func decorations(of id: String) -> [Decoration] {
        guard let start = rawNode(id) else { return [] }
        let box = start.frame
        var modifiers: [(node: InspectorNode, contentChild: String?)] = []

        // Up: the child we came from is the modifier's content.
        var child = id
        var cursor = rawParent(id)
        for _ in 0..<80 {
            guard let c = cursor, let node = rawNode(c) else { break }
            let sameBox = node.frame.equalTo(box, tolerance: 0.5) || !node.hasOwnFrame
            guard node.isModifier || Self.isWrapper(node.className) || (sameBox && rawChildren(c).count == 1),
                  sameBox else { break }
            if Self.isDecorating(node) { modifiers.append((node, child)) }
            child = c
            cursor = rawParent(c)
        }
        // Down: through the same box; a decorating modifier's content is its last child.
        cursor = id
        for _ in 0..<80 {
            guard let c = cursor, let node = rawNode(c) else { break }
            let children = rawChildren(c)
            if Self.isDecorating(node) {
                modifiers.append((node, children.last))
                cursor = children.last
            } else if node.isModifier || Self.isWrapper(node.className) || children.count == 1 {
                cursor = children.count == 1 ? children[0] : nil
            } else {
                break
            }
            if let next = cursor, let n = rawNode(next), !n.frame.equalTo(box, tolerance: 0.5), n.hasOwnFrame { break }
        }

        var out: [Decoration] = []
        var seen = Set<String>()
        for (modifier, content) in modifiers {
            for decorationRoot in rawChildren(modifier.id) where decorationRoot != content {
                for shape in shapeNodes(under: decorationRoot, box: box) where seen.insert(shape.id).inserted {
                    out.append(.init(kind: Self.isStroke(shape) ? .border : .fill, node: shape))
                }
            }
        }
        // Backgrounds first (they're under), then overlays; within each, as found.
        return out.filter { $0.kind == .fill } + out.filter { $0.kind == .border }
    }

    private static func isDecorating(_ node: InspectorNode) -> Bool {
        node.isModifier && (node.className.hasPrefix("_OverlayModifier") || node.className.hasPrefix("_BackgroundModifier"))
    }

    /// Shape/colour views that cover the box (a small badge in an overlay isn't its border).
    private func shapeNodes(under id: String, box: CGRect) -> [InspectorNode] {
        var out: [InspectorNode] = []
        var stack = [id]
        var visited = 0
        while let c = stack.popLast(), visited < 200 {
            visited += 1
            guard let node = rawNode(c) else { continue }
            let drawn = node.className.hasPrefix("_ShapeView<") || node.className == "Color"
                || node.className.hasPrefix("_ShapeView ") || node.className.hasPrefix("Color<")
            if drawn {
                let covers = node.frame.insetBy(dx: -1, dy: -1).contains(box.insetBy(dx: 1, dy: 1))
                if covers && !Self.isInvisible(node) { out.append(node) }
                continue
            }
            // Don't wander into nested boxes' own decorations.
            if Self.isDecorating(node) { stack.append(contentsOf: rawChildren(c).dropLast().reversed()); continue }
            stack.append(contentsOf: rawChildren(c).reversed())
        }
        return out
    }

    private static func isStroke(_ node: InspectorNode) -> Bool {
        node.className.contains("_StrokedShape") || node.className.contains("StrokeBorder")
            || node.props.keys.contains { $0.hasSuffix("style.lineWidth") }
    }

    /// A clear fill, or a stroke drawn with no width (an outline hidden in
    /// this state) — still reported for strokes, since the width is the news.
    private static func isInvisible(_ node: InspectorNode) -> Bool {
        guard !isStroke(node) else { return false }
        return node.props["style"].map { $0.hasSuffix("00") && $0.count == 9 } ?? false
    }

    // MARK: - Rows

    private func decorationRows(_ decoration: Decoration, ownerEntry: InspectorSourceMapEntry?,
                                ownerStack: [InspectorSourceTag]) -> [InspectorDetailSection.Row] {
        let node = decoration.node
        let props = node.props
        // What wrote it: the decoration's own tag (`shape.strokeBorder(color, lineWidth:)`),
        // else the owner's `.border(color, width:)` / `.background(color)`.
        let paintNames: Set<String> = decoration.kind == .border
            ? ["strokeBorder", "stroke", "border"]
            : ["fill", "foregroundStyle", "foregroundColor", "background", "tint"]
        var paint: InspectorSourceMapEntry.Modifier?
        var stack: [InspectorSourceTag] = []
        if let tagged = chainTag(of: node.id, owns: { entry in entry.mods.contains { paintNames.contains($0.name) } }),
           let tag = tagged.stack.first,
           let entry = sourceEntry(for: tag) {
            paint = entry.mods.last { paintNames.contains($0.name) }
            stack = tagged.stack
        } else if let ownerEntry {
            let ownerNames: Set<String> = decoration.kind == .border ? ["border"] : ["background"]
            paint = ownerEntry.mods.first { ownerNames.contains($0.name) }
            stack = ownerStack
        }
        let colorArg = paint?.args.first { $0.label == nil || $0.label == "content" || $0.label == "color" }
        let widthArg = paint?.args.first { $0.label == "lineWidth" || $0.label == "width" }

        var rows: [InspectorDetailSection.Row] = []
        let color = props["style"] ?? props["color"] ?? props["provider.base"]
        if let color {
            rows.append(Self.tokenRow("Color", value: color, arg: colorArg, stack: stack))
        }
        if decoration.kind == .border {
            let width = props.first { $0.key.hasSuffix("style.lineWidth") }?.value
            rows.append(Self.tokenRow("Width", value: width.map { Self.prettyValue($0) } ?? "1", arg: widthArg, stack: stack))
            if let dash = props.first(where: { $0.key.hasSuffix("style.dash") })?.value, dash != "[]" {
                rows.append(.init(key: "Dash", value: dash, monospaced: true))
            }
        }
        if let shape = Self.shapeName(node.className) {
            rows.append(.init(key: "Shape", value: shape, monospaced: true))
        }
        if let radius = Self.cornerRadius(props) {
            rows.append(.init(key: "Corner radius", value: radius, monospaced: true))
        }
        return rows
    }

    private static func tokenRow(_ key: String, value: String, arg: InspectorSourceMapEntry.Argument?,
                                 stack: [InspectorSourceTag]) -> InspectorDetailSection.Row {
        guard let arg, arg.token else { return .init(key: key, value: value, monospaced: true) }
        return .init(key: key, value: value, monospaced: true, token: arg.expr, tokenStack: stack,
                     tokenValue: value, tokenRefs: arg.refs, tokenProbe: arg.probe, tokenBinding: arg.binding)
    }

    /// `_ShapeView<_StrokedShape<SwiftUIButtonLoadingShape>, Color>` → `SwiftUIButtonLoadingShape`.
    static func shapeName(_ className: String) -> String? {
        guard className.hasPrefix("_ShapeView<") else { return nil }
        var inner = String(className.dropFirst("_ShapeView<".count))
        // Peel SwiftUI's wrappers: _StrokedShape<…>, _Inset<…>, _StrokedShape<_Inset<…>>.
        while let open = inner.firstIndex(of: "<"),
              ["_StrokedShape", "_Inset", "_InsetShape", "_TrimmedShape", "_StrokedShape<_Inset"].contains(String(inner[..<open])) {
            inner = String(inner[inner.index(after: open)...])
        }
        // Up to the first top-level `,` or `>`.
        var depth = 0
        var end = inner.endIndex
        for i in inner.indices {
            switch inner[i] {
            case "<": depth += 1
            case ">": if depth == 0 { end = i }; depth -= 1
            case ",": if depth == 0 { end = i }
            default: break
            }
            if end != inner.endIndex { break }
        }
        let name = String(inner[..<end]).trimmingCharacters(in: .whitespaces)
        return name.isEmpty ? nil : name
    }

    /// `cornerRadius` / `cornerSize` wherever the shape keeps it; a capsule is fully round.
    static func cornerRadius(_ props: [String: String]) -> String? {
        if let r = props.first(where: { $0.key.hasSuffix("cornerRadius") })?.value {
            return (Double(r) ?? 0) >= 9_999 ? "full (\(prettyValue(r)))" : prettyValue(r)
        }
        if let size = props.first(where: { $0.key.hasSuffix("cornerSize") })?.value { return size }
        if let w = props.first(where: { $0.key.hasSuffix("cornerSize.width") })?.value { return prettyValue(w) }
        return nil
    }
}

private extension CGRect {
    func equalTo(_ other: CGRect, tolerance: CGFloat) -> Bool {
        abs(minX - other.minX) <= tolerance && abs(minY - other.minY) <= tolerance
            && abs(width - other.width) <= tolerance && abs(height - other.height) <= tolerance
    }
}
