import SwiftUI
import AppKit

// One aligned row of a side (ours/theirs) pane, anchored to the Result spine.
struct MergeSideRow: Identifiable, Hashable {
    let id: Int
    let lineNum: Int?        // this side's 1-based line number (nil = gap)
    let text: String?        // nil = gap row (result has a line this side lacks)
    let resultLine: Int?     // 0-based result line it anchors to (nil = side-only extra)
    let isConflict: Bool
    let regionId: Int?
    let isRegionStart: Bool
}

// JetBrains-style 3-pane merge editor: left = ours (read-only), center = Result
// (editable NSTextView), right = theirs (read-only). Non-conflicts are auto-merged;
// conflicts are seeded with ours and resolved via Accept Left/Right or free-text edit.
struct MergeRevisionsView: View {
    let path: String
    let oursLabel: String
    let theirsLabel: String
    let baseText: String
    let oursText: String
    let theirsText: String
    let onApply: (String) async -> Void
    let onCancel: () -> Void

    @State private var ours: [String] = []
    @State private var theirs: [String] = []
    @State private var regions: [ConflictRegion] = []
    @State private var changeCount = 0

    @State private var result = ""
    @State private var prevResultLines: [String] = []
    @State private var leftRows: [MergeSideRow] = []
    @State private var rightRows: [MergeSideRow] = []
    @State private var loaded = false
    @State private var suppressRemap = false

    @State private var whitespaceMode: DiffWhitespaceMode = .doNotIgnore
    @State private var fontSize: CGFloat = 12
    @State private var selectedRegion: Int? = nil

    struct UndoSnapshot { let result: String; let regions: [ConflictRegion] }
    @State private var undoStack: [UndoSnapshot] = []
    @State private var redoStack: [UndoSnapshot] = []

    // Scroll sync: 0=left 1=gutterL 2=center 3=gutterR 4=right (Y only).
    @State private var syncY: CGFloat = 0
    @State private var activeCol = 0
    @State private var leftScroll = ScrollPosition()
    @State private var rightScroll = ScrollPosition()
    @State private var gutterLScroll = ScrollPosition()
    @State private var gutterRScroll = ScrollPosition()
    @StateObject private var centerEditor = DiffEditorHandle()

    @State private var showApplyWarning = false
    @State private var toastVisible = false
    @State private var hideToastWork: DispatchWorkItem?

    private var unresolvedCount: Int { regions.filter { !$0.processed }.count }
    private var allProcessed: Bool { !regions.isEmpty && unresolvedCount == 0 }
    private var fileExt: String { (path as NSString).pathExtension }

    // Toast shown once every conflict has an action; links straight to Apply.
    private var allProcessedToast: some View {
        VStack(spacing: 3) {
            Text("All changes have been processed.")
            Button("Save changes and finish merging") { Task { await onApply(result) } }
                .buttonStyle(.plain)
                .underline()
        }
        .font(.system(size: 13))
        .foregroundStyle(.white)
        .padding(.horizontal, 16).padding(.vertical, 10)
        .background(Color.accentColor, in: RoundedRectangle(cornerRadius: 8))
        .shadow(radius: 6, y: 2)
        .transition(.opacity.combined(with: .move(edge: .top)))
    }

    var body: some View {
        VStack(spacing: 0) {
            toolbar
            Divider()
            header
            Divider()
            HStack(spacing: 0) {
                sidePane(leftRows, isLeft: true, col: 0, pos: $leftScroll)
                gutter(leftRows, isLeft: true, col: 1, pos: $gutterLScroll)
                centerPane
                gutter(rightRows, isLeft: false, col: 3, pos: $gutterRScroll)
                sidePane(rightRows, isLeft: false, col: 4, pos: $rightScroll)
            }
            .overlay(alignment: .top) {
                if toastVisible { allProcessedToast.padding(.top, 12) }
            }
            .animation(.easeOut(duration: 0.2), value: toastVisible)
            Divider()
            bottomBar
        }
        .frame(minWidth: 820, minHeight: 460)
        .background(Color(NSColor.textBackgroundColor))
        .onAppear { if !loaded { loadMerge(); loaded = true } }
        .onChange(of: result) { _, _ in resultChanged() }
        .onChange(of: whitespaceMode) { _, _ in loadMerge() }
        .onChange(of: allProcessed) { _, done in
            hideToastWork?.cancel()
            guard done else { toastVisible = false; return }
            toastVisible = true
            let w = DispatchWorkItem { toastVisible = false }
            hideToastWork = w
            DispatchQueue.main.asyncAfter(deadline: .now() + 4, execute: w)
        }
    }

    // MARK: - Load / rebuild

    private func loadMerge() {
        ours = Self.split(oursText)
        theirs = Self.split(theirsText)
        let m = ThreeWayMerger.merge(base: Self.split(baseText), ours: ours, theirs: theirs,
                                     whitespace: whitespaceMode)
        regions = m.regions
        changeCount = m.changeCount
        suppressRemap = true
        result = m.result.joined(separator: "\n")
        prevResultLines = m.result
        rebuildRows(m.result)
        selectedRegion = regions.first(where: { !$0.processed })?.id
        undoStack.removeAll()
        redoStack.removeAll()
    }

    private func resultChanged() {
        let newLines = Self.split(result)
        if suppressRemap {
            suppressRemap = false
        } else {
            regions = ThreeWayMerger.remap(regions, from: prevResultLines, to: newLines)
        }
        prevResultLines = newLines
        rebuildRows(newLines)
    }

    private func rebuildRows(_ resultLines: [String]) {
        leftRows = Self.buildSideRows(result: resultLines, side: ours, regions: regions, isLeft: true)
        rightRows = Self.buildSideRows(result: resultLines, side: theirs, regions: regions, isLeft: false)
    }

    static func split(_ s: String) -> [String] { s.isEmpty ? [] : s.components(separatedBy: "\n") }

    /// Build one side's aligned rows. Non-conflict spans are LCS-diffed against the
    /// Result (yielding gaps for other-side-only lines); each unresolved conflict is
    /// emitted as a fixed block whose height is `max(this side's lines, Result rows)`,
    /// so ours / Result / theirs share the same row grid across all three panes.
    static func buildSideRows(result: [String], side: [String],
                              regions: [ConflictRegion], isLeft: Bool) -> [MergeSideRow] {
        let active = regions.filter { !$0.processed }.sorted { $0.start < $1.start }
        var rows: [MergeSideRow] = []
        var id = 0
        var rCursor = 0, sCursor = 0

        // Align a plain span result[rCursor..<resEnd] with side[sCursor..<sEnd].
        func emitSpan(_ resEnd: Int, _ sEnd: Int) {
            guard resEnd >= rCursor, sEnd >= sCursor else { rCursor = resEnd; sCursor = sEnd; return }
            let ops = LineDiffer.diff(Array(result[rCursor..<resEnd]), Array(side[sCursor..<sEnd]))
            var r = rCursor, s = sCursor
            for op in ops {
                switch op {
                case .equal(let line):
                    rows.append(MergeSideRow(id: id, lineNum: s + 1, text: line, resultLine: r,
                                             isConflict: false, regionId: nil, isRegionStart: false))
                    r += 1; s += 1; id += 1
                case .delete:   // result line absent on this side -> gap
                    rows.append(MergeSideRow(id: id, lineNum: nil, text: nil, resultLine: r,
                                             isConflict: false, regionId: nil, isRegionStart: false))
                    r += 1; id += 1
                case .insert(let line):   // side-only extra line
                    rows.append(MergeSideRow(id: id, lineNum: s + 1, text: line, resultLine: nil,
                                             isConflict: false, regionId: nil, isRegionStart: false))
                    s += 1; id += 1
                }
            }
            rCursor = resEnd; sCursor = sEnd
        }

        // First contiguous match of this side's region lines in `side` at/after `from`.
        func locate(_ sub: [String], from: Int) -> Int {
            if sub.isEmpty || from + sub.count > side.count { return from }
            var i = from
            while i + sub.count <= side.count {
                if Array(side[i..<i + sub.count]) == sub { return i }
                i += 1
            }
            return from
        }

        for reg in active {
            let sideLines = isLeft ? reg.oursLines : reg.theirsLines
            let sideStart = locate(sideLines, from: sCursor)
            emitSpan(min(reg.start, result.count), min(sideStart, side.count))
            let resLen = max(0, min(reg.length, result.count - reg.start))
            let height = max(sideLines.count, resLen)
            for k in 0..<height {
                let text = k < sideLines.count ? sideLines[k] : nil
                rows.append(MergeSideRow(id: id,
                                         lineNum: text == nil ? nil : sideStart + k + 1,
                                         text: text,
                                         resultLine: k < resLen ? reg.start + k : nil,
                                         isConflict: true, regionId: reg.id, isRegionStart: k == 0))
                id += 1
            }
            rCursor = min(reg.end, result.count)
            sCursor = min(sideStart + sideLines.count, side.count)
        }
        emitSpan(result.count, side.count)
        return rows
    }

    // MARK: - Resolve actions

    // Snapshot (Result text + region state) taken before each accept, so the user can
    // undo a `>>` / `<<` accept and restore the conflict.
    private func pushUndo() {
        undoStack.append(UndoSnapshot(result: result, regions: regions))
        redoStack.removeAll()   // a new accept invalidates the redo branch
    }

    private func restore(_ snap: UndoSnapshot) {
        suppressRemap = true
        regions = snap.regions
        result = snap.result
        selectedRegion = regions.first(where: { !$0.processed })?.id
        rebuildRows(Self.split(result))
    }

    private func undo() {
        guard let snap = undoStack.popLast() else { return }
        redoStack.append(UndoSnapshot(result: result, regions: regions))
        restore(snap)
    }

    private func redo() {
        guard let snap = redoStack.popLast() else { return }
        undoStack.append(UndoSnapshot(result: result, regions: regions))
        restore(snap)
    }

    /// Set one side of a conflict to accepted/ignored, then rewrite that region's
    /// Result content from the two per-side states. Both sides must be acted on for
    /// the conflict to count as processed.
    private func setSide(regionId: Int, ours: Bool, state: SideState, snapshot: Bool = true) {
        guard let idx = regions.firstIndex(where: { $0.id == regionId }) else { return }
        if snapshot { pushUndo() }
        if ours { regions[idx].oursState = state } else { regions[idx].theirsState = state }
        // Maintain acceptance order: append when accepted, drop otherwise.
        regions[idx].acceptOrder.removeAll { $0 == ours }
        if state == .accepted { regions[idx].acceptOrder.append(ours) }
        recomputeRegion(idx)
        selectedRegion = regions.first(where: { !$0.processed })?.id
    }

    // Splice the region's merged content into the Result, shifting later regions.
    private func recomputeRegion(_ idx: Int) {
        var region = regions[idx]
        let content = region.mergedContent
        var lines = Self.split(result)
        let lo = min(region.start, lines.count)
        let hi = min(region.end, lines.count)
        lines.replaceSubrange(lo..<hi, with: content)
        let delta = content.count - region.length
        region.length = content.count
        regions[idx] = region
        for j in regions.indices where regions[j].start > region.start { regions[j].start += delta }
        suppressRemap = true
        result = lines.joined(separator: "\n")
    }

    // Bottom-bar "Accept Left/Right": take that side, ignore the other, for all conflicts.
    private func acceptAll(ours takeOurs: Bool) {
        pushUndo()
        // Last to first so earlier splices don't shift later ranges.
        for r in regions.sorted(by: { $0.start > $1.start }) where !r.processed {
            setSide(regionId: r.id, ours: takeOurs, state: .accepted, snapshot: false)
            setSide(regionId: r.id, ours: !takeOurs, state: .ignored, snapshot: false)
        }
    }

    private func apply() {
        if unresolvedCount > 0 { showApplyWarning = true }
        else { Task { await onApply(result) } }
    }

    // MARK: - Navigation

    private func jumpConflict(_ delta: Int) {
        let unresolved = regions.filter { !$0.processed }.sorted { $0.start < $1.start }
        guard !unresolved.isEmpty else { return }
        let cur = selectedRegion.flatMap { id in unresolved.firstIndex { $0.id == id } } ?? -1
        let next = max(0, min(unresolved.count - 1, cur + delta))
        let region = unresolved[next]
        selectedRegion = region.id
        if let anchor = leftRows.first(where: { $0.regionId == region.id && $0.isRegionStart }) {
            withAnimation(.easeOut(duration: 0.15)) {
                leftScroll.scrollTo(id: anchor.id, anchor: .center)
                rightScroll.scrollTo(id: anchor.id, anchor: .center)
                gutterLScroll.scrollTo(id: anchor.id, anchor: .center)
                gutterRScroll.scrollTo(id: anchor.id, anchor: .center)
            }
        }
    }

    // MARK: - Panes

    private var rowHeight: CGFloat {
        NSLayoutManager().defaultLineHeight(for: NSFont.monospacedSystemFont(ofSize: fontSize, weight: .regular))
    }

    private func sidePane(_ rows: [MergeSideRow], isLeft: Bool, col: Int, pos: Binding<ScrollPosition>) -> some View {
        GeometryReader { geo in
        ScrollView([.horizontal, .vertical]) {
            LazyVStack(spacing: 0) {
                ForEach(rows) { row in
                    ZStack(alignment: .leading) {
                        if row.isConflict { Color.red.opacity(0.16) }
                        else if row.text == nil { Color.gray.opacity(0.05) }
                        Text(row.text ?? "")
                            .font(.system(size: fontSize, design: .monospaced))
                            .lineLimit(1)
                            .fixedSize(horizontal: true, vertical: false)
                            .textSelection(.enabled)
                            .padding(.leading, 8)
                    }
                    .frame(minWidth: 120, maxWidth: .infinity, minHeight: rowHeight,
                           maxHeight: rowHeight, alignment: .leading)
                    .id(row.id)
                }
            }
            // minWidth/minHeight = viewport so short/narrow content pins top-left
            // instead of the two-axis ScrollView centering it on both axes.
            .frame(minWidth: geo.size.width, maxWidth: .infinity,
                   minHeight: geo.size.height, alignment: .topLeading)
            .padding(.vertical, 4)
        }
        .defaultScrollAnchor(.topLeading)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .scrollPosition(pos)
        .onHover { if $0 { activeCol = col } }
        .onScrollGeometryChange(for: CGFloat.self) { $0.contentOffset.y } action: { _, y in
            if activeCol == col { syncY = y }
        }
        .onChange(of: syncY) { _, y in
            if activeCol != col { pos.wrappedValue.scrollTo(y: y) }
        }
        }
    }

    private var centerPane: some View {
        SyncedTextEditor(
            text: $result,
            fontSize: fontSize,
            topInset: 4,
            syntaxExt: fileExt.isEmpty ? nil : fileExt,
            handle: centerEditor,
            external: activeCol == 2 ? nil : CGPoint(x: 0, y: syncY),
            onScroll: { p in activeCol = 2; syncY = p.y }
        )
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(Color(NSColor.textBackgroundColor))
    }

    private func gutter(_ rows: [MergeSideRow], isLeft: Bool, col: Int, pos: Binding<ScrollPosition>) -> some View {
        ScrollView(.vertical, showsIndicators: false) {
            LazyVStack(spacing: 0) {
                ForEach(rows) { row in
                    HStack(spacing: 2) {
                        if isLeft {
                            rejectX(row, isLeft: true)
                            acceptChevron(row, isLeft: true)
                            Text(row.lineNum.map(String.init) ?? "")
                                .frame(width: 34, alignment: .trailing)
                        } else {
                            Text(row.lineNum.map(String.init) ?? "")
                                .frame(width: 34, alignment: .leading)
                            acceptChevron(row, isLeft: false)
                            rejectX(row, isLeft: false)
                        }
                    }
                    .font(.system(size: max(10, fontSize - 1), design: .monospaced))
                    .foregroundStyle(.secondary)
                    .frame(width: Self.gutterWidth, height: rowHeight)
                    .id(row.id)
                }
            }
            .padding(.vertical, 4)
        }
        .frame(width: Self.gutterWidth)
        .background(Color(NSColor.windowBackgroundColor).opacity(0.5))
        .scrollPosition(pos)
        .onHover { if $0 { activeCol = col } }
        .onScrollGeometryChange(for: CGFloat.self) { $0.contentOffset.y } action: { _, y in
            if activeCol == col { syncY = y }
        }
        .onChange(of: syncY) { _, y in
            if activeCol != col { pos.wrappedValue.scrollTo(y: y) }
        }
    }

    private func sideState(_ regionId: Int, ours: Bool) -> SideState {
        guard let r = regions.first(where: { $0.id == regionId }) else { return .pending }
        return ours ? r.oursState : r.theirsState
    }

    // >> / << : accept this side (merge its lines into Result). Green once accepted.
    @ViewBuilder
    private func acceptChevron(_ row: MergeSideRow, isLeft: Bool) -> some View {
        if row.isRegionStart, row.isConflict, let rid = row.regionId {
            let st = sideState(rid, ours: isLeft)
            // Once the other side is merged, accepting this side appends below it -> show
            // the "append" corner arrow instead of the plain accept chevron.
            let appends = sideState(rid, ours: !isLeft) == .accepted
            // Append arrow points into the Result (center): left pane -> down-right,
            // right pane -> down-left.
            let icon = appends
                ? (isLeft ? "arrow.turn.down.right" : "arrow.turn.down.left")
                : (isLeft ? "chevron.right.2" : "chevron.left.2")
            Button {
                setSide(regionId: rid, ours: isLeft, state: .accepted)
            } label: {
                Image(systemName: icon)
                    .font(.system(size: 10, weight: .bold))
                    .foregroundStyle(st == .accepted ? Color.green : Color.accentColor)
                    .opacity(st == .ignored ? 0.3 : 1)
            }
            .buttonStyle(.borderless)
            .help(appends ? "Append this side below the other"
                          : (isLeft ? "Accept ours (left)" : "Accept theirs (right)"))
            .frame(width: 18)
        } else {
            Color.clear.frame(width: 18)
        }
    }

    // X : ignore this side (its lines are NOT merged). Red once ignored.
    @ViewBuilder
    private func rejectX(_ row: MergeSideRow, isLeft: Bool) -> some View {
        if row.isRegionStart, row.isConflict, let rid = row.regionId {
            let st = sideState(rid, ours: isLeft)
            Button {
                setSide(regionId: rid, ours: isLeft, state: .ignored)
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 9, weight: .bold))
                    .foregroundStyle(st == .ignored ? Color.red : Color.secondary)
                    .opacity(st == .accepted ? 0.3 : 1)
            }
            .buttonStyle(.borderless)
            .help(isLeft ? "Ignore ours (left)" : "Ignore theirs (right)")
            .frame(width: 18)
        } else {
            Color.clear.frame(width: 18)
        }
    }

    static let gutterWidth: CGFloat = 78

    // MARK: - Header / toolbar / bottom

    private var header: some View {
        HStack(spacing: 0) {
            label("Changes from \(oursLabel)", lock: true)
                .frame(maxWidth: .infinity, alignment: .leading)
            Spacer().frame(width: Self.gutterWidth)
            Text("Result").font(.system(size: 11, weight: .semibold))
                .frame(maxWidth: .infinity, alignment: .center)
            Spacer().frame(width: Self.gutterWidth)
            label("Changes from \(theirsLabel)", lock: true)
                .frame(maxWidth: .infinity, alignment: .trailing)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 4)
        .background(Color(NSColor.windowBackgroundColor).opacity(0.6))
    }

    private func label(_ text: String, lock: Bool) -> some View {
        HStack(spacing: 4) {
            Image(systemName: lock ? "lock" : "pencil").font(.system(size: 10)).foregroundStyle(.secondary)
            Text(text).font(.system(size: 11, weight: .medium)).lineLimit(1).truncationMode(.middle)
        }
    }

    private var toolbar: some View {
        HStack(spacing: 8) {
            Button { jumpConflict(-1) } label: { Image(systemName: "chevron.up") }
                .disabled(unresolvedCount == 0).help("Previous conflict")
            Button { jumpConflict(1) } label: { Image(systemName: "chevron.down") }
                .disabled(unresolvedCount == 0).help("Next conflict")
            Divider().frame(height: 14)
            Button { undo() } label: { Image(systemName: "arrow.uturn.backward") }
                .disabled(undoStack.isEmpty).help("Undo last accept")
            Button { redo() } label: { Image(systemName: "arrow.uturn.forward") }
                .disabled(redoStack.isEmpty).help("Redo")
            Divider().frame(height: 14)
            Menu {
                ForEach(DiffWhitespaceMode.allCases, id: \.self) { m in
                    Button {
                        whitespaceMode = m
                    } label: {
                        if m == whitespaceMode { Label(m.label, systemImage: "checkmark") }
                        else { Text(m.label) }
                    }
                }
            } label: { Text(whitespaceMode.label).font(.system(size: 11)) }
            .menuStyle(.borderlessButton).fixedSize()
            Spacer()
            Text(counterText).font(.system(size: 11)).foregroundStyle(unresolvedCount > 0 ? .orange : .secondary)
        }
        .buttonStyle(.borderless)
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
        .background(Color(NSColor.windowBackgroundColor).opacity(0.7))
    }

    private var counterText: String {
        let c = unresolvedCount
        let changes = changeCount
        let changesStr = changes == 0 ? "No changes" : "\(changes) change\(changes == 1 ? "" : "s")"
        return "\(changesStr). \(c) conflict\(c == 1 ? "" : "s")."
    }

    private var bottomBar: some View {
        HStack(spacing: 8) {
            Button("Accept Left") { acceptAll(ours: true) }.disabled(unresolvedCount == 0)
            Button("Accept Right") { acceptAll(ours: false) }.disabled(unresolvedCount == 0)
            Spacer()
            Button("Cancel", role: .cancel) { onCancel() }.keyboardShortcut(.cancelAction)
            Button("Apply") { apply() }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .confirmationDialog("Apply Changes", isPresented: $showApplyWarning) {
            Button("Apply Changes and Mark Resolved") { Task { await onApply(result) } }
            Button("Continue Merge", role: .cancel) { }
        } message: {
            let n = unresolvedCount
            Text("There \(n == 1 ? "is" : "are") \(n) conflict\(n == 1 ? "" : "s") left unprocessed.\nSave changes and mark the conflict\(n == 1 ? "" : "s") resolved anyway?")
        }
    }
}
