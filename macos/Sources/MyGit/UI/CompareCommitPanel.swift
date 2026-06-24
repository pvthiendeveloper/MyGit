import SwiftUI

struct CompareCommitPanel: View {
    let side: CompareSide
    @ObservedObject var vm: CompareBranchesViewModel
    @State private var localSelection: GitCommit?

    private var commits: [GitCommit] { side == .aMinusB ? vm.filteredAB : vm.filteredBA }
    private var filter: Binding<CompareFilter> {
        side == .aMinusB ? $vm.filterAB : $vm.filterBA
    }
    private var authors: [String] { side == .aMinusB ? vm.authorsAB : vm.authorsBA }

    private var bannerText: String {
        side == .aMinusB
            ? "Commits that exist in \(vm.pair.a) but don't exist in \(vm.pair.b)"
            : "Commits that exist in \(vm.pair.b) but don't exist in \(vm.pair.a)"
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 6) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(.yellow)
                    .font(.caption)
                Text(bannerText)
                    .font(.system(size: 11, weight: .medium))
                    .lineLimit(1)
                Spacer()
                Text("\(commits.count)")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(Color(NSColor.windowBackgroundColor).opacity(0.85))

            Divider()

            CompareFilterBar(filter: filter, authors: authors)

            Divider()

            if commits.isEmpty {
                Text("No commits")
                    .foregroundStyle(.secondary)
                    .font(.caption)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
            } else {
                ScrollView {
                    LazyVStack(spacing: 0) {
                        ForEach(commits) { commit in
                            CommitRow(commit: commit)
                                .padding(.horizontal, 8)
                                .background(localSelection == commit
                                    ? Color.accentColor.opacity(0.15)
                                    : Color.clear)
                                .contentShape(Rectangle())
                                .onTapGesture {
                                    localSelection = commit
                                    vm.selectCommit(commit, side: side)
                                }
                            Divider().padding(.leading, 8)
                        }
                    }
                }
            }
        }
    }
}
