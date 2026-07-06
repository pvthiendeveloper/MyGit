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

    // Scroll sync: 0=left 1=gutterL 2=center 3=gutterR 4=right (Y only).
    @State private var syncY: CGFloat = 0
    @State private var activeCol = 0
    @State private var leftScroll = ScrollPosition()
    @State private var rightScroll = ScrollPosition()
    @State private var gutterLScroll = ScrollPosition()
    @State private var gutterRScroll = ScrollPosition()
    @StateObject private var centerEditor = DiffEditorHandle()

    private var unresolvedCount: Int { regions.filter { !$0.resolved }.count }
    private var canApply: Bool { unresolvedCount == 0 }
    private var fileExt: String { (path as NSString).pathExtension }

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
            Divider()
            bottomBar
        }
        .frame(minWidth: 820, minHeight: 460)
        .background(Color(NSColor.textBackgroundColor))
        .onAppear { if !loaded { loadMerge(); loaded = true } }
        .onChange(of: result) { _, _ in resultChanged() }
        .onChange(of: whitespaceMode) { _, _ in loadMerge() }
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
        selectedRegion = regions.first(where: { !$0.resolved })?.id
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
        leftRows = Self.buildSideRows(result: resultLines, side: ours, regions: regions)
        rightRows = Self.buildSideRows(result: resultLines, side: theirs, regions: regions)
    }

    static func split(_ s: String) -> [String] { s.isEmpty ? [] : s.components(separatedBy: "\n") }

    static func buildSideRows(result: [String], side: [String], regions: [ConflictRegion]) -> [MergeSideRow] {
        let ops = LineDiffer.diff(result, side)
        func regionAt(_ r: Int) -> ConflictRegion? {
            regions.first { !$0.resolved && r >= $0.start && r < $0.end }
        }
        var rows: [MergeSideRow] = []
        var r = 0, s = 0, id = 0
        for op in ops {
            switch op {
            case .equal(let line):
                let reg = regionAt(r)
                rows.append(MergeSideRow(id: id, lineNum: s + 1, text: line, resultLine: r,
                                         isConflict: reg != nil, regionId: reg?.id,
                                         isRegionStart: reg?.start == r))
                r += 1; s += 1; id += 1
            case .delete:   // in result, not this side -> gap on this side
                let reg = regionAt(r)
                rows.append(MergeSideRow(id: id, lineNum: nil, text: nil, resultLine: r,
                                         isConflict: reg != nil, regionId: reg?.id,
                                         isRegionStart: reg?.start == r))
                r += 1; id += 1
            case .insert(let line):   // in this side, not result -> side-only extra
                rows.append(MergeSideRow(id: id, lineNum: s + 1, text: line, resultLine: nil,
                                         isConflict: false, regionId: nil, isRegionStart: false))
                s += 1; id += 1
            }
        }
        return rows
    }

    // MARK: - Resolve actions

    private func accept(regionId: Int, ours takeOurs: Bool) {
        guard let idx = regions.firstIndex(where: { $0.id == regionId }) else { return }
        var region = regions[idx]
        let newLines = takeOurs ? region.oursLines : region.theirsLines
        var lines = Self.split(result)
        let lo = min(region.start, lines.count)
        let hi = min(region.end, lines.count)
        lines.replaceSubrange(lo..<hi, with: newLines)
        let delta = newLines.count - region.length
        region.length = newLines.count
        region.resolved = true
        regions[idx] = region
        for j in regions.indices where regions[j].start > region.start { regions[j].start += delta }
        suppressRemap = true
        result = lines.joined(separator: "\n")
        selectedRegion = regions.first(where: { !$0.resolved })?.id
    }

    private func acceptAll(ours takeOurs: Bool) {
        // Resolve from last to first so earlier splices don't shift later ranges.
        for r in regions.sorted(by: { $0.start > $1.start }) where !r.resolved {
            accept(regionId: r.id, ours: takeOurs)
        }
    }

    private func apply() {
        Task { await onApply(result) }
    }

    // MARK: - Navigation

    private func jumpConflict(_ delta: Int) {
        let unresolved = regions.filter { !$0.resolved }.sorted { $0.start < $1.start }
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
            .frame(maxWidth: .infinity, alignment: .topLeading)
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
                            Text(row.lineNum.map(String.init) ?? "")
                                .frame(width: 40, alignment: .trailing)
                            acceptChevron(row, isLeft: true)
                        } else {
                            acceptChevron(row, isLeft: false)
                            Text(row.lineNum.map(String.init) ?? "")
                                .frame(width: 40, alignment: .leading)
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

    @ViewBuilder
    private func acceptChevron(_ row: MergeSideRow, isLeft: Bool) -> some View {
        if row.isRegionStart, row.isConflict, let rid = row.regionId {
            Button {
                accept(regionId: rid, ours: isLeft)
            } label: {
                Image(systemName: isLeft ? "chevron.right.2" : "chevron.left.2")
                    .font(.system(size: 10, weight: .bold))
                    .foregroundStyle(Color.accentColor)
            }
            .buttonStyle(.borderless)
            .help(isLeft ? "Accept ours (left)" : "Accept theirs (right)")
            .frame(width: 20)
        } else {
            Color.clear.frame(width: 20)
        }
    }

    static let gutterWidth: CGFloat = 64

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
                .disabled(!canApply)
                .keyboardShortcut(.defaultAction)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }
}
