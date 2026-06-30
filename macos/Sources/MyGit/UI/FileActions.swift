import AppKit
import Foundation

/// Shared file-level actions used by tab context menus (file editor tabs + diff tabs).
enum FileActions {
    static func copyToPasteboard(_ string: String) {
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString(string, forType: .string)
    }

    static func reveal(absPath: String) {
        let url = URL(fileURLWithPath: absPath)
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }

    static func openDefault(absPath: String) {
        NSWorkspace.shared.open(URL(fileURLWithPath: absPath))
    }

    /// Opens the given directory in Terminal.app.
    static func openTerminal(dir: String) {
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/usr/bin/open")
        task.arguments = ["-a", "Terminal", dir]
        try? task.run()
    }
}
