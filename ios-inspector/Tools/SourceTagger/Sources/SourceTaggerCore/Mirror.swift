import Foundation

/// Keeps `dest` a tagged mirror of every `.swift` file under `source`,
/// doing as little work as possible:
///
/// - **Incremental:** a manifest remembers each file's size, mtime and
///   content hash. Unchanged files are skipped on `stat` alone; touched but
///   identical ones on a hash; only real changes are parsed.
/// - **Stable output:** a mirrored file is rewritten only when its bytes
///   change, so its mtime — and Xcode's incremental build — survive.
/// - **Parallel:** files are processed across all cores with
///   `concurrentPerform` (GCD work-stealing over the file list).
/// - **Cheap rejects:** files without SwiftUI views are byte-scanned and
///   copied without parsing.
///
/// Non-Swift files are the caller's job (rsync); this only owns `*.swift`.
public struct Mirror {
    public struct Options {
        public var source: URL
        public var dest: URL
        public var manifest: URL
        public var jobs: Int
        /// Repo-relative paths to mirror untagged (e.g. after a build error).
        public var plain: Set<String>
        /// Repo-relative paths to tag without token probes (their
        /// arguments didn't compile wrapped in `__mT`).
        public var unprobed: Set<String> = []
        /// Where per-file source maps go (`<dir>/<rel>.json`); nil = none.
        public var mapDirectory: URL?
        /// Modifier calls removed from view chains (`debugLayoutBounds`).
        public var stripModifiers: Set<String> = []

        public init(source: URL, dest: URL, manifest: URL, jobs: Int, plain: Set<String>, mapDirectory: URL? = nil) {
            self.source = source
            self.dest = dest
            self.manifest = manifest
            self.jobs = jobs
            self.plain = plain
            self.mapDirectory = mapDirectory
        }
    }

    public struct Stats: CustomStringConvertible {
        public var files = 0, unchanged = 0, tagged = 0, copied = 0, written = 0, removed = 0, tags = 0
        public var seconds = 0.0

        public var description: String {
            String(format: "%d Swift files: %d unchanged, %d tagged (%d tags), %d copied as-is, %d written, %d removed — %.2fs",
                   files, unchanged, tagged, tags, copied, written, removed, seconds)
        }
    }

    /// Bumped whenever tagging output changes, to invalidate old manifests.
    static let toolVersion = 28

    /// Directories never mirrored.
    static let skippedDirectories: Set<String> = [".git", ".mygit", ".build", "DerivedData", "node_modules", "xcuserdata"]
    /// Third-party code: mirrored, never tagged.
    static let vendorDirectories: Set<String> = ["Pods", "Carthage", "SourcePackages", "checkouts", "Vendor", "ThirdParty"]

    private struct Entry: Codable {
        var size: Int64
        var mtime: Double
        var hash: UInt64
        var outHash: UInt64
        /// The mirror copy's size and mtime when written: a copy edited in
        /// place (say, from an Xcode build error) is rewritten.
        var outSize: Int64? = nil
        var outMtime: Double? = nil
        var mode: Mode
        /// The file's simple-valued properties (merged into `_symbols.json`).
        var symbols: [SymbolEntry]?
    }

    private enum Mode: String, Codable { case tagged, unprobed, copied, plain }

    private struct Manifest: Codable {
        var version: Int
        /// The strip list the mirror was made with; a different one redoes it.
        var strip: [String]?
        var entries: [String: Entry]
        /// Files forced untagged; cleared for a file once its source changes.
        var plain: Set<String>
        /// Files tagged without token probes; cleared the same way.
        var unprobed: Set<String>? = nil
    }

    let options: Options

    public init(options: Options) { self.options = options }

    public func run() throws -> Stats {
        let started = Date()
        var manifest = loadManifest()
        manifest.plain.formUnion(options.plain)
        manifest.unprobed = (manifest.unprobed ?? []).union(options.unprobed)

        let files = swiftFiles()
        var stats = Stats()
        stats.files = files.count

        let results = UnsafeMutableBufferPointer<(String, Entry?, Outcome)>.allocate(capacity: files.count)
        defer { results.deallocate() }
        let previous = manifest.entries
        let plainSet = manifest.plain
        let unprobedSet = manifest.unprobed ?? []

        // `jobs` workers pull the next file from a shared counter, so a few
        // huge files don't leave the other cores idle.
        let next = Counter()
        DispatchQueue.concurrentPerform(iterations: max(1, min(options.jobs, files.count))) { _ in
            while case let i = next.increment(), i < files.count {
                let rel = files[i]
                let outcome = process(rel, previous: previous[rel], forcePlain: plainSet.contains(rel),
                                      unprobed: unprobedSet.contains(rel))
                (results.baseAddress! + i).initialize(to: (rel, outcome.entry, outcome))
            }
        }

        var entries: [String: Entry] = [:]
        entries.reserveCapacity(files.count)
        for (rel, entry, outcome) in results {
            if let entry { entries[rel] = entry }
            switch outcome.kind {
            case .unchanged: stats.unchanged += 1
            case .tagged: stats.tagged += 1
            case .copied: stats.copied += 1
            case .failed(let message): FileHandle.standardError.write(Data("⚠︎ \(rel): \(message)\n".utf8))
            }
            if outcome.wrote { stats.written += 1 }
            stats.tags += outcome.tags
            // A changed file gets another chance at tagging.
            if outcome.sourceChanged { manifest.plain.remove(rel); manifest.unprobed?.remove(rel) }
        }
        results.baseAddress!.deinitialize(count: files.count)

        // Files gone from the source leave the mirror too.
        let present = Set(files)
        for rel in previous.keys where !present.contains(rel) {
            try? FileManager.default.removeItem(at: options.dest.appendingPathComponent(rel))
            writeMap([:], for: rel)
            stats.removed += 1
        }
        manifest.entries = entries
        manifest.plain = manifest.plain.intersection(present)
        manifest.unprobed = manifest.unprobed?.intersection(present)
        saveManifest(manifest)
        writeSymbolIndex(entries)
        stats.seconds = Date().timeIntervalSince(started)
        return stats
    }

    // MARK: - One file

    private struct Outcome {
        enum Kind { case unchanged, tagged, copied, failed(String) }
        var kind: Kind
        var entry: Entry?
        var wrote = false
        var tags = 0
        var sourceChanged = false
    }

    private func process(_ rel: String, previous: Entry?, forcePlain: Bool, unprobed: Bool) -> Outcome {
        let src = options.source.appendingPathComponent(rel)
        let dst = options.dest.appendingPathComponent(rel)
        guard let meta = Self.stat(src.path) else { return Outcome(kind: .failed("unreadable")) }
        let wantMode: Mode = forcePlain ? .plain : isVendor(rel) ? .copied : unprobed ? .unprobed : .tagged
        let destMeta = Self.stat(dst.path)
        let destExists = destMeta != nil
        let destUntouched = destMeta.map { $0.size == previous?.outSize && $0.mtime == previous?.outMtime } ?? false

        // Fast path: same size and mtime as last time.
        if let previous, destUntouched, previous.size == meta.size, previous.mtime == meta.mtime,
           previous.mode == wantMode || (wantMode == .tagged && previous.mode == .copied) {
            return Outcome(kind: .unchanged, entry: previous)
        }
        guard let data = FileManager.default.contents(atPath: src.path) else {
            return Outcome(kind: .failed("unreadable"))
        }
        let hash = Self.fnv1a(data)
        if let previous, destUntouched, previous.hash == hash,
           previous.mode == wantMode || (wantMode == .tagged && previous.mode == .copied) {
            var entry = previous
            entry.size = meta.size
            entry.mtime = meta.mtime
            return Outcome(kind: .unchanged, entry: entry)
        }

        // Produce the mirrored bytes.
        var output = data
        var mode: Mode = wantMode
        var tags = 0
        var symbols: [SymbolEntry]?
        if wantMode == .tagged || wantMode == .unprobed {
            let worth = data.withUnsafeBytes { raw in
                SourceTagger.mightContainViews(raw.bindMemory(to: UInt8.self))
            }
            if worth, let text = String(data: data, encoding: .utf8) {
                let result = SourceTagger.tag(source: text, path: rel, stripModifiers: options.stripModifiers,
                                              probeTokens: wantMode == .tagged)
                symbols = result.symbols
                tags = result.tagCount
                // Tags, or only stripped modifiers: either way the rewrite counts.
                if result.output != text { output = Data(result.output.utf8) }
                if tags == 0 { mode = .copied }
                writeMap(result.sourceMap, for: rel)
            } else {
                mode = .copied
                writeMap([:], for: rel)
                // No views, but maybe the design tokens themselves — and
                // getters whose `return`s can report which one ran.
                if let text = String(data: data, encoding: .utf8) {
                    if let probed = SourceTagger.probe(source: text, path: rel) {
                        output = Data(probed.output.utf8)
                        symbols = probed.symbols
                    } else {
                        symbols = SourceTagger.symbols(source: text, path: rel)
                    }
                }
            }
        } else {
            writeMap([:], for: rel)
        }
        let outHash = Self.fnv1a(output)
        var wrote = false
        // Compare with what's on disk, not the manifest: a new tool version
        // drops the manifest but mostly produces the same bytes, and
        // rewriting them would cost Xcode a full rebuild.
        if !(destExists && Self.fnv1a(contentsOf: dst) == outHash) {
            do {
                try FileManager.default.createDirectory(at: dst.deletingLastPathComponent(), withIntermediateDirectories: true)
                try output.write(to: dst)
                wrote = true
            } catch {
                return Outcome(kind: .failed("write failed: \(error.localizedDescription)"))
            }
        }
        let written = Self.stat(dst.path)
        let entry = Entry(size: meta.size, mtime: meta.mtime, hash: hash, outHash: outHash,
                          outSize: written?.size, outMtime: written?.mtime, mode: mode,
                          symbols: symbols?.isEmpty == false ? symbols : nil)
        return Outcome(kind: mode == .tagged || mode == .unprobed ? .tagged : .copied, entry: entry, wrote: wrote, tags: tags,
                       sourceChanged: previous?.hash != hash)
    }

    /// All files' properties in one index: `name → [SymbolEntry]`. Rewritten
    /// only when it changes.
    private func writeSymbolIndex(_ entries: [String: Entry]) {
        guard let dir = options.mapDirectory else { return }
        var index: [String: [SymbolEntry]] = [:]
        for (_, entry) in entries {
            for symbol in entry.symbols ?? [] { index[symbol.name, default: []].append(symbol) }
        }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        for key in index.keys { index[key]?.sort { ($0.path, $0.line) < ($1.path, $1.line) } }
        guard let data = try? encoder.encode(index) else { return }
        let url = dir.appendingPathComponent("_symbols.json")
        if FileManager.default.contents(atPath: url.path) == data { return }
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try? data.write(to: url, options: .atomic)
    }

    /// One JSON per source file; removed when the file has no tags.
    private func writeMap(_ map: [String: SourceMapEntry], for rel: String) {
        guard let dir = options.mapDirectory else { return }
        let url = dir.appendingPathComponent(rel + ".json")
        guard !map.isEmpty else {
            try? FileManager.default.removeItem(at: url)
            return
        }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        guard let data = try? encoder.encode(map) else { return }
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? data.write(to: url, options: .atomic)
    }

    private func isVendor(_ rel: String) -> Bool {
        rel.split(separator: "/").dropLast().contains { Self.vendorDirectories.contains(String($0)) }
    }

    // MARK: - Files

    /// Repo-relative paths of every `.swift` file, skipping build output.
    private func swiftFiles() -> [String] {
        let root = options.source.standardizedFileURL
        let rootPath = root.path.hasSuffix("/") ? root.path : root.path + "/"
        guard let walker = FileManager.default.enumerator(
            at: root, includingPropertiesForKeys: [.isDirectoryKey], options: [], errorHandler: nil
        ) else { return [] }
        var out: [String] = []
        for case let url as URL in walker {
            let name = url.lastPathComponent
            if Self.skippedDirectories.contains(name) {
                walker.skipDescendants()
                continue
            }
            guard name.hasSuffix(".swift") else { continue }
            let path = url.standardizedFileURL.path
            if path.hasPrefix(rootPath) { out.append(String(path.dropFirst(rootPath.count))) }
        }
        return out
    }

    // MARK: - Manifest

    private func loadManifest() -> Manifest {
        guard let data = FileManager.default.contents(atPath: options.manifest.path),
              let manifest = try? JSONDecoder().decode(Manifest.self, from: data),
              manifest.version == Self.toolVersion,
              Set(manifest.strip ?? []) == options.stripModifiers else {
            return Manifest(version: Self.toolVersion, strip: options.stripModifiers.sorted(), entries: [:], plain: [])
        }
        return manifest
    }

    private func saveManifest(_ manifest: Manifest) {
        try? FileManager.default.createDirectory(at: options.manifest.deletingLastPathComponent(),
                                                 withIntermediateDirectories: true)
        try? JSONEncoder().encode(manifest).write(to: options.manifest, options: .atomic)
    }

    // MARK: - Primitives

    /// Returns 0, 1, 2… across threads.
    private final class Counter: @unchecked Sendable {
        private var value = 0
        private var lock = os_unfair_lock()

        func increment() -> Int {
            os_unfair_lock_lock(&lock)
            defer { os_unfair_lock_unlock(&lock) }
            let current = value
            value += 1
            return current
        }
    }

    private static func stat(_ path: String) -> (size: Int64, mtime: Double)? {
        var st = Darwin.stat()
        guard lstat(path, &st) == 0 else { return nil }
        let mtime = Double(st.st_mtimespec.tv_sec) + Double(st.st_mtimespec.tv_nsec) / 1e9
        return (Int64(st.st_size), mtime)
    }

    /// FNV-1a, 64-bit: fast, and plenty to detect edits.
    static func fnv1a(_ data: Data) -> UInt64 {
        data.withUnsafeBytes { raw -> UInt64 in
            var h: UInt64 = 0xcbf2_9ce4_8422_2325
            for byte in raw {
                h ^= UInt64(byte)
                h = h &* 0x0000_0100_0000_01b3
            }
            return h
        }
    }

    private static func fnv1a(contentsOf url: URL) -> UInt64? {
        FileManager.default.contents(atPath: url.path).map(fnv1a)
    }
}
