import Foundation

/// A ref decorating a commit (from git's `%D`), used for inline badges.
struct GitRef: Hashable {
    enum Kind { case head, localBranch, remoteBranch, tag }
    let kind: Kind
    let name: String      // display name, e.g. "main", "origin/main", "v1.2"
    var isHead: Bool = false
}

struct GitCommit: Identifiable, Hashable {
    let id: String  // full sha
    let author: String
    let email: String
    let date: Date
    let parents: [String]
    let subject: String
    let body: String
    let refs: [GitRef]

    var hash: String { id }
    var shortHash: String { String(id.prefix(7)) }
}

enum GitLogParser {
    /// Use US (0x1F) as field separator, RS (0x1E) as record separator —
    /// neither appears in commit subjects or author names in practice.
    /// Trailing `%D` carries ref decorations (populated when run with
    /// `--decorate=full`); empty for plain `log` calls.
    static let format = "%H%x1f%an%x1f%ae%x1f%aI%x1f%P%x1f%s%x1f%b%x1f%D%x1e"

    static func parse(_ output: String) -> [GitCommit] {
        let iso = ISO8601DateFormatter()
        iso.formatOptions = [.withInternetDateTime]

        return output
            .split(separator: "\u{1e}", omittingEmptySubsequences: true)
            .compactMap { rec -> GitCommit? in
                let trimmed = rec.trimmingCharacters(in: .whitespacesAndNewlines)
                let fields = trimmed
                    .split(separator: "\u{1f}", omittingEmptySubsequences: false)
                    .map(String.init)
                guard fields.count >= 7 else { return nil }
                let date = iso.date(from: fields[3]) ?? Date()
                let parents = fields[4].split(separator: " ").map(String.init)
                let refs = fields.count >= 8 ? parseRefs(fields[7]) : []
                return GitCommit(
                    id: fields[0],
                    author: fields[1],
                    email: fields[2],
                    date: date,
                    parents: parents,
                    subject: fields[5],
                    body: fields[6],
                    refs: refs
                )
            }
    }

    /// Parse a `%D` decoration field. Expects full ref names (`--decorate=full`)
    /// so `refs/heads/` vs `refs/remotes/` vs `refs/tags/` disambiguate kind.
    static func parseRefs(_ field: String) -> [GitRef] {
        let trimmed = field.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return [] }
        return trimmed.split(separator: ",").compactMap { raw -> GitRef? in
            let s = raw.trimmingCharacters(in: .whitespaces)
            if s == "HEAD" {
                return GitRef(kind: .head, name: "HEAD")
            }
            if let arrow = s.range(of: " -> ") {
                // "HEAD -> refs/heads/main"
                let target = String(s[arrow.upperBound...])
                return GitRef(kind: .localBranch, name: shortName(target), isHead: true)
            }
            if s.hasPrefix("tag: ") {
                return GitRef(kind: .tag, name: shortName(String(s.dropFirst(5))))
            }
            if s.hasPrefix("refs/remotes/") {
                let name = shortName(s)
                if name.hasSuffix("/HEAD") { return nil }   // symbolic ref, not a branch
                return GitRef(kind: .remoteBranch, name: name)
            }
            if s.hasPrefix("refs/tags/") {
                return GitRef(kind: .tag, name: shortName(s))
            }
            return GitRef(kind: .localBranch, name: shortName(s))
        }
    }

    private static func shortName(_ s: String) -> String {
        for p in ["refs/heads/", "refs/remotes/", "refs/tags/"] {
            if s.hasPrefix(p) { return String(s.dropFirst(p.count)) }
        }
        return s
    }
}
