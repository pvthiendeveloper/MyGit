import AppKit
import SwiftUI
import WebKit

/// Standalone window that previews an image file changed in a PR (before/after).
/// Raster files render as `NSImage`; Android VectorDrawable `.xml` files are
/// converted to SVG and shown in a WebView. Bytes are fetched via a host-auth
/// closure supplied by the caller.
@MainActor
final class ImagePreviewWindow: NSObject, NSWindowDelegate {
    private static var windows: [ImagePreviewWindow] = []
    private var window: NSWindow?

    static func open(file: PRFileChange, fetch: @escaping (URL) async -> Data?) {
        let instance = ImagePreviewWindow()
        let hosting = NSHostingController(rootView: ImagePreviewView(file: file, fetch: fetch))
        let win = NSWindow(contentViewController: hosting)
        win.title = (file.path as NSString).lastPathComponent
        win.styleMask = [.titled, .closable, .resizable]
        win.delegate = instance
        win.setContentSize(NSSize(width: 900, height: 600))
        win.center()
        win.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        instance.window = win
        windows.append(instance)
    }

    func windowWillClose(_ notification: Notification) {
        ImagePreviewWindow.windows.removeAll { $0 === self }
        window = nil
    }
}

struct ImagePreviewView: View {
    let file: PRFileChange
    let fetch: (URL) async -> Data?

    private struct Side { var image: NSImage?; var svg: String? }

    @State private var old = Side()
    @State private var new = Side()
    @State private var loading = true

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Text(file.statusLabel)
                    .font(.system(size: 11, weight: .bold))
                    .foregroundStyle(file.statusColor)
                Text(file.path)
                    .font(.system(size: 12, design: .monospaced))
                    .lineLimit(1).truncationMode(.middle)
                Spacer()
            }
            .padding(10)
            Divider()
            if loading {
                ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                HStack(spacing: 0) {
                    sideView("Before", old, expected: file.oldBlobURL != nil)
                    Divider()
                    sideView("After", new, expected: file.newBlobURL != nil)
                }
            }
        }
        .task { await load() }
    }

    @ViewBuilder
    private func sideView(_ label: String, _ side: Side, expected: Bool) -> some View {
        VStack(spacing: 8) {
            Text(label).font(.system(size: 11, weight: .semibold)).foregroundStyle(.secondary)
            if let image = side.image {
                Image(nsImage: image)
                    .resizable().interpolation(.high).scaledToFit()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(Checkerboard())
                Text("\(Int(image.size.width)) × \(Int(image.size.height))")
                    .font(.system(size: 10)).foregroundStyle(.secondary)
            } else if let svg = side.svg {
                SVGWebView(svg: svg).frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                Text(expected ? "Can't preview (unsupported or unresolved)" : "—")
                    .font(.system(size: 12)).foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func load() async {
        old = await render(file.oldBlobURL)
        new = await render(file.newBlobURL)
        loading = false
    }

    private func render(_ url: URL?) async -> Side {
        guard let url, let data = await fetch(url) else { return Side() }
        if file.isImage { return Side(image: NSImage(data: data)) }
        if let xml = String(data: data, encoding: .utf8),
           let svg = AndroidVectorDrawable.toSVG(xml) {
            return Side(svg: svg)
        }
        return Side()
    }
}

/// Renders an inline SVG string in a transparent WebView.
struct SVGWebView: NSViewRepresentable {
    let svg: String

    func makeNSView(context: Context) -> WKWebView {
        let view = WKWebView()
        view.setValue(false, forKey: "drawsBackground")
        return view
    }

    func updateNSView(_ view: WKWebView, context: Context) {
        // Checkerboard backdrop so icons of any color (incl. black/white) show.
        let html = """
        <html><head><meta name="viewport" content="width=device-width, initial-scale=1"></head>
        <body style="margin:0;height:100vh;display:flex;align-items:center;justify-content:center;
        background-color:#9a9a9a;
        background-image:linear-gradient(45deg,#8a8a8a 25%,transparent 25%),linear-gradient(-45deg,#8a8a8a 25%,transparent 25%),linear-gradient(45deg,transparent 75%,#8a8a8a 75%),linear-gradient(-45deg,transparent 75%,#8a8a8a 75%);
        background-size:16px 16px;background-position:0 0,0 8px,8px -8px,-8px 0;">
        <div style="width:80%;height:80%;display:flex;align-items:center;justify-content:center;">\(svg)</div>
        </body></html>
        """
        view.loadHTMLString(html, baseURL: nil)
    }
}

/// Light checkerboard used behind previewed images to reveal transparency.
struct Checkerboard: View {
    var body: some View {
        Canvas { ctx, size in
            let s: CGFloat = 8
            // Mid-gray so both light and dark (even white) images stay visible.
            ctx.fill(Path(CGRect(origin: .zero, size: size)), with: .color(Color(white: 0.60)))
            for row in 0..<Int(size.height / s + 1) {
                for col in 0..<Int(size.width / s + 1) where (row + col) % 2 == 0 {
                    ctx.fill(Path(CGRect(x: CGFloat(col) * s, y: CGFloat(row) * s, width: s, height: s)),
                             with: .color(Color(white: 0.54)))
                }
            }
        }
    }
}
