import Foundation
import CIndexStore

/// A symbol as Xcode's index knows it, and every place it occurs in the repo.
struct IndexedSymbol {
    struct Occurrence: Hashable {
        let path: String          // repo-relative
        let line: Int             // 1-based
        let isDefinition: Bool    // declaration or definition
    }

    let usr: String
    let name: String
    let occurrences: [Occurrence]
    /// When the index was last written — older than the file means lines may
    /// have moved since.
    let indexedAt: Date?
}

/// Semantic ⌘-click lookup backed by the index Xcode writes while building
/// (DerivedData/<proj>/Index.noindex/DataStore), read through Xcode's own
/// libIndexStore. Unlike `git grep` this resolves the *symbol* under the
/// caret (its USR) and lists only real references to it: same-named locals,
/// other types' members and comments don't show up.
///
/// Returns nil whenever it can't answer (no Xcode, repo never built, file not
/// indexed, index older than the edit) so the caller can fall back to grep.
final class XcodeSymbolIndex: @unchecked Sendable {
    static let shared = XcodeSymbolIndex()

    /// All libIndexStore calls happen here; the C API isn't thread-safe per store.
    private let queue = DispatchQueue(label: "com.thienpham.MyGit.indexstore", qos: .userInitiated)
    private var libraryState: Bool?   // nil = not tried yet
    private var stores: [String: StoreCache] = [:]

    /// One opened store plus which records describe which source file.
    private final class StoreCache {
        let handle: indexstore_t
        var stamp: Date?
        var recordsByFile: [String: Set<String>] = [:]
        var recordFiles: [String: String] = [:]   // record name → source path

        init(handle: indexstore_t) { self.handle = handle }
    }

    func lookup(repo: URL, path: String, line: Int, name: String) async -> IndexedSymbol? {
        await withCheckedContinuation { cont in
            queue.async { cont.resume(returning: self.lookupSync(repo: repo, path: path, line: line, name: name)) }
        }
    }

    // MARK: - Lookup

    private func lookupSync(repo: URL, path: String, line: Int, name: String) -> IndexedSymbol? {
        guard loadLibrary() else { return nil }
        let repoPath = Self.canonical(repo.path)
        let filePath = Self.canonical(repo.appendingPathComponent(path).path)

        for storeURL in Self.storeCandidates(forRepo: repoPath) {
            guard let cache = openStore(storeURL) else { continue }
            guard let records = cache.recordsByFile[filePath], !records.isEmpty,
                  let target = symbol(at: line, named: name, in: records, cache: cache) else { continue }

            var found: Set<IndexedSymbol.Occurrence> = []
            let usrBytes = Array(target.usr.utf8)
            for (record, source) in cache.recordFiles {
                guard source == repoPath || source.hasPrefix(repoPath + "/") else { continue }
                let relative = String(source.dropFirst(repoPath.count + 1))
                for hit in occurrences(of: usrBytes, in: record, cache: cache) {
                    found.insert(IndexedSymbol.Occurrence(path: relative, line: hit.line,
                                                          isDefinition: hit.isDefinition))
                }
            }
            // The same line can be both (a definition record from one target,
            // a reference from another build) — keep one row, definition wins.
            var byLocation: [String: IndexedSymbol.Occurrence] = [:]
            for occ in found {
                let key = "\(occ.path):\(occ.line)"
                if let existing = byLocation[key], existing.isDefinition { continue }
                byLocation[key] = occ
            }
            return IndexedSymbol(
                usr: target.usr,
                name: target.name,
                occurrences: byLocation.values.sorted { ($0.path, $0.line) < ($1.path, $1.line) },
                indexedAt: cache.stamp
            )
        }
        return nil
    }

    /// The symbol named `name` that the index places on `line` of the file.
    private func symbol(at line: Int, named name: String, in records: Set<String>,
                        cache: StoreCache) -> (usr: String, name: String)? {
        var result: (usr: String, name: String)?
        for record in records {
            guard let reader = mygit_indexstore_record_reader_create(cache.handle, record) else { continue }
            defer { mygit_indexstore_record_reader_dispose(reader) }
            _ = mygit_indexstore_record_reader_occurrences_apply(reader) { occ in
                var l: UInt32 = 0, c: UInt32 = 0
                mygit_indexstore_occurrence_get_line_col(occ, &l, &c)
                guard Int(l) == line else { return true }
                let roles = mygit_indexstore_occurrence_get_roles(occ)
                guard roles & UInt64(MYGIT_INDEXSTORE_ROLE_IMPLICIT) == 0 else { return true }
                let sym = mygit_indexstore_occurrence_get_symbol(occ)
                let symName = Self.string(mygit_indexstore_symbol_get_name(sym))
                // Functions are indexed with their labels: `foo(bar:)`.
                guard symName == name || symName.hasPrefix(name + "(") else { return true }
                result = (Self.string(mygit_indexstore_symbol_get_usr(sym)), symName)
                return false
            }
            if result != nil { break }
        }
        return result
    }

    private func occurrences(of usr: [UInt8], in record: String,
                             cache: StoreCache) -> [(line: Int, isDefinition: Bool)] {
        guard let reader = mygit_indexstore_record_reader_create(cache.handle, record) else { return [] }
        defer { mygit_indexstore_record_reader_dispose(reader) }

        // Cheap pre-check against the record's symbol table before walking
        // every occurrence in it.
        var mentions = false
        _ = mygit_indexstore_record_reader_search_symbols(reader, { sym, stop in
            if Self.equals(mygit_indexstore_symbol_get_usr(sym!), usr) {
                stop?.pointee = true
                return true
            }
            return false
        }, { _ in mentions = true })
        guard mentions else { return [] }

        var hits: [(line: Int, isDefinition: Bool)] = []
        _ = mygit_indexstore_record_reader_occurrences_apply(reader) { occ in
            let roles = mygit_indexstore_occurrence_get_roles(occ)
            guard roles & UInt64(MYGIT_INDEXSTORE_ROLE_IMPLICIT) == 0,
                  Self.equals(mygit_indexstore_symbol_get_usr(mygit_indexstore_occurrence_get_symbol(occ)), usr)
            else { return true }
            var l: UInt32 = 0, c: UInt32 = 0
            mygit_indexstore_occurrence_get_line_col(occ, &l, &c)
            let def = UInt64(MYGIT_INDEXSTORE_ROLE_DECLARATION | MYGIT_INDEXSTORE_ROLE_DEFINITION)
            hits.append((Int(l), roles & def != 0))
            return true
        }
        return hits
    }

    // MARK: - Store

    private func openStore(_ url: URL) -> StoreCache? {
        let key = url.path
        let stamp = Self.modificationDate(url.appendingPathComponent("v5/units"))
        if let cached = stores[key], cached.stamp == stamp { return cached }

        if let stale = stores.removeValue(forKey: key) { mygit_indexstore_store_dispose(stale.handle) }
        guard let handle = mygit_indexstore_store_create(url.path) else { return nil }
        let cache = StoreCache(handle: handle)
        cache.stamp = stamp

        var units: [String] = []
        _ = mygit_indexstore_store_units_apply(handle) { name in
            units.append(Self.string(name))
            return true
        }
        // A file can be named by several units: other targets/archs, but also
        // older builds whose record predates the latest edit (lines shifted).
        // Keep only the record from the newest unit per file.
        let unitsDir = url.appendingPathComponent("v5/units")
        var newest: [String: (record: String, date: Date)] = [:]
        for unit in units {
            guard let reader = mygit_indexstore_unit_reader_create(handle, unit) else { continue }
            let date = Self.modificationDate(unitsDir.appendingPathComponent(unit)) ?? .distantPast
            _ = mygit_indexstore_unit_reader_dependencies_apply(reader) { dep in
                guard mygit_indexstore_unit_dependency_get_kind(dep) == MYGIT_INDEXSTORE_DEP_RECORD else { return true }
                let record = Self.string(mygit_indexstore_unit_dependency_get_name(dep))
                let file = Self.canonical(Self.string(mygit_indexstore_unit_dependency_get_filepath(dep)))
                guard !record.isEmpty, !file.isEmpty else { return true }
                if let current = newest[file], current.date >= date { return true }
                newest[file] = (record, date)
                return true
            }
            mygit_indexstore_unit_reader_dispose(reader)
        }
        for (file, entry) in newest {
            cache.recordsByFile[file, default: []].insert(entry.record)
            cache.recordFiles[entry.record] = file
        }
        stores[key] = cache
        return cache
    }

    /// Index stores that may cover the repo, freshest first: Xcode's
    /// DerivedData for any workspace/project inside it, MyGit's own run builds
    /// (`.mygit`), and SwiftPM's `.build`.
    static func storeCandidates(forRepo repoPath: String) -> [URL] {
        let fm = FileManager.default
        var stores: [URL] = []

        for root in derivedDataRoots() {
            for entry in (try? fm.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)) ?? [] {
                guard let info = NSDictionary(contentsOf: entry.appendingPathComponent("info.plist")),
                      let workspace = info["WorkspacePath"] as? String else { continue }
                let ws = canonical(workspace)
                guard ws == repoPath || ws.hasPrefix(repoPath + "/") else { continue }
                stores.append(entry.appendingPathComponent("Index.noindex/DataStore"))
                stores.append(entry.appendingPathComponent("Index/DataStore"))   // Xcode < 14
            }
        }
        let repo = URL(fileURLWithPath: repoPath)
        stores.append(repo.appendingPathComponent(".mygit/Index.noindex/DataStore"))
        stores.append(repo.appendingPathComponent(".build/debug/index/store"))
        let build = repo.appendingPathComponent(".build")
        for triple in (try? fm.contentsOfDirectory(atPath: build.path)) ?? [] {
            stores.append(build.appendingPathComponent(triple).appendingPathComponent("debug/index/store"))
        }

        return stores
            .filter { fm.fileExists(atPath: $0.appendingPathComponent("v5/units").path) }
            .sorted {
                (modificationDate($0.appendingPathComponent("v5/units")) ?? .distantPast)
                    > (modificationDate($1.appendingPathComponent("v5/units")) ?? .distantPast)
            }
    }

    private static func derivedDataRoots() -> [URL] {
        var roots: [URL] = []
        if let custom = UserDefaults(suiteName: "com.apple.dt.Xcode")?.string(forKey: "IDECustomDerivedDataLocation") {
            roots.append(URL(fileURLWithPath: (custom as NSString).expandingTildeInPath))
        }
        roots.append(FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Developer/Xcode/DerivedData"))
        return roots
    }

    // MARK: - Library

    private func loadLibrary() -> Bool {
        if let state = libraryState { return state }
        var ok = false
        for path in Self.libraryCandidates() where FileManager.default.fileExists(atPath: path) {
            var error = [CChar](repeating: 0, count: 256)
            if mygit_indexstore_load(path, &error, error.count) { ok = true; break }
        }
        libraryState = ok
        return ok
    }

    private static func libraryCandidates() -> [String] {
        let suffix = "/Toolchains/XcodeDefault.xctoolchain/usr/lib/libIndexStore.dylib"
        var developerDirs: [String] = []
        if let env = ProcessInfo.processInfo.environment["DEVELOPER_DIR"] { developerDirs.append(env) }
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/usr/bin/xcode-select")
        proc.arguments = ["-p"]
        let out = Pipe()
        proc.standardOutput = out
        proc.standardError = FileHandle.nullDevice
        if (try? proc.run()) != nil {
            let data = out.fileHandleForReading.readDataToEndOfFile()
            proc.waitUntilExit()
            if let dir = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines),
               !dir.isEmpty { developerDirs.append(dir) }
        }
        developerDirs.append("/Applications/Xcode.app/Contents/Developer")
        return developerDirs.map { $0 + suffix }
    }

    // MARK: - Helpers

    private static func string(_ ref: indexstore_string_ref_t) -> String {
        guard let data = ref.data, ref.length > 0 else { return "" }
        return String(decoding: UnsafeRawBufferPointer(start: data, count: ref.length), as: UTF8.self)
    }

    private static func equals(_ ref: indexstore_string_ref_t, _ bytes: [UInt8]) -> Bool {
        guard ref.length == bytes.count, let data = ref.data else { return false }
        return bytes.withUnsafeBytes { memcmp(data, $0.baseAddress, ref.length) == 0 }
    }

    /// Absolute, symlink-free path, so DerivedData's paths match the repo's.
    static func canonical(_ path: String) -> String {
        URL(fileURLWithPath: path).standardizedFileURL.resolvingSymlinksInPath().path
    }

    private static func modificationDate(_ url: URL) -> Date? {
        (try? FileManager.default.attributesOfItem(atPath: url.path))?[.modificationDate] as? Date
    }
}
