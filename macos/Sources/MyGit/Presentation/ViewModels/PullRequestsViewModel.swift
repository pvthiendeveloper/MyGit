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

    /// True while the right panel shows the "Create Pull Request" composer
    /// instead of a selected PR's detail.
    @Published var isComposing = false

    @Published var selected: PullRequestSummary?
    @Published private(set) var detail: PullRequestDetail?
    @Published private(set) var detailLoading = false

    /// True while a review (approve / request-changes / withdraw) is in flight.
    @Published private(set) var reviewSubmitting = false
    /// The token's own user, resolved once per repo; drives `myReviewState`.
    private var currentUser: PRUser?

    /// Merge-readiness checklist for the selected PR (best-effort, host-specific).
    @Published private(set) var mergeChecks: [PRMergeCheck] = []

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
    private let git: GitRepository
    private let repoSource: () -> Repository?
    private var page = 1
    private var cancellables = Set<AnyCancellable>()

    /// Local git `user.name`, resolved once — the authorship fallback when the
    /// host can't tell us who we are (Bitbucket token without `read:user`).
    private var localName: String?
    private var localNameResolved = false

    init(
        pullRequests: PullRequestRepository,
        account: AccountViewModel,
        main: MainViewModel,
        git: GitRepository,
        repoSource: @escaping () -> Repository?
    ) {
        self.pullRequests = pullRequests
        self.account = account
        self.main = main
        self.git = git
        self.repoSource = repoSource

        $selected
            .removeDuplicates()
            .sink { [weak self] pr in
                guard let self else { return }
                // Picking a PR leaves compose mode so the detail shows.
                if pr != nil { self.isComposing = false }
                Task { await self.loadDetail(pr) }
            }
            .store(in: &cancellables)
    }

    var isSupportedHost: Bool { PullRequestRouter.supports(host: account.account?.host) }
    var hasToken: Bool { account.storedToken() != nil }

    /// The signed-in user's standing on the selected PR. Matched by host id when
    /// available, else by normalized display name vs. local git `user.name` (same
    /// fallback as `isMyPR`, for Bitbucket tokens that can't resolve `/user`).
    var myReviewState: PRReviewState {
        guard let d = detail else { return .none }
        let mine: PRParticipant?
        if let me = currentUser {
            mine = d.participants.first { $0.id != nil && $0.id == me.id }
        } else if let local = localName {
            mine = d.participants.first { Self.normalizedName($0.name) == Self.normalizedName(local) }
        } else {
            mine = nil
        }
        guard let mine else { return .none }
        if mine.approved { return .approved }
        if mine.requestedChanges { return .changesRequested }
        return .none
    }

    private var host: String? { account.account?.host }
    var isGitHub: Bool { host?.lowercased().contains("github") ?? false }
    var isBitbucket: Bool { host?.lowercased().contains("bitbucket") ?? false }

    /// True when the selected PR was opened by the signed-in user. Preferred:
    /// host-stable author id vs. resolved `currentUser`. Fallback (when the host
    /// won't tell us who we are, e.g. a Bitbucket token without `read:user`):
    /// compare the author's display name to the local git `user.name`, normalized
    /// so `Thien Pham (Genesis)` matches `Thien Pham [Genesis]`.
    /// Hides the Approve/Request-changes bar on your own PR.
    var isMyPR: Bool {
        if let me = currentUser, let mine = selected?.authorId {
            return mine == me.id
        }
        if let local = localName, let author = selected?.authorName {
            return Self.normalizedName(local) == Self.normalizedName(author)
        }
        return false
    }

    /// Lowercased, bracket/paren-stripped, whitespace-collapsed name for loose
    /// identity comparison across git config vs. host display names.
    private static func normalizedName(_ s: String) -> String {
        let stripped = s.unicodeScalars.filter { !"()[]{}".unicodeScalars.contains($0) }
        return String(String.UnicodeScalarView(stripped))
            .lowercased()
            .split(whereSeparator: { $0 == " " || $0 == "\t" })
            .joined(separator: " ")
    }

    /// Set once a detail load has attempted to resolve the host user (`/user`).
    private var identityResolved = false

    /// True only when we have NO identity signal at all — neither a host user
    /// (`/user` 403'd, e.g. Bitbucket without `account` scope) nor a local git
    /// `user.name` to name-match against. Then authorship is unknowable, so we
    /// fall back to the write-access model (offer manage actions on any PR).
    var identityUnknown: Bool {
        hasToken && currentUser == nil && localName == nil
            && identityResolved && localNameResolved
    }

    /// Offer author/maintainer actions only on your own PR. When identity is
    /// wholly unknown, fall back to offering them on any PR (write-access).
    var canManage: Bool { isMyPR || identityUnknown }

    /// Reviewer actions apply only while the PR is still open — and not to your
    /// own PR (you review others' PRs, you manage your own). When identity is
    /// unknown we can't tell it's yours, so Approve stays available too.
    var canReview: Bool {
        guard hasToken, !isMyPR, let s = selected?.state else { return false }
        return s == .open || s == .draft
    }

    // MARK: - Author / maintainer action availability

    /// True when a blocking merge check is failing — the Merge button is offered
    /// but disabled, and the checklist shows why.
    var mergeBlocked: Bool { mergeChecks.contains { $0.blocking && !$0.passed } }

    /// Merge is offered on an open (non-draft) PR you can manage.
    var canMerge: Bool { canManage && selected?.state == .open }
    /// Decline/Close applies while the PR is still live.
    var canDecline: Bool {
        guard canManage, let s = selected?.state else { return false }
        return s == .open || s == .draft
    }
    /// Reopen: GitHub only (Bitbucket can't reopen a declined PR), and only for a
    /// closed-not-merged PR.
    var canReopen: Bool { canManage && isGitHub && selected?.state == .closed }
    /// Convert an open PR to a draft.
    var canMarkDraft: Bool { canManage && selected?.state == .open }
    /// Mark a draft PR ready for review.
    var canMarkReady: Bool { canManage && selected?.state == .draft }
    /// Whether any management action is available (drives showing the bar).
    var hasOwnerActions: Bool {
        hasToken && (canMerge || canDecline || canReopen || canMarkDraft || canMarkReady)
    }
    /// Whether the "More" overflow menu has any items (everything but Merge, which
    /// is a standalone button).
    var hasMenuActions: Bool { canDecline || canReopen || canMarkDraft || canMarkReady }

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
        mergeChecks = []
        guard let pr, let c = coordinates() else { return }
        detailLoading = true
        defer { detailLoading = false }
        do {
            detail = try await pullRequests.detail(
                host: c.host, owner: c.owner, repo: c.repo, number: pr.number, token: c.token
            )
            // Merge-readiness checklist — only meaningful while the PR is open.
            if pr.state == .open || pr.state == .draft {
                mergeChecks = (try? await pullRequests.mergeChecks(
                    host: c.host, owner: c.owner, repo: c.repo, number: pr.number, token: c.token
                )) ?? []
            }
            // Resolve the token's user once (best-effort) so the review toggle
            // knows whether the current user already approved/requested changes.
            if currentUser == nil && !identityResolved {
                currentUser = try? await pullRequests.currentUser(host: c.host, token: c.token)
                identityResolved = true
            }
            // Fallback identity: local git user.name, for authorship matching when
            // the host can't resolve the current user (e.g. Bitbucket scope).
            if localName == nil && !localNameResolved {
                localNameResolved = true
                if let repo = repoSource() {
                    localName = await git.configValue("user.name", at: repo.url)
                }
            }
        } catch {
            main.errorMessage = error.localizedDescription
        }
    }

    /// Manual refresh of the selected PR: re-fetch detail + merge checks, and
    /// reload whichever sub-tabs are already open — without changing the current
    /// tab or commit selection.
    func refreshSelected() async {
        guard let pr = selected, let c = coordinates() else { return }
        detailLoading = true
        do {
            detail = try await pullRequests.detail(
                host: c.host, owner: c.owner, repo: c.repo, number: pr.number, token: c.token
            )
            if pr.state == .open || pr.state == .draft {
                mergeChecks = (try? await pullRequests.mergeChecks(
                    host: c.host, owner: c.owner, repo: c.repo, number: pr.number, token: c.token
                )) ?? []
            }
        } catch {
            main.errorMessage = error.localizedDescription
        }
        detailLoading = false
        if filesLoaded { filesLoaded = false; await loadFiles() }
        if commitsLoaded { commitsLoaded = false; await loadCommits() }
        if let c = selectedCommit { selectCommit(c) }
    }

    /// Re-fetch just the selected PR's detail (after a review) without resetting
    /// the open sub-tab / files / commits state.
    private func reloadDetail() async {
        guard let pr = selected, let c = coordinates() else { return }
        do {
            detail = try await pullRequests.detail(
                host: c.host, owner: c.owner, repo: c.repo, number: pr.number, token: c.token
            )
        } catch {
            main.errorMessage = error.localizedDescription
        }
    }

    /// Approve the PR, or withdraw an existing approval (toggle).
    func toggleApprove() async {
        await submitReview(myReviewState == .approved ? .unapprove : .approve)
    }

    /// Request changes on the PR, or withdraw an existing request (toggle).
    func toggleRequestChanges() async {
        await submitReview(myReviewState == .changesRequested ? .unrequestChanges : .requestChanges)
    }

    private func submitReview(_ action: PRReviewAction) async {
        guard !reviewSubmitting, let pr = selected, let c = coordinates() else { return }
        reviewSubmitting = true
        defer { reviewSubmitting = false }
        do {
            try await pullRequests.review(
                host: c.host, owner: c.owner, repo: c.repo,
                number: pr.number, action: action, token: c.token
            )
            await reloadDetail()
        } catch {
            main.errorMessage = error.localizedDescription
        }
    }

    // MARK: - Author lifecycle actions

    func merge() async {
        guard !mergeBlocked else {
            main.errorMessage = "This pull request can't be merged yet — some checks are still failing."
            return
        }
        await runLifecycle(.merge)
    }
    func decline() async   { await runLifecycle(.decline) }
    func reopen() async    { await runLifecycle(.reopen) }
    func markDraft() async { await runLifecycle(.markDraft) }
    func markReady() async { await runLifecycle(.markReady) }

    /// Run a lifecycle change, then refresh the list and re-point `selected` at
    /// the updated summary so the state-gated menu reflects the new state.
    private func runLifecycle(_ action: PRLifecycleAction) async {
        guard !reviewSubmitting, let pr = selected, let c = coordinates() else { return }
        reviewSubmitting = true
        defer { reviewSubmitting = false }
        do {
            try await pullRequests.lifecycle(
                host: c.host, owner: c.owner, repo: c.repo,
                number: pr.number, action: action, token: c.token
            )
            await refresh()
            // Re-selecting the refreshed summary triggers a detail reload via the
            // `$selected` sink; nil-out first so it fires even if fields match.
            selected = nil
            selected = loaded.first(where: { $0.number == pr.number })
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

    /// Fetch raw bytes for a file blob URL with the current repo's host auth.
    func imageData(_ url: URL) async -> Data? {
        guard let c = coordinates() else { return nil }
        return try? await pullRequests.download(host: c.host, url: url, token: c.token)
    }

    /// Enter compose mode: clear any selected PR and show the composer panel.
    func startCompose() {
        selected = nil
        isComposing = true
    }

    func repositoryDidChange() {
        isComposing = false
        currentUser = nil
        identityResolved = false
        localName = nil
        localNameResolved = false
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
