import Foundation

@MainActor
final class FileEditorViewModel: ObservableObject {
    @Published var openFileTabs: [OpenFileTab] = []
    @Published var activeFileTabId: UUID?
    @Published private(set) var closedPaths: [String] = []

    var activeFileTab: OpenFileTab? {
        guard let id = activeFileTabId else { return nil }
        return openFileTabs.first { $0.id == id }
    }

    private let fileEditor: FileEditorRepository
    private let main: MainViewModel
    private let repoSource: () -> Repository?
    private let onSaved: () async -> Void

    init(
        fileEditor: FileEditorRepository,
        main: MainViewModel,
        repoSource: @escaping () -> Repository?,
        onSaved: @escaping () async -> Void
    ) {
        self.fileEditor = fileEditor
        self.main = main
        self.repoSource = repoSource
        self.onSaved = onSaved
    }

    func repositoryDidChange() {
        openFileTabs.removeAll()
        activeFileTabId = nil
        closedPaths.removeAll()
    }

    func openFile(_ node: FileTreeNode) {
        guard !node.isDirectory else { return }
        openFile(path: node.id)
    }

    func openFile(path: String) {
        if let existing = openFileTabs.first(where: { $0.path == path }) {
            activeFileTabId = existing.id
            return
        }
        let tab = OpenFileTab(path: path)
        openFileTabs.append(tab)
        activeFileTabId = tab.id
        Task { await loadFileTab(tab) }
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
    }

    func closeOtherFileTabs(keep id: UUID) {
        for tab in openFileTabs where tab.id != id {
            recordClosed(tab.path)
        }
        openFileTabs.removeAll { $0.id != id }
        activeFileTabId = id
    }

    func closeAllFileTabs() {
        for tab in openFileTabs {
            recordClosed(tab.path)
        }
        openFileTabs.removeAll()
        activeFileTabId = nil
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
        } catch {
            main.errorMessage = "Save failed: \(error.localizedDescription)"
        }
    }
}
