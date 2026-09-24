import Foundation

/// Who last touched one line, from `git blame --porcelain`.
struct BlameLine: Equatable {
    let hash: String          // full sha; all zeros for uncommitted lines
    let author: String
    let email: String
    let date: Date
    let summary: String

    var isUncommitted: Bool { hash.allSatisfy { $0 == "0" } }
    var shortHash: String { String(hash.prefix(7)) }

    /// A `GitCommit` good enough for the commit card (blame has no body,
    /// parents or refs).
    var commit: GitCommit {
        GitCommit(id: hash, author: author, email: email, date: date,
                  parents: [], subject: summary, body: "", refs: [])
    }
}

enum GitBlameParser {
    /// Parses porcelain output into one entry per line of the file, in order.
    /// Commit headers (author, time, summary) are printed only the first time
    /// a commit appears, so they're remembered by hash.
    static func parse(_ output: String) -> [BlameLine] {
        struct Info { var author = "", email = "", time: TimeInterval = 0, summary = "" }
        var infos: [String: Info] = [:]
        var lines: [BlameLine] = []
        var current: String?

        for raw in output.split(separator: "\n", omittingEmptySubsequences: false) {
            if raw.hasPrefix("\t") {
                // The line's content ends each entry.
                guard let hash = current else { continue }
                let info = infos[hash] ?? Info()
                lines.append(BlameLine(hash: hash, author: info.author, email: info.email,
                                       date: Date(timeIntervalSince1970: info.time), summary: info.summary))
                current = nil
                continue
            }
            let line = String(raw)
            if current == nil {
                // "<40-hex sha> <orig line> <final line> [<group size>]"
                let sha = line.prefix { $0 != " " }
                if sha.count == 40, sha.allSatisfy(\.isHexDigit) {
                    current = String(sha)
                    if infos[current!] == nil { infos[current!] = Info() }
                }
                continue
            }
            guard let hash = current else { continue }
            func value(_ key: String) -> String? {
                line.hasPrefix(key + " ") ? String(line.dropFirst(key.count + 1)) : nil
            }
            if let v = value("author") { infos[hash]?.author = v }
            else if let v = value("author-mail") { infos[hash]?.email = v.trimmingCharacters(in: CharacterSet(charactersIn: "<>")) }
            else if let v = value("author-time") { infos[hash]?.time = TimeInterval(v) ?? 0 }
            else if let v = value("summary") { infos[hash]?.summary = v }
        }
        return lines
    }
}
