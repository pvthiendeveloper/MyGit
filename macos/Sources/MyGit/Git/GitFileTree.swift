import Foundation

final class FileTreeNode: Identifiable, ObservableObject {
    let id: String          // full path from repo root
    let name: String
    let isDirectory: Bool
    @Published var children: [FileTreeNode] = []
    @Published var isExpanded: Bool = false
    @Published var isLoading: Bool = false
    var isLoaded: Bool = false

    init(id: String, name: String, isDirectory: Bool) {
        self.id = id
        self.name = name
        self.isDirectory = isDirectory
    }
}

enum GitFileTree {
    // Parse `git ls-tree HEAD [path]` output (non-recursive).
    // Format per line: "<mode> <type> <sha>\t<path>"
    // `path` from git is the full path from repo root (e.g. "src/foo.swift").
    static func parse(output: String) -> [FileTreeNode] {
        var dirs: [FileTreeNode] = []
        var files: [FileTreeNode] = []

        for line in output.split(separator: "\n", omittingEmptySubsequences: true) {
            let parts = line.split(separator: "\t", maxSplits: 1)
            guard parts.count == 2 else { continue }
            let meta = parts[0].split(separator: " ")
            guard meta.count >= 2 else { continue }
            let type = String(meta[1])   // "blob" or "tree"
            let fullPath = String(parts[1])
            let leaf: String
            if let slash = fullPath.lastIndex(of: "/") {
                leaf = String(fullPath[fullPath.index(after: slash)...])
            } else {
                leaf = fullPath
            }
            let node = FileTreeNode(id: fullPath, name: leaf, isDirectory: type == "tree")
            if type == "tree" { dirs.append(node) } else { files.append(node) }
        }
        return dirs.sorted { $0.name < $1.name } + files.sorted { $0.name < $1.name }
    }
}
