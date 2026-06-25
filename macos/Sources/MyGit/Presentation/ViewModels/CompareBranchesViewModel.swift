import Foundation
import Combine
import AppKit

@MainActor
final class CompareBranchesViewModel: ObservableObject {
    @Published private(set) var pair: ComparePair = ComparePair(a: "", b: "")
    @Published var commitsAB: [GitCommit] = []
    @Published var commitsBA: [GitCommit] = []
    @Published var filterAB = CompareFilter()
    @Published var filterBA = CompareFilter()
    @Published var selectedAB: GitCommit?
    @Published var selectedBA: GitCommit?
    @Published var focused: CompareSide = .aMinusB
    @Published var changedFiles: [ChangedFileEntry] = []
    @Published var isLoading = false
    @Published var isLoadingFiles = false
    @Published var errorMessage: String? = nil
    @Published var pathsFilterHashesAB: Set<String>? = nil
    @Published var pathsFilterHashesBA: Set<String>? = nil
    @Published var upToCommitAB: String? = nil
    @Published var upToCommitBA: String? = nil

    private var git: GitRepository = GitCLIRepository()
    private var repoSource: () -> URL? = { nil }
    private var openDiffTab: (String, String, String, DiffTab.Mode, Bool) -> Void = { _, _, _, _, _ in }
    private var cancellables = Set<AnyCancellable>()
    private var pipelineSetup = false

    // Configure after view appearance when environment objects are available
    func configure(
        pair: ComparePair,
        git: GitRepository,
        repoSource: @escaping () -> URL?,
        openDiffTab: @escaping (String, String, String, DiffTab.Mode, Bool) -> Void
    ) {
        self.pair = pair
        self.git = git
        self.repoSource = repoSource
        self.openDiffTab = openDiffTab
        if !pipelineSetup { setupPipelines() }
    }

    var authorsAB: [String] { Array(Set(commitsAB.map { $0.author })).sorted() }
    var authorsBA: [String] { Array(Set(commitsBA.map { $0.author })).sorted() }

    var filteredAB: [GitCommit] {
        applyFilter(filterAB, to: commitsAB, pathHashes: pathsFilterHashesAB, upTo: upToCommitAB)
    }
    var filteredBA: [GitCommit] {
        applyFilter(filterBA, to: commitsBA, pathHashes: pathsFilterHashesBA, upTo: upToCommitBA)
    }

    func load() async {
        guard !pair.a.isEmpty, let repoURL = repoSource() else { return }
        isLoading = true
        defer { isLoading = false }
        do {
            async let ab = git.commitsInRange("\(pair.b)..\(pair.a)", at: repoURL)
            async let ba = git.commitsInRange("\(pair.a)..\(pair.b)", at: repoURL)
            (commitsAB, commitsBA) = try await (ab, ba)
            selectedAB = nil
            selectedBA = nil
            changedFiles = []
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func swap() {
        pair = ComparePair(a: pair.b, b: pair.a)
        filterAB = CompareFilter()
        filterBA = CompareFilter()
        pathsFilterHashesAB = nil
        pathsFilterHashesBA = nil
        Task { await load() }
    }

    func selectCommit(_ commit: GitCommit, side: CompareSide) {
        focused = side
        if side == .aMinusB { selectedAB = commit } else { selectedBA = commit }
        Task { await loadChangedFiles(for: commit) }
    }

    func openFile(_ entry: ChangedFileEntry) {
        guard repoSource() != nil else { return }
        let commit = focused == .aMinusB ? selectedAB : selectedBA
        guard let commit else { return }
        openDiffTab(commit.hash, commit.shortHash, entry.path, .commitVsParent, false)
    }

    func applyPathsFilter(paths: [String], side: CompareSide) {
        guard let repoURL = repoSource() else { return }
        let range = side == .aMinusB ? "\(pair.b)..\(pair.a)" : "\(pair.a)..\(pair.b)"
        Task {
            do {
                let hashes = paths.isEmpty ? nil : try await git.touchedHashes(range: range, paths: paths, at: repoURL)
                if side == .aMinusB { pathsFilterHashesAB = hashes } else { pathsFilterHashesBA = hashes }
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }

    private func loadChangedFiles(for commit: GitCommit) async {
        guard let repoURL = repoSource() else { return }
        isLoadingFiles = true
        defer { isLoadingFiles = false }
        do {
            changedFiles = try await git.changedFiles(commit: commit.hash, at: repoURL)
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func applyFilter(
        _ filter: CompareFilter,
        to commits: [GitCommit],
        pathHashes: Set<String>?,
        upTo: String?
    ) -> [GitCommit] {
        var result = commits
        if let upTo, let idx = result.firstIndex(where: { $0.hash == upTo }) {
            result = Array(result[idx...])
        }
        if !filter.text.isEmpty {
            let q = filter.text.lowercased()
            result = result.filter { $0.subject.lowercased().contains(q) || $0.shortHash.contains(q) }
        }
        if let author = filter.author, !author.isEmpty {
            result = result.filter { $0.author == author }
        }
        if let from = filter.dateFrom {
            result = result.filter { $0.date >= from }
        }
        if let to = filter.dateTo {
            let end = Calendar.current.date(byAdding: .day, value: 1, to: to) ?? to
            result = result.filter { $0.date < end }
        }
        if let hashes = pathHashes {
            result = result.filter { hashes.contains($0.hash) }
        }
        return filter.sort == .newestFirst ? result : result.reversed()
    }

    func clearHistoryUpTo(side: CompareSide) {
        if side == .aMinusB { upToCommitAB = nil } else { upToCommitBA = nil }
    }

    func perform(_ action: CompareFileAction, on entry: ChangedFileEntry) {
        guard let repoURL = repoSource() else { return }
        let commit = focused == .aMinusB ? selectedAB : selectedBA
        guard let commit else { return }
        switch action {
        case .showDiff:
            openDiffTab(commit.hash, commit.shortHash, entry.path, .commitVsParent, false)
        case .showDiffInNewTab:
            openDiffTab(commit.hash, commit.shortHash, entry.path, .commitVsParent, true)
        case .compareWithLocal:
            openDiffTab(commit.hash, commit.shortHash, entry.path, .commitVsWorking, true)
        case .compareBeforeWithLocal:
            openDiffTab(commit.hash, commit.shortHash, entry.path, .parentVsWorking, true)
        case .editSource:
            let url = repoURL.appendingPathComponent(entry.path)
            if FileManager.default.fileExists(atPath: url.path) {
                NSWorkspace.shared.open(url)
            } else {
                errorMessage = "File no longer exists in the working tree."
            }
        case .openRepositoryVersion:
            Task {
                do {
                    let url = try await git.extractFileAtCommit(commit: commit.hash, path: entry.path, at: repoURL)
                    NSWorkspace.shared.open(url)
                } catch {
                    errorMessage = error.localizedDescription
                }
            }
        case .revertChanges:
            Task {
                do { try await git.revertFileInCommit(commit: commit.hash, path: entry.path, at: repoURL) }
                catch { errorMessage = error.localizedDescription }
            }
        case .cherryPickChanges:
            Task {
                do { try await git.cherryPickFileFromCommit(commit: commit.hash, path: entry.path, at: repoURL) }
                catch { errorMessage = error.localizedDescription }
            }
        case .dropChanges:
            errorMessage = "Drop Selected Changes requires history rewrite and isn't supported yet."
        case .createPatch:
            Task {
                do {
                    let patch = try await git.patchForFile(commit: commit.hash, path: entry.path, at: repoURL)
                    let suggested = "\(commit.shortHash)-\((entry.path as NSString).lastPathComponent).patch"
                    savePatch(patch, suggestedName: suggested)
                } catch {
                    errorMessage = error.localizedDescription
                }
            }
        case .historyUpToHere:
            if focused == .aMinusB { upToCommitAB = commit.hash } else { upToCommitBA = commit.hash }
        }
    }

    private func savePatch(_ patch: String, suggestedName: String) {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = suggestedName
        panel.canCreateDirectories = true
        if panel.runModal() == .OK, let url = panel.url {
            do {
                try patch.write(to: url, atomically: true, encoding: .utf8)
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }

    private func setupPipelines() {
        pipelineSetup = true
        $filterAB.map { $0.paths }.removeDuplicates().dropFirst()
            .debounce(for: .milliseconds(400), scheduler: DispatchQueue.main)
            .sink { [weak self] paths in self?.applyPathsFilter(paths: paths, side: .aMinusB) }
            .store(in: &cancellables)

        $filterBA.map { $0.paths }.removeDuplicates().dropFirst()
            .debounce(for: .milliseconds(400), scheduler: DispatchQueue.main)
            .sink { [weak self] paths in self?.applyPathsFilter(paths: paths, side: .bMinusA) }
            .store(in: &cancellables)
    }
}
