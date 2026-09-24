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
    let claude = ClaudeViewModel()

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

        // Claude sessions run in the terminal panel; its assets open as editor
        // tabs in the active repo's editor.
        claude.setRunner { [weak self] command, cwd in
            self?.terminal.runCommand(command, cwd: cwd, title: "claude")
        }
        claude.setEditorOpener { [weak self] path in
            self?.activeBundle.editor.openFile(path: path)
        }

        rebuildBundles(for: container.repos.selected)

        // MyGit as Claude Code's IDE: editor selection, open files, @-mentions.
        ClaudeIDEServer.shared.host = self
        ClaudeIDEServer.shared.start()
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
            ClaudeIDEServer.shared.setWorkspaceFolders([])
            bundles = []
            watchers = []
            activeBundle = emptyBundle
            return
        }
        let built = workspace.repos.map {
            RepoBundle(repo: $0, container: container, main: main, settings: settings)
        }
        for bundle in built {
            // Runs land in the terminal panel: long, chatty, sometimes interactive.
            bundle.run.setRunner { [weak self] script in
                guard let self else { return }
                self.terminal.isVisible = true
                self.terminal.runShellScript(absolutePath: script)
            }
        }
        bundles.forEach { $0.editor.persistSession() }
        bundles = built
        ClaudeIDEServer.shared.setWorkspaceFolders(built.map { $0.repo.url.path })
        activeBundle = built.first ?? emptyBundle
        for bundle in built { bundle.editor.restoreSession(focus: bundle === activeBundle) }
        claude.repositoryDidChange(to: activeBundle.repo.url)
        watchers = built.map { bundle in
            RepoWatcher(url: bundle.repo.url) { [weak bundle] in
                Task { @MainActor in bundle?.refreshFromWatcher() }
            }
        }
        Task {
            for bundle in built { await bundle.refreshAll() }
        }
    }

    /// Flush every repo's open-tab session (caret lines change without
    /// republishing the tab list, so the debounced save can miss them).
    func persistSessions() {
        bundles.forEach { $0.editor.persistSession() }
    }

    func refreshAll() async {
        for bundle in bundles { await bundle.refreshAll() }
    }
}

// MARK: - Claude Code IDE host

extension AppCoordinator: ClaudeIDEHost {
    func ideOpenEditors() -> [ClaudeIDEEditor] {
        bundles.flatMap { bundle in
            bundle.editor.openFileTabs.compactMap { tab -> ClaudeIDEEditor? in
                guard let path = bundle.editor.absolutePath(for: tab) else { return nil }
                return ClaudeIDEEditor(
                    filePath: path,
                    isActive: bundle === activeBundle && bundle.editor.activeFileTabId == tab.id,
                    isDirty: tab.isDirty
                )
            }
        }
    }

    /// Open in the repo that holds the file (switching to it), else as an
    /// absolute-path tab in the active repo's editor.
    func ideOpenFile(_ path: String, line: Int?) {
        let (bundle, relative) = locate(path)
        if let bundle, bundle !== activeBundle { setActive(bundle) }
        main.tab = .files
        let editor = (bundle ?? activeBundle).editor
        editor.openFile(path: relative)
        if let line { editor.reveal(path: relative, line: line) }
    }

    func ideIsDirty(_ path: String) -> Bool? {
        let (bundle, relative) = locate(path)
        return (bundle ?? activeBundle).editor.openFileTabs.first { $0.path == relative }?.isDirty
    }

    func ideSave(_ path: String) async -> Bool {
        let (bundle, relative) = locate(path)
        let editor = (bundle ?? activeBundle).editor
        guard let tab = editor.openFileTabs.first(where: { $0.path == relative }) else { return false }
        await editor.saveFileTab(tab)
        return !tab.isDirty
    }

    /// The bundle whose repo contains `path`, and the path as that editor
    /// names it (repo-relative, or absolute when no repo holds it).
    private func locate(_ path: String) -> (RepoBundle?, String) {
        let target = URL(fileURLWithPath: path).standardizedFileURL.path
        for bundle in bundles {
            let root = bundle.repo.url.standardizedFileURL.path
            if target.hasPrefix(root + "/") {
                return (bundle, String(target.dropFirst(root.count + 1)))
            }
        }
        return (nil, target)
    }
}
