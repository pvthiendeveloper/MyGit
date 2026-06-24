import Foundation
import AppKit

@MainActor
final class BranchesViewModel: ObservableObject {
    @Published var branches: [GitBranch] = []
    @Published var recentBranches: [GitBranch] = []
    @Published var diffResult: String? = nil
    @Published var showNewBranchSheet: Bool = false

    private let git: GitRepository
    private let main: MainViewModel
    private let repoSource: () -> Repository?
    private let currentBranch: () -> String?
    private let onFinished: () async -> Void

    init(
        git: GitRepository,
        main: MainViewModel,
        repoSource: @escaping () -> Repository?,
        currentBranch: @escaping () -> String?,
        onFinished: @escaping () async -> Void
    ) {
        self.git = git
        self.main = main
        self.repoSource = repoSource
        self.currentBranch = currentBranch
        self.onFinished = onFinished
    }

    func repositoryDidChange() {
        branches = []
        recentBranches = []
    }

    func refresh() async {
        guard let repo = repoSource() else {
            branches = []
            recentBranches = []
            return
        }
        do {
            let all = try await git.branches(at: repo.url, currentBranch: currentBranch())
            let recentNames = try await git.recentBranches(at: repo.url)
            branches = all
            let localByName = Dictionary(
                uniqueKeysWithValues: all.filter { !$0.isRemote }.map { ($0.name, $0) }
            )
            recentBranches = recentNames.compactMap { localByName[$0] }
        } catch {
            main.errorMessage = error.localizedDescription
        }
    }

    func checkout(_ branch: GitBranch) async {
        await runOp { try await self.git.checkout(branch.name, at: $0) }
    }

    func createBranch(name: String, from: GitBranch) async {
        await runOp { try await self.git.createBranch(name, from: from.name, at: $0) }
    }

    func stashAndCreateBranch(name: String, from: GitBranch) async {
        await runOp { url in
            try await self.git.stashPush(message: "Auto-stash before creating \(name)", at: url)
            try await self.git.createBranch(name, from: from.name, at: url)
        }
    }

    func checkoutAndRebase(branch: GitBranch, onto: String) async {
        await runOp { try await self.git.checkoutAndRebase(branch: branch.name, onto: onto, at: $0) }
    }

    func checkoutAndUpdate(_ branch: GitBranch) async {
        await runOp { try await self.git.checkoutAndUpdate(branch: branch.name, at: $0) }
    }

    func compare(_ branch: GitBranch, vs current: String) {
        main.openCompare(ComparePair(a: branch.name, b: current))
    }

    func diffWithWorkingTree(_ branch: GitBranch) async {
        guard let repo = repoSource() else { return }
        do {
            let result = try await git.diffWithWorkingTree(branch: branch.name, at: repo.url)
            diffResult = result.isEmpty ? "(No differences)" : result
        } catch {
            main.errorMessage = error.localizedDescription
        }
    }

    func rebase(base: String, onto: String) async {
        await runOp { try await self.git.rebase(base: base, onto: onto, at: $0) }
    }

    func merge(_ branch: GitBranch, into target: String) async {
        await runOp { try await self.git.merge(source: branch.name, into: target, at: $0) }
    }

    func updateBranch(_ branch: GitBranch) async {
        await runOp {
            try await self.git.updateBranch(branch.name, isCurrent: branch.isCurrent, at: $0)
        }
    }

    func setUpstream(branch: GitBranch, to upstream: String) async {
        await runOp {
            try await self.git.setUpstream(branch: branch.name, upstream: upstream, at: $0)
        }
    }

    func rename(_ branch: GitBranch, to newName: String) async {
        await runOp { try await self.git.renameBranch(old: branch.name, new: newName, at: $0) }
    }

    func delete(_ branch: GitBranch, force: Bool) async {
        await runOp { try await self.git.deleteBranch(branch.name, force: force, at: $0) }
    }

    func pickWorktreeDirectory(for branch: GitBranch) {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.prompt = "Choose Worktree Location"
        panel.message = "Select a directory to create a new worktree for '\(branch.name)'"
        if panel.runModal() == .OK, let url = panel.url {
            Task { await newWorktree(from: branch, at: url) }
        }
    }

    func newWorktree(from branch: GitBranch, at url: URL) async {
        await runOp { try await self.git.newWorktree(path: url, from: branch.name, at: $0) }
    }

    func checkoutRevision(_ rev: String) async {
        await runOp { try await self.git.checkoutRevision(rev, at: $0) }
    }

    func remoteBranchNames(matching hint: String) -> [String] {
        branches.filter { $0.isRemote && $0.name.contains(hint) }.map { $0.name }
    }

    private func runOp(_ op: @escaping (URL) async throws -> Void) async {
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
}
