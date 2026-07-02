import Foundation
import Combine

/// A single file hit in the Search Everywhere overlay.
struct SearchHit: Identifiable, Hashable {
    let bundleID: URL
    let repoName: String
    let path: String   // repo-relative

    var id: String { "\(bundleID.path)|\(path)" }
    var name: String { (path as NSString).lastPathComponent }
    var dir: String { (path as NSString).deletingLastPathComponent }
}

/// IntelliJ-style "Search Everywhere" (double-Shift): fuzzy file search across
/// every repo in the active workspace. Indexes tracked files via `git ls-files`.
@MainActor
final class SearchEverywhereViewModel: ObservableObject {
    @Published var isPresented = false
    /// Bound to the text field — updates instantly for display.
    @Published var query = ""
    /// Debounced copy of `query`; scoring runs off this to avoid re-scoring the
    /// whole index on every keystroke.
    @Published private var debouncedQuery = ""
    @Published var selectedIndex = 0
    @Published private(set) var indexing = false
    /// nil = all repos. Otherwise restrict to this bundle id.
    @Published var repoFilter: URL? = nil
    @Published private(set) var repoOptions: [RepoOption] = []
    /// Bumped whenever the file index changes, so `results` recomputes in views.
    @Published private var index: [SearchHit] = []

    struct RepoOption: Identifiable, Hashable {
        let id: URL     // bundle id
        let name: String
    }

    private let git: GitRepository
    private let maxResults = 200
    private var cancellables: Set<AnyCancellable> = []

    init(git: GitRepository) {
        self.git = git
        $query
            .debounce(for: .seconds(1), scheduler: DispatchQueue.main)
            .removeDuplicates()
            .sink { [weak self] in self?.debouncedQuery = $0 }
            .store(in: &cancellables)
    }

    func present() {
        query = ""
        debouncedQuery = ""
        selectedIndex = 0
        isPresented = true
    }

    func dismiss() {
        isPresented = false
        query = ""
        debouncedQuery = ""
    }

    /// Filtered + scored results, derived from the debounced query / filter /
    /// index. Computed (not stored) so it can never desync from the inputs.
    var results: [SearchHit] {
        let base = repoFilter == nil ? index : index.filter { $0.bundleID == repoFilter }
        let q = debouncedQuery.trimmingCharacters(in: .whitespaces).lowercased()
        guard !q.isEmpty else { return Array(base.prefix(maxResults)) }
        let scored: [(SearchHit, Int)] = base.compactMap { hit in
            guard let s = Self.score(query: q, hit: hit) else { return nil }
            return (hit, s)
        }
        return scored
            .sorted { $0.1 != $1.1 ? $0.1 > $1.1 : $0.0.path.count < $1.0.path.count }
            .prefix(maxResults)
            .map { $0.0 }
    }

    /// (Re)build the file index from the workspace's repos.
    func buildIndex(_ repos: [(id: URL, name: String, url: URL)]) async {
        repoOptions = repos.map { RepoOption(id: $0.id, name: $0.name) }
        // Drop a stale filter that no longer matches a repo in this workspace.
        if let f = repoFilter, !repos.contains(where: { $0.id == f }) { repoFilter = nil }
        indexing = true
        var all: [SearchHit] = []
        for r in repos {
            let files = (try? await git.listFiles(at: r.url)) ?? []
            for f in files {
                all.append(SearchHit(bundleID: r.id, repoName: r.name, path: f))
            }
        }
        index = all
        indexing = false
    }

    func moveSelection(_ delta: Int) {
        guard !results.isEmpty else { return }
        selectedIndex = max(0, min(results.count - 1, selectedIndex + delta))
    }

    var selectedHit: SearchHit? {
        results.indices.contains(selectedIndex) ? results[selectedIndex] : nil
    }

    // MARK: - Fuzzy scoring

    /// Subsequence fuzzy match. Higher is better; nil if not a subsequence.
    /// Matches against the filename first (weighted) then the full path.
    private static func score(query: String, hit: SearchHit) -> Int? {
        let q = query.lowercased()
        // Filename match is worth more than a deep-path match.
        if let s = subsequenceScore(q, in: hit.name.lowercased()) {
            return s + 1000
        }
        if let s = subsequenceScore(q, in: hit.path.lowercased()) {
            return s
        }
        return nil
    }

    /// Score a subsequence match: reward consecutive runs and start-of-word hits.
    private static func subsequenceScore(_ query: String, in text: String) -> Int? {
        if query.isEmpty { return 0 }
        let t = Array(text)
        var ti = 0
        var score = 0
        var streak = 0
        var prevWasSep = true
        for qc in query {
            var matched = false
            while ti < t.count {
                let c = t[ti]
                let sep = (c == "/" || c == "_" || c == "-" || c == ".")
                if c == qc {
                    score += 1 + streak            // consecutive bonus
                    if prevWasSep { score += 5 }   // word-boundary bonus
                    streak += 1
                    prevWasSep = sep
                    ti += 1
                    matched = true
                    break
                } else {
                    streak = 0
                    prevWasSep = sep
                    ti += 1
                }
            }
            if !matched { return nil }
        }
        return score
    }
}
