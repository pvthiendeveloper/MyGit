import Foundation
import SwiftTerm

/// One shell session backed by a SwiftTerm `LocalProcessTerminalView` (its own
/// PTY + xterm emulator). The view is retained here so a session keeps running
/// while its tab is in the background; dropping the session closes the PTY
/// master, which SIGHUPs the child shell.
final class TerminalSession: NSObject, ObservableObject, Identifiable, LocalProcessTerminalViewDelegate {
    let id = UUID()
    let view: LocalProcessTerminalView
    /// Folder name, shown as the tab label; overridden live by the shell's own
    /// window-title escape sequences when it emits them.
    @Published var title: String
    @Published private(set) var isRunning = true

    init(cwd: URL, index: Int) {
        view = LocalProcessTerminalView(frame: CGRect(x: 0, y: 0, width: 640, height: 320))
        let leaf = cwd.lastPathComponent
        title = leaf.isEmpty ? "shell" : leaf
        super.init()
        view.processDelegate = self

        let env = Terminal.getEnvironmentVariables(termName: "xterm-256color", trueColor: true)
        let shell = ProcessInfo.processInfo.environment["SHELL"] ?? "/bin/zsh"
        let shellLeaf = (shell as NSString).lastPathComponent
        let dir = FileManager.default.fileExists(atPath: cwd.path) ? cwd.path : nil
        // execName with a leading "-" makes it a login shell so the user's
        // profile (PATH, aliases) loads, matching VS Code / Terminal.app.
        view.startProcess(executable: shell, args: [], environment: env, execName: "-\(shellLeaf)", currentDirectory: dir)
    }

    // MARK: LocalProcessTerminalViewDelegate

    func sizeChanged(source: LocalProcessTerminalView, newCols: Int, newRows: Int) {}

    func setTerminalTitle(source: LocalProcessTerminalView, title: String) {
        guard !title.isEmpty else { return }
        self.title = title
    }

    func hostCurrentDirectoryUpdate(source: TerminalView, directory: String?) {}

    func processTerminated(source: TerminalView, exitCode: Int32?) {
        isRunning = false
        title += " — exited"
    }
}

/// Shared, workspace-global state for the bottom terminal panel — visibility and
/// the open tab list. New tabs open in the caller-supplied cwd (the active repo).
@MainActor
final class TerminalViewModel: ObservableObject {
    @Published var isVisible = false
    @Published private(set) var sessions: [TerminalSession] = []
    @Published var activeID: UUID?

    var active: TerminalSession? { sessions.first { $0.id == activeID } }

    /// Toggle the panel. Opening with no tabs spawns the first one.
    func toggle(cwd: URL) {
        if isVisible {
            isVisible = false
        } else {
            isVisible = true
            if sessions.isEmpty { newSession(cwd: cwd) }
        }
    }

    @discardableResult
    func newSession(cwd: URL) -> TerminalSession {
        let session = TerminalSession(cwd: cwd, index: sessions.count)
        sessions.append(session)
        activeID = session.id
        isVisible = true
        return session
    }

    func select(_ id: UUID) { activeID = id }

    func close(_ id: UUID) {
        guard let index = sessions.firstIndex(where: { $0.id == id }) else { return }
        sessions.remove(at: index)
        if activeID == id {
            let next = min(index, sessions.count - 1)
            activeID = next >= 0 ? sessions[next].id : nil
        }
        if sessions.isEmpty { isVisible = false }
    }
}
