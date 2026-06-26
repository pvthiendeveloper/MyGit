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
            let kept = stagedPaths.intersection(allPaths)
            if kept.isEmpty {
                stagedPaths = allPaths
            } else {
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

    func setAllStaged(_ on: Bool) {
        guard let status else { return }
        stagedPaths = on ? Set(status.changes.map { $0.path }) : []
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
        do {
            switch modeAtStart {
            case .commit, .commitAndPush, .commitAndForcePush:
                try await git.commit(at: repo.url, paths: toStage, message: composedMessage)
            case .amendKeepMessage:
                try await git.amend(at: repo.url, paths: toStage, newMessage: nil)
            case .amendUpdateMessage:
                try await git.amend(at: repo.url, paths: toStage, newMessage: composedMessage)
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

    func refresh() async {
        await refreshStatus()
    }
}
