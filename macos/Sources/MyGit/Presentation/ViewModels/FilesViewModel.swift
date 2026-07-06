import Foundation
#if canImport(AppKit)
import AppKit
#endif

@MainActor
final class FilesViewModel: ObservableObject {
    @Published var fileTreeNodes: [FileTreeNode] = []

    private let git: GitRepository
    private let main: MainViewModel
    private let repoSource: () -> Repository?

    init(git: GitRepository, main: MainViewModel, repoSource: @escaping () -> Repository?) {
        self.git = git
        self.main = main
        self.repoSource = repoSource
    }

    func repositoryDidChange() {
        fileTreeNodes = []
    }

    func refreshFileTree() async {
        guard let repo = repoSource() else { fileTreeNodes = []; return }
        let fresh = listDir(repo: repo, relPath: nil)
        fileTreeNodes = await merge(old: fileTreeNodes, fresh: fresh, repo: repo)
    }

    /// Lists a directory from disk (not `git ls-tree`), so untracked and hidden
    /// (dot) entries show. Skips only the repo's own `.git`. Dirs first, A→Z.
    private func listDir(repo: Repository, relPath: String?) -> [FileTreeNode] {
        let base = relPath.map { repo.url.appendingPathComponent($0) } ?? repo.url
        guard let entries = try? FileManager.default.contentsOfDirectory(
            at: base,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: []   // no .skipsHiddenFiles → dot entries included
        ) else { return [] }

        var dirs: [FileTreeNode] = []
        var files: [FileTreeNode] = []
        for url in entries {
            let name = url.lastPathComponent
            if relPath == nil, name == ".git" { continue }
            let isDir = (try? url.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory ?? false
            let id = relPath.map { "\($0)/\(name)" } ?? name
            let node = FileTreeNode(id: id, name: name, isDirectory: isDir)
            if isDir { dirs.append(node) } else { files.append(node) }
        }
        let byName: (FileTreeNode, FileTreeNode) -> Bool = {
            $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending
        }
        return dirs.sorted(by: byName) + files.sorted(by: byName)
    }

    /// Reconciles a freshly-listed tree level against the existing one so that
    /// expansion state and lazily-loaded children survive a refresh (watcher
    /// fires would otherwise collapse every open folder). Reuses existing node
    /// instances when the path/kind matches to avoid needless view churn, and
    /// only re-lists children of folders that are actually expanded + loaded.
    private func merge(old: [FileTreeNode], fresh: [FileTreeNode], repo: Repository) async -> [FileTreeNode] {
        let oldById = Dictionary(old.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        var result: [FileTreeNode] = []
        for node in fresh {
            guard let existing = oldById[node.id], existing.isDirectory == node.isDirectory else {
                result.append(node)   // new entry — collapsed by default
                continue
            }
            if existing.isDirectory, existing.isExpanded, existing.isLoaded {
                let childFresh = listDir(repo: repo, relPath: existing.id)
                existing.children = await merge(old: existing.children, fresh: childFresh, repo: repo)
            }
            result.append(existing)
        }
        return result
    }

    func loadChildren(of node: FileTreeNode) async {
        guard let repo = repoSource(), node.isDirectory, !node.isLoaded else { return }
        node.isLoading = true
        node.children = listDir(repo: repo, relPath: node.id)
        node.isLoaded = true
        node.isLoading = false
    }

    /// Repo folder name, shown as the tree's root node.
    var repoName: String? { repoSource()?.url.lastPathComponent }

    /// Abbreviated repo path (`~/...`) shown next to the root node.
    var repoDisplayPath: String? {
        repoSource().map { ($0.url.path as NSString).abbreviatingWithTildeInPath }
    }

    // MARK: - Folder utilities (right-click)

    /// Prompt for a name and create an empty file inside `dir` (repo root when nil).
    func newFile(in dir: FileTreeNode?) {
        guard let name = promptName(title: "New File", placeholder: "name.txt") else { return }
        createEntry(name: name, in: dir, directory: false)
    }

    /// Prompt for a name and create a folder inside `dir` (repo root when nil).
    func newFolder(in dir: FileTreeNode?) {
        guard let name = promptName(title: "New Folder", placeholder: "folder") else { return }
        createEntry(name: name, in: dir, directory: true)
    }

    private func createEntry(name: String, in dir: FileTreeNode?, directory: Bool) {
        guard let repo = repoSource() else { return }
        let base = dir.map { repo.url.appendingPathComponent($0.id) } ?? repo.url
        let target = base.appendingPathComponent(name)
        do {
            if directory {
                try FileManager.default.createDirectory(at: target, withIntermediateDirectories: true)
            } else {
                try FileManager.default.createDirectory(at: target.deletingLastPathComponent(),
                                                        withIntermediateDirectories: true)
                if !FileManager.default.fileExists(atPath: target.path) {
                    try Data().write(to: target)
                }
            }
        } catch {
            main.errorMessage = error.localizedDescription
            return
        }
        Task {
            if let dir {
                dir.isLoaded = false
                await loadChildren(of: dir)
                dir.isExpanded = true
            } else {
                await refreshFileTree()
            }
        }
    }

    #if canImport(AppKit)
    private func promptName(title: String, placeholder: String) -> String? {
        let alert = NSAlert()
        alert.messageText = title
        alert.addButton(withTitle: "Create")
        alert.addButton(withTitle: "Cancel")
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 280, height: 24))
        field.placeholderString = placeholder
        alert.accessoryView = field
        alert.window.initialFirstResponder = field
        guard alert.runModal() == .alertFirstButtonReturn else { return nil }
        let name = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        return name.isEmpty ? nil : name
    }
    #endif

    func revealRoot() {
        guard let repo = repoSource() else { return }
        FileActions.reveal(absPath: repo.url.path)
    }

    func openRootInTerminal() {
        guard let repo = repoSource() else { return }
        FileActions.openTerminal(dir: repo.url.path)
    }

    func copyRootPath() {
        guard let repo = repoSource() else { return }
        FileActions.copyToPasteboard(repo.url.path)
    }

    // MARK: - File utilities (right-click)

    /// Absolute path of a node (`node.id` is the repo-relative path).
    func absolutePath(_ node: FileTreeNode) -> String? {
        guard let repo = repoSource() else { return nil }
        return repo.url.appendingPathComponent(node.id).path
    }

    func revealInFinder(_ node: FileTreeNode) {
        guard let path = absolutePath(node) else { return }
        FileActions.reveal(absPath: path)
    }

    func openInDefaultApp(_ node: FileTreeNode) {
        guard let path = absolutePath(node),
              FileManager.default.fileExists(atPath: path) else { return }
        FileActions.openDefault(absPath: path)
    }

    /// Open the node's directory (or the file's parent) in Terminal.
    func openInTerminal(_ node: FileTreeNode) {
        guard let path = absolutePath(node) else { return }
        let dir = node.isDirectory ? path : (path as NSString).deletingLastPathComponent
        FileActions.openTerminal(dir: dir)
    }

    func copyAbsolutePath(_ node: FileTreeNode) {
        guard let path = absolutePath(node) else { return }
        FileActions.copyToPasteboard(path)
    }

    func copyRelativePath(_ node: FileTreeNode) {
        FileActions.copyToPasteboard(node.id)
    }

    func copyFileName(_ node: FileTreeNode) {
        FileActions.copyToPasteboard(node.name)
    }

    func copyFileContents(_ node: FileTreeNode) {
        guard !node.isDirectory, let path = absolutePath(node),
              let text = try? String(contentsOfFile: path, encoding: .utf8) else { return }
        FileActions.copyToPasteboard(text)
    }
}
