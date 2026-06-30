import Foundation

/// Generates a commit message from a unified diff via an LLM provider.
protocol CommitMessageRepository: Sendable {
    func generate(diff: String, config: AIRequestConfig) async throws -> CommitSuggestion

    /// Validate that the provider is reachable with this config (key + base
    /// URL). Returns a short human-readable detail on success; throws on
    /// failure. Does not consume generation tokens.
    func testConnection(config: AIRequestConfig) async throws -> String

    /// Fetch the model IDs the provider exposes for this config. Used to
    /// populate the model picker with real options instead of hardcoded
    /// defaults. Throws on failure; does not consume generation tokens.
    func listModels(config: AIRequestConfig) async throws -> [String]
}

enum CommitMessageError: LocalizedError {
    case missingAPIKey
    case emptyDiff
    case badResponse(String)
    case httpError(Int, String)

    var errorDescription: String? {
        switch self {
        case .missingAPIKey:
            return "No API key set. Open Settings (⌘,) and add a key for your provider."
        case .emptyDiff:
            return "Nothing staged to summarize."
        case .badResponse(let s):
            return "AI returned an unexpected response: \(s)"
        case .httpError(let code, let body):
            return "AI request failed (HTTP \(code)): \(body)"
        }
    }
}
