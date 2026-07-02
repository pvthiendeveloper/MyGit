import Foundation

/// Routes pull-request calls to the right host implementation by hostname.
/// GitHub (github.com + GHE) and Bitbucket Cloud are supported; other hosts
/// throw a clear "unsupported" error.
struct PullRequestRouter: PullRequestRepository {
    private let github: PullRequestRepository
    private let bitbucket: PullRequestRepository

    init(
        github: PullRequestRepository = GitHubPullRequestRepository(),
        bitbucket: PullRequestRepository = BitbucketPullRequestRepository()
    ) {
        self.github = github
        self.bitbucket = bitbucket
    }

    /// True for hosts MyGit can open a PR against (drives the menu gate).
    static func supports(host: String?) -> Bool {
        guard let h = host?.lowercased() else { return false }
        return h.contains("github") || h.contains("bitbucket")
    }

    private func impl(for host: String) throws -> PullRequestRepository {
        let h = host.lowercased()
        if h.contains("bitbucket") { return bitbucket }
        if h.contains("github") { return github }
        throw PullRequestError.unsupportedHost(host)
    }

    func defaultBranch(host: String, owner: String, repo: String, token: String) async throws -> String {
        try await impl(for: host).defaultBranch(host: host, owner: owner, repo: repo, token: token)
    }

    func create(
        host: String, owner: String, repo: String,
        head: String, base: String, title: String, body: String,
        token: String
    ) async throws -> PullRequestInfo {
        try await impl(for: host).create(
            host: host, owner: owner, repo: repo,
            head: head, base: base, title: title, body: body, token: token
        )
    }

    func list(
        host: String, owner: String, repo: String,
        page: Int, token: String
    ) async throws -> PullRequestPage {
        try await impl(for: host).list(host: host, owner: owner, repo: repo, page: page, token: token)
    }

    func detail(
        host: String, owner: String, repo: String,
        number: Int, token: String
    ) async throws -> PullRequestDetail {
        try await impl(for: host).detail(host: host, owner: owner, repo: repo, number: number, token: token)
    }

    func files(
        host: String, owner: String, repo: String,
        number: Int, token: String
    ) async throws -> [PRFileChange] {
        try await impl(for: host).files(host: host, owner: owner, repo: repo, number: number, token: token)
    }

    func commits(
        host: String, owner: String, repo: String,
        number: Int, token: String
    ) async throws -> [PRCommit] {
        try await impl(for: host).commits(host: host, owner: owner, repo: repo, number: number, token: token)
    }

    func commitFiles(
        host: String, owner: String, repo: String,
        sha: String, token: String
    ) async throws -> [PRFileChange] {
        try await impl(for: host).commitFiles(host: host, owner: owner, repo: repo, sha: sha, token: token)
    }
}
