import Foundation

/// Turns a picked folder into a `Workspace`. If the folder is itself a git
/// repo it becomes a single-repo workspace; otherwise its immediate children
/// are scanned (one level) for nested git repos.
enum WorkspaceScanner {
    /// A path is a git repo if it contains `.git` (a dir for normal repos, a
    /// file for worktrees/submodules) — same predicate the rest of the app uses.
    static func isGitRepo(_ url: URL) -> Bool {
        FileManager.default.fileExists(atPath: url.appendingPathComponent(".git").path)
    }

    static func scan(_ folder: URL) -> Workspace {
        let root = folder.standardizedFileURL.resolvingSymlinksInPath()
        if isGitRepo(root) {
            return Workspace(url: root, repos: [Repository(url: root)])
        }
        let children = (try? FileManager.default.contentsOfDirectory(
            at: root,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        )) ?? []
        let repos = children
            .filter { (try? $0.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true }
            .filter { isGitRepo($0) }
            .map { Repository(url: $0.standardizedFileURL.resolvingSymlinksInPath()) }
            .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
        return Workspace(url: root, repos: repos)
    }
}
