import AppKit
import SwiftUI

/// Standalone "Merge Revisions" window (JetBrains-style 3-pane editor) for one
/// conflicted text file. One window per (bundle, path); reused if already open.
@MainActor
final class MergeEditorWindow: NSObject, NSWindowDelegate {
    private static var instances: [String: MergeEditorWindow] = [:]
    private var window: NSWindow?
    private var key: String?

    static func open(bundle: RepoBundle, change: FileChange, ours: String, theirs: String) {
        let key = "\(ObjectIdentifier(bundle))#\(change.path)"
        if let existing = instances[key]?.window {
            existing.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }
        Task {
            guard let stages = await bundle.changes.mergeStages(change) else { return }
            let instance = MergeEditorWindow()
            instance.key = key
            let root = MergeRevisionsView(
                path: change.path,
                oursLabel: ours,
                theirsLabel: theirs,
                baseText: stages.base,
                oursText: stages.ours,
                theirsText: stages.theirs,
                onApply: { [weak instance] content in
                    await bundle.changes.applyMergeResult(change, content: content)
                    instance?.window?.close()
                },
                onCancel: { [weak instance] in instance?.window?.close() }
            )
            let hosting = NSHostingController(rootView: root)
            let win = NSWindow(contentViewController: hosting)
            win.title = "Merge Revisions for \(change.path)"
            win.styleMask = [.titled, .closable, .resizable, .miniaturizable]
            win.delegate = instance
            win.setContentSize(NSSize(width: 1100, height: 640))
            win.center()
            win.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            instance.window = win
            instances[key] = instance
        }
    }

    func windowWillClose(_ notification: Notification) {
        if let key { MergeEditorWindow.instances[key] = nil }
        window = nil
    }
}
