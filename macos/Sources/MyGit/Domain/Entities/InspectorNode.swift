import AppKit

/// One view in a running iOS app's hierarchy, as the MyGitInspector agent
/// reports it: a UIKit view, or a SwiftUI view inside a hosting view.
/// Frames are in the window's coordinate space, in points.
struct InspectorNode: Identifiable {
    enum Kind: String, Decodable { case uikit, swiftui }

    let id: String
    let kind: Kind
    /// UIKit class, or SwiftUI's readable type (`HStack<TupleView<…>>`).
    let className: String
    let frame: CGRect
    let children: [InspectorNode]

    var isHidden = false
    var alpha: Double = 1
    var isInteractive = true
    var clipsToBounds = false
    var viewController: String?
    /// Module-qualified (`Example.HomeViewController`).
    var viewControllerType: String?
    var backgroundColor: String?
    var accessibilityIdentifier: String?
    var accessibilityLabel: String?
    var text: String?
    /// SwiftUI: a modifier (`_PaddingLayout`, `AccessibilityAttachmentModifier`)
    /// rather than a view.
    var isModifier = false
    /// App-defined types named in `fullType` (from the agent, which sees the
    /// untruncated type).
    var appTypes: [String]?
    /// SwiftUI: the node's value flattened to `path: value`
    /// (`insets.top: 12`, `root.spacing: 8`, `maxWidth: inf`).
    var props: [String: String] = [:]
    /// SwiftUI: false when the node has no geometry of its own and `frame`
    /// is its parent's (most modifiers and wrappers).
    var hasOwnFrame = true
    /// Fully qualified type (`SwiftUI.HStack<…>`, `Example.HomeCell`).
    var fullType: String?
    var value: String?

    /// `HStack<TupleView<…>>` → `HStack`: the part before generics, for rows.
    var shortName: String {
        guard let angle = className.firstIndex(of: "<") else { return className }
        return String(className[..<angle])
    }
}

/// One node as the agent sends it: flat, naming its parent. The tree is
/// rebuilt with `InspectorNode.tree(from:root:)`.
struct InspectorWireNode: Decodable {
    let id: String
    let parent: String?
    let kind: InspectorNode.Kind?
    let className: String
    let frame: [Double]
    var hidden: Bool?
    var alpha: Double?
    var interactive: Bool?
    var clips: Bool?
    var viewController: String?
    var viewControllerType: String?
    var backgroundColor: String?
    var accessibilityIdentifier: String?
    var accessibilityLabel: String?
    var text: String?
    var modifier: Bool?
    var type: String?
    var appTypes: [String]?
    var props: [String: String]?
    var ownFrame: Bool?
    var value: String?

    private enum CodingKeys: String, CodingKey {
        case id, parent, kind, frame, hidden, alpha, interactive, clips, viewController, viewControllerType
        case backgroundColor, accessibilityIdentifier, accessibilityLabel, text, modifier, type, value, appTypes, props, ownFrame
        case className = "class"
    }
}

extension InspectorNode {
    /// Rebuild the tree without recursion: real apps nest hundreds of levels
    /// deep. Children keep the list's (pre-order) order.
    static func tree(from wire: [InspectorWireNode], root: String) -> InspectorNode? {
        var childIDs: [String: [String]] = [:]
        for node in wire { if let parent = node.parent { childIDs[parent, default: []].append(node.id) } }
        var built: [String: InspectorNode] = [:]
        // Reverse pre-order visits every child before its parent.
        for w in wire.reversed() {
            let children = (childIDs[w.id] ?? []).compactMap { built.removeValue(forKey: $0) }
            let f = w.frame
            var node = InspectorNode(
                id: w.id,
                kind: w.kind ?? .uikit,
                className: w.className,
                frame: f.count == 4 ? CGRect(x: f[0], y: f[1], width: f[2], height: f[3]) : .zero,
                children: children
            )
            node.isHidden = w.hidden ?? false
            node.alpha = w.alpha ?? 1
            node.isInteractive = w.interactive ?? true
            node.clipsToBounds = w.clips ?? false
            node.viewController = w.viewController
            node.viewControllerType = w.viewControllerType
            node.backgroundColor = w.backgroundColor
            node.accessibilityIdentifier = w.accessibilityIdentifier
            node.accessibilityLabel = w.accessibilityLabel
            node.text = w.text
            node.isModifier = w.modifier ?? false
            node.fullType = w.type
            node.appTypes = w.appTypes
            node.props = w.props ?? [:]
            node.hasOwnFrame = w.ownFrame ?? true
            node.value = w.value
            built[w.id] = node
        }
        return built[root]
    }
}

/// One window of the inspected app: its tree plus what it looked like.
struct InspectorWindow: Identifiable {
    let root: InspectorNode
    let size: CGSize
    let isKey: Bool
    let image: NSImage?

    var id: String { root.id }
}

/// Which app a snapshot came from.
struct InspectorAppInfo: Decodable, Equatable {
    var appName: String?
    var bundleId: String?
    var device: String?
    var system: String?
    var simulator: Bool?
    var `protocol`: Int?
}

/// A full capture: every visible window of the app, taken at `takenAt`.
struct InspectorSnapshot {
    let windows: [InspectorWindow]
    let info: InspectorAppInfo?
    let takenAt: Date
}

/// An app advertising the inspector agent over Bonjour.
struct InspectorService: Identifiable, Hashable {
    /// Bonjour instance name: "<app> — <device>".
    let name: String
    var id: String { name }
}

/// A place in the open workspace's code that an inspected view points to.
struct InspectorSourceHit: Identifiable, Hashable {
    let repo: URL
    let repoName: String
    let path: String      // repo-relative
    let line: Int         // 1-based
    let preview: String

    var id: String { "\(repo.path):\(path):\(line)" }
}
