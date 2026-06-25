import Foundation
import Combine

@MainActor
final class MainViewModel: ObservableObject {
    enum Tab: Hashable { case changes, history, files }
    enum DetailTab: Hashable {
        case content
        case compare
        case diff(UUID)
    }

    @Published var tab: Tab = .changes
    @Published var detailTab: DetailTab = .content
    @Published var comparePair: ComparePair? = nil
    @Published var errorMessage: String?
    @Published var isBusy: Bool = false
    @Published var sidebarWidth: CGFloat = 280
    @Published var diffTabs: [DiffTab] = []
    @Published private(set) var tabHistory: [UUID] = []
    @Published private(set) var tabHistoryIndex: Int = -1
    private var navigating: Bool = false

    var canNavigateBackTab: Bool { tabHistoryIndex > 0 }
    var canNavigateForwardTab: Bool { tabHistoryIndex + 1 < tabHistory.count }

    func openCompare(_ pair: ComparePair) {
        comparePair = pair
        detailTab = .compare
    }

    func closeCompare() {
        comparePair = nil
        if case .compare = detailTab {
            detailTab = diffTabs.last.map { .diff($0.id) } ?? .content
        }
    }

    func openDiffTab(commitHash: String, commitShortHash: String, path: String, mode: DiffTab.Mode, forceNew: Bool) {
        if !forceNew,
           let existing = diffTabs.first(where: { $0.commitHash == commitHash && $0.path == path && $0.mode == mode }) {
            detailTab = .diff(existing.id)
            pushHistory(existing.id)
            return
        }
        let tab = DiffTab(commitHash: commitHash, commitShortHash: commitShortHash, path: path, mode: mode)
        diffTabs.append(tab)
        detailTab = .diff(tab.id)
        pushHistory(tab.id)
    }

    func selectDiffTab(_ id: UUID) {
        detailTab = .diff(id)
        pushHistory(id)
    }

    func closeDiffTab(_ id: UUID) {
        let wasActive: Bool = {
            if case let .diff(active) = detailTab { return active == id }
            return false
        }()
        diffTabs.removeAll { $0.id == id }
        tabHistory.removeAll { $0 == id }
        tabHistoryIndex = min(tabHistoryIndex, tabHistory.count - 1)
        if wasActive {
            if tabHistoryIndex >= 0 {
                let next = tabHistory[tabHistoryIndex]
                detailTab = .diff(next)
            } else if let last = diffTabs.last {
                detailTab = .diff(last.id)
                pushHistory(last.id)
            } else if comparePair != nil {
                detailTab = .compare
            } else {
                detailTab = .content
            }
        }
    }

    func navigateBackTab() {
        guard canNavigateBackTab else { return }
        tabHistoryIndex -= 1
        let id = tabHistory[tabHistoryIndex]
        navigating = true
        detailTab = .diff(id)
        navigating = false
    }

    func navigateForwardTab() {
        guard canNavigateForwardTab else { return }
        tabHistoryIndex += 1
        let id = tabHistory[tabHistoryIndex]
        navigating = true
        detailTab = .diff(id)
        navigating = false
    }

    private func pushHistory(_ id: UUID) {
        if navigating { return }
        if tabHistoryIndex >= 0, tabHistoryIndex < tabHistory.count, tabHistory[tabHistoryIndex] == id {
            return
        }
        if tabHistoryIndex + 1 < tabHistory.count {
            tabHistory.removeSubrange((tabHistoryIndex + 1)...)
        }
        tabHistory.append(id)
        tabHistoryIndex = tabHistory.count - 1
    }
}
