import SwiftUI

/// Left pane of the history graph: ref search + Local / Remote / Tags tree.
/// Local/Remote branches are grouped into folders by their `/`-prefix.
/// Clicking a ref scopes the graph to it; double-clicking a branch checks out.
struct RefsSidebarView: View {
    @EnvironmentObject var branches: BranchesViewModel
    @EnvironmentObject var history: HistoryViewModel

    @State private var search = ""
    @State private var localOpen = true
    @State private var remoteOpen = true
    @State private var tagsOpen = true

    private func match(_ name: String) -> Bool {
        search.isEmpty || name.localizedCaseInsensitiveContains(search)
    }

    private var locals: [GitBranch] { branches.branches.filter { !$0.isRemote && match($0.name) } }
    private var remotes: [GitBranch] { branches.branches.filter { $0.isRemote && match($0.name) } }
    private var tagList: [String] { branches.tags.filter { match($0) } }

    private var activeRef: String? {
        if case .ref(let r) = history.filter.branchScope { return r }
        return nil
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 4) {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 11)).foregroundStyle(.secondary)
                TextField("Branch or tag", text: $search)
                    .textFieldStyle(.plain).font(.system(size: 12))
            }
            .padding(.horizontal, 8).padding(.vertical, 6)
            Divider()

            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    Button { history.filter.branchScope = .all } label: {
                        HStack(spacing: 6) {
                            Image(systemName: "arrow.up.circle").font(.system(size: 11))
                            Text("All branches (HEAD)").font(.system(size: 12, weight: .medium))
                            Spacer()
                        }
                        .foregroundStyle(activeRef == nil ? Color.accentColor : .primary)
                        .padding(.horizontal, 10).padding(.vertical, 5)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)

                    section("Local", icon: "internaldrive", isOpen: $localOpen) {
                        branchTree(locals)
                    }
                    section("Remote", icon: "cloud", isOpen: $remoteOpen) {
                        branchTree(remotes)
                    }
                    section("Tags", icon: "tag", isOpen: $tagsOpen) {
                        ForEach(tagList, id: \.self) { t in
                            refRow(label: t, indent: 1, icon: "tag.fill",
                                   isActive: activeRef == t, starred: false) {
                                history.filter.branchScope = .ref(t)
                            } onDouble: { history.filter.branchScope = .ref(t) }
                        }
                    }
                }
                .padding(.vertical, 4)
            }
        }
        .background(Color(NSColor.controlBackgroundColor))
    }

    // MARK: Branch tree (folders by `/`-prefix)

    @ViewBuilder
    private func branchTree(_ list: [GitBranch]) -> some View {
        let grouped = Dictionary(grouping: list, by: { $0.group })
        let topLevel = (grouped[nil] ?? []).sorted { $0.name < $1.name }
        let folders = grouped.keys.compactMap { $0 }.sorted()

        ForEach(topLevel) { b in branchRow(b, label: b.name, indent: 1) }
        ForEach(folders, id: \.self) { folder in
            BranchFolder(name: folder, branches: (grouped[folder] ?? []).sorted { $0.leaf < $1.leaf }) { b in
                branchRow(b, label: b.leaf, indent: 2)
            }
        }
    }

    private func branchRow(_ b: GitBranch, label: String, indent: Int) -> some View {
        refRow(label: label, indent: indent,
               icon: b.isRemote ? "cloud" : "arrow.triangle.branch",
               isActive: activeRef == b.checkoutName, starred: b.isCurrent) {
            history.filter.branchScope = .ref(b.checkoutName)
        } onDouble: {
            Task { await branches.checkout(b) }
        }
    }

    private func refRow(label: String, indent: Int, icon: String,
                        isActive: Bool, starred: Bool,
                        onTap: @escaping () -> Void,
                        onDouble: @escaping () -> Void) -> some View {
        HStack(spacing: 5) {
            if starred {
                Image(systemName: "star.fill").font(.system(size: 9)).foregroundStyle(.yellow)
            } else {
                Image(systemName: icon).font(.system(size: 10)).foregroundStyle(.secondary)
            }
            Text(label).font(.system(size: 12, weight: starred ? .semibold : .regular)).lineLimit(1)
            Spacer()
        }
        .padding(.leading, CGFloat(indent) * 14 + 10).padding(.trailing, 8).padding(.vertical, 4)
        .background(isActive ? Color.accentColor.opacity(0.18) : .clear)
        .contentShape(Rectangle())
        .onTapGesture(count: 2, perform: onDouble)
        .onTapGesture(perform: onTap)
    }

    @ViewBuilder
    private func section<Content: View>(_ title: String, icon: String,
                                        isOpen: Binding<Bool>,
                                        @ViewBuilder content: () -> Content) -> some View {
        Button { withAnimation(.easeInOut(duration: 0.12)) { isOpen.wrappedValue.toggle() } } label: {
            HStack(spacing: 6) {
                Image(systemName: isOpen.wrappedValue ? "chevron.down" : "chevron.right")
                    .font(.system(size: 9, weight: .semibold)).foregroundStyle(.secondary).frame(width: 12)
                Image(systemName: icon).font(.system(size: 11)).foregroundStyle(.secondary)
                Text(title).font(.system(size: 12, weight: .semibold))
                Spacer()
            }
            .padding(.horizontal, 8).padding(.vertical, 5)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        if isOpen.wrappedValue { content() }
    }
}

/// A collapsible folder grouping branches that share a `/`-prefix.
private struct BranchFolder<Row: View>: View {
    let name: String
    let branches: [GitBranch]
    let row: (GitBranch) -> Row
    @State private var open = false

    var body: some View {
        Button { withAnimation(.easeInOut(duration: 0.12)) { open.toggle() } } label: {
            HStack(spacing: 5) {
                Image(systemName: open ? "chevron.down" : "chevron.right")
                    .font(.system(size: 8, weight: .semibold)).foregroundStyle(.secondary).frame(width: 12)
                Image(systemName: "folder.fill").font(.system(size: 10)).foregroundStyle(.secondary)
                Text(name).font(.system(size: 12)).lineLimit(1)
                Spacer()
            }
            .padding(.leading, 24).padding(.trailing, 8).padding(.vertical, 4)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        if open { ForEach(branches) { row($0) } }
    }
}
