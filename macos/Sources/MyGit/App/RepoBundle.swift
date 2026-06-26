import Foundation

/// All per-repo ViewModels for one git repo, wired together. A workspace
/// builds one bundle per nested repo; a single-repo workspace has exactly one.
///
/// This reproduces the per-repo wiring that used to live inline in
/// `AppCoordinator.init`, parameterized by a constant `repoSource = { repo }`.
/// `main` and `settings` stay shared (global) across all bundles.
@MainActor
final class RepoBundle: Identifiable {
    let repo: Repository
    var id: URL { repo.url }
    var name: String { repo.name }

    let changes: ChangesViewModel
    let history: HistoryViewModel
    let files: FilesViewModel
    let editor: FileEditorViewModel
    let branches: BranchesViewModel
    let account: AccountViewModel
    let remote: RemoteViewModel
    let compareVM: CompareBranchesViewModel

    init(repo: Repository, container: AppContainer, main: MainViewModel, settings: SettingsViewModel) {
        self.repo = repo
        let repoSource: () -> Repository? = { repo }

        let changes = ChangesViewModel(
            git: container.git,
            main: main,
            repoSource: repoSource,
            commitMessageRepo: container.commitMessage
        )
        self.changes = changes
        changes.setAIConfigSource { [weak settings] in settings?.requestConfig() }

        self.history = HistoryViewModel(git: container.git, main: main, repoSource: repoSource)
        self.files = FilesViewModel(git: container.git, main: main, repoSource: repoSource)

        let account = AccountViewModel(
            git: container.git,
            credentials: container.credentials,
            main: main,
            repoSource: repoSource
        )
        self.account = account

        self.editor = FileEditorViewModel(
            fileEditor: container.fileEditor,
            main: main,
            repoSource: repoSource,
            onSaved: { [weak changes] in await changes?.refreshStatus() }
        )

        let currentBranch: () -> String? = { [weak changes] in changes?.status?.branch }

        // refreshAll is forward-referenced by branches/remote; bind after build.
        let refreshAllBox = RefreshBox()
        let refreshAll: () async -> Void = { await refreshAllBox.run() }

        let branches = BranchesViewModel(
            git: container.git,
            main: main,
            repoSource: repoSource,
            currentBranch: currentBranch,
            onFinished: refreshAll
        )
        self.branches = branches

        let remote = RemoteViewModel(
            git: container.git,
            account: account,
            main: main,
            repoSource: repoSource,
            currentBranch: currentBranch,
            onFinished: refreshAll
        )
        self.remote = remote

        self.compareVM = CompareBranchesViewModel()

        refreshAllBox.body = { [weak self] in await self?.refreshAll() }
        changes.setOnFinished(refreshAll)
        changes.setPushAfterCommit { [weak remote] force in
            if force { await remote?.forcePush() } else { await remote?.push() }
        }
    }

    func refreshAll() async {
        await changes.refreshStatus()
        await history.refreshLog()
        await account.refreshAccount()
        await branches.refresh()
        await files.refreshFileTree()
    }

    func repositoryDidChange() {
        changes.repositoryDidChange()
        history.repositoryDidChange()
        files.repositoryDidChange()
        editor.repositoryDidChange()
        branches.repositoryDidChange()
        account.repositoryDidChange()
    }
}

/// Indirection so `branches`/`remote` can close over `refreshAll` before the
/// bundle is fully built (mirrors the old `var refreshAll` shim).
@MainActor
private final class RefreshBox {
    var body: () async -> Void = {}
    func run() async { await body() }
}
