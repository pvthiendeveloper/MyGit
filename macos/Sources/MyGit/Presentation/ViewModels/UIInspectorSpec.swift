import AppKit

/// The Spec card: a selected view's own paddings, gaps and corners with
/// their tokens, drawn like a Figma spec.
extension UIInspectorViewModel {
    /// The measures that belong to a view: its paddings, its stacks' gaps, its
    /// corners — and its direct children's, nothing deeper. At most 14.
    func specMeasures(for id: String) -> [InspectorMeasure] {
        let box = specBox(for: id)
        func depth(of nodeID: String) -> Int? {
            // Tags between the selection and the measure's node: 0 = the view's own.
            var cursor: String? = nodeID
            var tags = 0
            for _ in 0..<200 {
                guard let c = cursor else { return nil }
                if c == id { return tags }
                if let n = rawNode(c), Self.isTag(n.className) { tags += 1 }
                cursor = rawParent(c)
            }
            return nil
        }
        var seen = Set<String>()
        let wrappers = Set(ownWrappers(of: id))
        let own = collectMeasures().compactMap { m -> (InspectorMeasure, Int)? in
            guard box.insetBy(dx: -1, dy: -1).contains(m.rect.integral.insetBy(dx: 1, dy: 1)),
                  seen.insert(m.kind == .radius ? "r:\(m.nodeID)" : m.id).inserted else { return nil }
            // Its own chain's paddings sit above it; anything else must be inside it.
            let d = depth(of: m.nodeID) ?? (wrappers.contains(m.nodeID) ? 0 : nil)
            guard let d, d <= 2 else { return nil }
            return (m, d)
        }
        return own.sorted { ($0.1, -$0.0.rect.width * $0.0.rect.height) < ($1.1, -$1.0.rect.width * $1.0.rect.height) }
            .prefix(14).map(\.0)
    }

    /// The view with the paddings and frames wrapped around it: what the card crops to.
    func specBox(for id: String) -> CGRect {
        guard let node = rawNode(id) else { return .zero }
        return ownWrappers(of: id).compactMap(rawNode).reduce(node.frame) { box, modifier in
            modifier.frame.width > 0 && modifier.frame.height > 0 ? box.union(modifier.frame) : box
        }
    }

    /// The modifiers wrapped around a view by its own code: up through its
    /// chains' modifiers and tags while they're from the same module (a
    /// component's `body` wraps what it returns — `contentView.clipShape(…)`).
    /// A tag from elsewhere is the call site placing it, whose paddings
    /// space the component out and aren't its own.
    func ownWrappers(of id: String) -> [String] {
        var out: [String] = []
        var module: String?
        var cursor = rawParent(id)
        while let c = cursor, let node = rawNode(c), node.isModifier || Self.isWrapper(node.className) {
            // Style tags are helpers (`.tymeXTextStyle(…)`, maybe from another module): pass through.
            if node.className == Self.sourceTagClass {
                guard let tag = node.props["value"].flatMap(InspectorSourceTag.init) else { break }
                let root = tag.path.split(separator: "/").first.map(String.init) ?? tag.path
                if module == nil { module = root } else if module != root { break }
            }
            out.append(c)
            cursor = rawParent(c)
        }
        return out
    }

    /// Open the Spec window for a view: resolve its tokens, then freeze the
    /// picture so live captures don't disturb it.
    func openSpec(for id: String) {
        Task { @MainActor [weak self] in
            if let snapshot = await self?.specSnapshot(for: id) { InspectorSpecWindow.open(snapshot) }
        }
    }

    func specSnapshot(for id: String) async -> InspectorSpecSnapshot? {
        guard let window = currentWindow, let screenshot = window.image else { return nil }
        let measures = specMeasures(for: id)
        let box = specBox(for: id)
        var shapes: [String: CGRect] = [:]
        for m in measures where m.kind == .radius { shapes[m.nodeID] = rawNode(m.nodeID)?.frame }
        let title = sourceStack(for: id).first?.label ?? rawNode(id)?.shortName ?? "View"
        var names: [String: String] = [:]
        for m in measures { names[m.id] = await tokenName(for: m) }
        return InspectorSpecSnapshot(title: title, screenshot: screenshot, windowSize: window.size,
                                     box: box, measures: measures, names: names, shapes: shapes)
    }
}
