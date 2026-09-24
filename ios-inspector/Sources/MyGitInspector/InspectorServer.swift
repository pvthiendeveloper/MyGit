import Foundation
import Network
import UIKit

/// TCP listener advertised over Bonjour. Wire format, both directions: a
/// 4-byte big-endian length, then that many bytes of UTF-8 JSON.
///
/// Requests:  `{"id": 1, "method": "info" | "hierarchy" | "highlight", "params": {…}}`
/// Responses: `{"id": 1, "result": {…}}` or `{"id": 1, "error": "…"}`
final class InspectorServer {
    private let serviceName: String
    private let queue = DispatchQueue(label: "MyGitInspector.server")
    private var listener: NWListener?
    private var connections: [ObjectIdentifier: NWConnection] = [:]

    init(serviceName: String) {
        self.serviceName = serviceName
    }

    func start() {
        do {
            let listener = try NWListener(using: .tcp)
            listener.service = NWListener.Service(name: serviceName, type: MyGitInspector.serviceType)
            listener.newConnectionHandler = { [weak self] connection in self?.accept(connection) }
            listener.stateUpdateHandler = { state in
                if case let .failed(error) = state {
                    NSLog("[MyGitInspector] listener failed: \(error)")
                }
            }
            listener.start(queue: queue)
            self.listener = listener
        } catch {
            NSLog("[MyGitInspector] could not start: \(error)")
        }
    }

    func stop() {
        listener?.cancel()
        listener = nil
        queue.async {
            self.connections.values.forEach { $0.cancel() }
            self.connections.removeAll()
        }
    }

    // MARK: - Connections

    private func accept(_ connection: NWConnection) {
        let key = ObjectIdentifier(connection)
        connections[key] = connection
        connection.stateUpdateHandler = { [weak self] state in
            switch state {
            case .failed, .cancelled: self?.connections[key] = nil
            default: break
            }
        }
        connection.start(queue: queue)
        receiveFrame(on: connection)
    }

    private func receiveFrame(on connection: NWConnection) {
        connection.receive(minimumIncompleteLength: 4, maximumLength: 4) { [weak self] header, _, isComplete, error in
            guard let self, let header, header.count == 4, error == nil else {
                if isComplete || error != nil { connection.cancel() }
                return
            }
            let length = header.reduce(0) { $0 << 8 | Int($1) }
            guard length > 0, length < 16 << 20 else { connection.cancel(); return }
            connection.receive(minimumIncompleteLength: length, maximumLength: length) { body, _, _, error in
                guard let body, error == nil else { connection.cancel(); return }
                self.handle(body, on: connection)
                self.receiveFrame(on: connection)
            }
        }
    }

    private func handle(_ body: Data, on connection: NWConnection) {
        guard let request = try? JSONSerialization.jsonObject(with: body) as? [String: Any],
              let method = request["method"] as? String else { return }
        let id = request["id"] ?? NSNull()
        let params = request["params"] as? [String: Any] ?? [:]
        // UIKit only on the main thread; reply from there once done.
        DispatchQueue.main.async {
            var reply: [String: Any] = ["id": id]
            switch method {
            case "info":
                reply["result"] = HierarchyCapture.appInfo()
            case "hierarchy":
                let scale = params["scale"] as? Double
                reply["result"] = HierarchyCapture.capture(screenshotScale: scale.map { CGFloat($0) })
            case "highlight":
                let f = (params["frame"] as? [Any])?.compactMap { ($0 as? NSNumber)?.doubleValue } ?? []
                HierarchyCapture.highlight(
                    frame: f.count == 4 ? CGRect(x: f[0], y: f[1], width: f[2], height: f[3]) : nil,
                    windowIndex: (params["window"] as? NSNumber)?.intValue ?? 0
                )
                reply["result"] = [String: Any]()
            default:
                reply["error"] = "Unknown method \(method)"
            }
            self.send(reply, on: connection)
        }
    }

    private func send(_ message: [String: Any], on connection: NWConnection) {
        // JSONSerialization raises an ObjC exception (not a Swift error) on a
        // non-JSON value; check first so the inspector can never crash the app.
        var message = message
        if !JSONSerialization.isValidJSONObject(message) {
            message = ["id": message["id"] ?? NSNull(), "error": "Capture produced a non-JSON value"]
        }
        guard let body = try? JSONSerialization.data(withJSONObject: message) else { return }
        var frame = Data(count: 4)
        let length = UInt32(body.count).bigEndian
        withUnsafeBytes(of: length) { frame.replaceSubrange(0..<4, with: $0) }
        frame.append(body)
        connection.send(content: frame, completion: .contentProcessed { _ in })
    }
}
