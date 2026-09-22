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
        reviewers: [String],
        token: String
    ) async throws -> PullRequestInfo {
        try await impl(for: host).create(
            host: host, owner: owner, repo: repo,
            head: head, base: base, title: title, body: body,
            reviewers: reviewers, token: token
        )
    }

    func defaultReviewers(host: String, owner: String, repo: String, token: String) async throws -> [PRUser] {
        try await impl(for: host).defaultReviewers(host: host, owner: owner, repo: repo, token: token)
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

    func currentUser(host: String, token: String) async throws -> PRUser {
        try await impl(for: host).currentUser(host: host, token: token)
    }

    func review(
        host: String, owner: String, repo: String,
        number: Int, action: PRReviewAction, token: String
    ) async throws {
        try await impl(for: host).review(
            host: host, owner: owner, repo: repo, number: number, action: action, token: token
        )
    }

    func lifecycle(
        host: String, owner: String, repo: String,
        number: Int, action: PRLifecycleAction, token: String
    ) async throws {
        try await impl(for: host).lifecycle(
            host: host, owner: owner, repo: repo, number: number, action: action, token: token
        )
    }

    func mergeChecks(
        host: String, owner: String, repo: String,
        number: Int, token: String
    ) async throws -> [PRMergeCheck] {
        try await impl(for: host).mergeChecks(
            host: host, owner: owner, repo: repo, number: number, token: token
        )
    }

    func download(host: String, url: URL, token: String) async throws -> Data {
        try await impl(for: host).download(host: host, url: url, token: token)
    }
}
