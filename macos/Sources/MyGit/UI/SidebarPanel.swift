import SwiftUI

struct SidebarPanel: View {
    @EnvironmentObject var main: MainViewModel
    @EnvironmentObject var coordinator: AppCoordinator

    /// PR tab only shows for GitHub/Bitbucket repos.
    private var showsPullRequests: Bool {
        PullRequestRouter.supports(host: coordinator.activeBundle.account.account?.host)
    }

    /// Ordered tabs shown in the rail. PR tab is appended only when supported.
    private var tabs: [SidebarTab] {
        var items: [SidebarTab] = [
            SidebarTab(tab: .changes, symbol: "square.and.pencil", title: "Changes"),
            SidebarTab(tab: .stash, symbol: "archivebox", title: "Stash"),
            SidebarTab(tab: .history, symbol: "clock.arrow.circlepath", title: "History"),
            SidebarTab(tab: .files, symbol: "folder", title: "Files"),
        ]
        if showsPullRequests {
            items.append(SidebarTab(tab: .pullRequests, symbol: "arrow.triangle.pull", title: "Pull Requests"))
        }
        return items
    }

    var body: some View {
        HStack(spacing: 0) {
            // Vertical icon rail (Android Studio tool-window bar style).
            VStack(spacing: 4) {
                ForEach(tabs) { item in
                    SidebarRailButton(
                        item: item,
                        isSelected: main.tab == item.tab
                    ) { main.tab = item.tab }
                }
                Spacer(minLength: 0)
            }
            .padding(.vertical, 8)
            .padding(.horizontal, 6)
            .frame(width: 56)
            .background(Color(NSColor.windowBackgroundColor))

            Divider()

            Group {
                switch main.tab {
                case .changes:
                    WorkspaceChangesView()
                case .stash:
                    WorkspaceStashView()
                case .history:
                    WorkspaceHistoryView()
                case .files:
                    WorkspaceFilesView()
                case .pullRequests:
                    WorkspacePullRequestsView()
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .background(Color(NSColor.controlBackgroundColor))
        // If the active repo can't do PRs but the PR tab is selected (e.g. after
        // switching repos), fall back to Changes so the rail/content stay valid.
        .onChange(of: coordinator.activeBundle.id) {
            if main.tab == .pullRequests, !showsPullRequests {
                main.tab = .changes
            }
        }
    }
}

private struct SidebarTab: Identifiable {
    let tab: MainViewModel.Tab
    let symbol: String
    let title: String
    var id: MainViewModel.Tab { tab }
}

private struct SidebarRailButton: View {
    let item: SidebarTab
    let isSelected: Bool
    let action: () -> Void

    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            Image(systemName: item.symbol)
                .font(.system(size: 18, weight: .regular))
                .frame(width: 44, height: 44)
                .foregroundStyle(isSelected ? Color.accentColor : Color.primary)
                .background(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .fill(background)
                )
                .contentShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .help(item.title)
        .accessibilityLabel(item.title)
    }

    private var background: Color {
        if isSelected {
            return Color.accentColor.opacity(0.15)
        }
        if hovering {
            return Color.primary.opacity(0.08)
        }
        return .clear
    }
}
