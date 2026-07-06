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

// A still-tracked conflict as a line range into the live Result text, so the editor
// can navigate/accept and remap it as the user edits.
struct ConflictRegion: Identifiable {
    let id: Int
    var start: Int          // 0-based first Result line of the region
    var length: Int         // number of Result lines
    let oursLines: [String]
    let theirsLines: [String]
    let baseLines: [String]
    var resolved: Bool
    var end: Int { start + length }
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

        func oursIndex(_ baseIdx: Int) -> Int { mapBaseToSide(baseIdx, ho) }
        func theirsIndex(_ baseIdx: Int) -> Int { mapBaseToSide(baseIdx, ht) }

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
            let oursLines = slice(ours, oursIndex(regionStart), oursIndex(regionEnd))
            let theirsLines = slice(theirs, theirsIndex(regionStart), theirsIndex(regionEnd))

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
            case .conflict: chunkResult = oursLines.isEmpty ? baseLines : oursLines
            case .context: chunkResult = baseLines
            }

            if kind != .conflict { changeCount += 1 }   // "changes" = auto-merged only
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

    private static func mapBaseToSide(_ baseIdx: Int, _ hunks: [LineHunk]) -> Int {
        var delta = 0
        for h in hunks where h.sourceEnd <= baseIdx {
            delta += (h.workingEnd - h.workingStart) - (h.sourceEnd - h.sourceStart)
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
