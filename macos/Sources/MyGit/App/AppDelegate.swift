import AppKit
import SwiftUI

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var window: NSWindow?
    private let coordinator = AppCoordinator(container: .live())

    func applicationDidFinishLaunching(_ notification: Notification) {
        installMainMenu()

        let root = MainView()
            .environmentObject(coordinator)
            .environmentObject(coordinator.main)
            .environmentObject(coordinator.repos)
            .environmentObject(coordinator.changes)
            .environmentObject(coordinator.history)
            .environmentObject(coordinator.files)
            .environmentObject(coordinator.editor)
            .environmentObject(coordinator.branches)
            .environmentObject(coordinator.account)
            .environmentObject(coordinator.remote)
            .environmentObject(coordinator.compareVM)
            .environmentObject(coordinator.settings)
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
        editMenu.addItem(NSMenuItem(title: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x"))
        editMenu.addItem(NSMenuItem(title: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c"))
        editMenu.addItem(NSMenuItem(title: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v"))
        editMenu.addItem(NSMenuItem(title: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a"))
        editItem.submenu = editMenu
        main.addItem(editItem)

        NSApp.mainMenu = main
    }

    @objc private func openSettings() { SettingsWindow.open(settings: coordinator.settings) }
    @objc private func addLocalRepository() { coordinator.repos.pickRepository() }
    @objc private func fetchOrigin() { Task { await coordinator.remote.fetchOrigin() } }
    @objc private func pullRemote() { Task { await coordinator.remote.pull() } }
    @objc private func pushRemote() { Task { await coordinator.remote.push() } }
}
