import Foundation
import Combine

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
    @Published var openFileDiff: OpenFileDiff? = nil
    @Published var isLoading = false
    @Published var isLoadingFiles = false
    @Published var errorMessage: String? = nil
    @Published var pathsFilterHashesAB: Set<String>? = nil
    @Published var pathsFilterHashesBA: Set<String>? = nil

    private var git: GitRepository = GitCLIRepository()
    private var repoSource: () -> URL? = { nil }
    private var cancellables = Set<AnyCancellable>()
    private var pipelineSetup = false

    // Configure after view appearance when environment objects are available
    func configure(pair: ComparePair, git: GitRepository, repoSource: @escaping () -> URL?) {
        self.pair = pair
        self.git = git
        self.repoSource = repoSource
        if !pipelineSetup { setupPipelines() }
    }

    var authorsAB: [String] { Array(Set(commitsAB.map { $0.author })).sorted() }
    var authorsBA: [String] { Array(Set(commitsBA.map { $0.author })).sorted() }

    var filteredAB: [GitCommit] { applyFilter(filterAB, to: commitsAB, pathHashes: pathsFilterHashesAB) }
    var filteredBA: [GitCommit] { applyFilter(filterBA, to: commitsBA, pathHashes: pathsFilterHashesBA) }

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
        guard let repoURL = repoSource() else { return }
        let commit = focused == .aMinusB ? selectedAB : selectedBA
        guard let commit else { return }
        Task {
            do {
                let diff = try await git.showFileAtCommit(commit: commit.hash, path: entry.path, at: repoURL)
                openFileDiff = OpenFileDiff(entry: entry, diff: diff)
            } catch {
                errorMessage = error.localizedDescription
            }
        }
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

    private func applyFilter(_ filter: CompareFilter, to commits: [GitCommit], pathHashes: Set<String>?) -> [GitCommit] {
        var result = commits
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
