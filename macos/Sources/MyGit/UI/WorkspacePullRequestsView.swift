import SwiftUI

/// Pull Requests tab. Single repo → that repo's PR list. Multi-repo workspace →
/// one collapsible section per repo; selecting a PR activates that repo so the
/// detail panel shows it.
struct WorkspacePullRequestsView: View {
    @EnvironmentObject var coordinator: AppCoordinator

    var body: some View {
        if coordinator.bundles.count <= 1 {
            SingleRepoPRList(bundle: coordinator.activeBundle)
                .id(coordinator.activeBundle.id)
        } else {
            VStack(spacing: 0) {
                SectionActionBar(namespace: "pr", ids: coordinator.bundles.map { $0.id.absoluteString })
                Divider()
                ScrollView {
                    VStack(spacing: 0) {
                        ForEach(coordinator.bundles) { bundle in
                            RepoPRSection(bundle: bundle) {
                                coordinator.setActive(bundle)
                            }
                            Divider()
                        }
                    }
                }
            }
        }
    }
}

/// Single-repo PR list. Observes the account so the refresh task re-fires once
/// account coordinates resolve on cold launch.
private struct SingleRepoPRList: View {
    let bundle: RepoBundle
    @ObservedObject private var vm: PullRequestsViewModel
    @ObservedObject private var account: AccountViewModel

    init(bundle: RepoBundle) {
        self.bundle = bundle
        self.vm = bundle.pullRequests
        self.account = bundle.account
    }

    var body: some View {
        PullRequestListView(vm: vm)
            .task(id: prTaskID(bundle: bundle, account: account)) { await vm.refresh() }
    }
}

/// One repo's collapsible PR section: a header (chevron + folder + name + count)
/// and, when expanded, its PR list.
private struct RepoPRSection: View {
    let bundle: RepoBundle
    let onSelect: () -> Void

    @ObservedObject private var vm: PullRequestsViewModel
    @ObservedObject private var account: AccountViewModel
    @ObservedObject private var store = SectionCollapseStore.shared

    init(bundle: RepoBundle, onSelect: @escaping () -> Void) {
        self.bundle = bundle
        self.onSelect = onSelect
        self.vm = bundle.pullRequests
        self.account = bundle.account
    }

    private var expanded: Bool { store.isExpanded("pr", bundle.id.absoluteString) }
    // Re-run refresh once the account resolves (host/owner/repo populate async on
    // cold launch), otherwise the first .task sees no coordinates and stays empty.
    private var taskID: String { prTaskID(bundle: bundle, account: account) }

    var body: some View {
        VStack(spacing: 0) {
            Button {
                withAnimation(.easeInOut(duration: 0.15)) { store.set("pr", bundle.id.absoluteString, !expanded) }
            } label: {
                HStack(spacing: 8) {
                    Image(systemName: "chevron.down")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(.secondary)
                        .rotationEffect(.degrees(expanded ? 0 : -90))
                    Image(systemName: "folder")
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                    Text(bundle.name)
                        .font(.system(size: 13, weight: .semibold))
                    if !vm.loaded.isEmpty {
                        Text("\(vm.loaded.count)")
                            .font(.system(size: 11, weight: .medium))
                            .foregroundStyle(.secondary)
                            .padding(.horizontal, 7)
                            .padding(.vertical, 2)
                            .background(Capsule().fill(Color.primary.opacity(0.1)))
                    }
                    Spacer(minLength: 0)
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            if expanded {
                PullRequestListView(vm: vm, onSelect: onSelect)
                    .frame(height: 360)
            }
        }
        .task(id: taskID) { await vm.refresh() }
    }
}

/// Stable-until-account-resolves identity for a PR refresh task. Includes the
/// account coordinates so the `.task` re-fires when they populate on cold launch.
@MainActor
private func prTaskID(bundle: RepoBundle, account: AccountViewModel) -> String {
    let acc = account.account
    return [bundle.id.absoluteString, acc?.host, acc?.owner, acc?.repo]
        .map { $0 ?? "" }
        .joined(separator: "|")
}
