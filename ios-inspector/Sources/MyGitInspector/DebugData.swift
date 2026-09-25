import SwiftUI

/// Reads `_ViewDebug.Data` and the values in it through `Mirror` — what
/// `_ViewDebug.serializedData` does, minus its depth limit. Every accessor
/// returns nil/empty when the shape isn't what's expected, so a future
/// SwiftUI degrades the inspector instead of crashing the app.
enum DebugData {
    /// `data: [Property: Any]` and `childData: [Data]`.
    static func parts(of data: _ViewDebug.Data) -> ([_ViewDebug.Property: Any], [_ViewDebug.Data])? {
        let mirror = Mirror(reflecting: data)
        guard let props = mirror.children.first(where: { $0.label == "data" })?.value as? [_ViewDebug.Property: Any],
              let children = mirror.children.first(where: { $0.label == "childData" })?.value as? [_ViewDebug.Data] else {
            return nil
        }
        return (props, children)
    }

    // MARK: - Type names

    private static let modulePrefix = try! NSRegularExpression(
        pattern: "(^|[<(,\\[:>]\\s*)[A-Za-z_][A-Za-z0-9_]*\\.")
    private static let unknownContext = try! NSRegularExpression(pattern: "\\(unknown context at \\$[0-9a-fA-F]+\\)\\.")

    /// `SwiftUI._VariadicView.Tree<SwiftUI._HStackLayout, Example.Row>` →
    /// `_VariadicView.Tree<_HStackLayout, Row>` — what the serialized debug
    /// data called `readableType`. In `String(reflecting:)` every type
    /// reference starts with its module, right after the start, `<`, `,`,
    /// `(`, `[`, `:` or `>`, so that first segment is exactly the one to drop;
    /// nested names (`_VariadicView.Tree`) stay whole.
    static func readableName(_ type: Any.Type) -> String {
        let full = String(reflecting: type)
        var s = unknownContext.stringByReplacingMatches(in: full, range: NSRange(full.startIndex..., in: full),
                                                        withTemplate: "")
        s = modulePrefix.stringByReplacingMatches(in: s, range: NSRange(s.startIndex..., in: s), withTemplate: "$1")
        return s
    }

    // MARK: - Transform

    /// A node's transform, read the way the serialized form reports it.
    ///
    /// Scroll offsets live in a `ViewTransform` buffer `Mirror` can't open,
    /// but SwiftUI's serializer can — it just fails on deep trees. So the
    /// node is serialized alone: a copy with its children removed. That
    /// needs a write into the copy's memory, done only after checking the
    /// layout is exactly `data` then `childData` (16 bytes, and the pointers
    /// at offsets 0 and 8 are those two collections' storage); otherwise nil.
    static func serializedTransform(of data: _ViewDebug.Data) -> CGPoint? {
        guard MemoryLayout<_ViewDebug.Data>.size == 16, let (props, children) = parts(of: data) else { return nil }
        let propsBits = unsafeBitCast(props, to: UInt.self)
        let childBits = unsafeBitCast(children, to: UInt.self)
        var copy = data
        let isolated: Bool = withUnsafeMutablePointer(to: &copy) { pointer in
            let raw = UnsafeMutableRawPointer(pointer)
            guard raw.load(as: UInt.self) == propsBits,
                  raw.load(fromByteOffset: 8, as: UInt.self) == childBits else { return false }
            raw.advanced(by: 8).assumingMemoryBound(to: [_ViewDebug.Data].self).pointee = []
            return true
        }
        guard isolated, let json = _ViewDebug.serializedData([copy]),
              let roots = try? JSONSerialization.jsonObject(with: json) as? [[String: Any]],
              let properties = roots.first?["properties"] as? [[String: Any]],
              let transform = properties.first(where: { $0["id"] as? Int == 2 })?["attribute"] as? [String: Any],
              let items = (transform["value"] as? [String: Any])?["items"] as? [[String: Any]] else { return nil }
        var total = CGPoint.zero
        for item in items {
            if let t = item["translation"] as? [Any], t.count == 2,
               let x = (t[0] as? NSNumber)?.doubleValue, let y = (t[1] as? NSNumber)?.doubleValue {
                total.x += CGFloat(x)
                total.y += CGFloat(y)
            }
        }
        return total
    }

    /// A `ViewTransform`'s total translation as `Mirror` sees it (misses
    /// buffered elements — the fallback when serializing a node fails).
    static func translation(_ transform: Any) -> CGPoint? {
        guard let head = child("head", of: transform) else { return nil }
        var total = CGPoint.zero
        if let pending = child("pendingTranslation", of: transform) as? CGSize {
            total.x += pending.width
            total.y += pending.height
        }
        var element = unwrap(head)
        var guardCount = 0
        while let e = element, guardCount < 256 {
            guardCount += 1
            if let t = child("translation", of: e) as? CGSize {
                total.x += t.width
                total.y += t.height
            }
            element = child("next", of: e).flatMap(unwrap)
        }
        return total
    }

    // MARK: - Values

    /// A value as `path: text` pairs (`insets.top: 12.0`, `_tree.root.spacing: 8.0`,
    /// `maxWidth: inf`, `alignment.horizontal: leading`), like the serialized form.
    static func flatten(_ value: Any, limit: Int = 40) -> [String: String] {
        var out: [String: String] = [:]
        var stack: [(value: Any, path: [String], depth: Int)] = [(value, [], 0)]
        while let (current, path, depth) = stack.popLast(), out.count < limit {
            if path.last == "content" { continue }            // a ForEach/Tree's children
            // A Text's resolved string (`StyledTextContentView.text.storage`):
            // its color is the only way to tell which token painted it.
            if let attributed = current as? NSAttributedString {
                if !path.contains("cache"), let color = foregroundColor(of: attributed) {
                    out[(path + ["foregroundColor"]).joined(separator: ".")] = color
                }
                continue
            }
            if let leaf = leafText(current, name: path.last) {
                out[path.isEmpty ? "value" : path.joined(separator: ".")] = String(leaf.prefix(160))
                continue
            }
            guard depth < 7 else { continue }
            let mirror = Mirror(reflecting: current)
            if mirror.displayStyle == .optional {
                if let some = mirror.children.first?.value { stack.append((some, path, depth + 1)) }
                continue
            }
            if mirror.displayStyle == .collection || mirror.displayStyle == .set || mirror.displayStyle == .dictionary {
                continue                                          // contents are rarely layout
            }
            for c in allChildren(mirror).reversed() {
                stack.append((c.value, path + [c.label ?? "_"], depth + 1))
            }
        }
        return out
    }

    /// The first `String` inside a value (a `Text`'s literal or key).
    static func firstString(in value: Any) -> String? {
        var stack: [(Any, Int)] = [(value, 0)]
        while let (current, depth) = stack.popLast() {
            if let s = current as? String { return s }
            guard depth < 8 else { continue }
            let mirror = Mirror(reflecting: current)
            for c in allChildren(mirror).reversed() { stack.append((c.value, depth + 1)) }
        }
        return nil
    }

    /// Scalars and the few SwiftUI values worth naming.
    private static func leafText(_ value: Any, name: String?) -> String? {
        switch value {
        case let v as CGFloat: return "\(v)"
        case let v as Double: return "\(v)"
        case let v as Float: return "\(v)"
        case let v as Int: return "\(v)"
        case let v as Bool: return v ? "true" : "false"
        case let v as String: return v
        case let v as HorizontalAlignment: return named(v, in: [(.leading, "leading"), (.center, "center"), (.trailing, "trailing")])
        case let v as VerticalAlignment:
            return named(v, in: [(.top, "top"), (.center, "center"), (.bottom, "bottom"),
                                   (.firstTextBaseline, "firstTextBaseline"), (.lastTextBaseline, "lastTextBaseline")])
        case let v as Edge.Set:
            let names: [(Edge.Set, String)] = [(.top, "top"), (.leading, "leading"), (.bottom, "bottom"), (.trailing, "trailing")]
            return "[" + names.filter { v.contains($0.0) }.map(\.1).joined(separator: ", ") + "]"
        case let v as UIColor: return HierarchyCapture.hex(v, .current)
        case let v as Color: return HierarchyCapture.hex(UIColor(v), .current)
        case let v as CGPoint: return "[\(v.x), \(v.y)]"
        case let v as CGSize: return "[\(v.width), \(v.height)]"
        default:
            // Payload-free enums print as their case.
            let mirror = Mirror(reflecting: value)
            if mirror.displayStyle == .enum, mirror.children.isEmpty { return "\(value)" }
            return nil
        }
    }

    /// The color of the first character, as `#RRGGBBAA`. SwiftUI stores it
    /// under UIKit's key (`NSColor`) or, elsewhere, its own, as a UIColor or a CGColor.
    private static func foregroundColor(of text: NSAttributedString) -> String? {
        guard text.length > 0 else { return nil }
        for (key, value) in text.attributes(at: 0, effectiveRange: nil)
        where key == .foregroundColor || key.rawValue.range(of: "foregroundcolor", options: .caseInsensitive) != nil {
            if let color = value as? UIColor { return HierarchyCapture.hex(color, .current) }
            if CFGetTypeID(value as CFTypeRef) == CGColor.typeID {
                return HierarchyCapture.hex(UIColor(cgColor: value as! CGColor), .current)
            }
        }
        return nil
    }

    private static func named<T: Equatable>(_ value: T, in known: [(T, String)]) -> String {
        known.first { $0.0 == value }?.1 ?? "\(value)"
    }

    // MARK: - Mirror helpers

    /// Children including superclasses' (a transform element's `next` lives there).
    private static func allChildren(_ mirror: Mirror) -> [Mirror.Child] {
        var out = Array(mirror.children)
        var parent = mirror.superclassMirror
        while let p = parent {
            out += p.children
            parent = p.superclassMirror
        }
        return out
    }

    private static func child(_ label: String, of value: Any) -> Any? {
        allChildren(Mirror(reflecting: value)).first { $0.label == label }?.value
    }

    /// `Optional.some(x)` → x; nil → nil; anything else as is.
    private static func unwrap(_ value: Any) -> Any? {
        let mirror = Mirror(reflecting: value)
        guard mirror.displayStyle == .optional else { return value }
        return mirror.children.first?.value
    }
}
