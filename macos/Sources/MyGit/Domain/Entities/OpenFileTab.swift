import Foundation
import Combine
import AppKit

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

/// A spot in the editor, as Back/Forward navigation remembers it.
struct EditorLocation: Equatable {
    let path: String
    let line: Int          // 1-based
}

/// How a Markdown file is shown: source, rendered, or both side by side.
enum MarkdownViewMode: String, CaseIterable, Identifiable {
    case editor, split, preview
    var id: String { rawValue }

    var label: String {
        switch self {
        case .editor: return "Source"
        case .split: return "Split"
        case .preview: return "Preview"
        }
    }

    var symbol: String {
        switch self {
        case .editor: return "chevron.left.forwardslash.chevron.right"
        case .split: return "rectangle.split.2x1"
        case .preview: return "doc.richtext"
        }
    }
}

@MainActor
final class OpenFileTab: Identifiable, ObservableObject {
    let id = UUID()
    @Published private(set) var path: String   // repo-relative
    @Published private(set) var name: String   // leaf
    @Published var content: String = ""
    @Published var originalContent: String = ""
    @Published var isLoading: Bool = true
    @Published var isBinary: Bool = false
    /// Decoded image for binary files AppKit can render (png, jpg, gif, pdf…).
    @Published var image: NSImage?
    @Published var loadError: String?
    /// The file's text on disk when another program changed it while this tab
    /// had unsaved edits. Non-nil until the user picks a version; saving (and
    /// auto-save) holds off meanwhile so neither side is silently lost.
    @Published var diskConflict: String?
    /// Git blame annotations for the gutter; nil = off.
    @Published var blame: [BlameLine]?
    /// Line the editor should reveal next (⌘-click navigation, usage picker).
    @Published var goto: EditorGoto?
    /// 1-based line the caret is on, kept current by the editor so navigation
    /// history knows where the user was. Not published — it changes per keystroke.
    var caretLine: Int = 1
    /// Current selection (UTF-16), for Claude Code's IDE integration. Not
    /// published — it changes per keystroke.
    var selection = NSRange(location: 0, length: 0)
    /// Markdown files open split (source + rendered), like an IDE's .md view.
    @Published var markdownMode: MarkdownViewMode = .split
    /// ⌘F find / replace bar state for this tab.
    let find = EditorFindState()
    private var findSink: AnyCancellable?

    /// True for files the Markdown preview understands.
    var isMarkdown: Bool {
        ["md", "markdown", "mdx"].contains((name as NSString).pathExtension.lowercased())
    }

    var isDirty: Bool { content != originalContent }

    init(path: String) {
        self.path = path
        self.name = Self.leaf(of: path)
        find.textSource = { [weak self] in self?.content ?? "" }
        // Keep hits in sync with edits, without jumping the view around.
        findSink = $content
            .dropFirst()
            .debounce(for: .milliseconds(150), scheduler: DispatchQueue.main)
            .sink { [weak self] _ in self?.find.recompute(reveal: false) }
    }

    /// Point the tab at a new path after the file (or a parent folder) was
    /// renamed on disk. Content and unsaved edits stay as they are.
    func move(to newPath: String) {
        path = newPath
        name = Self.leaf(of: newPath)
    }

    private static func leaf(of path: String) -> String {
        guard let slash = path.lastIndex(of: "/") else { return path }
        return String(path[path.index(after: slash)...])
    }
}
