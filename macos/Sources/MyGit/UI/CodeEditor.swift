import SwiftUI
import AppKit
import Combine

/// An editable, monospaced code editor with a left line-number gutter (like
/// IntelliJ / VS Code) and optional syntax highlighting. An `NSTextView` in an
/// `NSScrollView` renders the code; a separate `LineNumberGutter` view sits to
/// its left and draws numbers, tracking the text layout + vertical scroll.
///
/// The gutter is a sibling view — NOT an `NSRulerView` — because wiring a ruler
/// into this scroll view stopped the document view from drawing at all.
struct CodeEditor: NSViewRepresentable {
    @Binding var text: String
    var fontSize: CGFloat = 12
    /// File extension for syntax highlighting; nil disables it (plain text).
    var syntaxExt: String?
    /// False for previews (symbol lookup), where the text is only for reading.
    var isEditable: Bool = true
    /// Line to reveal (from ⌘-click navigation / search results).
    var goto: EditorGoto?
    /// ⌘-click on an identifier: (symbol, 1-based line it was clicked on).
    var onCommandClick: ((String, Int) -> Void)?
    /// Extra completion candidates (declared names across the repo). The buffer's
    /// own words are gathered by the text view itself.
    var completionSymbols: () -> [String] = { [] }
    /// Type-aware completions (full text, UTF-16 caret) from a language
    /// server; nil keeps plain word completion only.
    var semanticCompletion: ((String, Int) async -> [CodeCompletionItem]?)?
    /// Pop the completion list automatically while typing an identifier.
    var autocompleteWhileTyping = true
    /// The AI-continuation shortcut (⌘⇧P by default) asks this for a continuation at the caret (prefix, suffix).
    var aiSuggest: ((String, String) async -> String?)?
    /// Scroll position to follow, 0…1 of the scrollable height. Nil means this
    /// pane is driving (see the Markdown split view).
    var scrollFraction: CGFloat?
    /// Reports this pane's own scroll position as the user moves it.
    var onScrollFraction: ((CGFloat) -> Void)?
    /// Caret moved: (1-based line, whether the user moved it by navigating —
    /// false for typing and programmatic reveals). Feeds Back/Forward history.
    var onCaretLine: ((Int, Bool) -> Void)?
    /// Every selection change (a caret is an empty range), UTF-16 based.
    var onSelectionChange: ((NSRange) -> Void)?
    /// "Send to Claude Code" (shortcut / context menu); nil hides the command.
    var onMention: (() -> Void)?
    /// Git blame shown in the gutter; nil = annotations off.
    var blame: [BlameLine]?
    /// The buffer has unsaved edits, so blame lines may not line up.
    var blameStale = false
    /// Gutter right-click ▸ "Annotate with Git Blame"; nil hides the item.
    var onToggleBlame: (() -> Void)?
    /// A blame cell was clicked (commit, and the cell in the gutter's coordinates).
    var onBlameClick: ((BlameLine, NSView, NSRect) -> Void)?
    /// ⌘F find state whose matches this editor highlights.
    var find: EditorFindState?

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeNSView(context: Context) -> NSView {
        let tv = NavigableTextView()
        tv.onCommandClick = { [weak coordinator = context.coordinator] symbol, line in
            coordinator?.parent.onCommandClick?(symbol, line)
        }
        tv.completionSymbols = { [weak coordinator = context.coordinator] in
            coordinator?.parent.completionSymbols() ?? []
        }
        tv.autocompleteWhileTyping = autocompleteWhileTyping
        context.coordinator.wireSemanticCompletion(tv)
        tv.aiSuggest = { [weak coordinator = context.coordinator] prefix, suffix in
            await coordinator?.parent.aiSuggest?(prefix, suffix)
        }
        tv.onMention = onMention == nil ? nil : { [weak coordinator = context.coordinator] in
            coordinator?.parent.onMention?()
        }
        tv.delegate = context.coordinator
        tv.isRichText = false
        tv.isAutomaticQuoteSubstitutionEnabled = false
        tv.isAutomaticDashSubstitutionEnabled = false
        tv.isAutomaticSpellingCorrectionEnabled = false
        tv.isAutomaticTextReplacementEnabled = false
        tv.allowsUndo = true
        tv.isEditable = isEditable
        tv.font = NSFont.monospacedSystemFont(ofSize: fontSize, weight: .regular)
        tv.textColor = .textColor
        tv.textContainerInset = NSSize(width: 4, height: 4)
        tv.textContainer?.lineFragmentPadding = 2
        tv.drawsBackground = true
        tv.backgroundColor = .textBackgroundColor
        tv.string = text
        // No soft-wrap: one visual row per logical line, so gutter numbers align.
        tv.isHorizontallyResizable = true
        tv.isVerticallyResizable = true
        tv.autoresizingMask = []
        tv.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        tv.textContainer?.widthTracksTextView = false
        tv.textContainer?.size = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)

        let scroll = NSScrollView()
        scroll.documentView = tv
        scroll.hasVerticalScroller = true
        scroll.hasHorizontalScroller = true
        scroll.drawsBackground = true
        scroll.backgroundColor = .textBackgroundColor
        scroll.contentView.postsBoundsChangedNotifications = true
        scroll.translatesAutoresizingMaskIntoConstraints = false

        let gutter = LineNumberGutter(textView: tv, scrollView: scroll, fontSize: fontSize)
        gutter.blame = blame
        gutter.onToggleBlame = onToggleBlame == nil ? nil : { [weak coordinator = context.coordinator] in
            coordinator?.parent.onToggleBlame?()
        }
        gutter.onBlameClick = { [weak coordinator = context.coordinator, weak gutter] line, rect in
            guard let gutter else { return }
            coordinator?.parent.onBlameClick?(line, gutter, rect)
        }
        gutter.translatesAutoresizingMaskIntoConstraints = false

        let container = NSView()
        container.addSubview(scroll)
        container.addSubview(gutter)
        let gutterWidth = gutter.widthAnchor.constraint(equalToConstant: gutter.desiredWidth)
        NSLayoutConstraint.activate([
            gutter.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            gutter.topAnchor.constraint(equalTo: container.topAnchor),
            gutter.bottomAnchor.constraint(equalTo: container.bottomAnchor),
            gutterWidth,
            scroll.leadingAnchor.constraint(equalTo: gutter.trailingAnchor),
            scroll.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            scroll.topAnchor.constraint(equalTo: container.topAnchor),
            scroll.bottomAnchor.constraint(equalTo: container.bottomAnchor),
        ])
        gutter.widthConstraint = gutterWidth

        context.coordinator.textView = tv
        context.coordinator.scrollView = scroll
        context.coordinator.gutter = gutter
        context.coordinator.lastExt = syntaxExt
        context.coordinator.applyHighlight(tv)
        context.coordinator.bind(find: find)

        NotificationCenter.default.addObserver(
            context.coordinator, selector: #selector(Coordinator.viewChanged),
            name: NSView.boundsDidChangeNotification, object: scroll.contentView)
        NotificationCenter.default.addObserver(
            context.coordinator, selector: #selector(Coordinator.viewChanged),
            name: NSView.frameDidChangeNotification, object: tv)
        return container
    }

    func updateNSView(_ container: NSView, context: Context) {
        context.coordinator.parent = self
        if let gutter = context.coordinator.gutter {
            if gutter.blame != blame { gutter.blame = blame }
            gutter.blameStale = blameStale
        }
        guard let tv = context.coordinator.textView else { return }
        if tv.isEditable != isEditable { tv.isEditable = isEditable }
        if let tv = tv as? NavigableTextView {
            tv.autocompleteWhileTyping = autocompleteWhileTyping
            context.coordinator.wireSemanticCompletion(tv)
        }
        let textChanged = tv.string != text
        if textChanged {
            context.coordinator.isRevealing = true
            tv.string = text
            context.coordinator.isRevealing = false
        }
        let fontChanged = (tv.font?.pointSize ?? 0) != fontSize
        if fontChanged {
            tv.font = NSFont.monospacedSystemFont(ofSize: fontSize, weight: .regular)
        }
        let extChanged = context.coordinator.lastExt != syntaxExt
        if textChanged || fontChanged || extChanged {
            context.coordinator.lastExt = syntaxExt
            context.coordinator.applyHighlight(tv)
            context.coordinator.gutter?.refresh()
        }
        // A goto can arrive before the file's text does (the tab is still
        // loading), so retry it on every pass until it lands on real content.
        if let goto, context.coordinator.appliedGoto != goto.token, !tv.string.isEmpty {
            context.coordinator.appliedGoto = goto.token
            context.coordinator.reveal(line: goto.line, in: tv)
        }
        if let scrollFraction { context.coordinator.follow(fraction: scrollFraction) }
        context.coordinator.bind(find: find)
    }

    final class Coordinator: NSObject, NSTextViewDelegate {
        var parent: CodeEditor
        weak var textView: NSTextView?
        weak var scrollView: NSScrollView?
        weak var gutter: LineNumberGutter?
        var lastExt: String?
        var appliedGoto: UUID?
        private var highlightWork: DispatchWorkItem?
        /// Set while the caret moves because of us or an edit, not navigation.
        var isRevealing = false
        private var isEditing = false
        private weak var boundFind: EditorFindState?
        private var findSinks: Set<AnyCancellable> = []

        /// Forward to whatever closure the current `parent` holds; only the
        /// on/off state lives on the text view (the file type can change).
        func wireSemanticCompletion(_ tv: NavigableTextView) {
            let enabled = parent.semanticCompletion != nil
            guard enabled != (tv.semanticCompletion != nil) else { return }
            tv.semanticCompletion = enabled ? { [weak self] text, caret in
                await self?.parent.semanticCompletion?(text, caret)
            } : nil
        }

        // MARK: Find highlights

        /// Subscribe to a tab's find state: paint every hit, emphasize the
        /// current one, select + scroll to it on request, refocus on close.
        @MainActor func bind(find: EditorFindState?) {
            guard boundFind !== find else { return }
            findSinks.removeAll()
            boundFind = find
            if let tv = textView { paintMatches([], current: -1, in: tv) }
            guard let find else { return }
            find.performReplace = { [weak self] range, string in
                guard let tv = self?.textView,
                      NSMaxRange(range) <= (tv.string as NSString).length,
                      tv.shouldChangeText(in: range, replacementString: string) else { return }
                tv.textStorage?.replaceCharacters(in: range, with: string)
                tv.didChangeText()
            }
            Publishers.CombineLatest(find.$matches, find.$current)
                .receive(on: DispatchQueue.main)
                .sink { [weak self] matches, current in
                    guard let self, let tv = self.textView else { return }
                    self.paintMatches(matches, current: current, in: tv)
                }
                .store(in: &findSinks)
            find.$revealToken
                .dropFirst()
                .receive(on: DispatchQueue.main)
                .sink { [weak self, weak find] _ in
                    guard let self, let find, let tv = self.textView,
                          find.current >= 0, find.current < find.matches.count else { return }
                    self.revealMatch(find.matches[find.current], in: tv)
                }
                .store(in: &findSinks)
            find.$isVisible
                .dropFirst()
                .removeDuplicates()
                .filter { !$0 }
                .receive(on: DispatchQueue.main)
                .sink { [weak self] _ in
                    guard let tv = self?.textView else { return }
                    tv.window?.makeFirstResponder(tv)
                }
                .store(in: &findSinks)
        }

        private func paintMatches(_ matches: [NSRange], current: Int, in tv: NSTextView) {
            guard let lm = tv.layoutManager else { return }
            let length = (tv.string as NSString).length
            // Edits shift painted ranges, so clear the whole buffer each time.
            lm.removeTemporaryAttribute(.backgroundColor,
                                        forCharacterRange: NSRange(location: 0, length: length))
            let hit = NSColor.systemYellow.withAlphaComponent(0.35)
            let active = NSColor.systemOrange.withAlphaComponent(0.7)
            for (i, r) in matches.enumerated() where NSMaxRange(r) <= length {
                lm.addTemporaryAttribute(.backgroundColor, value: i == current ? active : hit,
                                         forCharacterRange: r)
            }
        }

        private func revealMatch(_ range: NSRange, in tv: NSTextView) {
            guard NSMaxRange(range) <= (tv.string as NSString).length else { return }
            isRevealing = true
            tv.setSelectedRange(range)
            isRevealing = false
            tv.scrollRangeToVisible(range)
            gutter?.needsDisplay = true
        }

        init(_ p: CodeEditor) { parent = p }

        /// Select a whole line and scroll it to the middle of the view.
        func reveal(line: Int, in tv: NSTextView) {
            isRevealing = true
            defer { isRevealing = false }
            let ns = tv.string as NSString
            var index = 0
            var current = 1
            while current < line, index < ns.length {
                index = NSMaxRange(ns.lineRange(for: NSRange(location: index, length: 0)))
                current += 1
            }
            guard index <= ns.length else { return }
            let lineRange = ns.lineRange(for: NSRange(location: min(index, max(0, ns.length - 1)), length: 0))
            tv.setSelectedRange(lineRange)
            tv.scrollRangeToVisible(lineRange)
            if let lm = tv.layoutManager, let tc = tv.textContainer, let clip = scrollView?.contentView {
                let rect = lm.boundingRect(forGlyphRange: lm.glyphRange(forCharacterRange: lineRange,
                                                                       actualCharacterRange: nil),
                                           in: tc)
                let target = max(0, rect.midY - clip.bounds.height / 2 + tv.textContainerInset.height)
                clip.scroll(to: NSPoint(x: clip.bounds.origin.x, y: target))
                scrollView?.reflectScrolledClipView(clip)
            }
            tv.window?.makeFirstResponder(tv)
            gutter?.needsDisplay = true
        }

        /// True while we're moving the scroll view ourselves, so the position
        /// we just applied isn't echoed back to the other pane.
        private var isFollowing = false

        @objc func viewChanged() {
            gutter?.needsDisplay = true
            guard !isFollowing, let report = parent.onScrollFraction,
                  let clip = scrollView?.contentView, let document = scrollView?.documentView else { return }
            let scrollable = document.frame.height - clip.bounds.height
            guard scrollable > 1 else { return }
            report(max(0, min(1, clip.bounds.origin.y / scrollable)))
        }

        /// Move this pane to a fraction of its scrollable height.
        func follow(fraction: CGFloat) {
            guard let scrollView, let clip = scrollView.contentView as NSClipView?,
                  let document = scrollView.documentView else { return }
            let scrollable = document.frame.height - clip.bounds.height
            guard scrollable > 1 else { return }
            let target = max(0, min(scrollable, fraction * scrollable))
            guard abs(clip.bounds.origin.y - target) > 1 else { return }
            isFollowing = true
            clip.scroll(to: NSPoint(x: clip.bounds.origin.x, y: target))
            scrollView.reflectScrolledClipView(clip)
            gutter?.needsDisplay = true
            // Re-arm after the bounds notification for this scroll has drained.
            DispatchQueue.main.async { [weak self] in self?.isFollowing = false }
        }

        func textView(_ textView: NSTextView, shouldChangeTextIn affectedCharRange: NSRange,
                      replacementString: String?) -> Bool {
            // The selection change that follows an edit (typing, paste) isn't a jump.
            isEditing = true
            DispatchQueue.main.async { [weak self] in self?.isEditing = false }
            return true
        }

        func textViewDidChangeSelection(_ notification: Notification) {
            if let tv = textView { parent.onSelectionChange?(tv.selectedRange()) }
            guard let report = parent.onCaretLine, let tv = textView else { return }
            let loc = min(tv.selectedRange().location, (tv.string as NSString).length)
            var line = 1
            for unit in tv.string.utf16.prefix(loc) where unit == 10 { line += 1 }
            report(line, !isRevealing && !isEditing)
        }

        func textDidChange(_ notification: Notification) {
            guard let tv = textView else { return }
            parent.text = tv.string
            gutter?.refresh()
            highlightWork?.cancel()
            guard parent.syntaxExt != nil else { return }
            let work = DispatchWorkItem { [weak self] in
                guard let self, let tv = self.textView else { return }
                self.applyHighlight(tv)
            }
            highlightWork = work
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.25, execute: work)
        }

        /// Paint a guaranteed-visible monospaced base, then overlay only the
        /// foreground colors from `SyntaxHighlighter`.
        @MainActor func applyHighlight(_ tv: NSTextView) {
            guard let storage = tv.textStorage else { return }
            let font = NSFont.monospacedSystemFont(ofSize: parent.fontSize, weight: .regular)
            let full = NSRange(location: 0, length: (tv.string as NSString).length)
            storage.beginEditing()
            storage.setAttributes([.font: font, .foregroundColor: NSColor.textColor], range: full)
            if let ext = parent.syntaxExt,
               let hl = SyntaxHighlighter.shared.attributed(tv.string, ext: ext, fontSize: parent.fontSize),
               hl.length == full.length {
                hl.enumerateAttribute(.foregroundColor, in: NSRange(location: 0, length: hl.length)) { value, range, _ in
                    if let color = value as? NSColor {
                        storage.addAttribute(.foregroundColor, value: color, range: range)
                    }
                }
            }
            storage.endEditing()
            tv.typingAttributes = [.font: font, .foregroundColor: NSColor.textColor]
        }
    }
}

/// `NSTextView` that reports ⌘-clicks on identifiers, so the editor can offer
/// IDE-style "go to definition" without a language server.
final class NavigableTextView: NSTextView {
    var onCommandClick: ((String, Int) -> Void)?
    /// Hands the selection (or current line) to Claude Code as an @-mention.
    var onMention: (() -> Void)?
    /// Repo-wide declared names, merged with this buffer's own words.
    var completionSymbols: () -> [String] = { [] }
    /// (full text, caret) → language-server completions; nil = words only.
    var semanticCompletion: ((String, Int) async -> [CodeCompletionItem]?)?
    var autocompleteWhileTyping = true
    /// Asks for an AI continuation at the caret; nil disables the shortcut.
    var aiSuggest: ((String, String) async -> String?)?
    /// Set while the last edit was a plain insertion, so completion doesn't pop
    /// up while deleting.
    private var lastEditWasInsertion = false
    /// Language-server results for the popup, valid only at `caret`.
    private var semanticResults: (caret: Int, items: [CodeCompletionItem])?
    private var semanticTask: Task<Void, Never>?
    /// Bumped on every edit, so a slow server reply for old text is dropped.
    private var editGeneration = 0
    /// Our own `super.complete` / completion insertion is in flight.
    private var isPresentingCompletion = false
    private var isInsertingCompletion = false

    /// Dimmed preview of an AI suggestion, drawn over the text rather than
    /// inserted — inserting it would dirty the file before the user accepts.
    private lazy var ghostView: NSTextView = {
        let view = NSTextView(frame: .zero)
        view.isEditable = false
        view.isSelectable = false
        view.drawsBackground = true
        view.backgroundColor = NSColor.textBackgroundColor.withAlphaComponent(0.92)
        view.textContainerInset = .zero
        view.textContainer?.lineFragmentPadding = 0
        view.isHidden = true
        return view
    }()
    private var ghostText: String?
    private var isRequestingSuggestion = false

    fileprivate static let identifierChars: CharacterSet = {
        var set = CharacterSet.alphanumerics
        set.insert(charactersIn: "_$")
        return set
    }()

    override func mouseDown(with event: NSEvent) {
        dismissSuggestion()
        guard event.modifierFlags.contains(.command), let onCommandClick else {
            super.mouseDown(with: event)
            return
        }
        let point = convert(event.locationInWindow, from: nil)
        let index = characterIndexForInsertion(at: point)
        let ns = string as NSString
        guard let range = Self.identifierRange(in: ns, at: index) else {
            super.mouseDown(with: event)
            return
        }
        setSelectedRange(range)
        onCommandClick(ns.substring(with: range), Self.lineNumber(in: ns, at: range.location))
    }

    /// The identifier surrounding `index`, or nil when the click isn't on one.
    static func identifierRange(in ns: NSString, at index: Int) -> NSRange? {
        guard ns.length > 0 else { return nil }
        var start = min(index, ns.length - 1)
        // A click just past the end of a word still targets that word.
        if !isIdentifier(ns.character(at: start)), start > 0, isIdentifier(ns.character(at: start - 1)) {
            start -= 1
        }
        guard isIdentifier(ns.character(at: start)) else { return nil }
        var end = start
        while start > 0, isIdentifier(ns.character(at: start - 1)) { start -= 1 }
        while end + 1 < ns.length, isIdentifier(ns.character(at: end + 1)) { end += 1 }
        let range = NSRange(location: start, length: end - start + 1)
        // Skip pure numbers — nothing to navigate to.
        let text = ns.substring(with: range)
        guard text.rangeOfCharacter(from: CharacterSet.letters.union(CharacterSet(charactersIn: "_"))) != nil else {
            return nil
        }
        return range
    }

    fileprivate static func isIdentifier(_ unichar: unichar) -> Bool {
        guard let scalar = UnicodeScalar(unichar) else { return false }
        return identifierChars.contains(scalar)
    }

    // MARK: - AI suggestion (ghost text)

    /// The AI-continuation shortcut asks for a suggestion (routed from `AppDelegate`'s key monitor, since
    /// the menu would swallow it first); ⇥ accepts the one on screen; ⎋ drops it.
    func requestAISuggestion() { requestSuggestion() }

    /// True while a suggestion is on screen, so the app-level shortcut knows
    /// this view is the one to talk to.
    var hasAISuggestion: Bool { ghostText != nil }

    override func menu(for event: NSEvent) -> NSMenu? {
        let menu = super.menu(for: event) ?? NSMenu()
        guard onMention != nil else { return menu }
        let shortcut = ShortcutSettings.shared.shortcut(for: .sendToClaude)
        let item = NSMenuItem(title: "Send to Claude Code", action: #selector(mentionInClaude),
                              keyEquivalent: shortcut?.key ?? "")
        item.keyEquivalentModifierMask = shortcut?.modifiers ?? []
        item.target = self
        menu.insertItem(item, at: 0)
        menu.insertItem(.separator(), at: 1)
        return menu
    }

    @objc private func mentionInClaude() { onMention?() }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        // ⌥⌘K by default, as in the VS Code / JetBrains Claude Code plugins.
        if onMention != nil, window?.firstResponder === self,
           ShortcutSettings.shared.shortcut(for: .sendToClaude)?.matches(event) == true {
            onMention?()
            return true
        }
        return super.performKeyEquivalent(with: event)
    }

    override func keyDown(with event: NSEvent) {
        if ghostText != nil {
            if event.keyCode == 48 {            // tab
                acceptSuggestion()
                return
            }
            if event.keyCode == 53 {            // esc
                dismissSuggestion()
                return
            }
            dismissSuggestion()
        }
        super.keyDown(with: event)
    }

    private func requestSuggestion() {
        guard let aiSuggest, isEditable, !isRequestingSuggestion else { return }
        let ns = string as NSString
        let caret = selectedRange().location
        guard caret <= ns.length else { return }
        let prefix = ns.substring(to: caret)
        let suffix = ns.substring(from: caret)
        isRequestingSuggestion = true
        showGhost("…")
        Task { @MainActor in
            let suggestion = await aiSuggest(prefix, suffix)
            isRequestingSuggestion = false
            guard let suggestion, !suggestion.isEmpty else {
                dismissSuggestion()
                return
            }
            ghostText = suggestion
            showGhost(suggestion)
        }
    }

    private func acceptSuggestion() {
        guard let text = ghostText else { return }
        dismissSuggestion()
        insertText(text, replacementRange: selectedRange())
    }

    private func dismissSuggestion() {
        ghostText = nil
        ghostView.isHidden = true
    }

    /// Park the preview just after the caret, clipped to the visible width.
    private func showGhost(_ text: String) {
        guard let layoutManager, let textContainer else { return }
        if ghostView.superview == nil { addSubview(ghostView) }
        let font = self.font ?? NSFont.monospacedSystemFont(ofSize: 12, weight: .regular)
        ghostView.string = text
        ghostView.font = font
        ghostView.textColor = .tertiaryLabelColor

        let caret = selectedRange()
        let glyphRange = layoutManager.glyphRange(forCharacterRange: NSRange(location: caret.location, length: 0),
                                                  actualCharacterRange: nil)
        var origin = layoutManager.boundingRect(forGlyphRange: glyphRange, in: textContainer).origin
        origin.x += textContainerInset.width
        origin.y += textContainerInset.height

        let lines = max(1, text.components(separatedBy: "\n").count)
        let lineHeight = layoutManager.defaultLineHeight(for: font)
        let width = max(80, (text.components(separatedBy: "\n").map { $0.count }.max() ?? 1))
        let charWidth = font.maximumAdvancement.width
        ghostView.frame = NSRect(
            x: origin.x,
            y: origin.y,
            width: min(CGFloat(width) * charWidth + 8, max(120, visibleRect.width - origin.x - 8)),
            height: CGFloat(lines) * lineHeight + 4
        )
        ghostView.isHidden = false
    }

    // MARK: - Completion

    /// AppKit owns the popup (arrow keys, Esc, insertion); this just supplies
    /// the candidate list for the partial word under the caret.
    override func completions(
        forPartialWordRange charRange: NSRange,
        indexOfSelectedItem index: UnsafeMutablePointer<Int>?
    ) -> [String]? {
        let ns = string as NSString
        guard charRange.location != NSNotFound, NSMaxRange(charRange) <= ns.length else { return nil }
        if let semantic = semanticResults, semantic.caret == NSMaxRange(charRange) {
            // The server already filtered and ranked for this prefix.
            var seen: Set<String> = []
            index?.pointee = -1
            return semantic.items.map(\.label).filter { seen.insert($0).inserted }.prefix(200).map { $0 }
        }
        let prefix = ns.substring(with: charRange)
        guard prefix.count >= 1 else { return nil }

        var seen: Set<String> = [prefix]
        var ranked: [(word: String, score: Int)] = []
        // Buffer words first (score 0) — what you're editing is the best guess.
        for word in bufferWords() where word.hasPrefix(prefix) && seen.insert(word).inserted {
            ranked.append((word, 0))
        }
        for word in completionSymbols() where word.hasPrefix(prefix) && seen.insert(word).inserted {
            ranked.append((word, 1))
        }
        // Then case-insensitive matches, so `av` still finds `AvatarView`.
        let lowerPrefix = prefix.lowercased()
        for word in completionSymbols()
        where word.lowercased().hasPrefix(lowerPrefix) && seen.insert(word).inserted {
            ranked.append((word, 2))
        }

        let sorted = ranked.sorted {
            $0.score == $1.score
                ? ($0.word.count == $1.word.count ? $0.word < $1.word : $0.word.count < $1.word.count)
                : $0.score < $1.score
        }
        guard !sorted.isEmpty else { return nil }
        // -1 = nothing preselected. With an item selected, AppKit writes it
        // into the buffer as an inline preview, which reads as the editor
        // typing for you.
        index?.pointee = -1
        return Array(sorted.prefix(60).map { $0.word })
    }

    /// Only commit on an explicit pick (⏎/⇥/click). AppKit otherwise inserts
    /// each candidate as you arrow through the list.
    override func insertCompletion(
        _ word: String,
        forPartialWordRange charRange: NSRange,
        movement: Int,
        isFinal flag: Bool
    ) {
        guard flag, movement != NSTextMovement.cancel.rawValue else { return }
        isInsertingCompletion = true
        defer { isInsertingCompletion = false }
        let semantic = semanticResults
        semanticResults = nil
        guard let item = semantic?.items.first(where: { $0.label == word }),
              NSMaxRange(item.replaceRange) <= (string as NSString).length else {
            super.insertCompletion(word, forPartialWordRange: charRange, movement: movement, isFinal: true)
            return
        }
        // The server's edit, not the label: `padding(_ insets:)` inserts `padding()`.
        insertText(item.insertText, replacementRange: item.replaceRange)
        // A call that takes arguments: park the caret between the parens.
        if item.insertText.hasSuffix("()"), !item.label.hasSuffix("()") {
            let caret = selectedRange().location
            if caret > 0 { setSelectedRange(NSRange(location: caret - 1, length: 0)) }
        }
    }

    /// The identifier part left of the caret — empty right after a `.`, so
    /// member completion works before anything is typed.
    override var rangeForUserCompletion: NSRange {
        let caret = selectedRange()
        let ns = string as NSString
        guard caret.length == 0, caret.location <= ns.length else { return super.rangeForUserCompletion }
        var start = caret.location
        while start > 0, Self.isIdentifier(ns.character(at: start - 1)) { start -= 1 }
        if start < caret.location { return NSRange(location: start, length: caret.location - start) }
        if semanticResults?.caret == caret.location { return NSRange(location: caret.location, length: 0) }
        return super.rangeForUserCompletion
    }

    /// ⌥⎋ / F5: ask the language server first when there is one.
    override func complete(_ sender: Any?) {
        guard semanticCompletion != nil, !isPresentingCompletion else { return super.complete(sender) }
        requestSemanticCompletion(wordFallback: true)
    }

    private func presentCompletion() {
        isPresentingCompletion = true
        defer { isPresentingCompletion = false }
        super.complete(nil)
    }

    /// Ask the server for completions at the caret, then show them — unless
    /// the text or caret moved meanwhile. `wordFallback` shows buffer/repo
    /// words when the server has nothing.
    private func requestSemanticCompletion(wordFallback: Bool) {
        guard let semanticCompletion else { return }
        semanticTask?.cancel()
        let generation = editGeneration
        let text = string
        let caret = selectedRange()
        guard caret.length == 0 else { return }
        semanticTask = Task { @MainActor [weak self] in
            // Coalesce fast typing into one request.
            try? await Task.sleep(nanoseconds: 40_000_000)
            guard !Task.isCancelled else { return }
            let items = await semanticCompletion(text, caret.location)
            guard let self, !Task.isCancelled, generation == self.editGeneration,
                  self.selectedRange() == caret, self.window?.firstResponder === self else { return }
            if let items, !items.isEmpty {
                self.semanticResults = (caret.location, items)
            } else {
                self.semanticResults = nil
                guard wordFallback else { return }
            }
            self.presentCompletion()
        }
    }

    /// Identifiers already present in this buffer.
    private func bufferWords() -> [String] {
        let ns = string as NSString
        var words: [String] = []
        var current = ""
        current.reserveCapacity(32)
        ns.enumerateSubstrings(in: NSRange(location: 0, length: ns.length),
                               options: [.byComposedCharacterSequences]) { substring, _, _, _ in
            guard let substring, let scalar = substring.unicodeScalars.first else { return }
            if Self.identifierChars.contains(scalar) {
                current.append(substring)
            } else if !current.isEmpty {
                if current.count > 1, !current.allSatisfy({ $0.isNumber }) { words.append(current) }
                current = ""
            }
        }
        if current.count > 1 { words.append(current) }
        return words
    }

    override func shouldChangeText(in affectedCharRange: NSRange, replacementString: String?) -> Bool {
        lastEditWasInsertion = (replacementString?.isEmpty == false)
        return super.shouldChangeText(in: affectedCharRange, replacementString: replacementString)
    }

    override func didChangeText() {
        super.didChangeText()
        dismissSuggestion()
        editGeneration += 1
        semanticResults = nil
        guard autocompleteWhileTyping, isEditable, lastEditWasInsertion, !isInsertingCompletion else {
            semanticTask?.cancel()
            return
        }
        let ns = string as NSString
        let caret = selectedRange().location
        guard caret > 0, caret <= ns.length else { return }
        if semanticCompletion != nil {
            // Member access (`.`) or inside an identifier — Xcode-style.
            if ns.character(at: caret - 1) == 46 {   // "."
                requestSemanticCompletion(wordFallback: false)
            } else if let range = Self.identifierRange(in: ns, at: caret - 1), NSMaxRange(range) == caret {
                requestSemanticCompletion(wordFallback: range.length >= 2)
            } else {
                semanticTask?.cancel()
            }
            return
        }
        // Only while typing inside a word of 2+ characters.
        guard let range = Self.identifierRange(in: ns, at: caret - 1),
              NSMaxRange(range) == caret, range.length >= 2 else { return }
        // Next runloop: completing inside didChangeText re-enters text editing.
        DispatchQueue.main.async { [weak self] in self?.complete(nil) }
    }

    private static func lineNumber(in ns: NSString, at location: Int) -> Int {
        var line = 1
        ns.enumerateSubstrings(in: NSRange(location: 0, length: location),
                               options: [.byLines, .substringNotRequired]) { _, _, _, _ in line += 1 }
        return line
    }
}

/// A fixed (non-scrolling) strip that draws right-aligned line numbers next to
/// its text view, offset by the scroll view's vertical position so numbers stay
/// glued to their lines. Flipped so its y-axis matches the text view's.
final class LineNumberGutter: NSView {
    private weak var textView: NSTextView?
    private weak var scrollView: NSScrollView?
    private let font: NSFont
    var widthConstraint: NSLayoutConstraint?

    /// Git blame per line (index 0 = line 1); nil hides the annotation column.
    var blame: [BlameLine]? {
        didSet {
            guard blame != oldValue else { return }
            blameRange = blame.flatMap { lines in
                let dates = lines.filter { !$0.isUncommitted }.map(\.date)
                guard let lo = dates.min(), let hi = dates.max() else { return nil }
                return (lo, hi)
            }
            refresh()
        }
    }
    /// Lines no longer match the blame (unsaved edits): keep the column, blank
    /// the cells, so the text doesn't jump sideways while typing.
    var blameStale = false {
        didSet { if blameStale != oldValue { needsDisplay = true } }
    }
    /// Right-click ▸ "Annotate with Git Blame".
    var onToggleBlame: (() -> Void)?
    /// A blame cell was clicked; the rect is in this view's coordinates.
    var onBlameClick: ((BlameLine, NSRect) -> Void)?

    private var blameRange: (Date, Date)?
    /// Rows drawn last pass, for hit-testing clicks and tooltips.
    private var drawnRows: [(line: Int, rect: NSRect)] = []
    private static let blameWidth: CGFloat = 150
    private static let blameDate: DateFormatter = {
        let f = DateFormatter()
        f.dateStyle = .short
        f.timeStyle = .none
        return f
    }()
    private var blameColumnWidth: CGFloat { blame == nil ? 0 : Self.blameWidth }

    init(textView: NSTextView, scrollView: NSScrollView, fontSize: CGFloat) {
        self.textView = textView
        self.scrollView = scrollView
        self.font = NSFont.monospacedSystemFont(ofSize: max(9, fontSize - 1), weight: .regular)
        super.init(frame: .zero)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override var isFlipped: Bool { true }

    /// Re-evaluate width for the current line count, then redraw.
    func refresh() {
        guard let tv = textView else { return }
        let lineCount = max(1, (tv.string as NSString).components(separatedBy: "\n").count)
        let digits = "\(lineCount)".count
        let sample = String(repeating: "9", count: digits) as NSString
        let width = ceil(sample.size(withAttributes: [.font: font]).width) + 14 + blameColumnWidth
        if let c = widthConstraint, abs(c.constant - width) > 0.5 { c.constant = width }
        needsDisplay = true
    }

    // MARK: Blame interaction

    override func menu(for event: NSEvent) -> NSMenu? {
        guard onToggleBlame != nil else { return nil }
        let menu = NSMenu()
        let item = NSMenuItem(title: "Annotate with Git Blame", action: #selector(toggleBlame), keyEquivalent: "")
        item.target = self
        item.state = blame == nil ? .off : .on
        menu.addItem(item)
        return menu
    }

    @objc private func toggleBlame() { onToggleBlame?() }

    private func blameRow(at point: NSPoint) -> (BlameLine, NSRect)? {
        guard let blame, !blameStale, point.x < blameColumnWidth,
              let row = drawnRows.first(where: { $0.rect.minY <= point.y && point.y < $0.rect.maxY }),
              row.line - 1 < blame.count else { return nil }
        return (blame[row.line - 1], row.rect)
    }

    override func mouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        if let (line, rect) = blameRow(at: point), !line.isUncommitted {
            onBlameClick?(line, rect)
        } else {
            super.mouseDown(with: event)
        }
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: bounds, options: [.mouseMoved, .activeInKeyWindow, .inVisibleRect],
                                       owner: self))
    }

    override func mouseMoved(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        guard let (line, _) = blameRow(at: point) else { toolTip = nil; return }
        toolTip = line.isUncommitted
            ? "Not committed yet"
            : "\(line.shortHash) · \(line.author) <\(line.email)>\n"
              + "\(line.date.formatted(date: .abbreviated, time: .shortened))\n\n\(line.summary)"
    }

    private func drawBlame(_ line: BlameLine, row: NSRect) {
        let cell = NSRect(x: 0, y: row.minY, width: blameColumnWidth - 4, height: row.height)
        if !line.isUncommitted {
            // Newer commits are tinted stronger, like IntelliJ's annotations.
            var t: CGFloat = 1
            if let (lo, hi) = blameRange, hi > lo {
                t = CGFloat(line.date.timeIntervalSince(lo) / hi.timeIntervalSince(lo))
            }
            NSColor.systemBlue.withAlphaComponent(0.08 + 0.32 * t).setFill()
            cell.fill()
        }
        let text = line.isUncommitted
            ? "Not committed"
            : "\(Self.blameDate.string(from: line.date))  \(line.author)"
        let style = NSMutableParagraphStyle()
        style.lineBreakMode = .byTruncatingTail
        let attrs: [NSAttributedString.Key: Any] = [
            .font: font,
            .foregroundColor: line.isUncommitted ? NSColor.tertiaryLabelColor : NSColor.secondaryLabelColor,
            .paragraphStyle: style,
        ]
        (text as NSString).draw(in: cell.insetBy(dx: 6, dy: 0), withAttributes: attrs)
    }

    var desiredWidth: CGFloat {
        let sample = "999" as NSString
        return ceil(sample.size(withAttributes: [.font: font]).width) + 14
    }

    override func draw(_ dirtyRect: NSRect) {
        NSColor.textBackgroundColor.setFill()
        bounds.fill()
        // Right divider.
        NSColor.separatorColor.setStroke()
        let border = NSBezierPath()
        border.move(to: NSPoint(x: bounds.maxX - 0.5, y: bounds.minY))
        border.line(to: NSPoint(x: bounds.maxX - 0.5, y: bounds.maxY))
        border.stroke()

        guard let tv = textView,
              let lm = tv.layoutManager,
              let tc = tv.textContainer,
              let clip = scrollView?.contentView else { return }

        let content = tv.string as NSString
        let inset = tv.textContainerInset.height
        let scrollY = clip.bounds.origin.y
        let visibleRect = clip.bounds
        let glyphRange = lm.glyphRange(forBoundingRect: visibleRect, in: tc)
        let charRange = lm.characterRange(forGlyphRange: glyphRange, actualGlyphRange: nil)

        // Line number of the first visible character (count newlines before it).
        var lineNumber = 1
        if charRange.location > 0 {
            content.enumerateSubstrings(
                in: NSRange(location: 0, length: charRange.location),
                options: [.byLines, .substringNotRequired]) { _, _, _, _ in lineNumber += 1 }
        }

        let attrs: [NSAttributedString.Key: Any] = [
            .font: font, .foregroundColor: NSColor.secondaryLabelColor]
        let pad: CGFloat = 6
        drawnRows.removeAll(keepingCapacity: true)

        var index = content.lineRange(for: NSRange(location: charRange.location, length: 0)).location
        while index <= NSMaxRange(charRange) {
            let glyphIdx = lm.glyphIndexForCharacter(at: index)
            let fragRect = lm.lineFragmentRect(forGlyphAt: min(glyphIdx, max(0, lm.numberOfGlyphs - 1)),
                                               effectiveRange: nil)
            let y = fragRect.minY + inset - scrollY
            let row = NSRect(x: 0, y: y, width: bounds.width, height: fragRect.height)
            drawnRows.append((lineNumber, row))
            if let blame, !blameStale, lineNumber - 1 < blame.count { drawBlame(blame[lineNumber - 1], row: row) }
            let label = "\(lineNumber)" as NSString
            let size = label.size(withAttributes: attrs)
            label.draw(at: NSPoint(x: bounds.width - size.width - pad, y: y), withAttributes: attrs)

            let lineRange = content.lineRange(for: NSRange(location: index, length: 0))
            let next = NSMaxRange(lineRange)
            if next <= index || next >= content.length { break }
            index = next
            lineNumber += 1
        }
    }
}
