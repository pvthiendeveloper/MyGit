import AppKit
import SwiftUI

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var window: NSWindow?
    private let coordinator = AppCoordinator(container: .live())

    // Double-Shift ("Search Everywhere") detection.
    private var lastShiftTap: TimeInterval = 0
    private var flagsMonitor: Any?
    private var keyMonitor: Any?

    func applicationDidFinishLaunching(_ notification: Notification) {
        installMainMenu()
        installSearchEverywhereShortcut()

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
        if let dbg = ProcessInfo.processInfo.environment["MYGIT_DEBUG_DIFF"] {
            DispatchQueue.main.asyncAfter(deadline: .now() + 3) { [coordinator] in
                coordinator.main.openDiffTab(commitHash: "HEAD", commitShortHash: "HEAD",
                                             path: dbg, mode: .commitVsWorking, forceNew: true)
            }
        }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }

    private func installMainMenu() {
        let main = NSMenu()

        let appItem = NSMenuItem()
        let appMenu = NSMenu()
        appMenu.addItem(NSMenuItem(
            title: "About MyGit",
            action: #selector(NSApplication.orderFrontStandardAboutPanel(_:)),
            keyEquivalent: ""
        ))
        appMenu.addItem(.separator())
        let settingsItem = NSMenuItem(
            title: "Settings…",
            action: #selector(openSettings),
            keyEquivalent: ","
        )
        settingsItem.target = self
        appMenu.addItem(settingsItem)
        appMenu.addItem(.separator())
        appMenu.addItem(NSMenuItem(
            title: "Quit MyGit",
            action: #selector(NSApplication.terminate(_:)),
            keyEquivalent: "q"
        ))
        appItem.submenu = appMenu
        main.addItem(appItem)

        let fileItem = NSMenuItem()
        let fileMenu = NSMenu(title: "File")
        let addRepo = NSMenuItem(
            title: "Add Local Repository…",
            action: #selector(addLocalRepository),
            keyEquivalent: "o"
        )
        addRepo.target = self
        fileMenu.addItem(addRepo)
        fileItem.submenu = fileMenu
        main.addItem(fileItem)

        let repoItem = NSMenuItem()
        let repoMenu = NSMenu(title: "Repository")
        let fetch = NSMenuItem(title: "Fetch", action: #selector(fetchOrigin), keyEquivalent: "f")
        fetch.keyEquivalentModifierMask = [.command, .shift]
        fetch.target = self
        repoMenu.addItem(fetch)
        let pull = NSMenuItem(title: "Pull", action: #selector(pullRemote), keyEquivalent: "p")
        pull.keyEquivalentModifierMask = [.command, .shift]
        pull.target = self
        repoMenu.addItem(pull)
        let push = NSMenuItem(title: "Push", action: #selector(pushRemote), keyEquivalent: "P")
        push.keyEquivalentModifierMask = [.command, .shift]
        push.target = self
        repoMenu.addItem(push)
        repoItem.submenu = repoMenu
        main.addItem(repoItem)

        let editItem = NSMenuItem()
        let editMenu = NSMenu(title: "Edit")
        // Undo/Redo are menu-driven on macOS: without these items ⌘Z never
        // reaches the focused text view's undo manager (`allowsUndo` alone
        // doesn't bind the key).
        editMenu.addItem(NSMenuItem(title: "Undo", action: Selector(("undo:")), keyEquivalent: "z"))
        let redoItem = NSMenuItem(title: "Redo", action: Selector(("redo:")), keyEquivalent: "z")
        redoItem.keyEquivalentModifierMask = [.command, .shift]
        editMenu.addItem(redoItem)
        editMenu.addItem(.separator())
        editMenu.addItem(NSMenuItem(title: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x"))
        editMenu.addItem(NSMenuItem(title: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c"))
        editMenu.addItem(NSMenuItem(title: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v"))
        editMenu.addItem(NSMenuItem(title: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a"))
        editItem.submenu = editMenu
        main.addItem(editItem)

        let viewItem = NSMenuItem()
        let viewMenu = NSMenu(title: "View")
        let terminalToggle = NSMenuItem(title: "Terminal", action: #selector(toggleTerminal), keyEquivalent: "`")
        terminalToggle.keyEquivalentModifierMask = [.control]
        terminalToggle.target = self
        viewMenu.addItem(terminalToggle)
        let newTerminal = NSMenuItem(title: "New Terminal", action: #selector(newTerminal), keyEquivalent: "`")
        newTerminal.keyEquivalentModifierMask = [.control, .shift]
        newTerminal.target = self
        viewMenu.addItem(newTerminal)
        let variants = NSMenuItem(title: "Build Variants", action: #selector(toggleBuildVariants), keyEquivalent: "b")
        variants.keyEquivalentModifierMask = [.control, .shift]
        variants.target = self
        viewMenu.addItem(variants)
        viewMenu.addItem(.separator())
        let revealFile = NSMenuItem(
            title: "Reveal Active File",
            action: #selector(revealActiveFile),
            keyEquivalent: "1"
        )
        revealFile.keyEquivalentModifierMask = [.command, .shift]
        revealFile.target = self
        viewMenu.addItem(revealFile)
        viewItem.submenu = viewMenu
        main.addItem(viewItem)

        NSApp.mainMenu = main
    }

    func validateMenuItem(_ item: NSMenuItem) -> Bool {
        if item.action == #selector(toggleTerminal) {
            item.state = coordinator.terminal.isVisible ? .on : .off
        }
        if item.action == #selector(revealActiveFile) {
            return coordinator.activeBundle.editor.activeFileTab != nil
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
            // Esc closes the overlay when it's open.
            if self.coordinator.search.isPresented, event.keyCode == 53 {
                self.coordinator.search.dismiss()
                return nil
            }
            self.lastShiftTap = 0
            return event
        }
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
