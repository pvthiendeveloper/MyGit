import Foundation
import Combine

/// Holds AI commit-generation settings for every provider at once. Each
/// provider's model/base-URL persist in UserDefaults; API keys live in the
/// keychain (one per provider). `activeProvider` is the one used to generate
/// commit messages. The settings UI shows one tab per provider, so all three
/// are edited independently.
@MainActor
final class SettingsViewModel: ObservableObject {
    /// Provider used to generate commit messages.
    @Published private(set) var activeProvider: AIProvider

    /// Per-provider editable state, keyed by `AIProvider.rawValue`.
    @Published var models: [String: String]
    @Published var baseURLs: [String: String]
    /// Working copies of keychain keys (persisted via `saveKey(for:)`).
    @Published var apiKeys: [String: String]

    /// Whether AI generation also fills in a commit body/description.
    /// Off by default — most commits only need a summary.
    @Published var generateBody: Bool {
        didSet { defaults.set(generateBody, forKey: Keys.generateBody) }
    }

    /// Transient connection-test result per provider (not persisted).
    @Published var testStatus: [String: ConnectionTestStatus] = [:]

    private let credentials: CredentialRepository
    private let defaults: UserDefaults
    private let ai: CommitMessageRepository

    private enum Keys {
        static let provider = "MyGit.ai.provider"
        static let generateBody = "MyGit.ai.generateBody"
        static func model(_ p: AIProvider) -> String { "MyGit.ai.model.\(p.rawValue)" }
        static func baseURL(_ p: AIProvider) -> String { "MyGit.ai.baseURL.\(p.rawValue)" }
    }

    init(credentials: CredentialRepository,
         ai: CommitMessageRepository = AICommitMessageRepository(),
         defaults: UserDefaults = .standard) {
        self.credentials = credentials
        self.ai = ai
        self.defaults = defaults

        self.activeProvider = AIProvider(rawValue: defaults.string(forKey: Keys.provider) ?? "")
            ?? .custom
        self.generateBody = defaults.bool(forKey: Keys.generateBody)

        var m: [String: String] = [:]
        var b: [String: String] = [:]
        var k: [String: String] = [:]
        for p in AIProvider.allCases {
            m[p.rawValue] = defaults.string(forKey: Keys.model(p)) ?? (p.defaultModels.first ?? "")
            b[p.rawValue] = defaults.string(forKey: Keys.baseURL(p)) ?? p.defaultBaseURL
            k[p.rawValue] = credentials.token(host: p.keychainAccount) ?? ""
        }
        self.models = m
        self.baseURLs = b
        self.apiKeys = k
    }

    // MARK: Active provider

    func setActive(_ p: AIProvider) {
        guard p != activeProvider else { return }
        activeProvider = p
        defaults.set(p.rawValue, forKey: Keys.provider)
    }

    // MARK: Per-provider accessors

    func model(for p: AIProvider) -> String { models[p.rawValue] ?? "" }

    func setModel(_ value: String, for p: AIProvider) {
        models[p.rawValue] = value
        defaults.set(value, forKey: Keys.model(p))
    }

    func baseURL(for p: AIProvider) -> String { baseURLs[p.rawValue] ?? p.defaultBaseURL }

    func setBaseURL(_ value: String, for p: AIProvider) {
        baseURLs[p.rawValue] = value
        defaults.set(value, forKey: Keys.baseURL(p))
    }

    func resetBaseURL(for p: AIProvider) {
        setBaseURL(p.defaultBaseURL, for: p)
    }

    func apiKey(for p: AIProvider) -> String { apiKeys[p.rawValue] ?? "" }

    func setAPIKey(_ value: String, for p: AIProvider) {
        apiKeys[p.rawValue] = value
        testStatus[p.rawValue] = nil
    }

    // MARK: Connection test

    func status(for p: AIProvider) -> ConnectionTestStatus {
        testStatus[p.rawValue] ?? .idle
    }

    /// Test reachability for `p` using its current (unsaved) field values.
    func testConnection(for p: AIProvider) {
        let key = apiKey(for: p).trimmingCharacters(in: .whitespaces)
        guard !key.isEmpty else {
            testStatus[p.rawValue] = .failure("No API key entered.")
            return
        }
        let m = model(for: p).trimmingCharacters(in: .whitespaces)
        let cfg = AIRequestConfig(
            provider: p,
            model: m,
            baseURL: effectiveBaseURL(for: p),
            apiKey: key
        )
        testStatus[p.rawValue] = .testing
        Task { [ai] in
            do {
                let detail = try await ai.testConnection(config: cfg)
                testStatus[p.rawValue] = .success(detail)
            } catch {
                let msg = (error as? LocalizedError)?.errorDescription
                    ?? error.localizedDescription
                testStatus[p.rawValue] = .failure(msg)
            }
        }
    }

    /// The base URL to send requests to for `p`.
    func effectiveBaseURL(for p: AIProvider) -> String {
        let trimmed = baseURL(for: p).trimmingCharacters(in: .whitespaces)
        return trimmed.isEmpty ? p.defaultBaseURL : trimmed
    }

    /// Persist the API key to the keychain for `p`.
    func saveKey(for p: AIProvider) {
        let key = apiKey(for: p).trimmingCharacters(in: .whitespaces)
        if key.isEmpty {
            credentials.delete(host: p.keychainAccount)
        } else {
            credentials.setToken(key, host: p.keychainAccount)
        }
    }

    /// Build a request config for the active provider, or nil if no key set.
    func requestConfig() -> AIRequestConfig? {
        let p = activeProvider
        let key = (credentials.token(host: p.keychainAccount) ?? "")
            .trimmingCharacters(in: .whitespaces)
        guard !key.isEmpty else { return nil }
        let m = model(for: p).trimmingCharacters(in: .whitespaces)
        guard !m.isEmpty else { return nil }
        return AIRequestConfig(
            provider: p,
            model: m,
            baseURL: effectiveBaseURL(for: p),
            apiKey: key,
            includeBody: generateBody
        )
    }
}
