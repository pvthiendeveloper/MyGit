import Foundation
import Combine

@MainActor
final class ChangesViewModel: ObservableObject {
    @Published var status: GitStatusSummary?
    @Published var selectedChange: FileChange?
    @Published var diff: FileDiff?
    @Published var stagedPaths: Set<String> = []
    @Published var commitSummary: String = ""
    @Published var commitDescription: String = ""

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
    }

    func refreshStatus() async {
        guard let repo = repoSource() else { status = nil; return }
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
        } catch {
            main.errorMessage = error.localizedDescription
        }
    }

    private func loadDiff(for change: FileChange) async {
        guard let repo = repoSource() else { return }
        diff = try? await git.diff(at: repo.url, change: change)
    }

    var canCommit: Bool {
        !commitSummary.trimmingCharacters(in: .whitespaces).isEmpty &&
        !stagedPaths.isEmpty &&
        repoSource() != nil
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
        var msg = commitSummary
        let descTrim = commitDescription.trimmingCharacters(in: .whitespacesAndNewlines)
        if !descTrim.isEmpty { msg += "\n\n" + descTrim }
        do {
            try await git.commit(at: repo.url, paths: toStage, message: msg)
            commitSummary = ""
            commitDescription = ""
            await onFinished()
        } catch {
            main.errorMessage = error.localizedDescription
        }
    }
}
