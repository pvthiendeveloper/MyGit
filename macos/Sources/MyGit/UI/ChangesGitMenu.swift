import SwiftUI

/// Repo-level VCS actions for the Changes section header's right-click menu — the
/// IntelliJ Git menu, flat. Targets that section's `RepoBundle` (correct in multi-repo).
/// Branch-target ops (Merge/Rebase/Branches) open the existing toolbar BranchPopover.
struct ChangesGitMenu: View {
    let bundle: RepoBundle
    @AppStorage("MyGit.changes.groupByDirectory") private var byDirectory = false
    @EnvironmentObject var main: MainViewModel
    @EnvironmentObject var coordinator: AppCoordinator
    // Observed so the rollback item's count/enabled state tracks the live status.
    @ObservedObject private var changes: ChangesViewModel

    init(bundle: RepoBundle) {
        self.bundle = bundle
        self._changes = ObservedObject(wrappedValue: bundle.changes)
    }

    private var remote: RemoteViewModel { bundle.remote }

    var body: some View {
        // Remote & log
        Button("Commit…") { main.tab = .changes }
        Button("Push…") { Task { await remote.push() } }
        Button("Pull…") { Task { await remote.pull() } }
        if PullRequestRouter.supports(host: bundle.account.account?.host) {
            Button("Create Pull Request…") {
                coordinator.setActive(bundle)
                bundle.pullRequests.startCompose()
                main.tab = .pullRequests
            }
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

        if changes.status?.mergeInProgress == true {
            Button("Abort Merge", role: .destructive) { changes.pendingAbortMerge = true }
        }

        if changes.status?.rebaseInProgress == true {
            Button("Continue Rebase") { Task { await changes.continueRebase() } }
                .disabled(changes.status?.hasConflicts == true)
            Button("Skip Commit") { Task { await changes.skipRebase() } }
            Button("Abort Rebase", role: .destructive) { changes.pendingAbortRebase = true }
        }

        if changes.status?.cherryPickInProgress == true {
            Button("Continue Cherry-Pick") { Task { await changes.continueCherryPick() } }
                .disabled(changes.status?.hasConflicts == true)
            Button("Skip Commit") { Task { await changes.skipCherryPick() } }
            Button("Abort Cherry-Pick", role: .destructive) { changes.pendingAbortCherryPick = true }
        }

        Divider()

        // Create
        Button("New Branch…") { changes.pendingNewBranch = true }
        Button("New Tag…") { changes.pendingNewTag = true }
        Button("Reset HEAD…") { changes.pendingResetHead = true }
        Button("New Worktree…") { changes.createWorktree() }

        Divider()

        Button("Show Git Log") { main.tab = .history }
        Menu("Group By") {
            Toggle("Directory", isOn: $byDirectory)
        }

        Divider()

        Menu("Patch") {
            Button("Create Patch from All Changes…") { changes.createPatchAllChanges() }
        }
        Menu("Uncommitted Changes") {
            Button("Stash All…") { changes.pendingStash = true }
            Button(rollbackTitle, role: .destructive) { changes.pendingDiscardAll = true }
                .disabled(changeCount == 0)
        }

        Divider()

        // Top-level too — rollback-all is a frequent action, one click deep.
        Button(rollbackTitle, role: .destructive) { changes.pendingDiscardAll = true }
            .disabled(changeCount == 0)
    }

    private var changeCount: Int { changes.status?.changes.count ?? 0 }

    private var rollbackTitle: String {
        changeCount > 0 ? "Rollback All (\(changeCount) file\(changeCount == 1 ? "" : "s"))…"
                        : "Rollback All…"
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
                "Abort the in-progress merge?",
                isPresented: $vm.pendingAbortMerge
            ) {
                Button("Abort Merge", role: .destructive) {
                    Task { await vm.abortMerge() }
                }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("Discards the merge and restores the working tree to before it started.")
            }
            .confirmationDialog(
                "Abort the in-progress rebase?",
                isPresented: $vm.pendingAbortRebase
            ) {
                Button("Abort Rebase", role: .destructive) {
                    Task { await vm.abortRebase() }
                }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("Restores the branch to where it was before the rebase started.")
            }
            .confirmationDialog(
                "Abort the in-progress cherry-pick?",
                isPresented: $vm.pendingAbortCherryPick
            ) {
                Button("Abort Cherry-Pick", role: .destructive) {
                    Task { await vm.abortCherryPick() }
                }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("Discards the picked changes and restores the branch to before the cherry-pick started.")
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
                "Rollback all local changes?",
                isPresented: $vm.pendingDiscardAll
            ) {
                Button("Rollback All", role: .destructive) {
                    Task { await vm.discardAllChanges(includeUntracked: true) }
                }
                Button("Rollback Tracked Only", role: .destructive) {
                    Task { await vm.discardAllChanges(includeUntracked: false) }
                }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("Resets tracked files to HEAD and deletes untracked files "
                     + "(ignored files are kept). This cannot be undone.")
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
