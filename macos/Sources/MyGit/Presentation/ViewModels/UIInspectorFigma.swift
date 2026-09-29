import AppKit

/// One check of the app against the linked Figma frame.
struct FigmaFinding: Identifiable {
    let id = UUID()
    let ok: Bool
    let title: String
    let detail: String
    /// Where in the app (window points), and what to select.
    let frame: CGRect
    let nodeID: String?
    let measure: InspectorMeasure?
}

/// A Figma frame laid over the app: its picture as an overlay, its auto
/// layout, corners and text colors compared with what the app renders.
extension UIInspectorViewModel {
    static let figmaHost = "api.figma.com"

    var hasFigmaToken: Bool { credentials?.hasToken(host: Self.figmaHost) == true }

    func setFigmaToken(_ token: String) {
        let trimmed = token.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { credentials?.delete(host: Self.figmaHost) } else { credentials?.setToken(trimmed, host: Self.figmaHost) }
    }

    /// Link a frame: fetch its node tree and picture, lay it over the selected
    /// view (or the whole screen), and compare.
    func linkFigma(_ link: String) {
        figmaError = nil
        guard let parsed = FigmaClient.parse(link) else { figmaError = FigmaError.badLink.localizedDescription; return }
        guard let token = credentials?.token(host: Self.figmaHost) else { figmaError = FigmaError.noToken.localizedDescription; return }
        guard let window = currentWindow else { return }
        let area = selectedNode?.frame ?? CGRect(origin: .zero, size: window.size)
        figmaLoading = true
        Task { @MainActor [weak self] in
            let client = FigmaClient(token: token)
            do {
                async let node = client.node(fileKey: parsed.fileKey, nodeID: parsed.nodeID)
                async let png = client.image(fileKey: parsed.fileKey, nodeID: parsed.nodeID)
                let (root, data) = try await (node, png)
                guard let self else { return }
                figmaNode = root
                figmaImage = NSImage(data: data)
                figmaArea = area
                figmaLink = link
                showFigma = true
                compareWithFigma()
            } catch {
                self?.figmaError = error.localizedDescription
            }
            self?.figmaLoading = false
        }
    }

    func unlinkFigma() {
        figmaNode = nil; figmaImage = nil; figmaFindings = []; figmaLink = nil; showFigma = false
    }

    /// A Figma box in app window points: the root frame fills `figmaArea`'s
    /// width (and starts at its top-left); everything scales with it.
    func appFrame(ofFigma box: FigmaNode.Box) -> CGRect? {
        guard let root = figmaNode?.absoluteBoundingBox, root.width > 0 else { return nil }
        let s = figmaArea.width / root.width
        return CGRect(x: figmaArea.minX + (box.x - root.x) * s, y: figmaArea.minY + (box.y - root.y) * s,
                      width: box.width * s, height: box.height * s)
    }

    /// Paddings, gaps and corners measured in the app next to the Figma nodes
    /// in the same place; text colors next to the Figma text there.
    func compareWithFigma() {
        guard let root = figmaNode else { figmaFindings = []; return }
        let nodes = root.flattened.compactMap { node -> (FigmaNode, CGRect)? in
            node.absoluteBoundingBox.flatMap { appFrame(ofFigma: $0) }.map { (node, $0) }
        }
        func same(_ a: CGRect, _ b: CGRect) -> Bool {
            let tolerance = max(2, 0.03 * max(a.width, a.height))
            return abs(a.minX - b.minX) <= tolerance && abs(a.minY - b.minY) <= tolerance
                && abs(a.width - b.width) <= tolerance && abs(a.height - b.height) <= tolerance
        }
        var findings: [FigmaFinding] = []
        var seen = Set<String>()
        let collected = collectMeasures()
        for m in collected where figmaArea.insetBy(dx: -1, dy: -1).contains(m.rect.integral.insetBy(dx: 1, dy: 1)) {
            guard seen.insert(m.kind == .radius ? "r:\(m.nodeID)" : m.id).inserted, let box = rawNode(m.nodeID)?.frame else { continue }
            var spec: (value: Double, node: FigmaNode)?
            switch m.kind {
            case .padding:
                continue    // Per padding node below, zero edges included.
            case .gap:
                let axis = m.rect.width < m.rect.height ? "HORIZONTAL" : "VERTICAL"
                if let (node, _) = nodes.first(where: { $0.0.layoutMode == axis && same($0.1, box) }), let gap = node.itemSpacing {
                    spec = (gap, node)
                }
            case .radius:
                if let (node, _) = nodes.first(where: { ($0.0.cornerRadius ?? 0) > 0 && same($0.1, box) }), let radius = node.cornerRadius {
                    spec = (radius, node)
                }
            }
            guard let spec else { continue }
            // Pills (9999) and "as round as it gets" in Figma agree.
            let ok = abs(spec.value - Double(m.value)) < 0.5 || (m.kind == .radius && spec.value >= Double(m.value) - 0.5)
            findings.append(.init(ok: ok, title: "\(m.kind.rawValue) \(m.edge)",
                                  detail: ok ? "\(Self.fmt(m.value)) — matches “\(spec.node.name)”"
                                             : "app \(Self.fmt(m.value)), Figma \(Self.fmt(spec.value)) (“\(spec.node.name)”)",
                                  frame: m.rect, nodeID: m.ownerID, measure: m))
        }
        findings += paddingFindings(nodes: nodes, measures: collected, same: same)
        findings += textColorFindings(figmaTexts: nodes.filter { $0.0.type == "TEXT" })
        figmaFindings = findings.sorted { ($0.ok ? 1 : 0, $0.frame.minY) < ($1.ok ? 1 : 0, $1.frame.minY) }
    }

    /// Every padding in the area against the auto-layout frame in the same
    /// place, all four edges — a padding the app renders as 0 but Figma
    /// specifies is exactly what to catch.
    private func paddingFindings(nodes: [(FigmaNode, CGRect)], measures: [InspectorMeasure],
                                 same: (CGRect, CGRect) -> Bool) -> [FigmaFinding] {
        guard let root = currentWindow?.root else { return [] }
        // Paddings stack (`.padding(.top, a).padding(.bottom, b)`): group those
        // lining up with one Figma frame and compare their combined inset.
        var groups: [String: (spec: FigmaNode, paddings: [InspectorNode])] = [:]
        var stack = [root]
        while let node = stack.popLast() {
            stack += node.children
            guard node.className == "_PaddingLayout", figmaArea.insetBy(dx: -1, dy: -1).contains(node.frame),
                  let (spec, _) = nodes.first(where: { $0.0.layoutMode ?? "NONE" != "NONE" && same($0.1, node.frame) }) else { continue }
            groups[spec.id, default: (spec, [])].paddings.append(node)
        }
        var out: [FigmaFinding] = []
        for (_, group) in groups {
            // Outermost box, innermost content.
            guard let outer = group.paddings.max(by: { $0.frame.width * $0.frame.height < $1.frame.width * $1.frame.height }),
                  let content = group.paddings.compactMap({ p in contentChild(p.id).flatMap { geometry(of: $0) } })
                    .min(by: { $0.width * $0.height < $1.width * $1.height }) else { continue }
            let box = outer.frame
            let insets: [String: CGFloat] = ["top": content.minY - box.minY, "bottom": box.maxY - content.maxY,
                                             "leading": content.minX - box.minX, "trailing": box.maxX - content.maxX]
            let spec = group.spec
            let figma: [String: Double?] = ["top": spec.paddingTop, "bottom": spec.paddingBottom,
                                            "leading": spec.paddingLeft, "trailing": spec.paddingRight]
            let ids = Set(group.paddings.map(\.id))
            for edge in ["top", "bottom", "leading", "trailing"] {
                guard let app = insets[edge], let wanted = figma[edge] ?? nil else { continue }
                guard app > 0.5 || wanted > 0.5 else { continue }     // both zero says nothing
                let ok = abs(Double(app) - wanted) < 0.5
                let measure = measures.first { ids.contains($0.nodeID) && $0.edge == edge }
                out.append(.init(ok: ok, title: "Padding \(edge)",
                                 detail: ok ? "\(Self.fmt(app)) — matches “\(spec.name)”"
                                            : "app \(Self.fmt(app)), Figma \(Self.fmt(wanted)) (“\(spec.name)”)",
                                 frame: box, nodeID: measure?.ownerID ?? visibleOwner(below: outer.id), measure: measure))
            }
        }
        return out
    }

    /// Each app Text's drawn color against the Figma text most overlapping it.
    private func textColorFindings(figmaTexts: [(FigmaNode, CGRect)]) -> [FigmaFinding] {
        guard let root = currentWindow?.root else { return [] }
        var out: [FigmaFinding] = []
        var stack = [root]
        while let node = stack.popLast() {
            stack += node.children
            guard let color = node.props.first(where: { $0.key.hasSuffix("storage.foregroundColor") })?.value,
                  figmaArea.intersects(node.frame) else { continue }
            let best = figmaTexts.max { a, b in
                a.1.intersection(node.frame).width * a.1.intersection(node.frame).height
                    < b.1.intersection(node.frame).width * b.1.intersection(node.frame).height
            }
            guard let (text, box) = best, !box.intersection(node.frame).isNull, let figmaHex = text.solidFillHex else { continue }
            let appHex = String(color.dropFirst().prefix(6)).uppercased()
            let ok = Self.hexClose(appHex, figmaHex)
            let label = text.characters.map { "“\($0.prefix(24))”" } ?? text.name
            out.append(.init(ok: ok, title: "Text color \(label)",
                             detail: ok ? "#\(appHex) matches" : "app #\(appHex), Figma #\(figmaHex)",
                             frame: node.frame, nodeID: isShown(node.id) ? node.id : nil, measure: nil))
        }
        return out
    }

    /// Same color within rounding (±2 per channel).
    static func hexClose(_ a: String, _ b: String) -> Bool {
        func channels(_ s: String) -> [Int] {
            stride(from: 0, to: min(6, s.count), by: 2).map { i in
                Int(s[s.index(s.startIndex, offsetBy: i)..<s.index(s.startIndex, offsetBy: i + 2)], radix: 16) ?? 0
            }
        }
        let x = channels(a), y = channels(b)
        return x.count == 3 && y.count == 3 && zip(x, y).allSatisfy { abs($0 - $1) <= 2 }
    }

    func selectFigmaFinding(_ finding: FigmaFinding) {
        if let measure = finding.measure { select(measure); return }
        if let id = finding.nodeID { reveal(id) }
    }
}
