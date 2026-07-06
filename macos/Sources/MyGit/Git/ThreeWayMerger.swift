import Foundation

// A contiguous region of an in-progress merge, classified against the base.
struct MergeChunk: Identifiable {
    enum Kind { case context, oursOnly, theirsOnly, bothSame, conflict }
    let id: Int
    let kind: Kind
    let baseLines: [String]
    let oursLines: [String]
    let theirsLines: [String]

    // Auto-merged output for non-conflicting chunks; conflicts are seeded with ours.
    var resultLines: [String] {
        switch kind {
        case .context, .bothSame: return oursLines.isEmpty ? baseLines : oursLines
        case .oursOnly: return oursLines
        case .theirsOnly: return theirsLines
        case .conflict: return oursLines.isEmpty ? baseLines : oursLines
        }
    }
}

// Per-side disposition of a conflict: the user must act on BOTH sides.
enum SideState { case pending, accepted, ignored }

// A still-tracked conflict as a line range into the live Result text, so the editor
// can navigate/accept and remap it as the user edits. Each side (ours/theirs) is
// independently accepted (merge its lines) or ignored (X — drop its lines).
struct ConflictRegion: Identifiable {
    let id: Int
    var start: Int          // 0-based first Result line of the region
    var length: Int         // number of Result lines
    let oursLines: [String]
    let theirsLines: [String]
    let baseLines: [String]
    var resolved: Bool      // manual free-text edit inside the region took over
    var oursState: SideState = .pending
    var theirsState: SideState = .pending
    // Sides in the order the user accepted them (true = ours). The first-accepted side
    // stays on top; a later "append" adds below it. Kept in sync with the states.
    var acceptOrder: [Bool] = []
    var end: Int { start + length }

    // Done when the user has acted on both sides, or edited the region by hand.
    var processed: Bool { resolved || (oursState != .pending && theirsState != .pending) }

    // Result content for this region, honoring acceptance order.
    var mergedContent: [String] {
        var out: [String] = []
        for isOurs in acceptOrder { out += isOurs ? oursLines : theirsLines }
        if !out.isEmpty { return out }
        // nothing accepted yet: show base as a placeholder while a side is pending,
        // otherwise (both ignored) the region collapses to nothing.
        return (oursState == .pending || theirsState == .pending) ? baseLines : []
    }
}

enum ThreeWayMerger {
    /// Classic diff3 merge: two 2-way diffs over the common base. Returns the initial
    /// auto-merged Result lines plus the conflict regions (line ranges into that Result).
    static func merge(base: [String], ours: [String], theirs: [String],
                      whitespace: DiffWhitespaceMode) -> (result: [String], regions: [ConflictRegion], changeCount: Int) {
        let ho = LineDiffer.hunks(source: base, working: ours, whitespace: whitespace)
        let ht = LineDiffer.hunks(source: base, working: theirs, whitespace: whitespace)

        var result: [String] = []
        var regions: [ConflictRegion] = []
        var i = 0            // base cursor
        var a = 0, b = 0     // hunk indices
        var regionId = 0
        var changeCount = 0


        while i < base.count || a < ho.count || b < ht.count {
            let nextO = a < ho.count ? ho[a].sourceStart : Int.max
            let nextT = b < ht.count ? ht[b].sourceStart : Int.max
            let nextChange = min(nextO, nextT)

            if i < nextChange {
                let end = min(nextChange, base.count)
                if i < end { result.append(contentsOf: Array(base[i..<end])) }
                i = end
                if i >= base.count && a >= ho.count && b >= ht.count { break }
                continue
            }

            // Grow a maximal overlap window covering all ours/theirs hunks that touch it.
            let regionStart = i
            var regionEnd = i
            var touchedOurs = false, touchedTheirs = false
            var grew = true
            while grew {
                grew = false
                while a < ho.count && ho[a].sourceStart <= regionEnd {
                    regionEnd = max(regionEnd, ho[a].sourceEnd)
                    touchedOurs = true; a += 1; grew = true
                }
                while b < ht.count && ht[b].sourceStart <= regionEnd {
                    regionEnd = max(regionEnd, ht[b].sourceEnd)
                    touchedTheirs = true; b += 1; grew = true
                }
            }
            regionEnd = min(max(regionEnd, regionStart), base.count)

            let baseLines = Array(base[regionStart..<regionEnd])
            // Map the base-coordinate region to each side. The start boundary maps to
            // BEFORE any pure insertion sitting exactly at it; the end boundary maps to
            // AFTER it — so a zero-width base region (e.g. add/add, where base is empty)
            // still spans the side's inserted lines instead of collapsing to nothing.
            let oursLines = slice(ours, mapBaseToSide(regionStart, ho, atEnd: false),
                                        mapBaseToSide(regionEnd, ho, atEnd: true))
            let theirsLines = slice(theirs, mapBaseToSide(regionStart, ht, atEnd: false),
                                            mapBaseToSide(regionEnd, ht, atEnd: true))

            let kind: MergeChunk.Kind
            if touchedOurs && touchedTheirs {
                kind = equalLines(oursLines, theirsLines, whitespace) ? .bothSame : .conflict
            } else if touchedOurs {
                kind = .oursOnly
            } else {
                kind = .theirsOnly
            }

            let chunkResult: [String]
            switch kind {
            case .oursOnly: chunkResult = oursLines
            case .theirsOnly: chunkResult = theirsLines
            case .bothSame: chunkResult = oursLines
            // Seed a conflict with the base (JetBrains-style "HELLO from base"), so the
            // Result starts neutral and the user picks a side. Empty base -> seed ours.
            case .conflict: chunkResult = baseLines.isEmpty ? oursLines : baseLines
            case .context: chunkResult = baseLines
            }

            if kind != .conflict { changeCount += 1 }   // "changes" = auto-merged; conflicts counted separately
            if kind == .conflict {
                regions.append(ConflictRegion(
                    id: regionId, start: result.count, length: chunkResult.count,
                    oursLines: oursLines, theirsLines: theirsLines, baseLines: baseLines,
                    resolved: false
                ))
                regionId += 1
            }
            result.append(contentsOf: chunkResult)
            i = regionEnd
        }

        return (result, regions, changeCount)
    }

    /// Remap conflict-region line ranges after the Result text was edited. Any region
    /// whose span was touched (lines changed/removed) is marked resolved.
    static func remap(_ regions: [ConflictRegion], from prev: [String], to new: [String]) -> [ConflictRegion] {
        let ops = LineDiffer.diff(prev, new)
        // Build oldIndex -> newIndex for surviving (equal) lines; nil if the old line was deleted.
        var oldToNew: [Int?] = Array(repeating: nil, count: prev.count)
        var oi = 0, ni = 0
        for op in ops {
            switch op {
            case .equal: if oi < prev.count { oldToNew[oi] = ni }; oi += 1; ni += 1
            case .delete: oi += 1
            case .insert: ni += 1
            }
        }
        return regions.map { r in
            var r = r
            if r.resolved { return r }
            // Every old line of the region still present & contiguous -> untouched.
            let survivors = (r.start..<min(r.end, prev.count)).compactMap { oldToNew[$0] }
            if survivors.count == r.length, let first = survivors.first,
               survivors == Array(first..<(first + r.length)) {
                r.start = first
            } else {
                r.resolved = true   // edited inside the conflict -> user took over
            }
            return r
        }
    }

    // MARK: - helpers

    /// Translate a base line index into the corresponding side (ours/theirs) index by
    /// summing the length delta of every hunk that lies before `baseIdx`. A pure
    /// insertion has a zero-width base range (`sourceStart == sourceEnd`); when it sits
    /// exactly at `baseIdx` it is counted only for the region's END boundary (`atEnd`),
    /// never its start — otherwise the inserted lines get skipped and the slice comes
    /// back empty (the add/add data-loss bug).
    private static func mapBaseToSide(_ baseIdx: Int, _ hunks: [LineHunk], atEnd: Bool) -> Int {
        var delta = 0
        for h in hunks {
            let before = h.sourceEnd < baseIdx
                || (h.sourceEnd == baseIdx && (h.sourceStart < baseIdx || atEnd))
            if before { delta += (h.workingEnd - h.workingStart) - (h.sourceEnd - h.sourceStart) }
        }
        return baseIdx + delta
    }

    private static func slice(_ arr: [String], _ lo: Int, _ hi: Int) -> [String] {
        let l = max(0, min(lo, arr.count)), h = max(l, min(hi, arr.count))
        return Array(arr[l..<h])
    }

    private static func equalLines(_ a: [String], _ b: [String], _ ws: DiffWhitespaceMode) -> Bool {
        guard a.count == b.count else { return false }
        if ws == .doNotIgnore { return a == b }
        return zip(a, b).allSatisfy { ws.normalize($0) == ws.normalize($1) }
    }
}
