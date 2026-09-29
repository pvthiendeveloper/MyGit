import UIKit

/// Drives the app from MyGit's UI Inspector: taps, drags, long presses,
/// typing, scrolling, going back.
///
/// Touches are real touches: a `UITouch` carrying a synthesized digitizer
/// `IOHIDEvent`, sent through `UIApplication.sendEvent` — the technique UI
/// test libraries such as KIF use. So SwiftUI buttons, lists, custom
/// gestures and scroll views react exactly as to a finger. It leans on
/// private UIKit/IOKit API, which is fine for a debug-only agent; every
/// private call is looked up at run time and skipped if missing, so a
/// future iOS can make a command fail, never crash the app.
///
/// Main thread only. Points are window coordinates, as in the hierarchy.
enum InteractionDriver {
    enum Failure: LocalizedError {
        case noWindow
        case unsupported(String)
        case noTarget(String)

        var errorDescription: String? {
            switch self {
            case .noWindow: return "No window at that index."
            case let .unsupported(what): return "This iOS version doesn't support \(what) from the inspector."
            case let .noTarget(what): return what
            }
        }
    }

    // MARK: - Touches

    /// Finger down at `path[0]`, through the rest of `path`, up at the end;
    /// `holdBefore`/`step` in seconds. `done` gets nil or the error.
    static func touch(path: [CGPoint], window index: Int, holdBefore: TimeInterval = 0.05,
                      step: TimeInterval = 0.016, done: @escaping (Error?) -> Void) {
        guard let window = window(at: index) else { return done(Failure.noWindow) }
        guard let first = path.first, HID.canEnqueue else { return done(Failure.unsupported("synthesized touches")) }
        // UIKit's digitizer events are in screen points.
        let screen = path.map { window.convert($0, to: nil) }
        HID.enqueue(at: window.convert(first, to: nil), phase: .began, window: window)
        var remaining = Array(screen.dropFirst())
        var last = screen[0]
        func next() {
            guard !remaining.isEmpty else {
                HID.enqueue(at: last, phase: .ended, window: window)
                // Let the gesture finish before the caller looks.
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { done(nil) }
                return
            }
            last = remaining.removeFirst()
            HID.enqueue(at: last, phase: .moved, window: window)
            DispatchQueue.main.asyncAfter(deadline: .now() + step, execute: next)
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + holdBefore, execute: next)
    }

    /// A tap: a real touch. Where touches can't be synthesized (a future
    /// iOS), the accessibility element under the point is activated instead —
    /// what VoiceOver's double-tap does, public API.
    static func tap(_ point: CGPoint, window index: Int, done: @escaping (Error?) -> Void) {
        if HID.canEnqueue { return touch(path: [point], window: index, holdBefore: 0.05, done: done) }
        // SwiftUI builds its accessibility tree only for an accessibility
        // client; the first time, turn automation on (as XCTest does) and let
        // it build before looking.
        if Automation.enable() {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { tap(point, window: index, done: done) }
            return
        }
        guard let window = window(at: index) else { return done(Failure.noWindow) }
        guard let element = accessibilityElement(at: point, in: window), element.accessibilityActivate() else {
            return done(Failure.unsupported("taps"))
        }
        done(nil)
    }

    // MARK: - Accessibility

    /// The smallest accessibility element whose frame holds the point.
    static func accessibilityElement(at point: CGPoint, in window: UIWindow) -> NSObject? {
        let screenPoint = window.convert(point, to: nil)
        var best: (element: NSObject, area: CGFloat)?
        func visit(_ object: NSObject, depth: Int) {
            guard depth < 60 else { return }
            if object.isAccessibilityElement {
                let frame = object.accessibilityFrame
                if frame.contains(screenPoint), frame.width * frame.height < (best?.area ?? .infinity) {
                    best = (object, frame.width * frame.height)
                }
            }
            if let elements = object.accessibilityElements as? [NSObject] {
                elements.forEach { visit($0, depth: depth + 1) }
            } else if let view = object as? UIView {
                view.subviews.forEach { visit($0, depth: depth + 1) }
            } else {
                let count = object.accessibilityElementCount()
                if count != NSNotFound, count > 0 {
                    for i in 0..<min(count, 500) {
                        if let child = object.accessibilityElement(at: i) as? NSObject { visit(child, depth: depth + 1) }
                    }
                }
            }
        }
        visit(window, depth: 0)
        return best?.element
    }

    static func longPress(_ point: CGPoint, duration: TimeInterval, window: Int, done: @escaping (Error?) -> Void) {
        touch(path: [point], window: window, holdBefore: max(0.5, duration), done: done)
    }

    /// A straight drag, eased, over `duration` seconds (60 steps a second).
    static func drag(from a: CGPoint, to b: CGPoint, duration: TimeInterval, window: Int,
                     done: @escaping (Error?) -> Void) {
        let steps = max(2, Int(duration * 60))
        let path = (0...steps).map { i -> CGPoint in
            let t = Double(i) / Double(steps)
            let eased = t * t * (3 - 2 * t)
            return CGPoint(x: a.x + (b.x - a.x) * eased, y: a.y + (b.y - a.y) * eased)
        }
        touch(path: path, window: window, holdBefore: 0.02, done: done)
    }

    // MARK: - Keyboard

    /// Types into the focused text input; `\n` is Return, `\u{8}` Backspace.
    static func type(_ text: String) throws {
        guard let input = firstResponder() as? UIKeyInput else {
            throw Failure.noTarget("Nothing has keyboard focus — tap a text field first.")
        }
        for character in text {
            if character == "\u{8}" { input.deleteBackward() } else { input.insertText(String(character)) }
        }
    }

    // MARK: - Scrolling & navigation

    /// Scrolls the scroll view under `point` by (dx, dy) points, clamped.
    static func scroll(at point: CGPoint, by delta: CGVector, window index: Int) throws {
        guard let window = window(at: index) else { throw Failure.noWindow }
        var view = window.hitTest(point, with: nil)
        while let v = view, !(v is UIScrollView && ((v as! UIScrollView).isScrollEnabled)) { view = v.superview }
        guard let scrollView = view as? UIScrollView else { throw Failure.noTarget("Nothing scrolls there.") }
        let inset = scrollView.adjustedContentInset
        let maxX = max(-inset.left, scrollView.contentSize.width - scrollView.bounds.width + inset.right)
        let maxY = max(-inset.top, scrollView.contentSize.height - scrollView.bounds.height + inset.bottom)
        let target = CGPoint(x: min(max(scrollView.contentOffset.x + delta.dx, -inset.left), maxX),
                             y: min(max(scrollView.contentOffset.y + delta.dy, -inset.top), maxY))
        scrollView.setContentOffset(target, animated: false)
    }

    /// Pops the top navigation stack of the window (SwiftUI's too — it's a
    /// `UINavigationController` underneath), or dismisses a presented sheet.
    static func back(window index: Int) throws {
        guard let window = window(at: index), let root = window.rootViewController else { throw Failure.noWindow }
        var top = root
        while let presented = top.presentedViewController { top = presented }
        if let nav = deepestNavigation(in: top), nav.viewControllers.count > 1 {
            nav.popViewController(animated: true)
        } else if top !== root {
            top.dismiss(animated: true)
        } else {
            throw Failure.noTarget("Nothing to go back from.")
        }
    }

    private static func deepestNavigation(in controller: UIViewController) -> UINavigationController? {
        var found = controller as? UINavigationController
        for child in controller.children {
            if let deeper = deepestNavigation(in: child), deeper.viewControllers.count > 1 || found == nil { found = deeper }
        }
        return found
    }

    // MARK: - Helpers

    static func window(at index: Int) -> UIWindow? {
        let windows = HierarchyCapture.allWindows()
        return windows.indices.contains(index) ? windows[index] : nil
    }

    /// The current first responder: whoever answers an action sent to nil.
    private static func firstResponder() -> UIResponder? {
        FirstResponderProbe.found = nil
        UIApplication.shared.sendAction(#selector(UIResponder.mygitInspectorFindFirstResponder), to: nil, from: nil, for: nil)
        return FirstResponderProbe.found
    }
}

private enum FirstResponderProbe {
    static weak var found: UIResponder?
}

extension UIResponder {
    @objc fileprivate func mygitInspectorFindFirstResponder() { FirstResponderProbe.found = self }
}

/// IOKit's digitizer events, looked up with `dlsym` (the functions are
/// exported but not in the public SDK headers).
private enum HID {
    private typealias CreateDigitizer = @convention(c) (
        CFAllocator?, UInt64, UInt32, UInt32, UInt32, UInt32, UInt32,
        Double, Double, Double, Double, Double, Bool, Bool, UInt32
    ) -> Unmanaged<CFTypeRef>?
    private typealias CreateFinger = @convention(c) (
        CFAllocator?, UInt64, UInt32, UInt32, UInt32,
        Double, Double, Double, Double, Double, Double, Double, Double, Double, Double,
        Bool, Bool, UInt32
    ) -> Unmanaged<CFTypeRef>?
    private typealias SetInteger = @convention(c) (CFTypeRef, UInt32, Int) -> Void
    private typealias Append = @convention(c) (CFTypeRef, CFTypeRef, UInt32) -> Void

    private typealias SetSender = @convention(c) (CFTypeRef, UInt64) -> Void
    private typealias SetDigitizerInfo = @convention(c) (CFTypeRef, UInt32, UInt8, UInt8, CFString?, Double, Float) -> Void
    private static let setDigitizerInfo: SetDigitizerInfo? = {
        guard let handle = dlopen("/System/Library/PrivateFrameworks/BackBoardServices.framework/BackBoardServices", RTLD_NOW),
              let pointer = dlsym(handle, "BKSHIDEventSetDigitizerInfo") else { return nil }
        return unsafeBitCast(pointer, to: SetDigitizerInfo.self)
    }()

    /// `UIWindow._contextId`: the render context UIKit routes digitizer events by.
    private static func contextID(of window: UIWindow) -> UInt32? {
        let selector = NSSelectorFromString("_contextId")
        guard window.responds(to: selector) else { return nil }
        typealias Getter = @convention(c) (NSObject, Selector) -> UInt32
        return unsafeBitCast(window.method(for: selector), to: Getter.self)(window, selector)
    }

    private static let handle = dlopen("/System/Library/Frameworks/IOKit.framework/IOKit", RTLD_NOW)
    private static func symbol<T>(_ name: String, as: T.Type) -> T? {
        guard let handle, let pointer = dlsym(handle, name) else { return nil }
        return unsafeBitCast(pointer, to: T.self)
    }
    private static let createDigitizer = symbol("IOHIDEventCreateDigitizerEvent", as: CreateDigitizer.self)
    private static let createFinger = symbol("IOHIDEventCreateDigitizerFingerEventWithQuality", as: CreateFinger.self)
    private static let setInteger = symbol("IOHIDEventSetIntegerValue", as: SetInteger.self)
    private static let append = symbol("IOHIDEventAppendEvent", as: Append.self)
    private static let setSender = symbol("IOHIDEventSetSenderID", as: SetSender.self)
    /// UIKit drops digitizer events without a sender.
    private static let senderID: UInt64 = 0x0000_0001_2345_6789
    private static let enqueueSelector = NSSelectorFromString("_enqueueHIDEvent:")

    static var canEnqueue: Bool {
        createDigitizer != nil && createFinger != nil && setInteger != nil && append != nil && setSender != nil
            && UIApplication.shared.responds(to: enqueueSelector)
    }

    /// One finger at a screen point, handed to UIKit's event queue, which
    /// turns it into touches like a real finger.
    static func enqueue(at point: CGPoint, phase: UITouch.Phase, window: UIWindow) {
        guard let event = event(for: [(point, phase)]), let setSender else { return }
        setSender(event.takeUnretainedValue(), senderID)
        // Which window's context the finger is in; without it UIKit drops the event.
        if let setDigitizerInfo, let contextID = contextID(of: window) {
            setDigitizerInfo(event.takeUnretainedValue(), contextID, 0, 0, nil, 0, 0)
        }
        let app = UIApplication.shared
        typealias Enqueue = @convention(c) (NSObject, Selector, CFTypeRef) -> Void
        unsafeBitCast(app.method(for: enqueueSelector), to: Enqueue.self)(app, enqueueSelector, event.takeUnretainedValue())
        event.release()
    }

    private static let transducerHand: UInt32 = 3
    private static let eventRange: UInt32 = 1 << 0
    private static let eventTouch: UInt32 = 1 << 1
    private static let eventPosition: UInt32 = 1 << 2
    /// `kIOHIDEventFieldDigitizerIsDisplayIntegrated`: (digitizer type 11 << 16) | 25.
    private static let fieldIsDisplayIntegrated: UInt32 = 0xB0019

    /// A hand event holding one finger per touch. Caller releases it.
    static func event(for touches: [(CGPoint, UITouch.Phase)]) -> Unmanaged<CFTypeRef>? {
        guard let createDigitizer, let createFinger, let setInteger, let append else { return nil }
        let time = mach_absolute_time()
        let touchingAny = touches.contains { $0.1 != .ended && $0.1 != .cancelled }
        let handMask = touches.contains { $0.1 == .moved } ? eventPosition : (eventRange | eventTouch)
        guard let hand = createDigitizer(kCFAllocatorDefault, time, transducerHand, 0, 0, handMask, 0,
                                         0, 0, 0, 0, 0, touchingAny, touchingAny, 0) else { return nil }
        setInteger(hand.takeUnretainedValue(), fieldIsDisplayIntegrated, 1)
        for (i, (point, phase)) in touches.enumerated() {
            let mask = phase == .moved ? eventPosition : (eventRange | eventTouch)
            let touching = phase != .ended && phase != .cancelled
            guard let finger = createFinger(kCFAllocatorDefault, time, UInt32(i + 1), 2, mask,
                                            Double(point.x), Double(point.y), 0, 0, 0, 5, 5, 1, 1, 1,
                                            touching, touching, 0) else { continue }
            setInteger(finger.takeUnretainedValue(), fieldIsDisplayIntegrated, 1)
            append(hand.takeUnretainedValue(), finger.takeUnretainedValue(), 0)
            finger.release()
        }
        return hand
    }
}

/// Accessibility automation (`_AXSSetAutomationEnabled`, what XCTest turns
/// on): makes SwiftUI publish its accessibility elements.
private enum Automation {
    private static var enabled = false

    /// True the first time, when it was just switched on.
    static func enable() -> Bool {
        guard !enabled else { return false }
        enabled = true
        typealias SetEnabled = @convention(c) (Bool) -> Void
        guard let handle = dlopen("/usr/lib/libAccessibility.dylib", RTLD_NOW),
              let symbol = dlsym(handle, "_AXSSetAutomationEnabled") else { return false }
        unsafeBitCast(symbol, to: SetEnabled.self)(true)
        return true
    }
}
