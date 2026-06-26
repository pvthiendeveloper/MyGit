import Foundation
import AppKit
import Combine

@MainActor
final class RepositoryListViewModel: ObservableObject {
    @Published private(set) var workspaces: [Workspace] = []
    @Published private(set) var selected: Workspace?

    private let store: RepoListRepository
    private let main: MainViewModel
    private var cancellables: Set<AnyCancellable> = []

    init(store: RepoListRepository, main: MainViewModel) {
        self.store = store
        self.main = main
        self.workspaces = store.workspaces
        self.selected = store.selected

        store.workspacesPublisher
            .receive(on: RunLoop.main)
            .sink { [weak self] in self?.workspaces = $0 }
            .store(in: &cancellables)
        store.selectedPublisher
            .receive(on: RunLoop.main)
            .sink { [weak self] in self?.selected = $0 }
            .store(in: &cancellables)
    }

    var selectedPublisher: AnyPublisher<Workspace?, Never> { store.selectedPublisher }

    func select(_ workspace: Workspace) { store.select(workspace) }
    func remove(_ workspace: Workspace) { store.remove(workspace) }

    func pickRepository() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.prompt = "Add Repository"
        panel.message = "Choose a git repository or a folder containing several repos"
        if panel.runModal() == .OK, let url = panel.url {
            let workspace = WorkspaceScanner.scan(url)
            if workspace.repos.isEmpty {
                main.errorMessage = "No git repository found in: \(url.path)"
            } else {
                store.add(url)
            }
        }
    }
}
