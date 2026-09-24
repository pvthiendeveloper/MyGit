import SwiftUI
import AppKit

extension View {
    /// Lets a plain mouse wheel (vertical-only) scroll the enclosing horizontal
    /// `ScrollView`. Apply to the scroll view's *content*. SwiftUI only honours
    /// horizontal deltas there, so tab strips were unreachable without a trackpad.
    func wheelScrollsHorizontally() -> some View {
        background(HorizontalWheelScroll())
    }
}

private struct HorizontalWheelScroll: NSViewRepresentable {
    func makeNSView(context: Context) -> WheelView { WheelView() }
    func updateNSView(_ view: WheelView, context: Context) {}

    final class WheelView: NSView {
        private var monitor: Any?

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            if let monitor { NSEvent.removeMonitor(monitor) }
            monitor = nil
            guard window != nil else { return }
            monitor = NSEvent.addLocalMonitorForEvents(matching: .scrollWheel) { [weak self] event in
                self?.handle(event) == true ? nil : event
            }
        }

        deinit {
            if let monitor { NSEvent.removeMonitor(monitor) }
        }

        /// Returns true when the event was consumed as a horizontal scroll.
        private func handle(_ event: NSEvent) -> Bool {
            guard event.window === window,
                  let scroll = enclosingScrollView,
                  abs(event.scrollingDeltaY) > abs(event.scrollingDeltaX) else { return false }
            let point = scroll.convert(event.locationInWindow, from: nil)
            guard scroll.bounds.contains(point) else { return false }

            let clip = scroll.contentView
            let docWidth = scroll.documentView?.frame.width ?? 0
            let maxX = max(0, docWidth - clip.bounds.width)
            guard maxX > 0 else { return false }

            // Wheel notches report line deltas; trackpads report points.
            let delta = event.scrollingDeltaY * (event.hasPreciseScrollingDeltas ? 1 : 12)
            let x = min(max(clip.bounds.origin.x - delta, 0), maxX)
            clip.scroll(to: NSPoint(x: x, y: clip.bounds.origin.y))
            scroll.reflectScrolledClipView(clip)
            return true
        }
    }
}
