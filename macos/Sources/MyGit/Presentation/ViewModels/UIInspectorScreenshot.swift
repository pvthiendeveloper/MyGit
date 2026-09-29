import AppKit
import SwiftUI

/// Screenshot of the preview as it is: the app's screen with the inspector's marks — wireframes, selection, token
/// matches, measures, the Figma overlay — or without them; or the 3D view.
/// Copied to the clipboard; `save` then asks where to write the PNG.
extension UIInspectorViewModel {
    /// `selectedOnly` crops to the selected view; `marks` false = the bare screen.
    func exportScreenshot(selectedOnly: Bool, marks: Bool = true, save: Bool) {
        Task { @MainActor [weak self] in
            guard let self else { return }
            // Interacting, the preview shows a 2× compressed stream: fetch the
            // screen as it is now, sharp, so every shot has the device's size.
            let sharp = interactMode && !show3D ? await sharpFrame(scale: Double(nativeScale)) : nil
            guard let image = screenshotImage(area: selectedOnly ? selectedNode?.frame : nil, marks: marks,
                                              screen: sharp) else { return }
            NSPasteboard.general.clearContents()
            NSPasteboard.general.writeObjects([image])
            guard save, let data = image.pngData() else { return }
            let panel = NSSavePanel()
            panel.allowedContentTypes = [.png]
            let name = [snapshot?.info?.appName, selectedOnly ? selectedNode?.shortName : nil]
                .compactMap { $0 }.joined(separator: " ")
            panel.nameFieldStringValue = "\(name.isEmpty ? "Screenshot" : name) \(Self.fileDate()).png"
            if panel.runModal() == .OK, let url = panel.url { try? data.write(to: url) }
        }
    }

    /// Device pixels per point, from the capture (taken at the screen's scale).
    var nativeScale: CGFloat {
        guard let window = currentWindow, let cg = window.image?.cgImage(forProposedRect: nil, context: nil, hints: nil),
              window.size.width > 0 else { return 3 }
        return (CGFloat(cg.width) / window.size.width).rounded()
    }

    /// `area` in window points; nil = the whole screen. Always at the device's
    /// pixel size, whatever `screen` (default: what the preview shows) is.
    func screenshotImage(area: CGRect?, marks: Bool, screen: NSImage? = nil) -> NSImage? {
        guard let window = currentWindow else { return nil }
        if show3D { return render3D(window) }
        guard let screen = screen ?? (interactMode ? liveFrame : nil) ?? window.image else { return nil }
        let px = nativeScale
        // The screen (plus, with marks, the preview's own layers) at 1 pt per
        // app point, rendered at the device's density.
        let content = marks
            ? AnyView(InspectorCanvasLayers(window: window, scale: 1, image: screen).environmentObject(self))
            : AnyView(Image(nsImage: screen).resizable().interpolation(.high)
                .frame(width: window.size.width, height: window.size.height))
        let renderer = ImageRenderer(content: content)
        renderer.scale = px
        guard let cg = renderer.cgImage else { return nil }
        let bounds = CGRect(origin: .zero, size: window.size)
        guard let area = area?.intersection(bounds), !area.isEmpty, area != bounds else {
            return NSImage(cgImage: cg, size: window.size)
        }
        let crop = CGRect(x: area.minX * px, y: area.minY * px, width: area.width * px, height: area.height * px).integral
        guard let cropped = cg.cropping(to: crop) else { return nil }
        return NSImage(cgImage: cropped, size: area.size)
    }

    private func render3D(_ window: InspectorWindow) -> NSImage? {
        let size = CGSize(width: 1200, height: 900)
        let scale = min(size.width / window.size.width, size.height / window.size.height) * 0.6
        let renderer = ImageRenderer(content: Inspector3DCanvas(window: window, scale: scale)
            .environmentObject(self).frame(width: size.width, height: size.height)
            .background(Color(NSColor.underPageBackgroundColor)))
        renderer.scale = 2
        return renderer.nsImage
    }
}
