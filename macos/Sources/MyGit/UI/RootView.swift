import SwiftUI

/// Injects the active repo bundle's ViewModels into the environment so the
/// existing single-repo views (toolbar, detail panel, History/Files/...) keep
/// working against the active repo. Re-evaluates whenever the active bundle
/// changes. The Changes tab separately iterates every bundle for its sections.
struct RootView: View {
    @EnvironmentObject var coordinator: AppCoordinator

    var body: some View {
        let bundle = coordinator.activeBundle
        MainView()
            .environmentObject(coordinator.main)
            .environmentObject(coordinator.repos)
            .environmentObject(coordinator.settings)
            .environmentObject(bundle.changes)
            .environmentObject(bundle.history)
            .environmentObject(bundle.files)
            .environmentObject(bundle.editor)
            .environmentObject(bundle.branches)
            .environmentObject(bundle.account)
            .environmentObject(bundle.remote)
            .environmentObject(bundle.pullRequests)
            .environmentObject(bundle.compareVM)
    }
}
