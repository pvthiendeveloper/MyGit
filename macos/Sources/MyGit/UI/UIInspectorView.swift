import SwiftUI
import AppKit

/// Standalone window hosting the UI Inspector (View ▸ UI Inspector).
@MainActor
final class UIInspectorWindow: NSObject, NSWindowDelegate {
    private static var shared: UIInspectorWindow?
    private var window: NSWindow?
    private let viewModel = UIInspectorViewModel()

    static func open(sourceNavigator: InspectorSourceNavigating?) {
        if let existing = shared?.window {
            existing.makeKeyAndOrderFront(nil)
            return
        }
        let instance = UIInspectorWindow()
        instance.viewModel.sourceNavigator = sourceNavigator
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
                        .frame(minWidth: 240, idealWidth: 300, maxWidth: 420)
                }
            }
        }
        .frame(minWidth: 900, minHeight: 560)
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
        let types = vm.sourceTypes(for: node.id, limit: 8)
        let text = vm.sourceText(for: node.id)
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
            .disabled(vm.connected == nil || vm.isLoading)
            .help("Capture the current screen again (⌘R)")

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

            if vm.isLoading || vm.isSearchingSource { ProgressView().controlSize(.small) }
            if let error = vm.errorMessage, vm.snapshot != nil {
                Label(error, systemImage: "exclamationmark.triangle")
                    .foregroundStyle(.orange)
                    .lineLimit(1)
                    .help(error)
            }

            Toggle("Hide Modifiers", isOn: $vm.hideModifiers)
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
                }
            }
            Divider()
            HStack {
                breadcrumb
                Spacer()
                Image(systemName: "minus.magnifyingglass").foregroundStyle(.secondary)
                Slider(value: $zoom, in: 0.5...4)
                    .frame(width: 120)
                Image(systemName: "plus.magnifyingglass").foregroundStyle(.secondary)
                Button("Fit") { zoom = 1 }
                    .buttonStyle(.borderless)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
        }
        .background(Color(NSColor.underPageBackgroundColor))
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
                    context.fill(Path(r), with: .color(.accentColor.opacity(0.18)))
                    context.stroke(Path(r), with: .color(.accentColor), lineWidth: 1.5)
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
                vm.hoveredID = vm.node(at: CGPoint(x: location.x / scale, y: location.y / scale))?.id
            case .ended:
                vm.hoveredID = nil
            }
        }
        .onTapGesture { location in
            if let node = vm.node(at: CGPoint(x: location.x / scale, y: location.y / scale)) {
                vm.reveal(node.id)
            }
        }
        .contextMenu {
            if let node = vm.hoveredNode ?? vm.selectedNode {
                InspectorSourceMenu(node: node)
            }
        }
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

/// One Figma-style block: a title, then key/value rows whose values wrap
/// instead of being cut off.
private struct DetailSectionView: View {
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
                        Text(row.value)
                            .font(row.monospaced ? .system(size: 11, design: .monospaced) : .system(size: 12))
                            .textSelection(.enabled)
                            .fixedSize(horizontal: false, vertical: true)
                            .lineLimit(8)
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
