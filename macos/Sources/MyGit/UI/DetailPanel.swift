import SwiftUI

struct DetailPanel: View {
    @EnvironmentObject var main: MainViewModel
    @EnvironmentObject var changes: ChangesViewModel
    @EnvironmentObject var history: HistoryViewModel
    @EnvironmentObject var compareVM: CompareBranchesViewModel
    @EnvironmentObject var editor: FileEditorViewModel
    @EnvironmentObject var pullRequests: PullRequestsViewModel
    @EnvironmentObject var coordinator: AppCoordinator

    private var hasDetailTabs: Bool {
        main.comparePair != nil || !main.diffTabs.isEmpty
            || !editor.openFileTabs.isEmpty || !main.patchTabs.isEmpty
    }

    var body: some View {
        VStack(spacing: 0) {
            if hasDetailTabs {
                detailTabBar
                Divider()
            }
            content
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(NSColor.textBackgroundColor))
    }

    // Tab bar shown when compare or any diff tab is active
    private var detailTabBar: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 0) {
                detailTabButton(label: tabContentLabel, tab: .content)

                if main.comparePair != nil {
                    Divider().frame(height: 16).padding(.horizontal, 4)
                    compareTabChip
                }

                ForEach(main.diffTabs) { tab in
                    Divider().frame(height: 16).padding(.horizontal, 4)
                    diffTabChip(tab)
                }

                ForEach(editor.openFileTabs) { tab in
                    Divider().frame(height: 16).padding(.horizontal, 4)
                    EditorTabChip(tab: tab)
                }

                ForEach(main.patchTabs) { tab in
                    Divider().frame(height: 16).padding(.horizontal, 4)
                    patchTabChip(tab)
                }

                Spacer(minLength: 0)
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
        }
        .background(Color(NSColor.windowBackgroundColor))
    }

    private var compareTabChip: some View {
        let isActive = main.detailTab == .compare
        return HStack(spacing: 0) {
            Button { main.detailTab = .compare } label: {
                Text("Compare")
                    .font(.system(size: 12, weight: isActive ? .semibold : .regular))
                    .foregroundStyle(isActive ? Color.accentColor : Color.primary)
                    .padding(.leading, 10)
                    .padding(.vertical, 5)
            }
            .buttonStyle(.plain)

            Button { main.closeCompare() } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 9, weight: .medium))
                    .foregroundStyle(.secondary)
                    .frame(width: 24, height: 24)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
        }
        .background(isActive ? Color.accentColor.opacity(0.15) : Color.clear)
        .clipShape(RoundedRectangle(cornerRadius: 6))
        .contextMenu {
            Button("Close") { main.closeCompare() }
        }
    }

    private func patchTabChip(_ tab: MainViewModel.PatchTab) -> some View {
        let isActive: Bool = {
            if case let .patch(id) = main.detailTab { return id == tab.id }
            return false
        }()
        return HStack(spacing: 0) {
            Button { main.detailTab = .patch(tab.id) } label: {
                HStack(spacing: 4) {
                    Image(systemName: "arrow.triangle.pull")
                        .font(.system(size: 10))
                        .foregroundStyle(isActive ? Color.accentColor : .secondary)
                    Text(tab.title)
                        .font(.system(size: 12, weight: isActive ? .semibold : .regular))
                        .foregroundStyle(isActive ? Color.accentColor : Color.primary)
                        .lineLimit(1)
                }
                .padding(.leading, 10)
                .padding(.vertical, 5)
            }
            .buttonStyle(.plain)
            .help(tab.key)

            Button { main.closePatchTab(tab.id) } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 9, weight: .medium))
                    .foregroundStyle(.secondary)
                    .frame(width: 24, height: 24)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
        }
        .background(isActive ? Color.accentColor.opacity(0.15) : Color.clear)
        .clipShape(RoundedRectangle(cornerRadius: 6))
        .contextMenu { Button("Close") { main.closePatchTab(tab.id) } }
    }

    private func diffTabChip(_ tab: DiffTab) -> some View {
        let isActive: Bool = {
            if case let .diff(id) = main.detailTab { return id == tab.id }
            return false
        }()
        return HStack(spacing: 0) {
            Button { main.selectDiffTab(tab.id) } label: {
                HStack(spacing: 4) {
                    Image(systemName: "doc.text")
                        .font(.system(size: 10))
                        .foregroundStyle(isActive ? Color.accentColor : .secondary)
                    Text(tab.title)
                        .font(.system(size: 12, weight: isActive ? .semibold : .regular))
                        .foregroundStyle(isActive ? Color.accentColor : Color.primary)
                        .lineLimit(1)
                }
                .padding(.leading, 10)
                .padding(.vertical, 5)
            }
            .buttonStyle(.plain)
            .help(tab.path)

            Button { main.closeDiffTab(tab.id) } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 9, weight: .medium))
                    .foregroundStyle(.secondary)
                    .frame(width: 24, height: 24)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
        }
        .background(isActive ? Color.accentColor.opacity(0.15) : Color.clear)
        .clipShape(RoundedRectangle(cornerRadius: 6))
        .contextMenu { diffTabMenu(tab) }
    }

    @ViewBuilder
    private func diffTabMenu(_ tab: DiffTab) -> some View {
        Button("Close") { main.closeDiffTab(tab.id) }
        Button("Close Others") { main.closeOtherDiffTabs(keep: tab.id) }
            .disabled(main.diffTabs.count < 2)
        Button("Close All") { main.closeAllDiffTabs() }

        Divider()

        Button("Copy Full Path") {
            if let abs = absolutePath(tab.path) { FileActions.copyToPasteboard(abs) }
        }
        Button("Copy Relative Path") { FileActions.copyToPasteboard(tab.path) }
        if tab.mode != .commitVsParent {
            Button("Reveal in Finder") {
                if let abs = absolutePath(tab.path) { FileActions.reveal(absPath: abs) }
            }
            Button("Open in Default App") {
                if let abs = absolutePath(tab.path) { FileActions.openDefault(absPath: abs) }
            }
        }

        Divider()

        Button("Reopen Closed Tab") { main.reopenClosedDiffTab() }
            .disabled(!main.hasClosedDiffTabs)
    }

    private func absolutePath(_ relative: String) -> String? {
        coordinator.activeBundle.repo.url.appendingPathComponent(relative).path
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
        case .stash:   return "Diff"
        case .history: return "Commit"
        case .files:   return "Editor"
        case .pullRequests: return "Pull Request"
        }
    }

    @ViewBuilder
    private var content: some View {
        switch main.detailTab {
        case .compare:
            if main.comparePair != nil { comparePane } else { normalContent }
        case .diff(let id):
            if let tab = main.diffTabs.first(where: { $0.id == id }) {
                SideBySideDiffTabView(tab: tab)
            } else {
                normalContent
            }
        case .editor(let id):
            if let tab = editor.openFileTabs.first(where: { $0.id == id }) {
                FileEditorContent(tab: tab)
            } else {
                normalContent
            }
        case .patch(let id):
            if let tab = main.patchTabs.first(where: { $0.id == id }) {
                DiffView(diff: tab.diff)
            } else {
                normalContent
            }
        case .content:
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
        case .stash:
            placeholder("Expand a stash and pick a file to view its diff.")
        case .history:
            if let commit = history.selectedCommit {
                CommitDetailHeader(commit: commit)
                Divider()
                CompareChangedFilesTree(
                    nodes: ChangedFileTreeBuilder.build(from: history.changedFiles),
                    onAction: { entry, action in history.perform(action, on: entry) }
                )
                .overlay {
                    if history.isLoadingFiles {
                        ProgressView()
                            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
                    }
                }
            } else {
                placeholder("Select a commit to see its diff.")
            }
        case .files:
            FileEditorView()
        case .pullRequests:
            if pullRequests.selected != nil {
                PullRequestDetailView(vm: pullRequests)
            } else {
                placeholder("Select a pull request to see its details.")
            }
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
                        onAction: { entry, action in compareVM.perform(action, on: entry) }
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
                    repoSource: { [weak coordinator] in coordinator?.activeBundle.repo.url },
                    openDiffTab: { [weak main] commitHash, commitShortHash, path, mode, forceNew in
                        main?.openDiffTab(
                            commitHash: commitHash,
                            commitShortHash: commitShortHash,
                            path: path,
                            mode: mode,
                            forceNew: forceNew
                        )
                    }
                )
                await compareVM.load()
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

/// A chip in the unified detail tab bar representing an open editor file tab.
/// Kept as its own view so `@ObservedObject` tracks the tab's dirty/name state.
private struct EditorTabChip: View {
    @ObservedObject var tab: OpenFileTab
    @EnvironmentObject var main: MainViewModel
    @EnvironmentObject var editor: FileEditorViewModel

    private var isActive: Bool {
        if case let .editor(id) = main.detailTab { return id == tab.id }
        return false
    }

    var body: some View {
        HStack(spacing: 0) {
            Button { editor.selectFileTab(id: tab.id) } label: {
                HStack(spacing: 4) {
                    Image(systemName: "doc")
                        .font(.system(size: 10))
                        .foregroundStyle(isActive ? Color.accentColor : .secondary)
                    Text(tab.name)
                        .font(.system(size: 12, weight: isActive ? .semibold : .regular))
                        .foregroundStyle(isActive ? Color.accentColor : Color.primary)
                        .lineLimit(1)
                    if tab.isDirty {
                        Circle().fill(Color.accentColor).frame(width: 6, height: 6)
                    }
                }
                .padding(.leading, 10)
                .padding(.vertical, 5)
            }
            .buttonStyle(.plain)
            .help(tab.path)

            Button { editor.closeFileTab(id: tab.id) } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 9, weight: .medium))
                    .foregroundStyle(.secondary)
                    .frame(width: 24, height: 24)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
        }
        .background(isActive ? Color.accentColor.opacity(0.15) : Color.clear)
        .clipShape(RoundedRectangle(cornerRadius: 6))
        .contextMenu { contextMenu }
    }

    @ViewBuilder
    private var contextMenu: some View {
        Button("Close") { editor.closeFileTab(id: tab.id) }
        Button("Close Others") { editor.closeOtherFileTabs(keep: tab.id) }
            .disabled(editor.openFileTabs.count < 2)
        Button("Close All") { editor.closeAllFileTabs() }
        Button("Close Saved") { editor.closeSavedFileTabs() }
            .disabled(!editor.openFileTabs.contains { !$0.isDirty })

        Divider()

        Button("Copy Full Path") {
            if let abs = editor.absolutePath(for: tab) { FileActions.copyToPasteboard(abs) }
        }
        Button("Copy Relative Path") { FileActions.copyToPasteboard(tab.path) }
        Button("Reveal in Finder") {
            if let abs = editor.absolutePath(for: tab) { FileActions.reveal(absPath: abs) }
        }
        Button("Open in Default App") {
            if let abs = editor.absolutePath(for: tab) { FileActions.openDefault(absPath: abs) }
        }
        Button("Open in Terminal") {
            if let abs = editor.absolutePath(for: tab) {
                FileActions.openTerminal(dir: (abs as NSString).deletingLastPathComponent)
            }
        }

        Divider()

        Button("Reopen Closed Tab") { editor.reopenClosedTab() }
            .disabled(editor.closedPaths.isEmpty)

        Divider()

        Menu("Git") {
            Button("Show Diff in New Tab") { editor.showDiffInNewTab(for: tab) }
        }
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
