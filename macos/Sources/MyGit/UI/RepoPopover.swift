import SwiftUI

struct RepoPopover: View {
    @EnvironmentObject var repos: RepositoryListViewModel
    @Environment(\.dismiss) private var dismiss
    @State private var searchText = ""
    /// Path being dragged, and the row it would land in front of — drives the
    /// insertion line. Dragging is disabled while filtering, since the visible
    /// list isn't the real order then.
    @State private var dragging: String?
    @State private var dropTarget: String?

    private var filtered: [Workspace] {
        guard !searchText.isEmpty else { return repos.workspaces }
        return repos.workspaces.filter {
            $0.name.localizedCaseInsensitiveContains(searchText)
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(alignment: .center, spacing: 8) {
                Image(systemName: "rectangle.stack").font(.system(size: 16))
                Text("Current Repository")
                    .font(.system(size: 15, weight: .bold))
                    .lineLimit(1)
                Spacer()
                Button { dismiss() } label: {
                    Image(systemName: "xmark").font(.caption2).foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)

            HStack(spacing: 8) {
                HStack(spacing: 6) {
                    Image(systemName: "magnifyingglass").foregroundStyle(.secondary).font(.caption)
                    TextField("Filter", text: $searchText)
                        .textFieldStyle(.plain)
                        .font(.system(size: 12))
                    if !searchText.isEmpty {
                        Button { searchText = "" } label: {
                            Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary).font(.caption)
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 6)
                .background(Color(NSColor.controlBackgroundColor))
                .clipShape(RoundedRectangle(cornerRadius: 6))
                .overlay(RoundedRectangle(cornerRadius: 6).stroke(Color.accentColor, lineWidth: 1))

                Menu {
                    Button("Add Local Repository…") {
                        dismiss()
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
                            repos.pickRepository()
                        }
                    }
                    Button("Add by Path…") {
                        dismiss()
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
                            repos.promptAddByPath()
                        }
                    }
                } label: {
                    HStack(spacing: 4) {
                        Text("Add").font(.system(size: 12, weight: .medium))
                        Image(systemName: "chevron.down").font(.system(size: 9))
                    }
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
                    .background(Color(NSColor.controlBackgroundColor))
                    .clipShape(RoundedRectangle(cornerRadius: 6))
                }
                .menuStyle(.borderlessButton)
                .fixedSize()
            }
            .padding(.horizontal, 12)
            .padding(.bottom, 8)

            Divider()

            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    if !filtered.isEmpty {
                        let groups = repos.grouped(filtered)
                        // The Pinned section stays visible even when empty, so
                        // there's somewhere to drag the first repo into.
                        if !groups.pinned.isEmpty || dragging != nil {
                            sectionHeader("Pinned")
                            ForEach(groups.pinned) { workspace in
                                row(for: workspace, pinnedSection: true)
                            }
                            dropZone(pinned: true, isEmpty: groups.pinned.isEmpty)
                        }
                        if !groups.others.isEmpty || dragging != nil {
                            sectionHeader(groups.pinned.isEmpty && dragging == nil ? "Repositories" : "Other")
                            ForEach(groups.others) { workspace in
                                row(for: workspace, pinnedSection: false)
                            }
                            dropZone(pinned: false, isEmpty: groups.others.isEmpty)
                        }
                    } else {
                        Text("No repositories match")
                            .font(.system(size: 12))
                            .foregroundStyle(.secondary)
                            .padding(16)
                    }
                }
                .padding(.vertical, 4)
            }
        }
        .frame(width: 340, height: 420)
    }

    private var canReorder: Bool { searchText.isEmpty }

    @ViewBuilder
    private func row(for workspace: Workspace, pinnedSection: Bool) -> some View {
        let path = workspace.url.path
        VStack(spacing: 0) {
            // Insertion line above the row the drop would land in front of.
            Rectangle()
                .fill(dropTarget == path ? Color.accentColor : Color.clear)
                .frame(height: 2)
                .padding(.horizontal, 8)

            RepoRow(workspace: workspace) {
                repos.select(workspace)
                dismiss()
            } onRemove: {
                repos.remove(workspace)
            }
            .opacity(dragging == path ? 0.4 : 1)
        }
        .modifier(RepoDragAndDrop(
            enabled: canReorder,
            path: path,
            onDragStart: { dragging = path },
            onDropEnter: { dropTarget = path },
            onDropExit: { if dropTarget == path { dropTarget = nil } },
            onDrop: { moved in
                repos.move(path: moved, before: path, intoPinned: pinnedSection, in: repos.workspaces)
                dragging = nil
                dropTarget = nil
            }
        ))
    }

    /// Tail of a section: drops here append to that section (and pin/unpin).
    @ViewBuilder
    private func dropZone(pinned: Bool, isEmpty: Bool) -> some View {
        let isActive = dropTarget == zoneKey(pinned)
        Rectangle()
            .fill(isActive ? Color.accentColor.opacity(0.25) : Color.clear)
            .frame(height: isEmpty ? 28 : 12)
            .overlay(alignment: .leading) {
                if isEmpty {
                    Text(pinned ? "Drop here to pin" : "Drop here to unpin")
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                        .padding(.leading, 16)
                }
            }
            .modifier(RepoDragAndDrop(
                enabled: canReorder,
                path: nil,
                onDragStart: {},
                onDropEnter: { dropTarget = zoneKey(pinned) },
                onDropExit: { if dropTarget == zoneKey(pinned) { dropTarget = nil } },
                onDrop: { moved in
                    repos.moveToEnd(path: moved, intoPinned: pinned, in: repos.workspaces)
                    dragging = nil
                    dropTarget = nil
                }
            ))
    }

    private func zoneKey(_ pinned: Bool) -> String { pinned ? "\u{0}pinned" : "\u{0}other" }

    private func sectionHeader(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 11, weight: .semibold))
            .foregroundStyle(.secondary)
            .padding(.horizontal, 12)
            .padding(.vertical, 4)
            .frame(maxWidth: .infinity, alignment: .leading)
    }
}

private struct RepoRow: View {
    let workspace: Workspace
    let onSelect: () -> Void
    let onRemove: () -> Void

    @EnvironmentObject var repos: RepositoryListViewModel
    @State private var isHovered = false

    private var isCurrent: Bool { repos.selected?.url == workspace.url }
    private var isPinned: Bool { repos.isPinned(workspace) }

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: workspace.isSingle ? "desktopcomputer" : "rectangle.stack")
                .font(.system(size: 13))
                .foregroundStyle(isCurrent ? Color.white : Color.primary)
                .frame(width: 18)

            VStack(alignment: .leading, spacing: 1) {
                Text(workspace.name)
                    .font(.system(size: 12, weight: isCurrent ? .semibold : .regular))
                    .foregroundStyle(isCurrent ? Color.white : Color.primary)
                    .lineLimit(1)
                if !workspace.isSingle {
                    Text("\(workspace.repos.count) repos")
                        .font(.system(size: 10))
                        .foregroundStyle(isCurrent ? Color.white.opacity(0.85) : Color.secondary)
                }
            }

            Spacer()

            // Pinned repos keep their marker visible; the rest reveal it on hover.
            if isPinned || isHovered {
                Button { repos.togglePin(workspace) } label: {
                    Image(systemName: isPinned ? "pin.fill" : "pin")
                        .font(.system(size: 11))
                        .foregroundStyle(isCurrent ? Color.white
                                         : (isPinned ? Color.accentColor : Color.secondary))
                        .rotationEffect(.degrees(45))
                }
                .buttonStyle(.plain)
                .help(isPinned ? "Unpin" : "Pin to the top")
            }

            if isHovered {
                Button(action: onRemove) {
                    Image(systemName: "minus.circle.fill")
                        .foregroundStyle(isCurrent ? Color.white : Color.red)
                        .font(.system(size: 12))
                }
                .buttonStyle(.plain)
                .help("Remove from list")
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 7)
        .background(
            isCurrent ? Color.accentColor :
            (isHovered ? Color.accentColor.opacity(0.15) : Color.clear)
        )
        .clipShape(RoundedRectangle(cornerRadius: 4))
        .contentShape(Rectangle())
        .onHover { isHovered = $0 }
        .onTapGesture(perform: onSelect)
        .contextMenu {
            Button(isPinned ? "Unpin" : "Pin") { repos.togglePin(workspace) }
            Divider()
            Button("Reveal in Finder") { FileActions.reveal(absPath: workspace.url.path) }
            Button("Copy Path") { FileActions.copyToPasteboard(workspace.url.path) }
            Divider()
            Button("Remove from List", role: .destructive, action: onRemove)
        }
        .padding(.horizontal, 4)
    }
}


/// Makes a row draggable by workspace path and droppable onto.
private struct RepoDragAndDrop: ViewModifier {
    let enabled: Bool
    /// Nil for the section tail, which can only receive drops.
    let path: String?
    let onDragStart: () -> Void
    let onDropEnter: () -> Void
    let onDropExit: () -> Void
    let onDrop: (String) -> Void

    func body(content: Content) -> some View {
        Group {
            if let path, enabled {
                content.draggable(path) {
                    Text((path as NSString).lastPathComponent)
                        .font(.system(size: 12))
                        .padding(6)
                        .onAppear(perform: onDragStart)
                }
            } else {
                content
            }
        }
        .dropDestination(for: String.self) { items, _ in
            guard enabled, let moved = items.first else { return false }
            onDrop(moved)
            return true
        } isTargeted: { targeted in
            guard enabled else { return }
            if targeted { onDropEnter() } else { onDropExit() }
        }
    }
}
