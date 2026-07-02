import Foundation
import Combine
import AppKit

/// Drives the Pull Requests tab for one repo: fetch (paginated), client-side
/// search/state/author filtering, and per-PR detail. Mirrors `RemoteViewModel`'s
/// token/account plumbing (`account.account` + `account.storedToken()`).
@MainActor
final class PullRequestsViewModel: ObservableObject {
    enum StateFilter: Hashable, CaseIterable {
        case all, open, merged, declined
        var label: String {
            switch self {
            case .all: return "All"
            case .open: return "Open"
            case .merged: return "Merged"
            case .declined: return "Declined"
            }
        }
        func matches(_ s: PullRequestState) -> Bool {
            switch self {
            case .all: return true
            case .open: return s == .open || s == .draft
            case .merged: return s == .merged
            case .declined: return s == .declined || s == .superseded || s == .closed
            }
        }
    }

    @Published private(set) var loaded: [PullRequestSummary] = []
    @Published private(set) var hasMore = false
    @Published private(set) var isLoading = false
    @Published private(set) var isLoadingMore = false

    @Published var searchText = ""
    @Published var stateFilter: StateFilter = .all
    @Published var authorFilter: String?

    enum DetailTab: Hashable { case overview, files, commits }

    @Published var selected: PullRequestSummary?
    @Published private(set) var detail: PullRequestDetail?
    @Published private(set) var detailLoading = false

    @Published var detailTab: DetailTab = .overview
    @Published private(set) var files: [PRFileChange] = []
    @Published private(set) var filesLoading = false
    @Published private(set) var filesLoaded = false
    @Published private(set) var commits: [PRCommit] = []
    @Published private(set) var commitsLoading = false
    @Published private(set) var commitsLoaded = false

    /// Commit drilled into within the Commits tab (nil → show the commit list).
    @Published var selectedCommit: PRCommit?
    @Published private(set) var commitFiles: [PRFileChange] = []
    @Published private(set) var commitFilesLoading = false

    private let pullRequests: PullRequestRepository
    private let account: AccountViewModel
    private let main: MainViewModel
    private var page = 1
    private var cancellables = Set<AnyCancellable>()

    init(pullRequests: PullRequestRepository, account: AccountViewModel, main: MainViewModel) {
        self.pullRequests = pullRequests
        self.account = account
        self.main = main

        $selected
            .removeDuplicates()
            .sink { [weak self] pr in
                guard let self else { return }
                Task { await self.loadDetail(pr) }
            }
            .store(in: &cancellables)
    }

    var isSupportedHost: Bool { PullRequestRouter.supports(host: account.account?.host) }
    var hasToken: Bool { account.storedToken() != nil }

    /// Distinct author names present in the loaded set (for the author menu).
    var authors: [String] {
        Array(Set(loaded.map(\.authorName))).sorted()
    }

    /// The list after applying state + author + search filters.
    var filtered: [PullRequestSummary] {
        let q = searchText.trimmingCharacters(in: .whitespaces).lowercased()
        return loaded.filter { pr in
            stateFilter.matches(pr.state)
                && (authorFilter == nil || pr.authorName == authorFilter)
                && (q.isEmpty || pr.title.lowercased().contains(q)
                    || String(pr.number).contains(q))
        }
    }

    private func coordinates() -> (host: String, owner: String, repo: String, token: String)? {
        guard let acc = account.account,
              let host = acc.host, let owner = acc.owner, let repo = acc.repo else { return nil }
        guard let token = account.storedToken() else { return nil }
        return (host, owner, repo, token)
    }

    func refresh() async {
        guard isSupportedHost else { return }
        guard let c = coordinates() else {
            // No token yet — clear rather than error; the UI shows an add-token prompt.
            loaded = []; hasMore = false
            return
        }
        isLoading = true
        defer { isLoading = false }
        page = 1
        do {
            let result = try await pullRequests.list(
                host: c.host, owner: c.owner, repo: c.repo, page: page, token: c.token
            )
            loaded = result.items
            hasMore = result.hasMore
        } catch {
            main.errorMessage = error.localizedDescription
        }
    }

    func loadMore() async {
        guard hasMore, !isLoadingMore, let c = coordinates() else { return }
        isLoadingMore = true
        defer { isLoadingMore = false }
        page += 1
        do {
            let result = try await pullRequests.list(
                host: c.host, owner: c.owner, repo: c.repo, page: page, token: c.token
            )
            loaded.append(contentsOf: result.items)
            hasMore = result.hasMore
        } catch {
            page -= 1
            main.errorMessage = error.localizedDescription
        }
    }

    private func loadDetail(_ pr: PullRequestSummary?) async {
        // Reset all sub-tab state for the newly selected PR.
        detail = nil
        detailTab = .overview
        files = []; filesLoaded = false
        commits = []; commitsLoaded = false
        selectedCommit = nil; commitFiles = []
        guard let pr, let c = coordinates() else { return }
        detailLoading = true
        defer { detailLoading = false }
        do {
            detail = try await pullRequests.detail(
                host: c.host, owner: c.owner, repo: c.repo, number: pr.number, token: c.token
            )
        } catch {
            main.errorMessage = error.localizedDescription
        }
    }

    /// Lazily fetch files for the selected PR (once per selection).
    func loadFiles() async {
        guard !filesLoaded, !filesLoading, let pr = selected, let c = coordinates() else { return }
        filesLoading = true
        defer { filesLoading = false }
        do {
            files = try await pullRequests.files(
                host: c.host, owner: c.owner, repo: c.repo, number: pr.number, token: c.token
            )
            filesLoaded = true
        } catch {
            main.errorMessage = error.localizedDescription
        }
    }

    /// Drill into a commit and load its changed files.
    func selectCommit(_ c: PRCommit?) {
        selectedCommit = c
        commitFiles = []
        guard let c else { return }
        Task { await loadCommitFiles(c) }
    }

    private func loadCommitFiles(_ c: PRCommit) async {
        guard let coords = coordinates() else { return }
        commitFilesLoading = true
        defer { commitFilesLoading = false }
        do {
            let loaded = try await pullRequests.commitFiles(
                host: coords.host, owner: coords.owner, repo: coords.repo, sha: c.id, token: coords.token
            )
            // Guard against a stale response if the user changed selection.
            if selectedCommit?.id == c.id { commitFiles = loaded }
        } catch {
            main.errorMessage = error.localizedDescription
        }
    }

    /// Lazily fetch commits for the selected PR (once per selection).
    func loadCommits() async {
        guard !commitsLoaded, !commitsLoading, let pr = selected, let c = coordinates() else { return }
        commitsLoading = true
        defer { commitsLoading = false }
        do {
            commits = try await pullRequests.commits(
                host: c.host, owner: c.owner, repo: c.repo, number: pr.number, token: c.token
            )
            commitsLoaded = true
        } catch {
            main.errorMessage = error.localizedDescription
        }
    }

    func openInBrowser(_ pr: PullRequestSummary) {
        NSWorkspace.shared.open(pr.url)
    }

    func repositoryDidChange() {
        loaded = []
        hasMore = false
        selected = nil
        detail = nil
        detailTab = .overview
        files = []; filesLoaded = false
        commits = []; commitsLoaded = false
        searchText = ""
        authorFilter = nil
        stateFilter = .all
        page = 1
    }
}
