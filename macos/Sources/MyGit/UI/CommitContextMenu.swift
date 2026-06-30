import SwiftUI

/// Right-click menu for a commit in History — grouped like JetBrains' Git log,
/// with history-rewrite items grayed out for already-pushed commits.
struct CommitContextMenu: View {
    let commit: GitCommit
    @ObservedObject var vm: HistoryViewModel

    private var canRewrite: Bool { vm.canRewrite(commit) }
    private var isTip: Bool { vm.isTip(commit) }
    private var isRoot: Bool { commit.parents.isEmpty }

    var body: some View {
        Button("Copy Revision Number") { vm.copyHash(commit) }
        Button("Create Patch…") { vm.createPatch(commit) }
        Button("Cherry-Pick") { vm.cherryPick(commit) }

        Divider()

        Button("Checkout Revision") { vm.checkout(commit) }
        Button("Show Repository at Revision") { vm.showAtRevision(commit) }
        Button("Compare with Local") { vm.compareWithLocal(commit) }

        Divider()

        Button("Reset Current Branch to Here…") { vm.pendingReset = commit }
        Button("Revert Commit") { vm.pendingRevert = commit }
        Button("Undo Commit…") { vm.undo(commit) }
            .disabled(!isTip || vm.isPushed(commit))

        Divider()

        Button("Edit Commit Message…") { vm.editMessageFor = commit }.disabled(!canRewrite)
        Button("Fixup…") { vm.fixupIntoParent(commit) }.disabled(!canRewrite || isRoot)
        Button("Squash Into…") { vm.squashIntoParent(commit) }.disabled(!canRewrite || isRoot)
        Button("Drop Commit") { vm.pendingDrop = commit }.disabled(!canRewrite)
        Button("Interactively Rebase from Here…") { vm.rebaseFrom = commit }.disabled(!canRewrite)

        Divider()

        Button("Push All up to Here…") { vm.pushUpToHere(commit) }

        Divider()

        Button("New Branch…") { vm.newBranchFrom = commit }
        Button("New Tag…") { vm.newTagFrom = commit }

        Divider()

        Button("Go to Child Commit") { vm.goToChild(commit) }
        Button("Go to Parent Commit") { vm.goToParent(commit) }.disabled(isRoot)
    }
}
