import SwiftUI
import AppKit

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

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeNSView(context: Context) -> NSView {
        let tv = NSTextView()
        tv.delegate = context.coordinator
        tv.isRichText = false
        tv.isAutomaticQuoteSubstitutionEnabled = false
        tv.isAutomaticDashSubstitutionEnabled = false
        tv.isAutomaticSpellingCorrectionEnabled = false
        tv.isAutomaticTextReplacementEnabled = false
        tv.allowsUndo = true
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
        guard let tv = context.coordinator.textView else { return }
        let textChanged = tv.string != text
        if textChanged { tv.string = text }
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
    }

    final class Coordinator: NSObject, NSTextViewDelegate {
        var parent: CodeEditor
        weak var textView: NSTextView?
        weak var scrollView: NSScrollView?
        weak var gutter: LineNumberGutter?
        var lastExt: String?
        private var highlightWork: DispatchWorkItem?

        init(_ p: CodeEditor) { parent = p }

        @objc func viewChanged() { gutter?.needsDisplay = true }

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

/// A fixed (non-scrolling) strip that draws right-aligned line numbers next to
/// its text view, offset by the scroll view's vertical position so numbers stay
/// glued to their lines. Flipped so its y-axis matches the text view's.
final class LineNumberGutter: NSView {
    private weak var textView: NSTextView?
    private weak var scrollView: NSScrollView?
    private let font: NSFont
    var widthConstraint: NSLayoutConstraint?

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
        let width = ceil(sample.size(withAttributes: [.font: font]).width) + 14
        if let c = widthConstraint, abs(c.constant - width) > 0.5 { c.constant = width }
        needsDisplay = true
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

        var index = content.lineRange(for: NSRange(location: charRange.location, length: 0)).location
        while index <= NSMaxRange(charRange) {
            let glyphIdx = lm.glyphIndexForCharacter(at: index)
            let fragRect = lm.lineFragmentRect(forGlyphAt: min(glyphIdx, max(0, lm.numberOfGlyphs - 1)),
                                               effectiveRange: nil)
            let y = fragRect.minY + inset - scrollY
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
