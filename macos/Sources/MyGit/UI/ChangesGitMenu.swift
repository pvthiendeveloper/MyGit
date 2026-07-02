import SwiftUI

/// Repo-level VCS actions for the Changes section header's right-click menu — the
/// IntelliJ Git menu, flat. Targets that section's `RepoBundle` (correct in multi-repo).
/// Branch-target ops (Merge/Rebase/Branches) open the existing toolbar BranchPopover.
struct ChangesGitMenu: View {
    let bundle: RepoBundle
    @EnvironmentObject var main: MainViewModel

    private var remote: RemoteViewModel { bundle.remote }
    private var changes: ChangesViewModel { bundle.changes }

    var body: some View {
        // Remote & log
        Button("Commit…") { main.tab = .changes }
        Button("Push…") { Task { await remote.push() } }
        Button("Pull…") { Task { await remote.pull() } }
        if PullRequestRouter.supports(host: bundle.account.account?.host) {
            Button("Create Pull Request…") { changes.pendingPullRequest = true }
        }
        Button("Update Project…") {
            Task { await remote.fetchOrigin(); await remote.pull() }
        }
        Button("Fetch") { Task { await remote.fetchOrigin() } }

        Divider()

        // Branch-target ops — open the branch picker (choose target there).
        Button("Merge…") { main.showBranchPopover = true }
        Button("Rebase…") { main.showBranchPopover = true }
        Button("Branches…") { main.showBranchPopover = true }

        Divider()

        // Create
        Button("New Branch…") { changes.pendingNewBranch = true }
        Button("New Tag…") { changes.pendingNewTag = true }
        Button("Reset HEAD…") { changes.pendingResetHead = true }
        Button("New Worktree…") { changes.createWorktree() }

        Divider()

        Button("Show Git Log") { main.tab = .history }

        Divider()

        Menu("Patch") {
            Button("Create Patch from All Changes…") { changes.createPatchAllChanges() }
        }
        Menu("Uncommitted Changes") {
            Button("Stash All…") { changes.pendingStash = true }
            Button("Rollback All…", role: .destructive) { changes.pendingDiscardAll = true }
        }
    }
}

extension View {
    /// Hosts the sheets/dialogs the Changes Git menu triggers (bound to `vm` pending state).
    func changesGitActionHost(_ vm: ChangesViewModel) -> some View {
        modifier(ChangesGitActionHost(vm: vm))
    }
}

struct ChangesGitActionHost: ViewModifier {
    @ObservedObject var vm: ChangesViewModel

    func body(content: Content) -> some View {
        content
            .sheet(isPresented: $vm.pendingNewBranch) {
                CommitInputSheet(title: "New Branch", prompt: "Branch name",
                                 placeholder: "new-branch", seed: "") { name in
                    Task { await vm.createBranch(name: name) }
                }
            }
            .sheet(isPresented: $vm.pendingNewTag) {
                CommitInputSheet(title: "New Tag", prompt: "Tag name",
                                 placeholder: "v1.0.0", seed: "") { name in
                    Task { await vm.tagHead(name: name) }
                }
            }
            .sheet(isPresented: $vm.pendingStash) {
                CommitInputSheet(title: "Stash Changes", prompt: "Title (optional)",
                                 placeholder: "WIP", seed: "", allowEmpty: true) { msg in
                    Task { await vm.stashAll(message: msg) }
                }
            }
            .confirmationDialog(
                "Reset current branch to HEAD?",
                isPresented: $vm.pendingResetHead
            ) {
                ForEach(GitResetMode.allCases, id: \.self) { mode in
                    Button(mode.label, role: mode == .hard ? .destructive : nil) {
                        Task { await vm.resetHead(mode: mode) }
                    }
                }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("Hard reset discards all uncommitted working-tree changes.")
            }
            .confirmationDialog(
                "Discard all local changes?",
                isPresented: $vm.pendingDiscardAll
            ) {
                Button("Discard All", role: .destructive) {
                    Task { await vm.discardAllChanges() }
                }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("Restores tracked files and deletes untracked ones. This cannot be undone.")
            }
            // Per-file rollback/delete alerts — hosted here (not just in
            // ChangesListView) so they also present in the multi-repo section view.
            .alert(
                "Rollback changes?",
                isPresented: Binding(
                    get: { vm.pendingRollback != nil },
                    set: { if !$0 { vm.pendingRollback = nil } }
                ),
                presenting: vm.pendingRollback
            ) { change in
                Button("Rollback", role: .destructive) {
                    Task { await vm.confirmRollback(change) }
                }
                Button("Cancel", role: .cancel) { vm.pendingRollback = nil }
            } message: { change in
                Text(change.isUntracked
                     ? "Delete untracked file \(change.path)? This cannot be undone."
                     : "Discard all local changes to \(change.path)?")
            }
            .alert(
                "Delete file?",
                isPresented: Binding(
                    get: { vm.pendingDelete != nil },
                    set: { if !$0 { vm.pendingDelete = nil } }
                ),
                presenting: vm.pendingDelete
            ) { change in
                Button("Delete", role: .destructive) {
                    Task { await vm.confirmDelete(change) }
                }
                Button("Cancel", role: .cancel) { vm.pendingDelete = nil }
            } message: { change in
                Text("Remove \(change.path) from the working tree? This cannot be undone.")
            }
    }
}
