import Foundation
import AppKit
import Combine

@MainActor
final class RepositoryListViewModel: ObservableObject {
    @Published private(set) var repositories: [Repository] = []
    @Published private(set) var selected: Repository?

    private let store: RepoListRepository
    private let main: MainViewModel
    private var cancellables: Set<AnyCancellable> = []

    init(store: RepoListRepository, main: MainViewModel) {
        self.store = store
        self.main = main
        self.repositories = store.repositories
        self.selected = store.selected

        store.repositoriesPublisher
            .receive(on: RunLoop.main)
            .sink { [weak self] in self?.repositories = $0 }
            .store(in: &cancellables)
        store.selectedPublisher
            .receive(on: RunLoop.main)
            .sink { [weak self] in self?.selected = $0 }
            .store(in: &cancellables)
    }

    var selectedPublisher: AnyPublisher<Repository?, Never> { store.selectedPublisher }

    func select(_ repo: Repository) { store.select(repo) }
    func remove(_ repo: Repository) { store.remove(repo) }

    func pickRepository() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.prompt = "Add Repository"
        panel.message = "Choose a local Git repository"
        if panel.runModal() == .OK, let url = panel.url {
            let gitDir = url.appendingPathComponent(".git")
            if FileManager.default.fileExists(atPath: gitDir.path) {
                store.add(url)
            } else {
                main.errorMessage = "Not a git repository: \(url.path)"
            }
        }
    }
}
