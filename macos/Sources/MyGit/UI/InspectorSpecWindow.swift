import SwiftUI
import AppKit

/// What the Spec window shows — frozen when opened, so live captures don't move it.
struct InspectorSpecSnapshot {
    let title: String
    let screenshot: NSImage
    let windowSize: CGSize
    /// The view with its own wrappers, window points.
    let box: CGRect
    let measures: [InspectorMeasure]
    /// Measure id → token name as written in Swift ("" = none).
    let names: [String: String]
    /// Radius measures' shape frames (for the corner arc).
    let shapes: [String: CGRect]
}

/// The Spec window: the selected view drawn large, its paddings and gaps in
/// pink, corners in blue, each labeled with its token — zoomable, to hold
/// next to the Figma design.
@MainActor
enum InspectorSpecWindow {
    private static var windows: [NSWindow] = []

    /// The window's content as an image (for checks without a window).
    static func render(_ snapshot: InspectorSpecSnapshot, size: CGSize, hovered: Int? = nil) -> NSImage? {
        let scale = InspectorSpecView.fit(snapshot, in: size)
        let layout = SpecLayout(snapshot: snapshot, scale: scale)
        let renderer = ImageRenderer(content: SpecCanvas(snapshot: snapshot, layout: layout, hovered: hovered)
            .frame(width: max(size.width, layout.size.width), height: max(size.height, layout.size.height))
            .background(Color(white: 0.95)))
        return renderer.nsImage
    }

    static func open(_ snapshot: InspectorSpecSnapshot) {
        let window = NSWindow(contentViewController: NSHostingController(rootView: InspectorSpecView(snapshot: snapshot)))
        window.title = "Spec — \(snapshot.title)"
        window.styleMask = [.titled, .closable, .miniaturizable, .resizable]
        window.setContentSize(NSSize(width: 1200, height: 800))
        window.center()
        window.isReleasedWhenClosed = false
        windows.append(window)
        NotificationCenter.default.addObserver(forName: NSWindow.willCloseNotification, object: window, queue: .main) { _ in
            MainActor.assumeIsolated { windows.removeAll { $0 === window } }
        }
        window.makeKeyAndOrderFront(nil)
    }
}

struct InspectorSpecView: View {
    let snapshot: InspectorSpecSnapshot
    /// Points per view point; nil until fitted to the window.
    @State private var scale: CGFloat?
    @State private var pinchBase: CGFloat?
    @State private var monitor: Any?
    @State private var hovering = false
    /// The callout under the pointer (its label, strip or marker).
    @State private var hovered: Int?
    private static let range: ClosedRange<CGFloat> = 0.5...12

    var body: some View {
        VStack(spacing: 0) {
            GeometryReader { geo in
                let s = scale ?? fit(geo.size)
                let layout = SpecLayout(snapshot: snapshot, scale: s)
                ScrollView([.horizontal, .vertical]) {
                    SpecCanvas(snapshot: snapshot, layout: layout, hovered: hovered)
                        .onContinuousHover { phase in
                            if case let .active(point) = phase { hovered = layout.callout(at: point) } else { hovered = nil }
                        }
                        .frame(minWidth: geo.size.width, minHeight: geo.size.height)
                }
                .background(Color(white: 0.95))
                .simultaneousGesture(
                    MagnifyGesture()
                        .onChanged { value in
                            let base = pinchBase ?? s
                            pinchBase = base
                            scale = clamp(base * value.magnification)
                        }
                        .onEnded { _ in pinchBase = nil }
                )
                .onHover { hovering = $0 }
                .onAppear { if scale == nil { scale = fit(geo.size) } }
            }
            Divider()
            HStack(spacing: 10) {
                Text("\(snapshot.measures.count) measure\(snapshot.measures.count == 1 ? "" : "s")")
                    .font(.caption).foregroundStyle(.secondary)
                Spacer()
                Image(systemName: "minus.magnifyingglass").foregroundStyle(.secondary)
                Slider(value: Binding(get: { scale ?? 1 }, set: { scale = clamp($0) }), in: Self.range)
                    .frame(width: 180)
                Image(systemName: "plus.magnifyingglass").foregroundStyle(.secondary)
                Text("\(Int(((scale ?? 1) * 100).rounded()))%").font(.caption.monospacedDigit()).frame(width: 48)
                Button("Fit") { scale = nil }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
        }
        .frame(minWidth: 600, minHeight: 400)
        .onAppear(perform: installScrollZoom)
        .onDisappear { if let monitor { NSEvent.removeMonitor(monitor) } }
    }

    private func fit(_ size: CGSize) -> CGFloat { Self.fit(snapshot, in: size) }

    /// The view fills about 60% of the width (labels take the rest), up to 6×.
    static func fit(_ snapshot: InspectorSpecSnapshot, in size: CGSize) -> CGFloat {
        guard snapshot.box.width > 0, snapshot.box.height > 0 else { return 1 }
        return min(max(min(size.width * 0.6 / snapshot.box.width, size.height * 0.6 / snapshot.box.height, 6), range.lowerBound),
                   range.upperBound)
    }

    private func clamp(_ s: CGFloat) -> CGFloat { min(max(s, Self.range.lowerBound), Self.range.upperBound) }

    /// ⌘ + scroll zooms, like the preview.
    private func installScrollZoom() {
        guard monitor == nil else { return }
        monitor = NSEvent.addLocalMonitorForEvents(matching: .scrollWheel) { event in
            guard hovering, event.modifierFlags.contains(.command) else { return event }
            let delta = event.hasPreciseScrollingDeltas ? event.scrollingDeltaY / 200 : event.scrollingDeltaY / 20
            scale = clamp((scale ?? 1) * (1 + delta))
            return nil
        }
    }

}

/// The spec drawing at one layout: the crop, strips, markers and labels.
struct SpecCanvas: View {
    let snapshot: InspectorSpecSnapshot
    let layout: SpecLayout
    var hovered: Int?

    var body: some View {
        Canvas { context, _ in draw(layout, in: &context) }
            .frame(width: layout.size.width, height: layout.size.height)
    }

    // MARK: - Drawing

    private static let pink = Color(red: 0.91, green: 0.13, blue: 0.55)
    private static let blue = Color(red: 0.12, green: 0.53, blue: 0.9)

    private func draw(_ layout: SpecLayout, in context: inout GraphicsContext) {
        let s = layout.scale, box = snapshot.box, target = layout.imageRect
        var crop = context
        crop.clip(to: Path(target))
        crop.draw(Image(nsImage: snapshot.screenshot),
                  in: CGRect(x: target.minX - box.minX * s, y: target.minY - box.minY * s,
                             width: snapshot.windowSize.width * s, height: snapshot.windowSize.height * s))
        let dotted = StrokeStyle(lineWidth: 1, dash: [1.5, 2])
        context.stroke(Path(target), with: .color(Self.pink), style: dotted)

        // The hovered callout last, so it sits on top.
        let order = layout.callouts.indices.filter { $0 != hovered } + (hovered.map { [$0] } ?? [])
        for index in order {
            let callout = layout.callouts[index]
            let active = hovered == nil || hovered == index
            let emphasized = hovered == index
            var context = context
            context.opacity = active ? 1 : 0.9
            let color = callout.kind == .radius ? Self.blue : Self.pink
            let strip = layout.map(callout.measure.rect)
            if callout.kind != .radius {
                context.fill(Path(strip), with: .color(Self.pink.opacity(emphasized ? 0.4 : 0.12)))
                context.stroke(Path(strip), with: .color(Self.pink),
                               style: emphasized ? StrokeStyle(lineWidth: 2) : dotted)
            }
            var marker = Path()
            switch callout.kind {
            case .above, .below:
                let y = callout.kind == .above ? target.minY - 9 : target.maxY + 9
                marker.move(to: CGPoint(x: strip.minX, y: y)); marker.addLine(to: CGPoint(x: strip.maxX, y: y))
                for x in [strip.minX, strip.maxX] {
                    marker.move(to: CGPoint(x: x, y: y - 4)); marker.addLine(to: CGPoint(x: x, y: y + 4))
                }
                let edge = callout.kind == .above ? callout.pill.maxY : callout.pill.minY
                marker.move(to: CGPoint(x: strip.midX, y: y)); marker.addLine(to: CGPoint(x: callout.pill.midX, y: edge))
            case .right:
                let x = target.maxX + 10
                marker.move(to: CGPoint(x: x, y: strip.minY)); marker.addLine(to: CGPoint(x: x, y: strip.maxY))
                for y in [strip.minY, strip.maxY] {
                    marker.move(to: CGPoint(x: x - 4, y: y)); marker.addLine(to: CGPoint(x: x + 4, y: y))
                }
                marker.move(to: CGPoint(x: x, y: strip.midY)); marker.addLine(to: CGPoint(x: callout.pill.minX, y: callout.pill.midY))
            case .radius:
                let shape = layout.map(snapshot.shapes[callout.measure.nodeID] ?? callout.measure.rect)
                let r = min(CGFloat(callout.measure.value) * s, shape.width / 2, shape.height / 2)
                let center = CGPoint(x: shape.minX + r, y: shape.maxY - r)
                marker.addArc(center: center, radius: r, startAngle: .degrees(180), endAngle: .degrees(90), clockwise: true)
                let foot = CGPoint(x: center.x - r * 0.707, y: center.y + r * 0.707)
                marker.move(to: foot); marker.addLine(to: CGPoint(x: foot.x, y: callout.pill.minY))
            }
            context.stroke(marker, with: .color(color),
                           lineWidth: (callout.kind == .radius ? 2.5 : 1.2) * (emphasized ? 1.8 : 1))
            if emphasized {
                context.stroke(Path(roundedRect: callout.pill.insetBy(dx: -2.5, dy: -2.5), cornerRadius: 8),
                               with: .color(color.opacity(0.45)), lineWidth: 3)
            }
            drawPill(callout, color: color, in: &context)
        }
    }

    private func drawPill(_ callout: SpecLayout.Callout, color: Color, in context: inout GraphicsContext) {
        let pill = callout.pill
        context.fill(Path(roundedRect: pill, cornerRadius: 6), with: .color(color))
        let font = Font.system(size: SpecLayout.fontSize, weight: .medium)
        if !callout.name.isEmpty {
            let nameBox = CGRect(x: pill.minX + 3, y: pill.minY + 3, width: callout.nameWidth + 8, height: pill.height - 6)
            context.fill(Path(roundedRect: nameBox, cornerRadius: 4), with: .color(.white.opacity(0.18)))
            context.draw(Text(callout.name).font(font).foregroundColor(.white), at: CGPoint(x: nameBox.midX, y: nameBox.midY))
        }
        context.draw(Text(callout.value).font(font.weight(.semibold)).foregroundColor(.white),
                     at: CGPoint(x: pill.maxX - 5 - callout.valueWidth / 2, y: pill.midY))
    }
}

/// Where everything goes at a given scale: the view large, labels at a fixed
/// small size around it — horizontal paddings above, vertical ones to the
/// right, horizontal gaps and corners below.
@MainActor
struct SpecLayout {
    enum Kind { case above, right, below, radius }
    struct Callout {
        let measure: InspectorMeasure
        let kind: Kind
        let name: String
        let value: String
        let nameWidth: CGFloat
        let valueWidth: CGFloat
        var pill: CGRect = .zero
    }

    static let fontSize: CGFloat = 11
    private static let pillHeight: CGFloat = 20
    private static let rowHeight: CGFloat = 26
    private static let margin: CGFloat = 24

    let scale: CGFloat
    let box: CGRect
    var imageRect: CGRect = .zero
    var callouts: [Callout] = []
    var size: CGSize = .zero

    func map(_ r: CGRect) -> CGRect {
        CGRect(x: imageRect.minX + (r.minX - box.minX) * scale, y: imageRect.minY + (r.minY - box.minY) * scale,
               width: r.width * scale, height: r.height * scale)
    }

    /// Which callout a point is on: a label first, then a marker (a few points
    /// of slack — lines are thin), then the smallest strip.
    func callout(at point: CGPoint) -> Int? {
        if let i = callouts.firstIndex(where: { $0.pill.insetBy(dx: -2, dy: -2).contains(point) }) { return i }
        for (i, c) in callouts.enumerated() {
            let strip = map(c.measure.rect)
            let zone: CGRect
            switch c.kind {
            case .above: zone = CGRect(x: strip.minX - 4, y: imageRect.minY - 16, width: strip.width + 8, height: 14)
            case .below: zone = CGRect(x: strip.minX - 4, y: imageRect.maxY + 2, width: strip.width + 8, height: 14)
            case .right: zone = CGRect(x: imageRect.maxX + 2, y: strip.minY - 4, width: 16, height: strip.height + 8)
            case .radius: zone = strip.insetBy(dx: -4, dy: -4)
            }
            if zone.contains(point) { return i }
        }
        return callouts.indices
            .filter { callouts[$0].kind != .radius && map(callouts[$0].measure.rect).insetBy(dx: -1, dy: -1).contains(point) }
            .min { map(callouts[$0].measure.rect).width * map(callouts[$0].measure.rect).height
                < map(callouts[$1].measure.rect).width * map(callouts[$1].measure.rect).height }
    }

    init(snapshot: InspectorSpecSnapshot, scale: CGFloat) {
        self.scale = scale
        box = snapshot.box
        let font = NSFont.systemFont(ofSize: Self.fontSize, weight: .medium)
        func textWidth(_ s: String) -> CGFloat { ceil((s as NSString).size(withAttributes: [.font: font]).width) }
        var items: [Callout] = snapshot.measures.map { m in
            let kind: Kind
            switch m.kind {
            case .radius: kind = .radius
            case .padding: kind = m.edge == "leading" || m.edge == "trailing" ? .above : .right
            case .gap: kind = m.rect.width < m.rect.height ? .below : .right
            }
            let name = snapshot.names[m.id] ?? ""
            let value = UIInspectorViewModel.fmt(m.value)
            return Callout(measure: m, kind: kind, name: name, value: value,
                           nameWidth: name.isEmpty ? 0 : textWidth(name), valueWidth: textWidth(value))
        }
        func pillWidth(_ c: Callout) -> CGFloat { (c.name.isEmpty ? 0 : c.nameWidth + 14) + c.valueWidth + 12 }

        // Lay out with the view at (0, 0), then shift everything into view.
        let image = CGRect(x: 0, y: 0, width: box.width * scale, height: box.height * scale)
        imageRect = image
        func pack(_ kinds: Set<Kind>) -> Int {
            var rows: [[ClosedRange<CGFloat>]] = []
            // Row 0 hugs the view; right-hand labels take the inner rows so the
            // outer labels' leaders run clear of them.
            let order = items.indices.filter { kinds.contains(items[$0].kind) }
                .sorted { items[$0].measure.rect.midX > items[$1].measure.rect.midX }
            for i in order {
                let w = pillWidth(items[i])
                let strip = map(items[i].measure.rect)
                let anchor = items[i].kind == .radius ? strip.minX : strip.midX
                let lead: CGFloat = items[i].kind == .radius ? w * 0.3 : (anchor < image.midX ? w - 24 : 24)
                let x = anchor - lead
                let span = x...(x + w)
                let row = rows.firstIndex { $0.allSatisfy { !$0.overlaps(span.lowerBound - 8...span.upperBound + 8) } } ?? rows.count
                if row == rows.count { rows.append([]) }
                rows[row].append(span)
                items[i].pill = CGRect(x: x, y: CGFloat(row), width: w, height: Self.pillHeight)
            }
            return rows.count
        }
        _ = pack([.above])
        _ = pack([.below, .radius])
        for i in items.indices {
            let row = items[i].pill.minY
            switch items[i].kind {
            case .above: items[i].pill.origin.y = image.minY - 20 - Self.pillHeight - row * Self.rowHeight
            case .below, .radius: items[i].pill.origin.y = image.maxY + 22 + row * Self.rowHeight
            case .right: break
            }
        }
        var nextY = -CGFloat.infinity
        for i in items.indices.sorted(by: { items[$0].measure.rect.midY < items[$1].measure.rect.midY }) where items[i].kind == .right {
            let strip = map(items[i].measure.rect)
            let y = max(strip.midY - Self.pillHeight / 2, nextY)
            items[i].pill = CGRect(x: image.maxX + 24, y: y, width: pillWidth(items[i]), height: Self.pillHeight)
            nextY = y + Self.pillHeight + 4
        }
        // Shift so everything starts at the margin.
        let bounds = items.map(\.pill).reduce(image.insetBy(dx: -16, dy: -16)) { $0.union($1) }
        let dx = Self.margin - bounds.minX, dy = Self.margin - bounds.minY
        imageRect = image.offsetBy(dx: dx, dy: dy)
        for i in items.indices { items[i].pill = items[i].pill.offsetBy(dx: dx, dy: dy) }
        callouts = items
        size = CGSize(width: bounds.width + Self.margin * 2, height: bounds.height + Self.margin * 2)
    }
}
