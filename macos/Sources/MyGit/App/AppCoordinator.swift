import Foundation
import Combine

@MainActor
final class AppCoordinator: ObservableObject {
    let container: AppContainer

    let main: MainViewModel
    let repos: RepositoryListViewModel
    let settings: SettingsViewModel

    /// One bundle per repo in the selected workspace.
    @Published private(set) var bundles: [RepoBundle] = []
    /// The bundle that the single-repo UI (toolbar, detail panel, menus) acts on.
    @Published private(set) var activeBundle: RepoBundle

    /// Placeholder used when no workspace is selected. Never exercised — the
    /// UI shows the empty state in that case.
    private let emptyBundle: RepoBundle
    private var cancellables: Set<AnyCancellable> = []

    init(container: AppContainer) {
        self.container = container

        let main = MainViewModel()
        self.main = main

        let repos = RepositoryListViewModel(store: container.repos, main: main)
        self.repos = repos

        let settings = SettingsViewModel(credentials: container.credentials)
        self.settings = settings

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

    func setActive(_ bundle: RepoBundle) {
        activeBundle = bundle
    }

    private func rebuildBundles(for workspace: Workspace?) {
        guard let workspace, !workspace.repos.isEmpty else {
            bundles = []
            activeBundle = emptyBundle
            return
        }
        let built = workspace.repos.map {
            RepoBundle(repo: $0, container: container, main: main, settings: settings)
        }
        bundles = built
        activeBundle = built.first ?? emptyBundle
        Task {
            for bundle in built { await bundle.refreshAll() }
        }
    }

    func refreshAll() async {
        for bundle in bundles { await bundle.refreshAll() }
    }
}
