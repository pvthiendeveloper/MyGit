import SwiftUI

struct BranchPopover: View {
    @EnvironmentObject var main: MainViewModel
    @EnvironmentObject var changes: ChangesViewModel
    @EnvironmentObject var branchesVM: BranchesViewModel
    @EnvironmentObject var remote: RemoteViewModel
    @Environment(\.dismiss) private var dismiss

    @State private var searchText = ""
    @State private var showRevisionSheet = false
    @State private var revisionInput = ""
    @State private var collapsed: Set<String> = []

    private var current: String { changes.status?.branch ?? "—" }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Image(systemName: "arrow.triangle.branch").font(.caption)
                Text("Git Branch: \(current)").font(.system(size: 12, weight: .semibold))
                Spacer()
                Button { dismiss() } label: {
                    Image(systemName: "xmark").font(.caption2).foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)

            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary).font(.caption)
                TextField("Search branches", text: $searchText)
                    .textFieldStyle(.plain)
                    .font(.system(size: 12))
                if !searchText.isEmpty {
                    Button { searchText = "" } label: {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundStyle(.secondary).font(.caption)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 6)
            .background(Color(NSColor.controlBackgroundColor))
            .clipShape(RoundedRectangle(cornerRadius: 6))
            .padding(.horizontal, 12)
            .padding(.bottom, 8)

            Divider()

            VStack(spacing: 0) {
                topActionRow(icon: "arrow.down.to.line", label: "Update Project", shortcut: "⌘T") {
                    Task { await remote.fetchOrigin(); await remote.pull() }
                    dismiss()
                }
                topActionRow(icon: "pencil.and.list.clipboard", label: "Commit…", shortcut: "⌘K") {
                    main.tab = .changes
                    dismiss()
                }
                topActionRow(icon: "arrow.up", label: "Push…", shortcut: "⇧⌘K") {
                    Task { await remote.push() }
                    dismiss()
                }
            }
            .padding(.vertical, 4)

            Divider()

            VStack(spacing: 0) {
                topActionRow(icon: "plus", label: "New Branch…", shortcut: "⌥⌘N") {
                    branchesVM.showNewBranchSheet = true
                    dismiss()
                }
                topActionRow(icon: "tag", label: "Checkout Tag or Revision…", shortcut: "") {
                    showRevisionSheet = true
                }
            }
            .padding(.vertical, 4)

            Divider()

            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0, pinnedViews: .sectionHeaders) {
                    if !branchesVM.recentBranches.isEmpty && searchText.isEmpty {
                        collapsibleSection(title: "Recent", branches: branchesVM.recentBranches)
                    }

                    let local = branchesVM.branches.filter { !$0.isRemote && matches($0) }
                    let remoteB = branchesVM.branches.filter { $0.isRemote && matches($0) }

                    if !local.isEmpty {
                        collapsibleSection(title: "Local", branches: local)
                    }
                    if !remoteB.isEmpty {
                        collapsibleSection(title: "Remote", branches: remoteB)
                    }
                }
                .padding(.vertical, 4)
            }
        }
        .frame(width: 340, height: 480)
        .task { await branchesVM.refresh() }
        .sheet(isPresented: $showRevisionSheet) {
            TextInputSheet(
                title: "Checkout Tag or Revision",
                prompt: "Tag / revision",
                placeholder: "v1.0.0 or abc1234",
                value: $revisionInput
            ) { rev in
                Task {
                    await branchesVM.checkoutRevision(rev)
                    dismiss()
                }
            }
        }
    }

    @ViewBuilder
    private func collapsibleSection(title: String, branches: [GitBranch]) -> some View {
        let isCollapsed = collapsed.contains(title)
        Section {
            if !isCollapsed {
                // Flatten to a single homogeneous list so LazyVStack + pinned section
                // headers lay out correctly (interleaving ForEach + lone views misrenders).
                ForEach(rowItems(title: title, branches: branches)) { item in
                    switch item.kind {
                    case let .folder(name, count, key, folderCollapsed):
                        folderHeader(name, count: count, isCollapsed: folderCollapsed) {
                            if folderCollapsed { collapsed.remove(key) } else { collapsed.insert(key) }
                        }
                    case let .branch(branch, indented):
                        BranchRow(branch: branch, onDismissParent: { dismiss() })
                            .padding(.leading, indented ? 12 : 0)
                    }
                }
            }
        } header: {
            sectionHeader(title, count: branches.count, isCollapsed: isCollapsed) {
                if isCollapsed { collapsed.remove(title) } else { collapsed.insert(title) }
            }
        }
    }

    private struct BranchListItem: Identifiable {
        enum Kind {
            case folder(name: String, count: Int, key: String, collapsed: Bool)
            case branch(GitBranch, indented: Bool)
        }
        let id: String
        let kind: Kind
    }

    private func rowItems(title: String, branches: [GitBranch]) -> [BranchListItem] {
        var items: [BranchListItem] = []
        for b in branches where b.group == nil {
            items.append(BranchListItem(id: "b/\(b.id)", kind: .branch(b, indented: false)))
        }
        let grouped = Dictionary(grouping: branches.filter { $0.group != nil }, by: { $0.group! })
        for g in grouped.keys.sorted() {
            let key = "\(title)/\(g)"
            let folderCollapsed = collapsed.contains(key)
            items.append(BranchListItem(
                id: "f/\(key)",
                kind: .folder(name: g, count: grouped[g]?.count ?? 0, key: key, collapsed: folderCollapsed)
            ))
            if !folderCollapsed {
                for b in grouped[g] ?? [] {
                    items.append(BranchListItem(id: "b/\(b.id)", kind: .branch(b, indented: true)))
                }
            }
        }
        return items
    }

    private func folderHeader(_ name: String, count: Int, isCollapsed: Bool, toggle: @escaping () -> Void) -> some View {
        Button(action: toggle) {
            HStack(spacing: 4) {
                Image(systemName: "chevron.right")
                    .font(.system(size: 8, weight: .semibold))
                    .rotationEffect(.degrees(isCollapsed ? 0 : 90))
                Image(systemName: isCollapsed ? "folder" : "folder.fill").font(.system(size: 10))
                Text(name).font(.system(size: 11))
                Text("\(count)").font(.system(size: 10)).foregroundStyle(.tertiary)
                Spacer()
            }
            .foregroundStyle(.secondary)
            .padding(.horizontal, 12)
            .padding(.vertical, 3)
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private func sectionHeader(_ text: String, count: Int, isCollapsed: Bool, toggle: @escaping () -> Void) -> some View {
        Button(action: toggle) {
            HStack(spacing: 4) {
                Image(systemName: "chevron.right")
                    .font(.system(size: 9, weight: .semibold))
                    .rotationEffect(.degrees(isCollapsed ? 0 : 90))
                Text(text).font(.system(size: 10, weight: .semibold))
                Text("\(count)").font(.system(size: 10)).foregroundStyle(.tertiary)
                Spacer()
            }
            .foregroundStyle(.secondary)
            .padding(.horizontal, 12)
            .padding(.vertical, 4)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color(NSColor.windowBackgroundColor))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private func topActionRow(icon: String, label: String, shortcut: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack {
                Image(systemName: icon).frame(width: 16)
                Text(label).font(.system(size: 12))
                Spacer()
                if !shortcut.isEmpty {
                    Text(shortcut).font(.system(size: 11)).foregroundStyle(.secondary)
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 5)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .hoverHighlight()
    }

    private func matches(_ b: GitBranch) -> Bool {
        searchText.isEmpty || b.name.localizedCaseInsensitiveContains(searchText)
    }
}

private struct BranchRow: View {
    let branch: GitBranch
    var onDismissParent: (() -> Void)? = nil
    @EnvironmentObject var main: MainViewModel
    @EnvironmentObject var changes: ChangesViewModel
    @EnvironmentObject var branchesVM: BranchesViewModel
    @EnvironmentObject var remote: RemoteViewModel
    @State private var showMenu = false
    @State private var isHovered = false

    var body: some View {
        Button { showMenu = true } label: {
            HStack(spacing: 6) {
                branchIcon
                VStack(alignment: .leading, spacing: 0) {
                    Text(branch.leaf)
                        .font(.system(size: 12, weight: branch.isCurrent ? .semibold : .regular))
                        .lineLimit(1)
                }
                Spacer()
                if let up = branch.upstream {
                    Text(up)
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                Image(systemName: "chevron.right")
                    .font(.system(size: 9))
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 5)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .background(isHovered ? Color.accentColor.opacity(0.15) : Color.clear)
        .clipShape(RoundedRectangle(cornerRadius: 4))
        .onHover { isHovered = $0 }
        .popover(isPresented: $showMenu, arrowEdge: .trailing) {
            BranchActionMenu(branch: branch, onDismissParent: onDismissParent)
                .environmentObject(main)
                .environmentObject(changes)
                .environmentObject(branchesVM)
                .environmentObject(remote)
        }
    }

    private var branchIcon: some View {
        Group {
            if branch.isCurrent {
                Image(systemName: "star.fill")
                    .font(.system(size: 10))
                    .foregroundStyle(Color.yellow)
            } else {
                Image(systemName: "arrow.triangle.branch")
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
            }
        }
        .frame(width: 14)
    }
}

private extension View {
    func hoverHighlight() -> some View {
        self.modifier(BranchPopoverHoverModifier())
    }
}

private struct BranchPopoverHoverModifier: ViewModifier {
    @State private var isHovered = false
    func body(content: Content) -> some View {
        content
            .background(isHovered ? Color.accentColor.opacity(0.15) : Color.clear)
            .clipShape(RoundedRectangle(cornerRadius: 4))
            .onHover { isHovered = $0 }
    }
}
