import SwiftUI

struct EmptyStateView: View {
    @EnvironmentObject var repos: RepositoryListViewModel

    var body: some View {
        VStack(spacing: 16) {
            Image(systemName: "tray")
                .font(.system(size: 56))
                .foregroundStyle(.tertiary)
            Text("No repository selected")
                .font(.title2)
            Text("Add a local Git repository to begin.")
                .foregroundStyle(.secondary)
            Button("Add Local Repository…") { repos.pickRepository() }
                .keyboardShortcut("o", modifiers: .command)
                .controlSize(.large)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(NSColor.textBackgroundColor))
    }
}
