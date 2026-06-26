import Foundation
import Security

/// PAT storage in MyGit-owned keychain items. Decoupled from
/// /usr/bin/git's credential helpers so fetch/pull/push do not trigger
/// the `git-credential-osxkeychain` login-keychain prompt.
struct KeychainCredentialRepository: CredentialRepository {
    private let service = "com.thienpham.MyGit"

    func setToken(_ token: String, host: String) {
        delete(host: host)
        guard let data = token.data(using: .utf8) else { return }
        let attrs: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: host,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlock,
            kSecValueData as String: data
        ]
        SecItemAdd(attrs as CFDictionary, nil)
    }

    func token(host: String) -> String? {
        let q: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: host,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]
        var item: CFTypeRef?
        guard SecItemCopyMatching(q as CFDictionary, &item) == errSecSuccess,
              let data = item as? Data,
              let s = String(data: data, encoding: .utf8) else { return nil }
        return s
    }

    func delete(host: String) {
        let q: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: host
        ]
        SecItemDelete(q as CFDictionary)
    }

    /// Existence check only. Crucially does NOT request `kSecReturnData`, so
    /// macOS does not trigger the keychain ACL ("…wants to access key…")
    /// prompt — only reading the secret data does. Lets the UI show
    /// signed-in state at launch without prompting.
    func hasToken(host: String) -> Bool {
        let q: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: host,
            kSecReturnAttributes as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]
        var item: CFTypeRef?
        return SecItemCopyMatching(q as CFDictionary, &item) == errSecSuccess
    }
}
