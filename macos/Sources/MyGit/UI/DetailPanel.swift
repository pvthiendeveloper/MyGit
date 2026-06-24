import SwiftUI

struct DetailPanel: View {
    @EnvironmentObject var main: MainViewModel
    @EnvironmentObject var changes: ChangesViewModel
    @EnvironmentObject var history: HistoryViewModel

    var body: some View {
        VStack(spacing: 0) {
            switch main.tab {
            case .changes:
                if changes.status?.changes.isEmpty ?? true {
                    NoLocalChangesView()
                } else if let diff = changes.diff {
                    DiffView(diff: diff)
                } else {
                    placeholder("Select a file to view its diff.")
                }
            case .history:
                if let commit = history.selectedCommit {
                    CommitDetailHeader(commit: commit)
                    Divider()
                    if let diff = history.diff {
                        DiffView(diff: diff)
                    } else {
                        placeholder("Loading commit…")
                    }
                } else {
                    placeholder("Select a commit to see its diff.")
                }
            case .files:
                FileEditorView()
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(NSColor.textBackgroundColor))
    }

    private func placeholder(_ text: String) -> some View {
        VStack {
            Spacer()
            Text(text).foregroundStyle(.secondary)
            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

struct NoLocalChangesView: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("No local changes")
                .font(.system(size: 28, weight: .semibold))
            Text("There are no uncommitted changes in this repository.")
                .foregroundStyle(.secondary)
            Spacer()
        }
        .padding(36)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }
}

struct CommitDetailHeader: View {
    let commit: GitCommit

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(commit.subject)
                .font(.system(size: 15, weight: .semibold))
            if !commit.body.isEmpty {
                Text(commit.body)
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
            }
            HStack(spacing: 8) {
                Text(commit.author).font(.system(size: 12, weight: .medium))
                Text(commit.email).font(.system(size: 11)).foregroundStyle(.secondary)
                Spacer()
                Text(commit.shortHash).font(.system(.caption, design: .monospaced))
                Text(commit.date, format: .dateTime).font(.caption).foregroundStyle(.secondary)
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}
