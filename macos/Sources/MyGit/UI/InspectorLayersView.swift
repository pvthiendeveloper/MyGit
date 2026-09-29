import SwiftUI

/// The exploded 3D view of the inspected window, like Xcode's view
/// debugger: one plane per depth of the outline, the screenshot on the back
/// plane, and each innermost view carrying its own piece of it forward.
/// Drag to turn it; click to select.
struct Inspector3DCanvas: View {
    @EnvironmentObject var vm: UIInspectorViewModel
    let window: InspectorWindow
    /// Window points → canvas points.
    let scale: CGFloat
    @State private var dragBase: (yaw: Double, pitch: Double)?

    var body: some View {
        GeometryReader { geo in
            let layers = vm.layers3D(canvas: geo.size, window: window.size, scale: scale)
            Canvas { context, size in
                let image = window.image.map { context.resolve(Image(nsImage: $0)) }
                let screen = CGRect(origin: .zero, size: window.size)
                let hairline = 1 / max(scale, 0.01)

                // The window itself, on the back plane.
                var back = context
                back.concatenate(vm.transform3D(depth: vm.layerRange.lowerBound, canvas: size, window: window.size, scale: scale))
                if let image { back.opacity = 0.3; back.draw(image, in: screen) }
                back.opacity = 1
                back.stroke(Path(screen), with: .color(.primary.opacity(0.3)), lineWidth: hairline)

                for layer in layers {
                    var c = context
                    c.concatenate(layer.transform)
                    let r = layer.node.frame
                    let selected = layer.node.id == vm.selectedID
                    let hovered = layer.node.id == vm.hoveredID
                    if layer.isLeaf, let image {
                        var piece = c
                        piece.clip(to: Path(r))
                        piece.draw(image, in: screen)
                    } else {
                        c.fill(Path(r), with: .color(.white.opacity(0.035)))
                    }
                    if selected {
                        c.fill(Path(r), with: .color(.accentColor.opacity(0.22)))
                        c.stroke(Path(r), with: .color(.accentColor), lineWidth: 2 * hairline)
                    } else if hovered {
                        c.stroke(Path(r), with: .color(.orange), lineWidth: 1.5 * hairline)
                    } else {
                        c.stroke(Path(r), with: .color(.gray.opacity(0.55)), lineWidth: hairline)
                    }
                }
            }
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 3)
                    .onChanged { value in
                        let base = dragBase ?? (vm.yaw, vm.pitch)
                        dragBase = base
                        vm.yaw = Self.clampAngle(base.yaw + value.translation.width * 0.35)
                        vm.pitch = Self.clampAngle(base.pitch - value.translation.height * 0.35)
                    }
                    .onEnded { _ in dragBase = nil }
            )
            .onTapGesture { location in
                if let node = vm.node3D(at: location, in: layers) { vm.reveal(node.id) } else { vm.selectedID = nil }
            }
            .onContinuousHover { phase in
                if case let .active(location) = phase {
                    vm.hoveredID = vm.node3D(at: location, in: layers)?.id
                } else {
                    vm.hoveredID = nil
                }
            }
            .contextMenu {
                if let node = vm.hoveredNode ?? vm.selectedNode {
                    InspectorSourceMenu(node: node)
                }
            }
        }
    }

    /// Past 80° the planes turn edge-on and the back-to-front order flips.
    private static func clampAngle(_ degrees: Double) -> Double { min(max(degrees, -80), 80) }
}

/// The preview's layer controls: which depths show (both ends drag, like
/// Xcode's range slider), and in 3D how far apart the planes are.
struct InspectorLayerControls: View {
    @EnvironmentObject var vm: UIInspectorViewModel

    var body: some View {
        HStack(spacing: 8) {
            Toggle(isOn: $vm.show3D) { Label("3D", systemImage: "square.3.layers.3d") }
                .toggleStyle(.button)
                .help("Pull the hierarchy apart in 3D — drag to turn it")
            if vm.maxDepth > 0 {
                Text("Layers").font(.caption).foregroundStyle(.secondary)
                LayerRangeSlider(range: $vm.layerRange, bounds: 0...vm.maxDepth)
                    .frame(width: 140, height: 18)
                    .help("Depths shown: \(vm.layerRange.lowerBound)–\(vm.layerRange.upperBound) of \(vm.maxDepth). Drag either end to hide outer containers or inner details.")
            }
            if vm.show3D {
                Text("Spacing").font(.caption).foregroundStyle(.secondary)
                Slider(value: $vm.layerSpacing, in: 4...80).frame(width: 80)
                Button("Front") { vm.yaw = 0; vm.pitch = 0 }
                    .buttonStyle(.borderless)
                    .help("Look straight at the screen")
            }
            if vm.layersAreFiltered {
                Button(vm.hiddenIDs.isEmpty ? "Show All" : "Show All (\(vm.hiddenIDs.count) hidden)") { vm.resetLayers() }
                    .buttonStyle(.borderless)
            }
        }
    }
}

/// Two knobs on one track, each on a whole depth.
struct LayerRangeSlider: View {
    @Binding var range: ClosedRange<Int>
    let bounds: ClosedRange<Int>
    @State private var dragging: Bool?   // true: the upper knob
    private let knob: CGFloat = 12

    private var count: CGFloat { CGFloat(max(bounds.upperBound - bounds.lowerBound, 1)) }

    /// Where a depth sits on a track `width` wide.
    private func x(_ value: Int, _ width: CGFloat) -> CGFloat {
        CGFloat(value - bounds.lowerBound) / count * max(width - knob, 1) + knob / 2
    }

    private func value(at x: CGFloat, _ width: CGFloat) -> Int {
        bounds.lowerBound + Int(((x - knob / 2) / max(width - knob, 1) * count).rounded()).clamped(to: 0...Int(count))
    }

    var body: some View {
        GeometryReader { geo in
            let w = geo.size.width
            let mid = geo.size.height / 2
            ZStack(alignment: .topLeading) {
                Capsule().fill(Color.primary.opacity(0.15))
                    .frame(width: max(w - knob, 1), height: 3)
                    .offset(x: knob / 2, y: mid - 1.5)
                Capsule().fill(Color.accentColor)
                    .frame(width: max(x(range.upperBound, w) - x(range.lowerBound, w), 0), height: 3)
                    .offset(x: x(range.lowerBound, w), y: mid - 1.5)
                ForEach([false, true], id: \.self) { upper in
                    Circle()
                        .fill(Color.white)
                        .overlay(Circle().stroke(Color.primary.opacity(0.3)))
                        .shadow(radius: 0.5)
                        .frame(width: knob, height: knob)
                        .offset(x: x(upper ? range.upperBound : range.lowerBound, w) - knob / 2, y: mid - knob / 2)
                }
            }
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { drag in
                        let v = value(at: drag.location.x, w)
                        // The nearer knob takes the drag, and keeps it.
                        let upper = dragging ?? (abs(drag.startLocation.x - x(range.upperBound, w))
                                                 < abs(drag.startLocation.x - x(range.lowerBound, w))
                                                 || (range.lowerBound == range.upperBound && v > range.upperBound))
                        dragging = upper
                        range = upper ? range.lowerBound...max(v, range.lowerBound) : min(v, range.upperBound)...range.upperBound
                    }
                    .onEnded { _ in dragging = nil }
            )
        }
    }
}

private extension Int {
    func clamped(to bounds: ClosedRange<Int>) -> Int { Swift.min(Swift.max(self, bounds.lowerBound), bounds.upperBound) }
}
