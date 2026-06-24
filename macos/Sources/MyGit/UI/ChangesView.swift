import SwiftUI

struct ChangesListView: View {
    @EnvironmentObject var vm: ChangesViewModel

    private var changes: [FileChange] { vm.status?.changes ?? [] }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            if changes.isEmpty {
                ScrollView { Text("No local changes")
                    .foregroundStyle(.secondary)
                    .padding(20)
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
            } else {
                List(selection: $vm.selectedChange) {
                    ForEach(changes) { change in
                        ChangeRow(change: change)
                            .tag(change as FileChange?)
                    }
                }
                .listStyle(.inset)
            }
        }
    }

    private var header: some View {
        HStack(spacing: 8) {
            Toggle(isOn: Binding(
                get: { !changes.isEmpty && changes.allSatisfy { vm.stagedPaths.contains($0.path) } },
                set: { vm.setAllStaged($0) }
            )) { EmptyView() }
            .toggleStyle(.checkbox)

            Text("\(changes.count) changed file\(changes.count == 1 ? "" : "s")")
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(.secondary)
            Spacer()
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }
}

private struct ChangeRow: View {
    @EnvironmentObject var vm: ChangesViewModel
    let change: FileChange

    var body: some View {
        HStack(spacing: 8) {
            Toggle(isOn: Binding(
                get: { vm.stagedPaths.contains(change.path) },
                set: { _ in vm.toggleStaged(change) }
            )) { EmptyView() }
            .toggleStyle(.checkbox)

            Text(change.path)
                .font(.system(size: 12))
                .lineLimit(1)
                .truncationMode(.middle)

            Spacer(minLength: 4)

            Text(change.glyph)
                .font(.system(size: 11, weight: .bold, design: .monospaced))
                .foregroundStyle(colorForKind(change.kind))
                .frame(width: 16, alignment: .trailing)
        }
        .contentShape(Rectangle())
    }

    private func colorForKind(_ k: FileChangeKind) -> Color {
        switch k {
        case .added, .untracked: return .green
        case .deleted: return .red
        case .modified: return .yellow
        case .renamed, .copied: return .blue
        case .conflict: return .orange
        }
    }
}
