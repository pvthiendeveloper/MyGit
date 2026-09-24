import Foundation
import AppKit

@MainActor
final class BranchesViewModel: ObservableObject {
    @Published var branches: [GitBranch] = []
    @Published var recentBranches: [GitBranch] = []
    @Published var tags: [String] = []
    @Published var diffResult: String? = nil
    @Published var showNewBranchSheet: Bool = false

    private let git: GitRepository
    private let main: MainViewModel
    private let repoSource: () -> Repository?
    private let currentBranch: () -> String?
    private let onFinished: () async -> Void
    /// Invoked when a merge leaves the repo mid-merge with conflicts, so the UI can
    /// present the Conflicts resolver instead of a raw error dialog. (ours, theirs).
    private var onMergeConflict: (_ ours: String, _ theirs: String) -> Void = { _, _ in }

    func setOnMergeConflict(_ block: @escaping (_ ours: String, _ theirs: String) -> Void) {
        self.onMergeConflict = block
    }

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
        tags = []
    }

    func refresh() async {
        guard let repo = repoSource() else {
            branches = []
            recentBranches = []
            tags = []
            return
        }
        do {
            let all = try await git.branches(at: repo.url, currentBranch: currentBranch())
            let recentNames = try await git.recentBranches(at: repo.url)
            tags = (try? await git.tags(at: repo.url)) ?? []
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
        await runOp { try await self.git.checkout(branch.checkoutName, at: $0) }
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
        await runOp { try await self.git.checkoutAndRebase(branch: branch.checkoutName, onto: onto, at: $0) }
    }

    func checkoutAndUpdate(_ branch: GitBranch) async {
        await runOp { try await self.git.checkoutAndUpdate(branch: branch.checkoutName, at: $0) }
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
        guard let repo = repoSource() else { return }
        main.isBusy = true
        defer { main.isBusy = false }
        do {
            try await git.merge(source: branch.name, into: target, at: repo.url)
            await onFinished()
        } catch {
            await onFinished()   // refresh so the conflicted state is visible
            // If the merge is now mid-flight with conflicts, open the resolver
            // instead of dumping git's raw hint into an error dialog.
            if let s = try? await git.status(at: repo.url), s.mergeInProgress, s.hasConflicts {
                onMergeConflict(target, branch.leaf)
            } else {
                main.errorMessage = error.localizedDescription
            }
        }
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
        guard !force, let repo = repoSource() else {
            await runOp { try await self.git.deleteBranch(branch.name, force: force, at: $0) }
            return
        }
        // `git branch -d` refuses branches with unmerged commits. Instead of
        // surfacing git's raw refusal, show what would be lost and offer -D.
        main.isBusy = true
        do {
            try await git.deleteBranch(branch.name, force: false, at: repo.url)
            main.isBusy = false
            await onFinished()
        } catch GitError.nonZeroExit(_, _, let stderr) where stderr.contains("not fully merged") {
            let commits = (try? await git.unmergedCommits(of: branch.name, at: repo.url)) ?? []
            main.isBusy = false
            if confirmForceDelete(branch.name, commits: commits) {
                await runOp { try await self.git.deleteBranch(branch.name, force: true, at: $0) }
            }
        } catch {
            main.isBusy = false
            main.errorMessage = error.localizedDescription
            await onFinished()
        }
    }

    private func confirmForceDelete(_ name: String, commits: [String]) -> Bool {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "“\(name)” has unmerged commits"
        let count = commits.count
        let shown = commits.prefix(8).joined(separator: "\n")
        let more = count > 8 ? "\n… and \(count - 8) more" : ""
        alert.informativeText = count == 0
            ? "Git says the branch isn't fully merged into its upstream. Deleting it anyway may lose commits that exist only on this branch."
            : "\(count) commit\(count == 1 ? "" : "s") on this branch aren't in the current branch and will be lost unless they exist elsewhere (e.g. pushed to a remote):\n\n\(shown)\(more)"
        alert.addButton(withTitle: "Force Delete")
        alert.addButton(withTitle: "Cancel")
        alert.buttons[0].hasDestructiveAction = true
        return alert.runModal() == .alertFirstButtonReturn
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
            // A failed merge/rebase can still leave the repo mid-operation with
            // conflicts (e.g. submodule merge). Refresh so that state is visible
            // instead of the UI staying stale behind the error dialog.
            await onFinished()
        }
    }
}
