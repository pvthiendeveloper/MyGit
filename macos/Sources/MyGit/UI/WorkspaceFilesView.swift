import SwiftUI

/// Files tab for a workspace. One repo → classic tree. Multi-repo → a
/// collapsible section per repo, each embedding that repo's file tree.
struct WorkspaceFilesView: View {
    @EnvironmentObject var coordinator: AppCoordinator

    var body: some View {
        if coordinator.bundles.count <= 1 {
            FilesView()
        } else {
            VStack(spacing: 0) {
                SectionActionBar(namespace: "files", ids: coordinator.bundles.map { $0.id.absoluteString })
                Divider()
                ScrollView {
                    LazyVStack(spacing: 0) {
                        ForEach(coordinator.bundles) { bundle in
                            RepoFilesSection(bundle: bundle)
                            Divider()
                        }
                    }
                }
            }
        }
    }
}

private struct RepoFilesSection: View {
    @EnvironmentObject var coordinator: AppCoordinator
    let bundle: RepoBundle
    @ObservedObject private var filesVM: FilesViewModel
    @ObservedObject private var store = SectionCollapseStore.shared

    init(bundle: RepoBundle) {
        self.bundle = bundle
        self._filesVM = ObservedObject(wrappedValue: bundle.files)
    }

    private var isActive: Bool { coordinator.activeBundle.id == bundle.id }
    private var expanded: Bool { store.isExpanded("files", bundle.id.absoluteString) }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            RepoSectionHeader(
                name: bundle.name,
                branch: nil,
                count: filesVM.fileTreeNodes.count,
                expanded: store.binding("files", bundle.id.absoluteString)
            )
            if expanded {
                FilesView()
                    .environmentObject(bundle.files)
                    .environmentObject(bundle.editor)
                    .frame(minHeight: 160, maxHeight: 340)
                    .simultaneousGesture(TapGesture().onEnded { coordinator.setActive(bundle) })
            }
        }
        .background(isActive ? Color.accentColor.opacity(0.06) : Color.clear)
    }
}
