import Foundation
import SwiftUI

/// Lifecycle state of a pull request, normalized across GitHub and Bitbucket.
enum PullRequestState: Hashable {
    case open, merged, declined, superseded, draft, closed

    var label: String {
        switch self {
        case .open:       return "OPEN"
        case .merged:     return "MERGED"
        case .declined:   return "DECLINED"
        case .superseded: return "SUPERSEDED"
        case .draft:      return "DRAFT"
        case .closed:     return "CLOSED"
        }
    }

    var color: Color {
        switch self {
        case .open:       return .green
        case .merged:     return .purple
        case .declined:   return .red
        case .superseded: return .orange
        case .draft:      return .secondary
        case .closed:     return .red
        }
    }
}

/// A reviewer/participant on a pull request.
struct PRParticipant: Hashable {
    let name: String
    let avatarURL: URL?
    let isReviewer: Bool
    let approved: Bool
}

/// One row in the pull-request list.
struct PullRequestSummary: Identifiable, Hashable {
    let id: Int              // PR number — unique within a repo
    var number: Int { id }
    let title: String
    let authorName: String
    let authorAvatarURL: URL?
    let sourceBranch: String
    let destBranch: String
    let state: PullRequestState
    let isDraft: Bool
    let commentCount: Int
    let updatedAt: Date?
    let url: URL
}

/// Aggregate CI/check status shown in the PR detail (best-effort per host).
struct PRChecksSummary: Hashable {
    let passed: Int
    let total: Int
    let buildsPassed: Int
    let buildsTotal: Int
}

/// Full pull-request detail (essentials + reviewers).
struct PullRequestDetail: Hashable {
    let summary: PullRequestSummary
    let description: String
    let createdAt: Date?
    let participants: [PRParticipant]
    let checks: PRChecksSummary?     // nil when unavailable
    let closedBy: String?

    var approvals: Int { participants.filter { $0.approved }.count }
    var reviewers: [PRParticipant] { participants.filter { $0.isReviewer } }
}

/// One page of a PR list plus whether more pages exist.
struct PullRequestPage {
    let items: [PullRequestSummary]
    let hasMore: Bool
}

/// A file changed in a PR (Files-changed tab).
struct PRFileChange: Identifiable, Hashable {
    enum Status: Hashable { case added, modified, removed, renamed }
    var id: String { path }
    let path: String
    let oldPath: String?
    let status: Status
    let additions: Int
    let deletions: Int
    /// Unified per-file patch, when the host provides one (GitHub). nil → counts only.
    let patch: String?

    var statusLabel: String {
        switch status {
        case .added: return "A"
        case .modified: return "M"
        case .removed: return "D"
        case .renamed: return "R"
        }
    }
    var statusColor: Color {
        switch status {
        case .added: return .green
        case .modified: return .orange
        case .removed: return .red
        case .renamed: return .blue
        }
    }
}

/// A commit in a PR (Commits tab).
struct PRCommit: Identifiable, Hashable {
    let id: String          // full hash
    let message: String
    let author: String
    let date: Date?
    var shortHash: String { String(id.prefix(7)) }
    var subject: String { message.split(separator: "\n").first.map(String.init) ?? message }
}

/// Shared ISO-8601 parsing for host timestamps. GitHub uses plain internet
/// date-time (`2024-01-02T03:04:05Z`); Bitbucket includes fractional seconds
/// (`...05.123456+00:00`), so try both.
enum PRDate {
    private static let plain: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        return f
    }()
    private static let fractional: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()

    static func parse(_ s: String?) -> Date? {
        guard let s, !s.isEmpty else { return nil }
        return fractional.date(from: s) ?? plain.date(from: s)
    }

    private static let relative: RelativeDateTimeFormatter = {
        let f = RelativeDateTimeFormatter()
        f.unitsStyle = .full
        return f
    }()

    static func relativeLabel(_ date: Date?) -> String {
        guard let date else { return "" }
        return relative.localizedString(for: date, relativeTo: Date())
    }
}
