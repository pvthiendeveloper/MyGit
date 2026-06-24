import SwiftUI

struct MainView: View {
    @EnvironmentObject var main: MainViewModel
    @EnvironmentObject var repos: RepositoryListViewModel
    @EnvironmentObject var remote: RemoteViewModel
    @State private var remoteURLInput: String = ""

    var body: some View {
        VStack(spacing: 0) {
            ToolbarBar()
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .background(Color(NSColor.windowBackgroundColor))
            Divider()

            if repos.selected == nil {
                EmptyStateView()
            } else {
                HSplitView {
                    SidebarPanel()
                        .frame(minWidth: 280, idealWidth: 340, maxWidth: 480)
                    DetailPanel()
                        .frame(minWidth: 480)
                }
            }
        }
        .alert(
            "Error",
            isPresented: Binding(
                get: { main.errorMessage != nil },
                set: { if !$0 { main.errorMessage = nil } }
            ),
            actions: { Button("OK") { main.errorMessage = nil } },
            message: { Text(main.errorMessage ?? "") }
        )
        .alert(
            "No Upstream Branch",
            isPresented: Binding(
                get: { remote.noUpstreamBranch != nil },
                set: { if !$0 { remote.noUpstreamBranch = nil } }
            ),
            actions: {
                Button("Cancel", role: .cancel) { remote.noUpstreamBranch = nil }
                Button("Publish Branch") {
                    if let branch = remote.noUpstreamBranch {
                        remote.noUpstreamBranch = nil
                        Task { await remote.pushWithUpstream(branch: branch) }
                    }
                }
            },
            message: {
                if let branch = remote.noUpstreamBranch {
                    Text("Branch '\(branch)' has no upstream. Publish it to origin/\(branch)?")
                }
            }
        )
        .sheet(isPresented: Binding(
            get: { remote.missingRemoteForBranch != nil },
            set: { if !$0 { remote.missingRemoteForBranch = nil } }
        )) {
            TextInputSheet(
                title: "Add Remote Origin",
                prompt: "Remote URL",
                placeholder: "https://github.com/user/repo.git",
                value: $remoteURLInput
            ) { url in
                if let branch = remote.missingRemoteForBranch {
                    remote.missingRemoteForBranch = nil
                    remoteURLInput = ""
                    Task { await remote.addOriginAndPush(url: url, branch: branch) }
                }
            }
        }
    }
}
