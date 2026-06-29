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
            ScrollView {
                LazyVStack(spacing: 0) {
                    ForEach(vm.commits) { commit in
                        CommitRow(commit: commit)
                            .padding(.horizontal, 8)
                            .background(
                                RoundedRectangle(cornerRadius: 4).fill(
                                    vm.selectedCommit == commit ? Color.accentColor.opacity(0.25) : .clear
                                )
                            )
                            .onTapGesture { vm.selectedCommit = commit }
                            .padding(.horizontal, 6)
                    }
                    if vm.hasMore {
                        LoadMoreButton(isLoading: vm.isLoadingMore) {
                            await vm.loadMore()
                        }
                    }
                }
                .padding(.vertical, 4)
            }
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
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(Rectangle())
    }
}
