import SwiftUI

struct HistoryListView: View {
    @EnvironmentObject var vm: HistoryViewModel

    var body: some View {
        if vm.commits.isEmpty {
            Text("No commits yet")
                .foregroundStyle(.secondary)
                .padding(20)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
        } else {
            List(selection: $vm.selectedCommit) {
                ForEach(vm.commits) { commit in
                    CommitRow(commit: commit)
                        .tag(commit as GitCommit?)
                }
            }
            .listStyle(.inset)
        }
    }
}

struct CommitRow: View {
    let commit: GitCommit

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(commit.subject)
                .font(.system(size: 12, weight: .medium))
                .lineLimit(2)
            HStack(spacing: 6) {
                Text(commit.author)
                Text("·")
                Text(commit.shortHash).font(.system(.caption, design: .monospaced))
                Text("·")
                Text(commit.date, format: .relative(presentation: .named))
            }
            .font(.caption)
            .foregroundStyle(.secondary)
        }
        .padding(.vertical, 4)
        .contentShape(Rectangle())
    }
}
