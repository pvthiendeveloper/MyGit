import SwiftUI

struct SidebarPanel: View {
    @EnvironmentObject var main: MainViewModel

    var body: some View {
        VStack(spacing: 0) {
            Picker("", selection: $main.tab) {
                Text("Changes").tag(MainViewModel.Tab.changes)
                Text("History").tag(MainViewModel.Tab.history)
                Text("Files").tag(MainViewModel.Tab.files)
            }
            .pickerStyle(.segmented)
            .padding(8)

            Divider()

            switch main.tab {
            case .changes:
                VStack(spacing: 0) {
                    ChangesListView()
                    Divider()
                    CommitComposerView()
                        .padding(10)
                }
            case .history:
                HistoryListView()
            case .files:
                FilesView()
            }
        }
        .background(Color(NSColor.controlBackgroundColor))
    }
}
