import SwiftUI

struct CompareChangedFilesTree: View {
    let nodes: [ChangedFileNode]
    let onSelect: (ChangedFileEntry) -> Void

    var body: some View {
        if nodes.isEmpty {
            Text("Select a commit to see changed files")
                .foregroundStyle(.secondary)
                .font(.caption)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
        } else {
            List(nodes, children: \.optionalChildren) { node in
                CompareFileNodeRow(node: node)
                    .contentShape(Rectangle())
                    .onTapGesture {
                        if let entry = node.entry {
                            onSelect(entry)
                        }
                    }
            }
            .listStyle(.inset)
        }
    }
}

private struct CompareFileNodeRow: View {
    let node: ChangedFileNode

    var body: some View {
        HStack(spacing: 6) {
            if node.children != nil {
                Image(systemName: "folder.fill")
                    .foregroundStyle(.secondary)
                    .font(.caption)
            } else if let entry = node.entry {
                Text(entry.statusGlyph)
                    .font(.system(size: 10, weight: .bold, design: .monospaced))
                    .foregroundStyle(statusColor(entry.status))
                    .frame(width: 14, alignment: .center)
            }
            if let entry = node.entry, let old = entry.oldPath {
                Text("\(old.lastPathComponent) → \(node.name)")
                    .font(.system(size: 12))
                    .lineLimit(1)
            } else {
                Text(node.name)
                    .font(.system(size: 12))
                    .lineLimit(1)
            }
        }
        .padding(.vertical, 1)
    }

    private func statusColor(_ status: ChangedFileStatus) -> Color {
        switch status {
        case .added: return .green
        case .deleted: return .red
        case .renamed, .copied: return .blue
        default: return .secondary
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
