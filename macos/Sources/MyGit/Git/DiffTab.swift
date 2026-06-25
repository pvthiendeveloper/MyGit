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

    var title: String { (path as NSString).lastPathComponent }

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
