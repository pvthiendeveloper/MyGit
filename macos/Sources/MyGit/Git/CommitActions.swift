import Foundation

/// Mode for `git reset` to a commit.
enum GitResetMode: String, CaseIterable {
    case soft, mixed, hard
    var flag: String { "--\(rawValue)" }
    var label: String {
        switch self {
        case .soft: return "Soft (keep staged + working)"
        case .mixed: return "Mixed (keep working, unstage)"
        case .hard: return "Hard (discard all)"
        }
    }
}

/// One line of a `git rebase -i` todo list.
enum RebaseStep {
    case pick(String)
    case reword(String, String)   // sha, new message
    case fixup(String)
    case squash(String)
    case drop(String)

    /// The todo-list verb + short sha git expects (oldest commit first).
    var todoLine: String {
        switch self {
        case .pick(let s):     return "pick \(s)"
        case .reword(let s, _): return "reword \(s)"
        case .fixup(let s):    return "fixup \(s)"
        case .squash(let s):   return "squash \(s)"
        case .drop(let s):     return "drop \(s)"
        }
    }

    var rewordMessage: String? {
        if case let .reword(_, m) = self { return m }
        return nil
    }
}

/// A row in the interactive-rebase editor sheet.
struct RebaseRow: Identifiable {
    enum Action: String, CaseIterable, Identifiable {
        case pick, reword, squash, fixup, drop
        var id: String { rawValue }
    }
    let commit: GitCommit
    var action: Action = .pick
    var id: String { commit.id }
}
