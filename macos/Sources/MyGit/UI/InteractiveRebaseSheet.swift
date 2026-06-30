import SwiftUI

/// Editor for "Interactively Rebase from Here…". Lists commits from the picked
/// commit up to HEAD (oldest first) with a per-commit action, then runs the
/// rebase. Reword keeps the existing message (use Edit Commit Message to change
/// text); this sheet handles pick / squash / fixup / drop ordering.
struct InteractiveRebaseSheet: View {
    let commit: GitCommit
    @ObservedObject var vm: HistoryViewModel
    @Environment(\.dismiss) private var dismiss

    @State private var rows: [RebaseRow] = []

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Interactive Rebase").font(.headline)
            Text("Oldest first. Squash/fixup merges into the commit above.")
                .font(.caption).foregroundStyle(.secondary)

            List {
                ForEach($rows) { $row in
                    HStack(spacing: 10) {
                        Picker("", selection: $row.action) {
                            ForEach(RebaseRow.Action.allCases) { a in
                                Text(a.rawValue.capitalized).tag(a)
                            }
                        }
                        .labelsHidden().frame(width: 110)

                        Text(row.commit.shortHash)
                            .font(.system(.caption, design: .monospaced))
                            .foregroundStyle(.secondary)
                        Text(row.commit.subject).lineLimit(1)
                        Spacer()
                    }
                }
            }
            .frame(width: 620, height: 360)

            HStack {
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }
                Button("Start Rebase") {
                    vm.applyRebase(from: commit, rows: rows)
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(rows.isEmpty)
            }
        }
        .padding(20)
        .task { rows = await vm.rebaseRows(from: commit) }
    }
}
