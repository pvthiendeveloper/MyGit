import Foundation

/// Creates pull requests on a git host (GitHub / GitHub Enterprise) via REST.
/// Not a git-CLI operation — mirrors `CommitMessageRepository`: a domain
/// protocol with a REST-backed implementation in `Data/`.
protocol PullRequestRepository: Sendable {
    /// The repository's default branch (used to prefill the PR base).
    func defaultBranch(host: String, owner: String, repo: String, token: String) async throws -> String

    /// Open a pull request from `head` into `base`. Returns the created PR.
    /// `reviewers` are host-specific identifiers (GitHub: usernames; Bitbucket:
    /// account UUIDs `{...}` or account ids) — best-effort, a bad reviewer must
    /// not fail the PR itself.
    func create(
        host: String, owner: String, repo: String,
        head: String, base: String, title: String, body: String,
        reviewers: [String],
        token: String
    ) async throws -> PullRequestInfo

    /// A page of the repo's pull requests (across all states), newest first.
    /// `page` is 1-based.
    func list(
        host: String, owner: String, repo: String,
        page: Int, token: String
    ) async throws -> PullRequestPage

    /// Full detail (description + reviewers + best-effort checks) for one PR.
    func detail(
        host: String, owner: String, repo: String,
        number: Int, token: String
    ) async throws -> PullRequestDetail

    /// Files changed in the PR.
    func files(
        host: String, owner: String, repo: String,
        number: Int, token: String
    ) async throws -> [PRFileChange]

    /// Commits in the PR.
    func commits(
        host: String, owner: String, repo: String,
        number: Int, token: String
    ) async throws -> [PRCommit]

    /// Files changed by a single commit (for the Commits tab's commit detail).
    func commitFiles(
        host: String, owner: String, repo: String,
        sha: String, token: String
    ) async throws -> [PRFileChange]

    /// The user the stored token authenticates as — used to match the current
    /// user against a PR's reviewers so the Approve/Request-changes toggle knows
    /// its own state.
    func currentUser(host: String, token: String) async throws -> PRUser

    /// Submit (or withdraw) a reviewer decision on a PR. Does not change the PR's
    /// open/closed lifecycle — only the current user's review standing.
    func review(
        host: String, owner: String, repo: String,
        number: Int, action: PRReviewAction, token: String
    ) async throws

    /// Change a PR's lifecycle (merge / decline / reopen / draft toggle). Author
    /// actions — the caller gates these on "is this my PR" and host support.
    func lifecycle(
        host: String, owner: String, repo: String,
        number: Int, action: PRLifecycleAction, token: String
    ) async throws

    /// Best-effort merge-readiness checklist (approvals, builds, tasks, …).
    /// Empty when the host exposes nothing readable. Some rows are informational
    /// only (`blocking == false`) when the exact policy can't be read.
    func mergeChecks(
        host: String, owner: String, repo: String,
        number: Int, token: String
    ) async throws -> [PRMergeCheck]

    /// Fetch raw bytes from a host API URL with the host's auth applied (used to
    /// load image blobs for in-app preview).
    func download(host: String, url: URL, token: String) async throws -> Data
}

/// The authenticated user, with the host-stable identity used to match reviews.
struct PRUser: Sendable, Hashable {
    /// GitHub login / Bitbucket account UUID — matches `PRParticipant.id`.
    let id: String
    let name: String
}

/// A reviewer decision the current user can apply to a PR (all reversible).
enum PRReviewAction: Sendable {
    case approve, unapprove
    case requestChanges, unrequestChanges
}

/// A lifecycle change the PR author can apply. Not all hosts support every case
/// (e.g. Bitbucket can't reopen a declined PR) — the ViewModel gates which are
/// offered per host + state.
enum PRLifecycleAction: Sendable {
    case merge, decline, reopen, markDraft, markReady
}

struct PullRequestInfo: Equatable {
    let number: Int
    let url: URL
}

enum PullRequestError: LocalizedError {
    case missingToken(String)
    case noRepository
    case noBranch
    case unsupportedHost(String)
    case httpError(Int, String)
    case badResponse(String)

    var errorDescription: String? {
        switch self {
        case .missingToken(let host):
            return "No access token stored for \(host). Add a token in the account panel first."
        case .noRepository:
            return "No supported remote (GitHub / Bitbucket) detected for this repo."
        case .noBranch:
            return "No current branch to open a pull request from."
        case .unsupportedHost(let host):
            return "Opening pull requests isn't supported for \(host)."
        case .httpError(let code, let body):
            return "Pull request request failed (HTTP \(code)): \(body)"
        case .badResponse(let s):
            return "Host returned an unexpected response: \(s)"
        }
    }
}
