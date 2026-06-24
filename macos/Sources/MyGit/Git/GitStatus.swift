import Foundation

enum FileChangeKind {
    case added, modified, deleted, renamed, copied, untracked, conflict
}

struct FileChange: Identifiable, Hashable {
    var id: String { (oldPath.map { "\($0)→" } ?? "") + path }
    let path: String
    let oldPath: String?
    let indexStatus: Character
    let worktreeStatus: Character

    var isUntracked: Bool { indexStatus == "?" }
    var isStaged: Bool { !isUntracked && indexStatus != " " }
    var isConflicted: Bool { indexStatus == "U" || worktreeStatus == "U" }

    var kind: FileChangeKind {
        if isUntracked { return .untracked }
        if isConflicted { return .conflict }
        let s = isStaged ? indexStatus : worktreeStatus
        switch s {
        case "A": return .added
        case "M": return .modified
        case "D": return .deleted
        case "R": return .renamed
        case "C": return .copied
        default: return .modified
        }
    }

    var glyph: String {
        switch kind {
        case .added, .untracked: return "+"
        case .modified: return "M"
        case .deleted: return "−"
        case .renamed: return "R"
        case .copied: return "C"
        case .conflict: return "!"
        }
    }
}

struct GitStatusSummary {
    let branch: String?
    let upstream: String?
    let ahead: Int
    let behind: Int
    let changes: [FileChange]
}

enum GitStatusParser {
    /// Parses `git status --porcelain=v1 -z --branch` output.
    /// Records are NUL-terminated. Rename/copy entries are followed by an
    /// extra NUL-separated old-path record.
    static func parse(_ porcelain: String) -> GitStatusSummary {
        var branch: String? = nil
        var upstream: String? = nil
        var ahead = 0
        var behind = 0
        var changes: [FileChange] = []

        let records = porcelain.split(separator: "\0", omittingEmptySubsequences: false).map(String.init)
        var i = 0
        while i < records.count {
            let rec = records[i]
            if rec.isEmpty { i += 1; continue }

            if rec.hasPrefix("## ") {
                let info = String(rec.dropFirst(3))
                parseHeader(info, branch: &branch, upstream: &upstream, ahead: &ahead, behind: &behind)
                i += 1
                continue
            }

            let scalars = Array(rec)
            guard scalars.count >= 4 else { i += 1; continue }
            let x = scalars[0]
            let y = scalars[1]
            let path = String(scalars[3...])

            var oldPath: String? = nil
            if x == "R" || x == "C" || y == "R" || y == "C" {
                i += 1
                if i < records.count {
                    oldPath = records[i]
                }
            }

            changes.append(FileChange(
                path: path,
                oldPath: oldPath,
                indexStatus: x,
                worktreeStatus: y
            ))
            i += 1
        }

        return GitStatusSummary(
            branch: branch,
            upstream: upstream,
            ahead: ahead,
            behind: behind,
            changes: changes
        )
    }

    private static func parseHeader(
        _ info: String,
        branch: inout String?,
        upstream: inout String?,
        ahead: inout Int,
        behind: inout Int
    ) {
        // Examples:
        //   "main"
        //   "main...origin/main"
        //   "main...origin/main [ahead 1, behind 2]"
        //   "HEAD (no branch)"
        //   "No commits yet on main"
        let noCommitsPrefix = "No commits yet on "
        if info.hasPrefix(noCommitsPrefix) {
            let rest = String(info.dropFirst(noCommitsPrefix.count))
            branch = rest.components(separatedBy: " ").first
            return
        }
        let head = info.components(separatedBy: " ").first ?? ""
        let parts = head.components(separatedBy: "...")
        if parts.first == "HEAD" && info.contains("no branch") {
            branch = nil
        } else {
            branch = parts.first
        }
        if parts.count > 1 { upstream = parts[1] }

        if let r = info.range(of: "ahead "),
           let end = info[r.upperBound...].firstIndex(where: { $0 == "," || $0 == "]" }) {
            ahead = Int(info[r.upperBound..<end]) ?? 0
        }
        if let r = info.range(of: "behind "),
           let end = info[r.upperBound...].firstIndex(where: { $0 == "," || $0 == "]" }) {
            behind = Int(info[r.upperBound..<end]) ?? 0
        }
    }
}
