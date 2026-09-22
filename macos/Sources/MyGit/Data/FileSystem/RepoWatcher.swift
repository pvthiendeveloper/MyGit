import CoreServices
import Foundation

/// Watches a git repo's working tree (recursively, including `.git/`) via
/// FSEvents and invokes `onChange` — coalesced by FSEvents' latency window —
/// whenever anything changes on disk. Lets the app auto-refresh status,
/// history and branches without the user hitting Refresh.
///
/// Not `@MainActor`: the FSEvents callback fires on a private dispatch queue.
/// `onChange` is responsible for hopping back to the main actor.
final class RepoWatcher {
    private let url: URL
    private let onChange: () -> Void
    private var stream: FSEventStreamRef?
    private let queue = DispatchQueue(label: "com.thienpham.MyGit.watcher", qos: .utility)

    init(url: URL, onChange: @escaping () -> Void) {
        self.url = url
        self.onChange = onChange
        start()
    }

    deinit { stop() }

    private func start() {
        var ctx = FSEventStreamContext(
            version: 0,
            info: Unmanaged.passUnretained(self).toOpaque(),
            retain: nil,
            release: nil,
            copyDescription: nil
        )
        // FileEvents = per-file granularity; NoDefer = fire at start of latency
        // window so the first change feels instant; WatchRoot/IgnoreSelf are
        // hygiene (track moves of the repo dir, drop our own writes from history).
        let flags = UInt32(
            kFSEventStreamCreateFlagUseCFTypes |
            kFSEventStreamCreateFlagNoDefer |
            kFSEventStreamCreateFlagWatchRoot |
            kFSEventStreamCreateFlagIgnoreSelf |
            kFSEventStreamCreateFlagFileEvents
        )
        guard let stream = FSEventStreamCreate(
            kCFAllocatorDefault,
            repoWatcherCallback,
            &ctx,
            [url.path] as CFArray,
            FSEventStreamEventId(kFSEventStreamEventIdSinceNow),
            0.5, // latency seconds — coalesces bursts (git writes many files at once)
            flags
        ) else { return }

        self.stream = stream
        FSEventStreamSetDispatchQueue(stream, queue)
        FSEventStreamStart(stream)
    }

    /// Idempotent. Invalidate guarantees no further callbacks fire, so it is
    /// safe to call from `deinit` even though the callback holds an unretained
    /// pointer back to `self`.
    func stop() {
        guard let stream else { return }
        FSEventStreamStop(stream)
        FSEventStreamInvalidate(stream)
        FSEventStreamRelease(stream)
        self.stream = nil
    }

    /// Events whose paths are *all* git-internal bookkeeping are dropped.
    /// Our own `git status` refreshes `.git/index`'s stat cache, which fires
    /// FSEvents, which would trigger another refresh — a self-feeding loop that
    /// pegs the CPU forever. (`IgnoreSelf` doesn't help: git is a child
    /// process, not us.) Ref/HEAD/MERGE changes are real and still pass.
    fileprivate func fire(paths: [String]) {
        guard paths.isEmpty || paths.contains(where: { !Self.isNoise($0) }) else { return }
        onChange()
    }

    private static func isNoise(_ path: String) -> Bool {
        guard let range = path.range(of: "/.git/") else {
            return path.hasSuffix("/.git")
        }
        let rest = path[range.upperBound...]
        // Refs, HEAD and merge state are meaningful; index/logs/objects churn is not.
        if rest.hasPrefix("refs/") || rest.hasPrefix("HEAD") || rest.hasPrefix("MERGE")
            || rest.hasPrefix("REBASE") || rest.hasPrefix("CHERRY") || rest.hasPrefix("packed-refs") {
            return false
        }
        return true
    }
}

/// C-compatible FSEvents callback. Recovers the `RepoWatcher` from the context
/// info pointer and forwards. Path/flag details are ignored — any event in the
/// tree means "something changed, re-read git state".
private func repoWatcherCallback(
    streamRef: ConstFSEventStreamRef,
    clientCallBackInfo: UnsafeMutableRawPointer?,
    numEvents: Int,
    eventPaths: UnsafeMutableRawPointer,
    eventFlags: UnsafePointer<FSEventStreamEventFlags>,
    eventIds: UnsafePointer<FSEventStreamEventId>
) {
    guard let info = clientCallBackInfo else { return }
    let paths = (Unmanaged<CFArray>.fromOpaque(eventPaths).takeUnretainedValue() as? [String]) ?? []
    Unmanaged<RepoWatcher>.fromOpaque(info).takeUnretainedValue().fire(paths: paths)
}
