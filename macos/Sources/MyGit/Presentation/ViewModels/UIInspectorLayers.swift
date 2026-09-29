import CoreGraphics
import Foundation

/// Cutting the noise, like Xcode's view debugger: hide a view (and what's
/// inside it) by hand, or keep only a range of depths; and the 3D exploded
/// view, where each depth of the outline tree is its own plane.
extension UIInspectorViewModel {
    /// Shown in the preview: inside the depth range and not under a hidden view.
    func isInLayers(_ id: String) -> Bool {
        if let depth = depthOf[id], !layerRange.contains(depth) { return false }
        guard !hiddenIDs.isEmpty else { return true }
        var cursor: String? = id
        while let c = cursor {
            if hiddenIDs.contains(c) { return false }
            cursor = parentOf[c]
        }
        return true
    }

    /// Hidden by hand itself, or inside a hidden view (the outline dims both).
    func isHiddenByHand(_ id: String) -> Bool {
        var cursor: String? = id
        while let c = cursor {
            if hiddenIDs.contains(c) { return true }
            cursor = parentOf[c]
        }
        return false
    }

    func hide(_ id: String) {
        hiddenIDs.insert(id)
        if let selected = selectedID, !isInLayers(selected) { selectedID = nil }
        hoveredID = nil
    }

    /// Hide everything beside this view's branch: every sibling of it and
    /// of its ancestors. It keeps what's inside it; its ancestors stay as
    /// the boxes around it.
    func hideOthers(_ id: String) {
        var ancestors: Set<String> = []
        var cursor = parentOf[id]
        while let c = cursor { ancestors.insert(c); cursor = parentOf[c] }
        hiddenIDs = Set(order.filter { other in
            other != id && !ancestors.contains(other)
                && (parentOf[other].map { ancestors.contains($0) } ?? true)
        })
        hoveredID = nil
    }

    func showHiddenViews() { hiddenIDs = [] }

    var layersAreFiltered: Bool { !hiddenIDs.isEmpty || layerRange != 0...maxDepth }

    func resetLayers() {
        hiddenIDs = []
        layerRange = 0...maxDepth
    }

    /// After a capture: depths of the new tree, the range kept where the user
    /// put it (following the bottom when it was at the bottom), and hidden
    /// views that are gone dropped.
    func rebuildDepths() {
        var depths: [String: Int] = [:]
        for id in order {   // parents come before their children
            depths[id] = parentOf[id].flatMap { depths[$0] }.map { $0 + 1 } ?? 0
        }
        depthOf = depths
        let oldMax = maxDepth
        let newMax = depths.values.max() ?? 0
        maxDepth = newMax
        let lower = min(layerRange.lowerBound, newMax)
        let upper = layerRange.upperBound >= oldMax ? newMax : min(max(layerRange.upperBound, lower), newMax)
        layerRange = lower...upper
        hiddenIDs = hiddenIDs.filter { nodes[$0] != nil }
    }

    // MARK: - 3D

    /// One plane of the exploded view.
    struct Layer3D {
        let node: InspectorNode
        let depth: Int
        /// Window points → canvas points for this plane.
        let transform: CGAffineTransform
        /// Nothing drawn above it in the outline: its content is what shows.
        let isLeaf: Bool
    }

    /// The shown nodes as planes, back to front, for a canvas of `size`
    /// showing the window at `scale`. Orthographic, so every plane maps to
    /// the canvas with one affine transform: rotate about the vertical axis
    /// (yaw), then the horizontal one (pitch), and drop the depth.
    func layers3D(canvas size: CGSize, window: CGSize, scale: CGFloat) -> [Layer3D] {
        let shown = wireframeNodes
        let shownIDs = Set(shown.map(\.id))
        var hasShownChild: Set<String> = []
        for node in shown { if let parent = parentOf[node.id], shownIDs.contains(parent) { hasShownChild.insert(parent) } }

        return shown
            .map { node -> Layer3D in
                let depth = depthOf[node.id] ?? 0
                return Layer3D(node: node, depth: depth,
                               transform: transform3D(depth: depth, canvas: size, window: window, scale: scale),
                               isLeaf: !hasShownChild.contains(node.id))
            }
            // Parallel planes: back to front is by depth while the view looks
            // from the front (|yaw|, |pitch| < 90°). Stable within a depth.
            .enumerated()
            .sorted { ($0.element.depth, $0.offset) < ($1.element.depth, $1.offset) }
            .map(\.element)
    }

    /// Window points → canvas points for the plane at `depth`.
    func transform3D(depth: Int, canvas size: CGSize, window: CGSize, scale: CGFloat) -> CGAffineTransform {
        let lowest = layerRange.lowerBound
        let span = CGFloat(layerRange.upperBound - lowest)
        let yaw = self.yaw * .pi / 180, pitch = self.pitch * .pi / 180
        let (sy, cy, sp, cp) = (CGFloat(sin(yaw)), CGFloat(cos(yaw)), CGFloat(sin(pitch)), CGFloat(cos(pitch)))
        // Centered on the window and the stack, so it turns in place.
        let z = (CGFloat(depth - lowest) - span / 2) * CGFloat(layerSpacing)
        // (x, y, z) → x' = x·cy + z·sy ; y' = x·sp·sy + y·cp − z·sp·cy
        return CGAffineTransform(translationX: -window.width / 2, y: -window.height / 2)
            .concatenating(CGAffineTransform(a: cy, b: sp * sy, c: 0, d: cp, tx: z * sy, ty: -z * sp * cy))
            .concatenating(CGAffineTransform(scaleX: scale, y: scale))
            .concatenating(CGAffineTransform(translationX: size.width / 2, y: size.height / 2))
    }

    /// The frontmost plane under a canvas point (smallest box on a tie).
    func node3D(at point: CGPoint, in layers: [Layer3D]) -> InspectorNode? {
        var best: Layer3D?
        for layer in layers.reversed() {
            if let found = best, layer.depth < found.depth { break }
            guard layer.node.alpha > 0.01 else { continue }
            let local = point.applying(layer.transform.inverted())
            guard layer.node.frame.contains(local) else { continue }
            if let found = best,
               found.node.frame.width * found.node.frame.height <= layer.node.frame.width * layer.node.frame.height { continue }
            best = layer
        }
        return best?.node
    }
}
