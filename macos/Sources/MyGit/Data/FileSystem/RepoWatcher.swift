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

    fileprivate func fire() { onChange() }
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
    Unmanaged<RepoWatcher>.fromOpaque(info).takeUnretainedValue().fire()
}
