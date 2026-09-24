import Foundation
import Combine
#if canImport(AppKit)
import AppKit
#endif

enum CommitMode: Equatable {
    case commit
    case amendKeepMessage
    case amendUpdateMessage
    case commitAndPush
    case commitAndForcePush
    /// Commit with no file changes — the usual way to re-run a CI/CD pipeline.
    /// Staged work is left staged.
    case emptyCommit
    case emptyCommitAndPush

    var isEmpty: Bool { self == .emptyCommit || self == .emptyCommitAndPush }
}

@MainActor
final class ChangesViewModel: ObservableObject {
    @Published var status: GitStatusSummary?
    @Published var selectedChange: FileChange?
    @Published var diff: FileDiff?
    @Published var stagedPaths: Set<String> = []
    @Published var commitSummary: String = "" { didSet { saveDraft() } }
    @Published var commitDescription: String = "" { didSet { saveDraft() } }
    @Published var commitMode: CommitMode = .commit
    @Published var canAmend: Bool = false
    @Published var pendingRollback: FileChange?
    @Published var pendingDelete: FileChange?
    // Triggers for the right-click "Git" menu's sheets/dialogs (hosted in the list view).
    @Published var pendingNewBranch = false
    @Published var pendingNewTag = false
    @Published var pendingResetHead = false
    @Published var pendingDiscardAll = false
    @Published var pendingStash = false
    @Published var pendingAbortMerge = false
    @Published var pendingAbortCherryPick = false
    @Published var pendingAbortRebase = false
    @Published var jumpToSourcePath: String?
    @Published var pendingForcePushConfirm: Bool = false
    @Published var isGeneratingMessage: Bool = false
    /// Most recent commit for this repo (cached + refreshed). Drives the
    /// "last commit" line shown per project.
    @Published var lastCommit: CachedCommit?

    private let git: GitRepository
    private let main: MainViewModel
    private let repoSource: () -> Repository?
    private let commitMessageRepo: CommitMessageRepository
    private let lastCommitStore = LastCommitStore()
    private let draftStore = CommitDraftStore()
    /// Suppresses draft persistence while we load/clear programmatically.
    private var loadingDraft = false
    private var aiConfigSource: () -> AIRequestConfig? = { nil }
    private var onFinished: () async -> Void = {}
    private var pushAfterCommit: (Bool) async -> Void = { _ in }
    private var previousPaths: Set<String> = []
    private var cancellables: Set<AnyCancellable> = []

    init(
        git: GitRepository,
        main: MainViewModel,
        repoSource: @escaping () -> Repository?,
        commitMessageRepo: CommitMessageRepository
    ) {
        self.git = git
        self.main = main
        self.repoSource = repoSource
        self.commitMessageRepo = commitMessageRepo
        self.lastCommit = repoSource().flatMap { LastCommitStore().get($0.url.path) }
        if let repo = repoSource() {
            let draft = CommitDraftStore().get(repo.url.path)
            self.commitSummary = draft.summary
            self.commitDescription = draft.description
        }

        $selectedChange
            .removeDuplicates()
            .sink { [weak self] change in
                guard let self, let change else { return }
                Task { await self.loadDiff(for: change) }
            }
            .store(in: &cancellables)
    }

    private func saveDraft() {
        guard !loadingDraft, let repo = repoSource() else { return }
        draftStore.set(
            summary: commitSummary,
            description: commitDescription,
            repoPath: repo.url.path
        )
    }

    func setOnFinished(_ block: @escaping () async -> Void) {
        self.onFinished = block
    }

    func setAIConfigSource(_ block: @escaping () -> AIRequestConfig?) {
        self.aiConfigSource = block
    }

    func setPushAfterCommit(_ block: @escaping (Bool) async -> Void) {
        self.pushAfterCommit = block
    }

    func repositoryDidChange() {
        selectedChange = nil
        diff = nil
        stagedPaths.removeAll()
        previousPaths.removeAll()
        status = nil
        commitMode = .commit
        canAmend = false
    }

    func refreshStatus() async {
        guard let repo = repoSource() else { status = nil; canAmend = false; return }
        do {
            let parsed = try await git.status(at: repo.url)
            status = parsed
            let allPaths = Set(parsed.changes.map { $0.path })
            if previousPaths.isEmpty {
                // First status after opening/switching the repo: default all checked.
                stagedPaths = allPaths
            } else {
                // Preserve the user's explicit checks/unchecks; auto-check only
                // files that newly appeared since the last refresh. Must NOT fall
                // back to "check everything" when the user has unchecked all —
                // otherwise the FSEvents auto-refresh re-checks them instantly.
                let kept = stagedPaths.intersection(allPaths)
                stagedPaths = kept.union(allPaths.subtracting(previousPaths))
            }
            previousPaths = allPaths

            if let sel = selectedChange, !allPaths.contains(sel.path) {
                selectedChange = parsed.changes.first
            } else if selectedChange == nil {
                selectedChange = parsed.changes.first
            }
            canAmend = await git.headExists(at: repo.url)
        } catch {
            main.errorMessage = error.localizedDescription
        }
        await updateLastCommit()
    }

    /// Refresh + persist this repo's most recent commit.
    private func updateLastCommit() async {
        guard let repo = repoSource() else { return }
        guard let latest = try? await git.log(at: repo.url, limit: 1).first else { return }
        let cached = CachedCommit(
            subject: latest.subject,
            shortHash: latest.shortHash,
            dateEpoch: latest.date.timeIntervalSince1970
        )
        lastCommit = cached
        lastCommitStore.set(cached, repoPath: repo.url.path)
    }

    func setCommitMode(_ mode: CommitMode) {
        let prev = commitMode
        commitMode = mode
        if mode == .amendUpdateMessage,
           prev != .amendUpdateMessage,
           commitSummary.trimmingCharacters(in: .whitespaces).isEmpty,
           commitDescription.trimmingCharacters(in: .whitespaces).isEmpty {
            Task { await prefillFromHead() }
        }
    }

    private func prefillFromHead() async {
        guard let repo = repoSource() else { return }
        do {
            let msg = try await git.headCommitMessage(at: repo.url)
            let parts = msg.components(separatedBy: "\n\n")
            commitSummary = parts.first ?? ""
            if parts.count > 1 {
                commitDescription = parts.dropFirst().joined(separator: "\n\n")
            }
        } catch {
            main.errorMessage = error.localizedDescription
        }
    }

    private func loadDiff(for change: FileChange) async {
        guard let repo = repoSource() else { return }
        diff = try? await git.diff(at: repo.url, change: change)
    }

    var canCommit: Bool {
        guard repoSource() != nil else { return false }
        let hasSummary = !commitSummary.trimmingCharacters(in: .whitespaces).isEmpty
        switch commitMode {
        case .commit, .commitAndPush, .commitAndForcePush:
            return hasSummary && !stagedPaths.isEmpty
        case .emptyCommit, .emptyCommitAndPush:
            // No summary needed: pipelines often key off the commit existing.
            return true
        case .amendKeepMessage:
            return canAmend
        case .amendUpdateMessage:
            return canAmend && hasSummary
        }
    }

    func toggleStaged(_ change: FileChange) {
        if stagedPaths.contains(change.path) {
            stagedPaths.remove(change.path)
        } else {
            stagedPaths.insert(change.path)
        }
    }

    /// Check / uncheck a group of files at once (a "Changes" or
    /// "Unversioned Files" group header).
    func setStaged(_ changes: [FileChange], _ on: Bool) {
        let paths = Set(changes.map(\.path))
        if on { stagedPaths.formUnion(paths) } else { stagedPaths.subtract(paths) }
    }

    func setAllStaged(_ on: Bool) {
        guard let status else { return }
        stagedPaths = on ? Set(status.changes.map { $0.path }) : []
    }

    /// Commit with no changes, optionally pushing straight after — pipelines
    /// usually only react to the push. Falls back to a default subject so the
    /// history stays readable when the composer is empty.
    func commitEmpty(message: String, push: Bool) async {
        guard let repo = repoSource(), !main.isBusy else { return }
        main.isBusy = true
        defer { main.isBusy = false }
        do {
            try await git.commitEmpty(
                message: message.trimmingCharacters(in: .whitespacesAndNewlines),
                at: repo.url
            )
            commitSummary = ""
            commitDescription = ""
            commitMode = .commit
            await onFinished()
            if push { await pushAfterCommit(false) }
        } catch {
            main.errorMessage = error.localizedDescription
        }
    }

    func commit() async {
        guard let repo = repoSource(), canCommit, let status else { return }
        main.isBusy = true
        defer { main.isBusy = false }
        let toStage = status.changes
            .filter { stagedPaths.contains($0.path) }
            .map { $0.path }
        let composedMessage = composeMessage()
        let modeAtStart = commitMode
        if modeAtStart.isEmpty {
            main.isBusy = false
            await commitEmpty(message: composedMessage, push: modeAtStart == .emptyCommitAndPush)
            return
        }
        do {
            switch modeAtStart {
            case .commit, .commitAndPush, .commitAndForcePush:
                try await git.commit(at: repo.url, paths: toStage, message: composedMessage)
            case .amendKeepMessage:
                try await git.amend(at: repo.url, paths: toStage, newMessage: nil)
            case .amendUpdateMessage:
                try await git.amend(at: repo.url, paths: toStage, newMessage: composedMessage)
            case .emptyCommit, .emptyCommitAndPush:
                break   // handled above
            }
            commitSummary = ""
            commitDescription = ""
            commitMode = .commit
            await onFinished()

            switch modeAtStart {
            case .commitAndPush:
                await pushAfterCommit(false)
            case .commitAndForcePush:
                await pushAfterCommit(true)
            default:
                break
            }
        } catch {
            main.errorMessage = error.localizedDescription
        }
    }

    var canGenerateMessage: Bool {
        repoSource() != nil && !stagedPaths.isEmpty && !isGeneratingMessage && !main.isBusy
    }

    /// Build the staged diff and ask the configured LLM for a commit message,
    /// filling in summary + description.
    func generateCommitMessage() async {
        guard let repo = repoSource(), let status, !stagedPaths.isEmpty else { return }
        guard let config = aiConfigSource() else {
            main.errorMessage = CommitMessageError.missingAPIKey.localizedDescription
            return
        }
        let changes = status.changes.filter { stagedPaths.contains($0.path) }
        guard !changes.isEmpty else { return }

        isGeneratingMessage = true
        defer { isGeneratingMessage = false }
        do {
            var diff = try await git.diffPatch(at: repo.url, changes: changes)
            let maxChars = 24_000
            if diff.count > maxChars {
                diff = String(diff.prefix(maxChars)) + "\n…(diff truncated)…"
            }
            let suggestion = try await commitMessageRepo.generate(diff: diff, config: config)
            commitSummary = suggestion.summary
            if config.includeBody {
                commitDescription = suggestion.body
            }
        } catch {
            main.errorMessage = error.localizedDescription
        }
    }

    /// Generate a pull request title + description from the local `base...head`
    /// change set via the configured AI provider. Returns nil (and sets
    /// `main.errorMessage`) on missing config, no changes, or provider error.
    func generatePullRequestText(base: String, head: String) async -> CommitSuggestion? {
        guard let repo = repoSource() else { return nil }
        guard let config = aiConfigSource() else {
            main.errorMessage = CommitMessageError.missingAPIKey.localizedDescription
            return nil
        }
        do {
            let subjects = try await git.commitsInRange("\(base)..\(head)", at: repo.url)
                .map { "- \($0.subject)" }
                .joined(separator: "\n")
            var diff = try await git.rangeDiff(range: "\(base)...\(head)", at: repo.url)
            let maxChars = 24_000
            if diff.count > maxChars {
                diff = String(diff.prefix(maxChars)) + "\n…(diff truncated)…"
            }
            let context = "Commits:\n\(subjects.isEmpty ? "(none)" : subjects)\n\nDiff:\n\(diff)"
            // PR generation always wants a body regardless of the commit toggle.
            var cfg = config
            cfg.includeBody = true
            return try await commitMessageRepo.generatePullRequest(diff: context, config: cfg)
        } catch {
            main.errorMessage = error.localizedDescription
            return nil
        }
    }

    private func composeMessage() -> String {
        var msg = commitSummary
        let descTrim = commitDescription.trimmingCharacters(in: .whitespacesAndNewlines)
        if !descTrim.isEmpty { msg += "\n\n" + descTrim }
        return msg
    }

    // MARK: - Context menu actions

    func commitFile(_ change: FileChange) async {
        guard let repo = repoSource() else { return }
        let msg = composeMessage().trimmingCharacters(in: .whitespacesAndNewlines)
        guard !msg.isEmpty else {
            main.errorMessage = "Enter a commit summary first."
            return
        }
        main.isBusy = true
        defer { main.isBusy = false }
        do {
            try await git.commit(at: repo.url, paths: [change.path], message: msg)
            commitSummary = ""
            commitDescription = ""
            commitMode = .commit
            await onFinished()
        } catch {
            main.errorMessage = error.localizedDescription
        }
    }

    func requestRollback(_ change: FileChange) {
        pendingRollback = change
    }

    func confirmRollback(_ change: FileChange) async {
        guard let repo = repoSource() else { return }
        main.isBusy = true
        defer { main.isBusy = false }
        do {
            if change.isUntracked {
                try await git.removeFile(at: repo.url, path: change.path, tracked: false)
            } else {
                try await git.restore(at: repo.url, paths: [change.path])
            }
            await onFinished()
        } catch {
            main.errorMessage = error.localizedDescription
        }
    }

    func addToVCS(_ change: FileChange) async {
        guard let repo = repoSource() else { return }
        main.isBusy = true
        defer { main.isBusy = false }
        do {
            try await git.addToIndex(at: repo.url, paths: [change.path])
            stagedPaths.insert(change.path)
            await refreshStatus()
        } catch {
            main.errorMessage = error.localizedDescription
        }
    }

    func requestDelete(_ change: FileChange) {
        pendingDelete = change
    }

    func confirmDelete(_ change: FileChange) async {
        guard let repo = repoSource() else { return }
        main.isBusy = true
        defer { main.isBusy = false }
        do {
            try await git.removeFile(at: repo.url, path: change.path, tracked: !change.isUntracked)
            await onFinished()
        } catch {
            main.errorMessage = error.localizedDescription
        }
    }

    func copyPatch(_ change: FileChange) async {
        guard let repo = repoSource() else { return }
        do {
            let patch = try await git.diffPatch(at: repo.url, changes: [change])
            #if canImport(AppKit)
            let pb = NSPasteboard.general
            pb.clearContents()
            pb.setString(patch, forType: .string)
            #endif
        } catch {
            main.errorMessage = error.localizedDescription
        }
    }

    func createPatch(_ change: FileChange, to url: URL) async {
        guard let repo = repoSource() else { return }
        do {
            let patch = try await git.diffPatch(at: repo.url, changes: [change])
            try patch.data(using: .utf8)?.write(to: url)
        } catch {
            main.errorMessage = error.localizedDescription
        }
    }

    func jumpToSource(_ change: FileChange) {
        jumpToSourcePath = change.path
    }

    // MARK: - File utilities (right-click)

    /// Absolute URL of a change's working-tree file.
    func absoluteURL(for change: FileChange) -> URL? {
        guard let repo = repoSource() else { return nil }
        return repo.url.appendingPathComponent(change.path)
    }

    /// File name only (last path component).
    func fileName(of change: FileChange) -> String {
        change.path.split(separator: "/").last.map(String.init) ?? change.path
    }

    #if canImport(AppKit)
    private func setClipboard(_ string: String) {
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString(string, forType: .string)
    }

    /// Copy the absolute path.
    func copyAbsolutePath(_ change: FileChange) {
        guard let url = absoluteURL(for: change) else { return }
        setClipboard(url.path)
    }

    /// Copy the repo-relative path.
    func copyRelativePath(_ change: FileChange) {
        setClipboard(change.path)
    }

    /// Copy just the file name.
    func copyFileName(_ change: FileChange) {
        setClipboard(fileName(of: change))
    }

    /// Reveal the file in Finder (or its parent dir if the file is gone).
    func revealInFinder(_ change: FileChange) {
        guard let url = absoluteURL(for: change) else { return }
        if FileManager.default.fileExists(atPath: url.path) {
            NSWorkspace.shared.activateFileViewerSelecting([url])
        } else {
            NSWorkspace.shared.activateFileViewerSelecting([url.deletingLastPathComponent()])
        }
    }

    /// Open the file with the default app.
    func openInDefaultApp(_ change: FileChange) {
        guard let url = absoluteURL(for: change),
              FileManager.default.fileExists(atPath: url.path) else { return }
        NSWorkspace.shared.open(url)
    }

    /// Copy the current on-disk file contents to the clipboard.
    func copyFileContents(_ change: FileChange) {
        guard let url = absoluteURL(for: change),
              let text = try? String(contentsOf: url, encoding: .utf8) else { return }
        setClipboard(text)
    }
    #endif

    func refresh() async {
        await refreshStatus()
    }

    // MARK: - Repo-level actions (right-click Git menu)

    /// Create a branch off the current branch and switch to it.
    func createBranch(name: String) async {
        guard let repo = repoSource(), !main.isBusy else { return }
        main.isBusy = true
        defer { main.isBusy = false }
        do {
            try await git.createBranch(name, from: status?.branch ?? "HEAD", at: repo.url)
            try await git.checkout(name, at: repo.url)
            await onFinished()
        } catch {
            main.errorMessage = error.localizedDescription
        }
    }

    /// Stash all changes (incl. untracked) under an optional title.
    func stashAll(message: String?) async {
        guard let repo = repoSource(), !main.isBusy else { return }
        main.isBusy = true
        defer { main.isBusy = false }
        let m = message?.trimmingCharacters(in: .whitespacesAndNewlines)
        do {
            try await git.stashPush(message: (m?.isEmpty ?? true) ? nil : m, at: repo.url)
            await onFinished()
        } catch {
            main.errorMessage = error.localizedDescription
        }
    }

    /// Tag the current HEAD.
    func tagHead(name: String) async {
        guard let repo = repoSource(), !main.isBusy else { return }
        main.isBusy = true
        defer { main.isBusy = false }
        do {
            try await git.createTag(name, at: "HEAD", message: nil, at: repo.url)
            await onFinished()
        } catch {
            main.errorMessage = error.localizedDescription
        }
    }

    /// Reset the current branch to HEAD with the given mode (hard discards working changes).
    func resetHead(mode: GitResetMode) async {
        guard let repo = repoSource(), !main.isBusy else { return }
        main.isBusy = true
        defer { main.isBusy = false }
        do {
            try await git.resetTo(commit: "HEAD", mode: mode, at: repo.url)
            await onFinished()
        } catch {
            main.errorMessage = error.localizedDescription
        }
    }

    /// Abort an in-progress merge, restoring the pre-merge HEAD/working tree.
    func abortMerge() async {
        guard let repo = repoSource(), !main.isBusy else { return }
        main.isBusy = true
        defer { main.isBusy = false }
        do {
            try await git.abortMerge(at: repo.url)
            await onFinished()
        } catch {
            main.errorMessage = error.localizedDescription
        }
    }

    // MARK: - Cherry-pick sequencer

    /// Escape hatches for a cherry-pick git left open (conflicts, or a pick that
    /// turned out empty). Mirrors `abortMerge`'s shape.
    func continueCherryPick() async { await runSequencerOp { try await self.git.cherryPickContinue(at: $0) } }
    func skipCherryPick() async { await runSequencerOp { try await self.git.cherryPickSkip(at: $0) } }
    func abortCherryPick() async { await runSequencerOp { try await self.git.cherryPickAbort(at: $0) } }

    func continueRebase() async { await runSequencerOp { try await self.git.rebaseContinue(at: $0) } }
    func skipRebase() async { await runSequencerOp { try await self.git.rebaseSkip(at: $0) } }
    func abortRebase() async { await runSequencerOp { try await self.git.rebaseAbort(at: $0) } }

    private func runSequencerOp(_ op: @escaping (URL) async throws -> Void) async {
        guard let repo = repoSource(), !main.isBusy else { return }
        main.isBusy = true
        defer { main.isBusy = false }
        do {
            try await op(repo.url)
            await onFinished()
        } catch {
            main.errorMessage = error.localizedDescription
        }
    }

    // MARK: - Merge conflict resolution

    /// Resolve one conflicted file by taking a whole side (ours/theirs), then stage it.
    func resolveConflict(_ change: FileChange, using side: ConflictSide) async {
        guard let repo = repoSource(), !main.isBusy else { return }
        main.isBusy = true
        defer { main.isBusy = false }
        do {
            try await git.resolveConflict(path: change.path, using: side, at: repo.url)
            await onFinished()
        } catch {
            main.errorMessage = error.localizedDescription
        }
    }

    /// Mark a conflicted file resolved after the user edited it by hand (stages it).
    func markResolved(_ change: FileChange) async {
        guard let repo = repoSource(), !main.isBusy else { return }
        main.isBusy = true
        defer { main.isBusy = false }
        do {
            try await git.markResolved(paths: [change.path], at: repo.url)
            await onFinished()
        } catch {
            main.errorMessage = error.localizedDescription
        }
    }

    /// Branch labels for the Conflicts window: ours = current branch, theirs = MERGE_HEAD.
    func mergeBranchNames() async -> (ours: String, theirs: String) {
        let ours = status?.branch ?? "HEAD"
        guard let repo = repoSource() else { return (ours, "incoming") }
        let theirs = await git.mergeSourceName(at: repo.url) ?? "incoming"
        return (ours, theirs)
    }

    /// Is this conflict a mergeable text file (not a gitlink/binary)? Gates the Merge editor.
    func isMergeableText(_ change: FileChange) async -> Bool {
        guard let repo = repoSource() else { return false }
        return await git.isTextConflict(path: change.path, at: repo.url)
    }

    /// The three conflict stages (base/ours/theirs) for the 3-way merge editor, or nil.
    func mergeStages(_ change: FileChange) async -> (base: String, ours: String, theirs: String)? {
        guard let repo = repoSource() else { return nil }
        return try? await git.readMergeConflict(path: change.path, at: repo.url)
    }

    /// Write the resolved merge output to the working file and stage it (git add).
    func applyMergeResult(_ change: FileChange, content: String) async {
        guard let repo = repoSource() else { return }
        main.isBusy = true
        defer { main.isBusy = false }
        do {
            let url = repo.url.appendingPathComponent(change.path)
            try content.write(to: url, atomically: true, encoding: .utf8)
            try await git.markResolved(paths: [change.path], at: repo.url)
            await onFinished()
        } catch {
            main.errorMessage = error.localizedDescription
        }
    }

    /// Finish the in-progress merge once conflicts are resolved.
    func commitMerge() async {
        guard let repo = repoSource(), !main.isBusy else { return }
        main.isBusy = true
        defer { main.isBusy = false }
        do {
            try await git.commitMerge(at: repo.url)
            commitSummary = ""
            commitDescription = ""
            await onFinished()
        } catch {
            main.errorMessage = error.localizedDescription
        }
    }

    /// Roll every uncommitted change back to HEAD. `includeUntracked` also deletes
    /// untracked files/directories; ignored files are never touched.
    func discardAllChanges(includeUntracked: Bool = true) async {
        guard let repo = repoSource(), let status, !status.changes.isEmpty, !main.isBusy else { return }
        main.isBusy = true
        defer { main.isBusy = false }
        do {
            try await git.discardAll(at: repo.url, includeUntracked: includeUntracked)
            stagedPaths.removeAll()
            selectedChange = nil
            await onFinished()
        } catch {
            main.errorMessage = error.localizedDescription
        }
    }

    /// Save a patch of all local changes via a save panel.
    func createPatchAllChanges() {
        #if canImport(AppKit)
        guard let status, !status.changes.isEmpty else { return }
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "local-changes.patch"
        panel.canCreateDirectories = true
        panel.title = "Save Patch"
        guard panel.runModal() == .OK, let url = panel.url, let repo = repoSource() else { return }
        let changes = status.changes
        Task {
            do {
                let patch = try await git.diffPatch(at: repo.url, changes: changes)
                try patch.data(using: .utf8)?.write(to: url)
            } catch {
                main.errorMessage = error.localizedDescription
            }
        }
        #endif
    }

    /// Create a new worktree from the current branch in a user-picked directory.
    func createWorktree() {
        #if canImport(AppKit)
        guard let repo = repoSource() else { return }
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.title = "Choose Worktree Location"
        panel.prompt = "Create Worktree"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        let from = status?.branch ?? "HEAD"
        Task {
            main.isBusy = true
            defer { main.isBusy = false }
            do {
                try await git.newWorktree(path: url, from: from, at: repo.url)
                await onFinished()
            } catch {
                main.errorMessage = error.localizedDescription
            }
        }
        #endif
    }
}
