import Foundation

/// Checking out a remote-tracking branch (`origin/x`) lands on local `x`,
/// moved to the remote. A local `x` with commits the remote lacks isn't
/// silently rewritten: the user picks rebase onto the remote, drop the local
/// commits, or cancel (`MainViewModel.remoteCheckoutConflict`).
@MainActor
enum RemoteCheckout {
    typealias Op = (URL) async throws -> Void

    static func run(remoteRef: String, repo: URL, git: GitRepository, main: MainViewModel,
                    perform: @escaping (@escaping Op) async -> Void) async {
        let local = GitBranch.checkoutName(for: remoteRef, isRemote: true)
        let ahead: Int?
        do { ahead = try await git.localCommitsAhead(branch: local, of: remoteRef, at: repo) }
        catch { main.errorMessage = error.localizedDescription; return }

        guard let ahead, ahead > 0 else {
            // No local branch yet, or one that's only behind: create / fast-forward it.
            await perform { try await git.checkoutResetting(branch: local, to: remoteRef, at: $0) }
            return
        }
        main.remoteCheckoutConflict = MainViewModel.RemoteCheckoutConflict(
            remoteRef: remoteRef, local: local, ahead: ahead,
            rebase: { Task { await perform { try await git.checkoutAndRebase(branch: local, onto: remoteRef, at: $0) } } },
            drop: { Task { await perform { try await git.checkoutResetting(branch: local, to: remoteRef, at: $0) } } }
        )
    }
}
