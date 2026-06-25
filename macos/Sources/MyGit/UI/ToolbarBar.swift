import SwiftUI

struct ToolbarBar: View {
    @EnvironmentObject var main: MainViewModel
    @EnvironmentObject var repos: RepositoryListViewModel
    @EnvironmentObject var changes: ChangesViewModel
    @EnvironmentObject var branches: BranchesViewModel
    @EnvironmentObject var remote: RemoteViewModel
    @State private var showBranchPopover = false
    @State private var showRepoPopover = false
    @State private var newBranchName = ""
    @State private var pendingNewBranch: PendingNewBranch? = nil
    @State private var hoveredRepo = false
    @State private var hoveredBranch = false
    @State private var hoveredFetch = false
    @State private var hoveredFetchChevron = false
    @State private var hoveredPublish = false
    @State private var hoveredAccount = false

    var body: some View {
        HStack(spacing: 0) {
            repoPicker
            branchButton
            if isUnpublished { publishButton } else { remoteActionButton }
            AccountBadge()
                .padding(.horizontal, 12)
                .frame(maxHeight: .infinity)
                .padding(.vertical, 8)
                .contentShape(Rectangle())
                .onHover { hoveredAccount = $0 }
                .background(hoveredAccount ? Color.primary.opacity(0.08) : .clear)
                .overlay(alignment: .trailing) {
                    Color(NSColor.separatorColor).frame(width: 1)
                }
            Spacer()
        }
        .fixedSize(horizontal: false, vertical: true)
        .sheet(isPresented: $branches.showNewBranchSheet) {
            TextInputSheet(
                title: "New Branch",
                prompt: "Branch name",
                placeholder: "my-branch",
                value: $newBranchName
            ) { name in
                guard let base = branches.branches.first(where: { $0.isCurrent }) ?? branches.branches.first else { return }
                let dirty = (changes.status?.changes.isEmpty == false)
                if dirty {
                    pendingNewBranch = PendingNewBranch(name: name, from: base)
                } else {
                    Task { await branches.createBranch(name: name, from: base) }
                }
            }
        }
        .alert(
            "Uncommitted changes",
            isPresented: Binding(
                get: { pendingNewBranch != nil },
                set: { if !$0 { pendingNewBranch = nil } }
            ),
            presenting: pendingNewBranch
        ) { p in
            Button("Bring Changes") {
                Task { await branches.createBranch(name: p.name, from: p.from) }
                pendingNewBranch = nil
            }
            Button("Stash, then Switch") {
                Task { await branches.stashAndCreateBranch(name: p.name, from: p.from) }
                pendingNewBranch = nil
            }
            Button("Cancel", role: .cancel) { pendingNewBranch = nil }
        } message: { p in
            Text("You have changes on '\(p.from.name)'. Bring them to '\(p.name)' or stash first?")
        }
        .sheet(item: Binding(
            get: { branches.diffResult.map { DiffResultWrapper(text: $0) } },
            set: { if $0 == nil { branches.diffResult = nil } }
        )) { r in
            ScrollView {
                Text(r.text)
                    .font(.system(.body, design: .monospaced))
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding()
            }
            .frame(width: 600, height: 400)
        }
    }

    private var branchButton: some View {
        Button {
            guard repos.selected != nil else { return }
            showBranchPopover.toggle()
        } label: {
            HStack(spacing: 8) {
                Image(systemName: "arrow.triangle.branch")
                    .font(.system(size: 16))
                VStack(alignment: .leading, spacing: 1) {
                    Text("Current Branch").font(.caption).foregroundStyle(.secondary)
                    Text(changes.status?.branch ?? "-")
                        .font(.system(size: 13, weight: .semibold))
                        .lineLimit(1)
                }
                .layoutPriority(1)
                Spacer(minLength: 4)
                DropdownBadge(isOpen: showBranchPopover)
            }
            .padding(.horizontal, 12)
            .frame(minWidth: 120, maxWidth: 220, maxHeight: .infinity)
            .padding(.vertical, 8)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hoveredBranch = $0 }
        .background(hoveredBranch ? Color.primary.opacity(0.08) : .clear)
        .overlay(alignment: .trailing) {
            Color(NSColor.separatorColor).frame(width: 1)
        }
        .disabled(repos.selected == nil)
        .popover(isPresented: $showBranchPopover, arrowEdge: .bottom) {
            BranchPopover()
                .environmentObject(main)
                .environmentObject(repos)
                .environmentObject(changes)
                .environmentObject(branches)
                .environmentObject(remote)
        }
    }

    private var repoPicker: some View {
        Button { showRepoPopover.toggle() } label: {
            HStack(spacing: 8) {
                Image(systemName: "rectangle.stack")
                    .font(.system(size: 16))
                VStack(alignment: .leading, spacing: 1) {
                    Text("Current Repository").font(.caption).foregroundStyle(.secondary)
                    Text(repos.selected?.name ?? "-")
                        .font(.system(size: 13, weight: .semibold))
                        .lineLimit(1)
                }
                .layoutPriority(1)
                Spacer(minLength: 4)
                DropdownBadge(isOpen: showRepoPopover)
            }
            .padding(.horizontal, 12)
            .frame(width: max(160, main.sidebarWidth))
            .frame(maxHeight: .infinity)
            .padding(.vertical, 8)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hoveredRepo = $0 }
        .background(hoveredRepo ? Color.primary.opacity(0.08) : .clear)
        .overlay(alignment: .trailing) {
            Color(NSColor.separatorColor).frame(width: 1)
        }
        .popover(isPresented: $showRepoPopover, arrowEdge: .bottom) {
            RepoPopover().environmentObject(repos)
        }
    }

    private var remoteActionButton: some View {
        HStack(spacing: 0) {
            Button(action: { Task { await runPrimaryRemoteAction() } }) {
                HStack(spacing: 8) {
                    primaryRemoteIcon
                    VStack(alignment: .leading, spacing: 1) {
                        HStack(spacing: 6) {
                            Text(primaryRemoteTitle)
                                .font(.system(size: 13, weight: .semibold))
                            if let badge = primaryRemoteBadge {
                                Text(badge)
                                    .font(.system(size: 11, weight: .semibold))
                                    .padding(.horizontal, 6)
                                    .padding(.vertical, 1)
                                    .background(Color.primary.opacity(0.12), in: Capsule())
                            }
                        }
                        Text(lastFetchLabel)
                            .font(.caption).foregroundStyle(.secondary)
                            .lineLimit(2)
                    }
                }
                .padding(.horizontal, 12)
                .frame(maxHeight: .infinity)
                .padding(.vertical, 8)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .onHover { hoveredFetch = $0 }
            .background(hoveredFetch ? Color.primary.opacity(0.08) : .clear)
            .disabled(repos.selected == nil || main.isBusy)

            Menu {
                Button {
                    Task { await remote.fetchOrigin() }
                } label: {
                    Label("Fetch origin", systemImage: "arrow.triangle.2.circlepath")
                }
                if let s = changes.status, s.behind > 0 {
                    Button {
                        Task { await remote.pull() }
                    } label: {
                        Label("Pull origin (\(s.behind))", systemImage: "arrow.down")
                    }
                }
                if let s = changes.status, s.ahead > 0 {
                    Button {
                        Task { await remote.push() }
                    } label: {
                        Label("Push origin (\(s.ahead))", systemImage: "arrow.up")
                    }
                }
            } label: {
                Image(systemName: "chevron.down")
                    .font(.caption)
                    .foregroundStyle(Color.secondary)
                    .frame(width: 24)
                    .frame(maxHeight: .infinity)
                    .contentShape(Rectangle())
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            .onHover { hoveredFetchChevron = $0 }
            .background(hoveredFetchChevron ? Color.primary.opacity(0.08) : .clear)
            .disabled(repos.selected == nil || main.isBusy)
        }
        .overlay(alignment: .trailing) {
            Color(NSColor.separatorColor).frame(width: 1)
        }
    }

    private var primaryRemoteTitle: String {
        if let s = changes.status, s.behind > 0 { return "Pull origin" }
        if let s = changes.status, s.ahead > 0 { return "Push origin" }
        return "Fetch origin"
    }

    private var primaryRemoteBadge: String? {
        if let s = changes.status, s.behind > 0 { return "\(s.behind) ↓" }
        if let s = changes.status, s.ahead > 0 { return "\(s.ahead) ↑" }
        return nil
    }

    @ViewBuilder
    private var primaryRemoteIcon: some View {
        if let s = changes.status, s.behind > 0 {
            Image(systemName: "arrow.down").font(.system(size: 16))
        } else if let s = changes.status, s.ahead > 0 {
            Image(systemName: "arrow.up").font(.system(size: 16))
        } else {
            SpinningFetchIcon(isBusy: main.isBusy)
        }
    }

    private func runPrimaryRemoteAction() async {
        if let s = changes.status, s.behind > 0 {
            await remote.pull()
            return
        }
        if let s = changes.status, s.ahead > 0 {
            await remote.push()
            return
        }
        await remote.fetchOrigin()
    }

    private var isUnpublished: Bool {
        guard repos.selected != nil,
              let b = changes.status?.branch, !b.isEmpty else { return false }
        return changes.status?.upstream == nil
    }

    private var publishButton: some View {
        Button {
            guard let b = changes.status?.branch else { return }
            Task { await remote.pushWithUpstream(branch: b) }
        } label: {
            HStack(spacing: 8) {
                Image(systemName: "square.and.arrow.up")
                    .font(.system(size: 16))
                VStack(alignment: .leading, spacing: 1) {
                    Text("Publish branch").font(.system(size: 13, weight: .semibold))
                    Text("Publish this branch to remote")
                        .font(.caption).foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
            .padding(.horizontal, 12)
            .frame(maxHeight: .infinity)
            .padding(.vertical, 8)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hoveredPublish = $0 }
        .background(hoveredPublish ? Color.primary.opacity(0.08) : .clear)
        .overlay(alignment: .trailing) {
            Color(NSColor.separatorColor).frame(width: 1)
        }
        .disabled(repos.selected == nil || main.isBusy)
    }

    private var lastFetchLabel: String {
        guard let d = remote.lastFetchedAt else { return "Never fetched this session" }
        let f = RelativeDateTimeFormatter()
        return "Last fetched " + f.localizedString(for: d, relativeTo: Date())
    }

}

private struct DiffResultWrapper: Identifiable {
    let id = UUID()
    let text: String
}

private struct PendingNewBranch: Identifiable {
    let id = UUID()
    let name: String
    let from: GitBranch
}

struct DropdownBadge: View {
    let isOpen: Bool
    var body: some View {
        Image(systemName: isOpen ? "chevron.up" : "chevron.down")
            .font(.caption2)
            .foregroundStyle(Color.secondary)
    }
}

private struct SpinningFetchIcon: View {
    let isBusy: Bool
    @State private var degrees: Double = 0

    var body: some View {
        Image(systemName: "arrow.triangle.2.circlepath")
            .font(.system(size: 16))
            .rotationEffect(.degrees(degrees))
            .task(id: isBusy) {
                if isBusy {
                    while !Task.isCancelled {
                        withAnimation(.linear(duration: 0.8)) { degrees += 360 }
                        try? await Task.sleep(nanoseconds: 800_000_000)
                    }
                } else {
                    let target = (degrees / 360).rounded(.up) * 360
                    withAnimation(.easeOut(duration: 0.25)) { degrees = target }
                }
            }
    }
}
