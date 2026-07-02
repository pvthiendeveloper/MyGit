import Foundation

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
        let fresh = (try? await git.lsTree(at: repo.url, path: nil)) ?? []
        fileTreeNodes = await merge(old: fileTreeNodes, fresh: fresh, repo: repo)
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
                let childFresh = (try? await git.lsTree(at: repo.url, path: existing.id)) ?? []
                existing.children = await merge(old: existing.children, fresh: childFresh, repo: repo)
            }
            result.append(existing)
        }
        return result
    }

    func loadChildren(of node: FileTreeNode) async {
        guard let repo = repoSource(), node.isDirectory, !node.isLoaded else { return }
        node.isLoading = true
        node.children = (try? await git.lsTree(at: repo.url, path: node.id)) ?? []
        node.isLoaded = true
        node.isLoading = false
    }
}
