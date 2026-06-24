import SwiftUI

struct BranchActionMenu: View {
    let branch: GitBranch
    var onDismissParent: (() -> Void)? = nil
    @EnvironmentObject var main: MainViewModel
    @EnvironmentObject var changes: ChangesViewModel
    @EnvironmentObject var branchesVM: BranchesViewModel
    @EnvironmentObject var remote: RemoteViewModel
    @Environment(\.dismiss) private var dismiss

    @State private var showNewBranchSheet = false
    @State private var showRenameSheet = false
    @State private var showDeleteConfirm = false
    @State private var showWorktreePicker = false
    @State private var showRevisionSheet = false
    @State private var inputText = ""
    @State private var pendingDirtyNewBranchName: String? = nil

    private var current: String { changes.status?.branch ?? "" }
    private var name: String { branch.name }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            menuItem("Checkout") {
                run { await branchesVM.checkout(branch) }
            }
            menuItem("New Branch from '\(name)'…") {
                inputText = "\(name)-copy"
                showNewBranchSheet = true
            }
            if !current.isEmpty {
                menuItem("Checkout and Rebase onto '\(current)'") {
                    run { await branchesVM.checkoutAndRebase(branch: branch, onto: current) }
                }
            }
            menuItem("Checkout and Update") {
                run { await branchesVM.checkoutAndUpdate(branch) }
            }
            Divider().padding(.vertical, 2)
            if !current.isEmpty {
                menuItem("Compare with '\(current)'") {
                    run { await branchesVM.compare(branch, vs: current) }
                }
            }
            menuItem("Show Diff with Working Tree") {
                run { await branchesVM.diffWithWorkingTree(branch) }
            }
            Divider().padding(.vertical, 2)
            if !current.isEmpty {
                menuItem("Rebase '\(current)' onto '\(name)'") {
                    run { await branchesVM.rebase(base: current, onto: name) }
                }
                menuItem("Merge '\(name)' into '\(current)'") {
                    run { await branchesVM.merge(branch, into: current) }
                }
            }
            menuItem("New Worktree from '\(name)'…") {
                dismiss()
                onDismissParent?()
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                    branchesVM.pickWorktreeDirectory(for: branch)
                }
            }
            Divider().padding(.vertical, 2)
            menuItem("Update") {
                run { await branchesVM.updateBranch(branch) }
            }
            menuItem("Push…") {
                run { await remote.pushBranch(branch) }
            }
            if let up = branch.upstream {
                DisclosureGroup("Tracked Branch '\(up)'") {
                    ForEach(branchesVM.remoteBranchNames(matching: up), id: \.self) { remoteName in
                        Button(remoteName) {
                            run { await branchesVM.setUpstream(branch: branch, to: remoteName) }
                        }
                        .buttonStyle(.plain)
                        .padding(.leading, 12)
                        .padding(.vertical, 3)
                    }
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 4)
            }
            Divider().padding(.vertical, 2)
            menuItem("Rename…") {
                inputText = name
                showRenameSheet = true
            }
            menuItem("Delete", destructive: true) {
                showDeleteConfirm = true
            }
        }
        .padding(.vertical, 6)
        .frame(minWidth: 280)
        .sheet(isPresented: $showNewBranchSheet) {
            TextInputSheet(
                title: "New Branch",
                prompt: "Branch name",
                placeholder: "new-branch",
                value: $inputText
            ) { name in
                let dirty = (changes.status?.changes.isEmpty == false)
                if dirty {
                    pendingDirtyNewBranchName = name
                } else {
                    run { await branchesVM.createBranch(name: name, from: branch) }
                }
            }
        }
        .alert(
            "Uncommitted changes",
            isPresented: Binding(
                get: { pendingDirtyNewBranchName != nil },
                set: { if !$0 { pendingDirtyNewBranchName = nil } }
            ),
            presenting: pendingDirtyNewBranchName
        ) { newName in
            Button("Bring Changes") {
                run { await branchesVM.createBranch(name: newName, from: branch) }
                pendingDirtyNewBranchName = nil
            }
            Button("Stash, then Switch") {
                run { await branchesVM.stashAndCreateBranch(name: newName, from: branch) }
                pendingDirtyNewBranchName = nil
            }
            Button("Cancel", role: .cancel) { pendingDirtyNewBranchName = nil }
        } message: { newName in
            Text("You have changes on '\(branch.name)'. Bring them to '\(newName)' or stash first?")
        }
        .sheet(isPresented: $showRenameSheet) {
            TextInputSheet(
                title: "Rename Branch",
                prompt: "New name",
                placeholder: branch.name,
                value: $inputText
            ) { newName in
                run { await branchesVM.rename(branch, to: newName) }
            }
        }
        .alert("Delete '\(name)'?", isPresented: $showDeleteConfirm) {
            Button("Delete", role: .destructive) {
                run { await branchesVM.delete(branch, force: false) }
            }
            Button("Force Delete", role: .destructive) {
                run { await branchesVM.delete(branch, force: true) }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This action cannot be undone.")
        }
    }

    private func menuItem(_ label: String, destructive: Bool = false, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(label)
                .foregroundStyle(destructive ? Color.red : Color.primary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 12)
                .padding(.vertical, 5)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .hoverHighlight()
    }

    private func run(_ op: @escaping () async -> Void) {
        dismiss()
        onDismissParent?()
        Task { await op() }
    }
}

private extension View {
    func hoverHighlight() -> some View {
        self.modifier(HoverHighlightModifier())
    }
}

private struct HoverHighlightModifier: ViewModifier {
    @State private var isHovered = false
    func body(content: Content) -> some View {
        content
            .frame(maxWidth: .infinity)
            .background(isHovered ? Color.accentColor : Color.clear)
            .foregroundStyle(isHovered ? Color.white : Color.primary)
            .clipShape(RoundedRectangle(cornerRadius: 4))
            .contentShape(Rectangle())
            .onHover { isHovered = $0 }
    }
}

struct TextInputSheet: View {
    let title: String
    let prompt: String
    let placeholder: String
    @Binding var value: String
    let onConfirm: (String) -> Void

    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(spacing: 16) {
            Text(title).font(.headline)
            LabeledContent(prompt) {
                TextField(placeholder, text: $value)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 220)
            }
            HStack {
                Button("Cancel", role: .cancel) { dismiss() }
                Button("OK") {
                    let v = value.trimmingCharacters(in: .whitespacesAndNewlines)
                    guard !v.isEmpty else { return }
                    onConfirm(v)
                    dismiss()
                }
                .keyboardShortcut(.return, modifiers: [])
                .disabled(value.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
        .padding(24)
        .frame(width: 360)
    }
}
