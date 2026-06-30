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

extension View {
    /// Attach every confirm dialog / input sheet the commit context menu triggers.
    func commitActionHost(_ vm: HistoryViewModel) -> some View {
        modifier(CommitActionHost(vm: vm))
    }
}

/// Hosts the dialogs/sheets driven by the optional trigger state on the VM.
struct CommitActionHost: ViewModifier {
    @ObservedObject var vm: HistoryViewModel

    func body(content: Content) -> some View {
        content
            .confirmationDialog(
                "Reset current branch to this commit?",
                isPresented: bool($vm.pendingReset),
                presenting: vm.pendingReset
            ) { c in
                ForEach(GitResetMode.allCases, id: \.self) { mode in
                    Button(mode.label, role: mode == .hard ? .destructive : nil) {
                        vm.reset(c, mode: mode)
                    }
                }
                Button("Cancel", role: .cancel) {}
            } message: { _ in Text("Hard reset discards working-tree changes.") }

            .confirmationDialog(
                "Revert this commit?",
                isPresented: bool($vm.pendingRevert),
                presenting: vm.pendingRevert
            ) { c in
                Button("Revert", role: .destructive) { vm.revert(c) }
                Button("Cancel", role: .cancel) {}
            } message: { _ in Text("Creates a new commit that undoes these changes.") }

            .confirmationDialog(
                "Drop this commit?",
                isPresented: bool($vm.pendingDrop),
                presenting: vm.pendingDrop
            ) { c in
                Button("Drop", role: .destructive) { vm.drop(c) }
                Button("Cancel", role: .cancel) {}
            } message: { _ in Text("Rewrites history to remove this commit. Local commits only.") }

            .sheet(item: $vm.newBranchFrom) { c in
                CommitInputSheet(title: "New Branch", prompt: "Branch name",
                                 placeholder: "new-branch", seed: "") { vm.createBranch(c, name: $0) }
            }
            .sheet(item: $vm.newTagFrom) { c in
                CommitInputSheet(title: "New Tag", prompt: "Tag name",
                                 placeholder: "v1.0.0", seed: "") { vm.createTag(c, name: $0) }
            }
            .sheet(item: $vm.editMessageFor) { c in
                CommitInputSheet(title: "Edit Commit Message", prompt: "Message",
                                 placeholder: "subject", seed: c.subject) { vm.editMessage(c, newMessage: $0) }
            }
            .sheet(item: $vm.rebaseFrom) { c in
                InteractiveRebaseSheet(commit: c, vm: vm)
            }
            .sheet(isPresented: bool($vm.diffResult)) {
                CommitTextOutputSheet(title: "Compare with Local", text: vm.diffResult ?? "")
            }
            .sheet(isPresented: bool($vm.treeResult)) {
                CommitTextOutputSheet(title: "Repository at Revision",
                                      text: (vm.treeResult ?? []).joined(separator: "\n"))
            }
    }

    private func bool<T>(_ b: Binding<T?>) -> Binding<Bool> {
        Binding(get: { b.wrappedValue != nil }, set: { if !$0 { b.wrappedValue = nil } })
    }
}

/// Self-seeding single-field input sheet (prefilled per commit).
struct CommitInputSheet: View {
    let title: String
    let prompt: String
    let placeholder: String
    let onConfirm: (String) -> Void
    @State private var text: String
    @Environment(\.dismiss) private var dismiss

    init(title: String, prompt: String, placeholder: String, seed: String,
         onConfirm: @escaping (String) -> Void) {
        self.title = title
        self.prompt = prompt
        self.placeholder = placeholder
        self.onConfirm = onConfirm
        _text = State(initialValue: seed)
    }

    var body: some View {
        VStack(spacing: 16) {
            Text(title).font(.headline)
            LabeledContent(prompt) {
                TextField(placeholder, text: $text)
                    .textFieldStyle(.roundedBorder).frame(width: 240)
            }
            HStack {
                Button("Cancel", role: .cancel) { dismiss() }
                Button("OK") {
                    let v = text.trimmingCharacters(in: .whitespacesAndNewlines)
                    guard !v.isEmpty else { return }
                    onConfirm(v); dismiss()
                }
                .keyboardShortcut(.return, modifiers: [])
                .disabled(text.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
        .padding(24).frame(width: 380)
    }
}

/// Read-only scrollable text output (diff / file list).
struct CommitTextOutputSheet: View {
    let title: String
    let text: String
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(title).font(.headline)
            ScrollView {
                Text(text.isEmpty ? "(empty)" : text)
                    .font(.system(.caption, design: .monospaced))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(width: 640, height: 420)
            .background(Color(NSColor.textBackgroundColor))
            HStack { Spacer(); Button("Close") { dismiss() }.keyboardShortcut(.defaultAction) }
        }
        .padding(20)
    }
}
