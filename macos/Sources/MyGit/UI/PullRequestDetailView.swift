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
                        case .showDiff, .showDiffInNewTab: openDiff(for: entry.path)
                        default: break   // local-repo actions don't apply to a remote PR
                        }
                    },
                    menuActions: [.showDiff]
                )
            }
        }
        .task(id: vm.selected) { await vm.loadFiles() }
    }

    /// Open the file's PR patch as a read-only diff tab (or the PR page in the
    /// browser when no textual diff is available, e.g. a binary file).
    private func openDiff(for path: String) {
        guard let pr = vm.selected,
              let file = vm.files.first(where: { $0.path == path }) else { return }
        let patch = file.patch ?? ""
        if patch.isEmpty {
            vm.openInBrowser(pr)
            return
        }
        let diff = GitDiffParser.parse(patch, path: file.path)
        main.openPatchTab(
            key: "pr:\(pr.number):\(file.path)",
            title: URL(fileURLWithPath: file.path).lastPathComponent,
            diff: diff
        )
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
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        ForEach(vm.commits) { c in
                            HStack(alignment: .top, spacing: 10) {
                                Text(c.shortHash)
                                    .font(.system(size: 11, design: .monospaced))
                                    .foregroundStyle(.secondary)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(c.subject).font(.system(size: 12)).lineLimit(2)
                                    Text("\(c.author) · \(PRDate.relativeLabel(c.date))")
                                        .font(.system(size: 10)).foregroundStyle(.secondary)
                                }
                                Spacer()
                            }
                            .padding(.horizontal, 16).padding(.vertical, 6)
                            Divider()
                        }
                    }
                }
            }
        }
        .task(id: vm.selected) { await vm.loadCommits() }
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
