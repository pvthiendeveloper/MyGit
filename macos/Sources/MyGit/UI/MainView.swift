import SwiftUI

struct MainView: View {
    @EnvironmentObject var main: MainViewModel
    @EnvironmentObject var repos: RepositoryListViewModel
    @EnvironmentObject var remote: RemoteViewModel
    @State private var remoteURLInput: String = ""

    private var sidebarMinWidth: CGFloat {
        switch main.tab {
        case .history: return 520
        case .pullRequests: return 440
        default: return 280
        }
    }
    private var sidebarIdealWidth: CGFloat {
        switch main.tab {
        case .history: return 760
        case .pullRequests: return 640
        default: return 280
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            ToolbarBar()
                .padding(.trailing, 12)
                .background(Color(NSColor.windowBackgroundColor))
            Divider()

            if repos.selected == nil {
                EmptyStateView()
            } else {
                HSplitView {
                    SidebarPanel()
                        .frame(
                            minWidth: sidebarMinWidth,
                            idealWidth: sidebarIdealWidth,
                            maxWidth: main.tab == .history ? 1200 : (main.tab == .pullRequests ? 900 : 480)
                        )
                        .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { main.sidebarWidth = $0 }
                    DetailPanel()
                        .frame(minWidth: 420)
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
