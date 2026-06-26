import AppKit
import SwiftUI

struct ChangesListView: View {
    @EnvironmentObject var vm: ChangesViewModel
    @EnvironmentObject var editor: FileEditorViewModel
    @EnvironmentObject var main: MainViewModel

    private var changes: [FileChange] { vm.status?.changes ?? [] }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            if changes.isEmpty {
                ScrollView { Text("No local changes")
                    .foregroundStyle(.secondary)
                    .padding(20)
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
            } else {
                List(selection: $vm.selectedChange) {
                    ForEach(changes) { change in
                        ChangeRow(change: change)
                            .tag(change as FileChange?)
                    }
                }
                .listStyle(.inset)
            }
        }
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
        .onReceive(vm.$jumpToSourcePath) { path in
            guard let path else { return }
            editor.openFile(path: path)
            main.tab = .files
            DispatchQueue.main.async { vm.jumpToSourcePath = nil }
        }
    }

    private var header: some View {
        HStack(spacing: 8) {
            Toggle(isOn: Binding(
                get: { !changes.isEmpty && changes.allSatisfy { vm.stagedPaths.contains($0.path) } },
                set: { vm.setAllStaged($0) }
            )) { EmptyView() }
            .toggleStyle(.checkbox)

            Text("\(changes.count) changed file\(changes.count == 1 ? "" : "s")")
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(.secondary)
            Spacer()
            Button {
                Task { await vm.refresh() }
            } label: {
                Image(systemName: "arrow.clockwise")
            }
            .buttonStyle(.borderless)
            .help("Refresh")
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }
}

struct ChangeRow: View {
    @EnvironmentObject var vm: ChangesViewModel
    @EnvironmentObject var main: MainViewModel
    let change: FileChange

    private var isSelected: Bool { vm.selectedChange == change }

    var body: some View {
        HStack(spacing: 8) {
            Toggle(isOn: Binding(
                get: { vm.stagedPaths.contains(change.path) },
                set: { _ in vm.toggleStaged(change) }
            )) { EmptyView() }
            .toggleStyle(.checkbox)

            Text(change.path)
                .font(.system(size: 12))
                .foregroundStyle(isSelected ? Color.white : Color.primary)
                .lineLimit(1)
                .truncationMode(.middle)

            Spacer(minLength: 4)

            Text(change.glyph)
                .font(.system(size: 11, weight: .bold, design: .monospaced))
                .foregroundStyle(isSelected ? Color.white : colorForKind(change.kind))
                .frame(width: 16, alignment: .trailing)
        }
        .padding(.horizontal, 6)
        .padding(.vertical, 3)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 4)
                .fill(isSelected ? Color.accentColor : Color.clear)
        )
        .contentShape(Rectangle())
        .onTapGesture { vm.selectedChange = change }
        .contextMenu { contextMenu }
    }

    @ViewBuilder
    private var contextMenu: some View {
        Button("Commit File…") {
            Task { await vm.commitFile(change) }
        }
        Button("Rollback…") {
            vm.requestRollback(change)
        }
        .keyboardShortcut("z", modifiers: [.command, .option])

        Divider()

        Button("Show Diff") {
            vm.selectedChange = change
            main.openDiffTab(
                commitHash: "HEAD",
                commitShortHash: "HEAD",
                path: change.path,
                mode: .commitVsWorking,
                forceNew: false
            )
        }
        .keyboardShortcut("d", modifiers: .command)
        Button("Show Diff in a New Tab") {
            main.openDiffTab(
                commitHash: "HEAD",
                commitShortHash: "HEAD",
                path: change.path,
                mode: .commitVsWorking,
                forceNew: true
            )
        }
        Button("Jump to Source") {
            vm.jumpToSource(change)
        }

        Divider()

        Button("Delete…") {
            vm.requestDelete(change)
        }
        if change.isUntracked {
            Button("Add to VCS") {
                Task { await vm.addToVCS(change) }
            }
            .keyboardShortcut("a", modifiers: [.command, .option])
        }

        Divider()

        Button("Create Patch from Local Changes…") {
            createPatch()
        }
        Button("Copy as Patch to Clipboard") {
            Task { await vm.copyPatch(change) }
        }

        Divider()

        Button("Refresh") {
            Task { await vm.refresh() }
        }
    }

    private func createPatch() {
        let panel = NSSavePanel()
        panel.allowedContentTypes = []
        panel.nameFieldStringValue = patchFilename()
        panel.canCreateDirectories = true
        panel.title = "Save Patch"
        if panel.runModal() == .OK, let url = panel.url {
            let captured = change
            Task { await vm.createPatch(captured, to: url) }
        }
    }

    private func patchFilename() -> String {
        let leaf = change.path.split(separator: "/").last.map(String.init) ?? change.path
        return leaf + ".patch"
    }

    private func colorForKind(_ k: FileChangeKind) -> Color {
        switch k {
        case .added, .untracked: return .green
        case .deleted: return .red
        case .modified: return .yellow
        case .renamed, .copied: return .blue
        case .conflict: return .orange
        }
    }
}
