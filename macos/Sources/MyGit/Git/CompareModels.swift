import Foundation

struct ComparePair: Identifiable {
    let id = UUID()
    let a: String
    let b: String
}

enum CompareSide { case aMinusB, bMinusA }

enum CompareSort { case newestFirst, oldestFirst }

struct CompareFilter: Equatable {
    var text: String = ""
    var author: String? = nil
    var dateFrom: Date? = nil
    var dateTo: Date? = nil
    var paths: [String] = []
    var sort: CompareSort = .newestFirst
}

enum ChangedFileStatus: String {
    case added = "A"
    case modified = "M"
    case deleted = "D"
    case renamed = "R"
    case copied = "C"
    case typeChanged = "T"
    case unknown = "?"
}

struct ChangedFileEntry: Identifiable, Hashable {
    var id: String { (oldPath.map { "\($0)→" } ?? "") + path }
    let path: String
    let oldPath: String?
    let status: ChangedFileStatus

    var displayName: String {
        if let old = oldPath {
            return "\(old) → \(path)"
        }
        return path
    }

    var statusGlyph: String {
        switch status {
        case .added: return "A"
        case .modified: return "M"
        case .deleted: return "D"
        case .renamed: return "R"
        case .copied: return "C"
        case .typeChanged: return "T"
        case .unknown: return "?"
        }
    }

    var statusColor: String { status == .deleted ? "red" : status == .added ? "green" : "secondary" }
}

final class ChangedFileNode: Identifiable {
    let id: String
    let name: String
    let entry: ChangedFileEntry?
    var children: [ChangedFileNode]?

    init(id: String, name: String, entry: ChangedFileEntry? = nil, children: [ChangedFileNode]? = nil) {
        self.id = id
        self.name = name
        self.entry = entry
        self.children = children
    }
}

struct OpenFileDiff: Identifiable {
    let id = UUID()
    let entry: ChangedFileEntry
    let diff: FileDiff
}

// Build a hierarchical tree from a flat list of file paths
enum ChangedFileTreeBuilder {
    static func build(from entries: [ChangedFileEntry]) -> [ChangedFileNode] {
        var root: [String: ChangedFileNode] = [:]
        var rootOrder: [String] = []

        for entry in entries {
            let components = entry.path.components(separatedBy: "/")
            insert(components: components, fullPath: entry.path, entry: entry,
                   into: &root, order: &rootOrder)
        }

        return rootOrder.compactMap { root[$0] }.map { sort($0) }
    }

    private static func insert(
        components: [String],
        fullPath: String,
        entry: ChangedFileEntry,
        into dict: inout [String: ChangedFileNode],
        order: inout [String]
    ) {
        guard let first = components.first else { return }
        let rest = Array(components.dropFirst())

        if rest.isEmpty {
            let node = ChangedFileNode(id: fullPath, name: first, entry: entry, children: nil)
            if dict[first] == nil { order.append(first) }
            dict[first] = node
        } else {
            if dict[first] == nil {
                dict[first] = ChangedFileNode(id: first, name: first, entry: nil, children: [])
                order.append(first)
            }
            let parent = dict[first]!
            if parent.children == nil { parent.children = [] }
            var childDict: [String: ChangedFileNode] = Dictionary(
                uniqueKeysWithValues: (parent.children ?? []).map { ($0.name, $0) }
            )
            var childOrder = (parent.children ?? []).map { $0.name }
            insert(components: rest, fullPath: fullPath, entry: entry,
                   into: &childDict, order: &childOrder)
            parent.children = childOrder.compactMap { childDict[$0] }
        }
    }

    private static func sort(_ node: ChangedFileNode) -> ChangedFileNode {
        guard var children = node.children else { return node }
        children.sort {
            let aIsDir = $0.children != nil
            let bIsDir = $1.children != nil
            if aIsDir != bIsDir { return aIsDir }
            return $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending
        }
        node.children = children.map { sort($0) }
        return node
    }
}
