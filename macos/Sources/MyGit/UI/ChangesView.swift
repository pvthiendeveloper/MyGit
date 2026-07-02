import AppKit
import SwiftUI

struct ChangesListView: View {
    @EnvironmentObject var vm: ChangesViewModel
    @EnvironmentObject var editor: FileEditorViewModel
    @EnvironmentObject var main: MainViewModel
    @EnvironmentObject var coordinator: AppCoordinator

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
        .onReceive(vm.$jumpToSourcePath) { path in
            guard let path else { return }
            editor.openFile(path: path)
            main.tab = .files
            DispatchQueue.main.async { vm.jumpToSourcePath = nil }
        }
        .changesGitActionHost(vm)
        .pullRequestActionHost(coordinator.activeBundle)
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
            Menu {
                ChangesGitMenu(bundle: coordinator.activeBundle)
            } label: {
                Image(systemName: "ellipsis.circle")
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            .help("Git actions")
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
        .contentShape(Rectangle())
        .contextMenu { ChangesGitMenu(bundle: coordinator.activeBundle) }
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
        .onTapGesture(count: 2) { showDiff() }
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

        Button("Show Diff") { showDiff() }
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

    private func showDiff() {
        vm.selectedChange = change
        main.openDiffTab(
            commitHash: "HEAD",
            commitShortHash: "HEAD",
            path: change.path,
            mode: .commitVsWorking,
            forceNew: false
        )
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
