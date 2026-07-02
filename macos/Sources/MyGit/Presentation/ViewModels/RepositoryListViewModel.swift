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
            addWorkspace(at: url)
        }
    }

    /// Prompts for an absolute (or `~`-relative) folder path and adds it.
    func promptAddByPath() {
        let alert = NSAlert()
        alert.messageText = "Add Repository by Path"
        alert.informativeText = "Enter the absolute path to a git repository or a folder containing several repos."
        alert.addButton(withTitle: "Add")
        alert.addButton(withTitle: "Cancel")

        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 380, height: 24))
        field.placeholderString = "/Users/you/path/to/repo"
        field.lineBreakMode = .byTruncatingHead
        alert.accessoryView = field
        alert.window.initialFirstResponder = field

        if alert.runModal() == .alertFirstButtonReturn {
            addRepository(path: field.stringValue)
        }
    }

    /// Validates a typed path, then scans + adds it as a workspace.
    func addRepository(path rawPath: String) {
        let trimmed = rawPath.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        let expanded = (trimmed as NSString).expandingTildeInPath
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: expanded, isDirectory: &isDir), isDir.boolValue else {
            main.errorMessage = "Folder not found: \(expanded)"
            return
        }
        addWorkspace(at: URL(fileURLWithPath: expanded).standardizedFileURL)
    }

    private func addWorkspace(at url: URL) {
        let workspace = WorkspaceScanner.scan(url)
        if workspace.repos.isEmpty {
            main.errorMessage = "No git repository found in: \(url.path)"
        } else {
            store.add(url)
        }
    }
}
