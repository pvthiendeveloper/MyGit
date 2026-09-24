import AppKit
import Combine
import SwiftUI

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var window: NSWindow?
    private let coordinator = AppCoordinator(container: .live())

    // Double-Shift ("Search Everywhere") detection.
    private var lastShiftTap: TimeInterval = 0
    private var flagsMonitor: Any?
    private var keyMonitor: Any?
    private var mouseMonitor: Any?
    private var shortcutsSink: AnyCancellable?

    /// SIGTERM (`killall`, as run.sh does before relaunching) skips
    /// `applicationWillTerminate`; route it through a normal quit so sessions
    /// are saved and the Claude Code lock file is removed.
    private var terminationSignal: DispatchSourceSignal?

    private func handleSIGTERM() {
        signal(SIGTERM, SIG_IGN)
        let source = DispatchSource.makeSignalSource(signal: SIGTERM, queue: .main)
        source.setEventHandler { NSApp.terminate(nil) }
        source.resume()
        terminationSignal = source
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        handleSIGTERM()
        installMainMenu()
        // Settings ▸ Keyboard Shortcuts: rebuild the menu bar with the new keys
        // (objectWillChange fires before the change lands, hence the hop).
        shortcutsSink = ShortcutSettings.shared.objectWillChange.sink { [weak self] _ in
            DispatchQueue.main.async { self?.installMainMenu() }
        }
        installSearchEverywhereShortcut()
        installNavigationHistoryShortcuts()

        let root = RootView()
            .environmentObject(coordinator)
            .frame(minWidth: 900, minHeight: 560)

        let hosting = NSHostingController(rootView: root)
        let win = NSWindow(contentViewController: hosting)
        win.title = "MyGit"
        win.setContentSize(NSSize(width: 1180, height: 720))
        win.styleMask = [.titled, .closable, .miniaturizable, .resizable]
        win.titlebarAppearsTransparent = false
        win.center()
        win.setFrameAutosaveName("MyGit.MainWindow")
        win.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        self.window = win
        // TEMP BENCH HOOK
        if ProcessInfo.processInfo.environment["MYGIT_DEBUG_EXPAND"] != nil {
            DispatchQueue.main.asyncAfter(deadline: .now() + 4) { [coordinator] in
                Task { @MainActor in
                    coordinator.main.tab = .files
                    let vm = coordinator.activeBundle.files
                    func expand(_ nodes: [FileTreeNode], depth: Int) async {
                        for n in nodes where n.isDirectory {
                            if !n.isLoaded { await vm.loadChildren(of: n) }
                            n.isExpanded = true
                            if depth < 8 { await expand(n.children, depth: depth + 1) }
                        }
                    }
                    await vm.refreshFileTree()
                    await expand(vm.fileTreeNodes, depth: 0)
                    var count = 0
                    func walk(_ nodes: [FileTreeNode]) { for n in nodes { count += 1; if n.isExpanded { walk(n.children) } } }
                    walk(vm.fileTreeNodes)
                    try? "EXPANDED rows=\(count)\n".data(using: .utf8)?.write(to: URL(fileURLWithPath: "/tmp/mygit-expand.log"))
                }
            }
        }
        if ProcessInfo.processInfo.environment["MYGIT_DEBUG_INSPECTOR"] != nil {
            DispatchQueue.main.asyncAfter(deadline: .now() + 1) { [coordinator] in UIInspectorWindow.open(sourceNavigator: coordinator) }
        }
        if let dbg = ProcessInfo.processInfo.environment["MYGIT_DEBUG_DIFF"] {
            DispatchQueue.main.asyncAfter(deadline: .now() + 3) { [coordinator] in
                coordinator.main.openDiffTab(commitHash: "HEAD", commitShortHash: "HEAD",
                                             path: dbg, mode: .commitVsWorking, forceNew: true)
            }
        }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }

    func applicationWillTerminate(_ notification: Notification) {
        coordinator.persistSessions()
        // Removes the lock file so Claude Code stops offering a dead MyGit.
        ClaudeIDEServer.shared.stop()
    }

    private func installMainMenu() {
        let main = NSMenu()
        main.addItem(appMenuItem())
        main.addItem(fileMenuItem())
        main.addItem(editMenuItem())
        main.addItem(viewMenuItem())
        main.addItem(repositoryMenuItem())
        main.addItem(windowMenuItem())
        NSApp.mainMenu = main
    }

    /// Build one menu item + submenu, wiring every entry's target to self.
    private func menu(_ title: String, _ entries: [MenuEntry]) -> NSMenuItem {
        let item = NSMenuItem()
        let submenu = NSMenu(title: title)
        for entry in entries {
            switch entry {
            case .separator:
                submenu.addItem(.separator())
            case let .action(title, selector, key, modifiers, target):
                let menuItem = NSMenuItem(title: title, action: selector, keyEquivalent: key)
                if let modifiers { menuItem.keyEquivalentModifierMask = modifiers }
                // A nil target means "walk the responder chain" — that's what
                // the Edit menu's text actions need.
                menuItem.target = target == .app ? self : nil
                submenu.addItem(menuItem)
            case let .shortcut(action, selector):
                let shortcut = ShortcutSettings.shared.shortcut(for: action)
                let menuItem = NSMenuItem(title: action.title, action: selector,
                                          keyEquivalent: shortcut?.key ?? "")
                menuItem.keyEquivalentModifierMask = shortcut?.modifiers ?? []
                menuItem.target = self
                submenu.addItem(menuItem)
            }
        }
        item.submenu = submenu
        return item
    }

    private enum MenuTarget { case app, responder }

    private enum MenuEntry {
        case separator
        case action(String, Selector, String, NSEvent.ModifierFlags?, MenuTarget)
        /// An app command whose key comes from Settings ▸ Keyboard Shortcuts.
        case shortcut(ShortcutAction, Selector)

        static func app(_ action: ShortcutAction, _ selector: Selector) -> MenuEntry {
            .shortcut(action, selector)
        }

        static func responder(_ title: String, _ selector: Selector,
                              _ key: String = "", _ modifiers: NSEvent.ModifierFlags? = nil) -> MenuEntry {
            .action(title, selector, key, modifiers, .responder)
        }
    }

    private func appMenuItem() -> NSMenuItem {
        menu("MyGit", [
            .responder("About MyGit", #selector(NSApplication.orderFrontStandardAboutPanel(_:))),
            .separator,
            .app(.openSettings, #selector(openSettings)),
            .separator,
            .responder("Hide MyGit", #selector(NSApplication.hide(_:)), "h"),
            .responder("Hide Others", #selector(NSApplication.hideOtherApplications(_:)), "h", [.command, .option]),
            .responder("Show All", #selector(NSApplication.unhideAllApplications(_:))),
            .separator,
            .responder("Quit MyGit", #selector(NSApplication.terminate(_:)), "q"),
        ])
    }

    private func fileMenuItem() -> NSMenuItem {
        menu("File", [
            .app(.addLocalRepository, #selector(addLocalRepository)),
            .app(.addRepositoryByPath, #selector(addRepositoryByPath)),
            .separator,
            .app(.closeTab, #selector(closeDetailTab)),
            .app(.reopenClosedTab, #selector(reopenClosedTab)),
            .separator,
            .app(.save, #selector(saveActiveFile)),
        ])
    }

    private func editMenuItem() -> NSMenuItem {
        // Undo/Redo are menu-driven on macOS: without these items ⌘Z never
        // reaches the focused text view's undo manager (`allowsUndo` alone
        // doesn't bind the key).
        menu("Edit", [
            .responder("Undo", Selector(("undo:")), "z"),
            .responder("Redo", Selector(("redo:")), "z", [.command, .shift]),
            .separator,
            .responder("Cut", #selector(NSText.cut(_:)), "x"),
            .responder("Copy", #selector(NSText.copy(_:)), "c"),
            .responder("Paste", #selector(NSText.paste(_:)), "v"),
            .responder("Select All", #selector(NSText.selectAll(_:)), "a"),
            .separator,
            .app(.find, #selector(findInFile)),
            .app(.findNext, #selector(findNext)),
            .app(.findPrevious, #selector(findPrevious)),
            .separator,
            // ⇧⌘F belongs to Repository ▸ Fetch; ⌘⇧O is the "open anything"
            // chord people already know from other editors.
            .app(.searchEverywhere, #selector(openSearchEverywhere)),
        ])
    }

    private func viewMenuItem() -> NSMenuItem {
        menu("View", [
            .app(.showChanges, #selector(showChangesTab)),
            .app(.showStash, #selector(showStashTab)),
            .app(.showHistory, #selector(showHistoryTab)),
            .app(.showFiles, #selector(showFilesTab)),
            .app(.showPullRequests, #selector(showPullRequestsTab)),
            .app(.showClaude, #selector(showClaudeTab)),
            .separator,
            .app(.revealActiveFile, #selector(revealActiveFile)),
            .separator,
            .app(.toggleTerminal, #selector(toggleTerminal)),
            .app(.newTerminal, #selector(newTerminal)),
            .app(.toggleBuildVariants, #selector(toggleBuildVariants)),
            .separator,
            .app(.uiInspector, #selector(openUIInspector)),
        ])
    }

    private func repositoryMenuItem() -> NSMenuItem {
        menu("Repository", [
            .app(.fetch, #selector(fetchOrigin)),
            .app(.pull, #selector(pullRemote)),
            .app(.push, #selector(pushRemote)),
            .separator,
            .app(.openInTerminal, #selector(openRepositoryInTerminal)),
            .app(.revealInFinder, #selector(revealRepositoryInFinder)),
        ])
    }

    private func windowMenuItem() -> NSMenuItem {
        let item = menu("Window", [
            .responder("Minimize", #selector(NSWindow.performMiniaturize(_:)), "m"),
            .responder("Zoom", #selector(NSWindow.performZoom(_:))),
            .separator,
            .responder("Bring All to Front", #selector(NSApplication.arrangeInFront(_:))),
        ])
        // Letting AppKit own this menu gives the window list for free.
        NSApp.windowsMenu = item.submenu
        return item
    }

    func validateMenuItem(_ item: NSMenuItem) -> Bool {
        if item.action == #selector(toggleTerminal) {
            item.state = coordinator.terminal.isVisible ? .on : .off
        }
        if item.action == #selector(revealActiveFile) {
            return coordinator.activeBundle.editor.activeFileTab != nil
        }
        for (selector, tab) in [
            (#selector(showChangesTab), MainViewModel.Tab.changes),
            (#selector(showStashTab), .stash),
            (#selector(showHistoryTab), .history),
            (#selector(showFilesTab), .files),
            (#selector(showPullRequestsTab), .pullRequests),
            (#selector(showClaudeTab), .claude),
        ] where item.action == selector {
            item.state = coordinator.main.tab == tab ? .on : .off
            return true
        }
        if item.action == #selector(findInFile) {
            return visibleEditorTab != nil
        }
        if item.action == #selector(findNext) || item.action == #selector(findPrevious) {
            return visibleEditorTab?.find.isVisible == true
        }
        if item.action == #selector(closeDetailTab) {
            if case .content = coordinator.main.detailTab { return false }
            return true
        }
        if item.action == #selector(saveActiveFile) {
            return coordinator.activeBundle.editor.activeFileTab?.isDirty == true
        }
        if item.action == #selector(reopenClosedTab) {
            return !coordinator.activeBundle.editor.closedPaths.isEmpty
        }
        if item.action == #selector(toggleBuildVariants) {
            let run = coordinator.activeBundle.run
            item.state = run.showVariantsPanel ? .on : .off
            return run.kind == .android
        }
        return true
    }

    // MARK: - Search Everywhere (double-Shift)

    private func installSearchEverywhereShortcut() {
        // A second Shift press within this window (with nothing typed between)
        // opens the overlay. Any other keystroke resets the sequence so it never
        // fires while shift-typing capitals.
        flagsMonitor = NSEvent.addLocalMonitorForEvents(matching: .flagsChanged) { [weak self] event in
            self?.handleFlagsChanged(event)
            return event
        }
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self else { return event }
            if self.handleNavigationHistoryKey(event) {
                self.lastShiftTap = 0
                return nil
            }
            // AI continuation (⌘⇧P by default) fires only while editing code —
            // the menu may own the same chord otherwise (Repository ▸ Pull), and
            // menu key equivalents run before the text view ever sees the key.
            if ShortcutSettings.shared.shortcut(for: .aiSuggest)?.matches(event) == true,
               let editor = NSApp.keyWindow?.firstResponder as? NavigableTextView,
               editor.isEditable {
                editor.requestAISuggestion()
                return nil
            }
            // Esc closes the overlay when it's open.
            if self.coordinator.search.isPresented, event.keyCode == 53 {
                self.coordinator.search.dismiss()
                return nil
            }
            self.lastShiftTap = 0
            return event
        }
    }

    // MARK: - Back / Forward navigation

    /// Back / Forward (⌘⌥← / ⌘⌥→ by default, see Settings ▸ Keyboard Shortcuts)
    /// and the mouse's side buttons walk navigation history, like an IDE. The
    /// chords win over whatever the focused text view would do with them.
    private func installNavigationHistoryShortcuts() {
        mouseMonitor = NSEvent.addLocalMonitorForEvents(matching: .otherMouseDown) { [weak self] event in
            guard let self, event.window === self.window else { return event }
            switch event.buttonNumber {
            case 3: self.navigateHistory(back: true); return nil
            case 4: self.navigateHistory(back: false); return nil
            default: return event
            }
        }
    }

    /// Returns true when the key event was a Back/Forward chord and was handled.
    private func handleNavigationHistoryKey(_ event: NSEvent) -> Bool {
        guard event.window === window else { return false }
        let shortcuts = ShortcutSettings.shared
        if shortcuts.shortcut(for: .navigateBack)?.matches(event) == true {
            navigateHistory(back: true)
            return true
        }
        if shortcuts.shortcut(for: .navigateForward)?.matches(event) == true {
            navigateHistory(back: false)
            return true
        }
        return false
    }

    /// Diff tabs keep their own tab history; everything else goes through the
    /// editor's location history (files + caret positions).
    private func navigateHistory(back: Bool) {
        let main = coordinator.main
        let editor = coordinator.activeBundle.editor
        if case .diff = main.detailTab {
            if back, main.canNavigateBackTab { main.navigateBackTab(); return }
            if !back, main.canNavigateForwardTab { main.navigateForwardTab(); return }
        }
        if back { editor.navigateBack() } else { editor.navigateForward() }
    }

    private func handleFlagsChanged(_ event: NSEvent) {
        guard event.keyCode == 56 || event.keyCode == 60 else { return }  // L/R Shift
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        // Ignore if any non-shift modifier is held (⇧⌘ etc).
        guard flags.subtracting(.shift).isEmpty else { lastShiftTap = 0; return }
        // flagsChanged fires on both press and release; act only on press.
        guard flags.contains(.shift) else { return }

        let now = ProcessInfo.processInfo.systemUptime
        if now - lastShiftTap < 0.4 {
            lastShiftTap = 0
            coordinator.openSearchEverywhere()
        } else {
            lastShiftTap = now
        }
    }

    @objc private func openSettings() { SettingsWindow.open(settings: coordinator.settings) }
    @objc private func addLocalRepository() { coordinator.repos.pickRepository() }
    @objc private func fetchOrigin() { Task { await coordinator.remote.fetchOrigin() } }
    @objc private func pullRemote() { Task { await coordinator.remote.pull() } }
    @objc private func pushRemote() { Task { await coordinator.remote.push() } }
    @objc private func toggleTerminal() { coordinator.toggleTerminal() }
    @objc private func newTerminal() { coordinator.newTerminal() }

    @objc private func addRepositoryByPath() { coordinator.repos.promptAddByPath() }
    @objc private func openSearchEverywhere() { coordinator.openSearchEverywhere() }
    @objc private func openUIInspector() { UIInspectorWindow.open(sourceNavigator: coordinator) }
    @objc private func showChangesTab() { coordinator.main.tab = .changes }
    @objc private func showStashTab() { coordinator.main.tab = .stash }
    @objc private func showHistoryTab() { coordinator.main.tab = .history }
    @objc private func showFilesTab() { coordinator.main.tab = .files }
    @objc private func showPullRequestsTab() { coordinator.main.tab = .pullRequests }
    @objc private func showClaudeTab() { coordinator.main.tab = .claude }

    @objc private func openRepositoryInTerminal() {
        FileActions.openTerminal(dir: coordinator.terminalCWD.path)
    }

    @objc private func revealRepositoryInFinder() {
        FileActions.reveal(absPath: coordinator.terminalCWD.path)
    }

    @objc private func saveActiveFile() {
        let editor = coordinator.activeBundle.editor
        guard let tab = editor.activeFileTab else { return }
        Task { await editor.saveFileTab(tab) }
    }

    /// The editor tab the detail pane is showing, if any.
    private var visibleEditorTab: OpenFileTab? {
        guard case let .editor(id) = coordinator.main.detailTab else { return nil }
        return coordinator.activeBundle.editor.openFileTabs.first { $0.id == id }
    }

    /// ⌘F: open the tab's find bar, seeded with the editor's selection.
    @objc private func findInFile() {
        guard let tab = visibleEditorTab else { return }
        var seed: String?
        if let tv = NSApp.keyWindow?.firstResponder as? NavigableTextView {
            let sel = tv.selectedRange()
            if sel.length > 0 { seed = (tv.string as NSString).substring(with: sel) }
        }
        tab.find.present(seed: seed)
    }

    @objc private func findNext() { visibleEditorTab?.find.next() }
    @objc private func findPrevious() { visibleEditorTab?.find.previous() }

    @objc private func reopenClosedTab() {
        coordinator.activeBundle.editor.reopenClosedTab()
    }

    /// ⌘W closes whatever the detail pane is showing — editor tab, diff, patch
    /// or the compare view — instead of the whole window.
    @objc private func closeDetailTab() {
        let main = coordinator.main
        switch main.detailTab {
        case .editor(let id): coordinator.activeBundle.editor.closeFileTab(id: id)
        case .diff(let id):   main.closeDiffTab(id)
        case .patch(let id):  main.closePatchTab(id)
        case .compare:        main.closeCompare()
        case .content:        break
        }
    }

    @objc private func toggleBuildVariants() {
        coordinator.activeBundle.run.showVariantsPanel.toggle()
    }

    /// Switch to the Files tab and expand the tree down to the file the editor
    /// is showing — the on-demand counterpart of the auto-expand setting.
    @objc private func revealActiveFile() {
        let bundle = coordinator.activeBundle
        guard let path = bundle.editor.activeFileTab?.path else { return }
        coordinator.main.tab = .files
        Task { await bundle.files.reveal(path: path) }
    }
}
