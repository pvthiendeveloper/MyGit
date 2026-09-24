import AppKit

/// A key chord: one key plus modifiers. `key` is the *unshifted* character the
/// key types (`"o"`, `"1"`, `"`"`), or an AppKit function-key character for
/// arrows / F-keys — the same string `NSMenuItem.keyEquivalent` takes.
struct KeyShortcut: Codable, Hashable {
    let key: String
    private let modifierBits: UInt

    init(_ key: String, _ modifiers: NSEvent.ModifierFlags = [.command]) {
        self.key = key.lowercased()
        self.modifierBits = modifiers.intersection(Self.relevant).rawValue
    }

    /// The chord a key-down event represents; nil for bare modifier presses.
    init?(event: NSEvent) {
        // Arrows / F-keys / ↩ ⇥: the layout reports ASCII control codes (←
        // is 0x1C), but menus and `functionKeyNames` use AppKit's function-key
        // characters, which `charactersIgnoringModifiers` still carries.
        if let raw = event.charactersIgnoringModifiers, let scalar = raw.unicodeScalars.first,
           raw.unicodeScalars.count == 1,
           (0xF700...0xF8FF).contains(scalar.value) || scalar.value < 0x20 || scalar.value == 0x7F {
            self.init(raw, event.modifierFlags)
            return
        }
        // Everything else: the unshifted character, so ⇧⌘1 is stored as "1", not "!".
        guard let key = event.characters(byApplyingModifiers: [])?.lowercased(), !key.isEmpty else { return nil }
        self.init(key, event.modifierFlags)
    }

    var modifiers: NSEvent.ModifierFlags { NSEvent.ModifierFlags(rawValue: modifierBits) }

    func matches(_ event: NSEvent) -> Bool { KeyShortcut(event: event) == self }

    private static let relevant: NSEvent.ModifierFlags = [.control, .option, .shift, .command]

    /// A chord worth binding: needs ⌘/⌃/⌥, except function keys.
    var isValid: Bool {
        !modifiers.intersection([.command, .control, .option]).isEmpty || Self.functionKeyNames[key]?.hasPrefix("F") == true
    }

    /// Mac-style label, modifiers in Apple's order: ⌃⌥⇧⌘.
    var display: String {
        var s = ""
        if modifiers.contains(.control) { s += "⌃" }
        if modifiers.contains(.option) { s += "⌥" }
        if modifiers.contains(.shift) { s += "⇧" }
        if modifiers.contains(.command) { s += "⌘" }
        return s + (Self.functionKeyNames[key] ?? key.uppercased())
    }

    private static let functionKeyNames: [String: String] = {
        var names: [String: String] = [
            String(UnicodeScalar(NSLeftArrowFunctionKey)!): "←",
            String(UnicodeScalar(NSRightArrowFunctionKey)!): "→",
            String(UnicodeScalar(NSUpArrowFunctionKey)!): "↑",
            String(UnicodeScalar(NSDownArrowFunctionKey)!): "↓",
            String(UnicodeScalar(NSHomeFunctionKey)!): "↖",
            String(UnicodeScalar(NSEndFunctionKey)!): "↘",
            String(UnicodeScalar(NSPageUpFunctionKey)!): "⇞",
            String(UnicodeScalar(NSPageDownFunctionKey)!): "⇟",
            String(UnicodeScalar(NSDeleteFunctionKey)!): "⌦",
            "\r": "↩", "\t": "⇥", " ": "Space", "\u{7f}": "⌫", "\u{1b}": "⎋",
        ]
        for n in 1...20 {
            names[String(UnicodeScalar(NSF1FunctionKey + n - 1)!)] = "F\(n)"
        }
        return names
    }()

    static let leftArrow = String(UnicodeScalar(NSLeftArrowFunctionKey)!)
    static let rightArrow = String(UnicodeScalar(NSRightArrowFunctionKey)!)
}

/// Every command whose shortcut can be changed in Settings ▸ Keyboard Shortcuts.
enum ShortcutAction: String, CaseIterable, Identifiable {
    // Navigation
    case navigateBack, navigateForward
    // Editor
    case aiSuggest, sendToClaude
    // File
    case openSettings, addLocalRepository, addRepositoryByPath, closeTab, reopenClosedTab, save
    // Edit
    case find, findNext, findPrevious, searchEverywhere
    // View
    case showChanges, showStash, showHistory, showFiles, showPullRequests, showClaude
    case revealActiveFile, toggleTerminal, newTerminal, toggleBuildVariants, uiInspector
    // Repository
    case fetch, pull, push, openInTerminal, revealInFinder

    var id: String { rawValue }

    enum Group: String, CaseIterable {
        case navigation = "Navigation"
        case editor = "Editor"
        case file = "File"
        case edit = "Edit"
        case view = "View"
        case repository = "Repository"
    }

    /// Editor commands only fire while a code editor has focus, so they may
    /// share a chord with a global command (⌘⇧P: AI continuation vs. Pull).
    enum Scope { case global, editor }

    var scope: Scope { group == .editor ? .editor : .global }

    var group: Group {
        switch self {
        case .navigateBack, .navigateForward: return .navigation
        case .aiSuggest, .sendToClaude: return .editor
        case .openSettings, .addLocalRepository, .addRepositoryByPath, .closeTab, .reopenClosedTab, .save:
            return .file
        case .find, .findNext, .findPrevious, .searchEverywhere: return .edit
        case .showChanges, .showStash, .showHistory, .showFiles, .showPullRequests, .showClaude,
             .revealActiveFile, .toggleTerminal, .newTerminal, .toggleBuildVariants, .uiInspector:
            return .view
        case .fetch, .pull, .push, .openInTerminal, .revealInFinder: return .repository
        }
    }

    var title: String {
        switch self {
        case .navigateBack: return "Back"
        case .navigateForward: return "Forward"
        case .aiSuggest: return "AI Continuation"
        case .sendToClaude: return "Send Selection to Claude Code"
        case .openSettings: return "Settings…"
        case .addLocalRepository: return "Add Local Repository…"
        case .addRepositoryByPath: return "Add Repository by Path…"
        case .closeTab: return "Close Tab"
        case .reopenClosedTab: return "Reopen Closed Tab"
        case .save: return "Save"
        case .find: return "Find…"
        case .findNext: return "Find Next"
        case .findPrevious: return "Find Previous"
        case .searchEverywhere: return "Search Everywhere…"
        case .showChanges: return "Changes"
        case .showStash: return "Stash"
        case .showHistory: return "History"
        case .showFiles: return "Files"
        case .showPullRequests: return "Pull Requests"
        case .showClaude: return "Claude Code"
        case .revealActiveFile: return "Reveal Active File"
        case .toggleTerminal: return "Terminal"
        case .newTerminal: return "New Terminal"
        case .toggleBuildVariants: return "Build Variants"
        case .uiInspector: return "UI Inspector"
        case .fetch: return "Fetch"
        case .pull: return "Pull"
        case .push: return "Push"
        case .openInTerminal: return "Open in Terminal"
        case .revealInFinder: return "Reveal in Finder"
        }
    }

    var defaultShortcut: KeyShortcut? {
        switch self {
        case .navigateBack: return KeyShortcut(KeyShortcut.leftArrow, [.command, .option])
        case .navigateForward: return KeyShortcut(KeyShortcut.rightArrow, [.command, .option])
        case .aiSuggest: return KeyShortcut("p", [.command, .shift])
        case .sendToClaude: return KeyShortcut("k", [.command, .option])
        case .openSettings: return KeyShortcut(",")
        case .addLocalRepository: return KeyShortcut("o")
        case .addRepositoryByPath: return KeyShortcut("o", [.command, .option])
        case .closeTab: return KeyShortcut("w")
        case .reopenClosedTab: return KeyShortcut("t", [.command, .shift])
        case .save: return KeyShortcut("s")
        case .find: return KeyShortcut("f")
        case .findNext: return KeyShortcut("g")
        case .findPrevious: return KeyShortcut("g", [.command, .shift])
        case .searchEverywhere: return KeyShortcut("o", [.command, .control])
        case .showChanges: return KeyShortcut("1")
        case .showStash: return KeyShortcut("2")
        case .showHistory: return KeyShortcut("3")
        case .showFiles: return KeyShortcut("4")
        case .showPullRequests: return KeyShortcut("5")
        case .showClaude: return KeyShortcut("6")
        case .revealActiveFile: return KeyShortcut("j", [.command, .shift])
        case .toggleTerminal: return KeyShortcut("`", [.control])
        case .newTerminal: return KeyShortcut("`", [.control, .shift])
        case .toggleBuildVariants: return KeyShortcut("b", [.control, .shift])
        case .uiInspector: return KeyShortcut("i", [.command, .option])
        case .fetch: return KeyShortcut("f", [.command, .shift])
        case .pull: return KeyShortcut("p", [.command, .shift])
        // ⌘⇧U, not ⌘⇧P: "P" + shift is the same chord as Pull.
        case .push: return KeyShortcut("u", [.command, .shift])
        case .openInTerminal: return KeyShortcut("t", [.command, .control])
        case .revealInFinder: return KeyShortcut("r", [.command, .control])
        }
    }
}
