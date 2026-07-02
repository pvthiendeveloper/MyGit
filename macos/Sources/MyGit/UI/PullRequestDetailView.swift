import SwiftUI

/// PR detail with three sub-tabs: Overview, Files changed, Commits.
struct PullRequestDetailView: View {
    @ObservedObject var vm: PullRequestsViewModel
    @EnvironmentObject var main: MainViewModel

    var body: some View {
        if let pr = vm.selected {
            VStack(alignment: .leading, spacing: 0) {
                header(pr)
                Divider()
                subTabBar
                Divider()
                switch vm.detailTab {
                case .overview: overview
                case .files:    filesTab
                case .commits:  commitsTab
                }
            }
        } else {
            Text("Select a pull request.")
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    // MARK: - Header + sub-tab bar

    private func header(_ pr: PullRequestSummary) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                chip(pr.sourceBranch)
                Image(systemName: "arrow.right").font(.system(size: 10)).foregroundStyle(.secondary)
                chip(pr.destBranch)
                StateBadge(state: pr.state)
                Spacer()
                Button { vm.openInBrowser(pr) } label: {
                    Label("Open in browser", systemImage: "arrow.up.right.square")
                }
                .buttonStyle(.link)
            }
            Text(pr.title).font(.title3).bold()
            Text("#\(pr.number) · \(pr.authorName) · updated \(PRDate.relativeLabel(pr.updatedAt))")
                .font(.caption).foregroundStyle(.secondary)
        }
        .padding(20)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var subTabBar: some View {
        HStack(spacing: 4) {
            tab("Overview", .overview)
            tab("Files changed", .files, count: vm.filesLoaded ? vm.files.count : nil)
            tab("Commits", .commits, count: vm.commitsLoaded ? vm.commits.count : nil)
            Spacer()
        }
        .padding(.horizontal, 16).padding(.vertical, 6)
    }

    private func tab(_ title: String, _ value: PullRequestsViewModel.DetailTab, count: Int? = nil) -> some View {
        let active = vm.detailTab == value
        return Button {
            vm.detailTab = value
        } label: {
            HStack(spacing: 5) {
                Text(title)
                    .font(.system(size: 12, weight: active ? .semibold : .regular))
                    .foregroundStyle(active ? Color.accentColor : Color.primary)
                if let count {
                    Text("\(count)")
                        .font(.system(size: 10, weight: .medium))
                        .padding(.horizontal, 5).padding(.vertical, 1)
                        .background(Capsule().fill(Color.secondary.opacity(0.2)))
                }
            }
            .padding(.horizontal, 8).padding(.vertical, 4)
            .background(active ? Color.accentColor.opacity(0.15) : Color.clear)
            .clipShape(RoundedRectangle(cornerRadius: 6))
        }
        .buttonStyle(.plain)
    }

    // MARK: - Overview

    private var overview: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                if vm.detailLoading && vm.detail == nil {
                    ProgressView().frame(maxWidth: .infinity).padding(.vertical, 20)
                } else if let detail = vm.detail {
                    overviewBody(detail)
                }
                Spacer(minLength: 0)
            }
            .padding(20)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    @ViewBuilder
    private func overviewBody(_ detail: PullRequestDetail) -> some View {
        if let created = detail.createdAt {
            Text("Created \(PRDate.relativeLabel(created))" + (detail.closedBy.map { " · closed by \($0)" } ?? ""))
                .font(.caption).foregroundStyle(.secondary)
        }

        section("Description") {
            Text(detail.description.isEmpty ? "No description." : detail.description)
                .font(.system(size: 12))
                .foregroundStyle(detail.description.isEmpty ? .secondary : .primary)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
        }

        if let checks = detail.checks {
            section("Checks") {
                HStack(spacing: 16) {
                    checkStat("Checks", checks.passed, checks.total)
                    if checks.buildsTotal > 0 {
                        checkStat("Builds", checks.buildsPassed, checks.buildsTotal)
                    }
                }
            }
        }

        let reviewers = detail.reviewers
        if !reviewers.isEmpty {
            section("Reviewers (\(reviewers.count)) · \(detail.approvals) approved") {
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(reviewers, id: \.name) { r in
                        HStack(spacing: 8) {
                            reviewerAvatar(r.avatarURL)
                            Text(r.name).font(.system(size: 12))
                            Spacer()
                            Image(systemName: r.approved ? "checkmark.circle.fill" : "circle")
                                .foregroundStyle(r.approved ? .green : .secondary)
                        }
                    }
                }
            }
        }
    }

    // MARK: - Files changed

    private var filesTab: some View {
        Group {
            if vm.filesLoading && vm.files.isEmpty {
                ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if vm.files.isEmpty {
                Text("No file changes.").foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                CompareChangedFilesTree(
                    nodes: ChangedFileTreeBuilder.build(from: vm.files.map(Self.toEntry)),
                    onAction: { entry, action in
                        switch action {
                        case .showDiff: openFileDiff(for: entry.path, forceNew: false)
                        case .showDiffInNewTab: openFileDiff(for: entry.path, forceNew: true)
                        default: break   // local-repo actions don't apply to a remote PR
                        }
                    },
                    menuActions: [.showDiff, .showDiffInNewTab]
                )
            }
        }
        .task(id: vm.selected) { await vm.loadFiles() }
    }

    private func openFileDiff(for path: String, forceNew: Bool) {
        guard let pr = vm.selected,
              let file = vm.files.first(where: { $0.path == path }) else { return }
        openDiff(file: file, dedupKey: "pr:\(pr.number):\(file.path)",
                 leftLabel: pr.destBranch, rightLabel: pr.sourceBranch, forceNew: forceNew)
    }

    /// Open a file's patch in the side-by-side diff viewer (same as commit
    /// diffs), reconstructing both sides from the patch. Falls back to the PR
    /// page in the browser when no textual diff is available (e.g. a binary file).
    private func openDiff(file: PRFileChange, dedupKey: String,
                          leftLabel: String, rightLabel: String, forceNew: Bool) {
        let patch = file.patch ?? ""
        if patch.isEmpty {
            if let pr = vm.selected { vm.openInBrowser(pr) }
            return
        }
        let diff = GitDiffParser.parse(patch, path: file.path)
        let tab = DiffTab.patchBacked(
            dedupKey: dedupKey,
            path: file.path,
            leftLabel: leftLabel,
            rightLabel: rightLabel,
            diff: diff
        )
        main.openPatchDiffTab(tab, forceNew: forceNew)
    }

    /// Map a PR file change into the presentational tree's entry model.
    private static func toEntry(_ f: PRFileChange) -> ChangedFileEntry {
        let status: ChangedFileStatus
        switch f.status {
        case .added:    status = .added
        case .modified: status = .modified
        case .removed:  status = .deleted
        case .renamed:  status = .renamed
        }
        return ChangedFileEntry(
            path: f.path,
            oldPath: f.status == .renamed ? f.oldPath : nil,
            status: status
        )
    }

    // MARK: - Commits

    private var commitsTab: some View {
        Group {
            if vm.commitsLoading && vm.commits.isEmpty {
                ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if vm.commits.isEmpty {
                Text("No commits.").foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if vm.selectedCommit != nil {
                HStack(spacing: 0) {
                    commitsList.frame(maxWidth: .infinity, maxHeight: .infinity)
                    Divider()
                    commitDetailPane.frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            } else {
                commitsList.frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .task(id: vm.selected) { await vm.loadCommits() }
    }

    private var commitsList: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 0) {
                ForEach(vm.commits) { c in
                    let selected = vm.selectedCommit?.id == c.id
                    HStack(alignment: .top, spacing: 10) {
                        Text(c.shortHash)
                            .font(.system(size: 11, design: .monospaced))
                            .foregroundStyle(.secondary)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(c.subject)
                                .font(.system(size: 12))
                                .lineLimit(1).truncationMode(.tail)
                            Text("\(c.author) · \(PRDate.relativeLabel(c.date))")
                                .font(.system(size: 10)).foregroundStyle(.secondary)
                                .lineLimit(1).truncationMode(.tail)
                        }
                        Spacer(minLength: 0)
                    }
                    .padding(.horizontal, 12).padding(.vertical, 6)
                    .background(selected ? Color.accentColor.opacity(0.15) : Color.clear)
                    .contentShape(Rectangle())
                    .onTapGesture { vm.selectCommit(c) }
                    Divider()
                }
            }
        }
    }

    /// Right pane: the selected commit's header + changed-files tree (same view
    /// a commit shows in Compare). Clicking a file opens its diff.
    @ViewBuilder
    private var commitDetailPane: some View {
        if let c = vm.selectedCommit {
            VStack(alignment: .leading, spacing: 0) {
                CommitDetailHeader(commit: Self.gitCommit(from: c))
                Divider()
                if vm.commitFilesLoading && vm.commitFiles.isEmpty {
                    ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
                } else if vm.commitFiles.isEmpty {
                    Text("No file changes.").font(.system(size: 12)).foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    CompareChangedFilesTree(
                        nodes: ChangedFileTreeBuilder.build(from: vm.commitFiles.map(Self.toEntry)),
                        onAction: { entry, action in
                            switch action {
                            case .showDiff: openCommitFileDiff(for: entry.path, forceNew: false)
                            case .showDiffInNewTab: openCommitFileDiff(for: entry.path, forceNew: true)
                            default: break
                            }
                        },
                        menuActions: [.showDiff, .showDiffInNewTab]
                    )
                }
            }
        } else {
            Text("Select a commit to see its changes.")
                .font(.system(size: 12)).foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private func openCommitFileDiff(for path: String, forceNew: Bool) {
        guard let pr = vm.selected, let c = vm.selectedCommit,
              let file = vm.commitFiles.first(where: { $0.path == path }) else { return }
        openDiff(file: file, dedupKey: "pr:\(pr.number):commit:\(c.id):\(file.path)",
                 leftLabel: "\(c.shortHash)^", rightLabel: c.shortHash, forceNew: forceNew)
    }

    /// Bridge a PR commit into the `GitCommit` the shared header expects.
    private static func gitCommit(from c: PRCommit) -> GitCommit {
        GitCommit(
            id: c.id, author: c.author, email: "", date: c.date ?? Date(),
            parents: [], subject: c.subject,
            body: c.message.contains("\n")
                ? String(c.message.drop(while: { $0 != "\n" }).dropFirst()).trimmingCharacters(in: .whitespacesAndNewlines)
                : "",
            refs: []
        )
    }

    // MARK: - Shared bits

    private func checkStat(_ label: String, _ passed: Int, _ total: Int) -> some View {
        let ok = passed == total
        return HStack(spacing: 5) {
            Image(systemName: ok ? "checkmark.circle.fill" : "exclamationmark.circle.fill")
                .foregroundStyle(ok ? .green : .orange)
            Text("\(label): \(passed)/\(total) passed").font(.system(size: 12))
        }
    }

    private func section<Content: View>(_ title: String, @ViewBuilder _ content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title).font(.system(size: 13, weight: .semibold))
            content()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func chip(_ name: String) -> some View {
        Text(name)
            .font(.system(size: 11, design: .monospaced))
            .lineLimit(1).truncationMode(.middle)
            .padding(.horizontal, 7).padding(.vertical, 2)
            .background(Capsule().fill(Color.secondary.opacity(0.15)))
    }

    private func reviewerAvatar(_ url: URL?) -> some View {
        AsyncImage(url: url) { phase in
            if case .success(let img) = phase {
                img.resizable().interpolation(.high)
            } else {
                Image(systemName: "person.crop.circle.fill").resizable().foregroundStyle(.secondary)
            }
        }
        .frame(width: 20, height: 20).clipShape(Circle())
    }
}
