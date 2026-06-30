import SwiftUI

struct SidebarPanel: View {
    @EnvironmentObject var main: MainViewModel

    var body: some View {
        VStack(spacing: 0) {
            Picker("", selection: $main.tab) {
                Text("Changes").tag(MainViewModel.Tab.changes)
                Text("Stash").tag(MainViewModel.Tab.stash)
                Text("History").tag(MainViewModel.Tab.history)
                Text("Files").tag(MainViewModel.Tab.files)
            }
            .pickerStyle(.segmented)
            .padding(8)

            Divider()

            switch main.tab {
            case .changes:
                WorkspaceChangesView()
            case .stash:
                WorkspaceStashView()
            case .history:
                WorkspaceHistoryView()
            case .files:
                WorkspaceFilesView()
            }
        }
        .background(Color(NSColor.controlBackgroundColor))
    }
}
