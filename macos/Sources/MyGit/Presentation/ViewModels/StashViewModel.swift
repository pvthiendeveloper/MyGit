import Foundation

/// Drives the Stash tab: lists `git stash` entries and runs create/apply/pop/drop/clear.
/// Mirrors the other per-repo VMs — busy + errors flow through `MainViewModel`, and a
/// successful mutation calls `onFinished` (the bundle's `refreshAll`).
@MainActor
final class StashViewModel: ObservableObject {
    @Published private(set) var stashes: [GitStash] = []
    @Published var newMessage: String = ""
    /// Lazily-loaded changed-file lists per stash index, for the expandable diff rows.
    @Published private(set) var files: [Int: [String]] = [:]
    @Published var expanded: Set<Int> = []

    private let git: GitRepository
    private let main: MainViewModel
    private let repoSource: () -> Repository?
    private var onFinished: () async -> Void = {}

    init(git: GitRepository, main: MainViewModel, repoSource: @escaping () -> Repository?) {
        self.git = git
        self.main = main
        self.repoSource = repoSource
    }

    func setOnFinished(_ block: @escaping () async -> Void) { onFinished = block }

    func repositoryDidChange() {
        stashes = []
        files = [:]
        expanded = []
        newMessage = ""
    }

    func refreshList() async {
        guard let repo = repoSource() else { return }
        do {
            stashes = try await git.stashList(at: repo.url)
            // Drop cached file lists for indices that no longer exist.
            let live = Set(stashes.map(\.index))
            files = files.filter { live.contains($0.key) }
            expanded = expanded.intersection(live)
        } catch {
            main.errorMessage = error.localizedDescription
        }
    }

    /// Stash all current changes (including untracked) under an optional message.
    func createStash() async {
        guard let repo = repoSource(), !main.isBusy else { return }
        main.isBusy = true
        defer { main.isBusy = false }
        let msg = newMessage.trimmingCharacters(in: .whitespacesAndNewlines)
        do {
            try await git.stashPush(message: msg.isEmpty ? nil : msg, at: repo.url)
            newMessage = ""
            await onFinished()
            await refreshList()
        } catch {
            main.errorMessage = error.localizedDescription
        }
    }

    func apply(_ stash: GitStash) async { await mutate { try await self.git.stashApply(index: stash.index, at: $0) } }
    func pop(_ stash: GitStash) async { await mutate { try await self.git.stashPop(index: stash.index, at: $0) } }
    func drop(_ stash: GitStash) async { await mutate { try await self.git.stashDrop(index: stash.index, at: $0) } }
    func clearAll() async { await mutate { try await self.git.stashClear(at: $0) } }

    private func mutate(_ op: @escaping (URL) async throws -> Void) async {
        guard let repo = repoSource(), !main.isBusy else { return }
        main.isBusy = true
        defer { main.isBusy = false }
        do {
            try await op(repo.url)
            await onFinished()
            await refreshList()
        } catch {
            main.errorMessage = error.localizedDescription
        }
    }

    // MARK: Diff

    func toggleExpanded(_ stash: GitStash) {
        if expanded.contains(stash.index) {
            expanded.remove(stash.index)
        } else {
            expanded.insert(stash.index)
            if files[stash.index] == nil { Task { await loadFiles(stash) } }
        }
    }

    func loadFiles(_ stash: GitStash) async {
        guard let repo = repoSource() else { return }
        do {
            files[stash.index] = try await git.stashFiles(index: stash.index, at: repo.url)
        } catch {
            main.errorMessage = error.localizedDescription
        }
    }

    /// Open a stash's file in the diff viewer: the stash commit vs its base parent.
    func showDiff(_ stash: GitStash, path: String, forceNew: Bool) {
        main.openDiffTab(
            commitHash: stash.ref,
            commitShortHash: stash.ref,
            path: path,
            mode: .commitVsParent,
            forceNew: forceNew
        )
    }
}
