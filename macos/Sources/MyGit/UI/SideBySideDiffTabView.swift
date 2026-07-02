import SwiftUI
import AppKit

struct SideBySideDiffTabView: View {
    let tab: DiffTab
    @EnvironmentObject var coordinator: AppCoordinator
    @EnvironmentObject var main: MainViewModel

    @State private var sourceText: String = ""
    @State private var workingText: String = ""
    @State private var diskText: String = ""
    @State private var hunks: [LineHunk] = []
    @State private var loading: Bool = true
    @State private var loadError: String? = nil
    @State private var applyingHunk: Bool = false

    @State private var viewerMode: DiffViewerMode = .sideBySide
    @State private var whitespaceMode: DiffWhitespaceMode = .doNotIgnore
    @State private var highlightMode: DiffHighlightMode = .lines
    @State private var syncScroll: Bool = true
    @State private var fontSize: CGFloat = 12
    @State private var showSettings: Bool = false
    @State private var showHelp: Bool = false
    @State private var currentHunkIndex: Int = -1
    @State private var excludedHunks: Set<Int> = []
    @State private var useCurrentVersion: Bool = false

    // Syntax highlighting: full-file colors sliced per line (left = source, right =
    // working). Recomputed only when the texts change (not on every keystroke).
    @State private var syntaxOn: Bool = true
    @State private var leftSyntax: [AttributedString] = []
    @State private var rightSyntax: [AttributedString] = []
    private var fileExt: String { (tab.path as NSString).pathExtension }

    // Editable pane's text view + undo manager, so applies join the native undo stack.
    @StateObject private var editor = DiffEditorHandle()

    // Aligned rows + per-hunk anchor rows, rebuilt with the hunks. Prev/Next resolve
    // against these relative to where the user is (caret when editable, else scroll).
    @State private var rows: [AlignedDiffRow] = []
    @State private var hunkAnchors: [HunkAnchor] = []

    struct HunkAnchor { let rowId: Int; let hunkIndex: Int }

    // Transient flash on the hunk Prev/Next just landed on, so the user sees where the
    // jump took them. Set strong, then animate back to 0.
    @State private var flashHunkId: Int? = nil
    @State private var flashOpacity: Double = 0

    // Side-by-side vertical-scroll sync. The column under the pointer drives;
    // the others follow its Y offset. Horizontal scroll stays per-pane.
    @State private var syncY: CGFloat = 0
    @State private var syncX: CGFloat = 0
    @State private var activeCol: Int = 0
    @State private var leftScroll = ScrollPosition()
    @State private var rightScroll = ScrollPosition()
    @State private var gutterScroll = ScrollPosition()

    // Right pane is editable whenever it shows the live working-tree file: the
    // working modes, or commitVsParent once "Current version" swaps the right side
    // to the on-disk file.
    private var isRightEditable: Bool {
        tab.mode.rightIsEditable || (tab.mode == .commitVsParent && useCurrentVersion)
    }
    private var isDirty: Bool { isRightEditable && workingText != diskText }

    var body: some View {
        VStack(spacing: 0) {
            toolbar
            Divider()
            secondaryHeader
            Divider()
            if loading {
                ProgressView()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if let loadError {
                VStack(spacing: 8) {
                    Image(systemName: "exclamationmark.triangle")
                        .font(.title2)
                        .foregroundStyle(.orange)
                    Text(loadError).foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                contentForViewer
            }
        }
        .background(Color(NSColor.textBackgroundColor))
        .task(id: tab.id) { await load() }
        .onChange(of: workingText) { _, _ in
            if !applyingHunk { recomputeHunks() }
        }
        .onChange(of: whitespaceMode) { _, _ in recomputeHunks() }
        .onChange(of: useCurrentVersion) { _, _ in
            Task { await reloadForCurrentVersionToggle() }
        }
        .onChange(of: syntaxOn) { _, _ in recomputeSyntax() }
    }

    // MARK: - Secondary header (commit info + Current version)

    private var secondaryHeader: some View {
        HStack(spacing: 0) {
            sideLabel(leftSideLabel, editable: false)
                .frame(maxWidth: .infinity, alignment: .leading)
            Spacer().frame(width: Self.gutterColWidth)
            sideLabel(rightSideLabel, editable: isRightEditable)
                .frame(maxWidth: .infinity, alignment: .leading)
            if tab.mode == .commitVsParent {
                Toggle(isOn: $useCurrentVersion) {
                    Text("Current version").font(.system(size: 11))
                }
                .toggleStyle(.checkbox)
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 4)
        .background(Color(NSColor.windowBackgroundColor).opacity(0.6))
    }

    // Left pane = source, right pane = working. The working side is "Current"
    // whenever it reflects the live file on disk (or the Current-version toggle).
    private var leftSideLabel: String {
        switch tab.mode {
        case .commitVsWorking: return tab.commitShortHash
        case .commitVsParent, .parentVsWorking: return "\(tab.commitShortHash)^"
        }
    }

    private var rightSideLabel: String {
        switch tab.mode {
        case .commitVsWorking, .parentVsWorking: return "Current"
        case .commitVsParent: return useCurrentVersion ? "Current" : tab.commitShortHash
        }
    }

    private func sideLabel(_ text: String, editable: Bool) -> some View {
        HStack(spacing: 6) {
            Image(systemName: editable ? "pencil" : "lock")
                .font(.system(size: 10))
                .foregroundStyle(.secondary)
            Text(text)
                .font(.system(size: 11, design: .monospaced))
                .foregroundStyle(.primary)
            Text(tab.path)
                .font(.system(size: 10, design: .monospaced))
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.middle)
        }
    }

    // MARK: - Toolbar

    private var toolbar: some View {
        HStack(spacing: 6) {
            toolbarButton(systemName: "arrow.up", help: "Previous change", enabled: canPrevHunk) {
                jumpHunk(delta: -1)
            }
            toolbarButton(systemName: "arrow.down", help: "Next change", enabled: canNextHunk) {
                jumpHunk(delta: 1)
            }
            toolbarButton(systemName: "pencil", help: "Edit file in editor", enabled: true) {
                editSource()
            }
            Divider().frame(height: 14)
            toolbarButton(systemName: "arrowshape.turn.up.backward", help: "Back tab", enabled: main.canNavigateBackTab) {
                main.navigateBackTab()
            }
            toolbarButton(systemName: "arrowshape.turn.up.forward", help: "Forward tab", enabled: main.canNavigateForwardTab) {
                main.navigateForwardTab()
            }
            if isRightEditable {
                Divider().frame(height: 14)
                toolbarButton(systemName: "arrow.uturn.backward", help: "Undo (⌘Z)", enabled: editor.canUndo) {
                    editor.undo()
                }
                .keyboardShortcut("z", modifiers: [.command])
                toolbarButton(systemName: "arrow.uturn.forward", help: "Redo (⇧⌘Z)", enabled: editor.canRedo) {
                    editor.redo()
                }
                .keyboardShortcut("z", modifiers: [.command, .shift])
            }
            Divider().frame(height: 14)
            viewerModeMenu
            whitespaceMenu
            highlightMenu
            toolbarButton(systemName: "xmark", help: "Disable highlighting", enabled: highlightMode != .none) {
                highlightMode = .none
            }
            toolbarToggle(systemName: "paintbrush", help: "Syntax highlighting", isOn: $syntaxOn)
            toolbarToggle(systemName: "arrow.up.arrow.down.square", help: "Synchronize scrolling", isOn: $syncScroll)
            toolbarButton(systemName: "gearshape", help: "Diff settings", enabled: true) {
                showSettings.toggle()
            }
            .popover(isPresented: $showSettings, arrowEdge: .bottom) { settingsPopover }
            toolbarButton(systemName: "questionmark.circle", help: "Help", enabled: true) {
                showHelp.toggle()
            }
            .popover(isPresented: $showHelp, arrowEdge: .bottom) { helpPopover }
            Spacer()
            if isDirty {
                Button("Revert") { workingText = diskText; recomputeHunks() }
                    .controlSize(.small)
                Button("Save") { save() }
                    .controlSize(.small)
                    .keyboardShortcut("s", modifiers: [.command])
                    .buttonStyle(.borderedProminent)
                Divider().frame(height: 14)
            }
            Text(statsLabel)
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(Color(NSColor.windowBackgroundColor).opacity(0.7))
    }

    private func toolbarButton(systemName: String, help: String, enabled: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(.system(size: 12))
                .frame(width: 22, height: 22)
                .foregroundStyle(enabled ? Color.primary : Color.secondary.opacity(0.5))
        }
        .buttonStyle(.borderless)
        .disabled(!enabled)
        .help(help)
    }

    private func toolbarToggle(systemName: String, help: String, isOn: Binding<Bool>) -> some View {
        Button { isOn.wrappedValue.toggle() } label: {
            Image(systemName: systemName)
                .font(.system(size: 12))
                .frame(width: 22, height: 22)
                .foregroundStyle(isOn.wrappedValue ? Color.accentColor : Color.primary)
                .background(isOn.wrappedValue ? Color.accentColor.opacity(0.15) : Color.clear)
                .clipShape(RoundedRectangle(cornerRadius: 4))
        }
        .buttonStyle(.borderless)
        .help(help)
    }

    private var viewerModeMenu: some View {
        Menu {
            ForEach(DiffViewerMode.allCases, id: \.self) { mode in
                Button {
                    viewerMode = mode
                } label: {
                    if mode == viewerMode {
                        Label(mode.label, systemImage: "checkmark")
                    } else {
                        Text(mode.label)
                    }
                }
            }
        } label: {
            HStack(spacing: 3) {
                Text(viewerMode.label).font(.system(size: 11))
                Image(systemName: "chevron.down").font(.system(size: 8))
            }
            .padding(.horizontal, 6).padding(.vertical, 3)
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
    }

    private var whitespaceMenu: some View {
        Menu {
            ForEach(DiffWhitespaceMode.allCases, id: \.self) { mode in
                Button {
                    whitespaceMode = mode
                } label: {
                    if mode == whitespaceMode {
                        Label(mode.label, systemImage: "checkmark")
                    } else {
                        Text(mode.label)
                    }
                }
            }
        } label: {
            HStack(spacing: 3) {
                Text(whitespaceMode.label).font(.system(size: 11))
                Image(systemName: "chevron.down").font(.system(size: 8))
            }
            .padding(.horizontal, 6).padding(.vertical, 3)
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
    }

    private var highlightMenu: some View {
        Menu {
            ForEach(DiffHighlightMode.allCases, id: \.self) { mode in
                Button {
                    highlightMode = mode
                } label: {
                    if mode == highlightMode {
                        Label(mode.label, systemImage: "checkmark")
                    } else {
                        Text(mode.label)
                    }
                }
            }
        } label: {
            HStack(spacing: 3) {
                Text(highlightMode.label).font(.system(size: 11))
                Image(systemName: "chevron.down").font(.system(size: 8))
            }
            .padding(.horizontal, 6).padding(.vertical, 3)
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
    }

    private var statsLabel: String {
        let count = hunks.count
        let word = count == 1 ? "difference" : "differences"
        // "included" only means something when hunks can be excluded from an apply,
        // i.e. an editable right side. Read-only diffs just report the count.
        guard isRightEditable else { return "\(count) \(word)" }
        let excluded = excludedHunks.intersection(Set(hunks.map(\.id))).count
        let included = count - excluded
        return "\(count) \(word), \(included) included"
    }

    private var settingsPopover: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Diff settings").font(.system(size: 12, weight: .semibold))
            HStack {
                Text("Font size").font(.system(size: 11))
                Slider(value: $fontSize, in: 10...18, step: 1)
                Text("\(Int(fontSize))").font(.system(size: 11)).foregroundStyle(.secondary).frame(width: 22)
            }
        }
        .padding(12)
        .frame(width: 260)
    }

    private var helpPopover: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Shortcuts").font(.system(size: 12, weight: .semibold))
            Group {
                Text("⌘S  — Save dirty changes")
                Text("↑↓ (toolbar) — Prev/Next change")
                Text("Gutter ›› — apply hunk to right")
                Text("Gutter ☐ — toggle include in selection")
            }
            .font(.system(size: 11))
            .foregroundStyle(.secondary)
        }
        .padding(12)
        .frame(width: 280)
    }

    // MARK: - Content

    @ViewBuilder
    private var contentForViewer: some View {
        switch viewerMode {
        case .sideBySide:
            alignedContent
        case .unified:
            unifiedContent
        }
    }

    // MARK: - Aligned side-by-side rows (shared scroll)

    private var alignedContent: some View {
        let rows = self.rows
        let charW = fontSize * 0.62
        let leftMax = rows.compactMap { $0.leftText?.count }.max() ?? 0
        let rightMax = rows.compactMap { $0.rightText?.count }.max() ?? 0
        let leftW = max(CGFloat(leftMax) * charW + 24, 120)
        let rightW = max(CGFloat(rightMax) * charW + 24, 120)

        if isRightEditable {
            return AnyView(editableAligned(rows: rows, leftW: max(leftW, rightW)))
        }
        // Non-editable: two independent code panes (col 0 / col 2) with a fixed-width
        // gutter (col 1) between them. Both panes are maxWidth:.infinity so the gutter
        // stays centered regardless of line length; each pane scrolls horizontally on
        // its own, while X/Y stay synced through activeCol (same machinery as editable).
        return AnyView(readonlyAligned(rows: rows, leftW: leftW, rightW: rightW))
    }

    // Read-only side-by-side: same per-pane scroll + center gutter as editableAligned,
    // but the right side is a code pane (col 2) instead of the live editor.
    private func readonlyAligned(rows: [AlignedDiffRow], leftW: CGFloat, rightW: CGFloat) -> some View {
        HStack(alignment: .top, spacing: 0) {
            codePane(rows, isLeft: true, contentWidth: leftW, col: 0, pos: $leftScroll)
            gutterColumn(rows, pos: $gutterScroll)
            codePane(rows, isLeft: false, contentWidth: rightW, col: 2, pos: $rightScroll)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .onChange(of: currentHunkIndex) { _, new in
            guard new >= 0, new < hunks.count,
                  let target = rows.first(where: { $0.hunkId == hunks[new].id }) else { return }
            let anchor = rowAnchor(target.id)
            withAnimation(.easeOut(duration: 0.15)) {
                leftScroll.scrollTo(id: anchor, anchor: .center)
                gutterScroll.scrollTo(id: anchor, anchor: .center)
                rightScroll.scrollTo(id: anchor, anchor: .center)
            }
        }
    }

    // Editable Current pane keeps its own scroll (TextEditor can't live inside the
    // shared row scroll). Left code + gutter sync to it via syncY as before.
    private func editableAligned(rows: [AlignedDiffRow], leftW: CGFloat) -> some View {
        HStack(alignment: .top, spacing: 0) {
            codePane(rows, isLeft: true, contentWidth: leftW, col: 0, pos: $leftScroll)
            gutterColumn(rows, pos: $gutterScroll)
            rightEditorPane
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .onChange(of: currentHunkIndex) { _, new in
            guard new >= 0, new < hunks.count,
                  let target = rows.first(where: { $0.hunkId == hunks[new].id }) else { return }
            let anchor = rowAnchor(target.id)
            withAnimation(.easeOut(duration: 0.15)) {
                leftScroll.scrollTo(id: anchor, anchor: .center)
                gutterScroll.scrollTo(id: anchor, anchor: .center)
            }
        }
    }

    private func rowAnchor(_ id: Int) -> String { "R-\(id)" }

    // One fixed-height row per line so the code text, the per-line highlight band, and
    // the gutter line numbers all line up 1:1 — no dependence on SwiftUI's Text line
    // height matching the gutter's rowHeight (which drifts and broke alignment).
    private func codePane(_ rows: [AlignedDiffRow], isLeft: Bool, contentWidth: CGFloat,
                          col: Int, pos: Binding<ScrollPosition>) -> some View {
        ScrollView([.horizontal, .vertical]) {
            LazyVStack(spacing: 0) {
                ForEach(rows) { row in
                    ZStack(alignment: .leading) {
                        if highlightMode == .lines {
                            isLeft ? leftBg(row.kind) : rightBg(row.kind)
                        }
                        if row.hunkId == flashHunkId {
                            Color.accentColor.opacity(flashOpacity)
                        }
                        Text(lineAttributed(row, isLeft: isLeft))
                            .font(.system(size: fontSize, design: .monospaced))
                            .lineLimit(1)
                            .fixedSize(horizontal: true, vertical: false)
                            .textSelection(.enabled)
                            .padding(.leading, 8)
                    }
                    .frame(minWidth: contentWidth, maxWidth: .infinity, minHeight: rowHeight,
                           maxHeight: rowHeight, alignment: .leading)
                    .id(rowAnchor(row.id))
                }
            }
            .frame(minWidth: contentWidth, maxWidth: .infinity, alignment: .topLeading)
            .padding(.vertical, 4)
        }
        .defaultScrollAnchor(.topLeading)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .scrollPosition(pos)
        .onHover { if $0 { activeCol = col } }
        .onScrollGeometryChange(for: CGPoint.self) { $0.contentOffset } action: { _, p in
            if activeCol == col { syncX = p.x; syncY = p.y }
        }
        .onChange(of: syncY) { _, y in
            // Scroll both axes together: scrollTo(x:)/scrollTo(y:) alone reset the other
            // axis to origin. syncX/syncY both track the active pane so neither is stale.
            if activeCol != col { pos.wrappedValue.scrollTo(point: CGPoint(x: syncX, y: y)) }
        }
        .onChange(of: syncX) { _, x in
            if activeCol != col { pos.wrappedValue.scrollTo(point: CGPoint(x: x, y: syncY)) }
        }
    }

    // Editable Current pane. Edits flow into workingText -> live re-diff (onChange)
    // updates the left pane + hunks, and Save writes to disk. Scroll is Y-synced with
    // the left code + gutter via syncY (col 2): scrolling the editor drives the others,
    // and the editor follows when the left/gutter drive.
    private var rightEditorPane: some View {
        SyncedTextEditor(
            text: $workingText,
            fontSize: fontSize,
            topInset: 4,
            syntaxExt: syntaxOn ? fileExt : nil,
            handle: editor,
            external: activeCol == 2 ? nil : CGPoint(x: syncX, y: syncY),
            onScroll: { p in
                activeCol = 2
                syncX = p.x
                syncY = p.y
            }
        )
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(Color(NSColor.textBackgroundColor))
    }

    private func gutterColumn(_ rows: [AlignedDiffRow], pos: Binding<ScrollPosition>) -> some View {
        ScrollView(.vertical, showsIndicators: false) {
            LazyVStack(spacing: 0) {
                ForEach(rows) { row in
                    HStack(spacing: 0) {
                        gutterMark(row.kind, left: true)
                        gutterNumber(row.leftLineNum)
                        centerGutter(row)
                        gutterNumber(row.rightLineNum)
                        gutterMark(row.kind, left: false)
                    }
                    .frame(height: rowHeight)
                    .id(rowAnchor(row.id))
                }
            }
            .padding(.vertical, 4)
        }
        .frame(width: Self.gutterColWidth)
        .scrollPosition(pos)
        .onHover { if $0 { activeCol = 1 } }
        .onScrollGeometryChange(for: CGFloat.self) { $0.contentOffset.y } action: { _, y in
            if activeCol == 1 { syncY = y }
        }
        .onChange(of: syncY) { _, y in
            if activeCol != 1 { pos.wrappedValue.scrollTo(y: y) }
        }
    }

    // Left mark (14) + left line-number (46) + center hunk gutter (46)
    // + right line-number (46) + right mark (14).
    private static let gutterColWidth: CGFloat = 14 + 46 + 46 + 46 + 14

    // Per-line +/- marker, pinned in the gutter (does not scroll with the code).
    private func gutterMark(_ kind: AlignedDiffRow.Kind, left: Bool) -> some View {
        let show = left ? (kind == .deletion || kind == .modification)
                        : (kind == .addition || kind == .modification)
        return Text(show ? (left ? "-" : "+") : " ")
            .font(.system(size: fontSize, design: .monospaced))
            .foregroundStyle(left ? Color.red.opacity(0.85) : Color.green.opacity(0.85))
            .frame(width: 14)
            .frame(maxHeight: .infinity)
            .background(gutterBg)
    }

    // Real line height of the rendered monospaced font, so the background layer and the
    // gutter rows line up 1:1 with the Text's lines (no drift over thousands of lines).
    private var rowHeight: CGFloat {
        NSLayoutManager().defaultLineHeight(for: NSFont.monospacedSystemFont(ofSize: fontSize, weight: .regular))
    }

    // Empty text == 0 lines, not one phantom empty line. A phantom "" spuriously
    // LCS-matches a blank line in the other side, mis-aligning added/deleted files.
    static func splitLines(_ s: String) -> [String] {
        s.isEmpty ? [] : s.components(separatedBy: "\n")
    }

    // One row's code as an AttributedString ("" for a gap row). Word mode shades the
    // differing run against its modification counterpart.
    private func lineAttributed(_ row: AlignedDiffRow, isLeft: Bool) -> AttributedString {
        let text = (isLeft ? row.leftText : row.rightText) ?? ""
        let lineNum = isLeft ? row.leftLineNum : row.rightLineNum
        var base = syntaxBase(isLeft: isLeft, lineNum: lineNum, fallback: text)
        if highlightMode == .words,
           let other = isLeft ? pairedRightFor(row) : pairedLeftFor(row) {
            overlayWordDiff(&base, text: text, other: other, isLeft: isLeft)
        }
        return base
    }

    // Word-level highlight: shade the run that differs (common prefix/suffix fold) by
    // applying a background over that character range of the (syntax-colored) base.
    private func overlayWordDiff(_ base: inout AttributedString, text: String, other: String, isLeft: Bool) {
        let a = Array(text), b = Array(other)
        var p = 0
        while p < a.count && p < b.count && a[p] == b[p] { p += 1 }
        var la = a.count - 1, lb = b.count - 1
        while la >= p && lb >= p && a[la] == b[lb] { la -= 1; lb -= 1 }
        guard la >= p else { return }
        let count = base.characters.count
        let lo = min(p, count), hi = min(la + 1, count)
        guard lo < hi else { return }
        let start = base.index(base.startIndex, offsetByCharacters: lo)
        let end = base.index(base.startIndex, offsetByCharacters: hi)
        base[start..<end].backgroundColor = isLeft ? Color.red.opacity(0.4) : Color.green.opacity(0.4)
    }

    private func pairedRightFor(_ row: AlignedDiffRow) -> String? {
        guard row.kind == .modification else { return nil }
        return row.rightText
    }

    private func pairedLeftFor(_ row: AlignedDiffRow) -> String? {
        guard row.kind == .modification else { return nil }
        return row.leftText
    }

    private func gutterNumber(_ n: Int?) -> some View {
        Text(n.map(String.init) ?? "")
            .font(.system(size: max(10, fontSize - 1), design: .monospaced))
            .foregroundStyle(.secondary)
            .frame(width: 42, alignment: .trailing)
            .padding(.trailing, 4)
            .background(gutterBg)
    }

    @ViewBuilder
    private func centerGutter(_ row: AlignedDiffRow) -> some View {
        ZStack {
            gutterBg
            // Apply chevron + include checkbox only make sense when the right side is
            // editable (working tree). In read-only diffs there's nothing to apply, so
            // the gutter shows just the hunk polygon lines.
            if row.isHunkStart, let hid = row.hunkId, isRightEditable {
                HStack(spacing: 4) {
                    Button { applyHunkById(hid) } label: {
                        Image(systemName: "chevron.right.2")
                            .font(.system(size: 10, weight: .bold))
                            .foregroundStyle(Color.accentColor)
                    }
                    .buttonStyle(.borderless)
                    .help("Apply hunk to right")
                    Button {
                        if excludedHunks.contains(hid) {
                            excludedHunks.remove(hid)
                        } else {
                            excludedHunks.insert(hid)
                        }
                    } label: {
                        Image(systemName: excludedHunks.contains(hid) ? "square" : "checkmark.square.fill")
                            .font(.system(size: 11))
                            .foregroundStyle(excludedHunks.contains(hid) ? .secondary : Color.accentColor)
                    }
                    .buttonStyle(.borderless)
                    .help("Include in selection")
                }
                .padding(.horizontal, 2)
            }
        }
        .frame(width: 46, alignment: .center)
        .overlay(alignment: .leading) { polygonLine(row, side: .left) }
        .overlay(alignment: .trailing) { polygonLine(row, side: .right) }
    }

    private enum GutterSide { case left, right }

    @ViewBuilder
    private func polygonLine(_ row: AlignedDiffRow, side: GutterSide) -> some View {
        if row.hunkId != nil {
            Rectangle()
                .fill(polygonColor(row.kind))
                .frame(width: 2)
        } else {
            EmptyView()
        }
    }

    private var gutterBg: Color {
        Color(NSColor.windowBackgroundColor).opacity(0.5)
    }

    private func leftBg(_ kind: AlignedDiffRow.Kind) -> Color {
        guard highlightMode != .none else { return .clear }
        switch kind {
        case .context: return .clear
        case .deletion: return Color.red.opacity(0.18)
        case .modification: return Color.red.opacity(0.14)
        case .addition: return Color.gray.opacity(0.05)
        }
    }

    private func rightBg(_ kind: AlignedDiffRow.Kind) -> Color {
        guard highlightMode != .none else { return .clear }
        switch kind {
        case .context: return .clear
        case .addition: return Color.green.opacity(0.18)
        case .modification: return Color.green.opacity(0.14)
        case .deletion: return Color.gray.opacity(0.05)
        }
    }

    private func polygonColor(_ kind: AlignedDiffRow.Kind) -> Color {
        switch kind {
        case .context: return .clear
        case .deletion: return Color.red.opacity(0.55)
        case .addition: return Color.green.opacity(0.55)
        case .modification: return Color.orange.opacity(0.55)
        }
    }

    // MARK: - Unified viewer

    private var unifiedContent: some View {
        let rows = UnifiedRowBuilder.build(source: sourceText, working: workingText, hunks: hunks)
        return ScrollViewReader { proxy in
            ScrollView([.vertical, .horizontal]) {
                LazyVStack(alignment: .leading, spacing: 0) {
                    ForEach(rows) { row in
                        unifiedRow(row)
                            .id("U-\(row.id)")
                    }
                }
                .padding(.vertical, 4)
            }
            .onChange(of: currentHunkIndex) { _, new in
                guard new >= 0, new < hunks.count else { return }
                if let target = rows.first(where: { $0.hunkId == hunks[new].id }) {
                    withAnimation(.easeOut(duration: 0.15)) {
                        proxy.scrollTo("U-\(target.id)", anchor: .center)
                    }
                }
            }
        }
    }

    private func unifiedRow(_ row: UnifiedRow) -> some View {
        HStack(spacing: 0) {
            Text(row.leftNum.map(String.init) ?? "")
                .font(.system(size: max(10, fontSize - 1), design: .monospaced))
                .foregroundStyle(.secondary)
                .frame(width: 42, alignment: .trailing)
                .padding(.trailing, 4)
            Text(row.rightNum.map(String.init) ?? "")
                .font(.system(size: max(10, fontSize - 1), design: .monospaced))
                .foregroundStyle(.secondary)
                .frame(width: 42, alignment: .trailing)
                .padding(.trailing, 6)
            Text(unifiedPrefix(row.kind))
                .font(.system(size: fontSize, design: .monospaced))
                .foregroundStyle(unifiedFg(row.kind))
                .frame(width: 14)
            Text(unifiedAttributed(row))
                .font(.system(size: fontSize, design: .monospaced))
                .textSelection(.enabled)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 1)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            ZStack {
                unifiedBg(row.kind)
                if row.hunkId == flashHunkId { Color.accentColor.opacity(flashOpacity) }
            }
        )
    }

    // Unified line text: syntax colors when on (deletion/context read from the source
    // side, addition from the working side), else the flat add/del/context fg color.
    private func unifiedAttributed(_ row: UnifiedRow) -> AttributedString {
        let text = row.text.isEmpty ? " " : row.text
        if syntaxOn {
            let fromLeft = row.kind != .addition
            let n = fromLeft ? row.leftNum : row.rightNum
            let lines = fromLeft ? leftSyntax : rightSyntax
            if let n, n - 1 >= 0, n - 1 < lines.count { return lines[n - 1] }
        }
        var a = AttributedString(text)
        a.foregroundColor = unifiedFg(row.kind)
        return a
    }

    private func unifiedPrefix(_ kind: UnifiedRow.Kind) -> String {
        switch kind {
        case .context: return " "
        case .deletion: return "-"
        case .addition: return "+"
        }
    }

    private func unifiedFg(_ kind: UnifiedRow.Kind) -> Color {
        switch kind {
        case .context: return .primary
        case .deletion: return Color(.sRGB, red: 0.75, green: 0.20, blue: 0.20, opacity: 1)
        case .addition: return Color(.sRGB, red: 0.18, green: 0.55, blue: 0.20, opacity: 1)
        }
    }

    private func unifiedBg(_ kind: UnifiedRow.Kind) -> Color {
        guard highlightMode != .none else { return .clear }
        switch kind {
        case .context: return .clear
        case .deletion: return Color.red.opacity(0.10)
        case .addition: return Color.green.opacity(0.10)
        }
    }

    // MARK: - Actions

    private func applyHunkById(_ id: Int) {
        guard let hunk = hunks.first(where: { $0.id == id }) else { return }
        applyHunk(hunk)
    }

    private func applyHunk(_ hunk: LineHunk) {
        var lines = workingText.components(separatedBy: "\n")
        let start = min(hunk.workingStart, lines.count)
        let end = min(hunk.workingEnd, lines.count)
        lines.replaceSubrange(start..<end, with: hunk.sourceLines)
        let newText = lines.joined(separator: "\n")

        // Route the edit through the NSTextView's text system so it registers on the
        // native undo stack — Cmd+Z (or the toolbar Undo) then rolls this apply back as a
        // single step. didChangeText fires textDidChange -> workingText -> recomputeHunks.
        if let tv = editor.textView {
            let full = NSRange(location: 0, length: (tv.string as NSString).length)
            guard tv.shouldChangeText(in: full, replacementString: newText) else { return }
            tv.textStorage?.replaceCharacters(in: full, with: newText)
            // Keep the monospaced face until the debounced re-highlight recolors, so the
            // freshly-replaced text doesn't flash in the system default font.
            tv.textStorage?.addAttribute(
                .font, value: NSFont.monospacedSystemFont(ofSize: fontSize, weight: .regular),
                range: NSRange(location: 0, length: (newText as NSString).length)
            )
            tv.didChangeText()
            editor.refresh()
        } else {
            applyingHunk = true
            defer { applyingHunk = false }
            workingText = newText
            recomputeHunks()
        }
    }

    // Rebuild the per-line color slices from the current texts. Cheap after the first
    // call per blob (SyntaxHighlighter memoizes by content), so safe to call on load.
    private func recomputeSyntax() {
        guard syntaxOn else { leftSyntax = []; rightSyntax = []; return }
        leftSyntax = SyntaxHighlighter.shared.lines(sourceText, ext: fileExt, fontSize: fontSize)
        rightSyntax = SyntaxHighlighter.shared.lines(workingText, ext: fileExt, fontSize: fontSize)
    }

    // Syntax base for one line, or plain text when off / unsupported / out of range.
    private func syntaxBase(isLeft: Bool, lineNum: Int?, fallback: String) -> AttributedString {
        guard syntaxOn, let n = lineNum else { return AttributedString(fallback) }
        let lines = isLeft ? leftSyntax : rightSyntax
        let idx = n - 1
        guard idx >= 0, idx < lines.count else { return AttributedString(fallback) }
        return lines[idx]
    }

    private func recomputeHunks() {
        let src = Self.splitLines(sourceText)
        let wrk = Self.splitLines(workingText)
        hunks = LineDiffer.hunks(source: src, working: wrk, whitespace: whitespaceMode)
        if hunks.isEmpty {
            currentHunkIndex = -1
        } else if currentHunkIndex >= hunks.count {
            currentHunkIndex = hunks.count - 1
        }
        excludedHunks = excludedHunks.intersection(Set(hunks.map(\.id)))
        rows = AlignedRowBuilder.build(source: src, working: wrk, hunks: hunks)
        hunkAnchors = rows.compactMap { r in
            guard r.isHunkStart, let hid = r.hunkId,
                  let hi = hunks.firstIndex(where: { $0.id == hid }) else { return nil }
            return HunkAnchor(rowId: r.id, hunkIndex: hi)
        }
    }

    // The row the user is currently at: the caret's line when the right pane is editable,
    // otherwise the top visible row derived from the shared scroll offset. Prev/Next and
    // their enabled state resolve relative to this, not a standalone step counter.
    private var referenceRowId: Int {
        if isRightEditable, let line = editor.caretLine,
           let r = rows.first(where: { $0.rightLineNum == line }) {
            return r.id
        }
        return max(0, Int((syncY / max(rowHeight, 1)).rounded(.down)))
    }

    // Unified viewer isn't wired to the row/scroll reference, so it keeps stepping by index.
    private var canPrevHunk: Bool {
        guard !hunks.isEmpty else { return false }
        if viewerMode == .unified { return currentHunkIndex != 0 }
        let ref = referenceRowId
        return hunkAnchors.contains { $0.rowId < ref }
    }
    private var canNextHunk: Bool {
        guard !hunks.isEmpty else { return false }
        if viewerMode == .unified { return currentHunkIndex != hunks.count - 1 }
        let ref = referenceRowId
        return hunkAnchors.contains { $0.rowId > ref }
    }

    private func jumpHunk(delta: Int) {
        guard !hunks.isEmpty else { return }
        if viewerMode == .unified {
            if currentHunkIndex < 0 {
                currentHunkIndex = delta > 0 ? 0 : hunks.count - 1
            } else {
                currentHunkIndex = max(0, min(hunks.count - 1, currentHunkIndex + delta))
            }
            flashHunk(currentHunkIndex)
            return
        }
        let ref = referenceRowId
        let target = delta > 0
            ? hunkAnchors.first(where: { $0.rowId > ref })
            : hunkAnchors.last(where: { $0.rowId < ref })
        guard let t = target else { return }
        currentHunkIndex = t.hunkIndex   // existing onChange centers it into view
        advanceReference(toHunk: t.hunkIndex)
        flashHunk(t.hunkIndex)
    }

    // Briefly tint the landed hunk's rows, then fade out.
    private func flashHunk(_ index: Int) {
        guard index >= 0, index < hunks.count else { return }
        let h = hunks[index]
        // Left code pane (and the right pane in read-only) flash via the SwiftUI band.
        flashHunkId = h.id
        flashOpacity = 0.5
        withAnimation(.easeOut(duration: 0.9)) { flashOpacity = 0 }
        // Editable right pane is an NSTextView, not a code-pane row — tint its text range.
        if isRightEditable, let tv = editor.textView {
            let startOff = workingLineStartOffset(h.workingStart + 1)
            let endOff = workingLineStartOffset(h.workingEnd + 1)
            let total = (tv.string as NSString).length
            let len = endOff > startOff ? endOff - startOff : max(0, total - startOff)
            editor.flash(range: NSRange(location: startOff, length: len),
                         color: NSColor.controlAccentColor.withAlphaComponent(0.45))
        }
    }

    // Move the reference onto the landed hunk so a repeated press steps on instead of
    // re-resolving to the same one: place the caret (editable) or nudge the scroll offset.
    private func advanceReference(toHunk index: Int) {
        let wline = hunks[index].workingStart + 1
        if isRightEditable, let tv = editor.textView {
            let off = workingLineStartOffset(wline)
            tv.setSelectedRange(NSRange(location: off, length: 0))
            tv.scrollRangeToVisible(NSRange(location: off, length: 0))
            editor.caretLine = wline
        } else if let row = rows.first(where: { $0.hunkId == hunks[index].id }) {
            syncY = CGFloat(row.id) * rowHeight
        }
    }

    // UTF-16 offset of the start of a 1-based line in workingText (for caret placement).
    private func workingLineStartOffset(_ line1: Int) -> Int {
        let ns = workingText as NSString
        var idx = 0
        var remaining = line1 - 1
        while remaining > 0, idx < ns.length {
            let r = ns.range(of: "\n", range: NSRange(location: idx, length: ns.length - idx))
            if r.location == NSNotFound { break }
            idx = r.location + 1
            remaining -= 1
        }
        return idx
    }

    // Edit the working-tree file in-place, in MyGit's own right pane — never an external
    // app. If the right side is already editable, just focus it; for a commit-vs-parent
    // diff, flip to the on-disk "Current version" (which makes the right pane editable),
    // then focus once it's swapped in.
    /// Opens the file's current working-tree version in a MyGit internal editor
    /// tab (added to the unified detail tab bar, alongside diff tabs).
    private func editSource() {
        coordinator.activeBundle.editor.openFile(path: tab.path)
    }

    private func focusEditor() {
        guard let tv = editor.textView else { return }
        tv.window?.makeFirstResponder(tv)
    }

    private func save() {
        let repoURL = coordinator.activeBundle.repo.url
        do {
            try coordinator.container.fileEditor.write(at: repoURL, path: tab.path, content: workingText)
            diskText = workingText
        } catch {
            loadError = error.localizedDescription
        }
    }

    private func load() async {
        loading = true
        loadError = nil
        defer { loading = false }
        let repoURL = coordinator.activeBundle.repo.url
        do {
            async let src = readSource(repoURL: repoURL)
            async let work = readWorking(repoURL: repoURL)
            let (s, w) = try await (src, work)
            sourceText = s
            workingText = w
            diskText = w
            recomputeHunks()
            recomputeSyntax()
        } catch {
            loadError = error.localizedDescription
        }
    }

    private func reloadForCurrentVersionToggle() async {
        guard tab.mode == .commitVsParent else { return }
        let repoURL = coordinator.activeBundle.repo.url
        do {
            let newRight: String
            if useCurrentVersion {
                let url = repoURL.appendingPathComponent(tab.path)
                newRight = FileManager.default.fileExists(atPath: url.path)
                    ? ((try? String(contentsOf: url, encoding: .utf8)) ?? "")
                    : ""
            } else {
                newRight = try await coordinator.container.git.readFileAtCommit(
                    commit: tab.commitHash, path: tab.path, at: repoURL
                )
            }
            workingText = newRight
            diskText = newRight
            recomputeHunks()
            recomputeSyntax()
        } catch {
            loadError = error.localizedDescription
        }
    }

    private func readSource(repoURL: URL) async throws -> String {
        let git = coordinator.container.git
        switch tab.mode {
        case .commitVsWorking:
            // File may not exist in the commit (added / untracked) -> empty left side.
            return (try? await git.readFileAtCommit(commit: tab.commitHash, path: tab.path, at: repoURL)) ?? ""
        case .commitVsParent, .parentVsWorking:
            return try await git.readFileAtCommit(commit: "\(tab.commitHash)^1", path: tab.path, at: repoURL)
        }
    }

    private func readWorking(repoURL: URL) async throws -> String {
        switch tab.mode {
        case .commitVsWorking, .parentVsWorking:
            let url = repoURL.appendingPathComponent(tab.path)
            if FileManager.default.fileExists(atPath: url.path) {
                return (try? String(contentsOf: url, encoding: .utf8)) ?? ""
            }
            return ""
        case .commitVsParent:
            return try await coordinator.container.git.readFileAtCommit(
                commit: tab.commitHash, path: tab.path, at: repoURL
            )
        }
    }
}

// MARK: - Aligned row model + builder

struct AlignedDiffRow: Identifiable, Hashable {
    let id: Int
    let leftLineNum: Int?
    let leftText: String?
    let rightLineNum: Int?
    let rightText: String?
    let kind: Kind
    let hunkId: Int?
    let isHunkStart: Bool

    enum Kind { case context, deletion, addition, modification }
}

enum AlignedRowBuilder {
    static func build(source: [String], working: [String], hunks: [LineHunk]) -> [AlignedDiffRow] {
        var rows: [AlignedDiffRow] = []
        var i = 0
        var j = 0
        var rowId = 0
        for h in hunks {
            while i < h.sourceStart && j < h.workingStart {
                rows.append(AlignedDiffRow(
                    id: rowId,
                    leftLineNum: i + 1,
                    leftText: source[i],
                    rightLineNum: j + 1,
                    rightText: working[j],
                    kind: .context,
                    hunkId: nil,
                    isHunkStart: false
                ))
                rowId += 1; i += 1; j += 1
            }
            let sCount = h.sourceLines.count
            let wCount = h.workingLines.count
            let paired = min(sCount, wCount)
            var first = true
            for k in 0..<paired {
                rows.append(AlignedDiffRow(
                    id: rowId,
                    leftLineNum: h.sourceStart + k + 1,
                    leftText: h.sourceLines[k],
                    rightLineNum: h.workingStart + k + 1,
                    rightText: h.workingLines[k],
                    kind: .modification,
                    hunkId: h.id,
                    isHunkStart: first
                ))
                first = false; rowId += 1
            }
            for k in paired..<sCount {
                rows.append(AlignedDiffRow(
                    id: rowId,
                    leftLineNum: h.sourceStart + k + 1,
                    leftText: h.sourceLines[k],
                    rightLineNum: nil,
                    rightText: nil,
                    kind: .deletion,
                    hunkId: h.id,
                    isHunkStart: first
                ))
                first = false; rowId += 1
            }
            for k in paired..<wCount {
                rows.append(AlignedDiffRow(
                    id: rowId,
                    leftLineNum: nil,
                    leftText: nil,
                    rightLineNum: h.workingStart + k + 1,
                    rightText: h.workingLines[k],
                    kind: .addition,
                    hunkId: h.id,
                    isHunkStart: first
                ))
                first = false; rowId += 1
            }
            i = h.sourceEnd
            j = h.workingEnd
        }
        while i < source.count && j < working.count {
            rows.append(AlignedDiffRow(
                id: rowId,
                leftLineNum: i + 1,
                leftText: source[i],
                rightLineNum: j + 1,
                rightText: working[j],
                kind: .context,
                hunkId: nil,
                isHunkStart: false
            ))
            rowId += 1; i += 1; j += 1
        }
        while i < source.count {
            rows.append(AlignedDiffRow(
                id: rowId,
                leftLineNum: i + 1,
                leftText: source[i],
                rightLineNum: nil,
                rightText: nil,
                kind: .context,
                hunkId: nil,
                isHunkStart: false
            ))
            rowId += 1; i += 1
        }
        while j < working.count {
            rows.append(AlignedDiffRow(
                id: rowId,
                leftLineNum: nil,
                leftText: nil,
                rightLineNum: j + 1,
                rightText: working[j],
                kind: .context,
                hunkId: nil,
                isHunkStart: false
            ))
            rowId += 1; j += 1
        }
        return rows
    }
}

// MARK: - Unified row model

struct UnifiedRow: Identifiable, Hashable {
    let id: Int
    let leftNum: Int?
    let rightNum: Int?
    let text: String
    let kind: Kind
    let hunkId: Int?

    enum Kind { case context, deletion, addition }
}

enum UnifiedRowBuilder {
    static func build(source: String, working: String, hunks: [LineHunk]) -> [UnifiedRow] {
        let src = source.components(separatedBy: "\n")
        let wrk = working.components(separatedBy: "\n")
        var rows: [UnifiedRow] = []
        var i = 0
        var j = 0
        var rowId = 0
        for h in hunks {
            while i < h.sourceStart && j < h.workingStart {
                rows.append(UnifiedRow(id: rowId, leftNum: i + 1, rightNum: j + 1, text: src[i], kind: .context, hunkId: nil))
                rowId += 1; i += 1; j += 1
            }
            for line in h.sourceLines {
                rows.append(UnifiedRow(id: rowId, leftNum: i + 1, rightNum: nil, text: line, kind: .deletion, hunkId: h.id))
                rowId += 1; i += 1
            }
            for line in h.workingLines {
                rows.append(UnifiedRow(id: rowId, leftNum: nil, rightNum: j + 1, text: line, kind: .addition, hunkId: h.id))
                rowId += 1; j += 1
            }
        }
        while i < src.count && j < wrk.count {
            rows.append(UnifiedRow(id: rowId, leftNum: i + 1, rightNum: j + 1, text: src[i], kind: .context, hunkId: nil))
            rowId += 1; i += 1; j += 1
        }
        return rows
    }
}

// MARK: - Word-level highlighter (common prefix/suffix fold)

// MARK: - Scroll-synced editable text pane

// An NSTextView-backed editor that reports its vertical scroll offset (onScroll) and
// follows an external offset (externalY) when it is not the active/driving column.
// No line wrapping so each line is exactly one row -> 1:1 height with the left code
// column and gutter, anchored to the top. SwiftUI's TextEditor exposes no scroll hook,
// hence the AppKit bridge.
// Bridges the editable pane's NSTextView to the SwiftUI view so applies route through
// the text system's native undo stack (Cmd+Z rolls an apply back as one step) and the
// toolbar Undo/Redo buttons can drive it with live enabled-state.
@MainActor
final class DiffEditorHandle: ObservableObject {
    weak var textView: NSTextView?
    @Published var canUndo = false
    @Published var canRedo = false
    /// 1-based line of the insertion point, or nil before the pane is touched.
    @Published var caretLine: Int? = nil
    private var observers: [NSObjectProtocol] = []

    func attach(_ tv: NSTextView) {
        textView = tv
        guard observers.isEmpty, let um = tv.undoManager else { refresh(); return }
        for name in [Notification.Name.NSUndoManagerCheckpoint,
                     .NSUndoManagerDidUndoChange,
                     .NSUndoManagerDidRedoChange,
                     .NSUndoManagerDidCloseUndoGroup] {
            observers.append(NotificationCenter.default.addObserver(forName: name, object: um, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.refresh() }
            })
        }
        refresh()
    }

    func refresh() {
        canUndo = textView?.undoManager?.canUndo ?? false
        canRedo = textView?.undoManager?.canRedo ?? false
    }

    func undo() { textView?.undoManager?.undo(); refresh() }
    func redo() { textView?.undoManager?.redo(); refresh() }

    // Briefly tint a character range (the hunk Prev/Next landed on) then clear it, so the
    // editable right pane flashes in step with the left code pane's band. Not undoable.
    func flash(range: NSRange, color: NSColor) {
        guard let ts = textView?.textStorage, ts.length > 0 else { return }
        let loc = min(range.location, ts.length)
        let len = min(range.length, ts.length - loc)
        guard len > 0 else { return }
        let r = NSRange(location: loc, length: len)
        ts.addAttribute(.backgroundColor, value: color, range: r)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.9) { [weak ts] in
            guard let ts, NSMaxRange(r) <= ts.length else { return }
            ts.removeAttribute(.backgroundColor, range: r)
        }
    }

    deinit { observers.forEach { NotificationCenter.default.removeObserver($0) } }
}

private struct SyncedTextEditor: NSViewRepresentable {
    @Binding var text: String
    var fontSize: CGFloat
    var topInset: CGFloat
    /// File extension for syntax highlighting; nil disables it (plain monospaced).
    var syntaxExt: String?
    /// Exposes this pane's NSTextView (and its undo manager) to the parent view.
    var handle: DiffEditorHandle
    /// Offset to follow; nil while this pane is the active driver (don't fight the user).
    var external: CGPoint?
    var onScroll: (CGPoint) -> Void

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeNSView(context: Context) -> NSScrollView {
        let tv = NSTextView()
        tv.delegate = context.coordinator
        tv.isRichText = false
        tv.isAutomaticQuoteSubstitutionEnabled = false
        tv.isAutomaticDashSubstitutionEnabled = false
        tv.isAutomaticSpellingCorrectionEnabled = false
        tv.allowsUndo = true
        tv.font = NSFont.monospacedSystemFont(ofSize: fontSize, weight: .regular)
        tv.textContainerInset = NSSize(width: 8, height: topInset)
        tv.textContainer?.lineFragmentPadding = 0
        tv.drawsBackground = false
        tv.string = text
        // No wrapping: one visual line per logical line -> matches the left row grid.
        tv.isHorizontallyResizable = true
        tv.isVerticallyResizable = true
        tv.autoresizingMask = []
        tv.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        tv.textContainer?.widthTracksTextView = false
        tv.textContainer?.size = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)

        let scroll = NSScrollView()
        scroll.documentView = tv
        scroll.hasVerticalScroller = true
        scroll.hasHorizontalScroller = true
        scroll.drawsBackground = false
        scroll.contentView.postsBoundsChangedNotifications = true

        context.coordinator.textView = tv
        context.coordinator.scrollView = scroll
        NotificationCenter.default.addObserver(
            context.coordinator,
            selector: #selector(Coordinator.boundsChanged(_:)),
            name: NSView.boundsDidChangeNotification,
            object: scroll.contentView
        )
        context.coordinator.lastExt = syntaxExt
        context.coordinator.applyHighlight(tv)
        handle.attach(tv)
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        context.coordinator.parent = self
        guard let tv = scroll.documentView as? NSTextView else { return }
        let textChanged = tv.string != text
        if textChanged { tv.string = text }
        let fontChanged = (tv.font?.pointSize ?? 0) != fontSize
        if fontChanged {
            tv.font = NSFont.monospacedSystemFont(ofSize: fontSize, weight: .regular)
        }
        let extChanged = context.coordinator.lastExt != syntaxExt
        // Re-color only on external text / font / toggle changes — NOT on the user's own
        // keystrokes (those route through the debounced re-highlight to avoid clobbering).
        if textChanged || fontChanged || extChanged {
            context.coordinator.lastExt = syntaxExt
            context.coordinator.applyHighlight(tv)
        }
        if let p = external {
            let clip = scroll.contentView
            if abs(clip.bounds.origin.y - p.y) > 0.5 || abs(clip.bounds.origin.x - p.x) > 0.5 {
                context.coordinator.suppress = true
                clip.scroll(to: NSPoint(x: p.x, y: p.y))
                scroll.reflectScrolledClipView(clip)
                context.coordinator.suppress = false
            }
        }
    }

    final class Coordinator: NSObject, NSTextViewDelegate {
        var parent: SyncedTextEditor
        weak var textView: NSTextView?
        weak var scrollView: NSScrollView?
        var suppress = false
        var lastExt: String?
        private var highlightWork: DispatchWorkItem?

        init(_ p: SyncedTextEditor) { parent = p }

        // Track the caret line so the parent's Prev/Next resolve from where the user is.
        func textViewDidChangeSelection(_ notification: Notification) {
            guard let tv = textView else { return }
            let ns = tv.string as NSString
            let loc = min(tv.selectedRange().location, ns.length)
            parent.handle.caretLine = ns.substring(to: loc).components(separatedBy: "\n").count
        }

        func textDidChange(_ notification: Notification) {
            guard let tv = textView else { return }
            parent.text = tv.string
            // Re-color after the user pauses typing; coalesces bursts and keeps editing smooth.
            highlightWork?.cancel()
            guard parent.syntaxExt != nil else { return }
            let work = DispatchWorkItem { [weak self] in
                guard let self, let tv = self.textView else { return }
                self.applyHighlight(tv)
            }
            highlightWork = work
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.25, execute: work)
        }

        // Replace the text storage with syntax-colored attributes (selection preserved),
        // or reset to a plain monospaced font when highlighting is off / unsupported.
        @MainActor func applyHighlight(_ tv: NSTextView) {
            let font = NSFont.monospacedSystemFont(ofSize: parent.fontSize, weight: .regular)
            guard let ext = parent.syntaxExt,
                  let attr = SyntaxHighlighter.shared.attributed(tv.string, ext: ext, fontSize: parent.fontSize) else {
                let sel = tv.selectedRanges
                tv.textStorage?.setAttributes(
                    [.font: font, .foregroundColor: NSColor.textColor],
                    range: NSRange(location: 0, length: (tv.string as NSString).length)
                )
                tv.typingAttributes = [.font: font, .foregroundColor: NSColor.textColor]
                tv.selectedRanges = sel
                return
            }
            let sel = tv.selectedRanges
            tv.textStorage?.setAttributedString(attr)
            tv.typingAttributes = [.font: font, .foregroundColor: NSColor.textColor]
            tv.selectedRanges = sel
        }

        // Fires only on user-driven scroll: programmatic follows set `suppress`.
        @objc func boundsChanged(_ note: Notification) {
            guard !suppress, let clip = scrollView?.contentView else { return }
            parent.onScroll(clip.bounds.origin)
        }
    }
}

enum WordHighlighter {
    static func attribute(for s: String, vs other: String, isLeft: Bool) -> AttributedString {
        let a = Array(s)
        let b = Array(other)
        var p = 0
        while p < a.count && p < b.count && a[p] == b[p] { p += 1 }
        var la = a.count - 1
        var lb = b.count - 1
        while la >= p && lb >= p && a[la] == b[lb] { la -= 1; lb -= 1 }
        var attr = AttributedString()
        if p > 0 { attr.append(AttributedString(String(a[..<p]))) }
        if la >= p {
            var mid = AttributedString(String(a[p...la]))
            let color: NSColor = isLeft ? NSColor(calibratedRed: 0.85, green: 0.30, blue: 0.30, alpha: 0.45)
                                        : NSColor(calibratedRed: 0.35, green: 0.75, blue: 0.40, alpha: 0.45)
            mid.backgroundColor = Color(color)
            attr.append(mid)
        }
        if la + 1 < a.count { attr.append(AttributedString(String(a[(la + 1)...]))) }
        if attr.characters.isEmpty { attr = AttributedString(" ") }
        return attr
    }
}
