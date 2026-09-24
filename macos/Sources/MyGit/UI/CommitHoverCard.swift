import SwiftUI

extension View {
    /// Shows the commit's full details in a popover after the pointer rests on
    /// the row, for rows too narrow to show the whole subject, refs and author.
    func commitHoverCard(_ commit: GitCommit) -> some View {
        modifier(CommitHoverCardModifier(commit: commit))
    }
}

private struct CommitHoverCardModifier: ViewModifier {
    let commit: GitCommit
    @State private var isShown = false
    @State private var pending: Task<Void, Never>?

    /// Long enough that sweeping across rows or scrolling doesn't flash cards.
    private static let delay: UInt64 = 600_000_000

    func body(content: Content) -> some View {
        content
            .onHover { inside in
                pending?.cancel()
                if inside {
                    pending = Task { @MainActor in
                        try? await Task.sleep(nanoseconds: Self.delay)
                        if !Task.isCancelled { isShown = true }
                    }
                } else {
                    isShown = false
                }
            }
            // Clicking selects the row; the card would only get in the way.
            .simultaneousGesture(TapGesture().onEnded {
                pending?.cancel()
                isShown = false
            })
            .popover(isPresented: $isShown, arrowEdge: .trailing) {
                CommitHoverCard(commit: commit)
            }
    }
}

/// Full details of one commit: message, refs, author, dates and hashes.
struct CommitHoverCard: View {
    let commit: GitCommit

    private var body_: String {
        commit.body.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(commit.subject)
                .font(.system(size: 13, weight: .semibold))
                .fixedSize(horizontal: false, vertical: true)
                .textSelection(.enabled)

            if !body_.isEmpty {
                Text(body_)
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .lineLimit(12)
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)
            }

            if !commit.refs.isEmpty {
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(Array(commit.refs.enumerated()), id: \.offset) { _, ref in
                        RefBadge(ref: ref).fixedSize()
                    }
                }
            }

            Divider()

            Grid(alignment: .leading, horizontalSpacing: 10, verticalSpacing: 4) {
                row("Author", "\(commit.author) <\(commit.email)>")
                row("Date", "\(commit.date.formatted(date: .abbreviated, time: .shortened)) · \(commit.date.formatted(.relative(presentation: .named)))")
                row("Commit", commit.id, mono: true)
                if !commit.parents.isEmpty {
                    row(commit.parents.count > 1 ? "Parents" : "Parent",
                        commit.parents.map { String($0.prefix(7)) }.joined(separator: ", "), mono: true)
                }
            }
            .font(.system(size: 11))
        }
        .padding(14)
        .frame(width: 380, alignment: .leading)
    }

    private func row(_ label: String, _ value: String, mono: Bool = false) -> some View {
        GridRow {
            Text(label)
                .foregroundStyle(.secondary)
                .gridColumnAlignment(.trailing)
            Text(value)
                .font(mono ? .system(size: 11, design: .monospaced) : .system(size: 11))
                .fixedSize(horizontal: false, vertical: true)
                .textSelection(.enabled)
        }
    }
}

/// Shows `CommitHoverCard` in an AppKit popover anchored to a rect of an
/// NSView — for AppKit surfaces (the editor gutter's blame column).
enum CommitCardPopover {
    private static var current: NSPopover?

    static func show(_ commit: GitCommit, relativeTo rect: NSRect, of view: NSView) {
        current?.close()
        let popover = NSPopover()
        popover.behavior = .transient
        popover.contentViewController = NSHostingController(rootView: CommitHoverCard(commit: commit))
        popover.show(relativeTo: rect, of: view, preferredEdge: .maxX)
        current = popover
    }
}
