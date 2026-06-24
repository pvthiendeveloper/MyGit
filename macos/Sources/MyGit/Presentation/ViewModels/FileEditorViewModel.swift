import Foundation

@MainActor
final class FileEditorViewModel: ObservableObject {
    @Published var openFileTabs: [OpenFileTab] = []
    @Published var activeFileTabId: UUID?

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
    }

    func openFile(_ node: FileTreeNode) {
        guard !node.isDirectory else { return }
        if let existing = openFileTabs.first(where: { $0.path == node.id }) {
            activeFileTabId = existing.id
            return
        }
        let tab = OpenFileTab(path: node.id)
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
        openFileTabs.remove(at: idx)
        if activeFileTabId == id {
            if openFileTabs.isEmpty {
                activeFileTabId = nil
            } else {
                let newIdx = min(idx, openFileTabs.count - 1)
                activeFileTabId = openFileTabs[newIdx].id
            }
        }
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
