import SwiftUI

/// History tab for a workspace. One repo → classic list. Multi-repo → a
/// collapsible section per repo. Selecting a commit makes that repo active so
/// the detail panel shows its commit.
struct WorkspaceHistoryView: View {
    @EnvironmentObject var coordinator: AppCoordinator

    var body: some View {
        if coordinator.bundles.count <= 1 {
            HistoryGraphPane()
        } else {
            ScrollView {
                LazyVStack(spacing: 0) {
                    ForEach(coordinator.bundles) { bundle in
                        RepoHistorySection(bundle: bundle)
                        Divider()
                    }
                }
            }
        }
    }
}

/// Single-repo history: 3-pane graph — refs sidebar | filter bar + commit
/// graph. The changed-files detail stays in the main DetailPanel.
struct HistoryGraphPane: View {
    @EnvironmentObject var history: HistoryViewModel
    @EnvironmentObject var branches: BranchesViewModel

    var body: some View {
        HSplitView {
            RefsSidebarView()
                .frame(minWidth: 170, idealWidth: 220, maxWidth: 320)
            VStack(spacing: 0) {
                HistoryFilterBar()
                Divider()
                CommitGraphList()
            }
            .frame(minWidth: 320)
        }
        .task { await branches.refresh() }
    }
}

private struct RepoHistorySection: View {
    @EnvironmentObject var coordinator: AppCoordinator
    let bundle: RepoBundle
    @ObservedObject private var historyVM: HistoryViewModel
    @State private var expanded = true

    init(bundle: RepoBundle) {
        self.bundle = bundle
        self._historyVM = ObservedObject(wrappedValue: bundle.history)
    }

    private var isActive: Bool { coordinator.activeBundle.id == bundle.id }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            RepoSectionHeader(
                name: bundle.name,
                branch: historyVM.selectedCommit?.shortHash,
                count: historyVM.commits.count,
                expanded: $expanded
            )
            if expanded {
                if historyVM.commits.isEmpty {
                    Text("No commits yet")
                        .font(.system(size: 12)).foregroundStyle(.secondary)
                        .padding(.horizontal, 16).padding(.vertical, 8)
                        .frame(maxWidth: .infinity, alignment: .leading)
                } else {
                    ForEach(historyVM.commits) { commit in
                        CommitRow(commit: commit)
                            .padding(.horizontal, 8)
                            .background(
                                RoundedRectangle(cornerRadius: 4).fill(
                                    historyVM.selectedCommit == commit ? Color.accentColor.opacity(0.25) : .clear
                                )
                            )
                            .onTapGesture {
                                coordinator.setActive(bundle)
                                historyVM.selectedCommit = commit
                            }
                            .padding(.horizontal, 6)
                    }
                    if historyVM.hasMore {
                        LoadMoreButton(isLoading: historyVM.isLoadingMore) {
                            await historyVM.loadMore()
                        }
                    }
                }
            }
        }
        .background(isActive ? Color.accentColor.opacity(0.06) : Color.clear)
    }
}

/// "Load more" affordance for paginated lists.
struct LoadMoreButton: View {
    let isLoading: Bool
    let action: () async -> Void

    var body: some View {
        Button {
            Task { await action() }
        } label: {
            HStack(spacing: 6) {
                if isLoading {
                    ProgressView().controlSize(.small)
                } else {
                    Image(systemName: "arrow.down.circle")
                }
                Text(isLoading ? "Loading…" : "Load more")
                    .font(.system(size: 12, weight: .medium))
            }
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 8)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(isLoading)
    }
}

/// Shared collapsible header for per-repo sections (History/Files).
struct RepoSectionHeader: View {
    let name: String
    let branch: String?
    let count: Int
    @Binding var expanded: Bool

    var body: some View {
        HStack(spacing: 8) {
            Button {
                withAnimation(.easeInOut(duration: 0.12)) { expanded.toggle() }
            } label: {
                Image(systemName: expanded ? "chevron.down" : "chevron.right")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(.secondary).frame(width: 14)
            }
            .buttonStyle(.plain)

            Image(systemName: "folder.fill").font(.system(size: 11)).foregroundStyle(.secondary)
            Text(name).font(.system(size: 13, weight: .semibold)).lineLimit(1)

            Text("\(count)")
                .font(.system(size: 11, weight: .medium)).foregroundStyle(.secondary)
                .padding(.horizontal, 6).padding(.vertical, 1)
                .background(Capsule().fill(Color.secondary.opacity(0.15)))

            Spacer()

            if let branch { Text(branch).font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(1) }
        }
        .padding(.horizontal, 12).padding(.vertical, 8)
        .contentShape(Rectangle())
        .onTapGesture(count: 2) {
            withAnimation(.easeInOut(duration: 0.12)) { expanded.toggle() }
        }
    }
}
