import AppKit

/// Redlines: the screen with every padding, gap and corner radius drawn in
/// and labeled with its value and token — like a Zeplin spec, for a designer
/// or a pull request.
extension UIInspectorViewModel {
    /// The selected view's area (or the whole screen), rendered at 2×. Copied
    /// to the clipboard; `save` then asks where to write the PNG.
    func exportRedlines(save: Bool) {
        guard !redlinesRunning else { return }
        redlinesRunning = true
        Task { @MainActor [weak self] in
            guard let self else { return }
            let image = await redlinesImage(area: selectedNode?.frame)
            redlinesRunning = false
            guard let image else { return }
            NSPasteboard.general.clearContents()
            NSPasteboard.general.writeObjects([image])
            guard save, let data = image.pngData() else { return }
            let panel = NSSavePanel()
            panel.allowedContentTypes = [.png]
            panel.nameFieldStringValue = "Redlines \(Self.fileDate()).png"
            if panel.runModal() == .OK, let url = panel.url { try? data.write(to: url) }
        }
    }

    /// The redlines of `area` (window points; nil = the whole screen).
    func redlinesImage(area requested: CGRect?) async -> NSImage? {
        guard let window = currentWindow, let screenshot = window.image else { return nil }
        let area = requested ?? CGRect(origin: .zero, size: window.size)
        // One label per padding edge / gap; one per shape for corners.
        var seen = Set<String>()
        let measures = collectMeasures().filter { m in
            area.insetBy(dx: -1, dy: -1).contains(m.rect.integral.insetBy(dx: 1, dy: 1))
                && seen.insert(m.kind == .radius ? "r:\(m.nodeID)" : m.id).inserted
        }
        let title = [snapshot?.info?.appName, selectedNode.map { sourceStack(for: $0.id).first?.label ?? $0.shortName }]
            .compactMap { $0 }.joined(separator: " — ")
        var labeled: [(InspectorMeasure, String)] = []
        for m in measures { labeled.append((m, await tokenName(for: m))) }
        return Self.renderRedlines(screenshot: screenshot, windowSize: window.size, area: area,
                                   measures: labeled, title: title.isEmpty ? "Redlines" : title)
    }

    static func fileDate() -> String {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd HH.mm.ss.SSS"
        return f.string(from: Date())
    }

    /// Crop of the screenshot around `area`, with a header, the measures and their labels.
    static func renderRedlines(screenshot: NSImage, windowSize: CGSize, area: CGRect,
                               measures: [(InspectorMeasure, String)], title: String) -> NSImage {
        let scale: CGFloat = 2
        let margin: CGFloat = 24
        let header: CGFloat = 44
        let size = CGSize(width: (area.width + margin * 2) * scale, height: (area.height + margin * 2 + header) * scale)
        let pink = NSColor(red: 0.93, green: 0.2, blue: 0.55, alpha: 1)
        return NSImage(size: size, flipped: true) { _ in
            NSColor(white: 0.97, alpha: 1).setFill()
            NSRect(origin: .zero, size: size).fill()
            // Header.
            let date = DateFormatter.localizedString(from: Date(), dateStyle: .medium, timeStyle: .short)
            (title as NSString).draw(at: CGPoint(x: margin * scale, y: 10 * scale), withAttributes: [
                .font: NSFont.systemFont(ofSize: 15 * scale, weight: .semibold), .foregroundColor: NSColor.black])
            ("MyGit UI Inspector · \(date)" as NSString).draw(at: CGPoint(x: margin * scale, y: 28 * scale), withAttributes: [
                .font: NSFont.systemFont(ofSize: 10 * scale), .foregroundColor: NSColor.gray])
            // Window point → image point.
            func map(_ r: CGRect) -> CGRect {
                CGRect(x: (r.minX - area.minX + margin) * scale, y: (r.minY - area.minY + margin + header) * scale,
                       width: r.width * scale, height: r.height * scale)
            }
            // The screenshot, cropped to the area (the image is the whole window).
            let full = CGRect(x: -area.minX + margin, y: -area.minY + margin + header, width: windowSize.width, height: windowSize.height)
            NSGraphicsContext.saveGraphicsState()
            NSBezierPath(rect: map(area)).setClip()
            screenshot.draw(in: CGRect(x: full.minX * scale, y: full.minY * scale, width: full.width * scale, height: full.height * scale),
                            from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil)
            NSGraphicsContext.restoreGraphicsState()
            NSColor(white: 0, alpha: 0.15).setStroke()
            NSBezierPath(rect: map(area)).stroke()
            // Regions first, then labels on top.
            for (m, _) in measures {
                pink.withAlphaComponent(0.25).setFill()
                NSBezierPath(rect: map(m.rect)).fill()
                pink.setStroke()
                let path = NSBezierPath(rect: map(m.rect)); path.lineWidth = scale; path.stroke()
            }
            var placed: [CGRect] = []
            for (m, token) in measures {
                let text = token.isEmpty ? fmt(m.value) : "\(fmt(m.value)) · \(token)"
                let attributes: [NSAttributedString.Key: Any] = [
                    .font: NSFont.systemFont(ofSize: 9 * scale, weight: .semibold), .foregroundColor: NSColor.white]
                let textSize = (text as NSString).size(withAttributes: attributes)
                let r = map(m.rect)
                var pill = CGRect(x: r.midX - textSize.width / 2 - 4 * scale, y: r.midY - textSize.height / 2 - scale,
                                  width: textSize.width + 8 * scale, height: textSize.height + 2 * scale)
                // Inside the image, and not stacked on each other (nudge down until free).
                pill.origin.x = min(max(2 * scale, pill.minX), size.width - pill.width - 2 * scale)
                while placed.contains(where: { $0.intersects(pill) }) { pill.origin.y += pill.height + 2 * scale }
                placed.append(pill)
                pink.setFill()
                NSBezierPath(roundedRect: pill, xRadius: pill.height / 2, yRadius: pill.height / 2).fill()
                (text as NSString).draw(at: CGPoint(x: pill.minX + 4 * scale, y: pill.minY + scale), withAttributes: attributes)
            }
            return true
        }
    }
}

extension NSImage {
    func pngData() -> Data? {
        guard let tiff = tiffRepresentation, let rep = NSBitmapImageRep(data: tiff) else { return nil }
        return rep.representation(using: .png, properties: [:])
    }
}
