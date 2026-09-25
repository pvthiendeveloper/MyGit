import Foundation
import Darwin

/// Where local AI lives: `~/Library/Application Support/MyGit/LocalAI/`.
enum LocalAIPaths {
    static var root: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("MyGit/LocalAI", isDirectory: true)
    }
    static var models: URL { root.appendingPathComponent("models", isDirectory: true) }
    static var runtime: URL { root.appendingPathComponent("runtime", isDirectory: true) }
    /// `llama-server` of the pinned release (the tarball unpacks to `llama-<build>/`).
    static var serverBinary: URL {
        runtime.appendingPathComponent("llama-\(LocalModelCatalog.runtimeBuild)/llama-server")
    }
    static func modelFile(_ spec: LocalModelSpec) -> URL { models.appendingPathComponent(spec.fileName) }

    static var isRuntimeInstalled: Bool { FileManager.default.isExecutableFile(atPath: serverBinary.path) }
    static func isInstalled(_ spec: LocalModelSpec) -> Bool {
        FileManager.default.fileExists(atPath: modelFile(spec).path)
    }
}

/// Runs llama.cpp's `llama-server` as a child process on a loopback port,
/// one model at a time, and hands out its OpenAI-compatible base URL. The
/// model is loaded on first use, swapped when another is asked for, and
/// unloaded after a while idle so it doesn't sit on gigabytes of memory.
actor LocalLLMServer {
    static let shared = LocalLLMServer()

    enum Failure: LocalizedError {
        case runtimeMissing
        case unknownModel(String)
        case modelMissing(String)
        case exited(String)
        case timedOut

        var errorDescription: String? {
            switch self {
            case .runtimeMissing:
                return "The local AI runtime isn't installed. Open Settings ▸ AI ▸ Local and download a model."
            case .unknownModel(let id):
                return "Unknown local model “\(id)”. Pick one in Settings ▸ AI ▸ Local."
            case .modelMissing(let name):
                return "\(name) isn't downloaded yet. Download it in Settings ▸ AI ▸ Local."
            case .exited(let log):
                return "The local AI server stopped: \(log)"
            case .timedOut:
                return "The local model took too long to load."
            }
        }
    }

    private var process: Process?
    private var modelID: String?
    private var baseURL: URL?
    private var starting: (id: String, task: Task<URL, Error>)?
    private var idleTimer: Task<Void, Never>?
    private var stderrTail = ""
    /// Unload after this long without a request.
    private let idleTimeout: UInt64 = 15 * 60

    /// For `terminateNow()` at app quit, which can't await the actor.
    private static let pidLock = NSLock()
    nonisolated(unsafe) private static var runningPID: pid_t = 0

    /// `http://127.0.0.1:<port>/v1` with `modelID` loaded.
    func baseURL(for modelID: String) async throws -> URL {
        touch()
        if let baseURL, self.modelID == modelID, process?.isRunning == true { return baseURL }
        if let starting, starting.id == modelID { return try await starting.task.value }
        let task = Task { try await self.start(modelID) }
        starting = (modelID, task)
        defer { if starting?.id == modelID { starting = nil } }
        return try await task.value
    }

    /// The model loaded right now, if any.
    func loadedModel() -> String? { process?.isRunning == true ? modelID : nil }

    func stop() {
        idleTimer?.cancel()
        idleTimer = nil
        if let process, process.isRunning { process.terminate() }
        process = nil
        modelID = nil
        baseURL = nil
        Self.setPID(0)
    }

    /// Kill the server synchronously (app termination).
    nonisolated static func terminateNow() {
        pidLock.lock()
        let pid = runningPID
        runningPID = 0
        pidLock.unlock()
        if pid > 0 { kill(pid, SIGTERM) }
    }

    // MARK: - Private

    private static func setPID(_ pid: pid_t) {
        pidLock.lock()
        runningPID = pid
        pidLock.unlock()
    }

    private func start(_ id: String) async throws -> URL {
        stop()
        guard let spec = LocalModelCatalog.model(id: id) else { throw Failure.unknownModel(id) }
        guard LocalAIPaths.isRuntimeInstalled else { throw Failure.runtimeMissing }
        let file = LocalAIPaths.modelFile(spec)
        guard FileManager.default.fileExists(atPath: file.path) else { throw Failure.modelMissing(spec.name) }

        let port = try Self.freePort()
        let p = Process()
        p.executableURL = LocalAIPaths.serverBinary
        p.currentDirectoryURL = LocalAIPaths.serverBinary.deletingLastPathComponent()
        p.arguments = [
            "--model", file.path,
            "--alias", spec.id,
            "--host", "127.0.0.1",
            "--port", String(port),
            "--ctx-size", String(spec.contextLength),
            "--n-gpu-layers", "999",
            "--parallel", "1",
            "--no-webui",
        ]
        let errPipe = Pipe()
        p.standardError = errPipe
        p.standardOutput = FileHandle.nullDevice
        stderrTail = ""
        errPipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            guard !data.isEmpty, let text = String(data: data, encoding: .utf8) else { return }
            Task { await self?.appendLog(text) }
        }
        try p.run()
        process = p
        modelID = id
        Self.setPID(p.processIdentifier)

        let url = URL(string: "http://127.0.0.1:\(port)/v1")!
        // Loading a model takes from a second to a minute or so.
        let health = URL(string: "http://127.0.0.1:\(port)/health")!
        let deadline = Date().addingTimeInterval(300)
        while Date() < deadline {
            guard p.isRunning else {
                stop()
                throw Failure.exited(Self.lastLines(stderrTail))
            }
            var req = URLRequest(url: health)
            req.timeoutInterval = 2
            if let (_, resp) = try? await URLSession.shared.data(for: req),
               (resp as? HTTPURLResponse)?.statusCode == 200 {
                baseURL = url
                touch()
                return url
            }
            try await Task.sleep(nanoseconds: 300_000_000)
        }
        stop()
        throw Failure.timedOut
    }

    private func appendLog(_ text: String) {
        stderrTail += text
        if stderrTail.count > 8000 { stderrTail = String(stderrTail.suffix(4000)) }
    }

    private func touch() {
        idleTimer?.cancel()
        let timeout = idleTimeout
        idleTimer = Task { [weak self] in
            try? await Task.sleep(nanoseconds: timeout * 1_000_000_000)
            guard !Task.isCancelled else { return }
            await self?.stop()
        }
    }

    private static func lastLines(_ log: String) -> String {
        let lines = log.split(whereSeparator: \.isNewline).suffix(4).joined(separator: " · ")
        return lines.isEmpty ? "no output" : lines
    }

    /// A loopback port nothing listens on (bind to 0, read it back, release).
    private static func freePort() throws -> Int {
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { throw Failure.exited("no socket") }
        defer { close(fd) }
        var addr = sockaddr_in()
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = 0
        addr.sin_addr.s_addr = inet_addr("127.0.0.1")
        var len = socklen_t(MemoryLayout<sockaddr_in>.size)
        let bound = withUnsafeMutablePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, len) == 0 && getsockname(fd, $0, &len) == 0 }
        }
        guard bound else { throw Failure.exited("no free port") }
        return Int(UInt16(bigEndian: addr.sin_port))
    }
}
