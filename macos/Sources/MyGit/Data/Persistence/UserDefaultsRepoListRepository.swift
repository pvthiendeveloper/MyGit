import Foundation
import Combine

@MainActor
final class UserDefaultsRepoListRepository: RepoListRepository, ObservableObject {
    @Published private(set) var repositories: [Repository] = []
    @Published private(set) var selected: Repository?

    var repositoriesPublisher: AnyPublisher<[Repository], Never> { $repositories.eraseToAnyPublisher() }
    var selectedPublisher: AnyPublisher<Repository?, Never> { $selected.eraseToAnyPublisher() }

    private let pathsKey = "MyGit.repositoryPaths"
    private let selectedKey = "MyGit.selectedRepositoryPath"

    init() {
        reload()
    }

    func reload() {
        let paths = UserDefaults.standard.array(forKey: pathsKey) as? [String] ?? []
        repositories = paths
            .map { URL(fileURLWithPath: $0) }
            .filter { FileManager.default.fileExists(atPath: $0.appendingPathComponent(".git").path) }
            .map { Repository(url: $0) }

        if let sel = UserDefaults.standard.string(forKey: selectedKey),
           let match = repositories.first(where: { $0.url.path == sel }) {
            selected = match
        } else {
            selected = repositories.first
        }
    }

    func add(_ url: URL) {
        let resolved = url.standardizedFileURL.resolvingSymlinksInPath()
        if let existing = repositories.first(where: { $0.url == resolved }) {
            select(existing)
            return
        }
        let repo = Repository(url: resolved)
        repositories.append(repo)
        selected = repo
        persist()
    }

    func remove(_ repo: Repository) {
        repositories.removeAll { $0.url == repo.url }
        if selected == repo { selected = repositories.first }
        persist()
    }

    func select(_ repo: Repository) {
        selected = repo
        UserDefaults.standard.set(repo.url.path, forKey: selectedKey)
    }

    private func persist() {
        UserDefaults.standard.set(repositories.map { $0.url.path }, forKey: pathsKey)
        if let sel = selected {
            UserDefaults.standard.set(sel.url.path, forKey: selectedKey)
        } else {
            UserDefaults.standard.removeObject(forKey: selectedKey)
        }
    }
}
