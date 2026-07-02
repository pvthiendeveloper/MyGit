import Foundation

enum DiffViewerMode: Hashable, CaseIterable {
    case sideBySide
    case unified

    var label: String {
        switch self {
        case .sideBySide: return "Side-by-side viewer"
        case .unified: return "Unified viewer"
        }
    }
}

enum DiffWhitespaceMode: Hashable, CaseIterable {
    case doNotIgnore
    case trimTrailing
    case ignoreChanges
    case ignoreAll

    var label: String {
        switch self {
        case .doNotIgnore: return "Do not ignore"
        case .trimTrailing: return "Trim trailing"
        case .ignoreChanges: return "Ignore whitespace changes"
        case .ignoreAll: return "Ignore all whitespace"
        }
    }

    func normalize(_ s: String) -> String {
        switch self {
        case .doNotIgnore:
            return s
        case .trimTrailing:
            var idx = s.endIndex
            while idx > s.startIndex {
                let prev = s.index(before: idx)
                if !s[prev].isWhitespace { break }
                idx = prev
            }
            return String(s[..<idx])
        case .ignoreChanges:
            return s.split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
        case .ignoreAll:
            return s.filter { !$0.isWhitespace }
        }
    }
}

enum DiffHighlightMode: Hashable, CaseIterable {
    case none
    case lines
    case words

    var label: String {
        switch self {
        case .none: return "No highlighting"
        case .lines: return "Highlight lines"
        case .words: return "Highlight words"
        }
    }
}

struct DiffTab: Identifiable, Hashable {
    let id = UUID()
    let commitHash: String
    let commitShortHash: String
    let path: String
    let mode: Mode

    /// When set, the two sides are supplied directly (reconstructed from a patch)
    /// instead of being read from local git. Used for remote PR files, which have
    /// no local working copy. The tab is read-only in this case.
    var embedded: Embedded? = nil

    var title: String { (path as NSString).lastPathComponent }

    /// Pre-built diff content + side labels for an `embedded` (patch-backed) tab.
    struct Embedded: Hashable {
        let dedupKey: String
        let leftText: String
        let rightText: String
        let leftLabel: String
        let rightLabel: String
    }

    /// Reconstruct old/new file text from a parsed unified patch and wrap it in an
    /// embedded, read-only diff tab. Only the patched regions are present (a remote
    /// patch omits unchanged context), which is exactly what a review shows.
    static func patchBacked(
        dedupKey: String,
        path: String,
        leftLabel: String,
        rightLabel: String,
        diff: FileDiff
    ) -> DiffTab {
        var left: [String] = []
        var right: [String] = []
        for line in diff.lines {
            switch line.kind {
            case .context:
                left.append(line.text); right.append(line.text)
            case .deletion:
                left.append(line.text)
            case .addition:
                right.append(line.text)
            case .header, .hunkHeader:
                break
            }
        }
        return DiffTab(
            commitHash: "",
            commitShortHash: "",
            path: path,
            mode: .commitVsParent,
            embedded: Embedded(
                dedupKey: dedupKey,
                leftText: left.joined(separator: "\n"),
                rightText: right.joined(separator: "\n"),
                leftLabel: leftLabel,
                rightLabel: rightLabel
            )
        )
    }

    enum Mode: Hashable {
        case commitVsParent
        case commitVsWorking
        case parentVsWorking

        var rightIsEditable: Bool {
            switch self {
            case .commitVsParent: return false
            case .commitVsWorking, .parentVsWorking: return true
            }
        }

        var label: String {
            switch self {
            case .commitVsParent: return "Commit"
            case .commitVsWorking: return "vs Local"
            case .parentVsWorking: return "Before vs Local"
            }
        }
    }
}
