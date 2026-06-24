import Foundation
import Combine

@MainActor
final class MainViewModel: ObservableObject {
    enum Tab: Hashable { case changes, history, files }

    @Published var tab: Tab = .changes
    @Published var errorMessage: String?
    @Published var isBusy: Bool = false
}
