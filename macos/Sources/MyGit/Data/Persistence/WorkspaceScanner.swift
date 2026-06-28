import Foundation

/// Turns a picked folder into a `Workspace`. The whole tree under the folder is
/// walked recursively for git repos; the root is included when it is a repo too.
/// So a plain repo → single-repo workspace; a parent of sibling repos →
/// multi-repo; a repo that *also* nests repos (at any depth) → root + nested.
///
/// `.skipsHiddenFiles` keeps the walk out of every repo's `.git/` internals
/// (it is hidden), but we still descend *into* a found repo's working tree so
/// repos nested deeper inside another repo are picked up.
enum WorkspaceScanner {
    /// A path is a git repo if it contains `.git` (a dir for normal repos, a
    /// file for worktrees/submodules) — same predicate the rest of the app uses.
    static func isGitRepo(_ url: URL) -> Bool {
        FileManager.default.fileExists(atPath: url.appendingPathComponent(".git").path)
    }

    static func scan(_ folder: URL) -> Workspace {
        let root = folder.standardizedFileURL.resolvingSymlinksInPath()

        var nested: [Repository] = []
        if let walker = FileManager.default.enumerator(
            at: root,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles, .skipsPackageDescendants]
        ) {
            for case let url as URL in walker {
                guard (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true,
                      isGitRepo(url) else { continue }
                nested.append(Repository(url: url.standardizedFileURL.resolvingSymlinksInPath()))
            }
        }
        nested.sort { $0.url.path.localizedCaseInsensitiveCompare($1.url.path) == .orderedAscending }

        // Root repo (if any) first, then nested repos in path order.
        let repos = (isGitRepo(root) ? [Repository(url: root)] : []) + nested
        return Workspace(url: root, repos: repos)
    }
}
