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
    /// Which `return`s of probed getters/functions ran (Run with Inspector):
    /// `"path:line"` → the latest values each produced, newest last.
    var branches: [String: [String]] = [:]
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

/// How a tagged view expression was written (from the source tagger's map):
/// which arguments read design tokens and which are hardcoded.
struct InspectorSourceMapEntry: Decodable {
    struct Argument: Decodable {
        let label: String?
        let expr: String
        let token: Bool
        /// Where the names it reads are: alternatives of ordered fallbacks.
        var refs: [[InspectorRef]]?
        /// For a local (`uiImage`): what it was bound to.
        var binding: String?
        /// Its number in the tag's runtime record (see `InspectorSourceTag.traces`).
        var probe: Int?
        /// A `cornerRadius:` written inside it, as its own argument (at most one).
        var radius: [Argument]?
    }

    /// The function / type the view is written in.
    struct Scope: Decodable {
        struct Parameter: Decodable {
            let name: String
            let label: String?
        }
        var function: String?
        var parameters: [Parameter]?
        var type: String?
    }

    struct Modifier: Decodable {
        let name: String
        let args: [Argument]
    }

    let call: String
    let args: [Argument]
    /// Source order: first = innermost.
    let mods: [Modifier]
    var scope: Scope?
}

/// A name read at a place in the original source (1-based line/column).
struct InspectorRef: Decodable, Hashable {
    let name: String
    let line: Int
    let column: Int
}

/// A simple-valued property from the tagger's index (`_symbols.json`).
struct InspectorSymbol: Decodable {
    let name: String
    let owner: String?
    let path: String
    let line: Int
    let expr: String
    let literal: String?
    /// A function's return value rather than a property.
    var function: Bool?
    /// Where the names in `expr` are, when it references something.
    var refs: [[InspectorRef]]?
    /// Line of the declared name, when `line` is a `return` inside it.
    var declLine: Int?
    /// This `return` reports at runtime when it runs (see `snapshot.branches`).
    var probed: Bool?
    /// A stored property without a value: see its initializer arguments.
    var stored: Bool?
    /// An initializer argument for stored property `name` of type `initOf`.
    var initOf: String?
    /// Line the initializer call starts on (what a `return` probe reports).
    var callLine: Int?

    /// Whether a runtime trace (`"path:line"` of the `return`s that ran) went through it.
    func ran(in branches: Set<String>) -> Bool {
        branches.contains("\(path):\(line)") || callLine.map { branches.contains("\(path):\($0)") } == true
    }
}

/// What one probed argument of one view instance evaluated to, and the
/// probed `return`s (`"path:line"`) it passed through on the way.
struct InspectorTokenTrace {
    let value: String
    let branches: [String]
}

/// A token expression resolved as far as the code allows: parameters
/// traced to their call sites, then properties to a root value.
struct InspectorTokenResolution {
    /// Human-readable steps, first = what the view's line says.
    let steps: [String]
    /// The followed chain, when one reached the index.
    let chain: InspectorTokenChain?
    /// Several possible roots (a function whose branches return different
    /// tokens, e.g. `labelColor(role)`), when the value on screen can't pick one.
    let alternatives: [InspectorSymbol]
    /// True when every step came from the compiler's index (and the tag
    /// stack); false for the by-name fallback.
    var exact = false
    /// What picked `chain` among several possible roots, when something did.
    var pickedBy: Pick?

    enum Pick: Equatable {
        /// The other roots can't produce the value on screen.
        case screenValue
        /// The app reported which `return` ran (Run with Inspector).
        case runtimeBranch
        /// This view's own evaluation of the argument passed through the
        /// chain's `return` (Run with Inspector's token probes).
        case traced
        /// A language model's reading of the code — a suggestion, not proof.
        case ai(confidence: Double, reason: String)
    }
}

/// A view's token followed to the design token at its root:
/// `tokenProvider.labelToValueSpacing` → `TymeXSwiftUI.patternGapGroupTextToGroupText` = 4.
struct InspectorTokenChain {
    /// Each definition followed, source token first, root last.
    let hops: [InspectorSymbol]
    var root: InspectorSymbol { hops[hops.count - 1] }
    /// The root's literal value, when the chain ended in one.
    var value: String? { root.literal }
}
