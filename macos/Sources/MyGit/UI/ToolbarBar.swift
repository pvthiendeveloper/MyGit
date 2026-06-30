import SwiftUI

struct ToolbarBar: View {
    @EnvironmentObject var main: MainViewModel
    @EnvironmentObject var repos: RepositoryListViewModel
    @EnvironmentObject var coordinator: AppCoordinator
    @EnvironmentObject var changes: ChangesViewModel
    @EnvironmentObject var branches: BranchesViewModel
    @EnvironmentObject var remote: RemoteViewModel
    @State private var showRepoPopover = false
    @State private var showRemoteMenu = false
    @State private var pendingPush: PendingPush?
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
            Spacer()
            AccountBadge()
                .padding(.horizontal, 12)
                .frame(maxHeight: .infinity)
                .padding(.vertical, 8)
                .contentShape(Rectangle())
                .onHover { hoveredAccount = $0 }
                .background(hoveredAccount ? Color.primary.opacity(0.08) : .clear)
                .overlay(alignment: .leading) {
                    Color(NSColor.separatorColor).frame(width: 1)
                }
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
        .alert(
            pushAlertTitle,
            isPresented: Binding(
                get: { pendingPush != nil },
                set: { if !$0 { pendingPush = nil } }
            ),
            presenting: pendingPush
        ) { p in
            switch p {
            case .regular:
                Button("Push") {
                    Task { await remote.push() }
                    pendingPush = nil
                }
                Button("Cancel", role: .cancel) { pendingPush = nil }
            case .force:
                Button("Force Push", role: .destructive) {
                    Task { await remote.forcePush() }
                    pendingPush = nil
                }
                Button("Cancel", role: .cancel) { pendingPush = nil }
            }
        } message: { p in
            Text(pushAlertMessage(p))
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
            main.showBranchPopover.toggle()
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
                DropdownBadge(isOpen: main.showBranchPopover)
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
        .popover(isPresented: $main.showBranchPopover, arrowEdge: .bottom) {
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
                    Text(coordinator.bundles.count > 1
                         ? "Active · \(coordinator.activeBundle.name)"
                         : "Current Repository")
                        .font(.caption).foregroundStyle(.secondary).lineLimit(1)
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
            Button(action: { runPrimaryRemoteAction() }) {
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

            Button(action: { showRemoteMenu.toggle() }) {
                Image(systemName: showRemoteMenu ? "chevron.up" : "chevron.down")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(Color.secondary)
                    .frame(width: 40)
                    .frame(maxHeight: .infinity)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .onHover { hoveredFetchChevron = $0 }
            .background(hoveredFetchChevron ? Color.primary.opacity(0.08) : .clear)
            .disabled(repos.selected == nil || main.isBusy)
            .popover(isPresented: $showRemoteMenu, arrowEdge: .bottom) {
                remoteActionPopover
            }
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
        if main.isBusy {
            SpinningFetchIcon(isBusy: true)
        } else if let s = changes.status, s.behind > 0 {
            Image(systemName: "arrow.down").font(.system(size: 16))
        } else if let s = changes.status, s.ahead > 0 {
            Image(systemName: "arrow.up").font(.system(size: 16))
        } else {
            SpinningFetchIcon(isBusy: main.isBusy)
        }
    }

    private func runPrimaryRemoteAction() {
        if let s = changes.status, s.behind > 0 {
            Task { await remote.pull() }
            return
        }
        if let s = changes.status, s.ahead > 0 {
            Task { await remote.push() }
            return
        }
        Task { await remote.fetchOrigin() }
    }

    private var primaryRemoteIconName: String {
        if let s = changes.status, s.behind > 0 { return "arrow.down" }
        if let s = changes.status, s.ahead > 0 { return "arrow.up" }
        return "arrow.triangle.2.circlepath"
    }

    private var remoteActionPopover: some View {
        VStack(spacing: 0) {
            RemoteActionRow(
                icon: primaryRemoteIconName,
                title: primaryRemoteTitle,
                subtitle: lastFetchLabel,
                badge: primaryRemoteBadge
            ) {
                showRemoteMenu = false
                runPrimaryRemoteAction()
            }
            if primaryRemoteTitle != "Fetch origin" {
                Divider()
                RemoteActionRow(
                    icon: "arrow.triangle.2.circlepath",
                    title: "Fetch origin",
                    subtitle: "Fetch the latest changes from origin",
                    badge: nil
                ) {
                    showRemoteMenu = false
                    Task { await remote.fetchOrigin() }
                }
            }
            if let s = changes.status, s.behind > 0, primaryRemoteTitle != "Pull origin" {
                Divider()
                RemoteActionRow(
                    icon: "arrow.down",
                    title: "Pull origin",
                    subtitle: "Pull \(s.behind) commit\(s.behind == 1 ? "" : "s") from origin",
                    badge: "\(s.behind) ↓"
                ) {
                    showRemoteMenu = false
                    Task { await remote.pull() }
                }
            }
            if let s = changes.status, s.ahead > 0, primaryRemoteTitle != "Push origin" {
                Divider()
                RemoteActionRow(
                    icon: "arrow.up",
                    title: "Push origin",
                    subtitle: "Push \(s.ahead) commit\(s.ahead == 1 ? "" : "s") to origin",
                    badge: "\(s.ahead) ↑"
                ) {
                    showRemoteMenu = false
                    Task { await remote.push() }
                }
            }
            Divider()
            RemoteActionRow(
                icon: "exclamationmark.arrow.triangle.2.circlepath",
                title: "Force push origin",
                subtitle: "Overwrite remote with local (uses --force-with-lease)",
                badge: nil,
                destructive: true
            ) {
                showRemoteMenu = false
                pendingPush = .force
            }
        }
        .frame(width: 340)
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

    private var pushAlertTitle: String {
        guard let p = pendingPush else { return "Push?" }
        switch p {
        case .regular: return "Push to origin?"
        case .force: return "Force push to origin?"
        }
    }

    private func pushAlertMessage(_ p: PendingPush) -> String {
        let branch = changes.status?.branch ?? "current branch"
        switch p {
        case .regular(let n):
            return "Push \(n) commit\(n == 1 ? "" : "s") from '\(branch)' to origin."
        case .force:
            return "Force push '\(branch)' to origin using --force-with-lease. This rewrites the remote branch and can destroy others' work if they have pushed since you fetched."
        }
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
                    // Spin up fast, then settle into a steady loop.
                    withAnimation(.easeIn(duration: 0.5)) { degrees += 360 }
                    try? await Task.sleep(nanoseconds: 500_000_000)
                    while !Task.isCancelled {
                        withAnimation(.linear(duration: 0.6)) { degrees += 360 }
                        try? await Task.sleep(nanoseconds: 600_000_000)
                    }
                } else {
                    // Wind down: finish the current turn plus two decelerating
                    // turns so it coasts to a stop instead of snapping.
                    let target = (degrees / 360).rounded(.up) * 360 + 720
                    withAnimation(.easeOut(duration: 1.0)) { degrees = target }
                }
            }
    }
}

private struct RemoteActionRow: View {
    let icon: String
    let title: String
    let subtitle: String
    let badge: String?
    var destructive: Bool = false
    let action: () -> Void
    @State private var hovered = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 12) {
                Image(systemName: icon)
                    .font(.system(size: 16))
                    .foregroundStyle(destructive ? Color.red : .primary)
                    .frame(width: 20)
                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(destructive ? Color.red : .primary)
                    Text(subtitle)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                        .multilineTextAlignment(.leading)
                }
                Spacer(minLength: 8)
                if let badge {
                    Text(badge)
                        .font(.system(size: 11, weight: .semibold))
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(Color.primary.opacity(0.15), in: Capsule())
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovered = $0 }
        .background(hovered ? Color.primary.opacity(0.08) : .clear)
    }
}

private enum PendingPush: Identifiable {
    case regular(Int)
    case force
    var id: String {
        switch self {
        case .regular(let n): return "regular-\(n)"
        case .force: return "force"
        }
    }
}
