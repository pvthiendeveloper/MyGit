import Foundation

@MainActor
final class RemoteViewModel: ObservableObject {
    @Published var lastFetchedAt: Date?
    @Published var noUpstreamBranch: String?
    @Published var missingRemoteForBranch: String?

    private let git: GitRepository
    private let account: AccountViewModel
    private let main: MainViewModel
    private let repoSource: () -> Repository?
    private let onFinished: () async -> Void
    private let currentBranch: () -> String?

    init(
        git: GitRepository,
        account: AccountViewModel,
        main: MainViewModel,
        repoSource: @escaping () -> Repository?,
        currentBranch: @escaping () -> String?,
        onFinished: @escaping () async -> Void
    ) {
        self.git = git
        self.account = account
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

    private func runRemote(_ op: @escaping (URL) async throws -> Void) async {
        guard let repo = repoSource() else { return }
        main.isBusy = true
        defer { main.isBusy = false }
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
