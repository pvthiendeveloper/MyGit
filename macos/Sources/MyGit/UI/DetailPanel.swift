import SwiftUI

struct DetailPanel: View {
    @EnvironmentObject var main: MainViewModel
    @EnvironmentObject var changes: ChangesViewModel
    @EnvironmentObject var history: HistoryViewModel
    @EnvironmentObject var compareVM: CompareBranchesViewModel
    @EnvironmentObject var coordinator: AppCoordinator

    var body: some View {
        VStack(spacing: 0) {
            if main.comparePair != nil {
                detailTabBar
                Divider()
            }
            content
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(NSColor.textBackgroundColor))
    }

    // Tab bar shown only when compare is active
    private var detailTabBar: some View {
        HStack(spacing: 0) {
            detailTabButton(label: tabContentLabel, tab: .content)

            Divider().frame(height: 16).padding(.horizontal, 4)

            // Compare tab with close button
            HStack(spacing: 0) {
                Button { main.detailTab = .compare } label: {
                    Text("Compare")
                        .font(.system(size: 12, weight: main.detailTab == .compare ? .semibold : .regular))
                        .foregroundStyle(main.detailTab == .compare ? Color.accentColor : Color.primary)
                        .padding(.leading, 10)
                        .padding(.vertical, 5)
                }
                .buttonStyle(.plain)

                Button { main.closeCompare() } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 9, weight: .medium))
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 5)
                }
                .buttonStyle(.plain)
            }
            .background(main.detailTab == .compare ? Color.accentColor.opacity(0.15) : Color.clear)
            .clipShape(RoundedRectangle(cornerRadius: 6))

            Spacer()
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(Color(NSColor.windowBackgroundColor))
    }

    private func detailTabButton(label: String, tab: MainViewModel.DetailTab) -> some View {
        Button { main.detailTab = tab } label: {
            Text(label)
                .font(.system(size: 12, weight: main.detailTab == tab ? .semibold : .regular))
                .foregroundStyle(main.detailTab == tab ? Color.accentColor : Color.primary)
                .padding(.horizontal, 10)
                .padding(.vertical, 5)
                .background(main.detailTab == tab ? Color.accentColor.opacity(0.15) : Color.clear)
                .clipShape(RoundedRectangle(cornerRadius: 6))
        }
        .buttonStyle(.plain)
    }

    private var tabContentLabel: String {
        switch main.tab {
        case .changes: return "Diff"
        case .history: return "Commit"
        case .files:   return "Editor"
        }
    }

    @ViewBuilder
    private var content: some View {
        if main.detailTab == .compare, main.comparePair != nil {
            comparePane
        } else {
            normalContent
        }
    }

    @ViewBuilder
    private var normalContent: some View {
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

    @ViewBuilder
    private var comparePane: some View {
        if let pair = main.comparePair {
            HSplitView {
                // Left: two commit panels stacked
                VSplitView {
                    CompareCommitPanel(side: .aMinusB, vm: compareVM)
                        .frame(minHeight: 160)
                    CompareCommitPanel(side: .bMinusA, vm: compareVM)
                        .frame(minHeight: 120)
                }
                .frame(minWidth: 300, idealWidth: 420)

                // Right: file tree + commit detail
                VSplitView {
                    CompareChangedFilesTree(
                        nodes: ChangedFileTreeBuilder.build(from: compareVM.changedFiles),
                        onSelect: { compareVM.openFile($0) }
                    )
                    .frame(minHeight: 160)
                    .overlay {
                        if compareVM.isLoadingFiles {
                            ProgressView()
                                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
                        }
                    }

                    compareCommitDetail.frame(minHeight: 80)
                }
                .frame(minWidth: 200)
            }
            .task(id: pair.id) {
                compareVM.configure(
                    pair: pair,
                    git: coordinator.container.git,
                    repoSource: { [weak coordinator] in coordinator?.repos.selected?.url }
                )
                await compareVM.load()
            }
            .sheet(item: $compareVM.openFileDiff) { state in
                CompareFileDiffSheet(state: state)
            }
            .alert("Error", isPresented: Binding(
                get: { compareVM.errorMessage != nil },
                set: { if !$0 { compareVM.errorMessage = nil } }
            )) {
                Button("OK") { compareVM.errorMessage = nil }
            } message: {
                Text(compareVM.errorMessage ?? "")
            }
        }
    }

    @ViewBuilder
    private var compareCommitDetail: some View {
        let commit = compareVM.focused == .aMinusB ? compareVM.selectedAB : compareVM.selectedBA
        if let c = commit {
            ScrollView {
                VStack(alignment: .leading, spacing: 6) {
                    Text(c.subject).font(.system(size: 13, weight: .semibold))
                    if !c.body.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                        Text(c.body.trimmingCharacters(in: .whitespacesAndNewlines))
                            .font(.system(size: 12)).foregroundStyle(.secondary)
                    }
                    Divider()
                    HStack(spacing: 12) {
                        Label(c.author, systemImage: "person")
                        Label(c.shortHash, systemImage: "number")
                        Label(c.date.formatted(.dateTime.month().day().year()), systemImage: "calendar")
                    }
                    .font(.caption).foregroundStyle(.secondary)
                }
                .padding(12)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        } else {
            placeholder("No commit selected")
        }
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
