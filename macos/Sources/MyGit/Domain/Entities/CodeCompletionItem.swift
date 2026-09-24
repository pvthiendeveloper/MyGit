import Foundation

/// One semantic completion candidate (from a language server), already mapped
/// onto the buffer it was requested for.
struct CodeCompletionItem: Hashable {
    /// What the popup shows, e.g. `padding(_ insets: EdgeInsets)`.
    let label: String
    /// What goes into the buffer, e.g. `padding()`.
    let insertText: String
    /// Type or signature, e.g. `VerticalAlignment`.
    let detail: String?
    /// UTF-16 range of the buffer the insertion replaces (the partial word).
    let replaceRange: NSRange
}
