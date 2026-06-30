import SwiftUI

struct HistoryListView: View {
    @EnvironmentObject var vm: HistoryViewModel

    var body: some View {
        Group {
            if vm.commits.isEmpty {
                Text("No commits yet")
                    .foregroundStyle(.secondary)
                    .padding(20)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
            } else {
                List(selection: $vm.selectedCommit) {
                    ForEach(vm.commits) { commit in
                        CommitRow(commit: commit)
                            .tag(commit as GitCommit?)
                            .contextMenu { CommitContextMenu(commit: commit, vm: vm) }
                    }
                }
                .listStyle(.inset)
            }
        }
        .modifier(CommitActionHost(vm: vm))
    }
}

/// Hosts every confirm dialog / input sheet the commit context menu triggers,
/// driven by the optional trigger state on HistoryViewModel.
private struct CommitActionHost: ViewModifier {
    @ObservedObject var vm: HistoryViewModel

    func body(content: Content) -> some View {
        content
            // Reset — soft / mixed / hard
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

            // Revert
            .confirmationDialog(
                "Revert this commit?",
                isPresented: bool($vm.pendingRevert),
                presenting: vm.pendingRevert
            ) { c in
                Button("Revert", role: .destructive) { vm.revert(c) }
                Button("Cancel", role: .cancel) {}
            } message: { _ in Text("Creates a new commit that undoes these changes.") }

            // Drop
            .confirmationDialog(
                "Drop this commit?",
                isPresented: bool($vm.pendingDrop),
                presenting: vm.pendingDrop
            ) { c in
                Button("Drop", role: .destructive) { vm.drop(c) }
                Button("Cancel", role: .cancel) {}
            } message: { _ in Text("Rewrites history to remove this commit. Local commits only.") }

            // New Branch
            .sheet(item: $vm.newBranchFrom) { c in
                InputSheet(title: "New Branch", prompt: "Branch name",
                           placeholder: "new-branch", seed: "") { vm.createBranch(c, name: $0) }
            }
            // New Tag
            .sheet(item: $vm.newTagFrom) { c in
                InputSheet(title: "New Tag", prompt: "Tag name",
                           placeholder: "v1.0.0", seed: "") { vm.createTag(c, name: $0) }
            }
            // Edit Commit Message
            .sheet(item: $vm.editMessageFor) { c in
                InputSheet(title: "Edit Commit Message", prompt: "Message",
                           placeholder: "subject", seed: c.subject) { vm.editMessage(c, newMessage: $0) }
            }
            // Interactive rebase
            .sheet(item: $vm.rebaseFrom) { c in
                InteractiveRebaseSheet(commit: c, vm: vm)
            }
            // Compare-with-local diff output
            .sheet(isPresented: bool($vm.diffResult)) {
                TextOutputSheet(title: "Compare with Local", text: vm.diffResult ?? "")
            }
            // Show-at-revision file tree
            .sheet(isPresented: bool($vm.treeResult)) {
                TextOutputSheet(title: "Repository at Revision",
                                text: (vm.treeResult ?? []).joined(separator: "\n"))
            }
    }

    /// Bridge an optional trigger to an isPresented Bool binding.
    private func bool<T>(_ b: Binding<T?>) -> Binding<Bool> {
        Binding(get: { b.wrappedValue != nil }, set: { if !$0 { b.wrappedValue = nil } })
    }
}

/// Self-seeding single-field input sheet (TextInputSheet needs an external
/// binding; this manages its own state so we can prefill per commit).
private struct InputSheet: View {
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
private struct TextOutputSheet: View {
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

struct CommitRow: View {
    let commit: GitCommit

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(commit.subject)
                .font(.system(size: 12, weight: .medium))
                .lineLimit(2)
            HStack(spacing: 6) {
                Text(commit.author)
                Text("·")
                Text(commit.shortHash).font(.system(.caption, design: .monospaced))
                Text("·")
                Text(commit.date, format: .relative(presentation: .named))
            }
            .font(.caption)
            .foregroundStyle(.secondary)
        }
        .padding(.vertical, 4)
        .contentShape(Rectangle())
    }
}
