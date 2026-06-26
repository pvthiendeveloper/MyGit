import Foundation
import Combine

@MainActor
final class UserDefaultsRepoListRepository: RepoListRepository, ObservableObject {
    @Published private(set) var workspaces: [Workspace] = []
    @Published private(set) var selected: Workspace?

    var workspacesPublisher: AnyPublisher<[Workspace], Never> { $workspaces.eraseToAnyPublisher() }
    var selectedPublisher: AnyPublisher<Workspace?, Never> { $selected.eraseToAnyPublisher() }

    /// Stores the FOLDER paths the user added (each rescanned into a workspace).
    private let pathsKey = "MyGit.repositoryPaths"
    private let selectedKey = "MyGit.selectedRepositoryPath"

    init() {
        reload()
    }

    func reload() {
        let paths = UserDefaults.standard.array(forKey: pathsKey) as? [String] ?? []
        workspaces = paths
            .map { URL(fileURLWithPath: $0) }
            .map { WorkspaceScanner.scan($0) }
            .filter { !$0.repos.isEmpty }

        if let sel = UserDefaults.standard.string(forKey: selectedKey),
           let match = workspaces.first(where: { $0.url.path == sel }) {
            selected = match
        } else {
            selected = workspaces.first
        }
    }

    func add(_ url: URL) {
        let resolved = url.standardizedFileURL.resolvingSymlinksInPath()
        if let existing = workspaces.first(where: { $0.url == resolved }) {
            select(existing)
            return
        }
        let workspace = WorkspaceScanner.scan(resolved)
        guard !workspace.repos.isEmpty else { return }
        workspaces.append(workspace)
        selected = workspace
        persist()
    }

    func remove(_ workspace: Workspace) {
        workspaces.removeAll { $0.url == workspace.url }
        if selected?.url == workspace.url { selected = workspaces.first }
        persist()
    }

    func select(_ workspace: Workspace) {
        selected = workspace
        UserDefaults.standard.set(workspace.url.path, forKey: selectedKey)
    }

    private func persist() {
        UserDefaults.standard.set(workspaces.map { $0.url.path }, forKey: pathsKey)
        if let sel = selected {
            UserDefaults.standard.set(sel.url.path, forKey: selectedKey)
        } else {
            UserDefaults.standard.removeObject(forKey: selectedKey)
        }
    }
}
