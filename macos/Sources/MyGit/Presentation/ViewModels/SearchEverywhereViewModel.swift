import Foundation
import Combine

/// A single file hit in the Search Everywhere overlay.
struct SearchHit: Identifiable, Hashable {
    let bundleID: URL
    let repoName: String
    let path: String   // repo-relative
    /// Set for content (`git grep`) hits: the matching line + its text preview.
    var matchLine: Int? = nil
    var preview: String? = nil

    var id: String { "\(bundleID.path)|\(path)" }
    var name: String { (path as NSString).lastPathComponent }
    var dir: String { (path as NSString).deletingLastPathComponent }
    var ext: String { (path as NSString).pathExtension.lowercased() }
}

/// What the query matches against.
enum SearchScope: String, CaseIterable, Identifiable {
    case name       // filename / path only (default — fast, in-memory)
    case content    // file contents only (git grep)
    case both       // name + contents

    var id: String { rawValue }
    var label: String {
        switch self {
        case .name: return "File name"
        case .content: return "Contents"
        case .both: return "Name & contents"
        }
    }
    var icon: String {
        switch self {
        case .name: return "doc.text.magnifyingglass"
        case .content: return "text.magnifyingglass"
        case .both: return "sparkle.magnifyingglass"
        }
    }
}

/// IntelliJ-style "Search Everywhere" (double-Shift): fuzzy file search across
/// every repo in the active workspace. Indexes tracked files via `git ls-files`.
@MainActor
final class SearchEverywhereViewModel: ObservableObject {
    @Published var isPresented = false
    /// Bound to the text field — updates instantly for display.
    @Published var query = ""
    @Published var selectedIndex = 0
    @Published private(set) var indexing = false
    /// True while a `git grep` content search is in flight.
    @Published private(set) var searchingContent = false
    /// nil = all repos. Otherwise restrict to this bundle id.
    @Published var repoFilter: URL? = nil
    @Published private(set) var repoOptions: [RepoOption] = []
    /// What the query matches against (name / contents / both).
    @Published var scope: SearchScope = .name
    /// nil = all file types. Otherwise restrict to this extension (e.g. "swift").
    @Published var typeFilter: String? = nil
    /// Bumped whenever the file index changes, so `results` recomputes in views.
    @Published private var index: [SearchHit] = []
    /// Content-search hits for the current debounced query (git grep output).
    @Published private var contentHits: [SearchHit] = []

    struct RepoOption: Identifiable, Hashable {
        let id: URL     // bundle id
        let name: String
    }

    private let git: GitRepository
    private let maxResults = 200
    private var cancellables: Set<AnyCancellable> = []
    /// Repos to grep, captured from the last `buildIndex`.
    private var repos: [(id: URL, name: String, url: URL)] = []
    private var contentTask: Task<Void, Never>?

    init(git: GitRepository) {
        self.git = git
        // Content grep spawns a process per repo — debounce it longer. Re-run
        // whenever the query, scope, or repo scope changes.
        Publishers.CombineLatest3(
            $query.debounce(for: .milliseconds(500), scheduler: DispatchQueue.main).removeDuplicates(),
            $scope, $repoFilter
        )
            .sink { [weak self] q, scope, filter in
                self?.runContentSearch(query: q, scope: scope, repoFilter: filter)
            }
            .store(in: &cancellables)
    }

    var indexCount: Int { index.count }

    /// Extensions present in the index, for the file-type filter menu.
    var typeOptions: [String] {
        Set(index.compactMap { $0.ext.isEmpty ? nil : $0.ext }).sorted()
    }

    func present() {
        query = ""
        selectedIndex = 0
        isPresented = true
    }

    func dismiss() {
        isPresented = false
        query = ""
        contentTask?.cancel()
        contentHits = []
    }

    /// Does a hit pass the repo + file-type filters (query-independent)?
    private func passesFilters(_ hit: SearchHit) -> Bool {
        if let f = repoFilter, hit.bundleID != f { return false }
        if let ext = typeFilter, hit.ext != ext { return false }
        return true
    }

    /// Filtered + scored results, derived from the debounced query / filters /
    /// index / content hits. Computed (not stored) so it can never desync.
    var results: [SearchHit] {
        // Name search is in-memory and cheap — filter off the LIVE query so it
        // can never desync from a Combine pipeline that isn't delivering.
        let q = query.trimmingCharacters(in: .whitespaces).lowercased()

        // Name (fuzzy) hits over the in-memory index.
        var nameHits: [SearchHit] = []
        if scope != .content {
            let base = index.filter(passesFilters)
            if q.isEmpty {
                nameHits = Array(base.prefix(maxResults))
            } else {
                nameHits = base.compactMap { hit -> (SearchHit, Int)? in
                    guard let s = Self.score(query: q, hit: hit) else { return nil }
                    return (hit, s)
                }
                .sorted { $0.1 != $1.1 ? $0.1 > $1.1 : $0.0.path.count < $1.0.path.count }
                .map { $0.0 }
            }
        }
        if scope == .name { return Array(nameHits.prefix(maxResults)) }

        // Content hits are already query-matched by git grep; apply UI filters.
        let content = contentHits.filter(passesFilters)
        if scope == .content { return Array(content.prefix(maxResults)) }

        // Both: name hits first, then content-only hits not already listed.
        var seen = Set(nameHits.map(\.id))
        var merged = nameHits
        for c in content where !seen.contains(c.id) {
            merged.append(c)
            seen.insert(c.id)
        }
        return Array(merged.prefix(maxResults))
    }

    /// Kick off a `git grep` across the (repo-scoped) workspace. No-op unless the
    /// scope needs contents and the query is non-empty.
    private func runContentSearch(query: String, scope: SearchScope, repoFilter: URL?) {
        contentTask?.cancel()
        let q = query.trimmingCharacters(in: .whitespaces)
        guard scope != .name, !q.isEmpty else {
            contentHits = []
            searchingContent = false
            return
        }
        let targets = repos.filter { repoFilter == nil || $0.id == repoFilter }
        searchingContent = true
        contentTask = Task { [weak self, git] in
            var hits: [SearchHit] = []
            for r in targets {
                if Task.isCancelled { return }
                let matches = (try? await git.grep(query: q, at: r.url)) ?? []
                for m in matches {
                    hits.append(SearchHit(bundleID: r.id, repoName: r.name, path: m.path,
                                          matchLine: m.line, preview: m.preview))
                }
            }
            if Task.isCancelled { return }
            await MainActor.run {
                guard let self, !Task.isCancelled else { return }
                self.contentHits = hits
                self.searchingContent = false
            }
        }
    }

    /// (Re)build the file index from the workspace's repos.
    func buildIndex(_ repos: [(id: URL, name: String, url: URL)]) async {
        self.repos = repos
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
