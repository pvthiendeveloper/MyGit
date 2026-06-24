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
        fileTreeNodes = (try? await git.lsTree(at: repo.url, path: nil)) ?? []
    }

    func loadChildren(of node: FileTreeNode) async {
        guard let repo = repoSource(), node.isDirectory, !node.isLoaded else { return }
        node.isLoading = true
        node.children = (try? await git.lsTree(at: repo.url, path: node.id)) ?? []
        node.isLoaded = true
        node.isLoading = false
    }
}
