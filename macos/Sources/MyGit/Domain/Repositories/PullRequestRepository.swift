import Foundation

/// Creates pull requests on a git host (GitHub / GitHub Enterprise) via REST.
/// Not a git-CLI operation — mirrors `CommitMessageRepository`: a domain
/// protocol with a REST-backed implementation in `Data/`.
protocol PullRequestRepository: Sendable {
    /// The repository's default branch (used to prefill the PR base).
    func defaultBranch(host: String, owner: String, repo: String, token: String) async throws -> String

    /// Open a pull request from `head` into `base`. Returns the created PR.
    func create(
        host: String, owner: String, repo: String,
        head: String, base: String, title: String, body: String,
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
