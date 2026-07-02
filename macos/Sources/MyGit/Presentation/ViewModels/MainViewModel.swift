import Foundation
import Combine

@MainActor
final class MainViewModel: ObservableObject {
    enum Tab: Hashable { case changes, stash, history, files, pullRequests }
    enum DetailTab: Hashable {
        case content
        case compare
        case diff(UUID)
        case editor(UUID)
        case patch(UUID)
    }

    /// A read-only diff tab backed by a pre-parsed patch (e.g. a remote PR
    /// file), rendered with `DiffView`. Unlike `DiffTab` it carries its content
    /// and never touches local git.
    struct PatchTab: Identifiable {
        let id = UUID()
        let key: String      // dedup key (e.g. "pr:<num>:<path>")
        let title: String
        let diff: FileDiff
    }

    @Published var tab: Tab = .changes
    /// Programmatically opens the toolbar's branch popover (from the Changes Git menu).
    @Published var showBranchPopover = false
    @Published var detailTab: DetailTab = .content
    @Published var comparePair: ComparePair? = nil
    @Published var errorMessage: String?
    @Published var isBusy: Bool = false
    @Published var sidebarWidth: CGFloat = 280
    @Published var diffTabs: [DiffTab] = []
    @Published var patchTabs: [PatchTab] = []
    @Published private(set) var tabHistory: [UUID] = []
    @Published private(set) var tabHistoryIndex: Int = -1
    @Published private(set) var hasClosedDiffTabs: Bool = false
    private var navigating: Bool = false

    private struct ClosedDiff {
        let commitHash: String
        let commitShortHash: String
        let path: String
        let mode: DiffTab.Mode
    }
    private var closedDiffs: [ClosedDiff] = []

    var canNavigateBackTab: Bool { tabHistoryIndex > 0 }
    var canNavigateForwardTab: Bool { tabHistoryIndex + 1 < tabHistory.count }

    /// Picks a sensible detail tab when the current one (usually an editor tab)
    /// goes away: prefer the last diff tab, then compare, then plain content.
    func fallbackDetailTab() {
        if let last = diffTabs.last { detailTab = .diff(last.id) }
        else if comparePair != nil { detailTab = .compare }
        else { detailTab = .content }
    }

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

    /// Open (or focus, if already open) a read-only patch tab.
    func openPatchTab(key: String, title: String, diff: FileDiff) {
        if let existing = patchTabs.first(where: { $0.key == key }) {
            detailTab = .patch(existing.id)
            return
        }
        let tab = PatchTab(key: key, title: title, diff: diff)
        patchTabs.append(tab)
        detailTab = .patch(tab.id)
    }

    func closePatchTab(_ id: UUID) {
        let wasActive: Bool = {
            if case let .patch(active) = detailTab { return active == id }
            return false
        }()
        patchTabs.removeAll { $0.id == id }
        if wasActive {
            if let last = patchTabs.last { detailTab = .patch(last.id) }
            else { fallbackDetailTab() }
        }
    }

    func closeDiffTab(_ id: UUID) {
        let wasActive: Bool = {
            if case let .diff(active) = detailTab { return active == id }
            return false
        }()
        if let tab = diffTabs.first(where: { $0.id == id }) {
            recordClosedDiff(tab)
        }
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

    func closeOtherDiffTabs(keep id: UUID) {
        for tab in diffTabs where tab.id != id {
            recordClosedDiff(tab)
        }
        diffTabs.removeAll { $0.id != id }
        tabHistory.removeAll { $0 != id }
        tabHistoryIndex = tabHistory.isEmpty ? -1 : tabHistory.count - 1
        detailTab = .diff(id)
    }

    func closeAllDiffTabs() {
        for tab in diffTabs {
            recordClosedDiff(tab)
        }
        diffTabs.removeAll()
        tabHistory.removeAll()
        tabHistoryIndex = -1
        detailTab = comparePair != nil ? .compare : .content
    }

    func reopenClosedDiffTab() {
        guard let d = closedDiffs.popLast() else { return }
        hasClosedDiffTabs = !closedDiffs.isEmpty
        openDiffTab(
            commitHash: d.commitHash,
            commitShortHash: d.commitShortHash,
            path: d.path,
            mode: d.mode,
            forceNew: true
        )
    }

    private func recordClosedDiff(_ tab: DiffTab) {
        closedDiffs.append(ClosedDiff(
            commitHash: tab.commitHash,
            commitShortHash: tab.commitShortHash,
            path: tab.path,
            mode: tab.mode
        ))
        hasClosedDiffTabs = true
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
