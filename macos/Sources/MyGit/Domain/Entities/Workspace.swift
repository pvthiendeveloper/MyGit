import Foundation

/// A folder the user added. Either a single git repo (the folder itself has
/// `.git`) or a parent folder containing several sibling git repos. Unifies
/// both cases so the rest of the app always works with a list of repos.
struct Workspace: Identifiable, Hashable {
    var id: URL { url }
    /// The folder the user picked.
    let url: URL
    /// Git repos under this workspace. One entry (== url) when the folder is
    /// itself a repo; N entries for nested sibling repos.
    let repos: [Repository]

    var name: String { url.lastPathComponent }

    /// True when the workspace is a plain single repo (folder == repo).
    var isSingle: Bool { repos.count == 1 && repos[0].url == url }
}
