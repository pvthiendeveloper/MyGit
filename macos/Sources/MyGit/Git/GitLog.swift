import Foundation

struct GitCommit: Identifiable, Hashable {
    let id: String  // full sha
    let author: String
    let email: String
    let date: Date
    let parents: [String]
    let subject: String
    let body: String

    var hash: String { id }
    var shortHash: String { String(id.prefix(7)) }
}

enum GitLogParser {
    /// Use US (0x1F) as field separator, RS (0x1E) as record separator —
    /// neither appears in commit subjects or author names in practice.
    static let format = "%H%x1f%an%x1f%ae%x1f%aI%x1f%P%x1f%s%x1f%b%x1e"

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
                return GitCommit(
                    id: fields[0],
                    author: fields[1],
                    email: fields[2],
                    date: date,
                    parents: parents,
                    subject: fields[5],
                    body: fields[6]
                )
            }
    }
}
