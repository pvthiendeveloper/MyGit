import SwiftUI
import AppKit

struct CompareChangedFilesTree: View {
    let nodes: [ChangedFileNode]
    let onAction: (ChangedFileEntry, CompareFileAction) -> Void
    /// When set, the right-click menu shows only these actions (in order).
    /// nil → the full default git menu (Changes/History usage).
    var menuActions: [CompareFileAction]? = nil

    @State private var expanded: Set<String> = []

    private var compacted: [ChangedFileNode] { nodes.map(Self.compact) }
    private var allDirIds: Set<String> { Set(Self.collectDirIds(compacted)) }
    private var totalFiles: Int { nodes.reduce(0) { $0 + Self.countLeafs($1) } }
    private var rootKey: String { nodes.map(\.id).joined(separator: "|") }

    var body: some View {
        VStack(spacing: 0) {
            actionsBar
            Divider()
            if nodes.isEmpty {
                Text("Select a commit to see changed files")
                    .foregroundStyle(.secondary)
                    .font(.caption)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        ForEach(compacted) { node in
                            CompareFileTreeRow(
                                node: node,
                                depth: 0,
                                expanded: $expanded,
                                onAction: onAction,
                                menuActions: menuActions
                            )
                        }
                    }
                    .padding(.vertical, 2)
                }
            }
        }
        .background(Color(NSColor.textBackgroundColor))
        .task(id: rootKey) {
            expanded = allDirIds
        }
    }

    private var actionsBar: some View {
        HStack(spacing: 2) {
            Button { expanded = allDirIds } label: {
                Image(systemName: "rectangle.expand.vertical")
                    .font(.system(size: 11))
            }
            .buttonStyle(.borderless)
            .help("Expand All")

            Button { expanded = [] } label: {
                Image(systemName: "rectangle.compress.vertical")
                    .font(.system(size: 11))
            }
            .buttonStyle(.borderless)
            .help("Collapse All")

            Divider().frame(height: 12).padding(.horizontal, 4)

            if !nodes.isEmpty {
                Text(totalFiles == 1 ? "1 file" : "\(totalFiles) files")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }

            Spacer()
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(Color(NSColor.windowBackgroundColor).opacity(0.85))
    }

    private static func compact(_ node: ChangedFileNode) -> ChangedFileNode {
        guard var children = node.children, !children.isEmpty else { return node }
        children = children.map { compact($0) }
        if children.count == 1, let only = children.first, only.children != nil {
            let merged = ChangedFileNode(
                id: node.id,
                name: "\(node.name)/\(only.name)",
                entry: nil,
                children: only.children
            )
            return merged
        }
        node.children = children
        return node
    }

    private static func collectDirIds(_ nodes: [ChangedFileNode]) -> [String] {
        var result: [String] = []
        for n in nodes {
            if n.children != nil {
                result.append(n.id)
                result.append(contentsOf: collectDirIds(n.children ?? []))
            }
        }
        return result
    }

    fileprivate static func countLeafs(_ node: ChangedFileNode) -> Int {
        if node.children == nil { return 1 }
        return (node.children ?? []).reduce(0) { $0 + countLeafs($1) }
    }
}

private struct CompareFileTreeRow: View {
    let node: ChangedFileNode
    let depth: Int
    @Binding var expanded: Set<String>
    let onAction: (ChangedFileEntry, CompareFileAction) -> Void
    var menuActions: [CompareFileAction]? = nil

    private var isDir: Bool { node.children != nil }
    private var isExpanded: Bool { expanded.contains(node.id) }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            rowContent
            if isDir, isExpanded {
                ForEach(node.children ?? []) { child in
                    CompareFileTreeRow(
                        node: child,
                        depth: depth + 1,
                        expanded: $expanded,
                        onAction: onAction,
                        menuActions: menuActions
                    )
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder
    private var rowContent: some View {
        HStack(spacing: 4) {
            Color.clear.frame(width: CGFloat(depth) * 14, height: 1)

            if isDir {
                Button {
                    toggle()
                } label: {
                    Image(systemName: isExpanded ? "chevron.down" : "chevron.right")
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundStyle(.secondary)
                        .frame(width: 10)
                }
                .buttonStyle(.plain)

                Image(systemName: "folder.fill")
                    .foregroundStyle(Color(red: 0.85, green: 0.72, blue: 0.40))
                    .font(.system(size: 11))

                Text(node.name)
                    .font(.system(size: 12))
                    .foregroundStyle(.primary)
                    .lineLimit(1)

                Text(countText)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            } else {
                Color.clear.frame(width: 10, height: 1)

                Text(statusGlyph)
                    .font(.system(size: 10, weight: .bold, design: .monospaced))
                    .foregroundStyle(statusColor)
                    .frame(width: 12, alignment: .leading)

                Image(systemName: fileSymbol)
                    .foregroundStyle(.secondary)
                    .font(.system(size: 11))

                fileNameText
                    .font(.system(size: 12))
                    .foregroundStyle(statusColor)
                    .strikethrough(node.entry?.status == .deleted)
                    .lineLimit(1)
            }

            Spacer(minLength: 0)
        }
        .padding(.horizontal, 8)
        .frame(maxWidth: .infinity, minHeight: 24, alignment: .leading)
        .contentShape(Rectangle())
        .onTapGesture {
            if isDir {
                toggle()
            } else if let entry = node.entry {
                onAction(entry, .showDiff)
            }
        }
        .contextMenu {
            if !isDir, let entry = node.entry {
                fileContextMenu(for: entry)
            }
        }
    }

    @ViewBuilder
    private func fileContextMenu(for entry: ChangedFileEntry) -> some View {
        if let actions = menuActions {
            // Restricted menu (e.g. Pull Requests): only the given actions.
            ForEach(Array(actions.enumerated()), id: \.offset) { _, action in
                Button(action.menuLabel) { onAction(entry, action) }
            }
        } else {
            Button("Show Diff") { onAction(entry, .showDiff) }
            Button("Show Diff in a New Tab") { onAction(entry, .showDiffInNewTab) }
            Button("Compare with Local") { onAction(entry, .compareWithLocal) }
            Button("Compare Before with Local") { onAction(entry, .compareBeforeWithLocal) }
            Divider()
            Button("Edit Source") { onAction(entry, .editSource) }
            Button("Open Repository Version") { onAction(entry, .openRepositoryVersion) }
            Divider()
            Button("Revert Selected Changes") { onAction(entry, .revertChanges) }
            Button("Cherry-Pick Selected Changes") { onAction(entry, .cherryPickChanges) }
            Button("Drop Selected Changes") { onAction(entry, .dropChanges) }
            Divider()
            Button("Create Patch...") { onAction(entry, .createPatch) }
            Button("History Up to Here") { onAction(entry, .historyUpToHere) }
        }
    }

    private var fileNameText: Text {
        if let entry = node.entry, let old = entry.oldPath {
            return Text("\(old.lastPathComponent) → \(node.name)")
        }
        return Text(node.name)
    }

    private func toggle() {
        if expanded.contains(node.id) {
            expanded.remove(node.id)
        } else {
            expanded.insert(node.id)
        }
    }

    private var countText: String {
        let n = CompareChangedFilesTree.countLeafs(node)
        return n == 1 ? "1 file" : "\(n) files"
    }

    private var statusGlyph: String {
        node.entry?.statusGlyph ?? ""
    }

    private var statusColor: Color {
        switch node.entry?.status {
        case .added: return .green
        case .deleted: return Color(red: 0.55, green: 0.55, blue: 0.55)
        case .renamed, .copied: return .blue
        case .modified: return Color(red: 0.40, green: 0.65, blue: 1.00)
        case .typeChanged: return .orange
        case .unknown: return .orange
        case .none: return .primary
        }
    }

    private var fileSymbol: String {
        let ext = (node.name as NSString).pathExtension.lowercased()
        switch ext {
        case "md": return "doc.text"
        case "swift", "py", "kt", "java", "js", "ts", "go", "rb", "rs", "c", "cpp", "h", "m", "mm":
            return "chevron.left.forwardslash.chevron.right"
        case "json", "yaml", "yml", "toml", "xml", "plist":
            return "doc.badge.gearshape"
        case "png", "jpg", "jpeg", "gif", "svg", "webp":
            return "photo"
        default:
            return "doc"
        }
    }
}

extension ChangedFileNode {
    var optionalChildren: [ChangedFileNode]? { children?.isEmpty == false ? children : nil }
}

private extension String {
    var lastPathComponent: String {
        components(separatedBy: "/").last ?? self
    }
}
