import Foundation
import Combine

@MainActor
final class AppCoordinator: ObservableObject {
    let container: AppContainer

    let main: MainViewModel
    let repos: RepositoryListViewModel
    let changes: ChangesViewModel
    let history: HistoryViewModel
    let files: FilesViewModel
    let editor: FileEditorViewModel
    let branches: BranchesViewModel
    let account: AccountViewModel
    let remote: RemoteViewModel

    private var cancellables: Set<AnyCancellable> = []

    init(container: AppContainer) {
        self.container = container

        let main = MainViewModel()
        self.main = main

        let repos = RepositoryListViewModel(store: container.repos, main: main)
        self.repos = repos

        let repoSource: () -> Repository? = { [weak repos] in repos?.selected }

        // Forward-declared closures need objects first. Build VMs, wire onSaved/onFinished after.
        let changes = ChangesViewModel(git: container.git, main: main, repoSource: repoSource)
        self.changes = changes

        let history = HistoryViewModel(git: container.git, main: main, repoSource: repoSource)
        self.history = history

        let files = FilesViewModel(git: container.git, main: main, repoSource: repoSource)
        self.files = files

        let account = AccountViewModel(
            git: container.git,
            credentials: container.credentials,
            main: main,
            repoSource: repoSource
        )
        self.account = account

        let editor = FileEditorViewModel(
            fileEditor: container.fileEditor,
            main: main,
            repoSource: repoSource,
            onSaved: { [weak changes] in await changes?.refreshStatus() }
        )
        self.editor = editor

        let currentBranch: () -> String? = { [weak changes] in changes?.status?.branch }

        var refreshAll: () async -> Void = {}

        let branches = BranchesViewModel(
            git: container.git,
            main: main,
            repoSource: repoSource,
            currentBranch: currentBranch,
            onFinished: { await refreshAll() }
        )
        self.branches = branches

        let remote = RemoteViewModel(
            git: container.git,
            account: account,
            main: main,
            repoSource: repoSource,
            currentBranch: currentBranch,
            onFinished: { await refreshAll() }
        )
        self.remote = remote

        refreshAll = { [weak self] in await self?.refreshAll() }
        changes.setOnFinished { await refreshAll() }

        container.repos.selectedPublisher
            .removeDuplicates()
            .sink { [weak self] _ in
                Task { await self?.repositorySwitched() }
            }
            .store(in: &cancellables)
    }

    func refreshAll() async {
        await changes.refreshStatus()
        await history.refreshLog()
        await account.refreshAccount()
        await branches.refresh()
        await files.refreshFileTree()
    }

    private func repositorySwitched() async {
        changes.repositoryDidChange()
        history.repositoryDidChange()
        files.repositoryDidChange()
        editor.repositoryDidChange()
        branches.repositoryDidChange()
        account.repositoryDidChange()
        await refreshAll()
    }
}
