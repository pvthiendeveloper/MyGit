import Foundation

/// Converts an Android VectorDrawable XML (`<vector><path android:pathData=…/>`)
/// into an SVG string that WebKit can render. Best-effort: handles paths with
/// fill/stroke colors and alpha; unresolved resource colors (`@color/…`) fall
/// back to black. Group transforms and clip-paths are not applied.
enum AndroidVectorDrawable {
    static func toSVG(_ xml: String) -> String? {
        guard xml.contains("<vector") else { return nil }
        let vpW = attr("android:viewportWidth", in: xml) ?? "24"
        let vpH = attr("android:viewportHeight", in: xml) ?? "24"

        var body = ""
        for tag in elements("path", in: xml) {
            let d = attr("android:pathData", in: tag) ?? ""
            if d.isEmpty { continue }
            let fill = color(attr("android:fillColor", in: tag)) ?? "#000000"
            var p = "<path d=\"\(escape(d))\" fill=\"\(fill)\""
            if let a = attr("android:fillAlpha", in: tag) { p += " fill-opacity=\"\(a)\"" }
            if let stroke = color(attr("android:strokeColor", in: tag)) {
                p += " stroke=\"\(stroke)\""
                if let w = attr("android:strokeWidth", in: tag) { p += " stroke-width=\"\(w)\"" }
                if let a = attr("android:strokeAlpha", in: tag) { p += " stroke-opacity=\"\(a)\"" }
            }
            p += "/>"
            body += p
        }
        guard !body.isEmpty else { return nil }
        return "<svg xmlns=\"http://www.w3.org/2000/svg\" viewBox=\"0 0 \(vpW) \(vpH)\" "
            + "width=\"100%\" height=\"100%\" preserveAspectRatio=\"xMidYMid meet\">\(body)</svg>"
    }

    // MARK: - Parsing helpers

    /// Value of `key="…"` within `text` (dot matches newlines, for long pathData).
    private static func attr(_ key: String, in text: String) -> String? {
        let pattern = "\(NSRegularExpression.escapedPattern(for: key))\\s*=\\s*\"([^\"]*)\""
        guard let re = try? NSRegularExpression(pattern: pattern, options: [.dotMatchesLineSeparators]),
              let m = re.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
              let r = Range(m.range(at: 1), in: text) else { return nil }
        return String(text[r]).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// All `<tag …>` opening elements (self-closing or not) in `text`.
    private static func elements(_ tag: String, in text: String) -> [String] {
        let pattern = "<\(tag)\\b[^>]*>"
        guard let re = try? NSRegularExpression(pattern: pattern, options: [.dotMatchesLineSeparators]) else { return [] }
        return re.matches(in: text, range: NSRange(text.startIndex..., in: text)).compactMap {
            Range($0.range, in: text).map { String(text[$0]) }
        }
    }

    /// Android color → SVG. `#AARRGGBB` → `#RRGGBBAA`; `#RRGGBB`/`#RGB` kept;
    /// resource refs (`@color/…`, `?attr/…`) → nil (caller defaults to black).
    private static func color(_ s: String?) -> String? {
        guard let s, s.hasPrefix("#") else { return nil }
        let hex = String(s.dropFirst())
        if hex.count == 8 {
            let a = hex.prefix(2)
            let rgb = hex.dropFirst(2)
            return "#\(rgb)\(a)"
        }
        return s
    }

    private static func escape(_ s: String) -> String {
        s.replacingOccurrences(of: "&", with: "&amp;")
         .replacingOccurrences(of: "\"", with: "&quot;")
         .replacingOccurrences(of: "<", with: "&lt;")
         .replacingOccurrences(of: ">", with: "&gt;")
    }
}
