import Foundation

/// One lane segment drawn within a single graph row. `fromColumn` is the lane
/// position at the row's top (for incoming) or at the commit node (for
/// outgoing); `toColumn` is the position at the row's mid/bottom.
struct GraphLaneSegment: Hashable {
    let fromColumn: Int
    let toColumn: Int
    let colorIndex: Int
}

/// A commit row laid out for graph rendering. The node dot sits at `column`
/// with `colorIndex`; `incoming` routes lanes from the top edge to the node
/// row, `outgoing` routes from the node row to the bottom edge.
struct GraphRow: Identifiable {
    let commit: GitCommit
    var id: String { commit.id }
    let column: Int
    let colorIndex: Int
    let incoming: [GraphLaneSegment]
    let outgoing: [GraphLaneSegment]
    let maxColumns: Int   // number of lane slots in use on this row
}

/// Pure lane-assignment for a topo-ordered commit list (newest first).
/// Reconstructs branch lanes from each commit's parent hashes — no git calls.
enum CommitGraph {
    static let paletteCount = 8

    static func layout(_ commits: [GitCommit]) -> [GraphRow] {
        // activeLanes[i] = the SHA lane i is currently waiting to reach next.
        var activeLanes: [String?] = []
        var laneColor: [Int] = []
        var rows: [GraphRow] = []
        var nextColor = 0

        func firstFreeLane() -> Int {
            if let idx = activeLanes.firstIndex(where: { $0 == nil }) { return idx }
            activeLanes.append(nil)
            laneColor.append(0)
            return activeLanes.count - 1
        }

        for commit in commits {
            // Lanes whose pending SHA is this commit (edges from already-seen children).
            let waiting = activeLanes.indices.filter { activeLanes[$0] == commit.id }

            let column: Int
            let colorIndex: Int
            if let first = waiting.first {
                column = first
                colorIndex = laneColor[first]
            } else {
                // No child in the loaded window — start a fresh root lane.
                column = firstFreeLane()
                colorIndex = nextColor % paletteCount
                nextColor += 1
                laneColor[column] = colorIndex
            }

            // Incoming: snapshot every live lane before mutation. Waiting lanes
            // converge into `column`; others continue straight down.
            var incoming: [GraphLaneSegment] = []
            for i in activeLanes.indices {
                guard let sha = activeLanes[i] else { continue }
                let to = (sha == commit.id) ? column : i
                incoming.append(GraphLaneSegment(fromColumn: i, toColumn: to, colorIndex: laneColor[i]))
            }

            // Free the extra waiting lanes (merged into `column`).
            for i in waiting where i != column { activeLanes[i] = nil }

            // Route parents. First parent continues this lane; extra parents fan out.
            var parentLanes: [Int] = []
            let parents = commit.parents
            if parents.isEmpty {
                activeLanes[column] = nil
            } else {
                activeLanes[column] = parents[0]
                laneColor[column] = colorIndex
                parentLanes.append(column)
                for p in parents.dropFirst() {
                    if let existing = activeLanes.firstIndex(where: { $0 == p }) {
                        parentLanes.append(existing)   // converge into an existing target lane
                    } else {
                        let lane = firstFreeLane()
                        activeLanes[lane] = p
                        let c = nextColor % paletteCount
                        nextColor += 1
                        laneColor[lane] = c
                        parentLanes.append(lane)
                    }
                }
            }

            // Outgoing: parent lanes emanate from the node `column`; others continue straight.
            var outgoing: [GraphLaneSegment] = []
            for i in activeLanes.indices where activeLanes[i] != nil {
                let from = parentLanes.contains(i) ? column : i
                outgoing.append(GraphLaneSegment(fromColumn: from, toColumn: i, colorIndex: laneColor[i]))
            }

            let usedTop = incoming.map { max($0.fromColumn, $0.toColumn) }.max() ?? column
            let usedBottom = outgoing.map { max($0.fromColumn, $0.toColumn) }.max() ?? column
            let maxColumns = max(column, max(usedTop, usedBottom)) + 1

            rows.append(GraphRow(
                commit: commit,
                column: column,
                colorIndex: colorIndex,
                incoming: incoming,
                outgoing: outgoing,
                maxColumns: maxColumns
            ))

            // Trim trailing empty lanes so width stays tight.
            while let last = activeLanes.last, last == nil {
                activeLanes.removeLast()
                laneColor.removeLast()
            }
        }

        return rows
    }
}
