import Foundation
import Combine

@MainActor
final class MainViewModel: ObservableObject {
    enum Tab: Hashable { case changes, history, files }
    enum DetailTab: Hashable { case content, compare }

    @Published var tab: Tab = .changes
    @Published var detailTab: DetailTab = .content
    @Published var comparePair: ComparePair? = nil
    @Published var errorMessage: String?
    @Published var isBusy: Bool = false
    @Published var sidebarWidth: CGFloat = 280

    func openCompare(_ pair: ComparePair) {
        comparePair = pair
        detailTab = .compare
    }

    func closeCompare() {
        comparePair = nil
        detailTab = .content
    }
}
