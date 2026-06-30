import SwiftUI

/// Center pane of the history graph: fixed-height commit rows with a Canvas
/// drawing branch lanes on the left, ref badges + subject in the middle, and
/// author/date on the right. Selecting a row drives the detail panel.
struct CommitGraphList: View {
    @EnvironmentObject var vm: HistoryViewModel

    private let rowHeight: CGFloat = 46
    private let laneWidth: CGFloat = 14

    private var graphWidth: CGFloat {
        CGFloat(max(vm.graphColumns, 1)) * laneWidth + laneWidth
    }

    var body: some View {
        if vm.graphRows.isEmpty {
            Text("No commits")
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            ScrollView {
                LazyVStack(spacing: 0) {
                    ForEach(vm.graphRows) { row in
                        GraphCommitRow(
                            row: row,
                            rowHeight: rowHeight,
                            laneWidth: laneWidth,
                            graphWidth: graphWidth,
                            isSelected: vm.selectedCommit?.id == row.commit.id
                        )
                        .contentShape(Rectangle())
                        .onTapGesture { vm.selectedCommit = row.commit }
                    }
                    if vm.hasMore {
                        LoadMoreButton(isLoading: vm.isLoadingMore) {
                            await vm.loadMore()
                        }
                    }
                }
            }
        }
    }
}

private struct GraphCommitRow: View {
    let row: GraphRow
    let rowHeight: CGFloat
    let laneWidth: CGFloat
    let graphWidth: CGFloat
    let isSelected: Bool

    var body: some View {
        HStack(spacing: 8) {
            GraphLaneCanvas(row: row, laneWidth: laneWidth, rowHeight: rowHeight)
                .frame(width: graphWidth, height: rowHeight)

            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 4) {
                    ForEach(Array(row.commit.refs.enumerated()), id: \.offset) { _, ref in
                        RefBadge(ref: ref)
                    }
                    Text(row.commit.subject)
                        .font(.system(size: 12, weight: .medium))
                        .lineLimit(1)
                }
                HStack(spacing: 6) {
                    Text(row.commit.author)
                    Text("·")
                    Text(row.commit.shortHash).font(.system(.caption, design: .monospaced))
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            }
            Spacer(minLength: 8)
            Text(row.commit.date, format: .relative(presentation: .named))
                .font(.caption)
                .foregroundStyle(.secondary)
                .padding(.trailing, 8)
        }
        .frame(height: rowHeight)
        .background(isSelected ? Color.accentColor.opacity(0.18) : Color.clear)
    }
}

/// Draws the lane segments + node dot for a single row.
private struct GraphLaneCanvas: View {
    let row: GraphRow
    let laneWidth: CGFloat
    let rowHeight: CGFloat

    private func x(_ col: Int) -> CGFloat { laneWidth / 2 + CGFloat(col) * laneWidth }

    var body: some View {
        Canvas { ctx, _ in
            let mid = rowHeight / 2

            func stroke(_ seg: GraphLaneSegment, fromY: CGFloat, toY: CGFloat) {
                var path = Path()
                let x0 = x(seg.fromColumn), x1 = x(seg.toColumn)
                path.move(to: CGPoint(x: x0, y: fromY))
                if x0 == x1 {
                    path.addLine(to: CGPoint(x: x1, y: toY))
                } else {
                    // Smooth S-curve when changing lanes.
                    let cy = (fromY + toY) / 2
                    path.addCurve(
                        to: CGPoint(x: x1, y: toY),
                        control1: CGPoint(x: x0, y: cy),
                        control2: CGPoint(x: x1, y: cy)
                    )
                }
                ctx.stroke(path, with: .color(GraphPalette.color(seg.colorIndex)), lineWidth: 2)
            }

            for seg in row.incoming { stroke(seg, fromY: 0, toY: mid) }
            for seg in row.outgoing { stroke(seg, fromY: mid, toY: rowHeight) }

            let cx = x(row.column)
            let dot = CGRect(x: cx - 4, y: mid - 4, width: 8, height: 8)
            ctx.fill(Path(ellipseIn: dot), with: .color(GraphPalette.color(row.colorIndex)))
            ctx.stroke(Path(ellipseIn: dot), with: .color(Color(NSColor.controlBackgroundColor)), lineWidth: 1)
        }
    }
}
