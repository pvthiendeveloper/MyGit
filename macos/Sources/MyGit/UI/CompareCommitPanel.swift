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
                        ForEach(Array(commits.enumerated()), id: \.element.id) { index, commit in
                            CompareCommitRow(
                                commit: commit,
                                isFirst: index == 0,
                                isLast: index == commits.count - 1,
                                isSelected: localSelection == commit
                            )
                            .contentShape(Rectangle())
                            .onTapGesture {
                                localSelection = commit
                                vm.selectCommit(commit, side: side)
                            }
                        }
                    }
                }
            }
        }
    }
}

private struct CompareCommitRow: View {
    let commit: GitCommit
    let isFirst: Bool
    let isLast: Bool
    let isSelected: Bool

    private var isMerge: Bool { commit.parents.count > 1 }

    var body: some View {
        HStack(spacing: 8) {
            CommitGraphGutter(isFirst: isFirst, isLast: isLast)

            Text(commit.subject)
                .font(.system(size: 12, weight: isSelected ? .semibold : .regular))
                .lineLimit(1)
                .truncationMode(.tail)
                .foregroundStyle(isSelected ? .primary : .secondary)

            Spacer(minLength: 8)

            Text(commit.author + (isMerge ? "*" : ""))
                .font(.system(size: 11, weight: isSelected ? .semibold : .regular))
                .lineLimit(1)
                .foregroundStyle(isSelected ? .primary : .secondary)

            Text(dateText)
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .frame(width: 110, alignment: .trailing)
        }
        .padding(.trailing, 10)
        .frame(height: 30)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(isSelected ? Color.accentColor.opacity(0.18) : Color.clear)
    }

    private var dateText: String {
        commit.date.formatted(
            .dateTime.day(.twoDigits).month(.twoDigits).year(.twoDigits)
                .hour(.twoDigits(amPM: .omitted)).minute()
        )
    }
}

private struct CommitGraphGutter: View {
    let isFirst: Bool
    let isLast: Bool

    var body: some View {
        GeometryReader { geo in
            let midX = geo.size.width / 2
            let midY = geo.size.height / 2
            Path { p in
                p.move(to: CGPoint(x: midX, y: isFirst ? midY : 0))
                p.addLine(to: CGPoint(x: midX, y: isLast ? midY : geo.size.height))
            }
            .stroke(Color.secondary.opacity(0.5), lineWidth: 1.5)

            Circle()
                .fill(Color.purple)
                .frame(width: 9, height: 9)
                .position(x: midX, y: midY)
        }
        .frame(width: 22)
    }
}
