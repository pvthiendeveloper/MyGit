import Foundation
import Combine

@MainActor
final class AppCoordinator: ObservableObject {
    let container: AppContainer

    let main: MainViewModel
    let repos: RepositoryListViewModel
    let settings: SettingsViewModel
    let search: SearchEverywhereViewModel
    let terminal = TerminalViewModel()

    /// One bundle per repo in the selected workspace.
    @Published private(set) var bundles: [RepoBundle] = []
    /// The bundle that the single-repo UI (toolbar, detail panel, menus) acts on.
    @Published private(set) var activeBundle: RepoBundle

    /// Placeholder used when no workspace is selected. Never exercised — the
    /// UI shows the empty state in that case.
    private let emptyBundle: RepoBundle
    private var cancellables: Set<AnyCancellable> = []
    /// One FSEvents watcher per active bundle; auto-refreshes that repo on
    /// any on-disk change. Replaced wholesale when bundles rebuild.
    private var watchers: [RepoWatcher] = []

    init(container: AppContainer) {
        self.container = container

        let main = MainViewModel()
        self.main = main

        let repos = RepositoryListViewModel(store: container.repos, main: main)
        self.repos = repos

        let settings = SettingsViewModel(credentials: container.credentials)
        self.settings = settings

        self.search = SearchEverywhereViewModel(git: container.git)

        let placeholder = Repository(url: URL(fileURLWithPath: "/"))
        self.emptyBundle = RepoBundle(repo: placeholder, container: container, main: main, settings: settings)
        self.activeBundle = emptyBundle

        container.repos.selectedPublisher
            .removeDuplicates()
            .sink { [weak self] workspace in
                self?.rebuildBundles(for: workspace)
            }
            .store(in: &cancellables)

        rebuildBundles(for: container.repos.selected)
    }

    // Convenience forwarders for menu/toolbar code that acts on the active repo.
    var changes: ChangesViewModel { activeBundle.changes }
    var remote: RemoteViewModel { activeBundle.remote }

    /// Working directory for new terminals: the active repo, or home when no
    /// workspace is selected.
    var terminalCWD: URL {
        bundles.isEmpty ? FileManager.default.homeDirectoryForCurrentUser : activeBundle.repo.url
    }

    func toggleTerminal() { terminal.toggle(cwd: terminalCWD) }
    func newTerminal() { terminal.newSession(cwd: terminalCWD) }

    func setActive(_ bundle: RepoBundle) {
        activeBundle = bundle
    }

    /// Open the Search Everywhere overlay and (re)index the workspace's files.
    func openSearchEverywhere() {
        guard !bundles.isEmpty else { return }
        search.present()
        let repos = bundles.map { (id: $0.id, name: $0.name, url: $0.repo.url) }
        Task { await search.buildIndex(repos) }
    }

    /// Activate the hit's repo, switch to Files, and open the file.
    func openSearchHit(_ hit: SearchHit) {
        if let bundle = bundles.first(where: { $0.id == hit.bundleID }) {
            setActive(bundle)
            main.tab = .files
            bundle.editor.openFile(path: hit.path)
        }
        search.dismiss()
    }

    private func rebuildBundles(for workspace: Workspace?) {
        watchers.forEach { $0.stop() }
        guard let workspace, !workspace.repos.isEmpty else {
            bundles = []
            watchers = []
            activeBundle = emptyBundle
            return
        }
        let built = workspace.repos.map {
            RepoBundle(repo: $0, container: container, main: main, settings: settings)
        }
        bundles = built
        activeBundle = built.first ?? emptyBundle
        watchers = built.map { bundle in
            RepoWatcher(url: bundle.repo.url) { [weak bundle] in
                Task { @MainActor in bundle?.refreshFromWatcher() }
            }
        }
        Task {
            for bundle in built { await bundle.refreshAll() }
        }
    }

    func refreshAll() async {
        for bundle in bundles { await bundle.refreshAll() }
    }
}
