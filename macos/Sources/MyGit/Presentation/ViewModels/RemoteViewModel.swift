import Foundation

@MainActor
final class RemoteViewModel: ObservableObject {
    @Published var lastFetchedAt: Date?
    @Published var noUpstreamBranch: String?
    @Published var missingRemoteForBranch: String?
    /// URL of the most recently opened pull request (drives a "View PR" affordance).
    @Published var lastPullRequestURL: URL?

    private let git: GitRepository
    private let account: AccountViewModel
    private let pullRequests: PullRequestRepository
    private let main: MainViewModel
    private let repoSource: () -> Repository?
    private let onFinished: () async -> Void
    private let currentBranch: () -> String?

    init(
        git: GitRepository,
        account: AccountViewModel,
        pullRequests: PullRequestRepository,
        main: MainViewModel,
        repoSource: @escaping () -> Repository?,
        currentBranch: @escaping () -> String?,
        onFinished: @escaping () async -> Void
    ) {
        self.git = git
        self.account = account
        self.pullRequests = pullRequests
        self.main = main
        self.repoSource = repoSource
        self.currentBranch = currentBranch
        self.onFinished = onFinished
    }

    func fetchOrigin() async {
        await runRemote {
            try await self.git.fetch(at: $0, auth: self.account.currentAuth())
        }
        lastFetchedAt = Date()
    }

    func pull() async {
        await runRemote {
            try await self.git.pull(at: $0, auth: self.account.currentAuth())
        }
    }

    func push() async {
        guard let branch = currentBranch() else { return }
        await runRemoteHandlingUpstream(args: ["push"], branchName: branch)
    }

    func forcePush() async {
        guard let branch = currentBranch() else { return }
        await runRemoteHandlingUpstream(
            args: ["push", "--force-with-lease", "origin", branch],
            branchName: branch
        )
    }

    func pushWithUpstream(branch: String) async {
        await runRemote {
            try await self.git.push(
                at: $0,
                args: ["push", "--set-upstream", "origin", branch],
                auth: self.account.currentAuth()
            )
        }
    }

    func pushBranch(_ branch: GitBranch) async {
        await runRemoteHandlingUpstream(args: ["push", "origin", branch.name], branchName: branch.name)
    }

    /// Push commits up to `sha` (inclusive) onto the current branch on origin.
    func pushUpToCommit(_ sha: String) async {
        guard let branch = currentBranch() else { return }
        await runRemoteHandlingUpstream(
            args: ["push", "origin", "\(sha):\(branch)"],
            branchName: branch
        )
    }

    func addOriginAndPush(url: String, branch: String) async {
        guard let repo = repoSource() else { return }
        main.isBusy = true
        defer { main.isBusy = false }
        do {
            try await git.addRemote(name: "origin", url: url, at: repo.url)
            try await git.push(
                at: repo.url,
                args: ["push", "--set-upstream", "origin", branch],
                auth: account.currentAuth()
            )
            await onFinished()
        } catch {
            main.errorMessage = error.localizedDescription
        }
    }

    // MARK: - Pull requests

    /// The current branch name — the head for a new pull request.
    var pullRequestHead: String? { currentBranch() }

    /// The GitHub account (host/owner/repo) for the current repo, if any.
    var pullRequestAccount: GitAccount? { account.account }

    /// Fetch the repo's default branch to prefill the PR base. Nil on any error
    /// (no token, non-GitHub, network) — the composer falls back to a text field.
    func defaultBaseBranch() async -> String? {
        guard let acc = account.account,
              let host = acc.host, let owner = acc.owner, let name = acc.repo,
              let token = account.storedToken() else { return nil }
        return try? await pullRequests.defaultBranch(host: host, owner: owner, repo: name, token: token)
    }

    /// Push the current branch (publishing/updating origin), then open a pull
    /// request from it into `base`. Returns the PR URL on success (also stored
    /// in `lastPullRequestURL`); nil on failure with `main.errorMessage` set.
    @discardableResult
    func createPullRequest(title: String, body: String, base: String) async -> URL? {
        guard let repo = repoSource() else { return nil }
        guard let acc = account.account,
              let host = acc.host, let owner = acc.owner, let name = acc.repo else {
            main.errorMessage = PullRequestError.noRepository.localizedDescription
            return nil
        }
        guard let head = currentBranch() else {
            main.errorMessage = PullRequestError.noBranch.localizedDescription
            return nil
        }
        guard let token = account.storedToken() else {
            main.errorMessage = PullRequestError.missingToken(host).localizedDescription
            return nil
        }
        main.isBusy = true
        defer { main.isBusy = false }
        await Task.yield()
        do {
            // Ensure the head branch exists on origin and is up to date. A no-op
            // when already published + pushed; publishes/pushes otherwise.
            try await git.push(
                at: repo.url,
                args: ["push", "--set-upstream", "origin", head],
                auth: account.currentAuth()
            )
            let info = try await pullRequests.create(
                host: host, owner: owner, repo: name,
                head: head, base: base, title: title, body: body,
                token: token
            )
            lastPullRequestURL = info.url
            await onFinished()
            return info.url
        } catch {
            main.errorMessage = error.localizedDescription
            return nil
        }
    }

    private func runRemote(_ op: @escaping (URL) async throws -> Void) async {
        guard let repo = repoSource() else { return }
        main.isBusy = true
        defer { main.isBusy = false }
        // Let SwiftUI paint the spinning state before any blocking main-actor
        // work (e.g. synchronous keychain read in currentAuth()).
        await Task.yield()
        do {
            try await op(repo.url)
            await onFinished()
        } catch {
            main.errorMessage = error.localizedDescription
        }
    }

    private func runRemoteHandlingUpstream(args: [String], branchName: String) async {
        guard let repo = repoSource() else { return }
        main.isBusy = true
        defer { main.isBusy = false }
        // Let SwiftUI paint the spinning state before the synchronous keychain
        // read in currentAuth() blocks the main actor.
        await Task.yield()
        do {
            try await git.push(at: repo.url, args: args, auth: account.currentAuth())
            await onFinished()
        } catch let err as GitError {
            let msg = err.localizedDescription
            if msg.contains("has no upstream branch") {
                noUpstreamBranch = branchName
            } else if msg.contains("No configured push destination")
                || msg.contains("does not appear to be a git repository")
                || msg.contains("'origin' does not appear to be a git repository") {
                missingRemoteForBranch = branchName
            } else {
                main.errorMessage = msg
            }
        } catch {
            main.errorMessage = error.localizedDescription
        }
    }
}
