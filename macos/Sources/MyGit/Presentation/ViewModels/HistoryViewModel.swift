import Foundation
import Combine

@MainActor
final class HistoryViewModel: ObservableObject {
    @Published var commits: [GitCommit] = []
    @Published var selectedCommit: GitCommit?
    @Published var diff: FileDiff?

    private let git: GitRepository
    private let main: MainViewModel
    private let repoSource: () -> Repository?
    private var cancellables: Set<AnyCancellable> = []

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

    func repositoryDidChange() {
        selectedCommit = nil
        diff = nil
        commits = []
    }

    func refreshLog() async {
        guard let repo = repoSource() else { commits = []; return }
        do {
            commits = try await git.log(at: repo.url, limit: 300)
            if selectedCommit == nil { selectedCommit = commits.first }
        } catch {
            commits = []
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
}
