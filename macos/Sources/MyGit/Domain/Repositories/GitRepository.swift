import Foundation

/// Which side of a merge to keep when resolving a conflict.
/// `ours` = the branch being merged into (current HEAD); `theirs` = the incoming branch.
enum ConflictSide {
    case ours, theirs
}

/// How a `git cherry-pick` ended. Git leaves the sequencer mid-flight for the
/// last two, so the UI has to offer a way out (resolve / skip / abort).
enum CherryPickOutcome {
    case done
    /// Conflicts staged as unmerged paths; `CHERRY_PICK_HEAD` is set.
    case conflicts
    /// The pick produced no changes (already applied, or emptied by conflict
    /// resolution). Git wants `--skip` or `commit --allow-empty`.
    case empty
}

/// One `git grep` hit: a repo-relative path, the 1-based line number, and the
/// matching line's text (trimmed for preview).
struct GitGrepMatch: Sendable, Hashable {
    let path: String
    let line: Int
    let preview: String
}

protocol GitRepository: Sendable {
    // Inspect
    func status(at repo: URL) async throws -> GitStatusSummary
    func log(at repo: URL, limit: Int) async throws -> [GitCommit]
    func graphLog(at repo: URL, limit: Int, filter: HistoryFilter) async throws -> [GitCommit]
    func tags(at repo: URL) async throws -> [String]
    func diff(at repo: URL, change: FileChange) async throws -> FileDiff
    func diff(at repo: URL, commit: GitCommit) async throws -> FileDiff
    func lsTree(at repo: URL, path: String?) async throws -> [FileTreeNode]
    func account(at repo: URL) async -> GitAccount
    func setRemoteURL(_ url: String, name: String, at repo: URL) async throws
    func addRemote(name: String, url: String, at repo: URL) async throws

    // Commit / index
    func commit(at repo: URL, paths: [String], message: String) async throws
    func amend(at repo: URL, paths: [String], newMessage: String?) async throws
    func headExists(at repo: URL) async -> Bool
    func headCommitMessage(at repo: URL) async throws -> String
    func stashPush(message: String?, at repo: URL) async throws
    func stashList(at repo: URL) async throws -> [GitStash]
    func stashApply(index: Int, at repo: URL) async throws
    func stashPop(index: Int, at repo: URL) async throws
    func stashDrop(index: Int, at repo: URL) async throws
    func stashClear(at repo: URL) async throws
    func stashFiles(index: Int, at repo: URL) async throws -> [String]

    // File ops
    func restore(at repo: URL, paths: [String]) async throws
    func addToIndex(at repo: URL, paths: [String]) async throws
    func removeFile(at repo: URL, path: String, tracked: Bool) async throws
    /// Roll the working tree + index back to HEAD. `includeUntracked` also deletes
    /// untracked files and directories (ignored files are always kept).
    func discardAll(at repo: URL, includeUntracked: Bool) async throws
    func diffPatch(at repo: URL, changes: [FileChange]) async throws -> String

    // Remote
    func fetch(at repo: URL, auth: AuthOverride?) async throws
    func pull(at repo: URL, auth: AuthOverride?) async throws
    func push(at repo: URL, args: [String], auth: AuthOverride?) async throws
    /// Short upstream ref of the current branch (e.g. "origin/feature/x"), or
    /// nil when the branch has no configured upstream.
    func upstreamRef(at repo: URL) async -> String?

    // Branches
    func branches(at repo: URL, currentBranch: String?) async throws -> [GitBranch]
    func recentBranches(at repo: URL) async throws -> [String]
    func checkout(_ name: String, at repo: URL) async throws
    func createBranch(_ name: String, from: String, at repo: URL) async throws
    func checkoutAndRebase(branch: String, onto: String, at repo: URL) async throws
    func checkoutAndUpdate(branch: String, at repo: URL) async throws
    func compareBranches(a: String, b: String, at repo: URL) async throws -> String
    func diffWithWorkingTree(branch: String, at repo: URL) async throws -> String
    func rebase(base: String, onto: String, at repo: URL) async throws
    func merge(source: String, into target: String, at repo: URL) async throws
    func abortMerge(at repo: URL) async throws
    /// Resolve one conflicted path by taking a whole side, then stage it.
    func resolveConflict(path: String, using side: ConflictSide, at repo: URL) async throws
    /// Stage manually-resolved paths (marks them resolved in the index).
    func markResolved(paths: [String], at repo: URL) async throws
    /// Finish an in-progress merge by committing the staged result (uses MERGE_MSG).
    func commitMerge(at repo: URL) async throws
    /// Name of the incoming branch of an in-progress merge (from MERGE_HEAD), if any.
    func mergeSourceName(at repo: URL) async -> String?
    /// Read a single git config value (`git config --get <key>`), nil if unset.
    func configValue(_ key: String, at repo: URL) async -> String?
    /// Read one of the three conflict stages of a path from the index:
    /// 1 = base (merge base), 2 = ours (HEAD), 3 = theirs (MERGE_HEAD).
    /// Returns "" when the stage is absent (side added/deleted the file).
    func readMergeStage(_ stage: Int, path: String, at repo: URL) async throws -> String
    /// All three conflict stages at once (base, ours, theirs).
    func readMergeConflict(path: String, at repo: URL) async throws -> (base: String, ours: String, theirs: String)
    /// True when a conflicted path is a mergeable text file (not a gitlink/binary),
    /// so the 3-way merge editor can be offered.
    func isTextConflict(path: String, at repo: URL) async -> Bool
    func updateBranch(_ name: String, isCurrent: Bool, at repo: URL) async throws
    func setUpstream(branch: String, upstream: String, at repo: URL) async throws
    func renameBranch(old: String, new: String, at repo: URL) async throws
    func deleteBranch(_ name: String, force: Bool, at repo: URL) async throws
    func newWorktree(path: URL, from: String, at repo: URL) async throws
    func checkoutRevision(_ rev: String, at repo: URL) async throws

    // Commit actions
    @discardableResult
    func cherryPick(commit: String, at repo: URL) async throws -> CherryPickOutcome
    /// Drop the in-flight pick and move to the next one (`cherry-pick --skip`).
    func cherryPickSkip(at repo: URL) async throws
    /// Roll the whole sequence back (`cherry-pick --abort`).
    func cherryPickAbort(at repo: URL) async throws
    /// Resume after conflicts were staged (`cherry-pick --continue`).
    func cherryPickContinue(at repo: URL) async throws
    /// Record the empty pick as an empty commit, then resume the sequence.
    func cherryPickCommitEmpty(at repo: URL) async throws
    func revertCommit(_ commit: String, at repo: URL) async throws
    func resetTo(commit: String, mode: GitResetMode, at repo: URL) async throws
    func formatPatch(commit: String, at repo: URL) async throws -> String
    func createTag(_ name: String, at commit: String, message: String?, at repo: URL) async throws
    func lsTreeAtRevision(_ rev: String, at repo: URL) async throws -> [String]
    /// All tracked file paths (repo-relative), recursive. Drives Search Everywhere.
    func listFiles(at repo: URL) async throws -> [String]
    /// Content search over tracked files (`git grep`). Drives Search Everywhere's
    /// content/both scopes. Case-insensitive fixed-string match.
    func grep(query: String, at repo: URL) async throws -> [GitGrepMatch]
    /// Every whole-word occurrence of a symbol across tracked files. Backs
    /// ⌘-click "go to definition" / "find usages" in the editor.
    func searchSymbol(_ symbol: String, at repo: URL) async throws -> [GitGrepMatch]
    func pushedHashes(at repo: URL) async throws -> Set<String>
    /// Refs (branches/tags, short names) that point directly at a commit.
    func refsPointingAt(commit: String, at repo: URL) async throws -> [String]
    /// Branches whose history contains a commit, split by local / remote-tracking.
    func branchesContaining(commit: String, at repo: URL) async throws -> (local: [String], remote: [String])
    /// True when `commit` is reachable from `ref` (so HEAD-relative rewrites apply).
    func isAncestor(_ commit: String, of ref: String, at repo: URL) async -> Bool
    func amendMessage(_ message: String, at repo: URL) async throws
    func interactiveRebase(todo: [RebaseStep], onto base: String, at repo: URL) async throws

    // Compare
    func commitsInRange(_ range: String, at repo: URL) async throws -> [GitCommit]
    func changedFiles(commit: String, at repo: URL) async throws -> [ChangedFileEntry]
    /// Files changed across a ref range, e.g. `base...head` for a pull request.
    func changedFiles(range: String, at repo: URL) async throws -> [ChangedFileEntry]
    /// Unified patch for a single file across a ref range (e.g. `base...head`).
    func rangeFilePatch(range: String, path: String, at repo: URL) async throws -> String
    /// Full unified diff across a ref range (e.g. `base...head`) — used to feed
    /// an AI a pull request's whole change set.
    func rangeDiff(range: String, at repo: URL) async throws -> String
    func showFileAtCommit(commit: String, path: String, at repo: URL) async throws -> FileDiff
    func touchedHashes(range: String, paths: [String], at repo: URL) async throws -> Set<String>
    func diffFileVsWorking(commit: String, path: String, at repo: URL) async throws -> FileDiff
    func diffFileBeforeVsWorking(commit: String, path: String, at repo: URL) async throws -> FileDiff
    func extractFileAtCommit(commit: String, path: String, at repo: URL) async throws -> URL
    func revertFileInCommit(commit: String, path: String, at repo: URL) async throws
    func cherryPickFileFromCommit(commit: String, path: String, at repo: URL) async throws
    func patchForFile(commit: String, path: String, at repo: URL) async throws -> String
    func readFileAtCommit(commit: String, path: String, at repo: URL) async throws -> String
}
