import AppKit

MainActor.assumeIsolated {
    // Instantiate NSApplication *first*. Touching `.shared` performs the
    // LaunchServices registration that `open` waits on — if the process does
    // slow work before that (AppDelegate builds the whole AppCoordinator, which
    // scans every saved workspace), LS times out after ~10s and aborts inside
    // _RegisterApplication with SIGABRT.
    let app = NSApplication.shared
    app.setActivationPolicy(.regular)
    app.delegate = AppDelegate()
    app.run()
}
