import Foundation

struct LineHunk: Identifiable, Hashable {
    let id: Int
    let sourceStart: Int
    let sourceEnd: Int
    let workingStart: Int
    let workingEnd: Int
    let sourceLines: [String]
    let workingLines: [String]

    var kind: Kind {
        if sourceLines.isEmpty { return .addition }
        if workingLines.isEmpty { return .deletion }
        return .modification
    }

    enum Kind { case addition, deletion, modification }
}

enum LineDiffer {
    enum Op { case equal(String); case delete(String); case insert(String) }

    static let maxLines = 6000

    static func diff(_ a: [String], _ b: [String]) -> [Op] {
        let n = a.count, m = b.count
        if n > maxLines || m > maxLines {
            var ops: [Op] = []
            ops.reserveCapacity(n + m)
            for line in a { ops.append(.delete(line)) }
            for line in b { ops.append(.insert(line)) }
            return ops
        }
        if n == 0 { return b.map { .insert($0) } }
        if m == 0 { return a.map { .delete($0) } }

        var dp = Array(repeating: Array(repeating: 0, count: m + 1), count: n + 1)
        for i in 1...n {
            for j in 1...m {
                if a[i-1] == b[j-1] {
                    dp[i][j] = dp[i-1][j-1] + 1
                } else {
                    dp[i][j] = max(dp[i-1][j], dp[i][j-1])
                }
            }
        }
        var ops: [Op] = []
        var i = n, j = m
        while i > 0 && j > 0 {
            if a[i-1] == b[j-1] {
                ops.append(.equal(a[i-1])); i -= 1; j -= 1
            } else if dp[i-1][j] >= dp[i][j-1] {
                ops.append(.delete(a[i-1])); i -= 1
            } else {
                ops.append(.insert(b[j-1])); j -= 1
            }
        }
        while i > 0 { ops.append(.delete(a[i-1])); i -= 1 }
        while j > 0 { ops.append(.insert(b[j-1])); j -= 1 }
        return ops.reversed()
    }

    static func hunks(source: [String], working: [String], whitespace: DiffWhitespaceMode = .doNotIgnore) -> [LineHunk] {
        let srcCmp = whitespace == .doNotIgnore ? source : source.map { whitespace.normalize($0) }
        let wrkCmp = whitespace == .doNotIgnore ? working : working.map { whitespace.normalize($0) }
        let ops = diff(srcCmp, wrkCmp)
        var result: [LineHunk] = []
        var i = 0, j = 0, k = 0, idx = 0
        while k < ops.count {
            if case .equal = ops[k] {
                i += 1; j += 1; k += 1
                continue
            }
            let sStart = i, wStart = j
            var sLines: [String] = [], wLines: [String] = []
            loop: while k < ops.count {
                switch ops[k] {
                case .equal:
                    break loop
                case .delete:
                    if i < source.count { sLines.append(source[i]) }
                    i += 1; k += 1
                case .insert:
                    if j < working.count { wLines.append(working[j]) }
                    j += 1; k += 1
                }
            }
            result.append(LineHunk(
                id: idx,
                sourceStart: sStart,
                sourceEnd: i,
                workingStart: wStart,
                workingEnd: j,
                sourceLines: sLines,
                workingLines: wLines
            ))
            idx += 1
        }
        return result
    }
}
