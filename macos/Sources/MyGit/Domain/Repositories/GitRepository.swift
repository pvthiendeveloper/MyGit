import Foundation

protocol GitRepository: Sendable {
    // Inspect
    func status(at repo: URL) async throws -> GitStatusSummary
    func log(at repo: URL, limit: Int) async throws -> [GitCommit]
    func diff(at repo: URL, change: FileChange) async throws -> FileDiff
    func diff(at repo: URL, commit: GitCommit) async throws -> FileDiff
    func lsTree(at repo: URL, path: String?) async throws -> [FileTreeNode]
    func account(at repo: URL) async -> GitAccount
    func setRemoteURL(_ url: String, name: String, at repo: URL) async throws
    func addRemote(name: String, url: String, at repo: URL) async throws

    // Commit / index
    func commit(at repo: URL, paths: [String], message: String) async throws
    func stashPush(message: String?, at repo: URL) async throws

    // Remote
    func fetch(at repo: URL, auth: AuthOverride?) async throws
    func pull(at repo: URL, auth: AuthOverride?) async throws
    func push(at repo: URL, args: [String], auth: AuthOverride?) async throws

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
    func updateBranch(_ name: String, isCurrent: Bool, at repo: URL) async throws
    func setUpstream(branch: String, upstream: String, at repo: URL) async throws
    func renameBranch(old: String, new: String, at repo: URL) async throws
    func deleteBranch(_ name: String, force: Bool, at repo: URL) async throws
    func newWorktree(path: URL, from: String, at repo: URL) async throws
    func checkoutRevision(_ rev: String, at repo: URL) async throws
}
