import SwiftUI

struct FilesView: View {
    @EnvironmentObject var vm: FilesViewModel
    @State private var searchText = ""
    @State private var rootExpanded = true

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary).font(.caption)
                TextField("Filter files", text: $searchText)
                    .textFieldStyle(.plain)
                    .font(.system(size: 12))
                if !searchText.isEmpty {
                    Button { searchText = "" } label: {
                        Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary).font(.caption)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)

            Divider()

            if vm.fileTreeNodes.isEmpty {
                Text("No files")
                    .foregroundStyle(.secondary)
                    .font(.system(size: 12))
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        rootRow
                        if rootExpanded || !searchText.isEmpty {
                            ForEach(vm.fileTreeNodes) { node in
                                FileNodeView(node: node, depth: 1, query: searchText)
                            }
                        }
                    }
                    .padding(.vertical, 4)
                }
            }
        }
    }

    @ViewBuilder
    private var rootRow: some View {
        HStack(spacing: 4) {
            Image(systemName: (rootExpanded || !searchText.isEmpty) ? "chevron.down" : "chevron.right")
                .font(.system(size: 9, weight: .semibold))
                .foregroundStyle(.secondary)
                .frame(width: 12)
            Image(systemName: "folder.badge.gearshape")
                .font(.system(size: 12))
                .foregroundStyle(Color.accentColor)
                .frame(width: 16)
            Text(vm.repoName ?? "Repository")
                .font(.system(size: 12, weight: .semibold))
                .lineLimit(1)
            if let path = vm.repoDisplayPath {
                Text(path)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            Spacer()
        }
        .padding(.vertical, 3)
        .padding(.horizontal, 8)
        .frame(maxWidth: .infinity)
        .contentShape(Rectangle())
        .onTapGesture { rootExpanded.toggle() }
        .contextMenu {
            Button("New File…") { vm.newFile(in: nil) }
            Button("New Folder…") { vm.newFolder(in: nil) }
            Divider()
            Button("Reveal in Finder") { vm.revealRoot() }
            Button("Open in Terminal") { vm.openRootInTerminal() }
            Divider()
            Button("Copy Path") { vm.copyRootPath() }
            Divider()
            Button("Refresh") { Task { await vm.refreshFileTree() } }
        }
        .padding(.horizontal, 4)
    }
}

private struct FileNodeView: View {
    @ObservedObject var node: FileTreeNode
    let depth: Int
    let query: String
    @EnvironmentObject var vm: FilesViewModel
    @EnvironmentObject var editor: FileEditorViewModel

    private var showChildren: Bool { node.isExpanded || !query.isEmpty }

    private var visibleChildren: [FileTreeNode] {
        guard query.isEmpty else {
            return node.children.filter { nodeContainsQuery($0) }
        }
        return node.children
    }

    private func nodeContainsQuery(_ n: FileTreeNode) -> Bool {
        if n.name.localizedCaseInsensitiveContains(query) { return true }
        return n.children.contains { nodeContainsQuery($0) }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            FileRowView(node: node, depth: depth) {
                if node.isDirectory {
                    if !node.isLoaded {
                        Task { await vm.loadChildren(of: node) }
                    }
                    node.isExpanded.toggle()
                } else {
                    editor.openFile(node)
                }
            }

            if showChildren {
                ForEach(visibleChildren) { child in
                    FileNodeView(node: child, depth: depth + 1, query: query)
                }
            }
        }
    }
}

private struct FileRowView: View {
    @ObservedObject var node: FileTreeNode
    let depth: Int
    let onTap: () -> Void
    @State private var isHovered = false
    @EnvironmentObject var vm: FilesViewModel
    @EnvironmentObject var editor: FileEditorViewModel

    private var icon: String {
        if node.isDirectory {
            return node.isExpanded ? "folder.fill" : "folder"
        }
        return fileIcon(name: node.name)
    }

    private var iconColor: Color {
        if node.isDirectory { return Color.yellow.opacity(0.85) }
        return Color.secondary
    }

    var body: some View {
        HStack(spacing: 4) {
            Rectangle().fill(.clear).frame(width: CGFloat(depth) * 16)

            if node.isDirectory {
                Image(systemName: node.isExpanded ? "chevron.down" : "chevron.right")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .frame(width: 12)
            } else {
                Rectangle().fill(.clear).frame(width: 12)
            }

            Image(systemName: icon)
                .font(.system(size: 12))
                .foregroundStyle(iconColor)
                .frame(width: 16)

            Text(node.name)
                .font(.system(size: 12))
                .lineLimit(1)

            Spacer()
        }
        .padding(.vertical, 3)
        .padding(.horizontal, 8)
        .frame(maxWidth: .infinity)
        .background(isHovered ? Color.accentColor.opacity(0.12) : Color.clear)
        .clipShape(RoundedRectangle(cornerRadius: 4))
        .contentShape(Rectangle())
        .onHover { isHovered = $0 }
        .onTapGesture(perform: onTap)
        .contextMenu { contextMenu }
        .padding(.horizontal, 4)
    }

    @ViewBuilder
    private var contextMenu: some View {
        if node.isDirectory {
            Button("New File…") { vm.newFile(in: node) }
            Button("New Folder…") { vm.newFolder(in: node) }
            Divider()
            Button(node.isExpanded ? "Collapse" : "Expand") {
                if !node.isLoaded { Task { await vm.loadChildren(of: node) } }
                node.isExpanded.toggle()
            }
            Divider()
        } else {
            Button("Open") { editor.openFile(node) }
            Divider()
        }
        Button("Reveal in Finder") { vm.revealInFinder(node) }
        if !node.isDirectory {
            Button("Open in Default App") { vm.openInDefaultApp(node) }
        }
        Button("Open in Terminal") { vm.openInTerminal(node) }

        Divider()

        Menu("Copy Path/Reference…") {
            Button("Copy Absolute Path") { vm.copyAbsolutePath(node) }
            Button("Copy Relative Path") { vm.copyRelativePath(node) }
            Button("Copy File Name") { vm.copyFileName(node) }
            if !node.isDirectory {
                Divider()
                Button("Copy File Contents") { vm.copyFileContents(node) }
            }
        }
    }

    private func fileIcon(name: String) -> String {
        let ext = (name as NSString).pathExtension.lowercased()
        switch ext {
        case "swift":                           return "swift"
        case "kt", "kts":                       return "k.square"
        case "py":                              return "p.square"
        case "js", "ts", "jsx", "tsx":          return "j.square"
        case "json":                            return "curlybraces"
        case "xml", "html":                     return "chevron.left.forwardslash.chevron.right"
        case "md", "txt":                       return "doc.text"
        case "png", "jpg", "jpeg", "svg", "pdf", "icns": return "photo"
        case "sh", "bash":                      return "terminal"
        default:                                return "doc"
        }
    }
}
