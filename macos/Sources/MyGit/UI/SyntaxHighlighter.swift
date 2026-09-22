import SwiftUI
import AppKit
import Highlightr

// Wraps Highlightr (highlight.js over JavaScriptCore) for the diff viewer.
//
// Highlightr returns one NSAttributedString for a whole code blob — multi-line
// constructs (block comments, strings) only color correctly with full-file
// context, so we highlight the entire left/right text once and slice it into
// per-line pieces that the side-by-side rows index into.
//
// Two outputs:
//  - lines(): per-line AttributedString with the *font attribute stripped*, so the
//    SwiftUI Text's own .font(.monospaced) wins and only foreground colors apply.
//  - attributed(): the full NSAttributedString (font kept) for the editable NSTextView.
//
// All calls are main-thread only (one shared JSContext per theme). Results are
// memoized by (theme, language, text) so a blob is highlighted at most once.
@MainActor
final class SyntaxHighlighter {
    static let shared = SyntaxHighlighter()

    private var engines: [String: Highlightr] = [:]      // themeName -> engine
    private var lineCache: [String: [AttributedString]] = [:]
    private var cacheOrder: [String] = []
    private var cachedLines = 0
    private let cacheCap = 24
    /// Highlighting materialises one `AttributedString` per line, which costs
    /// roughly 10 KB of attribute runs. Past these limits the panes fall back to
    /// plain text instead of eating gigabytes (a 60k-line file measured 1.2 GB).
    private static let maxHighlightLines = 6_000     // matches LineDiffer's diff cap
    private static let maxHighlightBytes = 512 * 1024
    /// Total lines kept across cached files, so a couple of big diffs can't pin
    /// hundreds of MB in the cache.
    private static let maxCachedLines = 20_000

    private init() {}

    // Dark/light theme follows the app appearance. atom-one reads well at our font sizes.
    private var themeName: String {
        let dark = NSApp.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        return dark ? "atom-one-dark" : "atom-one-light"
    }

    private func engine(fontSize: CGFloat) -> Highlightr? {
        let name = themeName
        let h = engines[name] ?? {
            let e = Highlightr()
            e?.setTheme(to: name)
            if let e { engines[name] = e }
            return e
        }()
        h?.theme.setCodeFont(NSFont.monospacedSystemFont(ofSize: fontSize, weight: .regular))
        return h
    }

    // Per-line, font-stripped colors for the read-only Text panes. "" lines yield "".
    func lines(_ text: String, ext: String, fontSize: CGFloat) -> [AttributedString] {
        guard !text.isEmpty, let lang = Self.language(forExtension: ext) else { return [] }
        guard text.utf8.count <= Self.maxHighlightBytes,
              text.count(where: { $0 == "\n" }) < Self.maxHighlightLines else { return [] }
        let key = "\(themeName)|\(lang)|\(text.hashValue)"
        if let hit = lineCache[key] { return hit }

        guard let full = engine(fontSize: fontSize)?.highlight(text, as: lang, fastRender: true) else {
            return []
        }
        let split = Self.splitAttributed(full).map { ns -> AttributedString in
            var a = AttributedString(ns)
            a.font = nil  // drop font so Text's monospaced face wins; keep per-run colors
            return a
        }
        if lineCache.count >= cacheCap { evictAll() }
        lineCache[key] = split
        cacheOrder.append(key)
        cachedLines += split.count
        while cachedLines > Self.maxCachedLines, let oldest = cacheOrder.first, cacheOrder.count > 1 {
            cachedLines -= lineCache.removeValue(forKey: oldest)?.count ?? 0
            cacheOrder.removeFirst()
        }
        return split
    }

    private func evictAll() {
        lineCache.removeAll()
        cacheOrder.removeAll()
        cachedLines = 0
    }

    // Full attributed blob (font kept) for the editable NSTextView pane.
    func attributed(_ text: String, ext: String, fontSize: CGFloat) -> NSAttributedString? {
        guard !text.isEmpty, let lang = Self.language(forExtension: ext) else { return nil }
        return engine(fontSize: fontSize)?.highlight(text, as: lang, fastRender: true)
    }

    // Slice one attributed blob into per-line attributed substrings (newline dropped).
    // Highlight.js preserves source text verbatim, so this matches splitLines() 1:1.
    private static func splitAttributed(_ full: NSAttributedString) -> [NSAttributedString] {
        let ns = full.string as NSString
        var out: [NSAttributedString] = []
        var start = 0
        var i = 0
        let len = ns.length
        while i <= len {
            if i == len || ns.character(at: i) == 10 { // '\n'
                out.append(full.attributedSubstring(from: NSRange(location: start, length: i - start)))
                start = i + 1
            }
            i += 1
        }
        return out
    }

    // Map a file extension to a highlight.js language id. nil => skip highlighting.
    static func language(forExtension ext: String) -> String? {
        switch ext.lowercased() {
        case "swift": return "swift"
        case "kt", "kts": return "kotlin"
        case "js", "jsx", "mjs", "cjs": return "javascript"
        case "ts", "tsx": return "typescript"
        case "py", "pyw": return "python"
        case "rb": return "ruby"
        case "go": return "go"
        case "rs": return "rust"
        case "java": return "java"
        case "c", "h": return "c"
        case "cpp", "cc", "cxx", "hpp", "hh", "hxx": return "cpp"
        case "m": return "objectivec"
        case "mm": return "objectivec"
        case "cs": return "csharp"
        case "php": return "php"
        case "sh", "bash", "zsh": return "bash"
        case "json": return "json"
        case "yml", "yaml": return "yaml"
        case "xml", "plist", "storyboard", "xib": return "xml"
        case "html", "htm": return "xml"
        case "css": return "css"
        case "scss", "sass": return "scss"
        case "less": return "less"
        case "md", "markdown": return "markdown"
        case "sql": return "sql"
        case "toml": return "toml"
        case "ini", "cfg", "conf": return "ini"
        case "gradle", "groovy": return "groovy"
        case "scala": return "scala"
        case "dart": return "dart"
        case "lua": return "lua"
        case "r": return "r"
        case "pl", "pm": return "perl"
        case "dockerfile": return "dockerfile"
        case "makefile", "mk": return "makefile"
        case "vue": return "xml"
        case "diff", "patch": return "diff"
        default: return nil
        }
    }
}
