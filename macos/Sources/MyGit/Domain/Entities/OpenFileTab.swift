import Foundation

/// A request to put the caret on a line and scroll it into view. The token lets
/// the same line be targeted twice in a row.
struct EditorGoto: Equatable {
    let line: Int          // 1-based
    let token: UUID

    init(line: Int, token: UUID = UUID()) {
        self.line = line
        self.token = token
    }
}

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
    /// Line the editor should reveal next (⌘-click navigation, usage picker).
    @Published var goto: EditorGoto?

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
