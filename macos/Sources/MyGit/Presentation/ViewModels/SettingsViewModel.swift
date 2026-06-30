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

    /// Model IDs fetched from each provider's API (via Test Connection),
    /// keyed by `AIProvider.rawValue`. Persisted so the picker keeps the real
    /// list across launches. Empty until the user tests the connection.
    @Published var fetchedModels: [String: [String]]

    /// Providers whose key currently lives in the plaintext file fallback (keychain
    /// save failed). Surfaced in the UI so the user knows it's not in the keychain.
    @Published private(set) var keyInFile: Set<String> = []

    private let credentials: CredentialRepository
    private let defaults: UserDefaults
    private let ai: CommitMessageRepository
    /// Last-resort secret store used only when the keychain is unavailable.
    private let secretFile = SecretFileStore()

    /// Session cache of keychain-resolved keys, keyed by `AIProvider.rawValue`.
    /// Reading the secret data triggers the keychain ACL prompt, so we read each
    /// provider's key at most once per launch instead of on every generation.
    /// Invalidated whenever the key is edited or re-saved.
    private var resolvedKeys: [String: String] = [:]

    private enum Keys {
        static let provider = "MyGit.ai.provider"
        static let generateBody = "MyGit.ai.generateBody"
        static func model(_ p: AIProvider) -> String { "MyGit.ai.model.\(p.rawValue)" }
        static func baseURL(_ p: AIProvider) -> String { "MyGit.ai.baseURL.\(p.rawValue)" }
        static func modelList(_ p: AIProvider) -> String { "MyGit.ai.modelList.\(p.rawValue)" }
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
        var fetched: [String: [String]] = [:]
        for p in AIProvider.allCases {
            m[p.rawValue] = defaults.string(forKey: Keys.model(p)) ?? (p.defaultModels.first ?? "")
            b[p.rawValue] = defaults.string(forKey: Keys.baseURL(p)) ?? p.defaultBaseURL
            if let list = defaults.stringArray(forKey: Keys.modelList(p)), !list.isEmpty {
                fetched[p.rawValue] = list
            }
        }
        self.models = m
        self.baseURLs = b
        self.fetchedModels = fetched
        // API keys are read lazily (see loadKey) so launching the app never
        // touches the keychain — that would pop the ACL prompt every run.
        self.apiKeys = [:]
    }

    /// Read a provider's stored key into the editable field. Called when its
    /// Settings tab appears, so the keychain prompt (if any) happens only when
    /// the user opens Settings — not on every launch.
    private var loadedKeys: Set<String> = []
    func loadKey(for p: AIProvider) {
        guard !loadedKeys.contains(p.rawValue) else { return }
        loadedKeys.insert(p.rawValue)
        if apiKeys[p.rawValue]?.isEmpty ?? true {
            if let k = credentials.token(host: p.keychainAccount), !k.isEmpty {
                apiKeys[p.rawValue] = k
                keyInFile.remove(p.rawValue)
            } else if let f = secretFile.get(account: p.keychainAccount), !f.isEmpty {
                // Keychain couldn't return it — fall back to the plaintext file.
                apiKeys[p.rawValue] = f
                keyInFile.insert(p.rawValue)
            } else {
                apiKeys[p.rawValue] = ""
            }
        }
    }

    /// Whether `p`'s key is stored in the plaintext file fallback instead of the keychain.
    func isKeyInFile(_ p: AIProvider) -> Bool { keyInFile.contains(p.rawValue) }

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
        resolvedKeys[p.rawValue] = nil
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
                let list = try await ai.listModels(config: cfg)
                setFetchedModels(list, for: p)
                testStatus[p.rawValue] = .success("Connected — \(list.count) models available")
            } catch {
                let msg = (error as? LocalizedError)?.errorDescription
                    ?? error.localizedDescription
                testStatus[p.rawValue] = .failure(msg)
            }
        }
    }

    /// Models offered in the picker for `p`: the API-fetched list when present
    /// (after Test Connection), otherwise the hardcoded defaults.
    func availableModels(for p: AIProvider) -> [String] {
        let fetched = fetchedModels[p.rawValue] ?? []
        return fetched.isEmpty ? p.defaultModels : fetched
    }

    /// Store and persist the model list fetched from a provider's API.
    private func setFetchedModels(_ list: [String], for p: AIProvider) {
        fetchedModels[p.rawValue] = list
        defaults.set(list, forKey: Keys.modelList(p))
    }

    /// The base URL to send requests to for `p`.
    func effectiveBaseURL(for p: AIProvider) -> String {
        let trimmed = baseURL(for: p).trimmingCharacters(in: .whitespaces)
        return trimmed.isEmpty ? p.defaultBaseURL : trimmed
    }

    /// Persist the API key to the keychain for `p`.
    func saveKey(for p: AIProvider) {
        let key = apiKey(for: p).trimmingCharacters(in: .whitespaces)
        let account = p.keychainAccount
        if key.isEmpty {
            credentials.delete(host: account)
            secretFile.delete(account: account)
            keyInFile.remove(p.rawValue)
        } else {
            credentials.setToken(key, host: account)
            // setToken reports nothing; verify it actually landed (hasToken reads only
            // attributes, so no ACL prompt). If the keychain rejected the write, persist
            // to the plaintext file fallback instead so the key isn't silently lost.
            if credentials.hasToken(host: account) {
                secretFile.delete(account: account)   // keychain holds it; drop stale plaintext
                keyInFile.remove(p.rawValue)
            } else {
                secretFile.set(key, account: account)
                keyInFile.insert(p.rawValue)
            }
        }
        resolvedKeys[p.rawValue] = key
    }

    /// Build a request config for the active provider, or nil if no key set.
    func requestConfig() -> AIRequestConfig? {
        let p = activeProvider
        let key = resolvedKey(for: p)
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

    /// Resolve a provider's key, hitting the keychain only on the first miss
    /// this session (subsequent generations reuse the cached value — one ACL
    /// prompt per launch at most). Prefers an unsaved edit if one is present.
    private func resolvedKey(for p: AIProvider) -> String {
        if let edited = apiKeys[p.rawValue], !edited.isEmpty {
            return edited.trimmingCharacters(in: .whitespaces)
        }
        if let cached = resolvedKeys[p.rawValue] {
            return cached
        }
        let fetched = (credentials.token(host: p.keychainAccount)
            ?? secretFile.get(account: p.keychainAccount)
            ?? "").trimmingCharacters(in: .whitespaces)
        resolvedKeys[p.rawValue] = fetched
        return fetched
    }
}
