import Foundation

/// AI provider used to auto-generate commit messages.
enum AIProvider: String, CaseIterable, Identifiable, Sendable {
    case openai
    case gemini
    case custom

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .openai: return "OpenAI"
        case .gemini: return "Google Gemini"
        case .custom: return "Custom (OpenAI-compatible)"
        }
    }

    /// Default REST base URL. For OpenAI-compatible providers this already
    /// includes the `/v1` suffix; the chat-completions path is appended.
    var defaultBaseURL: String {
        switch self {
        case .openai: return "https://api.openai.com/v1"
        case .gemini: return "https://generativelanguage.googleapis.com/v1beta"
        case .custom: return "http://localhost:20128/v1"
        }
    }

    var defaultModels: [String] {
        switch self {
        case .openai:
            return ["gpt-4o-mini", "gpt-4o", "gpt-4.1-mini", "gpt-4.1"]
        case .gemini:
            return ["gemini-2.0-flash", "gemini-2.5-flash", "gemini-2.5-pro"]
        case .custom:
            return ["cc/claude-opus-4-7", "kr/claude-sonnet-4.5", "glm/glm-5.1", "vertex/gemini-3.1-pro-preview"]
        }
    }

    /// Whether this provider speaks the OpenAI chat-completions wire format.
    var isOpenAICompatible: Bool {
        switch self {
        case .openai, .custom: return true
        case .gemini: return false
        }
    }

    /// Short label shown on the settings tab.
    var tabTitle: String {
        switch self {
        case .openai: return "OpenAI"
        case .gemini: return "Gemini"
        case .custom: return "Custom"
        }
    }

    /// SF Symbol shown on the settings tab.
    var tabIcon: String {
        switch self {
        case .openai: return "brain"
        case .gemini: return "sparkles"
        case .custom: return "slider.horizontal.3"
        }
    }

    /// Help text shown under the provider's settings form.
    var hint: String {
        switch self {
        case .openai: return "Key from platform.openai.com. Stored in your keychain."
        case .gemini: return "Key from aistudio.google.com. Stored in your keychain."
        case .custom: return "OpenAI-compatible endpoint (9Router, Ollama, OpenRouter…). Key stored in keychain."
        }
    }

    /// Keychain account key for this provider's API key. Namespaced so it
    /// never collides with git-host PATs stored in the same keychain service.
    var keychainAccount: String { "ai-key.\(rawValue)" }
}

/// Resolved request configuration handed to `CommitMessageRepository`.
struct AIRequestConfig: Sendable {
    let provider: AIProvider
    let model: String
    let baseURL: String
    let apiKey: String
    /// Whether to also generate a commit body/description. Default off —
    /// summary only.
    var includeBody: Bool = false
}

/// Result of a provider connection test, surfaced in Settings.
enum ConnectionTestStatus: Equatable {
    case idle
    case testing
    case success(String)
    case failure(String)
}

/// Parsed AI commit-message suggestion.
struct CommitSuggestion: Sendable {
    let summary: String
    let body: String
}
