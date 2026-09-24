# MyGitInspector

Debug-only agent that lets MyGit's **UI Inspector** (View ▸ UI Inspector, ⌥⌘I)
show a running iOS app's view hierarchy — UIKit views, the SwiftUI views inside
each hosting view (same type names as Xcode's view debugger), and a screenshot
you can click to select views.

## Add it to an app

1. Add this folder as a local Swift package (Xcode ▸ File ▸ Add Package
   Dependencies… ▸ Add Local…) and link `MyGitInspector` to the app target.
2. Start it **as early as possible** — SwiftUI only records the debug data the
   inspector reads for view graphs created after `start()`:

   ```swift
   #if DEBUG
   import MyGitInspector
   #endif

   @main
   struct ExampleApp: App {
       init() {
           #if DEBUG
           MyGitInspector.start()
           #endif
       }
       var body: some Scene { WindowGroup { ContentView() } }
   }
   ```

   UIKit apps: call it first thing in `application(_:didFinishLaunchingWithOptions:)`.
3. Run the app, open MyGit ▸ View ▸ UI Inspector and pick it from the app menu.

**Simulator:** nothing else needed.
**Physical device** (same Wi-Fi as the Mac): add to the app's Info.plist

```xml
<key>NSBonjourServices</key>
<array><string>_mygitinspect._tcp</string></array>
<key>NSLocalNetworkUsageDescription</key>
<string>Lets MyGit inspect this debug build's UI.</string>
```

## How it works

- `start()` sets `SWIFTUI_VIEW_DEBUG=27` (type | value | position | size) so
  SwiftUI records view debug data, then opens a TCP listener advertised over
  Bonjour as `_mygitinspect._tcp` ("<app> — <device>").
- Requests/responses are 4-byte big-endian length + JSON. Methods: `info`,
  `hierarchy` (tree + base64 PNG per window), `highlight` (outline a frame on
  the device).
- SwiftUI nodes come from `_UIHostingView._viewDebugData()` serialized with
  `_ViewDebug.serializedData` — underscored SPI, the same data Xcode uses. It
  may change between iOS releases; the agent reads the JSON defensively and
  never lets a capture crash the app.

Nothing is sent unless MyGit asks. Keep the call inside `#if DEBUG`.
