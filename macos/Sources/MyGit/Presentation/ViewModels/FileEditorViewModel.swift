import Foundation
import Combine
import AppKit

@MainActor
final class FileEditorViewModel: ObservableObject {
    @Published var openFileTabs: [OpenFileTab] = []
    @Published var activeFileTabId: UUID?
    @Published private(set) var closedPaths: [String] = []
    /// Pending ⌘-click result the user still has to choose from.
    @Published var symbolLookup: SymbolLookup?
    /// Symbol currently being resolved, so the UI can show progress.
    @Published private(set) var resolvingSymbol: String?
    /// Declared names across the repo, used as completion candidates.
    @Published private(set) var repoSymbols: [String] = []
    private var symbolsLoaded = false
    /// IDE-style Back/Forward (⌘⌥← / ⌘⌥→ by default, mouse side buttons): places the user
    /// jumped away from — tab switches, ⌘-click hops, big caret moves.
    @Published private(set) var backLocations: [EditorLocation] = []
    @Published private(set) var forwardLocations: [EditorLocation] = []
    /// True while replaying history, so the replay itself isn't recorded.
    private var isNavigatingHistory = false
    private static let historyLimit = 100
    /// Caret moves at least this many lines count as a jump worth remembering.
    private static let significantLineDelta = 10

    /// Open tabs are remembered per repo and reopened next launch.
    private let defaults: UserDefaults
    private var sessionSink: AnyCancellable?
    private struct Session: Codable {
        struct Tab: Codable { let path: String; let line: Int }
        let tabs: [Tab]
        let active: String?
    }

    var canNavigateBack: Bool { !backLocations.isEmpty }
    var canNavigateForward: Bool { !forwardLocations.isEmpty }

    var activeFileTab: OpenFileTab? {
        guard let id = activeFileTabId else { return nil }
        return openFileTabs.first { $0.id == id }
    }

    private let fileEditor: FileEditorRepository
    private let ai: CommitMessageRepository
    private var aiConfigSource: () -> AIRequestConfig? = { nil }
    private let git: GitRepository
    private let main: MainViewModel
    private let repoSource: () -> Repository?
    private let onSaved: () async -> Void
    private let symbolIndex: XcodeSymbolIndex
    private let swiftCompletion: SwiftCompletionService

    init(
        fileEditor: FileEditorRepository,
        ai: CommitMessageRepository,
        git: GitRepository,
        main: MainViewModel,
        repoSource: @escaping () -> Repository?,
        onSaved: @escaping () async -> Void,
        symbolIndex: XcodeSymbolIndex = .shared,
        swiftCompletion: SwiftCompletionService = .shared,
        defaults: UserDefaults = .standard
    ) {
        self.symbolIndex = symbolIndex
        self.swiftCompletion = swiftCompletion
        self.defaults = defaults
        self.fileEditor = fileEditor
        self.ai = ai
        self.git = git
        self.main = main
        self.repoSource = repoSource
        self.onSaved = onSaved
        sessionSink = Publishers.CombineLatest($openFileTabs, $activeFileTabId)
            .dropFirst()
            .debounce(for: .milliseconds(300), scheduler: DispatchQueue.main)
            .sink { [weak self] _, _ in self?.persistSession() }
    }

    // MARK: - Session (reopen tabs on launch)

    private var sessionKey: String? {
        repoSource().map { "MyGit.openFileTabs.\($0.url.path)" }
    }

    /// Save open tabs, the active one, and each caret line for this repo.
    func persistSession() {
        guard let key = sessionKey else { return }
        let session = Session(
            tabs: openFileTabs.map { .init(path: $0.path, line: $0.caretLine) },
            active: activeFileTab?.path
        )
        if let data = try? JSONEncoder().encode(session) { defaults.set(data, forKey: key) }
    }

    /// Reopen the tabs saved for this repo. `focus` also makes the active tab
    /// the visible detail tab (only the workspace's active repo should).
    func restoreSession(focus: Bool) {
        guard openFileTabs.isEmpty, let key = sessionKey, let repo = repoSource(),
              let data = defaults.data(forKey: key),
              let session = try? JSONDecoder().decode(Session.self, from: data) else { return }
        let fm = FileManager.default
        for saved in session.tabs {
            let abs = saved.path.hasPrefix("/") ? saved.path : repo.url.appendingPathComponent(saved.path).path
            guard fm.fileExists(atPath: abs), !openFileTabs.contains(where: { $0.path == saved.path }) else { continue }
            let tab = OpenFileTab(path: saved.path)
            tab.caretLine = saved.line
            if saved.line > 1 { tab.goto = EditorGoto(line: saved.line) }
            openFileTabs.append(tab)
            Task { await loadFileTab(tab) }
        }
        guard !openFileTabs.isEmpty else { return }
        let active = openFileTabs.first { $0.path == session.active } ?? openFileTabs.last!
        activeFileTabId = active.id
        if focus { main.detailTab = .editor(active.id) }
    }

    func setAIConfigSource(_ block: @escaping () -> AIRequestConfig?) { aiConfigSource = block }

    // MARK: - Auto-save

    private var autoSaveEnabled: () -> Bool = { false }
    private var autoSaveSinks: [UUID: AnyCancellable] = [:]
    private var autoSaveTabsSink: AnyCancellable?
    private var resignActiveObserver: NSObjectProtocol?
    private static let autoSaveDelay = 1.0

    /// Turn on auto-save: each open tab saves itself once typing pauses, and
    /// every dirty tab is flushed when the app loses focus (so a build or a
    /// `git` command run elsewhere sees the latest text).
    func setAutoSaveSource(_ enabled: @escaping () -> Bool) {
        autoSaveEnabled = enabled
        autoSaveTabsSink = $openFileTabs.sink { [weak self] tabs in self?.syncAutoSave(tabs) }
        resignActiveObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didResignActiveNotification, object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in await self?.autoSaveDirtyTabs() }
        }
    }

    private func syncAutoSave(_ tabs: [OpenFileTab]) {
        let ids = Set(tabs.map(\.id))
        autoSaveSinks = autoSaveSinks.filter { ids.contains($0.key) }
        for tab in tabs where autoSaveSinks[tab.id] == nil {
            autoSaveSinks[tab.id] = tab.$content
                .dropFirst()
                .debounce(for: .seconds(Self.autoSaveDelay), scheduler: DispatchQueue.main)
                .sink { [weak self, weak tab] _ in
                    guard let self, let tab else { return }
                    Task { @MainActor in await self.autoSave(tab) }
                }
        }
    }

    /// A tab closed inside the debounce window still gets its edits written.
    private func flushBeforeClose(_ tab: OpenFileTab) {
        guard autoSaveEnabled(), tab.isDirty, !tab.isLoading, !tab.isBinary, tab.loadError == nil,
              tab.diskConflict == nil else { return }
        Task { await saveFileTab(tab, refreshSymbols: false) }
    }

    private func autoSaveDirtyTabs() async {
        for tab in openFileTabs { await autoSave(tab) }
    }

    private func autoSave(_ tab: OpenFileTab) async {
        guard autoSaveEnabled(), tab.isDirty, !tab.isLoading, !tab.isBinary, tab.loadError == nil,
              tab.diskConflict == nil,
              openFileTabs.contains(where: { $0 === tab }) else { return }
        await saveFileTab(tab, refreshSymbols: false)
    }

    /// Ask the configured LLM to continue the code at the caret. Returns nil
    /// when AI isn't configured or it had nothing to add.
    func aiSuggestion(prefix: String, suffix: String, language: String) async -> String? {
        guard let config = aiConfigSource() else {
            main.errorMessage = CommitMessageError.missingAPIKey.errorDescription
            return nil
        }
        do {
            let text = try await ai.completeCode(prefix: prefix, suffix: suffix,
                                                 language: language, config: config)
            let trimmed = text.trimmingCharacters(in: .newlines)
            return trimmed.isEmpty ? nil : trimmed
        } catch {
            main.errorMessage = error.localizedDescription
            return nil
        }
    }

    // MARK: - Completion

    /// Harvest the repo's declared names once per session (and after a save, so
    /// new declarations show up). One `git grep` over tracked files.
    func loadRepoSymbols(force: Bool = false) async {
        guard let repo = repoSource(), force || !symbolsLoaded else { return }
        symbolsLoaded = true
        repoSymbols = (try? await git.declaredSymbols(at: repo.url)) ?? []
    }

    /// Type-aware completions for a Swift tab's unsaved buffer (sourcekit-lsp).
    /// Nil when the server can't answer; the editor then offers plain words.
    func swiftCompletions(for tab: OpenFileTab, text: String, caret: Int) async -> [CodeCompletionItem]? {
        guard let path = absolutePath(for: tab) else { return nil }
        return await swiftCompletion.completions(file: URL(fileURLWithPath: path),
                                                 repoRoot: repoSource()?.url, text: text, caret: caret)
    }

    // MARK: - ⌘-click navigation

    /// Resolve a ⌘-clicked identifier the way an IDE would. Xcode's index is
    /// asked first (real references to the symbol under the caret); files it
    /// doesn't cover fall back to a whole-word `git grep`:
    /// - clicked on a use, one declaration found → jump straight to it;
    /// - clicked on the declaration itself → list the usages to pick from;
    /// - several declarations (or no declaration at all) → let the user choose.
    func goToDefinition(symbol: String, line: Int, in tab: OpenFileTab) {
        guard let repo = repoSource() else { return }
        resolvingSymbol = symbol
        Task {
            defer { resolvingSymbol = nil }
            var source = SymbolLookup.Source.grep
            var occurrences: [SymbolOccurrence]
            if let indexed = await indexedOccurrences(symbol: symbol, line: line, in: tab, repo: repo) {
                occurrences = indexed.occurrences
                source = .index(updated: indexed.updated)
            } else {
                let matches: [GitGrepMatch]
                do { matches = try await git.searchSymbol(symbol, at: repo.url) }
                catch {
                    main.errorMessage = error.localizedDescription
                    return
                }
                occurrences = matches.map {
                    SymbolOccurrence(
                        path: $0.path,
                        line: $0.line,
                        preview: $0.preview,
                        isDefinition: SymbolClassifier.isDefinition(line: $0.preview, symbol: symbol)
                    )
                }
            }
            guard !occurrences.isEmpty else {
                main.errorMessage = "No occurrences of \"\(symbol)\" in the repo."
                return
            }
            let definitions = occurrences.filter { $0.isDefinition }
            let usages = occurrences.filter { !$0.isDefinition }
            let onDefinition = definitions.contains { $0.path == tab.path && $0.line == line }

            let present: @MainActor (SymbolLookup.Kind) -> Void = { kind in
                self.symbolLookup = SymbolLookup(
                    symbol: symbol,
                    initialKind: kind,
                    occurrences: occurrences,
                    originPath: tab.path,
                    originLine: line,
                    source: source
                )
            }

            if onDefinition || definitions.isEmpty {
                let others = usages.filter { !($0.path == tab.path && $0.line == line) }
                guard !others.isEmpty else {
                    main.errorMessage = "\"\(symbol)\" isn't used anywhere else."
                    return
                }
                if others.count == 1 { open(others[0]) } else { present(.usages) }
            } else if definitions.count == 1 {
                open(definitions[0])
            } else {
                present(.definitions)
            }
        }
    }

    /// Occurrences of the symbol under the caret from Xcode's index, with
    /// previews read from disk. Nil when the index can't answer (not an Xcode
    /// project, never built, or the clicked line has moved since indexing).
    private func indexedOccurrences(symbol: String, line: Int, in tab: OpenFileTab,
                                    repo: Repository) async -> (occurrences: [SymbolOccurrence], updated: Date?)? {
        // Unsaved edits shift lines the index doesn't know about.
        guard !tab.isDirty, !tab.path.hasPrefix("/"),
              let indexed = await symbolIndex.lookup(repo: repo.url, path: tab.path, line: line, name: symbol)
        else { return nil }

        var lines: [String: [Substring]] = [:]
        var result: [SymbolOccurrence] = []
        for occ in indexed.occurrences {
            if lines[occ.path] == nil {
                lines[occ.path] = fileContents(path: occ.path)?
                    .split(separator: "\n", omittingEmptySubsequences: false) ?? []
            }
            guard let fileLines = lines[occ.path], occ.line - 1 < fileLines.count else { continue }
            let text = fileLines[occ.line - 1]
            // The file changed since Xcode indexed it and this line moved:
            // drop it rather than point at the wrong code.
            guard text.contains(symbol) else { continue }
            result.append(SymbolOccurrence(
                path: occ.path,
                line: occ.line,
                preview: String(text.trimmingCharacters(in: .whitespaces).prefix(200)),
                isDefinition: occ.isDefinition
            ))
        }
        return result.isEmpty ? nil : (result, indexed.indexedAt)
    }

    /// Read a repo file as text (symbol-lookup preview). Nil for binaries or
    /// anything that can't be read.
    func fileContents(path: String) -> String? {
        guard let repo = repoSource(),
              let data = try? fileEditor.read(at: repo.url, path: path) else { return nil }
        return decodeText(data)
    }

    /// Open (or focus) the occurrence's file and reveal its line.
    func open(_ occurrence: SymbolOccurrence) {
        symbolLookup = nil
        recordJump()
        isNavigatingHistory = true
        defer { isNavigatingHistory = false }
        reveal(EditorLocation(path: occurrence.path, line: occurrence.line))
    }

    // MARK: - Back / Forward

    /// Where the user is right now — only when an editor tab is showing.
    private var currentLocation: EditorLocation? {
        guard case let .editor(id) = main.detailTab,
              let tab = openFileTabs.first(where: { $0.id == id }) else { return nil }
        return EditorLocation(path: tab.path, line: tab.caretLine)
    }

    /// Remember the current spot before jumping somewhere else.
    private func recordJump(from location: EditorLocation? = nil) {
        guard !isNavigatingHistory, let loc = location ?? currentLocation else { return }
        if backLocations.last != loc { backLocations.append(loc) }
        if backLocations.count > Self.historyLimit { backLocations.removeFirst() }
        forwardLocations.removeAll()
    }

    func navigateBack() {
        guard let target = popDistinct(&backLocations) else { return }
        if let cur = currentLocation { forwardLocations.append(cur) }
        replay(target)
    }

    func navigateForward() {
        guard let target = popDistinct(&forwardLocations) else { return }
        if let cur = currentLocation { backLocations.append(cur) }
        replay(target)
    }

    /// Pop the newest entry that isn't where the user already stands.
    private func popDistinct(_ stack: inout [EditorLocation]) -> EditorLocation? {
        let cur = currentLocation
        while let last = stack.popLast() {
            if last != cur { return last }
        }
        return nil
    }

    private func replay(_ location: EditorLocation) {
        isNavigatingHistory = true
        defer { isNavigatingHistory = false }
        reveal(location)
    }

    /// Open (or focus) the file and put the caret on the line.
    private func reveal(_ location: EditorLocation) {
        openFile(path: location.path)
        guard let tab = openFileTabs.first(where: { $0.path == location.path }) else { return }
        tab.caretLine = location.line
        tab.goto = EditorGoto(line: location.line)
    }

    // MARK: - Git blame

    /// Gutter ▸ "Annotate with Git Blame": show / hide who last changed each line.
    func toggleBlame(_ tab: OpenFileTab) {
        if tab.blame != nil {
            tab.blame = nil
        } else {
            Task { await loadBlame(tab, reportErrors: true) }
        }
    }

    /// (Re)load blame. After a save, lines have moved, so the annotations follow.
    func loadBlame(_ tab: OpenFileTab, reportErrors: Bool = false) async {
        guard let repo = repoSource(), !tab.path.hasPrefix("/") else {
            if reportErrors { main.errorMessage = "Git blame is only available for files inside the repository." }
            return
        }
        do {
            tab.blame = try await git.blame(path: tab.path, at: repo.url)
        } catch {
            tab.blame = nil
            if reportErrors {
                main.errorMessage = "Git blame isn't available for “\(tab.name)” — is the file tracked by git?"
            }
        }
    }

    // MARK: - External changes

    private var presentingConflict = false

    /// The file's current text on disk; nil when unreadable, deleted or binary.
    private func diskText(of tab: OpenFileTab) -> String? {
        let data: Data?
        if tab.path.hasPrefix("/") {
            data = try? Data(contentsOf: URL(fileURLWithPath: tab.path))
        } else if let repo = repoSource() {
            data = try? fileEditor.read(at: repo.url, path: tab.path)
        } else {
            data = nil
        }
        return data.flatMap(decodeText)
    }

    /// Called when the repo watcher sees disk changes. Clean tabs quietly take
    /// the new text (an IDE's "reload from disk"); tabs with unsaved edits ask.
    func checkExternalChanges() {
        for tab in openFileTabs where !tab.isLoading && !tab.isBinary && tab.loadError == nil {
            guard let disk = diskText(of: tab), disk != tab.originalContent else { continue }
            if disk == tab.content {
                // Same edit on both sides (or our own save landing late).
                tab.originalContent = disk
                tab.diskConflict = nil
            } else if !tab.isDirty {
                tab.content = disk
                tab.originalContent = disk
                if tab.blame != nil { Task { await loadBlame(tab) } }
            } else if tab.diskConflict != disk {
                tab.diskConflict = disk
                presentConflict(tab)
            }
        }
    }

    /// Ask which version wins. One dialog at a time; the editor keeps a banner
    /// with the same choices until the conflict is settled.
    func presentConflict(_ tab: OpenFileTab) {
        guard !presentingConflict, tab.diskConflict != nil else { return }
        presentingConflict = true
        defer { presentingConflict = false }

        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "“\(tab.name)” changed on disk"
        alert.informativeText = "Another program modified this file while you have unsaved edits in MyGit. Which version do you want to keep?"
        alert.addButton(withTitle: "Keep My Version")      // overwrite disk
        alert.addButton(withTitle: "Use Disk Version")     // drop my edits
        alert.addButton(withTitle: "Compare…")
        alert.buttons[1].hasDestructiveAction = true
        switch alert.runModal() {
        case .alertFirstButtonReturn: keepMyVersion(tab)
        case .alertSecondButtonReturn: useDiskVersion(tab)
        default: compareWithDisk(tab)
        }
    }

    /// Overwrite the disk with the editor's text.
    func keepMyVersion(_ tab: OpenFileTab) {
        guard let disk = tab.diskConflict else { return }
        // Accept what's on disk as the base, so the save below isn't flagged again.
        tab.originalContent = disk
        tab.diskConflict = nil
        Task { await saveFileTab(tab) }
    }

    /// Throw away the editor's unsaved edits and show the disk's text.
    func useDiskVersion(_ tab: OpenFileTab) {
        guard let disk = tab.diskConflict else { return }
        tab.diskConflict = nil
        tab.content = disk
        tab.originalContent = disk
    }

    /// Side-by-side: disk (left) vs the editor's unsaved text (right). The
    /// conflict stays open; the editor banner resolves it.
    func compareWithDisk(_ tab: OpenFileTab) {
        guard let disk = tab.diskConflict else { return }
        let diff = DiffTab(
            commitHash: "",
            commitShortHash: "",
            path: tab.path,
            mode: .commitVsParent,
            embedded: DiffTab.Embedded(
                dedupKey: "disk-conflict:\(tab.path)",
                leftText: disk,
                rightText: tab.content,
                leftLabel: "On disk",
                rightLabel: "MyGit (unsaved)"
            )
        )
        main.openPatchDiffTab(diff, forceNew: true)
    }

    // MARK: - Claude Code

    private var selectionWork: DispatchWorkItem?

    /// Tell a connected Claude Code what's selected, like the IDE plugins do.
    /// Debounced: a drag-select fires this per mouse move.
    func selectionChanged(in tab: OpenFileTab, to range: NSRange) {
        tab.selection = range
        selectionWork?.cancel()
        let work = DispatchWorkItem { [weak self, weak tab] in
            guard let self, let tab, case .editor(tab.id) = self.main.detailTab else { return }
            self.publishSelection(of: tab)
        }
        selectionWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15, execute: work)
    }

    private func publishSelection(of tab: OpenFileTab) {
        guard !tab.isBinary, let path = absolutePath(for: tab),
              let selection = Self.ideSelection(of: tab.selection, in: tab.content, path: path) else { return }
        ClaudeIDEServer.shared.publishSelection(selection)
    }

    /// ⌥⌘K: @-mention the file and selected lines (or the caret's line) in
    /// Claude Code's prompt.
    func mentionInClaude(_ tab: OpenFileTab) {
        guard let path = absolutePath(for: tab) else { return }
        guard ClaudeIDEServer.shared.connectedCount > 0 else {
            main.errorMessage = "No Claude Code session is connected. Run `claude` in MyGit's terminal (or /ide in one started elsewhere)."
            return
        }
        guard let selection = Self.ideSelection(of: tab.selection, in: tab.content, path: path) else { return }
        // A selection ending at column 0 doesn't really include that line.
        let endLine = selection.end.character == 0 && selection.end.line > selection.start.line
            ? selection.end.line - 1 : selection.end.line
        ClaudeIDEServer.shared.mention(filePath: path, lineStart: selection.start.line, lineEnd: endLine)
    }

    /// NSRange (UTF-16) → 0-based line/character positions + selected text.
    static func ideSelection(of range: NSRange, in text: String, path: String) -> ClaudeIDESelection? {
        let ns = text as NSString
        guard range.location != NSNotFound, NSMaxRange(range) <= ns.length else { return nil }
        func position(_ offset: Int) -> ClaudeIDESelection.Position {
            var line = 0, lineStart = 0
            var index = 0
            while index < offset {
                if ns.character(at: index) == 10 { line += 1; lineStart = index + 1 }
                index += 1
            }
            return .init(line: line, character: offset - lineStart)
        }
        return ClaudeIDESelection(
            filePath: path,
            text: ns.substring(with: range),
            start: position(range.location),
            end: position(NSMaxRange(range))
        )
    }

    /// Open (or focus) a file and put the caret on a 1-based line.
    func reveal(path: String, line: Int) {
        recordJump()
        reveal(EditorLocation(path: path, line: line))
    }

    /// The editor reports every caret move; user-driven moves (clicks, not
    /// typing or programmatic reveals) across many lines become history entries.
    func caretMoved(in tab: OpenFileTab, to line: Int, userInitiated: Bool) {
        let previous = tab.caretLine
        tab.caretLine = line
        guard userInitiated, abs(line - previous) >= Self.significantLineDelta,
              case let .editor(id) = main.detailTab, id == tab.id else { return }
        recordJump(from: EditorLocation(path: tab.path, line: previous))
    }

    func repositoryDidChange() {
        openFileTabs.removeAll()
        activeFileTabId = nil
        closedPaths.removeAll()
        backLocations.removeAll()
        forwardLocations.removeAll()
        repoSymbols = []
        symbolsLoaded = false
        syncDetailTab()
    }

    /// Keeps `main.detailTab` valid after editor tabs change: if it points at an
    /// editor tab that no longer exists, retarget the active tab or fall back.
    private func syncDetailTab() {
        guard case let .editor(id) = main.detailTab else { return }
        if openFileTabs.contains(where: { $0.id == id }) { return }
        if let active = activeFileTabId {
            main.detailTab = .editor(active)
        } else {
            main.fallbackDetailTab()
        }
    }

    func openFile(_ node: FileTreeNode) {
        guard !node.isDirectory else { return }
        openFile(path: node.id)
    }

    func openFile(path: String) {
        if let existing = openFileTabs.first(where: { $0.path == path }) {
            selectFileTab(id: existing.id)
            return
        }
        recordJump()
        let tab = OpenFileTab(path: path)
        openFileTabs.append(tab)
        activeFileTabId = tab.id
        main.detailTab = .editor(tab.id)
        Task { await loadFileTab(tab) }
    }

    /// Makes the given editor tab both the active file tab and the visible
    /// detail tab, so selecting a chip in the unified tab bar switches content.
    func selectFileTab(id: UUID) {
        if main.detailTab != .editor(id) { recordJump() }
        activeFileTabId = id
        main.detailTab = .editor(id)
        // Claude follows the focused file, like switching editors in an IDE.
        if let tab = openFileTabs.first(where: { $0.id == id }), !tab.isLoading { publishSelection(of: tab) }
    }

    private func loadFileTab(_ tab: OpenFileTab) async {
        tab.isLoading = true
        defer { tab.isLoading = false }
        do {
            // Files outside the repo (Claude Code config, skills) open by
            // absolute path; the repository helper is repo-relative only.
            let data: Data
            if tab.path.hasPrefix("/") {
                data = try Data(contentsOf: URL(fileURLWithPath: tab.path))
            } else {
                guard let repo = repoSource() else { return }
                data = try fileEditor.read(at: repo.url, path: tab.path)
            }
            if let text = decodeText(data) {
                tab.content = text
                tab.originalContent = text
                tab.isBinary = false
                tab.image = nil
            } else {
                tab.isBinary = true
                tab.image = NSImage(data: data)
                tab.content = ""
                tab.originalContent = ""
            }
        } catch {
            tab.loadError = error.localizedDescription
        }
    }

    private func decodeText(_ data: Data) -> String? {
        if data.contains(0) { return nil }
        return String(data: data, encoding: .utf8)
            ?? String(data: data, encoding: .utf16)
    }

    /// Retarget open tabs after `oldPath` (a file, or a folder holding them)
    /// was renamed to `newPath`.
    func pathRenamed(from oldPath: String, to newPath: String) {
        var moved = false
        for tab in openFileTabs {
            if tab.path == oldPath {
                tab.move(to: newPath)
            } else if tab.path.hasPrefix(oldPath + "/") {
                tab.move(to: newPath + tab.path.dropFirst(oldPath.count))
            } else {
                continue
            }
            moved = true
        }
        closedPaths.removeAll { $0 == oldPath || $0.hasPrefix(oldPath + "/") }
        if moved { persistSession() }
    }

    func closeFileTab(id: UUID) {
        guard let idx = openFileTabs.firstIndex(where: { $0.id == id }) else { return }
        let removed = openFileTabs.remove(at: idx)
        flushBeforeClose(removed)
        recordClosed(removed.path)
        if activeFileTabId == id {
            if openFileTabs.isEmpty {
                activeFileTabId = nil
            } else {
                let newIdx = min(idx, openFileTabs.count - 1)
                activeFileTabId = openFileTabs[newIdx].id
            }
        }
        syncDetailTab()
    }

    func closeOtherFileTabs(keep id: UUID) {
        for tab in openFileTabs where tab.id != id {
            flushBeforeClose(tab)
            recordClosed(tab.path)
        }
        openFileTabs.removeAll { $0.id != id }
        activeFileTabId = id
        syncDetailTab()
    }

    func closeAllFileTabs() {
        for tab in openFileTabs {
            flushBeforeClose(tab)
            recordClosed(tab.path)
        }
        openFileTabs.removeAll()
        activeFileTabId = nil
        syncDetailTab()
    }

    /// Closes every non-dirty tab; keeps tabs with unsaved edits.
    func closeSavedFileTabs() {
        for tab in openFileTabs where !tab.isDirty {
            recordClosed(tab.path)
        }
        openFileTabs.removeAll { !$0.isDirty }
        if let active = activeFileTabId, !openFileTabs.contains(where: { $0.id == active }) {
            activeFileTabId = openFileTabs.first?.id
        }
        syncDetailTab()
    }

    func reopenClosedTab() {
        guard let path = closedPaths.popLast() else { return }
        openFile(path: path)
    }

    private func recordClosed(_ path: String) {
        closedPaths.removeAll { $0 == path }
        closedPaths.append(path)
    }

    /// Absolute on-disk path for a tab, or nil if no repo is loaded.
    func absolutePath(for tab: OpenFileTab) -> String? {
        if tab.path.hasPrefix("/") { return tab.path }
        guard let repo = repoSource() else { return nil }
        return repo.url.appendingPathComponent(tab.path).path
    }

    /// Opens a working-tree-vs-HEAD diff for the tab in a new detail diff tab.
    func showDiffInNewTab(for tab: OpenFileTab) {
        main.openDiffTab(
            commitHash: "HEAD",
            commitShortHash: "HEAD",
            path: tab.path,
            mode: .commitVsWorking,
            forceNew: true
        )
    }

    /// `refreshSymbols` re-harvests completion names (a repo-wide grep) — done
    /// on ⌘S, skipped for the frequent background auto-saves.
    func saveFileTab(_ tab: OpenFileTab, refreshSymbols: Bool = true) async {
        guard !tab.isBinary else { return }
        // Someone else wrote the file since we loaded it: ask before clobbering.
        if tab.diskConflict != nil { presentConflict(tab); return }
        if let disk = diskText(of: tab), disk != tab.originalContent, disk != tab.content {
            tab.diskConflict = disk
            presentConflict(tab)
            return
        }
        do {
            if tab.path.hasPrefix("/") {
                try tab.content.write(to: URL(fileURLWithPath: tab.path), atomically: true, encoding: .utf8)
                tab.originalContent = tab.content
                return
            }
            guard let repo = repoSource() else { return }
            try fileEditor.write(at: repo.url, path: tab.path, content: tab.content)
            tab.originalContent = tab.content
            await onSaved()
            // Saved edits may have introduced new declarations.
            if refreshSymbols { await loadRepoSymbols(force: true) }
            if tab.blame != nil { await loadBlame(tab) }
        } catch {
            main.errorMessage = "Save failed: \(error.localizedDescription)"
        }
    }
}
