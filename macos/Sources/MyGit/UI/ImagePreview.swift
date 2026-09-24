import SwiftUI
import AppKit

/// Read-only viewer for image files: fits the available space, never upscales
/// past actual size, pixel dimensions in the corner.
struct ImagePreview: View {
    let image: NSImage

    /// Extensions opened as images in the diff viewer (AppKit can decode these).
    static let extensions: Set<String> = [
        "png", "jpg", "jpeg", "gif", "tif", "tiff", "bmp", "heic", "heif",
        "webp", "ico", "icns",
    ]

    static func isImage(path: String) -> Bool {
        extensions.contains((path as NSString).pathExtension.lowercased())
    }

    private var pixelSize: CGSize {
        if let rep = image.representations.first, rep.pixelsWide > 0 {
            return CGSize(width: rep.pixelsWide, height: rep.pixelsHigh)
        }
        return image.size
    }

    var body: some View {
        GeometryReader { geo in
            let size = image.size
            let scale = min(1, min(geo.size.width / max(size.width, 1),
                                   geo.size.height / max(size.height, 1)))
            Image(nsImage: image)
                .resizable()
                .interpolation(.high)
                .frame(width: size.width * scale, height: size.height * scale)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .padding(16)
        .overlay(alignment: .bottomTrailing) {
            Text("\(Int(pixelSize.width)) × \(Int(pixelSize.height))")
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
                .padding(8)
        }
    }
}
