import AppKit
import Network

/// Finds iOS apps running the MyGitInspector agent (simulators on this Mac,
/// devices on the same network) via Bonjour.
final class InspectorBrowser {
    static let serviceType = "_mygitinspect._tcp"

    private var browser: NWBrowser?
    private let queue = DispatchQueue(label: "com.thienpham.MyGit.inspector.browse")

    /// Called on the main queue with the current list, sorted by name.
    func start(onChange: @escaping ([InspectorService]) -> Void) {
        stop()
        let browser = NWBrowser(for: .bonjour(type: Self.serviceType, domain: nil), using: .tcp)
        browser.browseResultsChangedHandler = { results, _ in
            let names = Set(results.compactMap { result -> String? in
                if case let .service(name, _, _, _) = result.endpoint { return name }
                return nil
            })
            let services = names.sorted().map(InspectorService.init(name:))
            DispatchQueue.main.async { onChange(services) }
        }
        browser.start(queue: queue)
        self.browser = browser
    }

    func stop() {
        browser?.cancel()
        browser = nil
    }
}

/// One connection to an app's agent. Wire format both ways: 4-byte
/// big-endian length + UTF-8 JSON; responses carry the request's `id`.
final class InspectorConnection: @unchecked Sendable {
    enum Failure: LocalizedError {
        case closed, timedOut, remote(String), badResponse

        var errorDescription: String? {
            switch self {
            case .closed: return "The app closed the inspector connection."
            case .timedOut: return "The app didn't answer in time."
            case let .remote(message): return message
            case .badResponse: return "The app sent a response MyGit couldn't read."
            }
        }
    }

    let service: InspectorService
    private let connection: NWConnection
    private let queue = DispatchQueue(label: "com.thienpham.MyGit.inspector.connection")
    private let lock = NSLock()
    private var nextId = 1
    private var pending: [Int: (Result<Data, Error>) -> Void] = [:]
    private var closed = false
    /// Called on the main queue once, when the connection drops.
    var onClose: (() -> Void)?

    private static let timeout: TimeInterval = 20

    init(service: InspectorService) {
        self.service = service
        connection = NWConnection(
            to: .service(name: service.name, type: InspectorBrowser.serviceType, domain: "local.", interface: nil),
            using: .tcp
        )
        connection.stateUpdateHandler = { [weak self] state in
            switch state {
            case .failed, .cancelled: self?.close()
            default: break
            }
        }
        connection.start(queue: queue)
        receiveFrame()
    }

    deinit { connection.cancel() }

    func cancel() { connection.cancel() }

    // MARK: - Requests

    func info() async throws -> InspectorAppInfo {
        try await request("info", [:], as: InspectorAppInfo.self)
    }

    func hierarchy() async throws -> InspectorSnapshot {
        let result = try await request("hierarchy", [:], as: HierarchyResult.self)
        var windows: [InspectorWindow] = []
        for w in result.windows {
            guard let nodes = w.nodes, let rootID = w.root else {
                // Protocol 1 sent nested JSON that could overflow the stack.
                throw Failure.remote("This app runs an older MyGitInspector. Rebuild it to pick up the current agent.")
            }
            guard let root = InspectorNode.tree(from: nodes, root: rootID) else { throw Failure.badResponse }
            windows.append(InspectorWindow(
                root: root,
                size: w.size.count == 2 ? CGSize(width: w.size[0], height: w.size[1]) : root.frame.size,
                isKey: w.key ?? false,
                image: w.png.flatMap { Data(base64Encoded: $0) }.flatMap(NSImage.init(data:))
            ))
        }
        return InspectorSnapshot(windows: windows, info: result.info, takenAt: Date())
    }

    /// Outline a frame (window coordinates) on the device itself; nil removes
    /// the outline. Frames rather than ids, so SwiftUI nodes work too.
    func highlight(_ target: (frame: CGRect, window: Int)?) async throws {
        var params: [String: Any] = [:]
        if let target {
            let f = target.frame
            params = ["frame": [f.minX, f.minY, f.width, f.height], "window": target.window]
        }
        _ = try await request("highlight", params, as: Empty.self)
    }

    private struct HierarchyResult: Decodable {
        struct Window: Decodable {
            let root: String?
            let nodes: [InspectorWireNode]?
            let size: [Double]
            let key: Bool?
            let png: String?
        }
        let windows: [Window]
        let info: InspectorAppInfo?
    }

    private struct Empty: Decodable {}

    private struct Envelope<T: Decodable>: Decodable {
        let result: T?
        let error: String?
    }

    private struct IDOnly: Decodable { let id: Int? }

    private func request<T: Decodable>(_ method: String, _ params: [String: Any], as type: T.Type) async throws -> T {
        let data: Data = try await withCheckedThrowingContinuation { cont in
            lock.lock()
            if closed { lock.unlock(); cont.resume(throwing: Failure.closed); return }
            let id = nextId
            nextId += 1
            pending[id] = { cont.resume(with: $0) }
            lock.unlock()
            send(["id": id, "method": method, "params": params])
            queue.asyncAfter(deadline: .now() + Self.timeout) { [weak self] in
                self?.complete(id, .failure(Failure.timedOut))
            }
        }
        // Decoding a big tree is real work; keep it off the main actor.
        return try await Task.detached(priority: .userInitiated) {
            let envelope = try JSONDecoder().decode(Envelope<T>.self, from: data)
            if let error = envelope.error { throw Failure.remote(error) }
            guard let result = envelope.result else { throw Failure.badResponse }
            return result
        }.value
    }

    private func send(_ message: [String: Any]) {
        guard let body = try? JSONSerialization.data(withJSONObject: message) else { return }
        var frame = Data()
        withUnsafeBytes(of: UInt32(body.count).bigEndian) { frame.append(contentsOf: $0) }
        frame.append(body)
        connection.send(content: frame, completion: .contentProcessed { _ in })
    }

    private func complete(_ id: Int, _ result: Result<Data, Error>) {
        lock.lock()
        let callback = pending.removeValue(forKey: id)
        lock.unlock()
        callback?(result)
    }

    // MARK: - Receiving

    private func receiveFrame() {
        connection.receive(minimumIncompleteLength: 4, maximumLength: 4) { [weak self] header, _, isComplete, error in
            guard let self else { return }
            guard let header, header.count == 4, error == nil else {
                if isComplete || error != nil { self.close() }
                return
            }
            let length = header.reduce(0) { $0 << 8 | Int($1) }
            guard length > 0, length < 256 << 20 else { self.close(); return }
            self.connection.receive(minimumIncompleteLength: length, maximumLength: length) { body, _, _, error in
                guard let body, body.count == length, error == nil else { self.close(); return }
                if let id = (try? JSONDecoder().decode(IDOnly.self, from: body))?.id {
                    self.complete(id, .success(body))
                }
                self.receiveFrame()
            }
        }
    }

    private func close() {
        lock.lock()
        guard !closed else { lock.unlock(); return }
        closed = true
        let callbacks = pending.values
        pending.removeAll()
        lock.unlock()
        callbacks.forEach { $0(.failure(Failure.closed)) }
        connection.cancel()
        DispatchQueue.main.async { [weak self] in self?.onClose?() }
    }
}
