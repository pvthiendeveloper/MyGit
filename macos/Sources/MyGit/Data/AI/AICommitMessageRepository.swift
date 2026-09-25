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
        let raw = try await complete(config: config,
                                     system: Self.systemPrompt(includeBody: config.includeBody),
                                     user: userPrompt)
        return Self.parse(raw, includeBody: config.includeBody)
    }

    // MARK: - Pull request title + description

    private static let pullRequestRules = """
    You are a tool that writes GitHub/Bitbucket pull request descriptions.
    Given the commit subjects and unified diff of a branch, output a title and a description.
    Format your answer EXACTLY as:
    - Line 1: a concise, imperative PR title, <= 72 characters, no trailing period, no prefix like "Title:".
    - Line 2: blank.
    - From line 3: a Markdown description — a one-sentence summary, then a "## Changes" section \
    with bullet points of the notable changes. Keep it tight; do not invent things not in the diff.
    Do not wrap the output in code fences.
    """

    func generatePullRequest(diff: String, config: AIRequestConfig) async throws -> CommitSuggestion {
        let trimmed = diff.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw CommitMessageError.emptyDiff }
        guard !config.apiKey.isEmpty else { throw CommitMessageError.missingAPIKey }

        let userPrompt = "Write a pull request title and description for this change set:\n\n" + diff
        let raw = try await complete(config: config, system: Self.pullRequestRules, user: userPrompt)
        var suggestion = Self.parse(raw, includeBody: true)
        // Strip a stray leading Markdown heading on the title (e.g. "# Foo").
        var title = suggestion.summary
        while title.hasPrefix("#") { title.removeFirst() }
        suggestion = CommitSuggestion(summary: title.trimmingCharacters(in: .whitespaces), body: suggestion.body)
        return suggestion
    }

    // MARK: - Inline code completion

    private static let codeRules = """
    You are an inline code completion engine inside an editor.
    Continue the code at the <CARET> marker.
    Rules:
    - Output ONLY the text to insert at the caret. No explanation, no code fences, no repetition \
    of the code before the caret.
    - Keep it short: finish the current expression, statement, or at most a small block.
    - Match the surrounding style, indentation and language exactly.
    - If nothing sensible can be added, output nothing.
    """

    func completeCode(prefix: String, suffix: String, language: String,
                      config: AIRequestConfig) async throws -> String {
        guard !config.apiKey.isEmpty else { throw CommitMessageError.missingAPIKey }
        // Only the neighbourhood of the caret — whole files blow up the prompt
        // and slow the round trip down.
        let head = String(prefix.suffix(4000))
        let tail = String(suffix.prefix(1500))
        let user = """
        Language: \(language.isEmpty ? "unknown" : language)

        \(head)<CARET>\(tail)
        """
        let raw = try await complete(config: config, system: Self.codeRules, user: user)
        return Self.stripCodeFence(raw)
    }

    /// Models like to wrap answers in ``` fences even when told not to.
    private static func stripCodeFence(_ text: String) -> String {
        var lines = text.components(separatedBy: "\n")
        if lines.first?.trimmingCharacters(in: .whitespaces).hasPrefix("```") == true {
            lines.removeFirst()
            if let last = lines.last, last.trimmingCharacters(in: .whitespaces).hasPrefix("```") {
                lines.removeLast()
            }
        }
        return lines.joined(separator: "\n")
    }

    func ask(system: String, user: String, config: AIRequestConfig) async throws -> String {
        guard !config.apiKey.isEmpty else { throw CommitMessageError.missingAPIKey }
        return try await complete(config: config, system: system, user: user)
    }

    /// Dispatch a system+user completion to the configured provider.
    private func complete(config: AIRequestConfig, system: String, user: String) async throws -> String {
        if config.provider == .local {
            // Starts llama-server with the model on first use.
            let base = try await LocalLLMServer.shared.baseURL(for: config.model)
            let local = AIRequestConfig(provider: .local, model: config.model, baseURL: base.absoluteString,
                                        apiKey: config.apiKey, includeBody: config.includeBody)
            return Self.stripThinking(try await callOpenAI(config: local, system: system, user: user))
        }
        if config.provider.isOpenAICompatible {
            return try await callOpenAI(config: config, system: system, user: user)
        } else if config.provider == .anthropic {
            return try await callAnthropic(config: config, system: system, user: user)
        } else {
            return try await callGemini(config: config, system: system, user: user)
        }
    }

    // MARK: - Connection test

    func testConnection(config: AIRequestConfig) async throws -> String {
        let models = try await listModels(config: config)
        return "Connected — \(models.count) models available"
    }

    func listModels(config: AIRequestConfig) async throws -> [String] {
        if config.provider == .local {
            return LocalModelCatalog.models.filter(LocalAIPaths.isInstalled).map(\.id)
        }
        guard !config.apiKey.isEmpty else { throw CommitMessageError.missingAPIKey }
        if config.provider.isOpenAICompatible {
            return try await fetchOpenAIModels(config: config)
        } else if config.provider == .anthropic {
            return try await fetchAnthropicModels(config: config)
        } else {
            return try await fetchGeminiModels(config: config)
        }
    }

    /// OpenAI/compatible `GET /models` → `data[].id`.
    private func fetchOpenAIModels(config: AIRequestConfig) async throws -> [String] {
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
        let ids = (json?["data"] as? [[String: Any]])?
            .compactMap { $0["id"] as? String } ?? []
        return ids.sorted()
    }

    /// Gemini `GET /models?key=` → `models[].name` with the `models/` prefix stripped.
    private func fetchGeminiModels(config: AIRequestConfig) async throws -> [String] {
        let base = config.baseURL.trimmingCharacters(in: .whitespaces)
            .trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        guard let url = URL(string: "\(base)/models?key=\(config.apiKey)") else {
            throw CommitMessageError.badResponse("bad base URL")
        }
        let (data, resp) = try await session.data(for: URLRequest(url: url))
        try Self.checkStatus(resp, data)

        let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        let ids = (json?["models"] as? [[String: Any]])?
            .compactMap { $0["name"] as? String }
            .map { $0.hasPrefix("models/") ? String($0.dropFirst("models/".count)) : $0 } ?? []
        return ids.sorted()
    }

    // MARK: - OpenAI chat completions

    private func callOpenAI(config: AIRequestConfig, system: String, user: String) async throws -> String {
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
                ["role": "system", "content": system],
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

    private func callGemini(config: AIRequestConfig, system: String, user: String) async throws -> String {
        let base = config.baseURL.trimmingCharacters(in: .whitespaces)
            .trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        let path = "\(base)/models/\(config.model):generateContent?key=\(config.apiKey)"
        guard let url = URL(string: path) else {
            throw CommitMessageError.badResponse("bad base URL")
        }
        let body: [String: Any] = [
            "system_instruction": ["parts": [["text": system]]],
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

    // MARK: - Anthropic Messages API

    /// Anthropic version header required on every Messages API request.
    private static let anthropicVersion = "2023-06-01"

    /// Anthropic `GET /models` → `data[].id`.
    private func fetchAnthropicModels(config: AIRequestConfig) async throws -> [String] {
        let base = config.baseURL.trimmingCharacters(in: .whitespaces)
            .trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        guard let url = URL(string: base + "/models") else {
            throw CommitMessageError.badResponse("bad base URL")
        }
        var req = URLRequest(url: url)
        req.setValue(config.apiKey, forHTTPHeaderField: "x-api-key")
        req.setValue(Self.anthropicVersion, forHTTPHeaderField: "anthropic-version")

        let (data, resp) = try await session.data(for: req)
        try Self.checkStatus(resp, data)

        let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        let ids = (json?["data"] as? [[String: Any]])?
            .compactMap { $0["id"] as? String } ?? []
        return ids.sorted()
    }

    private func callAnthropic(config: AIRequestConfig, system: String, user: String) async throws -> String {
        let base = config.baseURL.trimmingCharacters(in: .whitespaces)
            .trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        guard let url = URL(string: base + "/messages") else {
            throw CommitMessageError.badResponse("bad base URL")
        }
        // Note: no `temperature` — deprecated/rejected on Opus 4.7+ (400).
        let body: [String: Any] = [
            "model": config.model,
            "max_tokens": 1024,
            "system": system,
            "messages": [
                ["role": "user", "content": user]
            ]
        ]
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue(config.apiKey, forHTTPHeaderField: "x-api-key")
        req.setValue(Self.anthropicVersion, forHTTPHeaderField: "anthropic-version")
        req.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, resp) = try await session.data(for: req)
        try Self.checkStatus(resp, data)

        // Response shape: { content: [ { type: "text", text: "…" }, … ] }
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let blocks = json["content"] as? [[String: Any]] else {
            throw CommitMessageError.badResponse(Self.snippet(data))
        }
        let text = blocks
            .filter { ($0["type"] as? String) == "text" }
            .compactMap { $0["text"] as? String }
            .joined()
        guard !text.isEmpty else { throw CommitMessageError.badResponse(Self.snippet(data)) }
        return text
    }

    // MARK: - Helpers

    /// Reasoning models (Qwen3, gpt-oss) may leave a `<think>…</think>`
    /// block in the content; the answer is what follows it.
    static func stripThinking(_ text: String) -> String {
        guard let end = text.range(of: "</think>") else { return text }
        return String(text[end.upperBound...]).trimmingCharacters(in: .whitespacesAndNewlines)
    }

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
