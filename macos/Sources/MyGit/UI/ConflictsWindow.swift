import AppKit
import SwiftUI

/// Standalone "Conflicts" window (JetBrains-style) shown when a merge leaves the
/// repo mid-merge with conflicts — instead of dumping git's raw hint into an error
/// dialog. One per repo bundle; reused if already open.
@MainActor
final class ConflictsWindow: NSObject, NSWindowDelegate {
    private static var instances: [ObjectIdentifier: ConflictsWindow] = [:]
    private var window: NSWindow?
    private var key: ObjectIdentifier?

    static func open(bundle: RepoBundle, ours: String, theirs: String) {
        let key = ObjectIdentifier(bundle)
        if let existing = instances[key]?.window {
            existing.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }
        let instance = ConflictsWindow()
        instance.key = key
        let root = ConflictsView(bundle: bundle, ours: ours, theirs: theirs) { [weak instance] in
            instance?.window?.close()
        }
        .environmentObject(bundle.changes)

        let hosting = NSHostingController(rootView: root)
        let win = NSWindow(contentViewController: hosting)
        win.title = "Conflicts"
        win.styleMask = [.titled, .closable, .resizable]
        win.delegate = instance
        win.setContentSize(NSSize(width: 780, height: 480))
        win.center()
        win.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        instance.window = win
        instances[key] = instance
    }

    func windowWillClose(_ notification: Notification) {
        if let key { ConflictsWindow.instances[key] = nil }
        window = nil
    }
}

struct ConflictsView: View {
    @EnvironmentObject var changes: ChangesViewModel
    let bundle: RepoBundle
    let ours: String
    let theirs: String
    var onClose: () -> Void

    @State private var selection: FileChange.ID?
    @State private var groupByDir = false
    @State private var mergeableSelected = false

    private var conflicts: [FileChange] {
        (changes.status?.changes ?? []).filter { $0.isConflicted }
    }
    private var selected: FileChange? {
        conflicts.first { $0.id == selection }
    }
    private var isCherryPick: Bool { changes.status?.cherryPickInProgress == true }
    private var isRebase: Bool { changes.status?.rebaseInProgress == true }

    var body: some View {
        VStack(spacing: 0) {
            if conflicts.isEmpty {
                resolvedState
            } else {
                HStack(alignment: .top, spacing: 12) {
                    conflictTable
                    sideButtons
                }
                .padding(12)
            }
            Divider()
            footer
        }
        .frame(minWidth: 640, minHeight: 380)
        // Merge/cherry-pick finished or aborted elsewhere -> nothing left to
        // resolve, close.
        .onChange(of: changes.status?.operationInProgress) { _, running in
            if running == false { onClose() }
        }
        // Merge editor only applies to text files; gitlink/binary -> disabled.
        .task(id: selection) {
            guard let s = selected else { mergeableSelected = false; return }
            mergeableSelected = await changes.isMergeableText(s)
        }
    }

    private var conflictTable: some View {
        Table(conflicts, selection: $selection) {
            TableColumn("Name") { c in
                HStack(spacing: 6) {
                    Image(systemName: "doc.text")
                        .foregroundStyle(.secondary)
                    Text(c.path).lineLimit(1).truncationMode(.middle)
                }
            }
            TableColumn("Yours (\(ours))") { c in
                Text(sideLabel(c, ours: true)).foregroundStyle(.secondary)
            }
            .width(min: 90)
            TableColumn("Theirs (\(theirs))") { c in
                Text(sideLabel(c, ours: false)).foregroundStyle(.secondary)
            }
            .width(min: 90)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var sideButtons: some View {
        VStack(spacing: 8) {
            conflictButton("Accept Yours") { resolve(.ours) }
            conflictButton("Accept Theirs") { resolve(.theirs) }
            Button {
                if let s = selected {
                    MergeEditorWindow.open(bundle: bundle, change: s, ours: ours, theirs: theirs)
                }
            } label: {
                Text("Merge…").frame(maxWidth: .infinity)
            }
            .controlSize(.large)
            .disabled(selected == nil || !mergeableSelected)
            .help(mergeableSelected ? "Open 3-way merge editor" : "Only text files can be merged")
            Spacer()
        }
        .frame(width: 150)
    }

    // Uniform-width side button: every button fills the fixed side column.
    private func conflictButton(_ title: String, _ action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title).frame(maxWidth: .infinity)
        }
        .controlSize(.large)
        .disabled(selected == nil)
    }

    private var resolvedState: some View {
        VStack(spacing: 12) {
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 40))
                .foregroundStyle(.green)
            Text("All conflicts resolved").font(.headline)
            Text(isRebase || isCherryPick
                 ? "Continue to finish the \(isRebase ? "rebase" : "cherry-pick")."
                 : "Commit to finish the merge.")
                .font(.subheadline).foregroundStyle(.secondary)
            // Rebase/cherry-pick finish through the sequencer, not a merge commit.
            Button(isRebase ? "Continue Rebase" : (isCherryPick ? "Continue Cherry-Pick" : "Commit Merge")) {
                Task {
                    if isRebase { await changes.continueRebase() }
                    else if isCherryPick { await changes.continueCherryPick() }
                    else { await changes.commitMerge() }
                    onClose()
                }
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(24)
    }

    private var footer: some View {
        HStack {
            Toggle("Group files by directory", isOn: $groupByDir)
                .toggleStyle(.checkbox)
                .disabled(true)
            Spacer()
            Button("Close") { onClose() }
                .keyboardShortcut(.cancelAction)
        }
        .padding(12)
    }

    private func resolve(_ side: ConflictSide) {
        guard let s = selected else { return }
        Task { await changes.resolveConflict(s, using: side) }
    }

    // Map porcelain unmerged XY codes to a per-side status label.
    private func sideLabel(_ c: FileChange, ours: Bool) -> String {
        switch (c.indexStatus, c.worktreeStatus) {
        case ("U", "U"): return "Modified"
        case ("A", "A"): return "Added"
        case ("D", "D"): return "Deleted"
        case ("A", "U"): return ours ? "Added" : "—"
        case ("U", "A"): return ours ? "—" : "Added"
        case ("D", "U"): return ours ? "Deleted" : "Modified"
        case ("U", "D"): return ours ? "Modified" : "Deleted"
        default: return "Modified"
        }
    }
}
