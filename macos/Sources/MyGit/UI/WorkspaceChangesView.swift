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
            ScrollView {
                VStack(spacing: 0) {
                    ForEach(coordinator.bundles) { bundle in
                        RepoChangesSection(bundle: bundle)
                        Divider()
                    }
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
        VStack(alignment: .leading, spacing: 0) {
            header
            if expanded {
                if changes.isEmpty {
                    Text("No local changes")
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 16)
                        .padding(.vertical, 8)
                        .frame(maxWidth: .infinity, alignment: .leading)
                } else {
                    ForEach(changes) { change in
                        ChangeRow(change: change)
                            .environmentObject(bundle.changes)
                            .environmentObject(bundle.editor)
                            .padding(.horizontal, 6)
                    }
                    CommitComposerView()
                        .environmentObject(bundle.changes)
                        .padding(10)
                }
            }
        }
        .background(isActive ? Color.accentColor.opacity(0.06) : Color.clear)
        .onChange(of: changesVM.selectedChange) {
            coordinator.setActive(bundle)
        }
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

            if let branch = changesVM.status?.branch {
                Text(branch)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .contentShape(Rectangle())
        .onTapGesture(count: 2) {
            withAnimation(.easeInOut(duration: 0.12)) { expanded.toggle() }
        }
        .onTapGesture { coordinator.setActive(bundle) }
    }
}
