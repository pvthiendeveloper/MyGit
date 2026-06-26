import Foundation

/// Calls an LLM provider's REST API to turn a unified diff into a
/// Conventional Commits message. OpenAI-compatible providers (OpenAI,
/// custom/9Router) share the chat-completions path; Gemini uses its own.
struct AICommitMessageRepository: CommitMessageRepository {
    private let session: URLSession

    init(session: URLSession = .shared) {
        self.session = session
    }

    private static let summaryRules = """
    You are a tool that writes git commit messages in the Conventional Commits format.
    Given a unified diff, output ONE commit message and nothing else.
    Rules:
    - First line: `<type>(<optional scope>): <summary>` where type is one of \
    feat, fix, docs, style, refactor, perf, test, build, ci, chore.
    - Summary: imperative mood, lower-case, no trailing period, <= 72 characters.
    - Do not wrap the message in code fences. Do not add commentary.
    """

    /// System prompt for the request. With a body, allow an explanatory
    /// paragraph; without, demand the summary line only.
    private static func systemPrompt(includeBody: Bool) -> String {
        if includeBody {
            return summaryRules + "\n"
                + "- Add a blank line then a concise body explaining the why, wrapped at ~72 cols."
        }
        return summaryRules + "\n"
            + "- Output ONLY the summary line. Do NOT add a body, blank line, or any extra lines."
    }

    func generate(diff: String, config: AIRequestConfig) async throws -> CommitSuggestion {
        let trimmedDiff = diff.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedDiff.isEmpty else { throw CommitMessageError.emptyDiff }
        guard !config.apiKey.isEmpty else { throw CommitMessageError.missingAPIKey }

        let userPrompt = "Write a commit message for this diff:\n\n" + diff

        let raw: String
        if config.provider.isOpenAICompatible {
            raw = try await callOpenAI(config: config, user: userPrompt)
        } else {
            raw = try await callGemini(config: config, user: userPrompt)
        }
        return Self.parse(raw, includeBody: config.includeBody)
    }

    // MARK: - Connection test

    func testConnection(config: AIRequestConfig) async throws -> String {
        guard !config.apiKey.isEmpty else { throw CommitMessageError.missingAPIKey }
        if config.provider.isOpenAICompatible {
            return try await listOpenAIModels(config: config)
        } else {
            return try await listGeminiModels(config: config)
        }
    }

    private func listOpenAIModels(config: AIRequestConfig) async throws -> String {
        let base = config.baseURL.trimmingCharacters(in: .whitespaces)
            .trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        guard let url = URL(string: base + "/models") else {
            throw CommitMessageError.badResponse("bad base URL")
        }
        var req = URLRequest(url: url)
        req.setValue("Bearer \(config.apiKey)", forHTTPHeaderField: "Authorization")

        let (data, resp) = try await session.data(for: req)
        try Self.checkStatus(resp, data)

        let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        let count = (json?["data"] as? [[String: Any]])?.count
        return count.map { "Connected — \($0) models available" } ?? "Connected"
    }

    private func listGeminiModels(config: AIRequestConfig) async throws -> String {
        let base = config.baseURL.trimmingCharacters(in: .whitespaces)
            .trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        guard let url = URL(string: "\(base)/models?key=\(config.apiKey)") else {
            throw CommitMessageError.badResponse("bad base URL")
        }
        let (data, resp) = try await session.data(for: URLRequest(url: url))
        try Self.checkStatus(resp, data)

        let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        let count = (json?["models"] as? [[String: Any]])?.count
        return count.map { "Connected — \($0) models available" } ?? "Connected"
    }

    // MARK: - OpenAI chat completions

    private func callOpenAI(config: AIRequestConfig, user: String) async throws -> String {
        let base = config.baseURL.trimmingCharacters(in: .whitespaces)
            .trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        guard let url = URL(string: base + "/chat/completions") else {
            throw CommitMessageError.badResponse("bad base URL")
        }
        let body: [String: Any] = [
            "model": config.model,
            "temperature": 0.2,
            "stream": false,
            "messages": [
                ["role": "system", "content": Self.systemPrompt(includeBody: config.includeBody)],
                ["role": "user", "content": user]
            ]
        ]
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue("Bearer \(config.apiKey)", forHTTPHeaderField: "Authorization")
        req.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, resp) = try await session.data(for: req)
        try Self.checkStatus(resp, data)

        if let content = Self.openAIContent(from: data) {
            return content
        }
        throw CommitMessageError.badResponse(Self.snippet(data))
    }

    /// Extract assistant text from an OpenAI chat-completions response.
    /// Handles both the non-streaming JSON shape (`choices[].message.content`)
    /// and an SSE stream (`data: {…delta.content…}` lines) — some
    /// OpenAI-compatible gateways (9Router) stream even when not asked to.
    static func openAIContent(from data: Data) -> String? {
        // Non-streaming: single JSON object with choices[].message.content.
        if let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let choices = json["choices"] as? [[String: Any]],
           let message = choices.first?["message"] as? [String: Any],
           let content = message["content"] as? String {
            return content
        }
        // Streaming: concatenate delta.content across `data:` SSE lines.
        guard let text = String(data: data, encoding: .utf8),
              text.contains("data:") else { return nil }
        var out = ""
        for rawLine in text.split(whereSeparator: \.isNewline) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            guard line.hasPrefix("data:") else { continue }
            let payload = line.dropFirst("data:".count).trimmingCharacters(in: .whitespaces)
            if payload == "[DONE]" { break }
            guard let chunk = payload.data(using: .utf8),
                  let json = try? JSONSerialization.jsonObject(with: chunk) as? [String: Any],
                  let choices = json["choices"] as? [[String: Any]],
                  let first = choices.first else { continue }
            // Streaming chunks carry `delta.content`; some send `message.content`.
            if let delta = first["delta"] as? [String: Any],
               let piece = delta["content"] as? String {
                out += piece
            } else if let message = first["message"] as? [String: Any],
                      let piece = message["content"] as? String {
                out += piece
            }
        }
        return out.isEmpty ? nil : out
    }

    // MARK: - Gemini generateContent

    private func callGemini(config: AIRequestConfig, user: String) async throws -> String {
        let base = config.baseURL.trimmingCharacters(in: .whitespaces)
            .trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        let path = "\(base)/models/\(config.model):generateContent?key=\(config.apiKey)"
        guard let url = URL(string: path) else {
            throw CommitMessageError.badResponse("bad base URL")
        }
        let body: [String: Any] = [
            "system_instruction": ["parts": [["text": Self.systemPrompt(includeBody: config.includeBody)]]],
            "contents": [["role": "user", "parts": [["text": user]]]],
            "generationConfig": ["temperature": 0.2]
        ]
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, resp) = try await session.data(for: req)
        try Self.checkStatus(resp, data)

        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let candidates = json["candidates"] as? [[String: Any]],
              let content = candidates.first?["content"] as? [String: Any],
              let parts = content["parts"] as? [[String: Any]],
              let text = parts.first?["text"] as? String else {
            throw CommitMessageError.badResponse(Self.snippet(data))
        }
        return text
    }

    // MARK: - Helpers

    private static func checkStatus(_ resp: URLResponse, _ data: Data) throws {
        guard let http = resp as? HTTPURLResponse else { return }
        guard (200..<300).contains(http.statusCode) else {
            throw CommitMessageError.httpError(http.statusCode, snippet(data))
        }
    }

    private static func snippet(_ data: Data) -> String {
        let s = String(data: data, encoding: .utf8) ?? ""
        return s.count > 300 ? String(s.prefix(300)) + "…" : s
    }

    /// Split the model output into summary (first non-empty line) and body,
    /// stripping any stray ``` code fences.
    static func parse(_ raw: String, includeBody: Bool = true) -> CommitSuggestion {
        var text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if text.hasPrefix("```") {
            let lines = text.split(separator: "\n", omittingEmptySubsequences: false)
                .drop { $0.hasPrefix("```") }
            text = lines.reversed().drop { $0.hasPrefix("```") }.reversed()
                .joined(separator: "\n")
                .trimmingCharacters(in: .whitespacesAndNewlines)
        }
        let parts = text.components(separatedBy: "\n")
        let summary = parts.first ?? ""
        // Drop any body the model produced anyway when bodies are disabled.
        guard includeBody else { return CommitSuggestion(summary: summary, body: "") }
        let body = parts.dropFirst()
            .joined(separator: "\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return CommitSuggestion(summary: summary, body: body)
    }
}
