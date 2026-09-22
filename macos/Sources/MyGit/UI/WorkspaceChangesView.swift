import SwiftUI

/// Changes tab for a workspace. One repo → the classic single-repo view. A
/// multi-repo workspace → a collapsible section per repo, each with its own
/// file list and inline commit composer (commit + AI message target that repo).
struct WorkspaceChangesView: View {
    @EnvironmentObject var coordinator: AppCoordinator

    var body: some View {
        if coordinator.bundles.count <= 1 {
            // Single repo: unchanged UX, driven by the active bundle in env.
            VStack(spacing: 0) {
                ChangesListView()
                Divider()
                CommitComposerView()
                    .padding(10)
            }
        } else {
            // List (NSTableView-backed) instead of ScrollView+VStack: rows are
            // materialised lazily. A plain stack builds every row of every repo
            // up front, which blows up SwiftUI's attribute graph (and aborts the
            // process) once a workspace has a few hundred changed files.
            List {
                ForEach(coordinator.bundles) { bundle in
                    RepoChangesSection(bundle: bundle)
                }
            }
            .listStyle(.inset)
            // Alerts/confirmation dialogs live outside the lazy rows so they
            // still present when their section is scrolled off-screen.
            .background {
                ForEach(coordinator.bundles) { bundle in
                    Color.clear.changesGitActionHost(bundle.changes)
                }
            }
        }
    }
}

/// One repo's changes inside a multi-repo workspace.
private struct RepoChangesSection: View {
    @EnvironmentObject var coordinator: AppCoordinator
    let bundle: RepoBundle
    @ObservedObject private var changesVM: ChangesViewModel
    @State private var expanded = true

    init(bundle: RepoBundle) {
        self.bundle = bundle
        self._changesVM = ObservedObject(wrappedValue: bundle.changes)
    }

    private var changes: [FileChange] { changesVM.status?.changes ?? [] }
    private var isActive: Bool { coordinator.activeBundle.id == bundle.id }

    var body: some View {
        Section(isExpanded: $expanded) {
            if changes.isEmpty {
                Text("No local changes")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 8)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .listRowSeparator(.hidden)
                    .listRowBackground(rowBackground)
            } else {
                ForEach(changes) { change in
                    ChangeRow(change: change)
                        .environmentObject(bundle.changes)
                        .environmentObject(bundle.editor)
                        .listRowSeparator(.hidden)
                        .listRowBackground(rowBackground)
                }
                CommitComposerView()
                    .environmentObject(bundle.changes)
                    .padding(10)
                    .listRowSeparator(.hidden)
                    .listRowBackground(rowBackground)
            }
        } header: {
            header
                .listRowInsets(EdgeInsets())
                .listRowBackground(rowBackground)
        }
        .onChange(of: changesVM.selectedChange) {
            coordinator.setActive(bundle)
        }
    }

    private var rowBackground: Color {
        isActive ? Color.accentColor.opacity(0.06) : Color.clear
    }

    private var header: some View {
        HStack(spacing: 8) {
            Button {
                withAnimation(.easeInOut(duration: 0.12)) { expanded.toggle() }
            } label: {
                Image(systemName: expanded ? "chevron.down" : "chevron.right")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .frame(width: 14)
            }
            .buttonStyle(.plain)

            Toggle(isOn: Binding(
                get: { !changes.isEmpty && changes.allSatisfy { changesVM.stagedPaths.contains($0.path) } },
                set: { changesVM.setAllStaged($0) }
            )) { EmptyView() }
            .toggleStyle(.checkbox)

            Image(systemName: "folder.fill").font(.system(size: 11)).foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 1) {
                Text(bundle.name)
                    .font(.system(size: 13, weight: .semibold))
                    .lineLimit(1)
                if let last = changesVM.lastCommit {
                    Text("\(last.shortHash) · \(last.subject)")
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }

            Text("\(changes.count)")
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(.secondary)
                .padding(.horizontal, 6)
                .padding(.vertical, 1)
                .background(Capsule().fill(Color.secondary.opacity(0.15)))

            Spacer()

            if changesVM.status?.operationInProgress == true, changesVM.status?.hasConflicts == true {
                Button {
                    Task {
                        let (ours, theirs) = await changesVM.mergeBranchNames()
                        ConflictsWindow.open(bundle: bundle, ours: ours, theirs: theirs)
                    }
                } label: {
                    Label("Resolve", systemImage: "exclamationmark.triangle.fill")
                        .font(.system(size: 11, weight: .medium))
                }
                .buttonStyle(.borderedProminent)
                .tint(.orange)
                .controlSize(.small)
                .help("Resolve merge conflicts")
            }

            if let branch = changesVM.status?.branch {
                Text(branch)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }

            Menu {
                ChangesGitMenu(bundle: bundle)
            } label: {
                Image(systemName: "ellipsis.circle")
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            .help("Git actions")
            Button {
                Task { await changesVM.refresh() }
            } label: {
                Image(systemName: "arrow.clockwise")
            }
            .buttonStyle(.borderless)
            .help("Refresh")
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .contentShape(Rectangle())
        .onTapGesture(count: 2) {
            withAnimation(.easeInOut(duration: 0.12)) { expanded.toggle() }
        }
        .onTapGesture { coordinator.setActive(bundle) }
        .contextMenu { ChangesGitMenu(bundle: bundle) }
    }
}
