import Foundation

@MainActor
struct AppContainer {
    let git: GitRepository
    let repos: RepoListRepository
    let credentials: CredentialRepository
    let fileEditor: FileEditorRepository

    @MainActor
    static func live() -> AppContainer {
        AppContainer(
            git: GitCLIRepository(),
            repos: UserDefaultsRepoListRepository(),
            credentials: KeychainCredentialRepository(),
            fileEditor: FileSystemFileEditorRepository()
        )
    }
}
