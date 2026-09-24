import Foundation
import Network

/// What the editor has selected, in the shape Claude Code's IDE protocol uses:
/// absolute path, 0-based line / UTF-16 character positions (like VS Code).
struct ClaudeIDESelection: Equatable {
    struct Position: Equatable {
        let line: Int
        let character: Int
    }

    let filePath: String
    let text: String
    let start: Position
    let end: Position

    var isEmpty: Bool { start == end }
}

/// One open editor tab, as `getOpenEditors` reports it.
struct ClaudeIDEEditor {
    let filePath: String
    let isActive: Bool
    let isDirty: Bool
}

/// The app side the server calls back into (open a file, list tabs, save).
@MainActor
protocol ClaudeIDEHost: AnyObject {
    func ideOpenEditors() -> [ClaudeIDEEditor]
    func ideOpenFile(_ path: String, line: Int?)
    func ideIsDirty(_ path: String) -> Bool?
    func ideSave(_ path: String) async -> Bool
}

/// Makes MyGit an "IDE" for Claude Code, the way the VS Code and JetBrains
/// plugins do: a local MCP server over WebSocket, advertised through a lock file
/// in `~/.claude/ide/<port>.lock`. Claude Code started in MyGit's terminal
/// connects on its own (the terminal exports `CLAUDE_CODE_SSE_PORT`); one
/// started elsewhere inside a workspace repo finds it through `/ide`.
///
/// Once connected, Claude sees what's selected in the editor
/// (`selection_changed`), can ask for it (`getCurrentSelection`), open files,
/// and receive ⌥⌘K @-mentions (`at_mentioned`).
final class ClaudeIDEServer: @unchecked Sendable {
    static let shared = ClaudeIDEServer()

    private let queue = DispatchQueue(label: "com.thienpham.MyGit.claude-ide")
    /// Port and token survive relaunches: a Claude session that lost MyGit
    /// (rebuild, restart) retries the same URL + token and reconnects by
    /// itself, instead of needing `/ide` again.
    private static let portKey = "MyGit.claudeIDE.port"
    private static let tokenKey = "MyGit.claudeIDE.token"
    private let authToken: String = {
        if let saved = UserDefaults.standard.string(forKey: tokenKey), !saved.isEmpty { return saved }
        let fresh = UUID().uuidString
        UserDefaults.standard.set(fresh, forKey: tokenKey)
        return fresh
    }()
    private var listener: NWListener?
    /// Connections that completed the MCP `initialize` handshake.
    private var clients: [ObjectIdentifier: NWConnection] = [:]
    private var pending: [ObjectIdentifier: NWConnection] = [:]
    private var latestSelection: ClaudeIDESelection?
    private var workspaceFolders: [String] = []
    private var lockFiles: [URL] = []

    private let stateLock = NSLock()
    private var _port: UInt16?
    private var _connectedCount = 0

    @MainActor weak var host: ClaudeIDEHost?

    /// Called on the main queue whenever the number of connected Claude
    /// sessions changes.
    var onConnectionsChanged: ((Int) -> Void)?

    /// Listening port once the server is up.
    var port: UInt16? {
        stateLock.lock(); defer { stateLock.unlock() }
        return _port
    }

    var connectedCount: Int {
        stateLock.lock(); defer { stateLock.unlock() }
        return _connectedCount
    }

    /// Variables for terminal sessions, so `claude` run there connects to
    /// MyGit without `/ide`.
    var terminalEnvironment: [String] {
        guard let port else { return [] }
        return ["CLAUDE_CODE_SSE_PORT=\(port)", "ENABLE_IDE_INTEGRATION=true"]
    }

    // MARK: - Lifecycle

    func start() {
        queue.sync {
            removeStaleLockFiles()
            startOnQueue()
        }
    }

    func stop() {
        queue.sync {
            listener?.cancel()
            listener = nil
            for conn in clients.values { conn.cancel() }
            for conn in pending.values { conn.cancel() }
            clients.removeAll()
            pending.removeAll()
            removeLockFiles()
            setPort(nil)
        }
    }

    /// Repos of the open workspace; Claude Code started inside one of them
    /// offers MyGit in `/ide`.
    func setWorkspaceFolders(_ folders: [String]) {
        queue.async {
            guard folders != self.workspaceFolders else { return }
            self.workspaceFolders = folders
            self.writeLockFiles()
        }
    }

    private func startOnQueue() {
        guard listener == nil else { return }
        let saved = UInt16(exactly: UserDefaults.standard.integer(forKey: Self.portKey)).flatMap(NWEndpoint.Port.init(rawValue:))
        listen(on: saved ?? .any, fallbackToAny: saved != nil)
    }

    /// Bind `port`; if it's taken (another app, or a MyGit still shutting
    /// down), take any free one and remember that instead.
    private func listen(on port: NWEndpoint.Port, fallbackToAny: Bool) {
        let ws = NWProtocolWebSocket.Options()
        ws.autoReplyPing = true
        ws.maximumMessageSize = 16 * 1024 * 1024
        let token = authToken
        ws.setClientRequestHandler(queue) { subprotocols, headers in
            // Only Claude Code, which read the token from our lock file.
            let authorized = headers.contains {
                $0.name.caseInsensitiveCompare("x-claude-code-ide-authorization") == .orderedSame && $0.value == token
            }
            return NWProtocolWebSocket.Response(
                status: authorized ? .accept : .reject,
                subprotocol: subprotocols.contains("mcp") ? "mcp" : nil,
                additionalHeaders: nil
            )
        }
        let params = NWParameters.tcp
        params.defaultProtocolStack.applicationProtocols.insert(ws, at: 0)
        // Loopback only: nothing off this machine should reach the editor.
        params.requiredLocalEndpoint = NWEndpoint.hostPort(host: "127.0.0.1", port: port)
        params.allowLocalEndpointReuse = true

        guard let listener = try? NWListener(using: params) else { return }
        self.listener = listener
        listener.stateUpdateHandler = { [weak self] state in
            guard let self else { return }
            switch state {
            case .ready:
                self.setPort(listener.port?.rawValue)
                if let bound = listener.port?.rawValue {
                    UserDefaults.standard.set(Int(bound), forKey: Self.portKey)
                }
                self.writeLockFiles()
            case .failed where fallbackToAny && self.listener === listener:
                listener.cancel()
                self.listener = nil
                self.listen(on: .any, fallbackToAny: false)
            case .failed, .cancelled:
                // A replaced listener's late cancel mustn't take down the new one.
                guard self.listener === listener else { return }
                self.setPort(nil)
                self.removeLockFiles()
            default:
                break
            }
        }
        listener.newConnectionHandler = { [weak self] conn in self?.accept(conn) }
        listener.start(queue: queue)
    }

    private func setPort(_ port: UInt16?) {
        stateLock.lock(); _port = port; stateLock.unlock()
    }

    // MARK: - Lock file

    /// `~/.claude/ide` is always searched; a `CLAUDE_CONFIG_DIR` MyGit itself
    /// was launched with gets a copy too.
    private func lockDirectories() -> [URL] {
        let home = FileManager.default.homeDirectoryForCurrentUser
        var dirs = [home.appendingPathComponent(".claude/ide", isDirectory: true)]
        if let config = ProcessInfo.processInfo.environment["CLAUDE_CONFIG_DIR"], !config.isEmpty {
            let dir = URL(fileURLWithPath: (config as NSString).expandingTildeInPath)
                .appendingPathComponent("ide", isDirectory: true)
            if dir.standardizedFileURL != dirs[0].standardizedFileURL { dirs.append(dir) }
        }
        return dirs
    }

    private func writeLockFiles() {
        guard let port else { return }
        let payload: [String: Any] = [
            "pid": Int(ProcessInfo.processInfo.processIdentifier),
            "workspaceFolders": workspaceFolders,
            "ideName": "MyGit",
            "transport": "ws",
            "runningInWindows": false,
            "authToken": authToken,
        ]
        guard let data = try? JSONSerialization.data(withJSONObject: payload, options: [.withoutEscapingSlashes]) else { return }
        let fm = FileManager.default
        var written: [URL] = []
        for dir in lockDirectories() {
            try? fm.createDirectory(at: dir, withIntermediateDirectories: true,
                                    attributes: [.posixPermissions: 0o700])
            let file = dir.appendingPathComponent("\(port).lock")
            // Holds the auth token: owner-only.
            if fm.createFile(atPath: file.path, contents: data, attributes: [.posixPermissions: 0o600]) {
                written.append(file)
            }
        }
        lockFiles = written
    }

    /// Lock files of earlier MyGit runs that died without cleaning up (a
    /// crash, `kill -9`). Claude Code would otherwise list a dead MyGit.
    private func removeStaleLockFiles() {
        let fm = FileManager.default
        for dir in lockDirectories() {
            for name in (try? fm.contentsOfDirectory(atPath: dir.path)) ?? [] where name.hasSuffix(".lock") {
                let file = dir.appendingPathComponent(name)
                guard let data = fm.contents(atPath: file.path),
                      let lock = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                      lock["ideName"] as? String == "MyGit",
                      let pid = lock["pid"] as? Int else { continue }
                if kill(pid_t(pid), 0) != 0 && errno == ESRCH { try? fm.removeItem(at: file) }
            }
        }
    }

    private func removeLockFiles() {
        for file in lockFiles { try? FileManager.default.removeItem(at: file) }
        lockFiles = []
    }

    // MARK: - Connections

    private func accept(_ conn: NWConnection) {
        let key = ObjectIdentifier(conn)
        pending[key] = conn
        conn.stateUpdateHandler = { [weak self, weak conn] state in
            guard let self, let conn else { return }
            switch state {
            case .failed, .cancelled:
                self.drop(conn)
            default:
                break
            }
        }
        conn.start(queue: queue)
        receive(on: conn)
    }

    private func drop(_ conn: NWConnection) {
        let key = ObjectIdentifier(conn)
        pending.removeValue(forKey: key)
        if clients.removeValue(forKey: key) != nil { connectionsChanged() }
    }

    private func connectionsChanged() {
        let count = clients.count
        stateLock.lock(); _connectedCount = count; stateLock.unlock()
        DispatchQueue.main.async { [weak self] in self?.onConnectionsChanged?(count) }
    }

    private func receive(on conn: NWConnection) {
        conn.receiveMessage { [weak self, weak conn] data, context, _, error in
            guard let self, let conn else { return }
            if error != nil {
                conn.cancel()
                return
            }
            let metadata = context?.protocolMetadata(definition: NWProtocolWebSocket.definition)
                as? NWProtocolWebSocket.Metadata
            if metadata?.opcode == .close {
                conn.cancel()
                return
            }
            if let data, !data.isEmpty, metadata?.opcode == .text || metadata?.opcode == .binary {
                self.handle(data, from: conn)
            }
            self.receive(on: conn)
        }
    }

    private func send(_ object: [String: Any], to conn: NWConnection) {
        guard let data = try? JSONSerialization.data(withJSONObject: object, options: [.withoutEscapingSlashes]) else { return }
        let metadata = NWProtocolWebSocket.Metadata(opcode: .text)
        let context = NWConnection.ContentContext(identifier: "mcp", metadata: [metadata])
        conn.send(content: data, contentContext: context, isComplete: true, completion: .idempotent)
    }

    private func broadcast(method: String, params: [String: Any]) {
        let message: [String: Any] = ["jsonrpc": "2.0", "method": method, "params": params]
        for conn in clients.values { send(message, to: conn) }
    }

    // MARK: - Editor events

    /// The editor's selection (or caret) moved. Sent to every connected Claude
    /// session and kept for `getLatestSelection`.
    func publishSelection(_ selection: ClaudeIDESelection) {
        queue.async {
            guard selection != self.latestSelection else { return }
            self.latestSelection = selection
            self.broadcast(method: "selection_changed", params: Self.selectionPayload(selection))
        }
    }

    /// ⌥⌘K: put an @-mention of the file (and lines) into Claude's prompt.
    /// Lines are 0-based, like the rest of the protocol.
    func mention(filePath: String, lineStart: Int?, lineEnd: Int?) {
        queue.async {
            var params: [String: Any] = ["filePath": filePath]
            if let lineStart { params["lineStart"] = lineStart }
            if let lineEnd { params["lineEnd"] = lineEnd }
            self.broadcast(method: "at_mentioned", params: params)
        }
    }

    private static func selectionPayload(_ s: ClaudeIDESelection) -> [String: Any] {
        [
            "text": s.text,
            "filePath": s.filePath,
            "fileUrl": URL(fileURLWithPath: s.filePath).absoluteString,
            "selection": [
                "start": ["line": s.start.line, "character": s.start.character],
                "end": ["line": s.end.line, "character": s.end.character],
                "isEmpty": s.isEmpty,
            ],
        ]
    }

    // MARK: - JSON-RPC

    private func handle(_ data: Data, from conn: NWConnection) {
        guard let object = try? JSONSerialization.jsonObject(with: data) else { return }
        // JSON-RPC batches are allowed; Claude Code doesn't send them, but be lenient.
        let messages = (object as? [[String: Any]]) ?? [(object as? [String: Any]) ?? [:]]
        for message in messages { handleMessage(message, from: conn) }
    }

    private func handleMessage(_ message: [String: Any], from conn: NWConnection) {
        guard let method = message["method"] as? String else { return }   // a response to us: ignore
        let id = message["id"]
        let params = message["params"] as? [String: Any] ?? [:]

        func reply(_ result: [String: Any]) {
            guard let id else { return }
            send(["jsonrpc": "2.0", "id": id, "result": result], to: conn)
        }
        func fail(_ code: Int, _ text: String) {
            guard let id else { return }
            send(["jsonrpc": "2.0", "id": id, "error": ["code": code, "message": text]], to: conn)
        }

        switch method {
        case "initialize":
            reply([
                "protocolVersion": params["protocolVersion"] as? String ?? "2025-06-18",
                "capabilities": ["tools": ["listChanged": false]],
                "serverInfo": ["name": "MyGit", "version": "1.0"],
            ])
            let key = ObjectIdentifier(conn)
            pending.removeValue(forKey: key)
            if clients[key] == nil {
                clients[key] = conn
                connectionsChanged()
            }
            // Catch the new session up on what's selected right now.
            if let selection = latestSelection {
                send(["jsonrpc": "2.0", "method": "selection_changed",
                      "params": Self.selectionPayload(selection)], to: conn)
            }
        case "ping":
            reply([:])
        case "tools/list":
            reply(["tools": Self.tools])
        case "tools/call":
            let name = params["name"] as? String ?? ""
            let args = params["arguments"] as? [String: Any] ?? [:]
            callTool(name, args) { result in
                if let result {
                    reply(result)
                } else {
                    fail(-32601, "Tool not supported by MyGit: \(name)")
                }
            }
        case "prompts/list":
            reply(["prompts": []])
        case "resources/list":
            reply(["resources": []])
        default:
            if id != nil { fail(-32601, "Method not found: \(method)") }
            // Notifications (initialized, ide_connected, log_event…) need no answer.
        }
    }

    private static func text(_ string: String) -> [String: Any] {
        ["content": [["type": "text", "text": string]]]
    }

    private static func json(_ object: Any) -> [String: Any] {
        let data = (try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys, .withoutEscapingSlashes])) ?? Data()
        return text(String(decoding: data, as: UTF8.self))
    }

    /// Runs a tool and hands back the MCP result, or nil for unknown tools.
    /// Called on `queue`; `completion` runs on `queue` too.
    private func callTool(_ name: String, _ args: [String: Any],
                          completion: @escaping ([String: Any]?) -> Void) {
        func onMain(_ work: @escaping @MainActor (ClaudeIDEHost?) async -> [String: Any]?) {
            Task { @MainActor [weak self] in
                let result = await work(self?.host)
                self?.queue.async { completion(result) }
            }
        }

        switch name {
        case "getCurrentSelection", "getLatestSelection":
            if let selection = latestSelection {
                var payload = Self.selectionPayload(selection)
                payload["success"] = true
                completion(Self.json(payload))
            } else {
                completion(Self.json(["success": false, "message": "No selection in MyGit's editor"]))
            }

        case "getWorkspaceFolders":
            let folders = workspaceFolders.map {
                ["name": ($0 as NSString).lastPathComponent,
                 "uri": URL(fileURLWithPath: $0).absoluteString,
                 "path": $0]
            }
            completion(Self.json(["success": true, "folders": folders,
                                  "rootPath": workspaceFolders.first ?? ""]))

        case "getOpenEditors":
            onMain { host in
                let tabs = (host?.ideOpenEditors() ?? []).map { editor -> [String: Any] in
                    [
                        "uri": URL(fileURLWithPath: editor.filePath).absoluteString,
                        "isActive": editor.isActive,
                        "label": (editor.filePath as NSString).lastPathComponent,
                        "languageId": (editor.filePath as NSString).pathExtension,
                        "isDirty": editor.isDirty,
                    ]
                }
                return Self.json(["tabs": tabs])
            }

        case "openFile":
            guard let path = args["filePath"] as? String, !path.isEmpty else {
                completion(Self.text("filePath is required"))
                return
            }
            let absolute = Self.absolutePath(path, relativeTo: workspaceFolders.first)
            let line = (args["startText"] as? String).flatMap { Self.line(of: $0, in: absolute) }
            onMain { host in
                host?.ideOpenFile(absolute, line: line)
                return Self.text("Opened file: \(absolute)")
            }

        case "checkDocumentDirty":
            let path = Self.absolutePath(args["filePath"] as? String ?? "", relativeTo: workspaceFolders.first)
            onMain { host in
                guard let dirty = host?.ideIsDirty(path) else {
                    return Self.json(["success": false, "message": "Document not open: \(path)"])
                }
                return Self.json(["success": true, "filePath": path, "isDirty": dirty, "isUntitled": false])
            }

        case "saveDocument":
            let path = Self.absolutePath(args["filePath"] as? String ?? "", relativeTo: workspaceFolders.first)
            onMain { host in
                let saved = await host?.ideSave(path) ?? false
                return Self.json(["success": saved, "filePath": path,
                                  "saved": saved, "message": saved ? "Document saved" : "Document not open"])
            }

        case "getDiagnostics":
            // MyGit has no language server; "no problems" keeps Claude's
            // before/after-edit comparison quiet instead of timing out.
            completion(Self.text("[]"))

        case "close_tab", "closeAllDiffTabs":
            // Diffs stay in Claude's terminal UI (openDiff isn't offered).
            completion(Self.text("CLOSED"))

        default:
            completion(nil)
        }
    }

    private static func absolutePath(_ path: String, relativeTo root: String?) -> String {
        var path = path
        if path.hasPrefix("file://"), let url = URL(string: path) { path = url.path }
        if path.hasPrefix("/") { return path }
        guard let root else { return path }
        return (root as NSString).appendingPathComponent(path)
    }

    /// 1-based line of the first occurrence of `needle` in the file.
    private static func line(of needle: String, in path: String) -> Int? {
        guard !needle.isEmpty,
              let content = try? String(contentsOfFile: path, encoding: .utf8),
              let range = content.range(of: needle) else { return nil }
        return content[..<range.lowerBound].reduce(1) { $1 == "\n" ? $0 + 1 : $0 }
    }

    private static let tools: [[String: Any]] = [
        tool("getCurrentSelection", "Get the current text selection in MyGit's editor"),
        tool("getLatestSelection", "Get the most recent text selection in MyGit's editor"),
        tool("getOpenEditors", "List the files open in MyGit's editor"),
        tool("getWorkspaceFolders", "List the repositories open in MyGit"),
        tool("openFile", "Open a file in MyGit's editor", properties: [
            "filePath": ["type": "string", "description": "Path of the file to open"],
            "preview": ["type": "boolean"],
            "startText": ["type": "string", "description": "Text marking where to put the caret"],
            "endText": ["type": "string"],
            "selectToEndOfLine": ["type": "boolean"],
            "makeFrontmost": ["type": "boolean"],
        ], required: ["filePath"]),
        tool("checkDocumentDirty", "Check whether a file has unsaved changes in MyGit", properties: [
            "filePath": ["type": "string"],
        ], required: ["filePath"]),
        tool("saveDocument", "Save a file open in MyGit's editor", properties: [
            "filePath": ["type": "string"],
        ], required: ["filePath"]),
        tool("getDiagnostics", "Get diagnostics (MyGit has none)", properties: [
            "uri": ["type": "string"],
        ]),
        tool("close_tab", "Close a diff tab", properties: ["tab_name": ["type": "string"]]),
        tool("closeAllDiffTabs", "Close all diff tabs"),
    ]

    private static func tool(_ name: String, _ description: String,
                             properties: [String: Any] = [:], required: [String] = []) -> [String: Any] {
        var schema: [String: Any] = ["type": "object", "properties": properties]
        if !required.isEmpty { schema["required"] = required }
        return ["name": name, "description": description, "inputSchema": schema]
    }
}
