import Foundation

/// Type-aware Swift completion (`HStack(alignment: .` → `top`, `center`, …)
/// from the `sourcekit-lsp` that ships with Xcode. One server per package
/// root, started on first use and kept for the session.
///
/// Returns nil whenever it can't answer (no Xcode toolchain, server crashed,
/// request timed out) so the editor can fall back to word completion.
final class SwiftCompletionService: @unchecked Sendable {
    static let shared = SwiftCompletionService()

    private let lock = NSLock()
    private var clients: [String: SourceKitLSPClient] = [:]

    private init() {
        // Writing to a server that just died must fail with EPIPE, not kill the app.
        signal(SIGPIPE, SIG_IGN)
    }

    /// Completions at `caret` (UTF-16 offset) in `text`, the unsaved buffer of
    /// the file at `file`. `repoRoot` bounds the search for `Package.swift`.
    func completions(file: URL, repoRoot: URL?, text: String, caret: Int) async -> [CodeCompletionItem]? {
        guard let client = client(forRoot: Self.root(for: file, repoRoot: repoRoot)) else { return nil }
        let lines = LineIndex(text)
        let position = lines.position(of: caret)
        do {
            let result = try await client.completion(uri: file.absoluteURL.absoluteString, text: text,
                                                     line: position.line, character: position.character)
            return Self.items(from: result, lines: lines, caret: caret)
        } catch {
            if (error as? SourceKitLSPClient.Failure) == .exited { drop(client) }
            return nil
        }
    }

    // MARK: - Servers

    private func client(forRoot root: URL) -> SourceKitLSPClient? {
        lock.lock(); defer { lock.unlock() }
        if let existing = clients[root.path] { return existing }
        guard let client = SourceKitLSPClient(root: root) else { return nil }
        clients[root.path] = client
        return client
    }

    private func drop(_ client: SourceKitLSPClient) {
        lock.lock(); defer { lock.unlock() }
        clients = clients.filter { $0.value !== client }
    }

    /// The nearest directory holding a `Package.swift` (so SwiftPM supplies
    /// real build settings), else the repo root — sourcekit-lsp still answers
    /// SDK completions there with its fallback settings.
    static func root(for file: URL, repoRoot: URL?) -> URL {
        let fm = FileManager.default
        let stop = repoRoot?.standardizedFileURL.path
        var dir = file.deletingLastPathComponent().standardizedFileURL
        while true {
            if fm.fileExists(atPath: dir.appendingPathComponent("Package.swift").path) { return dir }
            if dir.path == stop || dir.path == "/" { break }
            dir = dir.deletingLastPathComponent()
        }
        return repoRoot ?? file.deletingLastPathComponent()
    }

    // MARK: - Mapping

    private static func items(from result: Any?, lines: LineIndex, caret: Int) -> [CodeCompletionItem] {
        let raw: [[String: Any]]
        if let list = result as? [String: Any] {
            raw = list["items"] as? [[String: Any]] ?? []
        } else {
            raw = result as? [[String: Any]] ?? []
        }
        let sorted = raw.sorted {
            ($0["sortText"] as? String ?? $0["label"] as? String ?? "")
                < ($1["sortText"] as? String ?? $1["label"] as? String ?? "")
        }
        return sorted.compactMap { item in
            guard let label = item["label"] as? String else { return nil }
            var insert = item["insertText"] as? String ?? label
            var range = NSRange(location: caret, length: 0)
            if let edit = item["textEdit"] as? [String: Any],
               let newText = edit["newText"] as? String,
               let r = edit["range"] as? [String: Any],
               let start = lines.offset(of: r["start"]), let end = lines.offset(of: r["end"]), start <= end {
                insert = newText
                range = NSRange(location: start, length: end - start)
            }
            return CodeCompletionItem(label: label, insertText: insert,
                                      detail: item["detail"] as? String, replaceRange: range)
        }
    }

    /// LSP positions are (line, UTF-16 column); `NSString` offsets are UTF-16 too.
    private struct LineIndex {
        private var starts: [Int] = [0]
        private let length: Int

        init(_ text: String) {
            let ns = text as NSString
            length = ns.length
            for i in 0..<length where ns.character(at: i) == 10 { starts.append(i + 1) }
        }

        func position(of offset: Int) -> (line: Int, character: Int) {
            // Last line start <= offset.
            var lo = 0, hi = starts.count - 1
            while lo < hi {
                let mid = (lo + hi + 1) / 2
                if starts[mid] <= offset { lo = mid } else { hi = mid - 1 }
            }
            return (lo, offset - starts[lo])
        }

        func offset(of position: Any?) -> Int? {
            guard let p = position as? [String: Any], let line = p["line"] as? Int,
                  let character = p["character"] as? Int, line < starts.count else { return nil }
            let offset = starts[line] + character
            return offset <= length ? offset : nil
        }
    }
}

/// A minimal JSON-RPC client for one `sourcekit-lsp` process: initialize,
/// full-text document sync, and `textDocument/completion`.
final class SourceKitLSPClient: @unchecked Sendable {
    enum Failure: Error, Equatable { case exited, timedOut, server(String) }

    private let process = Process()
    private let input: FileHandle
    private let writeQueue = DispatchQueue(label: "com.thienpham.MyGit.sourcekit-lsp.write")
    private let lock = NSLock()
    private var nextId = 1
    private var pending: [Int: (Result<Any?, Error>) -> Void] = [:]
    private var buffer = Data()
    private var exited = false
    /// Last text sent per document URI, with its version.
    private var documents: [String: (version: Int, text: String)] = [:]
    private var ready: Task<Void, Error>!

    /// First request loads the SDK's modules; later ones are milliseconds.
    private static let timeout: TimeInterval = 15

    init?(root: URL) {
        guard FileManager.default.isExecutableFile(atPath: "/usr/bin/xcrun") else { return nil }
        let stdin = Pipe(), stdout = Pipe()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/xcrun")
        process.arguments = ["sourcekit-lsp"]
        process.currentDirectoryURL = root
        process.standardInput = stdin
        process.standardOutput = stdout
        process.standardError = FileHandle.nullDevice
        input = stdin.fileHandleForWriting

        stdout.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let chunk = handle.availableData
            guard let self else { return }
            if chunk.isEmpty { self.terminate(); handle.readabilityHandler = nil; return }
            self.receive(chunk)
        }
        process.terminationHandler = { [weak self] _ in self?.terminate() }
        do { try process.run() } catch { return nil }

        ready = Task { [weak self] in
            guard let self else { throw Failure.exited }
            let params: [String: Any] = [
                "processId": Int(ProcessInfo.processInfo.processIdentifier),
                "rootUri": root.absoluteURL.absoluteString,
                "capabilities": [
                    "textDocument": ["completion": ["completionItem": ["snippetSupport": false]]],
                ],
                // No background `swift build` for indexing: completion only
                // needs build settings, and a surprise build is heavy.
                "initializationOptions": ["backgroundIndexing": false],
            ]
            _ = try await self.request("initialize", params)
            self.notify("initialized", [:])
        }
    }

    deinit {
        if process.isRunning { process.terminate() }
    }

    func completion(uri: String, text: String, line: Int, character: Int) async throws -> Any? {
        try await ready.value
        sync(uri: uri, text: text)
        return try await request("textDocument/completion", [
            "textDocument": ["uri": uri],
            "position": ["line": line, "character": character],
        ])
    }

    // MARK: - Documents

    /// Open the document, or replace its text when the buffer changed.
    private func sync(uri: String, text: String) {
        lock.lock()
        let previous = documents[uri]
        let version = (previous?.version ?? 0) + 1
        if previous?.text != text { documents[uri] = (version, text) }
        lock.unlock()
        if previous == nil {
            notify("textDocument/didOpen", [
                "textDocument": ["uri": uri, "languageId": "swift", "version": version, "text": text],
            ])
        } else if previous?.text != text {
            notify("textDocument/didChange", [
                "textDocument": ["uri": uri, "version": version],
                "contentChanges": [["text": text]],
            ])
        }
    }

    // MARK: - JSON-RPC

    private func request(_ method: String, _ params: [String: Any]) async throws -> Any? {
        try await withCheckedThrowingContinuation { cont in
            lock.lock()
            if exited { lock.unlock(); cont.resume(throwing: Failure.exited); return }
            let id = nextId
            nextId += 1
            pending[id] = { cont.resume(with: $0) }
            lock.unlock()
            send(["jsonrpc": "2.0", "id": id, "method": method, "params": params])
            DispatchQueue.global().asyncAfter(deadline: .now() + Self.timeout) { [weak self] in
                self?.complete(id, .failure(Failure.timedOut))
            }
        }
    }

    private func notify(_ method: String, _ params: [String: Any]) {
        send(["jsonrpc": "2.0", "method": method, "params": params])
    }

    private func send(_ message: [String: Any]) {
        guard let body = try? JSONSerialization.data(withJSONObject: message) else { return }
        writeQueue.async { [input] in
            var frame = Data("Content-Length: \(body.count)\r\n\r\n".utf8)
            frame.append(body)
            try? input.write(contentsOf: frame)
        }
    }

    /// Resolve a pending request once (a reply racing its timeout is dropped).
    private func complete(_ id: Int, _ result: Result<Any?, Error>) {
        lock.lock()
        let callback = pending.removeValue(forKey: id)
        lock.unlock()
        callback?(result)
    }

    /// Accumulate stdout and dispatch every complete `Content-Length` frame.
    private func receive(_ chunk: Data) {
        buffer.append(chunk)
        let separator = Data("\r\n\r\n".utf8)
        while let headerEnd = buffer.range(of: separator) {
            let header = String(decoding: buffer[buffer.startIndex..<headerEnd.lowerBound], as: UTF8.self)
            guard let length = header.split(separator: "\r\n")
                .first(where: { $0.lowercased().hasPrefix("content-length:") })
                .flatMap({ Int($0.split(separator: ":")[1].trimmingCharacters(in: .whitespaces)) })
            else { buffer.removeAll(); return }
            let bodyStart = headerEnd.upperBound
            guard buffer.distance(from: bodyStart, to: buffer.endIndex) >= length else { return }
            let bodyEnd = buffer.index(bodyStart, offsetBy: length)
            let body = buffer[bodyStart..<bodyEnd]
            buffer = Data(buffer[bodyEnd...])
            if let message = try? JSONSerialization.jsonObject(with: body) as? [String: Any] {
                handle(message)
            }
        }
    }

    private func handle(_ message: [String: Any]) {
        if message["method"] != nil {
            // A request from the server (progress, capability registration):
            // acknowledge it so the server never waits on us. Notifications
            // (logs, diagnostics) are ignored.
            if let id = message["id"] { send(["jsonrpc": "2.0", "id": id, "result": NSNull()]) }
            return
        }
        guard let id = message["id"] as? Int else { return }
        if let error = message["error"] as? [String: Any] {
            complete(id, .failure(Failure.server(error["message"] as? String ?? "error")))
        } else {
            let result = message["result"]
            complete(id, .success(result is NSNull ? nil : result))
        }
    }

    private func terminate() {
        lock.lock()
        exited = true
        let callbacks = pending.values
        pending.removeAll()
        lock.unlock()
        callbacks.forEach { $0(.failure(Failure.exited)) }
    }
}
