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

    /// Widest lane span across all rows — drives the graph column width.
    var graphColumns: Int { graphRows.map { $0.maxColumns }.max() ?? 1 }

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

    func repositoryDidChange() {
        selectedCommit = nil
        diff = nil
        changedFiles = []
        commits = []
        graphRows = []
        limit = pageSize
        hasMore = false
    }

    func refreshLog() async {
        guard let repo = repoSource() else {
            commits = []; graphRows = []; hasMore = false; return
        }
        do {
            let loaded = try await git.graphLog(at: repo.url, limit: limit, filter: filter)
            commits = loaded
            graphRows = CommitGraph.layout(loaded)
            hasMore = loaded.count >= limit
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
