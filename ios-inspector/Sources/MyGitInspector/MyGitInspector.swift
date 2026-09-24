import UIKit

/// Debug-only agent for MyGit's UI Inspector.
///
/// Call `MyGitInspector.start()` once at launch (inside `#if DEBUG`). The app
/// then advertises itself over Bonjour (`_mygitinspect._tcp`) and answers
/// MyGit's requests for its view hierarchy — UIKit views, the SwiftUI views
/// inside every hosting view, and a screenshot of each window.
///
/// Nothing runs until `start()` is called, and nothing is ever sent unless
/// MyGit asks. On a physical device, add to the app's Info.plist:
/// `NSBonjourServices` = [`_mygitinspect._tcp`] and an
/// `NSLocalNetworkUsageDescription`.
public enum MyGitInspector {
    public static let serviceType = "_mygitinspect._tcp"
    /// Bumped when the wire format changes incompatibly.
    /// 2: flat node list with `parent` ids instead of nested `children`.
    public static let protocolVersion = 2

    private static var server: InspectorServer?

    /// Start advertising. Safe to call more than once.
    /// - Parameter name: How the app is listed in MyGit; defaults to
    ///   "<app name> — <device name>".
    public static func start(name: String? = nil) {
        // SwiftUI only records view debug data when this is set before its
        // view graphs exist — so call `start()` as early as possible (App.init
        // / didFinishLaunching). The value is a `_ViewDebug.Properties` mask:
        // type 1 | value 2 | transform 4 | position 8 | size 16. Transform
        // carries scroll offsets (positions inside a ScrollView are in content
        // space). Environment (32) is left out: it's megabytes per hosting
        // view and the inspector ignores it.
        setenv("SWIFTUI_VIEW_DEBUG", "31", 0)
        DispatchQueue.main.async {
            guard server == nil else { return }
            let server = InspectorServer(serviceName: name ?? defaultName)
            server.start()
            self.server = server
        }
    }

    public static func stop() {
        DispatchQueue.main.async {
            server?.stop()
            server = nil
        }
    }

    private static var defaultName: String {
        let app = Bundle.main.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String
            ?? Bundle.main.object(forInfoDictionaryKey: "CFBundleName") as? String
            ?? ProcessInfo.processInfo.processName
        #if targetEnvironment(simulator)
        let device = ProcessInfo.processInfo.environment["SIMULATOR_DEVICE_NAME"] ?? UIDevice.current.name
        #else
        let device = UIDevice.current.name
        #endif
        return "\(app) — \(device)"
    }
}
