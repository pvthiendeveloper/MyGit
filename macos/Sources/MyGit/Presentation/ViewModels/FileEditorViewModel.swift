import Foundation

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

    var activeFileTab: OpenFileTab? {
        guard let id = activeFileTabId else { return nil }
        return openFileTabs.first { $0.id == id }
    }

    private let fileEditor: FileEditorRepository
    private let git: GitRepository
    private let main: MainViewModel
    private let repoSource: () -> Repository?
    private let onSaved: () async -> Void

    init(
        fileEditor: FileEditorRepository,
        git: GitRepository,
        main: MainViewModel,
        repoSource: @escaping () -> Repository?,
        onSaved: @escaping () async -> Void
    ) {
        self.fileEditor = fileEditor
        self.git = git
        self.main = main
        self.repoSource = repoSource
        self.onSaved = onSaved
    }

    // MARK: - Completion

    /// Harvest the repo's declared names once per session (and after a save, so
    /// new declarations show up). One `git grep` over tracked files.
    func loadRepoSymbols(force: Bool = false) async {
        guard let repo = repoSource(), force || !symbolsLoaded else { return }
        symbolsLoaded = true
        repoSymbols = (try? await git.declaredSymbols(at: repo.url)) ?? []
    }

    // MARK: - ⌘-click navigation

    /// Resolve a ⌘-clicked identifier the way an IDE would, but backed by
    /// `git grep` instead of a language server:
    /// - clicked on a use, one declaration found → jump straight to it;
    /// - clicked on the declaration itself → list the usages to pick from;
    /// - several declarations (or no declaration at all) → let the user choose.
    func goToDefinition(symbol: String, line: Int, in tab: OpenFileTab) {
        guard let repo = repoSource() else { return }
        resolvingSymbol = symbol
        Task {
            defer { resolvingSymbol = nil }
            let matches: [GitGrepMatch]
            do { matches = try await git.searchSymbol(symbol, at: repo.url) }
            catch {
                main.errorMessage = error.localizedDescription
                return
            }
            let occurrences = matches.map {
                SymbolOccurrence(
                    path: $0.path,
                    line: $0.line,
                    preview: $0.preview,
                    isDefinition: SymbolClassifier.isDefinition(line: $0.preview, symbol: symbol)
                )
            }
            guard !occurrences.isEmpty else {
                main.errorMessage = "No occurrences of \"\(symbol)\" in tracked files."
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
                    originLine: line
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
        openFile(path: occurrence.path)
        guard let tab = openFileTabs.first(where: { $0.path == occurrence.path }) else { return }
        tab.goto = EditorGoto(line: occurrence.line)
    }

    func repositoryDidChange() {
        openFileTabs.removeAll()
        activeFileTabId = nil
        closedPaths.removeAll()
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
        let tab = OpenFileTab(path: path)
        openFileTabs.append(tab)
        activeFileTabId = tab.id
        main.detailTab = .editor(tab.id)
        Task { await loadFileTab(tab) }
    }

    /// Makes the given editor tab both the active file tab and the visible
    /// detail tab, so selecting a chip in the unified tab bar switches content.
    func selectFileTab(id: UUID) {
        activeFileTabId = id
        main.detailTab = .editor(id)
    }

    private func loadFileTab(_ tab: OpenFileTab) async {
        guard let repo = repoSource() else { return }
        tab.isLoading = true
        defer { tab.isLoading = false }
        do {
            let data = try fileEditor.read(at: repo.url, path: tab.path)
            if let text = decodeText(data) {
                tab.content = text
                tab.originalContent = text
                tab.isBinary = false
            } else {
                tab.isBinary = true
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

    func closeFileTab(id: UUID) {
        guard let idx = openFileTabs.firstIndex(where: { $0.id == id }) else { return }
        let removed = openFileTabs.remove(at: idx)
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
            recordClosed(tab.path)
        }
        openFileTabs.removeAll { $0.id != id }
        activeFileTabId = id
        syncDetailTab()
    }

    func closeAllFileTabs() {
        for tab in openFileTabs {
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

    func saveFileTab(_ tab: OpenFileTab) async {
        guard let repo = repoSource(), !tab.isBinary else { return }
        do {
            try fileEditor.write(at: repo.url, path: tab.path, content: tab.content)
            tab.originalContent = tab.content
            await onSaved()
            // Saved edits may have introduced new declarations.
            await loadRepoSymbols(force: true)
        } catch {
            main.errorMessage = "Save failed: \(error.localizedDescription)"
        }
    }
}
