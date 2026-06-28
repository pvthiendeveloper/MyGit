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

AppKit shell + SwiftUI content. `Sources/MyGit/App/main.swift` boots `NSApplication` with `AppDelegate` (no `@main`/SwiftUI `App`). `AppDelegate.applicationDidFinishLaunching` installs the main menu manually and hosts `MainView` inside an `NSHostingController` in a single `NSWindow`. Menu items (`Add Local Repository`, `Fetch`/`Pull`/`Push`) dispatch into the relevant ViewModel on `AppCoordinator`.

Source layout follows Clean Architecture:

- `Domain/Entities/` — value types (`Repository`, `Workspace`, `AuthOverride`, `OpenFileTab`, `AICommitConfig`, `CachedCommit`).
- `Domain/Repositories/` — protocols only: `GitRepository`, `CredentialRepository`, `RepoListRepository`, `FileEditorRepository`, `CommitMessageRepository`.
- `Data/{Git,Keychain,Persistence,FileSystem,AI}/` — concrete implementations (`GitCLIRepository`, `KeychainCredentialRepository`, `UserDefaultsRepoListRepository`, `FileSystemFileEditorRepository`, `AICommitMessageRepository`), plus `WorkspaceScanner` and the FSEvents `RepoWatcher`.
- `Presentation/ViewModels/` — per-feature `@MainActor ObservableObject` VMs (`MainViewModel`, `ChangesViewModel`, `HistoryViewModel`, `FilesViewModel`, `BranchesViewModel`, `AccountViewModel`, `RemoteViewModel`, `RepositoryListViewModel`, `FileEditorViewModel`, `CompareBranchesViewModel`, `SettingsViewModel`).
- `UI/` — SwiftUI views, each reading the VMs it needs as `@EnvironmentObject`. `Workspace*View` are the multi-repo variants; `SettingsView`/`SettingsWindow` host AI config.
- `Git/` — shared models + helpers used by both Data and Presentation (`GitStatus`, `GitLog`, `GitDiff`, `GitBranch`, `GitAccount`, `GitFileTree`, `CompareModels`, `DiffTab`, `LineDiffer`).

### Wiring

`AppContainer` (`App/AppContainer.swift`) is the DI seam — `.live()` returns the five repository protocols (`git`, `repos`, `credentials`, `fileEditor`, `commitMessage`) backed by their concrete implementations.

The per-repo ViewModels are grouped into a `RepoBundle` (`App/RepoBundle.swift`) — one bundle per git repo, holding that repo's `changes`/`history`/`files`/`editor`/`branches`/`account`/`remote`/`compare` VMs wired together with a constant `repoSource = { repo }`. `MainViewModel` and `SettingsViewModel` are **shared** (global) across all bundles. `RepoBundle` reproduces the cross-reference wiring that used to live inline in `AppCoordinator.init`:

- `repoSource: () -> Repository?` — constant `{ repo }` for the bundle.
- `currentBranch: () -> String?` — pulled from `ChangesViewModel.status?.branch`.
- `onFinished: () async -> Void` — most action VMs call this after a remote/branch op; it's the bundle's `refreshAll()`.
- `ChangesViewModel.pushAfterCommit` is bound to `RemoteViewModel.push()` / `forcePush()`.

`AppCoordinator` (`App/AppCoordinator.swift`) holds `bundles: [RepoBundle]` (one per repo in the selected workspace) and `activeBundle` (the bundle the single-repo UI — toolbar, detail panel, menus — acts on). It exposes convenience forwarders (`changes`, `remote`, …) onto `activeBundle`. `AppDelegate` injects the coordinator and the shared VMs as `@EnvironmentObject` on `MainView`; views reach per-repo VMs through `coordinator.activeBundle`.

Workspace switching: `RepoListRepository.selectedPublisher` (a `Workspace?`) → Combine sink → `rebuildBundles(for:)`, which stops old `RepoWatcher`s, builds a fresh bundle per repo, picks the first as `activeBundle`, starts one watcher per bundle, and `refreshAll()`s each.

### Git execution

All git work shells out via `GitRunner.run` / `runOrThrow` (`Data/Git/GitRunner.swift`) to `/usr/bin/git`. Always sets `GIT_TERMINAL_PROMPT=0` and `LC_ALL=C`. `run` returns even on non-zero exit (some commands like `diff --no-index` exit 1 when diffs exist); `runOrThrow` throws `GitError.nonZeroExit` on non-zero. The app is **unsandboxed** (`Packaging/MyGit.entitlements`) precisely so it can spawn `git` against user-selected directories.

`GitCLIRepository` is the only place `GitRunner` is called from in production code — keep `GitRunner` calls out of ViewModels. The `GitRepository` protocol is the ViewModel-facing surface; add a new method there when you need a new git operation.

Parsers live next to the runner under `Git/` — `GitStatusParser` (porcelain=v1 -z --branch, handles rename/copy extra NUL record), `GitLogParser`, `GitDiffParser` (parses unified diff, tracks old/new line numbers per hunk), `GitAccountLoader` (parses remote URL into host/owner/repo, detects SCP-vs-URL transport).

### Auth model (important)

Push/pull/fetch must NOT trigger `git-credential-osxkeychain`, because a self-signed app's keychain access prompts every launch. `AccountViewModel.currentAuth()` returns an `AuthOverride?` (just a bearer token) when the current repo has an HTTPS remote and a stored PAT. `RemoteViewModel` passes this to `GitRepository.fetch`/`pull`/`push`, and `GitCLIRepository` prepends the per-command flags:

```
-c credential.helper=                          # disable all helpers
-c http.extraheader=AUTHORIZATION: bearer <PAT>
```

PATs are stored by host in MyGit's own keychain via `KeychainCredentialRepository` (service `com.thienpham.MyGit`, `kSecClassGenericPassword`, `kSecAttrAccessibleAfterFirstUnlock`) — independent of the system `osxkeychain` helper. `AccountViewModel.signIn`/`signOut` manipulate that store, keyed by `account?.host`.

### Staging model

Mirrors GitHub Desktop: `ChangesViewModel.stagedPaths` is a `Set<String>` of paths the user has checked. On commit, `GitCLIRepository.commit(at:paths:message:)` resets the index (`git reset --mixed -q`), then `git add`s only the checked paths, then `git commit -m`. Status refresh defaults newly-appeared paths to checked while preserving explicit unchecks (`previousPaths` diff).

### Diff viewer

Two ways to show a file diff, both built on `Git/LineDiffer.swift` + `Git/DiffTab.swift`:

- **In-app tabs** — `MainViewModel` owns `diffTabs: [DiffTab]` and its `DetailTab` enum has a `.diff(UUID)` case. `openDiffTab(...)` dedups on `(commitHash, path, mode)` unless `forceNew`. Browser-style back/forward lives on `tabHistory`/`tabHistoryIndex`; the `navigating` flag suppresses `pushHistory` during nav so back/forward don't pollute history. `closeDiffTab` falls back to the previous history entry, then last tab, then compare, then content.
- **Standalone window** — `UI/DiffWindow.open(diff:)` hosts `DiffView` in a detached `NSWindow`, retained in a static array and removed on `willCloseNotification`.

`DiffTab.Mode` (`commitVsParent`, `commitVsWorking`, `parentVsWorking`) drives `rightIsEditable` — only the working-tree side can be edited and saved to disk. `SideBySideDiffTabView` (the big view) loads `sourceText`/`workingText`/`diskText`, runs `LineDiffer.diff` (LCS DP, capped at `maxLines = 6000` — beyond that it degrades to delete-all/insert-all), and renders `LineHunk`s with per-hunk exclude/apply. Viewer/whitespace/highlight options are the enums in `DiffTab.swift` (`DiffViewerMode`, `DiffWhitespaceMode`, `DiffHighlightMode`); whitespace `normalize` is applied before diffing.

Data path is new `GitRepository` methods (all in `GitCLIRepository`): `diffFileVsWorking`, `diffFileBeforeVsWorking`, `readFileAtCommit`, `extractFileAtCommit`, `patchForFile`, `revertFileInCommit`, `cherryPickFileFromCommit`, plus working-tree file ops `restore`, `addToIndex`, `removeFile`, `diffPatch`.

### Workspaces & multi-repo

A picked folder becomes a `Workspace` via `WorkspaceScanner.scan`: the whole tree is walked recursively for `.git` (via `FileManager.enumerator` with `.skipsHiddenFiles`, which keeps the walk out of each repo's `.git/` internals while still descending into a repo's working tree), and the root is included when it is a git repo too. So a plain repo with no nested repos → single-repo workspace (`isSingle`); a repo that *also* nests git repos at any depth → root + nested; a non-repo parent of repos → just the descendants. `RepoListRepository` now deals in `Workspace`s, not raw repos — `workspaces` / `selected` (a `Workspace?`) with matching publishers. The coordinator builds one `RepoBundle` per repo in the selected workspace; `Workspace*View` render the multi-repo UI, falling back to single-repo views when `isSingle`.

### Auto-refresh (filesystem watcher)

`RepoWatcher` (`Data/FileSystem/RepoWatcher.swift`) wraps FSEvents over a repo's working tree (including `.git/`), coalesced by the FSEvents latency window. Its callback fires on a private dispatch queue — `onChange` must hop back to `@MainActor`. The coordinator runs one watcher per active bundle and calls `bundle.refreshFromWatcher()` on change, so status/history/branches update without a manual Refresh. Watchers are torn down and rebuilt wholesale whenever bundles rebuild.

### AI commit messages

`CommitMessageRepository.generate(diff:config:)` turns a staged unified diff into a Conventional Commits message; `AICommitMessageRepository` implements it over REST. OpenAI and "custom (OpenAI-compatible)" share the chat-completions path; Gemini has its own. `SettingsViewModel` holds per-provider model/base-URL (UserDefaults) and API keys (keychain, one per provider), with `activeProvider` selecting which is used. `testConnection` validates a provider without spending generation tokens. Errors surface via `CommitMessageError` (e.g. missing key → "Open Settings (⌘,)").

### Repository persistence

`UserDefaultsRepoListRepository` persists added workspace folders and the selection; on load it drops paths whose `.git` no longer exists. `workspacesPublisher` / `selectedPublisher` are the Combine seams the rest of the app reacts to. Two small UserDefaults caches in `CachedCommit.swift` improve perceived launch speed and avoid data loss: `LastCommitStore` (keyed `MyGit.lastCommit.<repoPath>`) shows each repo's last commit instantly before the log loads; `CommitDraftStore` persists the in-progress commit summary/description per repo. `HistoryViewModel` paginates the log — `pageSize = 100`, `hasMore` true while a fetch fills the limit, raising `limit` to load more.

## Conventions

- Concurrency: all UI state on `@MainActor`. `GitRunner.run` hops to `DispatchQueue.global(qos: .userInitiated)` and bridges via `withCheckedThrowingContinuation`.
- `Package.swift` pins `.swiftLanguageMode(.v5)` despite swift-tools-version 6.0 — keep new code Swift-5-compatible (no strict concurrency by default).
- Links AppKit + SwiftUI + UniformTypeIdentifiers via `linkerSettings`, no other deps.
- Bundle ID `com.thienpham.MyGit`, min macOS 15.
