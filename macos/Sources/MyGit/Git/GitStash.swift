import Foundation

/// One entry from `git stash list`. `index` is the stack position (0 = most recent);
/// `ref` is the addressable form (`stash@{0}`). `branch`/`message` come from the reflog
/// subject ("WIP on main: <sha> <msg>" or "On main: <msg>").
struct GitStash: Identifiable, Hashable {
    let index: Int
    let hash: String
    let date: Date
    let branch: String?
    let message: String

    var id: Int { index }
    var ref: String { "stash@{\(index)}" }
}

enum GitStashParser {
    /// gd = selector (stash@{n}), H = full sha, aI = ISO date, gs = reflog subject.
    static let format = "%gd%x1f%H%x1f%aI%x1f%gs"

    static func parse(_ output: String) -> [GitStash] {
        let iso = ISO8601DateFormatter()
        iso.formatOptions = [.withInternetDateTime]
        return output.split(separator: "\n").compactMap { line -> GitStash? in
            let f = line.components(separatedBy: "\u{1f}")
            guard f.count >= 4 else { return nil }
            let (branch, message) = parseSubject(f[3])
            return GitStash(
                index: parseIndex(f[0]) ?? 0,
                hash: f[1],
                date: iso.date(from: f[2]) ?? Date(timeIntervalSince1970: 0),
                branch: branch,
                message: message
            )
        }
    }

    /// "stash@{2}" -> 2.
    private static func parseIndex(_ selector: String) -> Int? {
        guard let open = selector.firstIndex(of: "{"),
              let close = selector.firstIndex(of: "}"), open < close else { return nil }
        return Int(selector[selector.index(after: open)..<close])
    }

    /// "WIP on main: 1a2b3c4 Tidy up" -> (branch: "main", message: "1a2b3c4 Tidy up").
    private static func parseSubject(_ subject: String) -> (String?, String) {
        var s = subject
        for prefix in ["WIP on ", "On "] where s.hasPrefix(prefix) {
            s.removeFirst(prefix.count)
            break
        }
        if let r = s.range(of: ": ") {
            let branch = String(s[..<r.lowerBound])
            let msg = String(s[r.upperBound...])
            return (branch.isEmpty ? nil : branch, msg.isEmpty ? subject : msg)
        }
        return (nil, subject)
    }
}
