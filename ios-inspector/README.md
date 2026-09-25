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

## Run with Inspector (exact source lines)

SwiftUI's debug data has no source locations, so by default the inspector can
only guess code from text and type names. The **App with Inspector** run
configuration (Run bar ▸ configurations, then ▶; or Run with Inspector in the
UI Inspector window) builds
a copy of the repo in which every SwiftUI view expression carries its
`file:line:column`; then any view opens its exact line, with the enclosing
views as a clickable stack.

```
<repo>/.mygit/inspect/src          mirror (rsync for non-Swift, tagger for Swift)
<repo>/.mygit/inspect/DerivedData  its own build output
<repo>/.mygit/inspect/build.log    last xcodebuild log
```

- `Tools/SourceTagger` (`mygit-source-tagger`, SwiftSyntax) appends
  `.preference(key: __MyGitSourceKey.self, value: "path:line:col")` to each
  view expression inside view-builder contexts, on the expression's own last
  line — line numbers never move — and declares the file-private key at the
  end of the file. `.preference` is one of the few modifiers SwiftUI keeps in
  its debug data (custom `ViewModifier`s and `.environment` vanish), and
  nothing reads the key, so the app behaves the same.
- It is incremental and parallel: a manifest skips unchanged files on
  size+mtime, then on a content hash; only changed files are parsed; output
  is written only when it differs (Xcode's incremental build survives); files
  are spread over all cores. Pods/Carthage/SourcePackages are copied untagged.
  On the CDS repo: 320 files / 514 tags in 0.2s cold, 0.1s warm; a no-change
  run with Xcode's incremental build takes ~3s end to end.
- `Tools/mygit-inspect-run.sh` mirrors, tags, builds with `xcodebuild`, and
  installs/launches like a normal run. If the compiler rejects a tag (an API
  the tagger misread), those files are mirrored untagged and the build retried.
- Debug-only modifiers are removed from the mirror so their overlays don't
  clutter the inspected tree: `.debugLayoutBounds(…)` by default, or any
  space-separated names in `MYGIT_INSPECT_STRIP_MODIFIERS` (empty = none).
  The removed span keeps its line breaks, so every tag and index position
  still matches the original file.
- Getters and functions with several `return`s (design-token providers:
  `var message: String? { if … return a … return b }`) get a **branch
  probe**: `return X` becomes `return __mB(X)`, `return` moving left into
  the indentation so `X` keeps its line *and column* (the compiler's index is
  looked up there). `__mB` (file-private, appended to the file) passes the
  value through and records its description under `"path:line"` in the main
  thread's dictionary; the agent sends that map with each `hierarchy`, and
  the inspector shows the branch that actually produced a value instead of
  "one of". Views, `some`/`@…Builder` bodies, `try`/`await` returns and
  returns without room (`{ return x }`, `case .a: return x`) are left alone —
  the inspector only trusts a report when every candidate was probed.
- The repo is never modified; `.mygit/` is added to `.git/info/exclude`.

MyGit's `run.sh` builds the tagger and ships both tools inside MyGit.app.
Tagger tests: `swift test --package-path Tools/SourceTagger`.

## How it works

- `start()` sets `SWIFTUI_VIEW_DEBUG=31` (type | value | transform | position
  | size) so SwiftUI records view debug data, then opens a TCP listener
  advertised over Bonjour as `_mygitinspect._tcp` ("<app> — <device>").
- Requests/responses are 4-byte big-endian length + JSON. Methods: `info`,
  `hierarchy` (per window: a flat pre-order node list with `parent` ids — real
  trees nest hundreds deep — plus a base64 PNG; and `branches`, what the
  branch probes recorded), `highlight` (outline a frame on the device).
- SwiftUI positions inside a ScrollView are in content space; the agent adds
  the node's `transform` translations (absolute, not cumulative) to place them.
- SwiftUI nodes come from `_UIHostingView._viewDebugData()` serialized with
  `_ViewDebug.serializedData` — underscored SPI, the same data Xcode uses. It
  may change between iOS releases; the agent reads the JSON defensively and
  never lets a capture crash the app.

Nothing is sent unless MyGit asks. Keep the call inside `#if DEBUG`.
