import SwiftUI

/// The two groups the change list is split into, IntelliJ-style: tracked
/// files with modifications, and files git doesn't track yet.
enum ChangeGroup: String, CaseIterable {
    case changes
    case unversioned

    var title: String {
        switch self {
        case .changes: return "Changes"
        case .unversioned: return "Unversioned Files"
        }
    }

    func filter(_ changes: [FileChange]) -> [FileChange] {
        changes.filter { $0.isUntracked == (self == .unversioned) }
    }
}

/// Collapsible header of a change group: chevron, a checkbox that (un)checks
/// the whole group and shows "mixed" when only some files are checked, the
/// title and the file count.
struct ChangeGroupHeader: View {
    let group: ChangeGroup
    let changes: [FileChange]
    @Binding var expanded: Bool
    @ObservedObject var vm: ChangesViewModel

    var body: some View {
        HStack(spacing: 6) {
            Button {
                withAnimation(.easeInOut(duration: 0.12)) { expanded.toggle() }
            } label: {
                Image(systemName: expanded ? "chevron.down" : "chevron.right")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .frame(width: 14)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            // One binding per file: SwiftUI derives on / off / mixed from them.
            Toggle(sources: changes.map { change in
                Binding(
                    get: { vm.stagedPaths.contains(change.path) },
                    set: { on in vm.setStaged([change], on) }
                )
            }, isOn: \.self) { EmptyView() }
            .toggleStyle(.checkbox)

            Text(group.title)
                .font(.system(size: 12, weight: .semibold))
            Text("\(changes.count) file\(changes.count == 1 ? "" : "s")")
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
            Spacer()
        }
        .padding(.vertical, 2)
        .contentShape(Rectangle())
        .onTapGesture(count: 2) { expanded.toggle() }
    }
}

// MARK: - Directory tree

/// A folder in the "Group By ▸ Directory" view. Chains of folders that hold
/// nothing but one subfolder are compacted into one row ("Example/Playground/Home").
struct ChangeFolder: Identifiable {
    let id: String            // full folder path, "" for the root
    let name: String          // what the row shows (maybe several segments)
    var folders: [ChangeFolder]
    var files: [FileChange]

    var allFiles: [FileChange] { files + folders.flatMap(\.allFiles) }
    /// Ids of every folder below this one (what "Collapse All" folds).
    var allFolderIDs: [String] { folders.flatMap { [$0.id] + $0.allFolderIDs } }

    static func tree(_ changes: [FileChange]) -> ChangeFolder {
        final class Node {
            var folders: [String: Node] = [:]
            var files: [FileChange] = []
        }
        let root = Node()
        for change in changes {
            var node = root
            for part in change.path.split(separator: "/").dropLast() {
                let key = String(part)
                if node.folders[key] == nil { node.folders[key] = Node() }
                node = node.folders[key]!
            }
            node.files.append(change)
        }
        func build(_ node: Node, name: String, path: String) -> ChangeFolder {
            var folder = ChangeFolder(
                id: path, name: name,
                folders: node.folders.keys
                    .sorted { $0.localizedStandardCompare($1) == .orderedAscending }
                    .map { key in build(node.folders[key]!, name: key,
                                        path: path.isEmpty ? key : "\(path)/\(key)") },
                files: node.files.sorted {
                    ($0.path as NSString).lastPathComponent
                        .localizedStandardCompare(($1.path as NSString).lastPathComponent) == .orderedAscending
                }
            )
            // Compact "a" → "b" → "c" into one "a/b/c" row (never the root).
            while !folder.id.isEmpty, folder.files.isEmpty, folder.folders.count == 1 {
                let only = folder.folders[0]
                folder = ChangeFolder(id: only.id, name: "\(folder.name)/\(only.name)",
                                      folders: only.folders, files: only.files)
            }
            return folder
        }
        return build(root, name: "", path: "")
    }
}

/// One visible row of the tree, after applying collapsed folders.
enum ChangeTreeRow: Identifiable {
    case folder(ChangeFolder, depth: Int)
    case file(FileChange, depth: Int)

    var id: String {
        switch self {
        case .folder(let f, _): return "d:" + f.id
        case .file(let c, _): return "f:" + c.path
        }
    }

    static func rows(_ root: ChangeFolder, collapsed: Set<String>) -> [ChangeTreeRow] {
        var rows: [ChangeTreeRow] = []
        func walk(_ folder: ChangeFolder, depth: Int) {
            for sub in folder.folders {
                rows.append(.folder(sub, depth: depth))
                if !collapsed.contains(sub.id) { walk(sub, depth: depth + 1) }
            }
            for file in folder.files { rows.append(.file(file, depth: depth)) }
        }
        walk(root, depth: 0)
        return rows
    }
}

/// A folder row: chevron, whole-folder checkbox (mixed when partly checked),
/// icon, compacted name and file count.
struct ChangeFolderRow: View {
    let folder: ChangeFolder
    let depth: Int
    @Binding var expanded: Bool
    @ObservedObject var vm: ChangesViewModel

    var body: some View {
        let files = folder.allFiles
        HStack(spacing: 6) {
            Button {
                expanded.toggle()
            } label: {
                Image(systemName: expanded ? "chevron.down" : "chevron.right")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .frame(width: 12)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            Toggle(sources: files.map { change in
                Binding(get: { vm.stagedPaths.contains(change.path) },
                        set: { on in vm.setStaged([change], on) })
            }, isOn: \.self) { EmptyView() }
            .toggleStyle(.checkbox)

            Image(systemName: "folder.fill")
                .font(.system(size: 11))
                .foregroundStyle(Color.yellow.opacity(0.85))
            Text(folder.name)
                .font(.system(size: 12))
                .lineLimit(1)
                .truncationMode(.middle)
            Text("\(files.count)")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
            Spacer()
        }
        .padding(.leading, CGFloat(depth) * 16)
        .padding(.vertical, 1)
        .contentShape(Rectangle())
        .onTapGesture(count: 2) { expanded.toggle() }
    }
}

/// The rows of one change group, flat or as a directory tree. `fileRow`
/// builds a file row at an indent level (callers add their list styling).
struct ChangeGroupRows<FileRow: View>: View {
    let files: [FileChange]
    let byDirectory: Bool
    @ObservedObject var vm: ChangesViewModel
    @Binding var collapsed: Set<String>
    let groupKey: String
    @ViewBuilder let fileRow: (FileChange, _ depth: Int, _ showDirectory: Bool) -> FileRow

    var body: some View {
        if byDirectory {
            ForEach(ChangeTreeRow.rows(ChangeFolder.tree(files), collapsed: scopedCollapsed)) { row in
                switch row {
                case .folder(let folder, let depth):
                    ChangeFolderRow(folder: folder, depth: depth, expanded: expanded(folder.id), vm: vm)
                        .selectionDisabled()
                case .file(let change, let depth):
                    fileRow(change, depth, false)
                }
            }
        } else {
            ForEach(files) { change in fileRow(change, 0, true) }
        }
    }

    /// Collapsed folder ids of this group (the set is shared by both groups).
    private var scopedCollapsed: Set<String> {
        Set(collapsed.compactMap { key in
            key.hasPrefix(groupKey + ":") ? String(key.dropFirst(groupKey.count + 1)) : nil
        })
    }

    private func expanded(_ id: String) -> Binding<Bool> {
        let key = "\(groupKey):\(id)"
        return Binding(get: { !collapsed.contains(key) },
                       set: { open in if open { collapsed.remove(key) } else { collapsed.insert(key) } })
    }
}

// MARK: - Expand / collapse all

extension ChangeGroup {
    /// Collapsed-folder keys (as `ChangeGroupRows` stores them) for every
    /// folder of every group — "Collapse All" in the directory view.
    static func allFolderKeys(_ changes: [FileChange]) -> Set<String> {
        var keys: Set<String> = []
        for group in allCases {
            for id in ChangeFolder.tree(group.filter(changes)).allFolderIDs {
                keys.insert("\(group.rawValue):\(id)")
            }
        }
        return keys
    }
}

/// Expand All / Collapse All buttons for a change list header.
struct ExpandCollapseButtons: View {
    let expandAll: () -> Void
    let collapseAll: () -> Void

    var body: some View {
        HStack(spacing: 2) {
            Button(action: expandAll) {
                Image(systemName: "rectangle.expand.vertical")
            }
            .help("Expand All")
            Button(action: collapseAll) {
                Image(systemName: "rectangle.compress.vertical")
            }
            .help("Collapse All")
        }
        .buttonStyle(.borderless)
    }
}
