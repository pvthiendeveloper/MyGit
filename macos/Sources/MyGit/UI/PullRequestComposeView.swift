import AppKit
import SwiftUI

/// Right-panel "Create Pull Request" composer. Mirrors `PullRequestDetailView`'s
/// layout: a header, then Overview / Files changed / Commits sub-tabs. Overview
/// holds the editable Title / Description / Reviewers; the other two tabs preview
/// the local diff between the base branch and the current branch (`base...head`),
/// computed with git — the PR doesn't exist yet, so there's no API to read.
struct PullRequestComposeView: View {
    let bundle: RepoBundle
    @EnvironmentObject var main: MainViewModel

    private enum Tab: Hashable { case overview, files, commits }

    @State private var title = ""
    @State private var desc = ""
    @State private var base = ""
    @State private var reviewers = ""
    @State private var tab: Tab = .overview

    @State private var loadingBase = true
    @State private var submitting = false
    @State private var generatingTitle = false
    @State private var generatingDesc = false
    @State private var showBasePicker = false
    @State private var baseSearch = ""

    @State private var files: [ChangedFileEntry] = []
    @State private var commits: [GitCommit] = []
    @State private var loadingDiff = false

    private let git: GitRepository = GitCLIRepository()

    private var head: String { bundle.remote.pullRequestHead ?? "" }
    private var repoURL: URL? { bundle.repo.url }
    private var reviewerTokens: [String] {
        reviewers.split(whereSeparator: { $0 == "," || $0 == " " || $0 == "\n" })
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
    }
    private var canSubmit: Bool {
        !title.trimmingCharacters(in: .whitespaces).isEmpty
            && !base.trimmingCharacters(in: .whitespaces).isEmpty
            && !head.isEmpty
            && !submitting
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider()
            subTabBar
            Divider()
            switch tab {
            case .overview: overview
            case .files:    filesTab
            case .commits:  commitsTab
            }
        }
        .task { await prefill() }
    }

    // MARK: - Header

    private var header: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                chip(head.isEmpty ? "?" : head)
                Image(systemName: "arrow.right").font(.system(size: 10)).foregroundStyle(.secondary)
                if loadingBase {
                    ProgressView().controlSize(.small)
                } else {
                    basePicker
                }
                Spacer()
                Button { bundle.pullRequests.isComposing = false } label: {
                    Label("Cancel", systemImage: "xmark")
                }
                .buttonStyle(.link)
            }
            Text("Create Pull Request").font(.title3).bold()
            Text(head.isEmpty ? "No current branch to open a PR from."
                              : "New pull request from \(head)")
                .font(.caption).foregroundStyle(.secondary)
        }
        .padding(20)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var subTabBar: some View {
        HStack(spacing: 4) {
            tabButton("Overview", .overview)
            tabButton("Files changed", .files, count: files.isEmpty ? nil : files.count)
            tabButton("Commits", .commits, count: commits.isEmpty ? nil : commits.count)
            Spacer()
        }
        .padding(.horizontal, 16).padding(.vertical, 6)
    }

    private func tabButton(_ label: String, _ value: Tab, count: Int? = nil) -> some View {
        let active = tab == value
        return Button { tab = value } label: {
            HStack(spacing: 5) {
                Text(label)
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

    // MARK: - Overview (editable form)

    private var overview: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                section("Title") {
                    HStack(spacing: 6) {
                        TextField("Pull request title", text: $title)
                            .textFieldStyle(.plain)
                        aiButton(generating: generatingTitle) { generate(applyTitle: true, applyDesc: false) }
                    }
                    .padding(.horizontal, 8).padding(.vertical, 6)
                    .background(fieldBorder)
                }
                section("Description") {
                    TextEditor(text: $desc)
                        .font(.system(size: 12))
                        .frame(height: 160)
                        .overlay(RoundedRectangle(cornerRadius: 4).stroke(Color.secondary.opacity(0.3)))
                        .overlay(alignment: .topTrailing) {
                            aiButton(generating: generatingDesc) { generate(applyTitle: false, applyDesc: true) }
                                .padding(6)
                        }
                }
                section("Reviewers") {
                    VStack(alignment: .leading, spacing: 4) {
                        TextField("usernames, comma-separated", text: $reviewers)
                            .textFieldStyle(.roundedBorder)
                        Text("GitHub: usernames · Bitbucket: account UUIDs `{…}`. Best-effort — a bad name won't block the PR.")
                            .font(.system(size: 10)).foregroundStyle(.secondary)
                    }
                }
                HStack {
                    Spacer()
                    Button("Cancel") { bundle.pullRequests.isComposing = false }
                    Button(submitting ? "Creating…" : "Create Pull Request") { submit() }
                        .buttonStyle(.borderedProminent)
                        .keyboardShortcut(.return, modifiers: [.command])
                        .disabled(!canSubmit)
                }
            }
            .padding(20)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    // MARK: - Files changed (local base...head)

    private var filesTab: some View {
        Group {
            if loadingDiff && files.isEmpty {
                ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if files.isEmpty {
                Text("No file changes between \(base) and \(head).")
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                CompareChangedFilesTree(
                    nodes: ChangedFileTreeBuilder.build(from: files),
                    onAction: { entry, action in
                        switch action {
                        case .showDiff:         openFileDiff(entry.path, forceNew: false)
                        case .showDiffInNewTab: openFileDiff(entry.path, forceNew: true)
                        default: break
                        }
                    },
                    menuActions: [.showDiff, .showDiffInNewTab]
                )
            }
        }
    }

    // MARK: - Commits (local base..head)

    private var commitsTab: some View {
        Group {
            if loadingDiff && commits.isEmpty {
                ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if commits.isEmpty {
                Text("No commits between \(base) and \(head).")
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        ForEach(commits) { c in
                            HStack(alignment: .top, spacing: 10) {
                                Text(c.shortHash)
                                    .font(.system(size: 11, design: .monospaced))
                                    .foregroundStyle(.secondary)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(c.subject).font(.system(size: 12)).lineLimit(1)
                                    Text("\(c.author) · \(PRDate.relativeLabel(c.date))")
                                        .font(.system(size: 10)).foregroundStyle(.secondary).lineLimit(1)
                                }
                                Spacer(minLength: 0)
                            }
                            .padding(.horizontal, 12).padding(.vertical, 6)
                            Divider()
                        }
                    }
                }
            }
        }
    }

    // MARK: - Base branch picker (searchable dropdown)

    /// Candidate base branches: every local/remote branch (remote prefix stripped
    /// and de-duplicated) except the head branch itself.
    private var baseCandidates: [String] {
        var seen = Set<String>()
        var out: [String] = []
        for b in bundle.branches.branches {
            let n = b.checkoutName
            guard !n.isEmpty, n != head, seen.insert(n).inserted else { continue }
            out.append(n)
        }
        return out.sorted()
    }

    private var filteredBase: [String] {
        let q = baseSearch.trimmingCharacters(in: .whitespaces).lowercased()
        return q.isEmpty ? baseCandidates : baseCandidates.filter { $0.lowercased().contains(q) }
    }

    private var basePicker: some View {
        Button { showBasePicker = true } label: {
            HStack(spacing: 4) {
                Text(base.isEmpty ? "base" : base)
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(base.isEmpty ? .secondary : .primary)
                    .lineLimit(1).truncationMode(.middle)
                Spacer(minLength: 0)
                Image(systemName: "chevron.down").font(.system(size: 9)).foregroundStyle(.secondary)
            }
            .padding(.horizontal, 8).padding(.vertical, 4)
            .frame(width: 220)
            .background(RoundedRectangle(cornerRadius: 6).fill(Color(NSColor.textBackgroundColor)))
            .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(Color.secondary.opacity(0.3)))
        }
        .buttonStyle(.plain)
        .popover(isPresented: $showBasePicker, arrowEdge: .bottom) { basePickerPopover }
    }

    private var basePickerPopover: some View {
        VStack(spacing: 0) {
            HStack(spacing: 4) {
                Image(systemName: "magnifyingglass").font(.system(size: 11)).foregroundStyle(.secondary)
                TextField("Search branch", text: $baseSearch)
                    .textFieldStyle(.plain).font(.system(size: 12))
            }
            .padding(8)
            Divider()
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    ForEach(filteredBase, id: \.self) { baseRow($0, isCustom: false) }
                    let q = baseSearch.trimmingCharacters(in: .whitespaces)
                    if !q.isEmpty && !baseCandidates.contains(q) {
                        baseRow(q, isCustom: true)
                    } else if filteredBase.isEmpty {
                        Text("No branches.").font(.system(size: 11))
                            .foregroundStyle(.secondary).padding(8)
                    }
                }
            }
            .frame(maxHeight: 260)
        }
        .frame(width: 280)
    }

    private func baseRow(_ name: String, isCustom: Bool) -> some View {
        Button {
            base = name
            showBasePicker = false
            baseSearch = ""
            Task { await loadDiff() }
        } label: {
            HStack(spacing: 6) {
                Image(systemName: isCustom ? "pencil" : "arrow.triangle.branch")
                    .font(.system(size: 10)).foregroundStyle(.secondary)
                Text(isCustom ? "Use “\(name)”" : name)
                    .font(.system(size: 12, design: .monospaced))
                    .lineLimit(1).truncationMode(.middle)
                Spacer(minLength: 0)
                if name == base {
                    Image(systemName: "checkmark").font(.system(size: 10)).foregroundStyle(Color.accentColor)
                }
            }
            .padding(.horizontal, 10).padding(.vertical, 5)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    // MARK: - Actions

    private func prefill() async {
        if bundle.branches.branches.isEmpty { await bundle.branches.refresh() }
        if title.isEmpty { title = bundle.changes.lastCommit?.subject ?? head }
        if let def = await bundle.remote.defaultBaseBranch() {
            base = def
        } else if base.isEmpty {
            base = "main"
        }
        loadingBase = false
        await loadDiff()
    }

    private func loadDiff() async {
        let b = base.trimmingCharacters(in: .whitespaces)
        guard let repoURL, !b.isEmpty, !head.isEmpty else { files = []; commits = []; return }
        loadingDiff = true
        defer { loadingDiff = false }
        async let f = try? git.changedFiles(range: "\(b)...\(head)", at: repoURL)
        async let c = try? git.commitsInRange("\(b)..\(head)", at: repoURL)
        files = await f ?? []
        commits = await c ?? []
    }

    private func openFileDiff(_ path: String, forceNew: Bool) {
        let b = base.trimmingCharacters(in: .whitespaces)
        guard let repoURL, !b.isEmpty else { return }
        Task {
            let patch = (try? await git.rangeFilePatch(range: "\(b)...\(head)", path: path, at: repoURL)) ?? ""
            guard !patch.isEmpty else { return }
            let diff = GitDiffParser.parse(patch, path: path)
            let dtab = DiffTab.patchBacked(
                dedupKey: "prcompose:\(b):\(head):\(path)",
                path: path,
                leftLabel: b,
                rightLabel: head,
                diff: diff
            )
            main.openPatchDiffTab(dtab, forceNew: forceNew)
        }
    }

    /// Generate title and/or description from the branch diff. The AI call
    /// returns both fields; each field's button applies only its own so they
    /// generate independently.
    private func generate(applyTitle: Bool, applyDesc: Bool) {
        let b = base.trimmingCharacters(in: .whitespaces)
        guard !b.isEmpty, !head.isEmpty else { return }
        if applyTitle { generatingTitle = true }
        if applyDesc { generatingDesc = true }
        Task {
            let suggestion = await bundle.changes.generatePullRequestText(base: b, head: head)
            generatingTitle = false
            generatingDesc = false
            guard let suggestion else { return }   // error surfaced via main.errorMessage
            if applyTitle, !suggestion.summary.isEmpty { title = suggestion.summary }
            if applyDesc, !suggestion.body.isEmpty { desc = suggestion.body }
        }
    }

    private func submit() {
        submitting = true
        Task {
            let url = await bundle.remote.createPullRequest(
                title: title.trimmingCharacters(in: .whitespacesAndNewlines),
                body: desc,
                base: base.trimmingCharacters(in: .whitespacesAndNewlines),
                reviewers: reviewerTokens
            )
            submitting = false
            guard url != nil else { return }   // error surfaced via main.errorMessage
            // Refresh the list, then select the just-created PR (newest one from
            // this branch). Selecting it exits compose and shows its detail.
            await bundle.pullRequests.refresh()
            if let created = bundle.pullRequests.loaded.first(where: { $0.sourceBranch == head }) {
                bundle.pullRequests.selected = created
            } else {
                bundle.pullRequests.isComposing = false
            }
        }
    }

    // MARK: - Bits

    private func section<Content: View>(_ title: String, @ViewBuilder _ content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title).font(.system(size: 13, weight: .semibold))
            content()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// Compact in-field "Generate with AI" button (sparkles / spinner while busy).
    private func aiButton(generating: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            if generating {
                ProgressView().controlSize(.small)
            } else {
                Image(systemName: "sparkles").font(.system(size: 12))
            }
        }
        .buttonStyle(.plain)
        .foregroundStyle(.tint)
        .help("Generate with AI from the branch diff")
        .disabled(generating || base.trimmingCharacters(in: .whitespaces).isEmpty || head.isEmpty)
    }

    private var fieldBorder: some View {
        RoundedRectangle(cornerRadius: 6)
            .fill(Color(nsColor: .textBackgroundColor))
            .overlay(RoundedRectangle(cornerRadius: 6).stroke(Color.secondary.opacity(0.3)))
    }

    private func chip(_ name: String) -> some View {
        Text(name)
            .font(.system(size: 11, design: .monospaced))
            .lineLimit(1).truncationMode(.middle)
            .padding(.horizontal, 7).padding(.vertical, 2)
            .background(Capsule().fill(Color.secondary.opacity(0.15)))
    }
}
