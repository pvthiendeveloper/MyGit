import Foundation
import AppKit
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

    /// Local scroll-wheel monitor. SwiftTerm's own wheel handler only scrolls
    /// scrollback, which the alternate screen buffer (Claude Code, vim, less,
    /// htop) doesn't have — so the wheel is dead there. This translates the wheel
    /// into arrow-key presses while an alt-buffer TUI is up and isn't doing its
    /// own mouse reporting, matching iTerm2/Terminal.app "alternate scroll mode".
    private var scrollMonitor: Any?

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

        scrollMonitor = NSEvent.addLocalMonitorForEvents(matching: .scrollWheel) { [weak self] event in
            self?.handleScroll(event) ?? event
        }
    }

    deinit {
        if let scrollMonitor { NSEvent.removeMonitor(scrollMonitor) }
    }

    /// Returns nil to swallow the wheel event (we handled it by sending arrows),
    /// or the event unchanged to let SwiftTerm's default scrollback handling run.
    private func handleScroll(_ event: NSEvent) -> NSEvent? {
        // Only when the pointer is over this session's live view.
        guard let window = view.window, event.window === window,
              window.contentView?.hitTest(event.locationInWindow).map({ $0 === view || $0.isDescendant(of: view) }) == true,
              let term = view.terminal, event.deltaY != 0 else { return event }

        let velocity = max(1, min(Int(abs(event.deltaY).rounded()), 5))
        let up = event.deltaY > 0

        // App requested mouse reporting (Claude Code, htop, tmux): SwiftTerm's own
        // wheel handler only touches scrollback, so forward the wheel as real mouse
        // wheel events (buttons 4/5) via the app's negotiated mouse protocol.
        if term.mouseMode != .off {
            let (col, row) = cellCoord(for: event, cols: term.cols, rows: term.rows)
            let flags = term.encodeButton(button: up ? 4 : 5, release: false,
                                          shift: false, meta: false, control: false)
            for _ in 0..<velocity { term.sendEvent(buttonFlags: flags, x: col, y: row) }
            return nil
        }

        // No mouse reporting: only the alt buffer lacks scrollback, so translate
        // the wheel into arrow keys there; leave the normal buffer to scrollback.
        guard term.isCurrentBufferAlternate else { return event }
        let seq: [UInt8] = term.applicationCursor
            ? (up ? EscapeSequences.moveUpApp : EscapeSequences.moveDownApp)
            : (up ? EscapeSequences.moveUpNormal : EscapeSequences.moveDownNormal)
        for _ in 0..<velocity { view.send(seq) }
        return nil
    }

    /// Terminal cell (col,row) under the pointer, for mouse-event reporting.
    private func cellCoord(for event: NSEvent, cols: Int, rows: Int) -> (Int, Int) {
        let p = view.convert(event.locationInWindow, from: nil)
        let cw = max(1, view.bounds.width / CGFloat(cols))
        let ch = max(1, view.bounds.height / CGFloat(rows))
        let yTop = view.isFlipped ? p.y : (view.bounds.height - p.y)
        let col = min(cols - 1, max(0, Int(p.x / cw)))
        let row = min(rows - 1, max(0, Int(yTop / ch)))
        return (col, row)
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

/// Which browser a run-script action should hand off to. Tools that open a URL
/// during a run (e.g. `aws sso login`, which goes through Python's `webbrowser`
/// module) honour the `$BROWSER` env var; we export it for the run's subshell.
enum ScriptBrowser: String, CaseIterable, Identifiable {
    case systemDefault
    case safari
    case chrome

    var id: String { rawValue }

    var label: String {
        switch self {
        case .systemDefault: return "System Default"
        case .safari: return "Safari"
        case .chrome: return "Google Chrome"
        }
    }

    /// `$BROWSER` value that forces this browser; nil leaves it unset so the OS
    /// default browser is used. `%s` is where `webbrowser` substitutes the URL.
    var browserEnv: String? {
        switch self {
        case .systemDefault: return nil
        case .safari: return "open -a Safari %s"
        case .chrome: return "open -a \"Google Chrome\" %s"
        }
    }
}

/// Shared, workspace-global state for the bottom terminal panel — visibility and
/// the open tab list. New tabs open in the caller-supplied cwd (the active repo).
@MainActor
final class TerminalViewModel: ObservableObject {
    private static let scriptBrowserKey = "MyGit.scriptBrowser"

    @Published var isVisible = false
    @Published private(set) var sessions: [TerminalSession] = []
    @Published var activeID: UUID?

    /// Remembered browser for the run-script button, persisted across launches.
    @Published var scriptBrowser: ScriptBrowser =
        ScriptBrowser(rawValue: UserDefaults.standard.string(forKey: scriptBrowserKey) ?? "")
            ?? .systemDefault
    {
        didSet { UserDefaults.standard.set(scriptBrowser.rawValue, forKey: Self.scriptBrowserKey) }
    }

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

    /// Runs a shell script in the terminal panel, IntelliJ-style: reveals the
    /// panel, reuses the active session (or spawns one), and feeds a command that
    /// runs the script from its own directory in a subshell — so the interactive
    /// session's own cwd is left untouched. `$SHELL` typing keeps the user's PATH.
    func runShellScript(absolutePath: String, browser: ScriptBrowser = .systemDefault) {
        let url = URL(fileURLWithPath: absolutePath)
        let dir = url.deletingLastPathComponent()
        let name = url.lastPathComponent
        isVisible = true
        let session = active ?? newSession(cwd: dir)
        let interpreter = name.hasSuffix(".sh") ? "bash " : ""
        // Scope the browser override to the run's subshell only, so the
        // interactive session's own $BROWSER is left untouched.
        let browserPrefix = browser.browserEnv.map { "export BROWSER=\(Self.shellQuote($0)); " } ?? ""
        let command = "(\(browserPrefix)cd \(Self.shellQuote(dir.path)) && \(interpreter)\(Self.shellQuote(name)))\n"
        session.view.send(txt: command)
        DispatchQueue.main.async { session.view.window?.makeFirstResponder(session.view) }
    }

    /// Single-quote a path for safe shell interpolation.
    private static func shellQuote(_ s: String) -> String {
        "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'"
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
