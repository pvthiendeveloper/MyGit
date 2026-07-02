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
            .environmentObject(coordinator.search)
            .environmentObject(bundle.changes)
            .environmentObject(bundle.history)
            .environmentObject(bundle.files)
            .environmentObject(bundle.editor)
            .environmentObject(bundle.branches)
            .environmentObject(bundle.account)
            .environmentObject(bundle.remote)
            .environmentObject(bundle.pullRequests)
            .environmentObject(bundle.compareVM)
            .overlay {
                // Observe the search VM directly — RootView only observes the
                // coordinator, so a nested VM change wouldn't re-render otherwise.
                SearchEverywhereHost(search: coordinator.search)
                    .environmentObject(coordinator)
                    .environmentObject(coordinator.search)
            }
    }
}

/// Renders the Search Everywhere overlay when presented. Exists so the `search`
/// VM is `@ObservedObject`-observed (RootView only watches the coordinator).
private struct SearchEverywhereHost: View {
    @ObservedObject var search: SearchEverywhereViewModel

    var body: some View {
        if search.isPresented {
            SearchEverywhereView()
        }
    }
}
