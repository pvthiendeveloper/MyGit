import SwiftUI

/// Stash tab: create a stash from current changes, and list existing stashes with
/// apply/pop/drop/clear plus expandable per-file diffs. Mirrors the changes list idioms.
struct StashPanelView: View {
    @ObservedObject var vm: StashViewModel

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            composer
            Divider()
            if vm.stashes.isEmpty {
                Text("No stashes")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .center)
                    .padding(.vertical, 12)
            } else {
                stashList
            }
        }
    }

    private var composer: some View {
        HStack(spacing: 6) {
            TextField("Stash message (optional)", text: $vm.newMessage)
                .textFieldStyle(.roundedBorder)
                .onSubmit { Task { await vm.createStash() } }
            Button("Stash All") { Task { await vm.createStash() } }
                .buttonStyle(.borderedProminent)
        }
    }

    private var stashList: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 0) {
                ForEach(vm.stashes) { stash in
                    StashRow(vm: vm, stash: stash)
                    Divider()
                }
            }
        }
        .frame(maxHeight: 240)
    }
}

private struct StashRow: View {
    @ObservedObject var vm: StashViewModel
    let stash: GitStash

    private static let dateFormat: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "d/M/yy, HH:mm"
        return f
    }()

    private var isExpanded: Bool { vm.expanded.contains(stash.index) }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            if isExpanded { files }
        }
    }

    private var header: some View {
        HStack(spacing: 8) {
            Button {
                vm.toggleExpanded(stash)
            } label: {
                Image(systemName: isExpanded ? "chevron.down" : "chevron.right")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .frame(width: 12)
            }
            .buttonStyle(.plain)

            VStack(alignment: .leading, spacing: 1) {
                Text(stash.message)
                    .font(.system(size: 12))
                    .lineLimit(1)
                HStack(spacing: 6) {
                    if let b = stash.branch {
                        Label(b, systemImage: "arrow.triangle.branch")
                            .font(.system(size: 10))
                            .foregroundStyle(.secondary)
                    }
                    Text(Self.dateFormat.string(from: stash.date))
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                }
            }
            Spacer()
            Text(stash.ref)
                .font(.system(size: 10, design: .monospaced))
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .contentShape(Rectangle())
        .onTapGesture { vm.toggleExpanded(stash) }
        .contextMenu { rowMenu }
    }

    @ViewBuilder
    private var rowMenu: some View {
        Button("Pop") { Task { await vm.pop(stash) } }
        Button("Apply") { Task { await vm.apply(stash) } }
        Divider()
        Button("Drop") { Task { await vm.drop(stash) } }
        Button("Clear All…") { Task { await vm.clearAll() } }
    }

    @ViewBuilder
    private var files: some View {
        let list = vm.files[stash.index]
        if let list, !list.isEmpty {
            ForEach(list, id: \.self) { path in
                Button {
                    vm.showDiff(stash, path: path, forceNew: false)
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: "doc.text")
                            .font(.system(size: 10))
                            .foregroundStyle(.secondary)
                        Text(path)
                            .font(.system(size: 11, design: .monospaced))
                            .lineLimit(1)
                            .truncationMode(.middle)
                        Spacer()
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .padding(.leading, 28)
                .padding(.trailing, 8)
                .padding(.vertical, 2)
                .contextMenu {
                    Button("Show Diff") { vm.showDiff(stash, path: path, forceNew: false) }
                    Button("Show Diff in a New Tab") { vm.showDiff(stash, path: path, forceNew: true) }
                }
            }
        } else {
            Text(list == nil ? "Loading…" : "No files")
                .font(.system(size: 10))
                .foregroundStyle(.secondary)
                .padding(.leading, 28)
                .padding(.vertical, 2)
        }
    }
}
