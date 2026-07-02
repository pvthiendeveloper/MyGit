import Foundation

@MainActor
struct AppContainer {
    let git: GitRepository
    let repos: RepoListRepository
    let credentials: CredentialRepository
    let fileEditor: FileEditorRepository
    let commitMessage: CommitMessageRepository
    let pullRequests: PullRequestRepository

    @MainActor
    static func live() -> AppContainer {
        AppContainer(
            git: GitCLIRepository(),
            repos: UserDefaultsRepoListRepository(),
            credentials: KeychainCredentialRepository(),
            fileEditor: FileSystemFileEditorRepository(),
            commitMessage: AICommitMessageRepository(),
            pullRequests: PullRequestRouter()
        )
    }
}
