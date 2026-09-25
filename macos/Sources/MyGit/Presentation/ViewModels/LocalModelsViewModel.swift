import Foundation
import AppKit

/// The Local AI settings page: which catalog models are on disk, downloads
/// in flight, the llama.cpp runtime, and what the server has loaded.
@MainActor
final class LocalModelsViewModel: ObservableObject {
    static let shared = LocalModelsViewModel()

    struct DownloadState: Equatable {
        var received: Int64 = 0
        var total: Int64
        var rate: Double = 0
        var fraction: Double { total > 0 ? min(1, Double(received) / Double(total)) : 0 }
    }

    /// Key for the runtime's own download in `downloads`.
    static let runtimeKey = "llama.cpp-runtime"

    @Published private(set) var installed: Set<String> = []
    @Published private(set) var runtimeInstalled = false
    @Published private(set) var downloads: [String: DownloadState] = [:]
    @Published private(set) var errors: [String: String] = [:]
    @Published private(set) var loadedModel: String?

    let catalog = LocalModelCatalog.models
    let physicalMemoryGB = Int((Double(ProcessInfo.processInfo.physicalMemory) / 1_073_741_824).rounded())
    let isAppleSilicon: Bool = {
        var value: Int32 = 0
        var size = MemoryLayout<Int32>.size
        return sysctlbyname("hw.optional.arm64", &value, &size, nil, 0) == 0 && value == 1
    }()

    private var active: [String: FileDownload] = [:]
    /// Models to fetch once the runtime lands.
    private var waitingForRuntime: [LocalModelSpec] = []

    private init() {
        refresh()
    }

    func refresh() {
        installed = Set(catalog.filter(LocalAIPaths.isInstalled).map(\.id))
        runtimeInstalled = LocalAIPaths.isRuntimeInstalled
        Task { loadedModel = await LocalLLMServer.shared.loadedModel() }
    }

    func isDownloading(_ id: String) -> Bool { downloads[id] != nil }

    /// Bytes of a half-finished download left from an earlier session.
    func partialBytes(_ spec: LocalModelSpec) -> Int64 {
        let part = LocalAIPaths.modelFile(spec).appendingPathExtension("part")
        return ((try? FileManager.default.attributesOfItem(atPath: part.path))?[.size] as? NSNumber)?.int64Value ?? 0
    }

    // MARK: - Actions

    func download(_ spec: LocalModelSpec) {
        guard !isDownloading(spec.id), !installed.contains(spec.id) else { return }
        errors[spec.id] = nil
        if !runtimeInstalled {
            waitingForRuntime.append(spec)
            downloads[spec.id] = DownloadState(total: spec.sizeBytes)
            installRuntime()
            return
        }
        start(key: spec.id, url: spec.url, to: LocalAIPaths.modelFile(spec), sha256: spec.sha256, size: spec.sizeBytes) { [weak self] _ in
            self?.refresh()
        }
    }

    func cancel(_ id: String) {
        active[id]?.cancel()
        active[id] = nil
        downloads[id] = nil
        waitingForRuntime.removeAll { $0.id == id }
    }

    func delete(_ spec: LocalModelSpec) {
        Task {
            if await LocalLLMServer.shared.loadedModel() == spec.id { await LocalLLMServer.shared.stop() }
            let file = LocalAIPaths.modelFile(spec)
            try? FileManager.default.removeItem(at: file)
            try? FileManager.default.removeItem(at: file.appendingPathExtension("part"))
            refresh()
        }
    }

    func unload() {
        Task {
            await LocalLLMServer.shared.stop()
            refresh()
        }
    }

    func revealInFinder() {
        try? FileManager.default.createDirectory(at: LocalAIPaths.models, withIntermediateDirectories: true)
        NSWorkspace.shared.activateFileViewerSelecting([LocalAIPaths.models])
    }

    func installRuntime() {
        let key = Self.runtimeKey
        guard !isDownloading(key) else { return }
        guard isAppleSilicon else {
            errors[key] = "Local models need an Apple Silicon Mac."
            failWaiting(errors[key]!)
            return
        }
        errors[key] = nil
        let archive = LocalAIPaths.root.appendingPathComponent("llama-\(LocalModelCatalog.runtimeBuild).tar.gz")
        start(key: key, url: LocalModelCatalog.runtimeURL, to: archive, sha256: LocalModelCatalog.runtimeSHA256,
              size: LocalModelCatalog.runtimeSizeBytes) { [weak self] result in
            guard let self else { return }
            guard case let .success(file) = result else {
                self.failWaiting(self.errors[key] ?? "Runtime download failed.")
                return
            }
            Task {
                do {
                    try await Self.unpack(file, into: LocalAIPaths.runtime)
                    try? FileManager.default.removeItem(at: file)
                    self.refresh()
                    let waiting = self.waitingForRuntime
                    self.waitingForRuntime = []
                    for spec in waiting {
                        self.downloads[spec.id] = nil
                        self.download(spec)
                    }
                } catch {
                    self.errors[key] = error.localizedDescription
                    self.failWaiting(error.localizedDescription)
                }
            }
        }
    }

    // MARK: - Private

    private func failWaiting(_ message: String) {
        for spec in waitingForRuntime {
            downloads[spec.id] = nil
            errors[spec.id] = message
        }
        waitingForRuntime = []
    }

    private func start(key: String, url: URL, to destination: URL, sha256: String, size: Int64,
                       then: @escaping (Result<URL, Error>) -> Void) {
        downloads[key] = DownloadState(total: size)
        let job = FileDownload(url: url, to: destination, sha256: sha256, expectedSize: size,
            onProgress: { [weak self] p in
                Task { @MainActor in
                    guard let self, self.downloads[key] != nil else { return }
                    self.downloads[key] = DownloadState(received: p.received, total: p.total, rate: p.rate)
                }
            },
            onFinish: { [weak self] result in
                Task { @MainActor in
                    guard let self else { return }
                    self.active[key] = nil
                    self.downloads[key] = nil
                    if case let .failure(error) = result { self.errors[key] = error.localizedDescription }
                    then(result)
                }
            })
        active[key] = job
        job.start()
    }

    /// `tar -xzf` into `dir` (the tarball holds `llama-<build>/…`).
    private static func unpack(_ archive: URL, into dir: URL) async throws {
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            let p = Process()
            p.executableURL = URL(fileURLWithPath: "/usr/bin/tar")
            p.arguments = ["-xzf", archive.path, "-C", dir.path]
            p.terminationHandler = { proc in
                if proc.terminationStatus == 0 {
                    cont.resume()
                } else {
                    cont.resume(throwing: FileDownload.Failure.io("Couldn't unpack the runtime (tar exit \(proc.terminationStatus))."))
                }
            }
            do { try p.run() } catch { cont.resume(throwing: error) }
        }
    }
}
