import SwiftUI

/// Stash tab. Single repo → that repo's stash panel. Multi-repo workspace → one
/// collapsible-free section per repo, each with its own stash list and composer.
struct WorkspaceStashView: View {
    @EnvironmentObject var coordinator: AppCoordinator

    var body: some View {
        if coordinator.bundles.count <= 1 {
            StashPanelView(vm: coordinator.activeBundle.stash)
                .padding(10)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
                .task(id: coordinator.activeBundle.id) {
                    await coordinator.activeBundle.stash.refreshList()
                }
        } else {
            ScrollView {
                VStack(spacing: 0) {
                    ForEach(coordinator.bundles) { bundle in
                        Text(bundle.name)
                            .font(.system(size: 13, weight: .semibold))
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.horizontal, 12)
                            .padding(.top, 10)
                        StashPanelView(vm: bundle.stash)
                            .padding(10)
                        Divider()
                    }
                }
            }
        }
    }
}
