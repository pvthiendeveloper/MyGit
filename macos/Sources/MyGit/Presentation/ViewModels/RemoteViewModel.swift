import Foundation

@MainActor
final class RemoteViewModel: ObservableObject {
    @Published var lastFetchedAt: Date?
    @Published var noUpstreamBranch: String?
    @Published var missingRemoteForBranch: String?
    /// URL of the most recently opened pull request (drives a "View PR" affordance).
    @Published var lastPullRequestURL: URL?
    /// Set when a pull can't fast-forward because the branch has diverged; the
    /// toolbar then asks whether to merge or rebase.
    @Published var pendingDivergedPull: DivergedPull?

    /// The two sides of a diverged branch, for the merge-or-rebase prompt.
    struct DivergedPull: Identifiable {
        let id = UUID()
        let branch: String
        let ahead: Int
        let behind: Int
    }

    private let git: GitRepository
    private let account: AccountViewModel
    private let pullRequests: PullRequestRepository
    private let main: MainViewModel
    private let repoSource: () -> Repository?
    private let onFinished: () async -> Void
    private let currentBranch: () -> String?
    /// Invoked when pulling leaves conflicts, so the UI can open the resolver.
    private var onMergeConflict: (_ ours: String, _ theirs: String) -> Void = { _, _ in }

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

    func setOnMergeConflict(_ block: @escaping (_ ours: String, _ theirs: String) -> Void) {
        onMergeConflict = block
    }

    func fetchOrigin() async {
        await runRemote {
            try await self.git.fetch(at: $0, auth: self.account.currentAuth())
        }
        lastFetchedAt = Date()
    }

    /// Fast-forward pull. A diverged branch can't fast-forward, so instead of
    /// dumping git's hint into an error dialog, ask how to integrate.
    func pull() async {
        await pull(strategy: .fastForwardOnly)
    }

    func pull(strategy: PullStrategy) async {
        guard let repo = repoSource() else { return }
        main.isBusy = true
        defer { main.isBusy = false }
        await Task.yield()
        do {
            try await git.pull(at: repo.url, auth: account.currentAuth(), strategy: strategy)
            await onFinished()
        } catch {
            await onFinished()   // refresh so any conflicted state is visible
            let text = error.localizedDescription
            if strategy == .fastForwardOnly, Self.isDiverged(text) {
                let status = try? await git.status(at: repo.url)
                pendingDivergedPull = DivergedPull(
                    branch: status?.branch ?? currentBranch() ?? "HEAD",
                    ahead: status?.ahead ?? 0,
                    behind: status?.behind ?? 0
                )
                return
            }
            if let status = try? await git.status(at: repo.url), status.hasConflicts {
                let upstream = await git.upstreamRef(at: repo.url) ?? "upstream"
                onMergeConflict(status.branch ?? "HEAD", upstream)
                return
            }
            main.errorMessage = text
        }
    }

    /// git's wording for "your branch and the remote have both moved on".
    private static func isDiverged(_ message: String) -> Bool {
        message.contains("Not possible to fast-forward")
            || message.contains("Diverging branches can't be fast-forwarded")
            || message.contains("divergent branches")
    }

    func push() async {
        guard let branch = currentBranch() else { return }
        // Push HEAD to the tracked upstream branch explicitly. A bare `git push`
        // relies on push.default; with `simple` it 128s when the upstream branch
        // name differs from the local branch name. Resolving @{upstream} and
        // pushing HEAD:<remote-branch> works regardless of push.default.
        if let repo = repoSource(),
           let upstream = await git.upstreamRef(at: repo.url),
           let slash = upstream.firstIndex(of: "/") {
            let remote = String(upstream[..<slash])
            let remoteBranch = String(upstream[upstream.index(after: slash)...])
            await runRemoteHandlingUpstream(
                args: ["push", remote, "HEAD:\(remoteBranch)"],
                branchName: branch
            )
        } else {
            // No upstream configured → let the bare push surface the
            // "has no upstream branch" path so we can offer to set it.
            await runRemoteHandlingUpstream(args: ["push"], branchName: branch)
        }
    }

    func forcePush() async {
        guard let branch = currentBranch() else { return }
        // Plain --force (not --force-with-lease): the lease variant silently
        // declines to force when there's no local remote-tracking ref for the
        // branch, degrading to a normal push that fails non-fast-forward. This
        // action is already gated behind an explicit destructive confirmation.
        await runRemoteHandlingUpstream(
            args: ["push", "--force", "origin", branch],
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

    /// The repo's configured default reviewers, minus the PR author (you) — a
    /// Bitbucket PR rejects the author as a reviewer. Author identity is resolved
    /// by host id when the token allows it (`/user`), else by matching the
    /// display name against local git `user.name`. Empty on any failure.
    func defaultReviewers() async -> [PRUser] {
        guard let acc = account.account,
              let host = acc.host, let owner = acc.owner, let name = acc.repo,
              let token = account.storedToken() else { return [] }
        guard let list = try? await pullRequests.defaultReviewers(
            host: host, owner: owner, repo: name, token: token
        ), !list.isEmpty else { return [] }

        let me = try? await pullRequests.currentUser(host: host, token: token)
        var localName: String?
        if me == nil, let repo = repoSource() {
            localName = await git.configValue("user.name", at: repo.url)
        }
        return list.filter { u in
            if let me { return u.id != me.id }
            if let localName {
                return PRIdentity.normalizedName(u.name) != PRIdentity.normalizedName(localName)
            }
            return true
        }
    }

    /// Push the current branch (publishing/updating origin), then open a pull
    /// request from it into `base`. Returns the PR URL on success (also stored
    /// in `lastPullRequestURL`); nil on failure with `main.errorMessage` set.
    @discardableResult
    func createPullRequest(title: String, body: String, base: String, reviewers: [String] = []) async -> URL? {
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
                reviewers: reviewers, token: token
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
