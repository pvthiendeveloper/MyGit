import SwiftUI

/// A piece of spacing on screen the inspector can point at, like Figma's
/// measure mode: a padding strip, the gap between two stack items, or a
/// rounded corner.
struct InspectorMeasure: Identifiable, Equatable {
    enum Kind: String {
        case padding = "Padding"
        case gap = "Spacing"
        case radius = "Corner radius"
    }

    let id: String
    let kind: Kind
    /// `top`, `between 1 – 2`, `top leading`…
    let edge: String
    /// Hit region, window coordinates.
    let rect: CGRect
    let value: CGFloat
    /// The node that carries it (the `_PaddingLayout`, the stack, the shape).
    let nodeID: String
    /// What a click selects: the view it belongs to, as shown in the outline.
    let ownerID: String
}

extension UIInspectorViewModel {
    // MARK: - Collecting

    /// Every padding strip, stack gap and rounded corner in the current window.
    func collectMeasures() -> [InspectorMeasure] {
        guard let root = currentWindow?.root else { return [] }
        var out: [InspectorMeasure] = []
        var corners = Set<String>()
        var stack = [root]
        while let node = stack.popLast() {
            stack += node.children
            if node.className == "_PaddingLayout" {
                out += paddingMeasures(node)
            } else if let axis = Self.stackAxis(node.className), axis == "Vertical" || axis == "Horizontal" {
                out += gapMeasures(node, vertical: axis == "Vertical")
            }
            if let radius = Self.cornerRadius(node), radius > 0.5 {
                // A clip, its background and the shape often share one box: once.
                let key = "\(Int(node.frame.minX)),\(Int(node.frame.minY)),\(Int(node.frame.width)),\(Int(node.frame.height)),\(radius)"
                if corners.insert(key).inserted { out += cornerMeasures(node, radius: radius) }
            }
        }
        return Self.withoutDuplicates(out)
    }

    /// A stack and the stack built inside it (or a same-size wrapper) give the
    /// same gap twice: keep one per kind, region and value.
    private static func withoutDuplicates(_ measures: [InspectorMeasure]) -> [InspectorMeasure] {
        var seen = Set<String>()
        return measures.filter { m in
            let r = m.rect
            let key = "\(m.kind.rawValue)|\(Int((r.minX * 2).rounded()))|\(Int((r.minY * 2).rounded()))|"
                + "\(Int((r.width * 2).rounded()))|\(Int((r.height * 2).rounded()))|\(Int((m.value * 2).rounded()))"
            return seen.insert(key).inserted
        }
    }

    private func paddingMeasures(_ p: InspectorNode) -> [InspectorMeasure] {
        guard let content = contentChild(p.id).flatMap({ geometry(of: $0) }) else { return [] }
        let outer = p.frame
        let owner = visibleOwner(below: p.id)
        let strips: [(String, CGRect)] = [
            ("top", CGRect(x: outer.minX, y: outer.minY, width: outer.width, height: content.minY - outer.minY)),
            ("bottom", CGRect(x: outer.minX, y: content.maxY, width: outer.width, height: outer.maxY - content.maxY)),
            ("leading", CGRect(x: outer.minX, y: content.minY, width: content.minX - outer.minX, height: content.height)),
            ("trailing", CGRect(x: content.maxX, y: content.minY, width: outer.maxX - content.maxX, height: content.height)),
        ]
        return strips.compactMap { edge, rect in
            let thickness = edge == "top" || edge == "bottom" ? rect.height : rect.width
            guard thickness > 0.5, rect.width > 0, rect.height > 0 else { return nil }
            return InspectorMeasure(id: "p:\(p.id):\(edge)", kind: .padding, edge: edge, rect: rect,
                                    value: thickness, nodeID: p.id, ownerID: owner)
        }
    }

    private func gapMeasures(_ stackNode: InspectorNode, vertical: Bool) -> [InspectorMeasure] {
        var itemsParent = stackNode.id
        for kid in rawChildren(stackNode.id) where rawNode(kid)?.className.hasPrefix("_VariadicView.Tree") == true {
            itemsParent = kid
        }
        let items = rawChildren(itemsParent).compactMap { geometry(of: $0) }
            .filter { $0.width > 0 || $0.height > 0 }
            .sorted { vertical ? $0.minY < $1.minY : $0.minX < $1.minX }
        guard items.count > 1 else { return [] }
        let box = stackNode.frame
        let owner = visibleOwner(below: stackNode.id)
        var out: [InspectorMeasure] = []
        for (i, (a, b)) in zip(items, items.dropFirst()).enumerated() {
            let rect = vertical
                ? CGRect(x: box.minX, y: a.maxY, width: box.width, height: b.minY - a.maxY)
                : CGRect(x: a.maxX, y: box.minY, width: b.minX - a.maxX, height: box.height)
            let gap = vertical ? rect.height : rect.width
            guard gap > 0.5 else { continue }
            out.append(InspectorMeasure(id: "g:\(stackNode.id):\(i)", kind: .gap, edge: "between \(i + 1) – \(i + 2)",
                                        rect: rect, value: gap, nodeID: stackNode.id, ownerID: owner))
        }
        return out
    }

    private func cornerMeasures(_ node: InspectorNode, radius: CGFloat) -> [InspectorMeasure] {
        let f = node.frame
        let side = min(radius, f.width / 2, f.height / 2)
        guard side > 0.5 else { return [] }
        let owner = node.isModifier ? visibleOwner(below: node.id) : visibleOwner(of: node.id)
        let corners: [(String, CGPoint)] = [
            ("top leading", CGPoint(x: f.minX, y: f.minY)),
            ("top trailing", CGPoint(x: f.maxX - side, y: f.minY)),
            ("bottom leading", CGPoint(x: f.minX, y: f.maxY - side)),
            ("bottom trailing", CGPoint(x: f.maxX - side, y: f.maxY - side)),
        ]
        return corners.map { edge, origin in
            InspectorMeasure(id: "r:\(node.id):\(edge)", kind: .radius, edge: edge,
                             rect: CGRect(origin: origin, size: CGSize(width: side, height: side)),
                             value: radius, nodeID: node.id, ownerID: owner)
        }
    }

    /// `shape.cornerSize: [16.0, 16.0]` on a `RoundedRectangle` shape, clip or
    /// background. Only the node's own shape: an overlay's props also hold
    /// its whole content (a badge's circle deep inside isn't the overlay's).
    static func cornerRadius(_ node: InspectorNode) -> CGFloat? {
        let own = ["shape.cornerSize", "background.shape.cornerSize", "overlay.shape.cornerSize"]
        guard let raw = own.lazy.compactMap({ node.props[$0] }).first else { return nil }
        let numbers = raw.trimmingCharacters(in: CharacterSet(charactersIn: "[]")).split(separator: ",")
            .compactMap { Double($0.trimmingCharacters(in: .whitespaces)) }
        return numbers.first.map { CGFloat($0) }
    }

    // MARK: - Owners

    /// The outline row for the view a modifier applies to: down its content
    /// to the first node the outline shows, else up to the nearest one.
    func visibleOwner(below id: String) -> String {
        var current: String? = id
        for _ in 0..<40 {
            guard let c = current else { break }
            if isShown(c) { return c }
            current = contentChild(c)
        }
        return visibleOwner(of: id)
    }

    private func visibleOwner(of id: String) -> String {
        var current: String? = id
        while let c = current {
            if isShown(c) { return c }
            current = rawParent(c)
        }
        return id
    }

    // MARK: - Hit testing

    /// The measure under a point: corners first (they sit on top of paddings),
    /// then the smallest region.
    func measure(at point: CGPoint) -> InspectorMeasure? {
        let hits = measures.filter { $0.rect.insetBy(dx: -1, dy: -1).contains(point) }
        return hits.min { a, b in
            if (a.kind == .radius) != (b.kind == .radius) { return a.kind == .radius }
            return a.rect.width * a.rect.height < b.rect.width * b.rect.height
        }
    }

    func select(_ measure: InspectorMeasure) {
        reveal(measure.ownerID)
        selectedMeasure = measure
    }

    // MARK: - Root

    /// The design token behind a measure, from its resolution. A padding
    /// given as `EdgeInsets(top: a, leading: b, …)` is one edge of it: that
    /// edge's component — and among several candidates (one per variant),
    /// those whose component on this edge is the measured value.
    func measureRoot(_ m: InspectorMeasure, _ resolution: InspectorTokenResolution?,
                     near tag: InspectorSourceTag?) -> (name: String, literal: String?)? {
        if let root = resolution?.chain?.root {
            if m.kind == .padding, let part = Self.edgeComponent(root.literal ?? root.expr, edge: m.edge) {
                return component(part, near: tag)
            }
            return (root.name, root.literal)
        }
        guard m.kind == .padding, let alternatives = resolution?.alternatives, !alternatives.isEmpty else { return nil }
        // One `EdgeInsets` gave all four edges: keep the candidates that fit every
        // edge measured on this padding, then name this edge's component.
        let insets = paddingInsets(m.nodeID)
        func fits(_ component: (name: String, literal: String?), _ value: CGFloat) -> Bool {
            component.literal.flatMap(Double.init).map { abs($0 - Double(value)) < 0.5 } == true
        }
        let consistent = alternatives.filter { alternative in
            insets.allSatisfy { edge, value in
                Self.edgeComponent(alternative.literal ?? alternative.expr, edge: edge).map { fits(component($0, near: tag), value) } == true
            }
        }
        var names: [String] = []
        var literal: String?
        for alternative in consistent {
            guard let part = Self.edgeComponent(alternative.literal ?? alternative.expr, edge: m.edge) else { continue }
            let c = component(part, near: tag)
            if !names.contains(c.name) { names.append(c.name) }
            literal = c.literal
        }
        // Tied candidates (same values, e.g. loading or not) are listed, not guessed.
        return names.isEmpty ? nil : (names.joined(separator: " | "), literal)
    }

    /// A padding's measured inset per edge.
    func paddingInsets(_ paddingID: String) -> [String: CGFloat] {
        guard let p = rawNode(paddingID), let content = contentChild(paddingID).flatMap({ geometry(of: $0) }) else { return [:] }
        let outer = p.frame
        return ["top": content.minY - outer.minY, "bottom": outer.maxY - content.maxY,
                "leading": content.minX - outer.minX, "trailing": outer.maxX - content.maxX]
    }

    /// `EdgeInsets(top: A, leading: B, …)` → the expression given for `edge`.
    static func edgeComponent(_ text: String, edge: String) -> String? {
        guard text.hasPrefix("EdgeInsets("),
              let range = text.range(of: "\\b\(edge):\\s*([^,)]+)", options: .regularExpression) else { return nil }
        let part = text[range].drop { $0 != ":" }.dropFirst()
        return part.trimmingCharacters(in: .whitespaces)
    }

    /// A component as a token: a number stays itself; `TymeXSwiftUI.spacing3`
    /// is `spacing3`, its value looked up in the property index.
    private func component(_ expr: String, near tag: InspectorSourceTag?) -> (name: String, literal: String?) {
        if Double(expr) != nil { return (expr, expr) }
        let name = String(expr.split(separator: ".").last ?? Substring(expr))
        var literal: String?
        var next = name
        if let tag {
            for _ in 0..<6 {
                guard let symbol = symbols(named: next, near: tag).first else { break }
                if let value = symbol.literal { literal = value; break }
                next = String(symbol.expr.split(separator: ".").last ?? "")
            }
        }
        return (name, literal)
    }

    // MARK: - Token name

    /// Resolve the root design token of a measure once (`patternGapElementToElement`).
    func loadTokenName(_ m: InspectorMeasure) {
        guard measureTokenNames[m.id] == nil, measureTokenLoads.insert(m.id).inserted else { return }
        Task { @MainActor [weak self] in
            guard let self else { return }
            let name = await tokenName(for: m)
            measureTokenLoads.remove(m.id)
            measureTokenNames[m.id] = name
        }
    }

    /// The name a measure's pill shows: its root token, what the source
    /// wrote, a SwiftUI style — or "" (hardcoded / nothing). Cached.
    func tokenName(for m: InspectorMeasure) async -> String {
        if let cached = measureTokenNames[m.id] { return cached }
        var name = ""
        if let token = measureToken(m) {
            let value = Self.fmt(m.value)
            let resolution = await resolveTokenExactly(token.arg.expr, refs: token.arg.refs, binding: token.arg.binding,
                                                       probe: token.arg.probe, stack: token.stack, runtimeValue: value)
                ?? resolveToken(token.arg.expr, stack: token.stack, runtimeValue: value)
            // The root when one was reached, else what the source wrote.
            name = measureRoot(m, resolution, near: token.stack.first)?.name ?? token.arg.expr
        } else if let style = systemStyle(around: m.nodeID) {
            name = "SwiftUI \(style)"
        } else if usesDefaultSpacing(m) {
            name = "SwiftUI default spacing"
        }
        measureTokenNames[m.id] = name
        return name
    }

    /// A SwiftUI built-in style the node is drawn by (`.buttonStyle(.bordered)`
    /// pads its label itself): `BorderedButtonStyle`. Only when no tag of
    /// ours is closer — then it's the app's own code.
    func systemStyle(around id: String) -> String? {
        var cursor: String? = id
        for _ in 0..<30 {
            guard let c = cursor, let node = rawNode(c) else { return nil }
            if Self.isTag(node.className) { return nil }
            if let range = node.className.range(of: "ResolvedButtonStyleBody<") ?? node.className.range(of: "ResolvedToggleStyleBody<") {
                let name = node.className[range.upperBound...].prefix { $0.isLetter || $0.isNumber || $0 == "_" }
                return name.isEmpty ? nil : String(name.split(separator: "_").first ?? Substring(name))
            }
            cursor = rawParent(c)
        }
        return nil
    }

    /// A gap in a stack written without `spacing:` — SwiftUI's own default
    /// (about 8 pt), not a token and not zero.
    func usesDefaultSpacing(_ m: InspectorMeasure) -> Bool {
        guard m.kind == .gap,
              let entry = (chainTag(of: m.nodeID)?.stack ?? sourceStack(for: m.nodeID)).first.flatMap({ sourceEntry(for: $0) }),
              Self.stackAxis(entry.call) != nil else { return false }
        return !entry.args.contains { $0.label == "spacing" }
    }

    // MARK: - Details

    /// The attributes panel's block for a picked measure, with the token behind it.
    func measureSection(_ m: InspectorMeasure) -> InspectorDetailSection {
        var rows: [InspectorDetailSection.Row] = [.init(key: m.kind == .radius ? "Corner" : "Edge", value: m.edge)]
        let token = measureToken(m)
        if token == nil, let style = systemStyle(around: m.nodeID) {
            rows.append(.init(key: "Drawn by", value: "SwiftUI \(style) (built in, no source)"))
        } else if token == nil, usesDefaultSpacing(m) {
            rows.append(.init(key: "Source", value: "SwiftUI default spacing — the stack has no spacing: argument (write spacing: 0 for none)"))
        }
        rows.append(.init(key: "Value", value: Self.fmt(m.value), token: token?.arg.expr, tokenStack: token?.stack ?? [],
                          tokenValue: Self.fmt(m.value), tokenRefs: token?.arg.refs, tokenProbe: token?.arg.probe,
                          tokenBinding: token?.arg.binding))
        return .init(title: m.kind.rawValue, rows: rows)
    }

    /// The source argument that set it: the matching `.padding(…)` of the
    /// padded view, the stack's `spacing:`, the shape's `cornerRadius`.
    func measureToken(_ m: InspectorMeasure) -> (arg: InspectorSourceMapEntry.Argument, stack: [InspectorSourceTag])? {
        switch m.kind {
        case .padding:
            guard let source = paddingSource(m.nodeID), let arg = source.mod.args.first(where: \.token) else { return nil }
            return (arg, source.stack)
        case .gap:
            let stack = chainTag(of: m.nodeID, owns: { $0.args.contains { $0.label == "spacing" } || Self.stackAxis($0.call) != nil })?.stack
                ?? sourceStack(for: m.nodeID)
            guard let arg = stack.first.flatMap({ sourceEntry(for: $0) })?.args
                .first(where: { $0.label == "spacing" && $0.token }) else { return nil }
            return (arg, stack)
        case .radius:
            // The modifier that drew it: a clip, a background/overlay shape, `.cornerRadius(t)`.
            let className = rawNode(m.nodeID)?.className ?? ""
            let drawnBy: [String] = className.hasPrefix("_ClipEffect") ? ["clipShape", "cornerRadius", "mask"]
                : className.hasPrefix("_BackgroundModifier") ? ["background"]
                : className.hasPrefix("_OverlayModifier") ? ["overlay"]
                : ["cornerRadius", "clipShape", "background", "overlay", "mask"]
            let stack = chainTag(of: m.nodeID, owns: { entry in
                entry.args.contains { $0.label == "cornerRadius" } || Self.isValueRooted(entry)
                    || Self.writtenModifiers(entry).contains { drawnBy.contains($0.name) }
            })?.stack ?? sourceStack(for: m.nodeID)
            guard let entry = stack.first.flatMap({ sourceEntry(for: $0) }) else { return nil }
            // A shape's own radius: `RoundedRectangle(cornerRadius: t)`.
            if let arg = entry.args.first(where: { $0.label == "cornerRadius" && $0.token }) { return (arg, stack) }
            let args = Self.writtenModifiers(entry).filter { drawnBy.contains($0.name) }.flatMap(\.args)
            // The radius written inside an argument (`RoundedRectangle(cornerRadius: r).fill(c)`)
            // before the whole argument, whose refs lead to the fill.
            if let radius = args.lazy.compactMap({ $0.radius?.first }).first(where: \.token) { return (radius, stack) }
            if let arg = args.first(where: \.token) { return (arg, stack) }
            // A shape held in a value (`tokens.circleShape.fill(…)`).
            if let root = entry.args.first, entry.args.count == 1, root.expr == entry.call, root.token { return (root, stack) }
            return nil
        }
    }
}

// MARK: - Audit (MYGIT_AUDIT_MEASURES=<file>)

extension UIInspectorViewModel {
    /// Debug aid: after a capture of a screen not seen before, resolve every
    /// measure's token the way the preview does and append one JSON line per
    /// measure to the file — the token found, or why there's none.
    func auditMeasuresIfRequested() {
        let env = ProcessInfo.processInfo.environment
        guard let path = env["MYGIT_AUDIT_MEASURES"] ?? env["MYGIT_REDLINES"] ?? env["MYGIT_FIGMA_FAKE"] ?? env["MYGIT_SPEC"] ?? env["MYGIT_3D"],
              let root = currentWindow?.root else { return }
        // One audit per screen: identified by the tags on it.
        var tags = Set<String>()
        var stack = [root]
        while let node = stack.popLast() {
            stack += node.children
            if Self.isTag(node.className), let v = node.props["value"], let t = InspectorSourceTag(v) { tags.insert(t.id) }
        }
        let signature = tags.sorted().joined(separator: ",").hashValue
        // Only once two captures agree: the first can predate the layout.
        guard signature == lastAuditSignature else { lastAuditSignature = signature; return }
        guard !auditedScreens.contains(signature) else { return }
        auditedScreens.insert(signature)
        if let fake = env["MYGIT_FIGMA_FAKE"], let data = FileManager.default.contents(atPath: fake),
           let node = try? JSONDecoder().decode(FigmaNode.self, from: data), let window = currentWindow {
            figmaNode = node
            figmaArea = CGRect(origin: .zero, size: window.size)
            compareWithFigma()
            let text = figmaFindings.map { "\($0.ok ? "OK" : "MISMATCH")\t\($0.title)\t\($0.detail)" }.joined(separator: "\n") + "\n"
            try? text.write(toFile: fake + ".out", atomically: true, encoding: .utf8)
            return
        }
        if let png = env["MYGIT_3D"] {
            // MYGIT_3D_RANGE=lo-hi narrows the layers; the render is 1200×900.
            if let spec = env["MYGIT_3D_RANGE"]?.split(separator: "-").compactMap({ Int($0) }), spec.count == 2 {
                layerRange = max(0, spec[0])...min(maxDepth, max(spec[0], spec[1]))
            }
            if let window = currentWindow {
                let size = CGSize(width: 1200, height: 900)
                let scale = min(size.width / window.size.width, size.height / window.size.height) * 0.6
                let renderer = ImageRenderer(content: Inspector3DCanvas(window: window, scale: scale)
                    .environmentObject(self).frame(width: size.width, height: size.height)
                    .background(Color(NSColor.underPageBackgroundColor)))
                renderer.scale = 1
                if let data = renderer.nsImage?.pngData() { try? data.write(to: URL(fileURLWithPath: png)) }
            }
            return
        }
        if let png = env["MYGIT_SPEC"], let source = env["MYGIT_SPEC_SOURCE"] {
            // The view tagged "File.swift:line", as selected from the outline.
            guard let tagID = allTagNodeIDs().first(where: { id in
                rawNode(id)?.props["value"].flatMap(InspectorSourceTag.init)?.label == source
            }) else { return }
            let nodeID = visibleOwner(below: tagID)
            Task { @MainActor [weak self] in
                guard let self else { return }
                guard let snapshot = await specSnapshot(for: nodeID),
                      let data = InspectorSpecWindow.render(snapshot, size: CGSize(width: 1200, height: 800),
                                                            hovered: env["MYGIT_SPEC_HOVER"].flatMap { Int($0) })?.pngData() else { return }
                try? data.write(to: URL(fileURLWithPath: png))
            }
            return
        }
        if let png = env["MYGIT_REDLINES"] {
            Task { @MainActor [weak self] in
                if let data = await self?.redlinesImage(area: nil)?.pngData() { try? data.write(to: URL(fileURLWithPath: png)) }
            }
            return
        }
        let measures = collectMeasures()
        let screen = ProcessInfo.processInfo.environment["MYGIT_AUDIT_SCREEN"] ?? "screen-\(auditedScreens.count)"
        Task { @MainActor in
            var seen = Set<String>()
            var lines: [String] = []
            for m in measures {
                // Corners of one shape share a token: once.
                let key = m.kind == .radius ? "r:\(m.nodeID)" : m.id
                guard seen.insert(key).inserted else { continue }
                var record: [String: Any] = ["screen": screen, "kind": m.kind.rawValue, "edge": m.edge,
                                             "value": Double(m.value), "tag": chainTag(of: m.nodeID)?.stack.first?.label ?? "-"]
                if let token = measureToken(m) {
                    record["arg"] = token.arg.expr
                    let value = Self.fmt(m.value)
                    let resolution = await resolveTokenExactly(token.arg.expr, refs: token.arg.refs, binding: token.arg.binding,
                                                               probe: token.arg.probe, stack: token.stack, runtimeValue: value)
                        ?? resolveToken(token.arg.expr, stack: token.stack, runtimeValue: value)
                    if let root = measureRoot(m, resolution, near: token.stack.first) {
                        record["token"] = root.name
                        record["literal"] = root.literal ?? ""
                        record["status"] = "ok"
                    } else if let alternatives = resolution?.alternatives, !alternatives.isEmpty {
                        record["status"] = "ambiguous"
                        record["candidates"] = alternatives.map(\.name)
                    } else {
                        record["status"] = "unresolved"
                    }
                } else {
                    record["status"] = "no-arg"
                    record["reason"] = auditReason(m)
                }
                if let data = try? JSONSerialization.data(withJSONObject: record, options: [.sortedKeys]) {
                    lines.append(String(decoding: data, as: UTF8.self))
                }
            }
            let text = lines.joined(separator: "\n") + "\n"
            if let handle = FileHandle(forWritingAtPath: path) {
                handle.seekToEndOfFile(); handle.write(Data(text.utf8)); try? handle.close()
            } else {
                try? text.write(toFile: path, atomically: true, encoding: .utf8)
            }
        }
    }

    /// Why `measureToken` found no argument.
    private func auditReason(_ m: InspectorMeasure) -> String {
        if let style = systemStyle(around: m.nodeID) { return "system: SwiftUI \(style)" }
        guard let chain = chainTag(of: m.nodeID) else { return "no tag on the chain" }
        guard let entry = chain.stack.first.flatMap({ sourceEntry(for: $0) }) else { return "tag has no map entry" }
        switch m.kind {
        case .padding:
            let written = entry.mods.filter { $0.name == "padding" }
            if written.isEmpty && entry.call != "padding" { return "no .padding in \(entry.call)… chain" }
            if let source = paddingSource(m.nodeID) {
                return "hardcoded: .padding(\(source.mod.args.map(\.expr).joined(separator: ", ")))"
            }
            return "no matching .padding (\(written.count) written)"
        case .gap:
            if let spacing = entry.args.first(where: { $0.label == "spacing" }) { return "hardcoded: spacing: \(spacing.expr)" }
            return "spacing not written (\(entry.call) default)"
        case .radius:
            let mods = entry.mods.map(\.name).joined(separator: ",")
            return "no radius argument (\(entry.call); mods: \(mods))"
        }
    }
}
