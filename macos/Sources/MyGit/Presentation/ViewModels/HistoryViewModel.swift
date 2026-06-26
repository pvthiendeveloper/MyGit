import Foundation
import Combine

@MainActor
final class HistoryViewModel: ObservableObject {
    @Published var commits: [GitCommit] = []
    @Published var selectedCommit: GitCommit?
    @Published var diff: FileDiff?
    /// True when the last fetch hit the limit — more commits may exist.
    @Published private(set) var hasMore = false
    @Published private(set) var isLoadingMore = false

    private let pageSize = 100
    private var limit = 100

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
        limit = pageSize
        hasMore = false
    }

    func refreshLog() async {
        guard let repo = repoSource() else { commits = []; hasMore = false; return }
        do {
            let loaded = try await git.log(at: repo.url, limit: limit)
            commits = loaded
            hasMore = loaded.count >= limit
            if selectedCommit == nil { selectedCommit = commits.first }
        } catch {
            commits = []
            hasMore = false
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

    private func loadDiff(for commit: GitCommit) async {
        guard let repo = repoSource() else { return }
        do {
            diff = try await git.diff(at: repo.url, commit: commit)
        } catch {
            main.errorMessage = error.localizedDescription
        }
    }
}
