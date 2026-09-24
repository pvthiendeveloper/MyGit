import Foundation
import AppKit
import Combine

@MainActor
final class RepositoryListViewModel: ObservableObject {
    @Published private(set) var workspaces: [Workspace] = []
    @Published private(set) var selected: Workspace?
    /// Workspace paths the user pinned to the top of the picker.
    @Published private(set) var pinnedPaths: Set<String> = []
    /// Manual order (workspace paths). Anything not listed keeps store order,
    /// after the ones that are.
    @Published private(set) var order: [String] = []

    private let store: RepoListRepository
    private let main: MainViewModel
    private let defaults: UserDefaults
    private var cancellables: Set<AnyCancellable> = []
    private static let pinnedKey = "MyGit.repos.pinned"
    private static let orderKey = "MyGit.repos.order"

    init(store: RepoListRepository, main: MainViewModel, defaults: UserDefaults = .standard) {
        self.store = store
        self.main = main
        self.defaults = defaults
        self.pinnedPaths = Set(defaults.stringArray(forKey: Self.pinnedKey) ?? [])
        self.order = defaults.stringArray(forKey: Self.orderKey) ?? []
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

    func remove(_ workspace: Workspace) {
        unpin(workspace)
        store.remove(workspace)
    }

    // MARK: - Pinning

    func isPinned(_ workspace: Workspace) -> Bool { pinnedPaths.contains(workspace.url.path) }

    func togglePin(_ workspace: Workspace) {
        if isPinned(workspace) { unpin(workspace) } else { pin(workspace) }
    }

    func pin(_ workspace: Workspace) {
        pinnedPaths.insert(workspace.url.path)
        persistPins()
    }

    func unpin(_ workspace: Workspace) {
        pinnedPaths.remove(workspace.url.path)
        persistPins()
    }

    /// Pinned workspaces first, each group in the user's manual order.
    func grouped(_ list: [Workspace]) -> (pinned: [Workspace], others: [Workspace]) {
        (sorted(list.filter(isPinned)), sorted(list.filter { !isPinned($0) }))
    }

    /// Apply the manual order; unordered entries keep their existing relative
    /// position at the end (newly added repos land last, not in the middle).
    private func sorted(_ list: [Workspace]) -> [Workspace] {
        let rank = Dictionary(uniqueKeysWithValues: order.enumerated().map { ($0.element, $0.offset) })
        return list.enumerated().sorted { lhs, rhs in
            let l = rank[lhs.element.url.path] ?? Int.max
            let r = rank[rhs.element.url.path] ?? Int.max
            return l == r ? lhs.offset < rhs.offset : l < r
        }.map { $0.element }
    }

    // MARK: - Reordering

    /// Drop `moved` in front of `target`. Dragging across the Pinned/Other
    /// boundary pins or unpins as a side effect — that's what the drop means.
    func move(path moved: String, before target: String?, intoPinned pinned: Bool, in list: [Workspace]) {
        guard moved != target else { return }
        if pinned { pinnedPaths.insert(moved) } else { pinnedPaths.remove(moved) }
        persistPins()

        // Rebuild the full order from what's on screen, so a partial saved
        // order (or a freshly added repo) doesn't scramble the rest.
        var paths = (grouped(list).pinned + grouped(list).others).map { $0.url.path }
        paths.removeAll { $0 == moved }
        if let target, let index = paths.firstIndex(of: target) {
            paths.insert(moved, at: index)
        } else if let target, target.isEmpty {
            paths.append(moved)
        } else {
            paths.append(moved)
        }
        order = paths
        defaults.set(order, forKey: Self.orderKey)
    }

    /// Drop at the end of a section (the empty strip under its last row).
    func moveToEnd(path moved: String, intoPinned pinned: Bool, in list: [Workspace]) {
        if pinned { pinnedPaths.insert(moved) } else { pinnedPaths.remove(moved) }
        persistPins()
        let groups = grouped(list)
        var paths = (groups.pinned + groups.others).map { $0.url.path }
        paths.removeAll { $0 == moved }
        if pinned {
            let insertAt = groups.pinned.filter { $0.url.path != moved }.count
            paths.insert(moved, at: min(insertAt, paths.count))
        } else {
            paths.append(moved)
        }
        order = paths
        defaults.set(order, forKey: Self.orderKey)
    }

    private func persistPins() {
        defaults.set(Array(pinnedPaths).sorted(), forKey: Self.pinnedKey)
    }

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
