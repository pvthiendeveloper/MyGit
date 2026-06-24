import Foundation

@MainActor
final class OpenFileTab: Identifiable, ObservableObject {
    let id = UUID()
    let path: String        // repo-relative
    let name: String        // leaf
    @Published var content: String = ""
    @Published var originalContent: String = ""
    @Published var isLoading: Bool = true
    @Published var isBinary: Bool = false
    @Published var loadError: String?

    var isDirty: Bool { content != originalContent }

    init(path: String) {
        self.path = path
        if let slash = path.lastIndex(of: "/") {
            self.name = String(path[path.index(after: slash)...])
        } else {
            self.name = path
        }
    }
}
