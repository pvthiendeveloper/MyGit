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
        // No custom SecAccess: the item gets the DEFAULT ACL, which trusts the
        // creating app by its code-signing designated requirement (DR). `run.sh`
        // re-signs every rebuild with the SAME persistent cert, so the DR stays
        // constant and the rebuilt binary keeps read access. The first read after
        // a fresh write shows the keychain prompt once — click "Always Allow" and
        // the stable DR is recorded, so later rebuilds read silently.
        //
        // (The previous trust-all ACL via the deprecated SecAccessCreate API did
        // not take effect on modern macOS — reads still hit the auth prompt and
        // the key looked "lost" each rebuild.)
        let attrs: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: host,
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
