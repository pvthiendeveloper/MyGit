import AppKit
import Combine

/// State for the UI Inspector window: which app is connected, its latest
/// snapshot, and the outline / preview / attributes selection.
@MainActor
final class UIInspectorViewModel: ObservableObject {
    /// One visible line of the outline.
    /// One visible line of the outline: a node, or — with Compact Chains —
    /// a run of single-child nodes shown as `A › B › C` (like Android
    /// Studio's "Compact Middle Packages").
    struct Row: Identifiable {
        /// Top to bottom; `node` (the last) owns the children and the id.
        let chain: [InspectorNode]
        let depth: Int
        let hasChildren: Bool
        let isExpanded: Bool
        let label: String
        let detail: String?
        var node: InspectorNode { chain[chain.count - 1] }
        var id: String { node.id }

        func contains(_ id: String?) -> Bool {
            guard let id else { return false }
            return chain.contains { $0.id == id }
        }
    }

    /// Outline geometry, shared with the view so the measured width matches.
    enum OutlineMetrics {
        static let indent: CGFloat = 12
        static let disclosure: CGFloat = 12
        static let icon: CGFloat = 16
        static let spacing: CGFloat = 4
        static let trailing: CGFloat = 16
        static let maxLabelWidth: CGFloat = 900
        static let labelFont = NSFont.systemFont(ofSize: 12)
        static let detailFont = NSFont.systemFont(ofSize: 11)
    }

    @Published private(set) var services: [InspectorService] = []
    @Published private(set) var connected: InspectorService?
    @Published private(set) var snapshot: InspectorSnapshot?
    @Published private(set) var rows: [Row] = []
    /// Width of the widest row (indent + label), so the outline can scroll
    /// sideways to it — lazy stacks only size the rows they've rendered.
    @Published private(set) var outlineWidth: CGFloat = 0
    @Published private(set) var isLoading = false
    @Published var errorMessage: String?

    @Published var windowIndex = 0 { didSet { rebuildTree() } }
    @Published var selectedID: String? { didSet { selectionChanged(from: oldValue) } }
    @Published var hoveredID: String?
    @Published var filter = "" { didSet { rebuildRows() } }
    /// Fold SwiftUI modifiers (`_PaddingLayout`, `AccessibilityAttachmentModifier`…)
    /// into their content, so the outline reads like the code.
    @Published var hideModifiers: Bool { didSet { defaults.set(hideModifiers, forKey: Keys.hideModifiers); rebuildTree() } }
    /// Only the views written in the source (one row per tagged view, named
    /// as written), what shows text, and public UIKit views — SwiftUI's
    /// plumbing and UIKit controls' private parts fold away.
    @Published var sourceViewsOnly: Bool { didSet { defaults.set(sourceViewsOnly, forKey: Keys.sourceOnly); rebuildTree() } }
    /// Measure mode: padding strips, stack gaps and rounded corners can be
    /// hovered and picked in the preview, like views.
    @Published var measureMode: Bool {
        didSet {
            defaults.set(measureMode, forKey: Keys.measure)
            measures = measureMode ? collectMeasures() : []
            if !measureMode { hoveredMeasureID = nil; selectedMeasure = nil }
        }
    }
    @Published private(set) var measures: [InspectorMeasure] = []
    @Published var hoveredMeasureID: String? { didSet { hoveredMeasure.map(loadTokenName) } }
    /// The measure last clicked; its view is `selectedID`.
    @Published var selectedMeasure: InspectorMeasure? { didSet { selectedMeasure.map(loadTokenName) } }
    /// Measure id → the design token behind it ("" = none found), for the
    /// preview's pill. Filled on first hover/pick.
    @Published var measureTokenNames: [String: String] = [:]
    var measureTokenLoads = Set<String>()
    /// `MYGIT_AUDIT_MEASURES`: screens already audited.
    var auditedScreens = Set<Int>()
    var lastAuditSignature: Int?
    var hoveredMeasure: InspectorMeasure? { hoveredMeasureID.flatMap { id in measures.first { $0.id == id } } }
    @Published var showWireframes: Bool { didSet { defaults.set(showWireframes, forKey: Keys.wireframes) } }
    /// Fold runs of single-child nodes into one `A › B › C` row.
    @Published var compactChains: Bool { didSet { defaults.set(compactChains, forKey: Keys.compact); rebuildRows() } }
    @Published var highlightOnDevice: Bool {
        didSet {
            defaults.set(highlightOnDevice, forKey: Keys.highlight)
            sendHighlight()
        }
    }
    @Published var autoRefresh = false { didSet { updateAutoRefresh() } }

    /// Several places matched "Open in Editor"; the view asks which one.
    struct SourceChoice: Identifiable {
        let id = UUID()
        let title: String
        let hits: [InspectorSourceHit]
    }
    @Published var sourceChoice: SourceChoice?
    @Published private(set) var isSearchingSource = false
    /// Resolves views to code in the repos open in MyGit.
    weak var sourceNavigator: InspectorSourceNavigating?
    /// Starts the active repo's "Run with Inspector" (nil when unavailable).
    var runWithInspector: (() -> Void)?
    /// The AI provider for "pick the branch" (nil hides the button), and its
    /// current config (nil when no provider is set up).
    var ai: CommitMessageRepository?
    var aiConfig: (() -> AIRequestConfig?)?
    /// AI picks by token key, so reselecting a view doesn't ask again.
    var aiPicks: [String: InspectorTokenResolution] = [:]
    /// Source maps by file path, with the modification date they were read at.
    private var sourceMaps: [String: (date: Date?, map: [String: InspectorSourceMapEntry])] = [:]

    /// Property indexes by URL, with the modification date they were read at.
    private var symbolIndexes: [URL: (date: Date?, index: [String: [InspectorSymbol]], byFile: [String: [InspectorSymbol]])] = [:]

    /// The repo's property index by name.
    func symbolIndex(near tag: InspectorSourceTag) -> [String: [InspectorSymbol]] {
        loadSymbolIndex(near: tag)?.index ?? [:]
    }

    /// The same index grouped by file.
    /// Properties named `name` in the repo's property index.
    func symbols(named name: String, near tag: InspectorSourceTag) -> [InspectorSymbol] {
        loadSymbolIndex(near: tag)?.index[name] ?? []
    }

    func symbolsByFile(near tag: InspectorSourceTag) -> [String: [InspectorSymbol]] {
        loadSymbolIndex(near: tag)?.byFile ?? [:]
    }

    private func loadSymbolIndex(near tag: InspectorSourceTag)
        -> (date: Date?, index: [String: [InspectorSymbol]], byFile: [String: [InspectorSymbol]])? {
        guard let url = sourceNavigator?.symbolIndexURL(forRelativePath: tag.path) else { return nil }
        let date = (try? FileManager.default.attributesOfItem(atPath: url.path))?[.modificationDate] as? Date
        if let cached = symbolIndexes[url], cached.date == date { return cached }
        let index = (try? FileManager.default.contents(atPath: url.path)
            .flatMap { try JSONDecoder().decode([String: [InspectorSymbol]].self, from: $0) }) ?? [:]
        var byFile: [String: [InspectorSymbol]] = [:]
        for (_, list) in index {
            for symbol in list { byFile[symbol.path, default: []].append(symbol) }
        }
        let loaded = (date, index, byFile)
        symbolIndexes[url] = loaded
        return loaded
    }

    /// How the tagged expression was written (tokens vs hardcoded values).
    func sourceEntry(for tag: InspectorSourceTag) -> InspectorSourceMapEntry? {
        guard let url = sourceNavigator?.sourceMapURL(forRelativePath: tag.path) else { return nil }
        let date = (try? FileManager.default.attributesOfItem(atPath: url.path))?[.modificationDate] as? Date
        if let cached = sourceMaps[tag.path], cached.date == date { return cached.map[tag.id] }
        let map = (try? FileManager.default.contents(atPath: url.path)
            .flatMap { try JSONDecoder().decode([String: InspectorSourceMapEntry].self, from: $0) }) ?? [:]
        sourceMaps[tag.path] = (date, map)
        return map[tag.id]
    }

    private let browser = InspectorBrowser()
    private var connection: InspectorConnection?
    private var refreshTask: Task<Void, Never>?
    private var autoRefreshTask: Task<Void, Never>?
    private let defaults: UserDefaults

    /// The current window's tree after folding modifiers.
    private var nodes: [String: InspectorNode] = [:]
    private var childrenOf: [String: [String]] = [:]
    private var parentOf: [String: String] = [:]
    private var rootIDs: [String] = []
    /// Pre-order, so hit-testing can prefer deeper nodes on ties.
    private var order: [String] = []
    private var collapsed: Set<String> = []
    /// The window's full tree (modifiers included), for the attributes panel.
    private var rawNodes: [String: InspectorNode] = [:]
    private var rawParentOf: [String: String] = [:]
    private var rawChildrenOf: [String: [String]] = [:]
    private var tagNodeIDs: [String] = []

    func allTagNodeIDs() -> [String] { tagNodeIDs }

    func rawNode(_ id: String) -> InspectorNode? { rawNodes[id] }
    func rawParent(_ id: String) -> String? { rawParentOf[id] }
    func rawChildren(_ id: String) -> [String] { rawChildrenOf[id] ?? [] }

    private enum Keys {
        static let hideModifiers = "MyGit.inspector.hideModifiers"
        static let wireframes = "MyGit.inspector.wireframes"
        static let highlight = "MyGit.inspector.highlightOnDevice"
        static let compact = "MyGit.inspector.compactChains"
        static let sourceOnly = "MyGit.inspector.sourceViewsOnly"
        static let measure = "MyGit.inspector.measureMode"
    }

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        hideModifiers = defaults.object(forKey: Keys.hideModifiers) as? Bool ?? true
        showWireframes = defaults.object(forKey: Keys.wireframes) as? Bool ?? true
        highlightOnDevice = defaults.object(forKey: Keys.highlight) as? Bool ?? true
        compactChains = defaults.object(forKey: Keys.compact) as? Bool ?? true
        sourceViewsOnly = defaults.object(forKey: Keys.sourceOnly) as? Bool ?? true
        measureMode = defaults.object(forKey: Keys.measure) as? Bool ?? false
    }

    // MARK: - Discovery & connection

    func startBrowsing() {
        browser.start { [weak self] services in
            guard let self else { return }
            self.services = services
            // Reconnect to the same app after it relaunches.
            if self.connected == nil, let only = services.first, services.count == 1 {
                self.connect(only)
            }
        }
    }

    func stopBrowsing() {
        browser.stop()
        autoRefresh = false
        disconnect()
    }

    func connect(_ service: InspectorService) {
        disconnect()
        let connection = InspectorConnection(service: service)
        connection.onClose = { [weak self, weak connection] in
            guard let self, self.connection === connection else { return }
            self.connection = nil
            self.connected = nil
            self.autoRefresh = false
        }
        self.connection = connection
        connected = service
        refresh()
        // The audit needs captures to keep coming (see `auditMeasuresIfRequested`).
        if ProcessInfo.processInfo.environment["MYGIT_AUDIT_MEASURES"] != nil { autoRefresh = true }
    }

    func disconnect() {
        refreshTask?.cancel()
        connection?.cancel()
        connection = nil
        connected = nil
    }

    // MARK: - Capture

    func refresh() {
        guard let connection, refreshTask == nil else { return }
        isLoading = true
        refreshTask = Task { [weak self] in
            defer {
                self?.isLoading = false
                self?.refreshTask = nil
            }
            do {
                let snapshot = try await connection.hierarchy()
                guard let self, !Task.isCancelled else { return }
                self.errorMessage = nil
                self.apply(snapshot)
            } catch {
                guard let self, !Task.isCancelled else { return }
                self.errorMessage = error.localizedDescription
                self.autoRefresh = false
            }
        }
    }

    private func apply(_ snapshot: InspectorSnapshot) {
        let firstCapture = self.snapshot == nil
        self.snapshot = snapshot
        if firstCapture || windowIndex >= snapshot.windows.count {
            // The key window is usually the app; alerts/keyboards sit above it.
            windowIndex = snapshot.windows.firstIndex(where: \.isKey) ?? max(0, snapshot.windows.count - 1)
        } else {
            rebuildTree()
        }
        if let selectedID, nodes[selectedID] == nil { self.selectedID = nil }
        auditMeasuresIfRequested()
    }

    private func updateAutoRefresh() {
        autoRefreshTask?.cancel()
        guard autoRefresh else { return }
        autoRefreshTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 1_500_000_000)
                guard let self, !Task.isCancelled, self.connection != nil else { return }
                self.refresh()
            }
        }
    }

    var currentWindow: InspectorWindow? {
        guard let windows = snapshot?.windows, windows.indices.contains(windowIndex) else { return nil }
        return windows[windowIndex]
    }

    var selectedNode: InspectorNode? { selectedID.flatMap { nodes[$0] } }
    var hoveredNode: InspectorNode? { hoveredID.flatMap { nodes[$0] } }

    /// Every node of the current window with a drawable frame, for wireframes.
    var wireframeNodes: [InspectorNode] {
        order.compactMap { nodes[$0] }.filter { !$0.isHidden && $0.frame.width > 0 && $0.frame.height > 0 }
    }

    /// Path from the root to the selection, for the breadcrumb.
    var selectionPath: [InspectorNode] {
        var path: [InspectorNode] = []
        var id = selectedID
        while let current = id, let node = nodes[current] {
            path.insert(node, at: 0)
            id = parentOf[current]
        }
        return path
    }

    // MARK: - Tree

    private func rebuildTree() {
        nodes = [:]; childrenOf = [:]; parentOf = [:]; rootIDs = []; order = []
        rawNodes = [:]; rawParentOf = [:]; rawChildrenOf = [:]; tagNodeIDs = []
        sourceNames = [:]
        if let root = currentWindow?.root {
            if sourceViewsOnly { markSourceViews(root) }
            rootIDs = visible(root).map { add($0, parent: nil) }
            // Iterative: trees run a few hundred levels deep.
            var stack = [root]
            while let node = stack.popLast() {
                rawNodes[node.id] = node
                if node.className == Self.sourceTagClass { tagNodeIDs.append(node.id) }
                if !node.children.isEmpty {
                    rawChildrenOf[node.id] = node.children.map(\.id)
                    for child in node.children { rawParentOf[child.id] = node.id }
                    stack += node.children
                }
            }
        }
        rebuildRows()
        if measureMode {
            measures = collectMeasures()
            // Keep a picked measure across live captures (same node, same edge).
            if let picked = selectedMeasure { selectedMeasure = measures.first { $0.id == picked.id } ?? picked }
        }
    }

    /// Whether the outline shows this node (it can be selected / revealed).
    func isShown(_ id: String) -> Bool { nodes[id] != nil }

    /// With `hideModifiers`, a modifier node is replaced by its children;
    /// with `sourceViewsOnly`, every node that isn't a source view is.
    private func visible(_ node: InspectorNode) -> [InspectorNode] {
        if sourceViewsOnly {
            return isSourceView(node) ? [node] : node.children.flatMap(visible)
        }
        guard hideModifiers, node.kind == .swiftui, node.isModifier else { return [node] }
        return node.children.flatMap(visible)
    }

    /// Source Views mode: tagged view → the name it's written with (`TextField`).
    private var sourceNames: [String: String] = [:]

    /// The view each tag stands for: below the tag, past modifiers and
    /// wrappers, the first real view (nested tags — a call site and the
    /// body it expands to — land on the same one; the innermost name wins).
    private func markSourceViews(_ root: InspectorNode) {
        var stack = [root]
        while let node = stack.popLast() {
            stack += node.children
            guard node.className == Self.sourceTagClass, let value = node.props["value"],
                  let tag = InspectorSourceTag(value) else { continue }
            var current = node
            while let next = Self.content(of: current) { current = next }
            // A node several views branch off stands for them — a custom `Layout`
            // has no node of its own, its subviews hang off the tag.
            guard current.children.count > 1 || (!current.isModifier && current.className != Self.sourceTagClass) else { continue }
            let name = sourceEntry(for: tag)?.call
            if sourceNames[current.id] == nil || name != nil { sourceNames[current.id] = name ?? current.shortName }
        }
    }

    /// The view a modifier / wrapper / tag applies to, or nil where the
    /// node is itself the view (or several views branch off it).
    private static func content(of node: InspectorNode) -> InspectorNode? {
        guard node.isModifier || node.className == sourceTagClass || isWrapper(node.className) else { return nil }
        return contentChild(of: node.className, isModifier: node.isModifier, node.children)
    }

    /// `.overlay(X)` / `.background(X)` hold two subtrees — X first, the
    /// content last (checked on live trees); anything else wraps one child.
    static func contentChild<T>(of className: String, isModifier: Bool, _ children: [T]) -> T? {
        if isModifier, decoratingModifiers.contains(where: { className.hasPrefix($0) }) { return children.last }
        return children.count == 1 ? children[0] : nil
    }

    private static let decoratingModifiers = [
        "_OverlayModifier", "_BackgroundModifier", "_OverlayShapeModifier", "_BackgroundShapeModifier",
        "_OverlayStyleModifier", "_BackgroundStyleModifier",
    ]

    private func isSourceView(_ node: InspectorNode) -> Bool {
        switch node.kind {
        case .swiftui:
            if sourceNames[node.id] != nil { return true }
            // Untagged content: what a view says (`Text` inside a `Button`).
            return !node.isModifier && node.text?.isEmpty == false
        case .uikit:
            // Windows, hosting views and public UIKit views; SDK internals
            // (`_UI…`) and the containers SwiftUI/UIKit wrap them in fold.
            if node.className.hasPrefix("_UIHostingView") { return true }
            return !node.className.hasPrefix("_") && !Self.uikitPlumbing.contains { node.className.hasPrefix($0) }
        }
    }

    private static let uikitPlumbing = [
        "UIKitPlatformViewHost", "PlatformContainer", "PlatformGroupContainer", "UITransitionView",
        "UIViewControllerWrapperView", "UILayoutContainerView", "UINavigationTransitionView", "UIDropShadowView",
        "HostingView", "UIKitNavigationController", "UIKitPlatformViewHost",
    ]

    /// System controls draw their own insides (selection, cursor, track…).
    private static let uikitLeafControls: Set<String> = [
        "UITextField", "UITextView", "UIButton", "UISwitch", "UISlider", "UILabel", "UIImageView",
        "UIDatePicker", "UISegmentedControl", "UIStepper", "UIProgressView", "UIActivityIndicatorView",
        "UISearchTextField", "UIPickerView",
    ]

    @discardableResult
    private func add(_ node: InspectorNode, parent: String?) -> String {
        nodes[node.id] = node
        order.append(node.id)
        if let parent { parentOf[node.id] = parent }
        let leaf = sourceViewsOnly && node.kind == .uikit && Self.uikitLeafControls.contains(node.className)
        let children = leaf ? [] : node.children.flatMap(visible)
        if !children.isEmpty { childrenOf[node.id] = children.map { add($0, parent: node.id) } }
        return node.id
    }

    private func rebuildRows() {
        let query = filter.trimmingCharacters(in: .whitespaces).lowercased()
        var matches: Set<String>?
        if !query.isEmpty {
            // Keep matching nodes and every ancestor of one.
            var keep: Set<String> = []
            for (id, node) in nodes where Self.matches(node, query) {
                var cursor: String? = id
                while let c = cursor, keep.insert(c).inserted { cursor = parentOf[c] }
            }
            matches = keep
        }
        func children(of id: String) -> [String] {
            let all = childrenOf[id] ?? []
            guard let matches else { return all }
            return all.filter { matches.contains($0) }
        }
        var out: [Row] = []
        var width: CGFloat = 0
        func walk(_ id: String, depth: Int) {
            guard let first = nodes[id], matches?.contains(id) ?? true else { return }
            var chain = [first]
            var kids = children(of: id)
            // Compact: keep descending while there's exactly one child.
            // A collapsed link ends the chain so it can still be opened.
            while compactChains, kids.count == 1, matches != nil || !collapsed.contains(chain.last!.id),
                  let only = nodes[kids[0]] {
                chain.append(only)
                kids = children(of: only.id)
            }
            let last = chain[chain.count - 1]
            // Filtering shows every match, whatever was collapsed.
            let expanded = matches != nil || !collapsed.contains(last.id)
            let row = Row(chain: chain, depth: depth, hasChildren: !kids.isEmpty, isExpanded: expanded,
                          label: chain.count == 1 ? label(last, full: true) : chain.map { label($0, full: false) }.joined(separator: " › "),
                          detail: Self.detail(for: last)
                              ?? chain.reversed().lazy.compactMap { self.ownSourceTag(for: $0.id) }.first.map { "· \($0.label)" })
            out.append(row)
            width = max(width, Self.width(of: row))
            if expanded { kids.forEach { walk($0, depth: depth + 1) } }
        }
        rootIDs.forEach { walk($0, depth: 0) }
        rows = out
        outlineWidth = width
    }

    /// As written in the source (Source Views mode), else the runtime type.
    private func label(_ node: InspectorNode, full: Bool) -> String {
        sourceNames[node.id] ?? (full ? node.className : node.shortName)
    }

    static func detail(for node: InspectorNode) -> String? {
        if let vc = node.viewController { return "— \(vc)" }
        if let text = node.text, !text.isEmpty { return "“\(text)”" }
        if let id = node.accessibilityIdentifier { return "#\(id)" }
        return nil
    }

    private static func width(of row: Row) -> CGFloat {
        typealias M = OutlineMetrics
        func measure(_ s: String, _ font: NSFont) -> CGFloat {
            ceil((s as NSString).size(withAttributes: [.font: font]).width)
        }
        var w = CGFloat(row.depth) * M.indent + M.disclosure + M.spacing + M.icon + M.spacing
        w += min(measure(row.label, M.labelFont), M.maxLabelWidth)
        if let detail = row.detail { w += M.spacing + measure(detail, M.detailFont) }
        return w + M.trailing
    }

    /// The row showing `id` — with compact chains, possibly a middle link.
    func row(containing id: String?) -> Row? {
        guard let id else { return nil }
        return rows.first { $0.contains(id) }
    }

    private static func matches(_ node: InspectorNode, _ query: String) -> Bool {
        // The short name, not the generics: `TupleView<(…, Text)>` isn't a Text.
        node.shortName.lowercased().contains(query)
            || node.text?.lowercased().contains(query) == true
            || node.accessibilityIdentifier?.lowercased().contains(query) == true
            || node.viewController?.lowercased().contains(query) == true
    }

    func toggle(_ row: Row) {
        if collapsed.contains(row.id) { collapsed.remove(row.id) } else { collapsed.insert(row.id) }
        rebuildRows()
    }

    /// ⌥-click on a disclosure: expand / collapse the whole subtree.
    func toggleRecursively(_ row: Row) {
        let collapse = !collapsed.contains(row.id)
        var stack = [row.id]
        while let id = stack.popLast() {
            if collapse { collapsed.insert(id) } else { collapsed.remove(id) }
            stack += childrenOf[id] ?? []
        }
        rebuildRows()
    }

    func expandAll() { collapsed.removeAll(); rebuildRows() }

    func collapseAll() {
        collapsed = Set(childrenOf.keys)
        rebuildRows()
    }

    // MARK: - Selection

    /// The node the user clicked in the preview: the smallest visible frame
    /// under the point (deepest wins a tie), like Xcode's view debugger.
    func node(at point: CGPoint) -> InspectorNode? {
        var best: InspectorNode?
        var bestArea = CGFloat.greatestFiniteMagnitude
        for id in order {
            guard let node = nodes[id], !node.isHidden, node.alpha > 0.01,
                  node.frame.width > 0, node.frame.height > 0, node.frame.contains(point) else { continue }
            let area = node.frame.width * node.frame.height
            if area <= bestArea {
                best = node
                bestArea = area
            }
        }
        return best
    }

    /// Select from the preview: open the outline down to it.
    func reveal(_ id: String) {
        var cursor = parentOf[id]
        while let c = cursor {
            collapsed.remove(c)
            cursor = parentOf[c]
        }
        rebuildRows()
        selectedID = id
    }

    // MARK: - Source

    /// Modules whose types aren't the app's own code.
    private static let systemModules: Set<String> = [
        "SwiftUI", "SwiftUICore", "UIKit", "UIKitCore", "Swift", "Foundation", "CoreGraphics",
        "CoreFoundation", "Combine", "ObjectiveC", "QuartzCore", "_Concurrency", "__C", "Observation",
    ]

    /// The app's own types behind a node, nearest first. Ancestors that *are*
    /// app types (`Example.HomeRow`) come first; names that only appear as
    /// generic arguments come last — a `TupleView<(…)>` high up lists every
    /// screen it can show, which says little about this view.
    func sourceTypes(for id: String, limit: Int = 6) -> [String] {
        var own: [String] = []
        var mentioned: [String] = []
        var cursor: String? = id
        while let current = cursor {
            if let node = nodes[current] {
                let type = node.fullType ?? node.className
                if let name = Self.appType(of: type), !own.contains(name) { own.append(name) }
                if let vc = node.viewControllerType, let name = Self.appType(of: vc), !own.contains(name) {
                    own.append(name)
                }
                if mentioned.count < limit {
                    for name in node.appTypes ?? Self.appTypes(in: type) where !mentioned.contains(name) {
                        mentioned.append(name)
                    }
                }
            }
            cursor = parentOf[current]
        }
        let rest = mentioned.filter { !own.contains($0) }
        return Array((own + rest).prefix(limit))
    }

    /// Text to look for in code: the node's own, else the first `Text` /
    /// label inside it (a row's title), breadth-first.
    func sourceText(for id: String) -> String? {
        var queue = [id]
        var index = 0
        while index < queue.count, index < 400 {
            let current = queue[index]
            index += 1
            if let text = nodes[current]?.text?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty {
                return text
            }
            queue += childrenOf[current] ?? []
        }
        return nil
    }

    /// `Example.HomeRow<…>` → `HomeRow`: the node's own type, when it's app code.
    static func appType(of type: String) -> String? {
        let head = type.split(separator: "<", maxSplits: 1).first.map(String.init) ?? type
        let parts = head.split(separator: ".")
        guard parts.count >= 2, !systemModules.contains(String(parts[0])), !parts[0].hasPrefix("_"),
              !parts[1].hasPrefix("_"), parts[1].first?.isUppercase == true else { return nil }
        return String(parts[1])
    }

    /// `SwiftUI.ModifiedContent<Example.CardView, SwiftUI._PaddingLayout>` → ["CardView"].
    /// Takes the top-level type after a non-system module name.
    static func appTypes(in type: String) -> [String] {
        guard let regex = try? NSRegularExpression(pattern: "\\b([A-Za-z_][A-Za-z0-9_]*)\\.([A-Za-z_][A-Za-z0-9_]*)") else { return [] }
        var out: [String] = []
        let ns = type as NSString
        for m in regex.matches(in: type, range: NSRange(location: 0, length: ns.length)) {
            // Only the start of a qualified name: `A.B.C` yields A.B, never B.C.
            if m.range.location > 0, ns.character(at: m.range.location - 1) == 46 { continue }
            let module = ns.substring(with: m.range(at: 1))
            let name = ns.substring(with: m.range(at: 2))
            guard !systemModules.contains(module), !module.hasPrefix("_"), !name.hasPrefix("_"),
                  name.first?.isUppercase == true, !out.contains(name) else { continue }
            out.append(name)
        }
        return out
    }

    func openDeclaration(ofType name: String) {
        runSourceSearch(title: "Declarations of \(name)", notFound: "No declaration of \(name) in the repos open in MyGit.") {
            await $0.declarations(ofType: name)
        }
    }

    func openText(_ text: String) {
        // "Row %lld" is how SwiftUI keeps `Text("Row \(i)")`: look for the
        // literal's fixed start instead.
        let literal: String
        if let percent = text.firstIndex(of: "%") {
            literal = "\"" + text[..<percent]
        } else {
            literal = "\"\(text)\""
        }
        runSourceSearch(title: "“\(text)” in code", notFound: "“\(text)” doesn't appear as a string literal in the open repos.") {
            await $0.occurrences(ofLiteral: literal)
        }
    }

    /// Jump to a tagged view's line in the repo open in MyGit.
    func open(_ tag: InspectorSourceTag) {
        guard let navigator = sourceNavigator else {
            errorMessage = "Open the app's repository in MyGit to jump to its code."
            return
        }
        if !navigator.open(relativePath: tag.path, line: tag.line) {
            errorMessage = "\(tag.path) isn't in any repository open in MyGit."
        }
    }

    func open(_ hit: InspectorSourceHit) {
        sourceChoice = nil
        sourceNavigator?.open(hit)
    }

    private func runSourceSearch(title: String, notFound: String,
                                 _ search: @escaping (InspectorSourceNavigating) async -> [InspectorSourceHit]) {
        guard let navigator = sourceNavigator else {
            errorMessage = "Open the app's repository in MyGit to jump to its code."
            return
        }
        isSearchingSource = true
        Task {
            let hits = await search(navigator)
            isSearchingSource = false
            switch hits.count {
            case 0: errorMessage = notFound
            case 1: open(hits[0])
            default: sourceChoice = SourceChoice(title: title, hits: hits)
            }
        }
    }

    private func selectionChanged(from old: String?) {
        guard old != selectedID else { return }
        if selectedMeasure?.ownerID != selectedID { selectedMeasure = nil }
        sendHighlight()
    }

    private func sendHighlight() {
        guard let connection else { return }
        let node = highlightOnDevice ? selectedNode : nil
        let window = windowIndex
        Task {
            try? await connection.highlight(node.map { (frame: $0.frame, window: window) })
        }
    }
}
