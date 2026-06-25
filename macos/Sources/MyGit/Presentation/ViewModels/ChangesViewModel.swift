import Foundation
import Combine

enum CommitMode: Equatable {
    case commit
    case amendKeepMessage
    case amendUpdateMessage
}

@MainActor
final class ChangesViewModel: ObservableObject {
    @Published var status: GitStatusSummary?
    @Published var selectedChange: FileChange?
    @Published var diff: FileDiff?
    @Published var stagedPaths: Set<String> = []
    @Published var commitSummary: String = ""
    @Published var commitDescription: String = ""
    @Published var commitMode: CommitMode = .commit
    @Published var canAmend: Bool = false

    private let git: GitRepository
    private let main: MainViewModel
    private let repoSource: () -> Repository?
    private var onFinished: () async -> Void = {}
    private var previousPaths: Set<String> = []
    private var cancellables: Set<AnyCancellable> = []

    init(git: GitRepository, main: MainViewModel, repoSource: @escaping () -> Repository?) {
        self.git = git
        self.main = main
        self.repoSource = repoSource

        $selectedChange
            .removeDuplicates()
            .sink { [weak self] change in
                guard let self, let change else { return }
                Task { await self.loadDiff(for: change) }
            }
            .store(in: &cancellables)
    }

    func setOnFinished(_ block: @escaping () async -> Void) {
        self.onFinished = block
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
        case .commit:
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
        do {
            switch commitMode {
            case .commit:
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
}
