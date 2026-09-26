import SwiftUI
import AppKit

/// Standalone window hosting the UI Inspector (View ▸ UI Inspector).
@MainActor
final class UIInspectorWindow: NSObject, NSWindowDelegate {
    private static var shared: UIInspectorWindow?
    private var window: NSWindow?
    private let viewModel = UIInspectorViewModel()

    static func open(sourceNavigator: InspectorSourceNavigating?, runWithInspector: (() -> Void)? = nil,
                     ai: CommitMessageRepository? = nil, aiConfig: (() -> AIRequestConfig?)? = nil) {
        if let existing = shared?.window {
            existing.makeKeyAndOrderFront(nil)
            return
        }
        let instance = UIInspectorWindow()
        instance.viewModel.sourceNavigator = sourceNavigator
        instance.viewModel.runWithInspector = runWithInspector
        instance.viewModel.ai = ai
        instance.viewModel.aiConfig = aiConfig
        let hosting = NSHostingController(rootView: UIInspectorView().environmentObject(instance.viewModel))
        let win = NSWindow(contentViewController: hosting)
        win.title = "UI Inspector"
        win.styleMask = [.titled, .closable, .miniaturizable, .resizable]
        win.setContentSize(NSSize(width: 1280, height: 820))
        win.setFrameAutosaveName("MyGit.UIInspector")
        win.delegate = instance
        win.makeKeyAndOrderFront(nil)
        instance.window = win
        instance.viewModel.startBrowsing()
        shared = instance
    }

    func windowWillClose(_ notification: Notification) {
        viewModel.stopBrowsing()
        UIInspectorWindow.shared = nil
        window = nil
    }
}

/// Xcode-style view debugger for iOS apps running the MyGitInspector agent:
/// outline on the left, the screen in the middle, attributes on the right.
struct UIInspectorView: View {
    @EnvironmentObject var vm: UIInspectorViewModel

    var body: some View {
        VStack(spacing: 0) {
            InspectorToolbar()
            Divider()
            if vm.connected == nil {
                InspectorEmptyState()
            } else if vm.snapshot == nil {
                VStack(spacing: 8) {
                    if let error = vm.errorMessage {
                        Label(error, systemImage: "exclamationmark.triangle").foregroundStyle(.orange)
                    } else {
                        ProgressView()
                        Text("Capturing…").foregroundStyle(.secondary)
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                HSplitView {
                    InspectorOutline()
                        .frame(minWidth: 260, idealWidth: 380)
                    InspectorPreview()
                        .frame(minWidth: 300, maxWidth: .infinity)
                    InspectorAttributes()
                        .frame(minWidth: 480, idealWidth: 600, maxWidth: 840)
                }
            }
        }
        .frame(minWidth: 1100, minHeight: 560)
        .sheet(item: $vm.sourceChoice) { choice in
            SourcePickerSheet(choice: choice)
        }
    }
}

/// Context menu for a view: open the app's own types behind it, or find its text.
struct InspectorSourceMenu: View {
    @EnvironmentObject var vm: UIInspectorViewModel
    let node: InspectorNode

    var body: some View {
        let stack = vm.sourceStack(for: node.id)
        let types = vm.sourceTypes(for: node.id, limit: 8)
        let text = vm.sourceText(for: node.id)
        // Exact locations first, when the app was run with source tags.
        if let first = stack.first {
            Button("Open \(first.label)") { vm.open(first) }
            if stack.count > 1 {
                Menu("Enclosing Views") {
                    ForEach(stack.dropFirst()) { tag in
                        Button(tag.label) { vm.open(tag) }
                    }
                }
            }
            Divider()
        }
        // Text first: SwiftUI flattens custom views out of its debug data, so
        // a literal ("Accordion") usually leads straight to the code, while
        // type names come from generic lists that may name sibling screens.
        if let text {
            Button("Find “\(text.prefix(40))” in Code") { vm.openText(text) }
        }
        if !types.isEmpty {
            if text != nil { Divider() }
            Section("Open Type in Editor") {
                ForEach(types, id: \.self) { name in
                    Button(name) { vm.openDeclaration(ofType: name) }
                }
            }
        }
        if types.isEmpty && text == nil {
            Text("No app code found for this view")
        }
        Divider()
        Button("Copy Type Name") { copy(node.shortName) }
        if let full = node.fullType {
            Button("Copy Full Type") { copy(full) }
        }
    }

    private func copy(_ string: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(string, forType: .string)
    }
}

/// Several matches: pick the one to open.
private struct SourcePickerSheet: View {
    @EnvironmentObject var vm: UIInspectorViewModel
    @Environment(\.dismiss) private var dismiss
    let choice: UIInspectorViewModel.SourceChoice

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(choice.title).font(.headline)
            List(choice.hits) { hit in
                Button {
                    vm.open(hit)
                } label: {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("\((hit.path as NSString).lastPathComponent):\(hit.line)")
                            .font(.system(size: 12, weight: .medium))
                        Text(hit.preview)
                            .font(.system(size: 11, design: .monospaced))
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                        Text("\(hit.repoName) · \(hit.path)")
                            .font(.system(size: 10))
                            .foregroundStyle(.tertiary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
            .frame(minHeight: 220)
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
            }
        }
        .padding(16)
        .frame(width: 560, height: 380)
    }
}

// MARK: - Toolbar

private struct InspectorToolbar: View {
    @EnvironmentObject var vm: UIInspectorViewModel

    var body: some View {
        HStack(spacing: 10) {
            Menu {
                if vm.services.isEmpty {
                    Text("No apps found")
                }
                ForEach(vm.services) { service in
                    Button {
                        vm.connect(service)
                    } label: {
                        if vm.connected == service {
                            Label(service.name, systemImage: "checkmark")
                        } else {
                            Text(service.name)
                        }
                    }
                }
                if vm.connected != nil {
                    Divider()
                    Button("Disconnect") { vm.disconnect() }
                }
            } label: {
                Label(vm.connected?.name ?? "Choose App", systemImage: "iphone")
            }
            .fixedSize()

            Button {
                vm.refresh()
            } label: {
                Label("Capture", systemImage: "arrow.clockwise")
            }
            .keyboardShortcut("r", modifiers: .command)
            // Live captures on its own; the button would flicker with every refresh.
            .disabled(vm.connected == nil || vm.autoRefresh || vm.isLoading)
            .help(vm.autoRefresh ? "Live is on: the screen is captured continuously" : "Capture the current screen again (⌘R)")

            if let run = vm.runWithInspector {
                Button {
                    run()
                } label: {
                    Label("Run with Inspector", systemImage: "play.circle")
                }
                .help("Build and run the active repo with source tags, so every view opens its exact line")
            }

            Toggle("Live", isOn: $vm.autoRefresh)
                .toggleStyle(.checkbox)
                .disabled(vm.connected == nil)
                .help("Capture again every 1.5 seconds")

            if let windows = vm.snapshot?.windows, windows.count > 1 {
                Picker("Window", selection: $vm.windowIndex) {
                    ForEach(windows.indices, id: \.self) { i in
                        Text("\(windows[i].root.className)\(windows[i].isKey ? " (key)" : "")").tag(i)
                    }
                }
                .fixedSize()
            }

            Spacer()

            if vm.autoRefresh && vm.connected != nil {
                // Live captures back to back: a steady indicator, not a spinner that blinks per capture.
                LiveDot().help("Live — the screen is captured continuously")
                if vm.isSearchingSource { ProgressView().controlSize(.small) }
            } else if vm.isLoading || vm.isSearchingSource {
                ProgressView().controlSize(.small)
            }
            if let error = vm.errorMessage, vm.snapshot != nil {
                Label(error, systemImage: "exclamationmark.triangle")
                    .foregroundStyle(.orange)
                    .lineLimit(1)
                    .help(error)
            }

            Toggle("Spacing", isOn: $vm.measureMode)
                .toggleStyle(.checkbox)
                .help("Hover and click paddings, gaps between stack items and rounded corners in the preview to see their values and tokens (highlighted in pink)")
            Toggle("Source Views", isOn: $vm.sourceViewsOnly)
                .toggleStyle(.checkbox)
                .help("Only the views written in your code (named as written), text, and public UIKit views — SwiftUI plumbing and system controls' private parts are folded away. Needs Run with Inspector.")
            Toggle("Hide Modifiers", isOn: $vm.hideModifiers)
                .disabled(vm.sourceViewsOnly)
                .toggleStyle(.checkbox)
                .help("Fold SwiftUI modifiers (padding, accessibility, layout wrappers) into their content")
            Toggle("Compact Chains", isOn: $vm.compactChains)
                .toggleStyle(.checkbox)
                .help("Show runs of single-child views as one row (A › B › C), like Android Studio's Compact Middle Packages")
            Toggle("Wireframes", isOn: $vm.showWireframes)
                .toggleStyle(.checkbox)
            Toggle("Highlight on Device", isOn: $vm.highlightOnDevice)
                .toggleStyle(.checkbox)
                .help("Outline the selected view in the running app too")
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }
}

private struct InspectorEmptyState: View {
    @EnvironmentObject var vm: UIInspectorViewModel

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Label(vm.services.isEmpty ? "Looking for apps…" : "Choose an app to inspect",
                  systemImage: "iphone.and.arrow.forward")
                .font(.title3.weight(.semibold))
            if !vm.services.isEmpty {
                ForEach(vm.services) { service in
                    Button(service.name) { vm.connect(service) }
                }
            }
            if let run = vm.runWithInspector {
                Button {
                    run()
                } label: {
                    Label("Run Active Repo with Inspector", systemImage: "play.circle.fill")
                }
                .controlSize(.large)
                Text("Builds a source-tagged copy in .mygit/inspect so any view can open its exact line.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Text("Apps appear here once they run the MyGitInspector agent (Debug builds only):")
                .foregroundStyle(.secondary)
            Text("""
            1. Add the Swift package in MyGit's `ios-inspector/` folder to the app target.
            2. Call it as early as possible, e.g. in your App's init:

                   #if DEBUG
                   import MyGitInspector
                   #endif
                   …
                   init() {
                       #if DEBUG
                       MyGitInspector.start()
                       #endif
                   }

            3. Run the app on a Simulator. For a physical device on the same network, also add
               `NSBonjourServices` = [`_mygitinspect._tcp`] and `NSLocalNetworkUsageDescription`
               to the app's Info.plist.
            """)
            .font(.system(.body, design: .monospaced))
            .textSelection(.enabled)
            .padding(12)
            .background(RoundedRectangle(cornerRadius: 8).fill(Color(NSColor.textBackgroundColor)))
        }
        .padding(32)
        .frame(maxWidth: 720)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

// MARK: - Outline

private struct InspectorOutline: View {
    @EnvironmentObject var vm: UIInspectorViewModel

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 6) {
                Image(systemName: "line.3.horizontal.decrease").foregroundStyle(.secondary)
                TextField("Filter", text: $vm.filter).textFieldStyle(.plain)
                Menu {
                    Button("Expand All") { vm.expandAll() }
                    Button("Collapse All") { vm.collapseAll() }
                } label: {
                    Image(systemName: "ellipsis.circle")
                }
                .menuStyle(.borderlessButton)
                .fixedSize()
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 7)
            Divider()
            // Scrolls both ways: real apps nest a few hundred levels, so deep
            // rows sit thousands of points to the right. The content width is
            // measured up front (`outlineWidth`) — a lazy stack only sizes the
            // rows it has rendered, and would clip the rest.
            GeometryReader { geo in
                let width = max(geo.size.width, vm.outlineWidth)
                ScrollViewReader { proxy in
                    ScrollView([.horizontal, .vertical]) {
                        LazyVStack(alignment: .leading, spacing: 0) {
                            ForEach(vm.rows) { row in
                                OutlineRow(row: row, width: width)
                            }
                        }
                        .frame(width: width, alignment: .leading)
                    }
                    .focusable()
                    .focusEffectDisabled()
                    .onKeyPress(.upArrow) { moveSelection(-1); return .handled }
                    .onKeyPress(.downArrow) { moveSelection(1); return .handled }
                    .onKeyPress(.leftArrow) { setExpanded(false); return .handled }
                    .onKeyPress(.rightArrow) { setExpanded(true); return .handled }
                    .onChange(of: vm.selectedID) { _, id in
                        // The id sits on the row's content (after the indent),
                        // so this scrolls sideways to it as well.
                        guard let row = vm.row(containing: id) else { return }
                        withAnimation(.easeOut(duration: 0.15)) {
                            proxy.scrollTo(row.id, anchor: UnitPoint(x: 0.02, y: 0.5))
                        }
                    }
                }
            }
        }
    }

    private func moveSelection(_ delta: Int) {
        let rows = vm.rows
        guard !rows.isEmpty else { return }
        let current = rows.firstIndex { $0.contains(vm.selectedID) }
        let next = current.map { min(max($0 + delta, 0), rows.count - 1) } ?? 0
        vm.selectedID = rows[next].id
    }

    /// → opens the selected row (or steps into it); ← closes it (or steps to its parent).
    private func setExpanded(_ expand: Bool) {
        guard let index = vm.rows.firstIndex(where: { $0.contains(vm.selectedID) }) else { return }
        let row = vm.rows[index]
        if row.hasChildren, row.isExpanded != expand {
            vm.toggle(row)
        } else if expand, row.hasChildren, index + 1 < vm.rows.count {
            vm.selectedID = vm.rows[index + 1].id
        } else if !expand, let parent = vm.rows[..<index].last(where: { $0.depth < row.depth }) {
            vm.selectedID = parent.id
        }
    }
}

private struct OutlineRow: View {
    @EnvironmentObject var vm: UIInspectorViewModel
    let row: UIInspectorViewModel.Row
    /// Full content width, so the selection bar spans it.
    let width: CGFloat

    private typealias M = UIInspectorViewModel.OutlineMetrics

    var body: some View {
        let node = row.node
        let selected = row.contains(vm.selectedID)
        HStack(spacing: 0) {
            Color.clear.frame(width: CGFloat(row.depth) * M.indent)
            content(node)
                .id(row.id)
            Spacer(minLength: 0)
        }
        .frame(width: width, height: 20, alignment: .leading)
        .foregroundStyle(selected ? Color.white : Color.primary)
        .background(selected ? Color.accentColor : (row.contains(vm.hoveredID) ? Color.primary.opacity(0.06) : .clear))
        .contentShape(Rectangle())
        .onTapGesture {
            // A compacted row stands for its deepest link, unless the
            // selection is already one of its links (e.g. picked in the preview).
            if !row.contains(vm.selectedID) { vm.selectedID = node.id }
        }
        .help(row.chain.map { $0.fullType ?? $0.className }.joined(separator: "\n› "))
        .contextMenu {
            // A compacted row acts on its selected link, else its deepest one.
            InspectorSourceMenu(node: row.chain.first { $0.id == vm.selectedID } ?? node)
        }
        .onHover { inside in
            if inside { vm.hoveredID = node.id } else if vm.hoveredID == node.id { vm.hoveredID = nil }
        }
    }

    private func content(_ node: InspectorNode) -> some View {
        HStack(spacing: M.spacing) {
            Group {
                if row.hasChildren {
                    Image(systemName: row.isExpanded ? "chevron.down" : "chevron.right")
                        .font(.system(size: 9, weight: .semibold))
                        .opacity(0.6)
                        .contentShape(Rectangle())
                        .onTapGesture {
                            if NSEvent.modifierFlags.contains(.option) {
                                vm.toggleRecursively(row)
                            } else {
                                vm.toggle(row)
                            }
                        }
                } else {
                    Color.clear
                }
            }
            .frame(width: M.disclosure)
            Image(systemName: icon(for: node))
                .font(.system(size: 11))
                .foregroundStyle(tint(for: node))
                .frame(width: M.icon)
            // Width is measured by the view model; generic SwiftUI types can
            // run to thousands of characters, so very long ones are cut
            // (the full type is in the tooltip and the attributes panel).
            Text(row.label)
                .font(Font(M.labelFont))
                .lineLimit(1)
                .truncationMode(row.chain.count > 1 ? .middle : .tail)
                .frame(maxWidth: M.maxLabelWidth, alignment: .leading)
                .layoutPriority(1)
                .opacity(node.isHidden ? 0.45 : 1)
            if let detail = row.detail {
                Text(detail)
                    .font(Font(M.detailFont))
                    .opacity(0.65)
                    .lineLimit(1)
                    .fixedSize()
            }
        }
    }

    private func icon(for node: InspectorNode) -> String {
        if node.kind == .swiftui { return node.isModifier ? "slider.horizontal.3" : "swift" }
        if node.viewController != nil { return "rectangle.stack" }
        return "square.dashed"
    }

    private func tint(for node: InspectorNode) -> Color {
        if node.kind == .swiftui { return node.isModifier ? .purple : .orange }
        return node.viewController != nil ? .yellow : .blue
    }

}

// MARK: - Preview

private struct InspectorPreview: View {
    @EnvironmentObject var vm: UIInspectorViewModel
    @State private var zoom: CGFloat = 1
    /// Zoom when the current pinch began.
    @State private var pinchBase: CGFloat?
    @State private var pointerInside = false
    @State private var scrollMonitor: Any?
    /// For zooming around the pointer: the visible area, where it's scrolled
    /// to, and where the pointer is in it.
    @State private var viewport: CGSize = .zero
    @State private var scrollOffset: CGPoint = .zero
    @State private var pointer: CGPoint?
    @State private var position = ScrollPosition(point: .zero)
    private static let zoomRange: ClosedRange<CGFloat> = 0.5...4

    var body: some View {
        VStack(spacing: 0) {
            if let window = vm.currentWindow {
                GeometryReader { geo in
                    let fit = min((geo.size.width - 40) / max(window.size.width, 1),
                                  (geo.size.height - 40) / max(window.size.height, 1))
                    let scale = max(0.05, fit * zoom)
                    ScrollView([.horizontal, .vertical]) {
                        canvas(window, scale: scale)
                            .padding(20)
                            .frame(minWidth: geo.size.width, minHeight: geo.size.height)
                    }
                    .scrollPosition($position)
                    .onScrollGeometryChange(for: CGPoint.self, of: { $0.contentOffset }) { _, offset in
                        scrollOffset = offset
                    }
                    // Trackpad pinch, around where it started.
                    .simultaneousGesture(
                        MagnifyGesture()
                            .onChanged { value in
                                let base = pinchBase ?? zoom
                                pinchBase = base
                                setZoom(base * value.magnification, around: value.startLocation)
                            }
                            .onEnded { _ in pinchBase = nil }
                    )
                    .onHover { pointerInside = $0 }
                    .onContinuousHover { phase in
                        if case let .active(location) = phase { pointer = location } else { pointer = nil }
                    }
                    .onAppear { viewport = geo.size }
                    .onChange(of: geo.size) { _, size in viewport = size }
                }
            }
            Divider()
            HStack {
                breadcrumb
                Spacer()
                Image(systemName: "minus.magnifyingglass").foregroundStyle(.secondary)
                Slider(value: $zoom, in: Self.zoomRange)
                    .frame(width: 120)
                Image(systemName: "plus.magnifyingglass").foregroundStyle(.secondary)
                Button("Fit") { zoom = 1 }
                    .buttonStyle(.borderless)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
        }
        .background(Color(NSColor.underPageBackgroundColor))
        .onAppear { installScrollZoom() }
        .onDisappear {
            if let scrollMonitor { NSEvent.removeMonitor(scrollMonitor) }
            scrollMonitor = nil
        }
    }

    private static func clamp(_ z: CGFloat) -> CGFloat { min(max(z, zoomRange.lowerBound), zoomRange.upperBound) }

    /// Zoom so the point under `anchor` (viewport coordinates) stays under it.
    private func setZoom(_ requested: CGFloat, around anchor: CGPoint?) {
        let newZoom = Self.clamp(requested)
        guard let window = vm.currentWindow?.size, let anchor, viewport.width > 0 else { zoom = newZoom; return }
        let fit = min((viewport.width - 40) / max(window.width, 1), (viewport.height - 40) / max(window.height, 1))
        let oldScale = max(0.05, fit * zoom), newScale = max(0.05, fit * newZoom)
        // Where the canvas starts in the scroll content: padding, plus centering while it's smaller than the view.
        func origin(_ scale: CGFloat) -> CGPoint {
            CGPoint(x: max(0, (viewport.width - window.width * scale - 40) / 2) + 20,
                    y: max(0, (viewport.height - window.height * scale - 40) / 2) + 20)
        }
        let o0 = origin(oldScale), o1 = origin(newScale)
        let point = CGPoint(x: (scrollOffset.x + anchor.x - o0.x) / oldScale, y: (scrollOffset.y + anchor.y - o0.y) / oldScale)
        let content = CGSize(width: max(viewport.width, window.width * newScale + 40),
                             height: max(viewport.height, window.height * newScale + 40))
        let target = CGPoint(
            x: min(max(0, o1.x + point.x * newScale - anchor.x), content.width - viewport.width),
            y: min(max(0, o1.y + point.y * newScale - anchor.y), content.height - viewport.height))
        zoom = newZoom
        // After the content has grown to the new size.
        DispatchQueue.main.async { position.scrollTo(point: target) }
    }

    /// ⌘ + scroll (wheel, or two fingers on a trackpad) over the preview zooms;
    /// SwiftUI doesn't expose scroll events with modifiers, so an AppKit monitor.
    private func installScrollZoom() {
        guard scrollMonitor == nil else { return }
        scrollMonitor = NSEvent.addLocalMonitorForEvents(matching: .scrollWheel) { event in
            guard pointerInside, event.modifierFlags.contains(.command) else { return event }
            let delta = event.hasPreciseScrollingDeltas ? event.scrollingDeltaY / 200 : event.scrollingDeltaY / 20
            guard delta != 0 else { return nil }
            setZoom(zoom * (1 + delta), around: pointer)
            return nil   // Consumed: don't also scroll the canvas.
        }
    }

    private func canvas(_ window: InspectorWindow, scale: CGFloat) -> some View {
        let size = CGSize(width: window.size.width * scale, height: window.size.height * scale)
        return ZStack(alignment: .topLeading) {
            if let image = window.image {
                Image(nsImage: image)
                    .resizable()
                    .interpolation(.high)
                    .frame(width: size.width, height: size.height)
            } else {
                Rectangle().fill(Color.gray.opacity(0.2))
            }
            Canvas { context, _ in
                func rect(_ f: CGRect) -> CGRect {
                    CGRect(x: f.minX * scale, y: f.minY * scale, width: f.width * scale, height: f.height * scale)
                }
                if vm.showWireframes {
                    for node in vm.wireframeNodes {
                        context.stroke(Path(rect(node.frame)), with: .color(.gray.opacity(0.35)), lineWidth: 0.5)
                    }
                }
                if let hovered = vm.hoveredNode, hovered.id != vm.selectedID {
                    context.stroke(Path(rect(hovered.frame)), with: .color(.orange), lineWidth: 1)
                }
                if let selected = vm.selectedNode {
                    let r = rect(selected.frame)
                    context.fill(Path(r), with: .color(.accentColor.opacity(vm.selectedMeasure == nil ? 0.18 : 0.06)))
                    context.stroke(Path(r), with: .color(.accentColor), lineWidth: vm.selectedMeasure == nil ? 1.5 : 0.75)
                }
                // Measures: pink, so they never read as a view.
                if let picked = vm.selectedMeasure {
                    drawMeasure(picked, in: &context, rect: rect(picked.rect), strong: true, scale: scale, canvas: size)
                }
                if let hovered = vm.hoveredMeasure, hovered.id != vm.selectedMeasure?.id {
                    drawMeasure(hovered, in: &context, rect: rect(hovered.rect), strong: false, scale: scale, canvas: size)
                }
            }
            .frame(width: size.width, height: size.height)
            .allowsHitTesting(false)
        }
        .frame(width: size.width, height: size.height)
        .overlay(RoundedRectangle(cornerRadius: 2).stroke(Color.primary.opacity(0.15)))
        .contentShape(Rectangle())
        .onContinuousHover { phase in
            switch phase {
            case let .active(location):
                let point = CGPoint(x: location.x / scale, y: location.y / scale)
                // Also the zoom anchor, in the scroll view's coordinates.
                pointer = CGPoint(x: max(0, (viewport.width - size.width - 40) / 2) + 20 + location.x - scrollOffset.x,
                                  y: max(0, (viewport.height - size.height - 40) / 2) + 20 + location.y - scrollOffset.y)
                let measure = vm.measureMode ? vm.measure(at: point) : nil
                vm.hoveredMeasureID = measure?.id
                vm.hoveredID = measure == nil ? vm.node(at: point)?.id : nil
            case .ended:
                vm.hoveredID = nil
                vm.hoveredMeasureID = nil
            }
        }
        .onTapGesture { location in
            let point = CGPoint(x: location.x / scale, y: location.y / scale)
            if vm.measureMode, let measure = vm.measure(at: point) {
                vm.select(measure)
            } else if let node = vm.node(at: point) {
                vm.reveal(node.id)
            }
        }
        .contextMenu {
            if let node = vm.hoveredNode ?? vm.selectedNode {
                InspectorSourceMenu(node: node)
            }
        }
    }

    /// A measure's region, filled pink, with its value in a pill; the token
    /// behind it goes in a second pill outside the highlighted view, so it
    /// never covers what's being inspected.
    private func drawMeasure(_ m: InspectorMeasure, in context: inout GraphicsContext, rect r: CGRect,
                             strong: Bool, scale: CGFloat, canvas: CGSize) {
        let pink = Color(red: 0.93, green: 0.2, blue: 0.55)
        context.fill(Path(r), with: .color(pink.opacity(strong ? 0.45 : 0.3)))
        context.stroke(Path(r), with: .color(pink), lineWidth: strong ? 1.5 : 1)

        func pill(_ text: String, centeredAt center: CGPoint) -> CGRect {
            let label = context.resolve(Text(text)
                .font(.system(size: 10, weight: .semibold, design: .rounded))
                .foregroundColor(.white))
            let size = label.measure(in: CGSize(width: 600, height: 40))
            let box = CGRect(x: center.x - size.width / 2 - 4, y: center.y - size.height / 2 - 1,
                             width: size.width + 8, height: size.height + 2)
            context.fill(Path(roundedRect: box, cornerRadius: box.height / 2), with: .color(pink))
            context.draw(label, at: CGPoint(x: box.midX, y: box.midY))
            return box
        }
        let valuePill = pill(UIInspectorViewModel.fmt(m.value), centeredAt: CGPoint(x: r.midX, y: r.midY))

        guard let token = vm.measureTokenNames[m.id], !token.isEmpty else { return }
        // Clear of the view the measure belongs to and of the hovered/selected views.
        var avoid = r
        for id in [m.ownerID, vm.selectedID, vm.hoveredID].compactMap({ $0 }) {
            if let f = vm.rawNode(id)?.frame {
                avoid = avoid.union(CGRect(x: f.minX * scale, y: f.minY * scale, width: f.width * scale, height: f.height * scale))
            }
        }
        let label = context.resolve(Text(token)
            .font(.system(size: 10, weight: .semibold, design: .rounded))
            .foregroundColor(.white))
        let size = label.measure(in: CGSize(width: 600, height: 40))
        let height = size.height + 2
        let below = avoid.maxY + 6 + height / 2
        let y = below + height / 2 <= canvas.height ? below : max(height / 2, avoid.minY - 6 - height / 2)
        let halfWidth = size.width / 2 + 4
        let x = min(max(r.midX, halfWidth), max(halfWidth, canvas.width - halfWidth))
        let tokenPill = pill(token, centeredAt: CGPoint(x: x, y: y))
        // Leader from the value to its token.
        var leader = Path()
        leader.move(to: CGPoint(x: valuePill.midX, y: y > valuePill.midY ? valuePill.maxY : valuePill.minY))
        leader.addLine(to: CGPoint(x: tokenPill.midX, y: y > valuePill.midY ? tokenPill.minY : tokenPill.maxY))
        context.stroke(leader, with: .color(pink.opacity(0.8)), style: StrokeStyle(lineWidth: 1, dash: [2, 2]))
    }

    private var breadcrumb: some View {
        let path = vm.selectionPath.suffix(4)
        return HStack(spacing: 4) {
            if vm.selectionPath.count > 4 { Text("…").foregroundStyle(.secondary) }
            ForEach(Array(path.enumerated()), id: \.element.id) { index, node in
                if index > 0 { Image(systemName: "chevron.right").font(.system(size: 8)).foregroundStyle(.secondary) }
                Button(node.shortName) { vm.selectedID = node.id }
                    .buttonStyle(.borderless)
                    .font(.system(size: 11))
                    .lineLimit(1)
            }
        }
    }
}

// MARK: - Attributes

private struct InspectorAttributes: View {
    @EnvironmentObject var vm: UIInspectorViewModel

    var body: some View {
        if let node = vm.selectedNode {
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    if let measure = vm.selectedMeasure, measure.ownerID == node.id {
                        DetailSectionView(section: vm.measureSection(measure))
                    }
                    SourceStackView(stack: vm.sourceStack(for: node.id))
                    ForEach(vm.detailSections(for: node.id)) { section in
                        DetailSectionView(section: section)
                    }
                }
                .padding(12)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        } else {
            Text("Select a view in the outline or click it in the preview.")
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)
                .padding()
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }
}

/// Where the view is written: the nearest tag on one line, the views around
/// it folded under "Enclosing". Without tags, a one-line hint.
private struct SourceStackView: View {
    @EnvironmentObject var vm: UIInspectorViewModel
    let stack: [InspectorSourceTag]
    @AppStorage("MyGit.inspector.sourceExpanded") private var expanded = false

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                Text("Source")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.secondary)
                if let first = stack.first {
                    row(first, primary: true)
                } else {
                    Text("Run with Inspector for exact lines")
                        .font(.system(size: 11))
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                        .truncationMode(.tail)
                        .help("Pick “App with Inspector” in the Run configurations (or use Run with Inspector above): the app is built with source tags, so any view opens the line that creates it.")
                }
            }
            if stack.count > 1 {
                DisclosureGroup(isExpanded: $expanded) {
                    VStack(alignment: .leading, spacing: 2) {
                        ForEach(stack.dropFirst()) { tag in row(tag, primary: false) }
                    }
                    .padding(.top, 2)
                } label: {
                    Text("Enclosing (\(stack.count - 1))")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }
                .padding(.leading, 2)
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 8).fill(Color.accentColor.opacity(stack.isEmpty ? 0.04 : 0.08)))
    }

    /// `HomeView.swift:132` on a single line; the full path is the tooltip.
    private func row(_ tag: InspectorSourceTag, primary: Bool) -> some View {
        Button {
            vm.open(tag)
        } label: {
            HStack(spacing: 4) {
                if primary {
                    Image(systemName: "arrow.right.circle.fill")
                        .font(.system(size: 11))
                        .foregroundStyle(Color.accentColor)
                }
                Text(tag.label)
                    .font(.system(size: 11, weight: primary ? .semibold : .regular, design: .monospaced))
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer(minLength: 0)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help("Open \(tag.path):\(tag.line):\(tag.column)")
    }
}

/// A value's design token: the root (`patternGapGroupTextToGroupText = 4`,
/// click to open its declaration) — or the possible roots of a branching
/// function — and, below, how the code got there.
private struct TokenView: View {
    @EnvironmentObject var vm: UIInspectorViewModel
    let token: String
    let row: InspectorDetailSection.Row
    @State private var resolution: InspectorTokenResolution?
    /// What the code alone resolved, before an AI pick (to undo it).
    @State private var base: InspectorTokenResolution?
    @State private var picking = false
    @State private var pickError: String?

    /// What the resolution depends on; a new selection re-resolves.
    private var key: String {
        "\(token)|\(row.tokenStack.map(\.id).joined(separator: ","))|\(row.tokenValue ?? "")|"
            + row.tokenStack.map { $0.traces.sorted { $0.key < $1.key }.map { "\($0.key)=\($0.value.value)\($0.value.branches)" }
                .joined(separator: ";") }.joined(separator: ",")
    }

    var body: some View {
        content
            .task(id: key) {
                pickError = nil
                // The compiler's index when the app was run with the
                // inspector; the by-name match otherwise.
                base = await vm.resolveTokenExactly(token, refs: row.tokenRefs, binding: row.tokenBinding, probe: row.tokenProbe,
                                                    stack: row.tokenStack, runtimeValue: row.tokenValue)
                    ?? vm.resolveToken(token, stack: row.tokenStack, runtimeValue: row.tokenValue)
                resolution = vm.aiPicks[key] ?? base
            }
    }

    /// The runtime record of this argument on the selected view instance.
    private var evaluated: String? {
        guard let probe = row.tokenProbe, let value = row.tokenStack.first?.traces[probe]?.value, !value.isEmpty else {
            return nil
        }
        return value
    }

    private var aiPick: (confidence: Double, reason: String)? {
        if case let .ai(confidence, reason)? = resolution?.pickedBy { return (confidence, reason) }
        return nil
    }

    private var content: some View {
        VStack(alignment: .leading, spacing: 1) {
            if let chain = resolution?.chain {
                rootButton(chain.root, prefix: "◆ ")
                if aiPick != nil, let others = resolution?.alternatives.filter({ $0.path != chain.root.path || $0.line != chain.root.line }),
                   !others.isEmpty {
                    Text("  other candidates")
                        .font(.system(size: 9.5, design: .monospaced))
                        .foregroundStyle(.secondary)
                    ForEach(Array(others.enumerated()), id: \.offset) { _, root in
                        rootButton(root, prefix: "  • ").opacity(0.55)
                    }
                }
            } else if let alternatives = resolution?.alternatives, !alternatives.isEmpty {
                HStack(spacing: 6) {
                    Text("◆ one of")
                        .font(.system(size: 10.5, weight: .semibold, design: .monospaced))
                        .foregroundStyle(Color.accentColor)
                    if vm.canPickWithAI { pickButton }
                }
                ForEach(Array(alternatives.enumerated()), id: \.offset) { _, root in
                    rootButton(root, prefix: "  • ")
                }
                if let pickError {
                    Text(pickError)
                        .font(.system(size: 9.5))
                        .foregroundStyle(.red)
                        .fixedSize(horizontal: false, vertical: true)
                        .textSelection(.enabled)
                }
            } else {
                Text("◆ " + (resolution?.steps.last.map(Self.lastExpression) ?? token))
                    .font(.system(size: 10.5, design: .monospaced))
                    .foregroundStyle(Color.accentColor)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
                    .lineLimit(4)
            }
            if let evaluated {
                // What this view's argument actually evaluated to — for content
                // (`Text(message)`) the root above is code, this is the value.
                Text("= " + evaluated)
                    .font(.system(size: 10.5, design: .monospaced))
                    .foregroundStyle(.primary)
                    .fixedSize(horizontal: false, vertical: true)
                    .lineLimit(3)
                    .textSelection(.enabled)
                    .help("Recorded by the running app (Run with Inspector) when it evaluated this argument.")
            }
            if let via = viaDescription, !via.isEmpty {
                Text("via " + via)
                    .font(.system(size: 9.5, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .lineLimit(4)
                    .textSelection(.enabled)
            }
            if let resolution, resolution.chain != nil || !resolution.alternatives.isEmpty {
                basisLabel(resolution)
            }
        }
    }

    /// How sure: the compiler's own binding, a name match, and what picked
    /// among several roots (the screen value, the app's report, or AI).
    @ViewBuilder
    private func basisLabel(_ resolution: InspectorTokenResolution) -> some View {
        switch resolution.pickedBy {
        case .screenValue?:
            Text("✓ the only branch that can show this value")
                .font(.system(size: 9))
                .foregroundStyle(Color.green.opacity(0.8))
                .help("The other branches were ruled out: they can't produce the value on screen (nil, a different literal, or a template that doesn't fit).")
        case .traced?:
            Text("✓ traced in the running app")
                .font(.system(size: 9))
                .foregroundStyle(Color.green.opacity(0.8))
                .help("Run with Inspector recorded this view's own evaluation of the argument, including which return statements it went through.")
        case .runtimeBranch?:
            Text("✓ branch reported by the running app")
                .font(.system(size: 9))
                .foregroundStyle(Color.green.opacity(0.8))
                .help("Run with Inspector instruments multi-return getters; the app recorded which return produced this value.")
        case let .ai(confidence, reason)?:
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text("✨ AI pick · \(Int((confidence * 100).rounded()))%" + (reason.isEmpty ? "" : " — \(reason)"))
                    .font(.system(size: 9))
                    .foregroundStyle(Color.purple)
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)
                Button("Undo") {
                    vm.aiPicks[key] = nil
                    self.resolution = base
                }
                .buttonStyle(.link)
                .font(.system(size: 9))
            }
            .help("A language model read the code around each branch and what's on screen. It's a suggestion, not proof — Run with Inspector records the real branch.")
        case nil:
            Text(resolution.exact ? "✓ compiler index" : "≈ matched by name")
                .font(.system(size: 9))
                .foregroundStyle(resolution.exact ? Color.green.opacity(0.8) : Color.orange.opacity(0.8))
                .help(resolution.exact
                      ? "Every step was resolved by the compiler (index store of the Run with Inspector build) and the runtime tag stack."
                      : "No inspector build index for this repo: definitions were matched by name, owner and on-screen value, which can be wrong when names repeat.")
        }
    }

    private var pickButton: some View {
        Button {
            guard let resolution, !picking else { return }
            picking = true
            pickError = nil
            let key = self.key
            Task {
                defer { picking = false }
                do {
                    let picked = try await vm.pickWithAI(token: token, resolution: resolution, stack: row.tokenStack,
                                                         runtimeValue: row.tokenValue, key: key)
                    if key == self.key { self.resolution = picked }
                } catch {
                    pickError = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
                }
            }
        } label: {
            HStack(spacing: 3) {
                if picking {
                    ProgressView().controlSize(.mini)
                } else {
                    Image(systemName: "sparkles")
                }
                Text(picking ? "Reading…" : "Pick")
            }
            .font(.system(size: 9.5, weight: .medium))
            .padding(.horizontal, 5)
            .padding(.vertical, 1)
            .background(Color.purple.opacity(0.15), in: Capsule())
            .foregroundStyle(Color.purple)
        }
        .buttonStyle(.plain)
        .help("Ask the AI provider (Settings ▸ AI) which branch produced this value, from the code and what's on screen.")
    }

    private func rootButton(_ root: InspectorSymbol, prefix: String) -> some View {
        Button {
            _ = vm.sourceNavigator?.open(relativePath: root.path, line: root.line)
        } label: {
            // Name first: it's the design token; long values (gradients) are cut.
            Text(prefix + root.name + (root.literal.map { " = \($0)" } ?? ""))
                .font(.system(size: 10.5, weight: .semibold, design: .monospaced))
                .foregroundStyle(Color.accentColor)
                .lineLimit(3)
                .truncationMode(.tail)
                .fixedSize(horizontal: false, vertical: true)
                .multilineTextAlignment(.leading)
        }
        .buttonStyle(.plain)
        .help("Open \((root.path as NSString).lastPathComponent):\(root.line)")
    }

    /// `style → labelText(style:) tokenProvider.restingLabelTextStyle →
    /// SwiftUIInputTokenProviding.restingLabelTextStyle`
    private var viaDescription: String? {
        guard let resolution else { return nil }
        var parts = resolution.steps
        if let chain = resolution.chain {
            parts += chain.hops.dropLast().map { ($0.owner.map { "\($0)." } ?? "") + $0.name }
        }
        // Nothing learned beyond the token itself.
        if parts.count <= 1, resolution.chain?.hops.count ?? 0 <= 1, resolution.alternatives.isEmpty { return nil }
        return parts.joined(separator: " → ")
    }

    /// "labelText(style:) tokenProvider.x" → "tokenProvider.x".
    private static func lastExpression(_ step: String) -> String {
        guard let space = step.firstIndex(of: " "), step.hasPrefix(step[..<space]), step[..<space].hasSuffix(":)") else {
            return step
        }
        return String(step[step.index(after: space)...])
    }
}

/// One Figma-style block: a title, then key/value rows whose values wrap
/// instead of being cut off.
private struct DetailSectionView: View {
    @EnvironmentObject var vm: UIInspectorViewModel
    let section: InspectorDetailSection

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(section.title)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.secondary)
                .textCase(nil)
            if section.rows.isEmpty {
                Text("No properties reported")
                    .font(.system(size: 11))
                    .foregroundStyle(.tertiary)
            }
            ForEach(section.rows) { row in
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text(row.key)
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .frame(width: 96, alignment: .leading)
                        .lineLimit(2)
                    HStack(spacing: 6) {
                        if let color = Self.color(in: row.value) {
                            RoundedRectangle(cornerRadius: 3)
                                .fill(Color(nsColor: color))
                                .frame(width: 12, height: 12)
                                .overlay(RoundedRectangle(cornerRadius: 3).stroke(Color.primary.opacity(0.2)))
                        }
                        VStack(alignment: .leading, spacing: 2) {
                            if !row.value.isEmpty {
                                Text(row.value)
                                    .font(row.monospaced ? .system(size: 11, design: .monospaced) : .system(size: 12))
                                    .textSelection(.enabled)
                                    .fixedSize(horizontal: false, vertical: true)
                                    .lineLimit(8)
                            }
                            if let token = row.token {
                                TokenView(token: token, row: row)
                            }
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 8).fill(Color.primary.opacity(0.04)))
    }

    /// `#RRGGBBAA` (UIKit backgrounds) → a swatch.
    static func color(in value: String) -> NSColor? {
        guard value.hasPrefix("#") else { return nil }
        let s = String(value.dropFirst())
        guard s.count == 8, let v = UInt32(s, radix: 16) else { return nil }
        return NSColor(srgbRed: CGFloat(v >> 24 & 0xFF) / 255, green: CGFloat(v >> 16 & 0xFF) / 255,
                       blue: CGFloat(v >> 8 & 0xFF) / 255, alpha: CGFloat(v & 0xFF) / 255)
    }
}

/// A live-stream style "on air" dot: a green dot that breathes, with a soft
/// ring swelling out of it.
private struct LiveDot: View {
    @State private var breathing = false
    @State private var ring = false

    var body: some View {
        ZStack {
            Circle()
                .fill(Color.green.opacity(0.45))
                .scaleEffect(ring ? 2.4 : 1)
                .opacity(ring ? 0 : 0.8)
            Circle()
                .fill(Color.green)
                .opacity(breathing ? 0.55 : 1)
        }
        .frame(width: 8, height: 8)
        .frame(width: 20, height: 20)
        .onAppear {
            withAnimation(.easeOut(duration: 1.6).repeatForever(autoreverses: false)) { ring = true }
            withAnimation(.easeInOut(duration: 0.8).repeatForever(autoreverses: true)) { breathing = true }
        }
        .accessibilityLabel("Live")
    }
}
