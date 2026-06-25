# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Repository layout

Single project: `macos/` holds a SwiftPM macOS app (MyGit — a GitHub Desktop-style git client). Root is otherwise empty. All source, build, and packaging live under `macos/`.

**Detailed guidance lives in `macos/CLAUDE.md`** — read it before editing Swift code. Architecture, auth model, staging model, and conventions are documented there. Do not duplicate that content here.

## Common commands (run from `macos/`)

```bash
swift build              # debug
swift build -c release   # release
./run.sh                 # build, bundle .app, codesign with persistent local cert, launch
./run.sh release         # same, release config
log stream --predicate 'process == "MyGit"' --level debug
```

`run.sh` is preferred over raw `swift build` for running — it preserves a stable codesign designated requirement (via persistent `MyGit Dev` cert in `mygit.keychain-db`) so granted system permissions survive rebuilds.

No tests. `Tests/` and `Sources/MyGit/DesignSystem/` are empty placeholders. Adding tests requires a `.testTarget` in `Package.swift`.

## Big picture

- AppKit shell + SwiftUI content. `App/main.swift` boots `NSApplication` manually (no `@main`); `AppDelegate` installs the menu and hosts `MainView` in an `NSHostingController`.
- Clean Architecture layers under `Sources/MyGit/`: `Domain/` (protocols + entities), `Data/` (implementations: `GitCLIRepository`, `KeychainCredentialRepository`, `UserDefaultsRepoListRepository`, `FileSystemFileEditorRepository`), `Presentation/ViewModels/` (one VM per feature).
- `AppContainer` is the live DI container; `AppCoordinator` builds all ViewModels and wires their cross-references (closures for `repoSource`, `currentBranch`, `onFinished`, `pushAfterCommit`). `AppDelegate` injects each VM as an `@EnvironmentObject`.
- All git work shells out to `/usr/bin/git` via `GitRunner` (`Data/Git/`) with `GIT_TERMINAL_PROMPT=0` and `LC_ALL=C`. App is **unsandboxed** so it can spawn `git` against user-selected directories.
- HTTPS auth bypasses `git-credential-osxkeychain` entirely: PATs stored in MyGit's own keychain (`KeychainCredentialRepository`, service `com.thienpham.MyGit`). `AccountViewModel.currentAuth() -> AuthOverride?` resolves a bearer token for the current repo's host; remote methods on `GitRepository` take an `AuthOverride?` and inject `-c credential.helper= -c http.extraheader=AUTHORIZATION: bearer <PAT>` per command. See `macos/CLAUDE.md` for why.
- Staging mirrors GitHub Desktop: `ChangesViewModel.stagedPaths: Set<String>` of user-checked paths; commit resets index then `git add`s only checked paths.

## Conventions

- swift-tools-version 6.0 but `.swiftLanguageMode(.v5)` is pinned in `Package.swift` — keep new code Swift-5 compatible (no strict concurrency).
- UI state on `@MainActor`; `GitRunner.run` hops to `DispatchQueue.global(qos: .userInitiated)` and bridges via `withCheckedThrowingContinuation`.
- Frameworks linked via `linkerSettings`: AppKit, SwiftUI, UniformTypeIdentifiers. No third-party deps.
- Bundle ID `com.thienpham.MyGit`, min macOS 15.
