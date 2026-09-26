import SwiftUI
import UIKit

/// Lets the capture ask any `_UIHostingView<Content>` for SwiftUI's own view
/// debug data (the same data Xcode's view debugger shows) without knowing
/// `Content`.
protocol SwiftUIDebugDataProviding {
    func _viewDebugData() -> [_ViewDebug.Data]
}

extension _UIHostingView: SwiftUIDebugDataProviding {}

/// Snapshots the app's UI into plain JSON-able dictionaries.
enum HierarchyCapture {
    private static weak var highlightView: UIView?

    static func appInfo() -> [String: Any] {
        let bundle = Bundle.main
        var info: [String: Any] = [
            "protocol": MyGitInspector.protocolVersion,
            "bundleId": bundle.bundleIdentifier ?? "",
            "appName": bundle.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String
                ?? bundle.object(forInfoDictionaryKey: "CFBundleName") as? String ?? "",
            "system": "\(UIDevice.current.systemName) \(UIDevice.current.systemVersion)",
            "model": UIDevice.current.model,
        ]
        #if targetEnvironment(simulator)
        info["simulator"] = true
        info["device"] = ProcessInfo.processInfo.environment["SIMULATOR_DEVICE_NAME"] ?? UIDevice.current.name
        #else
        info["simulator"] = false
        info["device"] = UIDevice.current.name
        #endif
        return info
    }

    /// Every visible window: its nodes (window coordinates, points) and a PNG
    /// of what it shows.
    ///
    /// Nodes go out as a flat pre-order list, each naming its `parent`, not as
    /// nested JSON: real apps nest a few hundred levels deep (SwiftUI adds
    /// one level per modifier), and nested JSON that deep overflows the
    /// stack of whoever parses it.
    static func capture(screenshotScale: CGFloat?) -> [String: Any] {
        // Keep MyGit's outline across refreshes, but out of the tree and the
        // screenshot.
        let overlay = highlightView
        overlay?.isHidden = true
        defer { overlay?.isHidden = false }
        var windows: [[String: Any]] = []
        for window in allWindows() {
            let scale = screenshotScale ?? window.screen.scale
            var entry: [String: Any] = [
                "root": id(of: window),
                "nodes": nodes(of: window),
                "size": [window.bounds.width, window.bounds.height],
                "scale": scale,
                "level": window.windowLevel.rawValue,
                "key": window.isKeyWindow,
            ]
            if let png = screenshot(of: window, scale: scale) {
                entry["png"] = png.base64EncodedString()
            }
            windows.append(entry)
        }
        return ["windows": windows, "info": appInfo(), "branches": branches()]
    }

    /// What the tagger's branch probes (`__mB`) recorded: `"path:line"` of a
    /// `return` → the latest values it produced, newest last.
    private static func branches() -> [String: [String]] {
        guard let all = Thread.main.threadDictionary["MyGitInspector.branches"] as? NSDictionary else { return [:] }
        var out: [String: [String]] = [:]
        for (key, values) in all {
            guard let key = key as? String, let values = values as? [Any] else { continue }
            out[key] = values.compactMap { $0 as? String }
        }
        return out
    }

    // MARK: - Tree

    private static func allWindows() -> [UIWindow] {
        UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .flatMap { $0.windows }
            .filter { !$0.isHidden && $0.bounds.width > 0 && $0.bounds.height > 0 }
            .sorted { $0.windowLevel < $1.windowLevel }
    }

    private static func id(of object: AnyObject) -> String {
        "0x" + String(UInt(bitPattern: ObjectIdentifier(object).hashValue), radix: 16)
    }

    /// The window's whole tree, pre-order, without recursion.
    private static func nodes(of window: UIWindow) -> [[String: Any]] {
        var out: [[String: Any]] = []
        var stack: [(view: UIView, parent: String?)] = [(window, nil)]
        while let (view, parent) = stack.popLast() {
            let nodeID = id(of: view)
            out.append(node(for: view, id: nodeID, parent: parent, in: window))
            // A hosting view's SwiftUI tree comes before its UIKit subviews.
            if let host = view as? SwiftUIDebugDataProviding {
                appendSwiftUINodes(of: host, in: view, window: window, parentID: nodeID, to: &out)
            }
            for sub in view.subviews.reversed() where sub !== highlightView {
                stack.append((sub, nodeID))
            }
        }
        return out
    }

    private static func node(for view: UIView, id nodeID: String, parent: String?, in window: UIWindow) -> [String: Any] {
        let frame = view.convert(view.bounds, to: window)
        var node: [String: Any] = [
            "id": nodeID,
            "kind": "uikit",
            "class": String(describing: type(of: view)),
            // Module-qualified (`Example.HomeCell`), so MyGit can tell app
            // code from UIKit and open it.
            "type": String(reflecting: type(of: view)),
            "frame": [frame.minX, frame.minY, frame.width, frame.height],
            "hidden": view.isHidden,
            "alpha": view.alpha,
            "interactive": view.isUserInteractionEnabled,
            "clips": view.clipsToBounds,
        ]
        if let parent { node["parent"] = parent }
        if let vc = owningViewController(of: view) {
            node["viewController"] = String(describing: type(of: vc))
            node["viewControllerType"] = String(reflecting: type(of: vc))
        }
        if let color = view.backgroundColor { node["backgroundColor"] = hex(color, view.traitCollection) }
        if let a11y = view.accessibilityIdentifier, !a11y.isEmpty { node["accessibilityIdentifier"] = a11y }
        if let label = view.accessibilityLabel, !label.isEmpty { node["accessibilityLabel"] = label }
        if let text = text(of: view) { node["text"] = text }
        return node
    }

    // MARK: - SwiftUI

    /// SwiftUI's view debug data for one hosting view, appended pre-order.
    ///
    /// Read by walking `_ViewDebug.Data` with `Mirror`, iteratively:
    /// `_ViewDebug.serializedData` gives up on deep trees (a few hundred
    /// levels — ordinary for a real app, where every modifier adds one) and
    /// returns a stub. The serialized path stays as a fallback in case the
    /// structure ever changes.
    private static func appendSwiftUINodes(of host: SwiftUIDebugDataProviding, in hostView: UIView,
                                           window: UIWindow, parentID: String, to out: inout [[String: Any]]) {
        let data = host._viewDebugData()
        if let first = data.first, DebugData.parts(of: first) != nil {
            appendMirrored(data, hostView: hostView, window: window, parentID: parentID, to: &out)
            return
        }
        guard let json = _ViewDebug.serializedData(data) else {
            out.append(diagnostic("SwiftUI couldn't serialize this hosting view's debug data (\(data.count) roots)",
                                  parentID: parentID, frame: hostView.convert(hostView.bounds, to: window)))
            return
        }
        let parsed: Any
        do {
            parsed = try JSONSerialization.jsonObject(with: json, options: [.fragmentsAllowed])
        } catch {
            out.append(diagnostic("Unreadable SwiftUI debug data (\(json.count) bytes): \(error.localizedDescription)",
                                  parentID: parentID, frame: hostView.convert(hostView.bounds, to: window)))
            return
        }
        guard let roots = parsed as? [[String: Any]] else { return }
        let hostFrame = hostView.convert(hostView.bounds, to: window)
        var counter = 0
        var stack: [(raw: [String: Any], parent: String, inherited: CGRect, offset: CGPoint)] =
            roots.reversed().map { ($0, parentID, hostFrame, .zero) }
        while let (raw, parent, inherited, inheritedOffset) = stack.popLast() {
            counter += 1
            let (node, frame, offset) = swiftUINode(raw, id: "\(parentID).s\(counter)", parent: parent,
                                                    hostView: hostView, window: window,
                                                    inherited: inherited, offset: inheritedOffset)
            out.append(node)
            let nodeID = node["id"] as! String
            for child in (raw["children"] as? [[String: Any]] ?? []).reversed() {
                stack.append((child, nodeID, frame, offset))
            }
        }
    }

    private static func appendMirrored(_ roots: [_ViewDebug.Data], hostView: UIView, window: UIWindow,
                                       parentID: String, to out: inout [[String: Any]]) {
        let hostFrame = hostView.convert(hostView.bounds, to: window)
        var counter = 0
        var stack: [(data: _ViewDebug.Data, parent: String, inherited: CGRect, offset: CGPoint)] =
            roots.reversed().map { ($0, parentID, hostFrame, .zero) }
        while let (data, parent, inherited, inheritedOffset) = stack.popLast() {
            guard let (props, children) = DebugData.parts(of: data) else { continue }
            counter += 1
            let nodeID = "\(parentID).s\(counter)"
            let type = props[.type] as? Any.Type
            let readable = type.map(DebugData.readableName) ?? "?"
            // Positions are in the coordinate space of the nearest transform
            // (a ScrollView's content); the transform maps it to the host.
            let offset = props[.transform] == nil
                ? inheritedOffset
                : (DebugData.serializedTransform(of: data) ?? props[.transform].flatMap(DebugData.translation) ?? inheritedOffset)
            var frame = inherited
            var ownFrame = false
            if let position = props[.position] as? CGPoint, let size = props[.size] as? CGSize {
                frame = hostView.convert(CGRect(x: position.x + offset.x, y: position.y + offset.y,
                                                width: size.width, height: size.height), to: window)
                ownFrame = true
            }
            var node: [String: Any] = [
                "id": nodeID,
                "parent": parent,
                "kind": "swiftui",
                "class": String(readable.prefix(2000)),
                "frame": [frame.minX, frame.minY, frame.width, frame.height],
                "modifier": type.map { $0 is any ViewModifier.Type } ?? false,
                "ownFrame": ownFrame,
            ]
            if let type {
                let full = String(reflecting: type)
                node["type"] = String(full.prefix(2000))
                let names = appTypes(in: full)
                if !names.isEmpty { node["appTypes"] = names }
            }
            if let value = props[.value] {
                if !wrapperPrefixes.contains(where: { readable.hasPrefix($0) }) {
                    var flat = DebugData.flatten(value)
                    // A source tag carries its arguments' runtime record: keep it whole.
                    if readable == sourceTagType || readable == styleTagType, let tag = DebugData.firstString(in: value) {
                        flat["value"] = String(tag.prefix(16_000))
                    }
                    if !flat.isEmpty { node["props"] = flat }
                }
                if readable == "Text", let text = DebugData.firstString(in: value) {
                    node["text"] = String(text.prefix(300))
                }
            }
            out.append(node)
            for child in children.reversed() { stack.append((child, nodeID, frame, offset)) }
        }
    }

    /// A visible stand-in when a hosting view's SwiftUI tree can't be read.
    private static func diagnostic(_ message: String, parentID: String, frame: CGRect) -> [String: Any] {
        NSLog("[MyGitInspector] %@", message)
        return [
            "id": "\(parentID).error", "parent": parentID, "kind": "swiftui",
            "class": "⚠︎ " + message, "frame": [frame.minX, frame.minY, frame.width, frame.height],
            "modifier": false, "ownFrame": true,
        ]
    }

    private static func swiftUINode(_ raw: [String: Any], id nodeID: String, parent: String, hostView: UIView,
                                    window: UIWindow, inherited: CGRect,
                                    offset inheritedOffset: CGPoint) -> ([String: Any], CGRect, CGPoint) {
        // properties: [{id: _ViewDebug.Property.rawValue, attribute: {...}}]
        var attributes: [Int: [String: Any]] = [:]
        for entry in raw["properties"] as? [[String: Any]] ?? [] {
            if let id = entry["id"] as? Int, let attribute = entry["attribute"] as? [String: Any] {
                attributes[id] = attribute
            }
        }
        let typeAttr = attributes[0]
        let readable = typeAttr?["readableType"] as? String ?? typeAttr?["type"] as? String ?? "?"
        // Positions are in the coordinate space of the nearest transform
        // (a ScrollView's content, which doesn't move as it scrolls), and the
        // transform maps that space to the hosting view. It's the whole chain
        // from the root, not relative to an outer transform — verified with a
        // horizontal ScrollView inside a scrolled vertical one.
        let offset = translation(attributes[2]?["value"]) ?? inheritedOffset
        // Frameless nodes (most modifiers) take their parent's frame, as in Xcode.
        var frame = inherited
        var ownFrame = false
        if let position = cgPair(attributes[3]?["value"]), let size = cgPair(attributes[4]?["value"]) {
            let local = CGRect(x: position.0 + offset.x, y: position.1 + offset.y, width: size.0, height: size.1)
            frame = hostView.convert(local, to: window)
            ownFrame = true
        }
        var node: [String: Any] = [
            "id": nodeID,
            "parent": parent,
            "kind": "swiftui",
            "class": String(readable.prefix(2000)),
            "frame": [frame.minX, frame.minY, frame.width, frame.height],
            // 1 = view, 2 = modifier.
            "modifier": (typeAttr?["flags"] as? Int) == 2,
            // False: no geometry of its own, frame copied from the parent.
            "ownFrame": ownFrame,
        ]
        if let full = typeAttr?["type"] as? String {
            node["type"] = String(full.prefix(2000))
            // From the untruncated type: generic lists of screens can run
            // past any sensible cap, and a cut name is useless for search.
            let names = appTypes(in: full)
            if !names.isEmpty { node["appTypes"] = names }
        }
        if let value = attributes[1]?["value"], let text = shortValue(value) { node["value"] = text }
        if let props = flattenedProps(of: attributes[1], readableType: readable) { node["props"] = props }
        if readable == "Text", let text = firstString(in: attributes[1], depth: 0) {
            // The literal or localization key: "Accordion", "Row %lld".
            node["text"] = String(text.prefix(300))
        }
        return (node, frame, offset)
    }

    private static let systemModules: Set<String> = [
        "SwiftUI", "SwiftUICore", "UIKit", "UIKitCore", "Swift", "Foundation", "CoreGraphics",
        "CoreFoundation", "Combine", "ObjectiveC", "QuartzCore", "_Concurrency", "__C", "Observation",
    ]
    private static let qualifiedName = try! NSRegularExpression(pattern: "(?<![\\w.])([A-Za-z_][A-Za-z0-9_]*)\\.([A-Za-z_][A-Za-z0-9_]*)")

    /// App-defined type names in a module-qualified type string:
    /// `SwiftUI.ModifiedContent<Example.CardView, …>` → ["CardView"].
    private static func appTypes(in type: String) -> [String] {
        let ns = type as NSString
        var out: [String] = []
        for m in qualifiedName.matches(in: type, range: NSRange(location: 0, length: ns.length)) {
            let module = ns.substring(with: m.range(at: 1))
            let name = ns.substring(with: m.range(at: 2))
            guard !systemModules.contains(module), !module.hasPrefix("_"), !name.hasPrefix("_"),
                  name.first?.isUppercase == true, !out.contains(name) else { continue }
            out.append(name)
            if out.count >= 24 { break }
        }
        return out
    }

    /// Wrappers whose value is the whole subtree below them — noise, and big.
    /// The tagger's `.preference(key: __MyGitSourceKey.self, value: …)`.
    static let sourceTagType = "_PreferenceWritingModifier<__MyGitSourceKey>"
    /// Its sibling on chains that restyle an incoming view (`content.padding(…)`).
    static let styleTagType = "_PreferenceWritingModifier<__MyGitStyleKey>"

    static let wrapperPrefixes = [
        "ModifiedContent", "_ViewModifier_Content", "TupleView", "_ConditionalContent", "Optional<",
        "AnyView", "StaticIf", "_UnaryViewAdaptor", "_ViewList_View", "Group<", "ForEach",
        "NavigationStack", "NavigationView", "TabView", "ScrollView", "List<", "LazyView",
    ]

    /// A node's value as `path: value` pairs (`insets.top: 12`,
    /// `root.spacing: 8`, `maxWidth: inf`) for the attributes panel.
    private static func flattenedProps(of value: [String: Any]?, readableType: String) -> [String: String]? {
        guard let value, !wrapperPrefixes.contains(where: { readableType.hasPrefix($0) }) else { return nil }
        var out: [String: String] = [:]
        // Iterative: (attribute, path, depth).
        var stack: [([String: Any], [String], Int)] = [(value, [], 0)]
        while let (attribute, path, depth) = stack.popLast(), out.count < 40 {
            var p = path
            if let name = attribute["name"] as? String, !name.isEmpty { p.append(name) }
            // ForEach/Tree `content` repeats the children; skip it.
            if p.last == "content" { continue }
            if let v = attribute["value"] {
                let text: String
                switch v {
                case let s as String: text = s
                case let n as NSNumber: text = n.stringValue
                case let a as [Any]: text = "[" + a.map { "\($0)" }.joined(separator: ", ") + "]"
                case let d as [String: Any]: text = d.isEmpty ? "{}" : d.keys.sorted().joined(separator: "|")
                default: text = "\(v)"
                }
                out[p.isEmpty ? "value" : p.joined(separator: ".")] =
                    String(text.prefix(readableType == sourceTagType || readableType == styleTagType ? 16_000 : 160))
            }
            if depth < 7 {
                for sub in (attribute["subattributes"] as? [[String: Any]] ?? []).reversed() {
                    stack.append((sub, p, depth + 1))
                }
            }
        }
        return out.isEmpty ? nil : out
    }

    /// First `Swift.String` value under a serialized attribute (a `Text`'s
    /// storage keeps its verbatim string or localization key a few levels down).
    private static func firstString(in attribute: [String: Any]?, depth: Int) -> String? {
        guard let attribute, depth < 8 else { return nil }
        if attribute["type"] as? String == "Swift.String", let s = attribute["value"] as? String { return s }
        for sub in attribute["subattributes"] as? [[String: Any]] ?? [] {
            if let s = firstString(in: sub, depth: depth + 1) { return s }
        }
        return nil
    }

    /// Sum of the translations in a serialized `ViewTransform`
    /// (`{"items": [{"translation": [x, y]}, …]}`). Other element kinds
    /// (scale/rotation effects) are ignored, so those frames are approximate.
    private static func translation(_ value: Any?) -> CGPoint? {
        guard let items = (value as? [String: Any])?["items"] as? [[String: Any]] else { return nil }
        var total = CGPoint.zero
        for item in items {
            if let t = cgPair(item["translation"]) {
                total.x += t.0
                total.y += t.1
            }
        }
        return total
    }

    private static func cgPair(_ value: Any?) -> (CGFloat, CGFloat)? {
        guard let pair = value as? [Any], pair.count == 2,
              let a = (pair[0] as? NSNumber)?.doubleValue, let b = (pair[1] as? NSNumber)?.doubleValue else { return nil }
        return (CGFloat(a), CGFloat(b))
    }

    /// Scalars and strings only — some values are whole environments.
    private static func shortValue(_ value: Any) -> String? {
        switch value {
        case let s as String: return String(s.prefix(200))
        case let n as NSNumber: return n.stringValue
        default: return nil
        }
    }

    private static func owningViewController(of view: UIView) -> UIViewController? {
        guard let vc = view.next as? UIViewController, vc.viewIfLoaded === view else { return nil }
        return vc
    }

    private static func text(of view: UIView) -> String? {
        switch view {
        case let label as UILabel: return label.text
        case let field as UITextField: return field.text?.isEmpty == false ? field.text : field.placeholder
        case let textView as UITextView: return textView.text
        case let button as UIButton: return button.currentTitle
        default: return nil
        }
    }

    static func hex(_ color: UIColor, _ traits: UITraitCollection) -> String {
        var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        guard color.resolvedColor(with: traits).getRed(&r, green: &g, blue: &b, alpha: &a) else {
            return color.description
        }
        func c(_ v: CGFloat) -> String { String(format: "%02X", Int((max(0, min(1, v)) * 255).rounded())) }
        return "#" + c(r) + c(g) + c(b) + c(a)
    }

    // MARK: - Screenshot

    private static func screenshot(of window: UIWindow, scale: CGFloat) -> Data? {
        let format = UIGraphicsImageRendererFormat()
        format.scale = scale
        format.opaque = false
        let renderer = UIGraphicsImageRenderer(bounds: window.bounds, format: format)
        let image = renderer.image { _ in
            window.drawHierarchy(in: window.bounds, afterScreenUpdates: false)
        }
        return image.pngData()
    }

    // MARK: - Highlight on device

    /// Outline the frame MyGit selected, on the device itself; nil clears it.
    /// Window index and coordinates match the last `capture`.
    static func highlight(frame: CGRect?, windowIndex: Int) {
        removeHighlight()
        let windows = allWindows()
        guard let frame, windows.indices.contains(windowIndex) else { return }
        let overlay = UIView(frame: frame)
        overlay.isUserInteractionEnabled = false
        overlay.backgroundColor = UIColor.systemBlue.withAlphaComponent(0.2)
        overlay.layer.borderColor = UIColor.systemBlue.cgColor
        overlay.layer.borderWidth = 1
        windows[windowIndex].addSubview(overlay)
        highlightView = overlay
    }

    private static func removeHighlight() {
        highlightView?.removeFromSuperview()
        highlightView = nil
    }
}
