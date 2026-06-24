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

    var body: some View {
        HStack(spacing: 12) {
            repoPicker
            Divider().frame(height: 36)
            branchButton
            Divider().frame(height: 36)
            fetchButton
            Divider().frame(height: 36)
            AccountBadge()
            Spacer()
            remoteOps
        }
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
            get: { branches.branchCompareResult.map { CompareResult(text: $0) } },
            set: { if $0 == nil { branches.branchCompareResult = nil } }
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
                }
                Image(systemName: showBranchPopover ? "chevron.up" : "chevron.down")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: 220, alignment: .leading)
        }
        .buttonStyle(.plain)
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
                Image(systemName: showRepoPopover ? "chevron.up" : "chevron.down")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: 260, alignment: .leading)
        }
        .buttonStyle(.plain)
        .popover(isPresented: $showRepoPopover, arrowEdge: .bottom) {
            RepoPopover().environmentObject(repos)
        }
    }

    private var fetchButton: some View {
        Button(action: { Task { await remote.fetchOrigin() } }) {
            HStack(spacing: 8) {
                SpinningFetchIcon(isBusy: main.isBusy)
                VStack(alignment: .leading, spacing: 1) {
                    Text("Fetch origin").font(.system(size: 13, weight: .semibold))
                    Text(lastFetchLabel)
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
        }
        .buttonStyle(.plain)
        .disabled(repos.selected == nil || main.isBusy)
    }

    private var lastFetchLabel: String {
        guard let d = remote.lastFetchedAt else { return "Never fetched this session" }
        let f = RelativeDateTimeFormatter()
        return "Last fetched " + f.localizedString(for: d, relativeTo: Date())
    }

    private var remoteOps: some View {
        HStack(spacing: 8) {
            if let s = changes.status, s.behind > 0 {
                Button(action: { Task { await remote.pull() } }) {
                    Label("Pull \(s.behind)", systemImage: "arrow.down")
                }
            }
            if let s = changes.status, s.ahead > 0 {
                Button(action: { Task { await remote.push() } }) {
                    Label("Push \(s.ahead)", systemImage: "arrow.up")
                }
            }
        }
    }
}

private struct CompareResult: Identifiable {
    let id = UUID()
    let text: String
}

private struct PendingNewBranch: Identifiable {
    let id = UUID()
    let name: String
    let from: GitBranch
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
