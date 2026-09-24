import AppKit
import Combine

/// User-assigned keyboard shortcuts (Settings ▸ Keyboard Shortcuts). Only
/// changes from the defaults are stored; the menu bar and key monitors read
/// `shortcut(for:)` and rebuild when `objectWillChange` fires.
@MainActor
final class ShortcutSettings: ObservableObject {
    static let shared = ShortcutSettings()

    /// action → chord, or `nil` when the user removed the shortcut.
    @Published private var overrides: [ShortcutAction: KeyShortcut?] = [:]

    private let defaults: UserDefaults
    private static let key = "MyGit.shortcuts"

    /// Fixed Edit/app-menu chords (Undo, Copy, Quit…) that stay AppKit's.
    static let reserved: [KeyShortcut: String] = [
        KeyShortcut("z"): "Undo", KeyShortcut("z", [.command, .shift]): "Redo",
        KeyShortcut("x"): "Cut", KeyShortcut("c"): "Copy", KeyShortcut("v"): "Paste",
        KeyShortcut("a"): "Select All", KeyShortcut("q"): "Quit MyGit",
        KeyShortcut("h"): "Hide MyGit", KeyShortcut("h", [.command, .option]): "Hide Others",
        KeyShortcut("m"): "Minimize",
    ]

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        let stored = defaults.dictionary(forKey: Self.key) as? [String: Data] ?? [:]
        for (id, data) in stored {
            guard let action = ShortcutAction(rawValue: id) else { continue }
            // Empty data = explicitly unassigned.
            overrides[action] = data.isEmpty ? .some(nil) : (try? JSONDecoder().decode(KeyShortcut.self, from: data))
        }
    }

    func shortcut(for action: ShortcutAction) -> KeyShortcut? {
        if let custom = overrides[action] { return custom }
        return action.defaultShortcut
    }

    func isCustomized(_ action: ShortcutAction) -> Bool { overrides[action] != nil }

    /// The action (same scope) already bound to `shortcut`, other than `action`.
    func conflict(for shortcut: KeyShortcut, excluding action: ShortcutAction) -> ShortcutAction? {
        ShortcutAction.allCases.first {
            $0 != action && $0.scope == action.scope && self.shortcut(for: $0) == shortcut
        }
    }

    /// Bind `shortcut` (nil = none). A same-scope action holding it loses it.
    func set(_ shortcut: KeyShortcut?, for action: ShortcutAction) {
        if let shortcut, let other = conflict(for: shortcut, excluding: action) {
            store(nil, for: other)
        }
        store(shortcut, for: action)
        persist()
    }

    func reset(_ action: ShortcutAction) {
        overrides[action] = nil
        // Taking the default back may collide with a custom binding elsewhere.
        if let d = action.defaultShortcut, let other = conflict(for: d, excluding: action) {
            store(nil, for: other)
        }
        persist()
    }

    func resetAll() {
        overrides = [:]
        persist()
    }

    private func store(_ shortcut: KeyShortcut?, for action: ShortcutAction) {
        overrides[action] = shortcut == action.defaultShortcut ? nil : .some(shortcut)
    }

    private func persist() {
        var out: [String: Data] = [:]
        for (action, shortcut) in overrides {
            out[action.rawValue] = shortcut.flatMap { try? JSONEncoder().encode($0) } ?? Data()
        }
        defaults.set(out, forKey: Self.key)
    }
}
