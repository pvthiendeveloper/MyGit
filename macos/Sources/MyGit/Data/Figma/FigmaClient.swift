import Foundation

/// The slice of a Figma node the UI Inspector compares against: geometry,
/// auto layout, corners, fills, text.
struct FigmaNode: Decodable {
    struct Box: Decodable { let x, y, width, height: Double }
    struct Paint: Decodable {
        struct RGBA: Decodable { let r, g, b, a: Double }
        let type: String
        let visible: Bool?
        let color: RGBA?
        let opacity: Double?
    }
    struct TextStyle: Decodable { let fontSize: Double?; let fontFamily: String?; let fontWeight: Double? }

    let id: String
    let name: String
    let type: String
    let visible: Bool?
    let absoluteBoundingBox: Box?
    let children: [FigmaNode]?
    let layoutMode: String?          // NONE | HORIZONTAL | VERTICAL
    let paddingLeft, paddingRight, paddingTop, paddingBottom: Double?
    let itemSpacing: Double?
    let cornerRadius: Double?
    let fills: [Paint]?
    let style: TextStyle?
    let characters: String?

    /// This node and everything under it that's visible, depth first.
    var flattened: [FigmaNode] {
        guard visible != false else { return [] }
        return [self] + (children ?? []).flatMap(\.flattened)
    }

    /// The first visible solid fill as `RRGGBB`.
    var solidFillHex: String? {
        guard let paint = fills?.first(where: { $0.type == "SOLID" && $0.visible != false }), let c = paint.color else { return nil }
        func hex(_ v: Double) -> String { String(format: "%02X", Int((max(0, min(1, v)) * 255).rounded())) }
        return hex(c.r) + hex(c.g) + hex(c.b)
    }
}

enum FigmaError: LocalizedError {
    case badLink
    case noToken
    case http(Int, String)
    case missingNode

    var errorDescription: String? {
        switch self {
        case .badLink: return "That isn't a Figma frame link (it needs a file and a node-id)."
        case .noToken: return "Add a Figma personal access token first (Figma ▸ Set Token…)."
        case let .http(code, message): return "Figma answered \(code): \(message)"
        case .missingNode: return "Figma didn't return that node."
        }
    }
}

/// Figma's REST API, with a personal access token.
struct FigmaClient {
    let token: String

    /// `https://www.figma.com/design/<key>/<name>?node-id=12-345` → (key, "12:345").
    static func parse(_ link: String) -> (fileKey: String, nodeID: String)? {
        guard let url = URL(string: link.trimmingCharacters(in: .whitespacesAndNewlines)),
              url.host?.hasSuffix("figma.com") == true else { return nil }
        let parts = url.pathComponents
        guard let index = parts.firstIndex(where: { ["design", "file", "proto"].contains($0) }), index + 1 < parts.count,
              let nodeParam = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?
                .first(where: { $0.name == "node-id" })?.value else { return nil }
        return (parts[index + 1], nodeParam.replacingOccurrences(of: "-", with: ":"))
    }

    func node(fileKey: String, nodeID: String) async throws -> FigmaNode {
        struct Response: Decodable {
            struct Entry: Decodable { let document: FigmaNode }
            let nodes: [String: Entry?]
        }
        let id = nodeID.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? nodeID
        let data = try await get("https://api.figma.com/v1/files/\(fileKey)/nodes?ids=\(id)")
        guard let node = try JSONDecoder().decode(Response.self, from: data).nodes[nodeID]??.document else {
            throw FigmaError.missingNode
        }
        return node
    }

    /// The node rendered as PNG at `scale`.
    func image(fileKey: String, nodeID: String, scale: Double = 2) async throws -> Data {
        struct Response: Decodable { let images: [String: String?] }
        let id = nodeID.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? nodeID
        let data = try await get("https://api.figma.com/v1/images/\(fileKey)?ids=\(id)&scale=\(scale)&format=png")
        guard let link = try JSONDecoder().decode(Response.self, from: data).images[nodeID] ?? nil,
              let url = URL(string: link) else { throw FigmaError.missingNode }
        return try await URLSession.shared.data(from: url).0
    }

    private func get(_ address: String) async throws -> Data {
        guard let url = URL(string: address) else { throw FigmaError.badLink }
        var request = URLRequest(url: url)
        request.setValue(token, forHTTPHeaderField: "X-Figma-Token")
        let (data, response) = try await URLSession.shared.data(for: request)
        let code = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard code == 200 else {
            let message = (try? JSONSerialization.jsonObject(with: data) as? [String: Any])?["err"] as? String
                ?? String(decoding: data.prefix(200), as: UTF8.self)
            throw FigmaError.http(code, message)
        }
        return data
    }
}
