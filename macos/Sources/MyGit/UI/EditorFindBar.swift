import SwiftUI
import Combine

/// Find / replace state for one editor tab (⌘F). Owns the match list; the
/// `CodeEditor` subscribes to it to paint highlights and reveal the current hit.
@MainActor
final class EditorFindState: ObservableObject {
    @Published var isVisible = false
    @Published var showReplace = false
    @Published var query = ""
    @Published var replacement = ""
    @Published var matchCase = false
    @Published var wholeWords = false
    @Published var useRegex = false
    @Published private(set) var matches: [NSRange] = []
    @Published private(set) var current: Int = -1
    @Published private(set) var regexError: String?
    /// Bumped to ask the find field to take focus (and select its text).
    @Published private(set) var focusToken = UUID()
    /// Bumped when the editor should select + scroll to the current match.
    @Published private(set) var revealToken = UUID()

    /// Current text of the tab, read whenever the query or options change.
    var textSource: () -> String = { "" }
    /// Installed by the editor: replace `range` with `string` through the text
    /// view, so the edit is undoable.
    var performReplace: ((NSRange, String) -> Void)?

    private static let matchLimit = 10_000
    private var cancellables: Set<AnyCancellable> = []

    init() {
        Publishers.CombineLatest4($query, $matchCase, $wholeWords, $useRegex)
            .dropFirst()
            .debounce(for: .milliseconds(60), scheduler: DispatchQueue.main)
            .sink { [weak self] _ in
                guard let self, self.isVisible else { return }
                self.recompute(reveal: true)
            }
            .store(in: &cancellables)
    }

    var resultLabel: String {
        if regexError != nil { return "Bad regex" }
        if matches.isEmpty { return "0 results" }
        let suffix = matches.count >= Self.matchLimit ? "+" : ""
        return current >= 0 ? "\(current + 1)/\(matches.count)\(suffix)" : "\(matches.count)\(suffix) results"
    }

    /// Show the bar and focus it; a single-line selection seeds the query.
    func present(seed: String?) {
        if let seed, !seed.isEmpty, !seed.contains("\n") { query = seed }
        isVisible = true
        focusToken = UUID()
        recompute(reveal: true)
    }

    func close() {
        isVisible = false
        matches = []
        current = -1
    }

    func next() { step(+1) }
    func previous() { step(-1) }

    private func step(_ delta: Int) {
        guard !matches.isEmpty else { return }
        current = current < 0 ? (delta > 0 ? 0 : matches.count - 1)
            : (current + delta + matches.count) % matches.count
        revealToken = UUID()
    }

    private func buildRegex() -> NSRegularExpression? {
        guard !query.isEmpty else { return nil }
        var pattern = useRegex ? query : NSRegularExpression.escapedPattern(for: query)
        if wholeWords { pattern = "\\b(?:\(pattern))\\b" }
        var options: NSRegularExpression.Options = [.anchorsMatchLines]
        if !matchCase { options.insert(.caseInsensitive) }
        do {
            regexError = nil
            return try NSRegularExpression(pattern: pattern, options: options)
        } catch {
            regexError = error.localizedDescription
            return nil
        }
    }

    /// Re-run the search. `reveal` jumps to the nearest hit (typing a query);
    /// without it (the file was edited) the current hit just stays close by.
    func recompute(reveal: Bool) {
        guard isVisible else { return }
        let text = textSource()
        let anchor = current >= 0 && current < matches.count ? matches[current].location : 0
        guard let regex = buildRegex() else {
            matches = []
            current = -1
            return
        }
        var found: [NSRange] = []
        let ns = text as NSString
        regex.enumerateMatches(in: text, range: NSRange(location: 0, length: ns.length)) { result, _, stop in
            guard let r = result?.range, r.length > 0 else { return }
            found.append(r)
            if found.count >= Self.matchLimit { stop.pointee = true }
        }
        matches = found
        current = found.isEmpty ? -1 : (found.firstIndex { $0.location >= anchor } ?? 0)
        if reveal, current >= 0 { revealToken = UUID() }
    }

    func replaceCurrent() {
        guard current >= 0, current < matches.count, let regex = buildRegex() else { return }
        let text = textSource()
        let range = matches[current]
        guard NSMaxRange(range) <= (text as NSString).length else { return }
        // For regex, expand the template ($1…) against just this match.
        let expanded: String
        if useRegex, let match = regex.firstMatch(in: text, range: range) {
            expanded = regex.replacementString(for: match, in: text, offset: 0, template: replacement)
        } else {
            expanded = replacement
        }
        performReplace?(range, expanded)
        recomputeAfterEdit()
    }

    func replaceAll() {
        guard !matches.isEmpty, let regex = buildRegex() else { return }
        let text = textSource()
        let full = NSRange(location: 0, length: (text as NSString).length)
        let template = useRegex ? self.replacement : NSRegularExpression.escapedTemplate(for: self.replacement)
        let result = regex.stringByReplacingMatches(in: text, range: full, withTemplate: template)
        performReplace?(full, result)
        recomputeAfterEdit()
    }

    /// The tab's content updates through the binding on the next pass.
    private func recomputeAfterEdit() {
        DispatchQueue.main.async { [weak self] in self?.recompute(reveal: true) }
    }
}

/// IntelliJ-style find bar: query field with Cc / W / .* toggles, result count,
/// previous / next, options menu, close. The chevron expands a replace row.
struct EditorFindBar: View {
    @ObservedObject var find: EditorFindState
    @FocusState private var focus: Field?

    private enum Field { case query, replacement }

    var body: some View {
        VStack(spacing: 6) {
            HStack(spacing: 8) {
                Button { find.showReplace.toggle() } label: {
                    Image(systemName: "chevron.right")
                        .rotationEffect(.degrees(find.showReplace ? 90 : 0))
                        .frame(width: 14)
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                .help(find.showReplace ? "Hide Replace" : "Show Replace")

                queryField
                    .frame(maxWidth: 420)

                Text(find.resultLabel)
                    .font(.system(size: 12))
                    .foregroundStyle(find.regexError != nil ? Color.red : Color.secondary)
                    .help(find.regexError ?? "")
                    .frame(minWidth: 70, alignment: .leading)

                iconButton("arrow.up", help: "Previous Occurrence (⇧↩ / ⌘⇧G)") { find.previous() }
                    .disabled(find.matches.isEmpty)
                iconButton("arrow.down", help: "Next Occurrence (↩ / ⌘G)") { find.next() }
                    .disabled(find.matches.isEmpty)

                Menu {
                    Toggle("Match Case", isOn: $find.matchCase)
                    Toggle("Words", isOn: $find.wholeWords)
                    Toggle("Regex", isOn: $find.useRegex)
                    Divider()
                    Toggle("Replace", isOn: $find.showReplace)
                } label: {
                    Image(systemName: "ellipsis").rotationEffect(.degrees(90))
                }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .fixedSize()

                Spacer()

                iconButton("xmark", help: "Close (Esc)") { find.close() }
            }
            if find.showReplace {
                HStack(spacing: 8) {
                    Color.clear.frame(width: 14, height: 1)
                    replaceField
                        .frame(maxWidth: 420)
                    Button("Replace") { find.replaceCurrent() }
                        .disabled(find.current < 0)
                    Button("Replace All") { find.replaceAll() }
                        .disabled(find.matches.isEmpty)
                    Spacer()
                }
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(Color(NSColor.windowBackgroundColor))
        .onAppear { focus = .query }
        .onChange(of: find.focusToken) { _, _ in focus = .query }
        .onExitCommand { find.close() }
    }

    private var queryField: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
            TextField("Search", text: $find.query)
                .textFieldStyle(.plain)
                .focused($focus, equals: .query)
                .onKeyPress(.return, phases: .down) { press in
                    if press.modifiers.contains(.control) && press.modifiers.contains(.shift) {
                        find.query += "\n"
                    } else if press.modifiers.contains(.shift) {
                        find.previous()
                    } else {
                        find.next()
                    }
                    return .handled
                }
            toggle(systemImage: "return", on: false, help: "New Line (⌃⇧↩)") { find.query += "\n" }
            toggle(text: "Cc", on: find.matchCase, help: "Match Case") { find.matchCase.toggle() }
            toggle(text: "W", on: find.wholeWords, help: "Words") { find.wholeWords.toggle() }
            toggle(text: ".*", on: find.useRegex, help: "Regex") { find.useRegex.toggle() }
        }
        .fieldChrome(focused: focus == .query)
    }

    private var replaceField: some View {
        HStack(spacing: 6) {
            Image(systemName: "arrow.2.squarepath").foregroundStyle(.secondary)
            TextField("Replace", text: $find.replacement)
                .textFieldStyle(.plain)
                .focused($focus, equals: .replacement)
                .onSubmit { find.replaceCurrent() }
        }
        .fieldChrome(focused: focus == .replacement)
    }

    private func iconButton(_ name: String, help: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: name).frame(width: 18, height: 18)
        }
        .buttonStyle(.plain)
        .foregroundStyle(.secondary)
        .help(help)
    }

    @ViewBuilder
    private func toggle(text: String? = nil, systemImage: String? = nil, on: Bool,
                        help: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Group {
                if let text { Text(text).font(.system(size: 12, weight: .semibold, design: .monospaced)) }
                if let systemImage { Image(systemName: systemImage).font(.system(size: 11)) }
            }
            .frame(minWidth: 20, minHeight: 18)
            .padding(.horizontal, 2)
            .background(on ? Color.accentColor.opacity(0.25) : Color.clear,
                        in: RoundedRectangle(cornerRadius: 4))
            .foregroundStyle(on ? Color.accentColor : Color.secondary)
        }
        .buttonStyle(.plain)
        .help(help)
    }
}

private extension View {
    func fieldChrome(focused: Bool) -> some View {
        padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(Color(NSColor.textBackgroundColor), in: RoundedRectangle(cornerRadius: 6))
            .overlay(
                RoundedRectangle(cornerRadius: 6)
                    .stroke(focused ? Color.accentColor : Color.secondary.opacity(0.3),
                            lineWidth: focused ? 2 : 1)
            )
    }
}
