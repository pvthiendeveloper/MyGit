import Foundation
import Combine
import AppKit

@MainActor
final class HistoryViewModel: ObservableObject {
    @Published var commits: [GitCommit] = []
    @Published private(set) var graphRows: [GraphRow] = []
    @Published var filter = HistoryFilter()
    @Published var selectedCommit: GitCommit?
    @Published var diff: FileDiff?
    @Published var changedFiles: [ChangedFileEntry] = []
    @Published var isLoadingFiles = false
    /// True when the last fetch hit the limit — more commits may exist.
    @Published private(set) var hasMore = false
    @Published private(set) var isLoadingMore = false

    // Gating state for the commit context menu.
    @Published private(set) var pushedHashes: Set<String> = []
    @Published private(set) var headHash: String?

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

    /// Widest lane span across all rows — drives the graph column width.
    var graphColumns: Int { graphRows.map { $0.maxColumns }.max() ?? 1 }

    private let pageSize = 100
    private var limit = 100

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
                Task { await self.loadChangedFiles(for: commit) }
            }
            .store(in: &cancellables)

        // Re-query whenever the filter changes (debounced). Reset to first page.
        $filter
            .dropFirst()
            .removeDuplicates()
            .debounce(for: .milliseconds(300), scheduler: RunLoop.main)
            .sink { [weak self] _ in
                guard let self else { return }
                self.limit = self.pageSize
                Task { await self.refreshLog() }
            }
            .store(in: &cancellables)
    }

    func setOnFinished(_ block: @escaping () async -> Void) { onFinished = block }
    func setPushUpTo(_ block: @escaping (GitCommit) async -> Void) { pushUpTo = block }

    func repositoryDidChange() {
        selectedCommit = nil
        diff = nil
        changedFiles = []
        commits = []
        graphRows = []
        pushedHashes = []
        headHash = nil
        limit = pageSize
        hasMore = false
    }

    func refreshLog() async {
        guard let repo = repoSource() else {
            commits = []; graphRows = []; hasMore = false
            pushedHashes = []; headHash = nil
            return
        }
        do {
            let loaded = try await git.graphLog(at: repo.url, limit: limit, filter: filter)
            commits = loaded
            graphRows = CommitGraph.layout(loaded)
            hasMore = loaded.count >= limit
            // Gating data: real HEAD (current branch tip) + already-pushed commits.
            headHash = (try? await git.log(at: repo.url, limit: 1))?.first?.id
            pushedHashes = (try? await git.pushedHashes(at: repo.url)) ?? []
            // Keep selection if still present; otherwise default to the top commit.
            if let sel = selectedCommit, !loaded.contains(where: { $0.id == sel.id }) {
                selectedCommit = loaded.first
            } else if selectedCommit == nil {
                selectedCommit = loaded.first
            }
        } catch {
            commits = []
            graphRows = []
            hasMore = false
            pushedHashes = []
            headHash = nil
            main.errorMessage = error.localizedDescription
        }
    }

    /// Grow the window by one page and reload. Selection is preserved.
    func loadMore() async {
        guard hasMore, !isLoadingMore else { return }
        isLoadingMore = true
        defer { isLoadingMore = false }
        limit += pageSize
        await refreshLog()
    }

    private func loadChangedFiles(for commit: GitCommit) async {
        guard let repo = repoSource() else { return }
        isLoadingFiles = true
        defer { isLoadingFiles = false }
        do {
            changedFiles = try await git.changedFiles(commit: commit.hash, at: repo.url)
        } catch {
            changedFiles = []
            main.errorMessage = error.localizedDescription
        }
    }

    func perform(_ action: CompareFileAction, on entry: ChangedFileEntry) {
        guard let repo = repoSource(), let commit = selectedCommit else { return }
        let repoURL = repo.url
        switch action {
        case .showDiff:
            main.openDiffTab(commitHash: commit.hash, commitShortHash: commit.shortHash, path: entry.path, mode: .commitVsParent, forceNew: false)
        case .showDiffInNewTab:
            main.openDiffTab(commitHash: commit.hash, commitShortHash: commit.shortHash, path: entry.path, mode: .commitVsParent, forceNew: true)
        case .compareWithLocal:
            main.openDiffTab(commitHash: commit.hash, commitShortHash: commit.shortHash, path: entry.path, mode: .commitVsWorking, forceNew: true)
        case .compareBeforeWithLocal:
            main.openDiffTab(commitHash: commit.hash, commitShortHash: commit.shortHash, path: entry.path, mode: .parentVsWorking, forceNew: true)
        case .editSource:
            let url = repoURL.appendingPathComponent(entry.path)
            if FileManager.default.fileExists(atPath: url.path) {
                NSWorkspace.shared.open(url)
            } else {
                main.errorMessage = "File no longer exists in the working tree."
            }
        case .openRepositoryVersion:
            Task {
                do {
                    let url = try await git.extractFileAtCommit(commit: commit.hash, path: entry.path, at: repoURL)
                    NSWorkspace.shared.open(url)
                } catch {
                    main.errorMessage = error.localizedDescription
                }
            }
        case .revertChanges:
            Task {
                do { try await git.revertFileInCommit(commit: commit.hash, path: entry.path, at: repoURL) }
                catch { main.errorMessage = error.localizedDescription }
            }
        case .cherryPickChanges:
            Task {
                do { try await git.cherryPickFileFromCommit(commit: commit.hash, path: entry.path, at: repoURL) }
                catch { main.errorMessage = error.localizedDescription }
            }
        case .dropChanges:
            main.errorMessage = "Drop Selected Changes requires history rewrite and isn't supported yet."
        case .createPatch:
            Task {
                do {
                    let patch = try await git.patchForFile(commit: commit.hash, path: entry.path, at: repoURL)
                    let suggested = "\(commit.shortHash)-\((entry.path as NSString).lastPathComponent).patch"
                    savePatch(patch, suggestedName: suggested)
                } catch {
                    main.errorMessage = error.localizedDescription
                }
            }
        case .historyUpToHere:
            break
        }
    }

    // MARK: - Commit context-menu gating

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
        let target = commit.parents.first ?? commit.id
        let mode: GitResetMode = commit.parents.isEmpty ? .mixed : .mixed
        runOp { try await self.git.resetTo(commit: target, mode: mode, at: $0) }
    }

    // MARK: - History rewrite (range-derived todos)

    func editMessage(_ commit: GitCommit, newMessage: String) {
        if isTip(commit) {
            runOp { try await self.git.amendMessage(newMessage, at: $0) }
            return
        }
        let base = base(forParentOf: commit)
        runOp { repo in
            let steps = try await self.stepsForRebase(base: base, at: repo) {
                $0.id == commit.id ? .reword(commit.id, newMessage) : .pick($0.id)
            }
            try await self.git.interactiveRebase(todo: steps, onto: base, at: repo)
        }
    }

    func drop(_ commit: GitCommit) {
        let base = base(forParentOf: commit)
        runOp { repo in
            let steps = try await self.stepsForRebase(base: base, at: repo) {
                $0.id == commit.id ? .drop(commit.id) : .pick($0.id)
            }
            try await self.git.interactiveRebase(todo: steps, onto: base, at: repo)
        }
    }

    func fixupIntoParent(_ commit: GitCommit) { squashLike(commit, fixup: true) }
    func squashIntoParent(_ commit: GitCommit) { squashLike(commit, fixup: false) }

    private func squashLike(_ commit: GitCommit, fixup: Bool) {
        guard !commit.parents.isEmpty else {
            main.errorMessage = "Cannot squash the root commit into a parent."
            return
        }
        let base = base(forGrandparentOf: commit)
        runOp { repo in
            let steps = try await self.stepsForRebase(base: base, at: repo) {
                $0.id == commit.id ? (fixup ? .fixup(commit.id) : .squash(commit.id)) : .pick($0.id)
            }
            try await self.git.interactiveRebase(todo: steps, onto: base, at: repo)
        }
    }

    /// Build the interactive-rebase editor rows for `commit`..HEAD (oldest first).
    func rebaseRows(from commit: GitCommit) async -> [RebaseRow] {
        guard let repo = repoSource() else { return [] }
        let base = base(forParentOf: commit)
        let range = (try? await rangeCommits(base: base, at: repo.url)) ?? []
        return range.map { RebaseRow(commit: $0) }
    }

    /// Apply the interactive-rebase editor sheet's plan.
    func applyRebase(from commit: GitCommit, rows: [RebaseRow]) {
        let base = base(forParentOf: commit)
        let steps: [RebaseStep] = rows.map { row in
            switch row.action {
            case .pick:   return .pick(row.commit.id)
            case .reword: return .reword(row.commit.id, row.commit.subject) // text via Edit Commit Message
            case .squash: return .squash(row.commit.id)
            case .fixup:  return .fixup(row.commit.id)
            case .drop:   return .drop(row.commit.id)
            }
        }
        runOp { try await self.git.interactiveRebase(todo: steps, onto: base, at: $0) }
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

    /// Commits in `base`..HEAD on the current branch, oldest first. `--root`
    /// base means the whole HEAD history.
    private func rangeCommits(base: String, at repo: URL) async throws -> [GitCommit] {
        let range = base == "--root" ? "HEAD" : "\(base)..HEAD"
        return try await git.commitsInRange(range, at: repo).reversed()
    }

    private func stepsForRebase(base: String, at repo: URL, _ f: (GitCommit) -> RebaseStep) async throws -> [RebaseStep] {
        try await rangeCommits(base: base, at: repo).map(f)
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
