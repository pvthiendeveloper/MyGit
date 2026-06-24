# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Build & Run

SwiftPM executable, macOS 15+, swift-tools-version 6.0 but compiled in Swift 5 language mode.

```bash
swift build              # debug
swift build -c release   # release
./run.sh                 # build + bundle .app + codesign + launch
./run.sh release         # release variant
```

`run.sh` does more than `swift build`. It:
- creates a dedicated keychain `mygit.keychain-db` and a persistent self-signed cert `MyGit Dev` (one-off), so the codesign designated requirement stays constant across rebuilds. Granted system permissions (keychain access, file access prompts) survive because the DR doesn't change.
- assembles `build/MyGit.app` from `Packaging/Info.plist` + `Packaging/MyGit.entitlements`, signs with that cert, kills any running instance, opens the bundle.

Tail logs: `log stream --predicate 'process == "MyGit"' --level debug`.

No tests exist. `Tests/` and `Sources/MyGit/DesignSystem/` are empty placeholders — adding tests requires adding a `.testTarget` to `Package.swift`.

## Architecture

AppKit shell + SwiftUI content. `Sources/MyGit/App/main.swift` boots `NSApplication` with `AppDelegate` (no `@main`/SwiftUI `App`). `AppDelegate.applicationDidFinishLaunching` installs the main menu manually and hosts `MainView` inside an `NSHostingController` in a single `NSWindow`. Menu items (`Add Local Repository`, `Fetch`/`Pull`/`Push`) dispatch into `AppViewModel`.

`AppViewModel` (`@MainActor ObservableObject`) is the hub. Every UI view reads it from `@EnvironmentObject`. It owns:
- `RepositoryStore` — list of local repos, persisted to `UserDefaults` (keys `MyGit.repositoryPaths`, `MyGit.selectedRepositoryPath`). Filters out paths whose `.git` no longer exists on load.
- All git state (`status`, `commits`, `account`, `diff`, `stagedPaths`, `commitSummary`/`Description`) as `@Published`.
- Combine pipelines: switching `repoStore.selected` triggers `repositorySwitched() → refreshAll()`; changing `selectedChange`/`selectedCommit` triggers `loadDiff(...)`.

All git work shells out via `GitRunner.run` / `runOrThrow` (`Sources/MyGit/Git/GitRunner.swift`) to `/usr/bin/git`. Always sets `GIT_TERMINAL_PROMPT=0` and `LC_ALL=C`. `run` returns even on non-zero exit (some commands like `diff --no-index` exit 1 when diffs exist); `runOrThrow` throws on non-zero. The app is **unsandboxed** (`Packaging/MyGit.entitlements`) precisely so it can spawn `git` against user-selected directories.

Parsers live next to runner — `GitStatusParser` (porcelain=v1 -z --branch, handles rename/copy extra NUL record), `GitLogParser`, `GitDiffParser` (parses unified diff, tracks old/new line numbers per hunk), `GitAccountLoader` (parses remote URL into host/owner/repo, detects SCP-vs-URL transport).

### Auth model (important)

Push/pull/fetch must NOT trigger `git-credential-osxkeychain`, because a self-signed app's keychain access prompts every launch. `AppViewModel.authPrefix()` injects:

```
-c credential.helper=                          # disable all helpers
-c http.extraheader=AUTHORIZATION: bearer <PAT>
```

before any remote subcommand when an HTTPS remote + stored PAT exist. PATs are stored by host in MyGit's own keychain via `CredentialStore` (service `com.thienpham.MyGit`, `kSecClassGenericPassword`, `kSecAttrAccessibleAfterFirstUnlock`) — independent of the system `osxkeychain` helper. Sign-in/out flows in the UI manipulate that store, keyed by `account?.host`.

### Staging model

Mirrors GitHub Desktop: `stagedPaths` is a `Set<String>` of paths the user has checked. On `commit()`, the index is reset (`git reset --mixed -q`), then only checked paths are `git add`-ed, then `git commit -m`. Status refresh defaults newly-appeared paths to checked while preserving explicit unchecks (`previousPaths` diff).

## Conventions

- Concurrency: all UI state on `@MainActor`. `GitRunner.run` hops to `DispatchQueue.global(qos: .userInitiated)` and bridges via `withCheckedThrowingContinuation`.
- `Package.swift` pins `.swiftLanguageMode(.v5)` despite swift-tools-version 6.0 — keep new code Swift-5-compatible (no strict concurrency by default).
- Links AppKit + SwiftUI + UniformTypeIdentifiers via `linkerSettings`, no other deps.
- Bundle ID `com.thienpham.MyGit`, min macOS 15.
