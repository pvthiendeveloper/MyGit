import AppKit
import SwiftUI

/// Hosts `SettingsView` in a standalone, reused window.
@MainActor
final class SettingsWindow: NSObject, NSWindowDelegate {
    private static var shared: SettingsWindow?

    private var window: NSWindow?

    static func open(settings: SettingsViewModel) {
        if let existing = shared?.window {
            existing.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }
        let instance = SettingsWindow()
        let root = SettingsView().environmentObject(settings)
        let hosting = NSHostingController(rootView: root)
        let win = NSWindow(contentViewController: hosting)
        win.title = "Settings"
        win.styleMask = [.titled, .closable]
        win.delegate = instance
        win.setContentSize(NSSize(width: 480, height: 360))
        win.center()
        win.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        instance.window = win
        shared = instance
    }

    func windowWillClose(_ notification: Notification) {
        SettingsWindow.shared = nil
        window = nil
    }
}
