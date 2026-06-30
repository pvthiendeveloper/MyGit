import Foundation
import Combine
import AppKit

@MainActor
final class HistoryViewModel: ObservableObject {
    @Published var commits: [GitCommit] = []
    @Published var selectedCommit: GitCommit?
    @Published var diff: FileDiff?

    /// Commits already on the upstream — used to gray out history-rewrite ops.
    @Published private(set) var pushedHashes: Set<String> = []

    // Sheet / dialog triggers driven by the context menu.
    @Published var newBranchFrom: GitCommit?
    @Published var newTagFrom: GitCommit?
    @Published var editMessageFor: GitCommit?
    @Published var pendingReset: GitCommit?
    @Published var pendingRevert: GitCommit?
    @Published var pendingDrop: GitCommit?
    @Published var rebaseFrom: GitCommit?
    @Published var diffResult: String?
    @Published var treeResult: [String]?

    private let git: GitRepository
    private let main: MainViewModel
    private let repoSource: () -> Repository?
    private var cancellables: Set<AnyCancellable> = []

    private var onFinished: () async -> Void = {}
    private var pushUpTo: (GitCommit) async -> Void = { _ in }

    init(git: GitRepository, main: MainViewModel, repoSource: @escaping () -> Repository?) {
        self.git = git
        self.main = main
        self.repoSource = repoSource

        $selectedCommit
            .removeDuplicates()
            .sink { [weak self] commit in
                guard let self, let commit else { return }
                Task { await self.loadDiff(for: commit) }
            }
            .store(in: &cancellables)
    }

    func setOnFinished(_ block: @escaping () async -> Void) { onFinished = block }
    func setPushUpTo(_ block: @escaping (GitCommit) async -> Void) { pushUpTo = block }

    func repositoryDidChange() {
        selectedCommit = nil
        diff = nil
        commits = []
        pushedHashes = []
    }

    func refreshLog() async {
        guard let repo = repoSource() else { commits = []; pushedHashes = []; return }
        do {
            commits = try await git.log(at: repo.url, limit: 300)
            pushedHashes = (try? await git.pushedHashes(at: repo.url)) ?? []
            if selectedCommit == nil { selectedCommit = commits.first }
        } catch {
            commits = []
            pushedHashes = []
            main.errorMessage = error.localizedDescription
        }
    }

    private func loadDiff(for commit: GitCommit) async {
        guard let repo = repoSource() else { return }
        do {
            diff = try await git.diff(at: repo.url, commit: commit)
        } catch {
            main.errorMessage = error.localizedDescription
        }
    }

    // MARK: - Gating helpers

    var headHash: String? { commits.first?.id }
    func isTip(_ c: GitCommit) -> Bool { c.id == headHash }
    func isPushed(_ c: GitCommit) -> Bool { pushedHashes.contains(c.id) }
    func canRewrite(_ c: GitCommit) -> Bool { !isPushed(c) }

    // MARK: - Safe actions

    func copyHash(_ commit: GitCommit) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(commit.id, forType: .string)
    }

    func createPatch(_ commit: GitCommit) {
        guard let repo = repoSource() else { return }
        Task {
            do {
                let patch = try await git.formatPatch(commit: commit.id, at: repo.url)
                savePatch(patch, suggestedName: "\(commit.shortHash).patch")
            } catch {
                main.errorMessage = error.localizedDescription
            }
        }
    }

    func cherryPick(_ commit: GitCommit) { runOp { try await self.git.cherryPick(commit: commit.id, at: $0) } }
    func checkout(_ commit: GitCommit) { runOp { try await self.git.checkoutRevision(commit.id, at: $0) } }

    func showAtRevision(_ commit: GitCommit) {
        guard let repo = repoSource() else { return }
        Task {
            do { treeResult = try await git.lsTreeAtRevision(commit.id, at: repo.url) }
            catch { main.errorMessage = error.localizedDescription }
        }
    }

    func compareWithLocal(_ commit: GitCommit) {
        guard let repo = repoSource() else { return }
        Task {
            do {
                let out = try await git.diffWithWorkingTree(branch: commit.id, at: repo.url)
                diffResult = out.isEmpty ? "(No differences)" : out
            } catch { main.errorMessage = error.localizedDescription }
        }
    }

    func createBranch(_ commit: GitCommit, name: String) {
        runOp { try await self.git.createBranch(name, from: commit.id, at: $0) }
    }

    func createTag(_ commit: GitCommit, name: String) {
        runOp { try await self.git.createTag(name, at: commit.id, message: nil, at: $0) }
    }

    func pushUpToHere(_ commit: GitCommit) { Task { await pushUpTo(commit) } }

    // MARK: - Reset / Revert / Undo

    func reset(_ commit: GitCommit, mode: GitResetMode) {
        runOp { try await self.git.resetTo(commit: commit.id, mode: mode, at: $0) }
    }

    func revert(_ commit: GitCommit) { runOp { try await self.git.revertCommit(commit.id, at: $0) } }

    /// Undo the tip commit, returning its changes to the working tree.
    func undo(_ commit: GitCommit) {
        guard let parent = commit.parents.first else {
            // Root commit: nothing to reset to — drop it entirely.
            runOp { try await self.git.resetTo(commit: commit.id, mode: .mixed, at: $0) }
            return
        }
        runOp { try await self.git.resetTo(commit: parent, mode: .mixed, at: $0) }
    }

    // MARK: - History rewrite

    func editMessage(_ commit: GitCommit, newMessage: String) {
        if isTip(commit) {
            runOp { try await self.git.amendMessage(newMessage, at: $0) }
        } else {
            let steps = rewriteSteps(target: commit) { $0.id == commit.id ? .reword(commit.id, newMessage) : .pick($0.id) }
            runOp { try await self.git.interactiveRebase(todo: steps, onto: self.base(forParentOf: commit), at: $0) }
        }
    }

    func drop(_ commit: GitCommit) {
        let steps = rewriteSteps(target: commit) { $0.id == commit.id ? .drop(commit.id) : .pick($0.id) }
        runOp { try await self.git.interactiveRebase(todo: steps, onto: self.base(forParentOf: commit), at: $0) }
    }

    func fixupIntoParent(_ commit: GitCommit) { squashLike(commit, fixup: true) }
    func squashIntoParent(_ commit: GitCommit) { squashLike(commit, fixup: false) }

    private func squashLike(_ commit: GitCommit, fixup: Bool) {
        guard let parentSha = commit.parents.first else {
            main.errorMessage = "Cannot squash the root commit into a parent."
            return
        }
        // Range covers the parent (pick) followed by this commit (fixup/squash).
        let steps = rewriteSteps(targetSha: parentSha) {
            $0.id == commit.id ? (fixup ? .fixup(commit.id) : .squash(commit.id)) : .pick($0.id)
        }
        runOp { try await self.git.interactiveRebase(todo: steps, onto: self.base(forGrandparentOf: commit), at: $0) }
    }

    /// Run the interactive-rebase editor sheet's plan.
    func applyRebase(from commit: GitCommit, rows: [RebaseRow]) {
        let steps: [RebaseStep] = rows.map { row in
            switch row.action {
            case .pick:   return .pick(row.commit.id)
            case .reword: return .reword(row.commit.id, row.commit.subject) // message kept; edit via Edit Message
            case .squash: return .squash(row.commit.id)
            case .fixup:  return .fixup(row.commit.id)
            case .drop:   return .drop(row.commit.id)
            }
        }
        runOp { try await self.git.interactiveRebase(todo: steps, onto: self.base(forParentOf: commit), at: $0) }
    }

    /// Commits from `commit` (inclusive) up to HEAD, oldest first — the editable
    /// window for an interactive rebase starting at `commit`.
    func rebaseRows(from commit: GitCommit) -> [RebaseRow] {
        guard let idx = commits.firstIndex(where: { $0.id == commit.id }) else { return [] }
        return commits[0...idx].reversed().map { RebaseRow(commit: $0) }
    }

    // MARK: - Navigation

    func goToParent(_ commit: GitCommit) {
        guard let p = commit.parents.first,
              let target = commits.first(where: { $0.id == p }) else { return }
        selectedCommit = target
    }

    func goToChild(_ commit: GitCommit) {
        guard let child = commits.first(where: { $0.parents.contains(commit.id) }) else { return }
        selectedCommit = child
    }

    // MARK: - Rebase plumbing

    /// Build a todo over `target`..HEAD (oldest first) mapping each commit via `f`.
    private func rewriteSteps(target: GitCommit, _ f: (GitCommit) -> RebaseStep) -> [RebaseStep] {
        rewriteSteps(targetSha: target.id, f)
    }

    private func rewriteSteps(targetSha: String, _ f: (GitCommit) -> RebaseStep) -> [RebaseStep] {
        guard let idx = commits.firstIndex(where: { $0.id == targetSha }) else { return [] }
        return commits[0...idx].reversed().map(f)
    }

    /// Rebase base = the parent of `commit` (or `--root` if it's the root).
    private func base(forParentOf commit: GitCommit) -> String {
        commit.parents.isEmpty ? "--root" : "\(commit.id)~1"
    }

    /// Rebase base = the grandparent of `commit` (for squash-into-parent).
    private func base(forGrandparentOf commit: GitCommit) -> String {
        guard let parentSha = commit.parents.first else { return "--root" }
        if let parent = commits.first(where: { $0.id == parentSha }), parent.parents.isEmpty {
            return "--root"
        }
        return "\(commit.id)~2"
    }

    // MARK: - Op wrapper

    private func runOp(_ op: @escaping (URL) async throws -> Void) {
        guard let repo = repoSource() else { return }
        Task {
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

    private func savePatch(_ patch: String, suggestedName: String) {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = suggestedName
        panel.canCreateDirectories = true
        if panel.runModal() == .OK, let url = panel.url {
            do { try patch.write(to: url, atomically: true, encoding: .utf8) }
            catch { main.errorMessage = error.localizedDescription }
        }
    }
}
