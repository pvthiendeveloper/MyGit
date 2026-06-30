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
        var attrs: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: host,
            kSecValueData as String: data
        ]
        // Prefer a trust-all ACL so the secret stays readable after a rebuild
        // re-signs the binary. Fall back to the data-protection accessibility
        // attribute if the legacy ACL API is unavailable.
        if let access = trustAllAccess(label: "\(service) \(host)") {
            attrs[kSecAttrAccess as String] = access
        } else {
            attrs[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
        }
        SecItemAdd(attrs as CFDictionary, nil)
    }

    /// Build a `SecAccess` letting ANY application read the item without the
    /// keychain ACL prompt. The default ACL pins each item to the creating
    /// app's code-signing identity, so a rebuilt (re-signed) MyGit binary is
    /// denied and the read returns nil — the stored key then looks "lost"
    /// every rebuild. Trust-all keeps it readable across `run.sh` rebuilds.
    /// Tradeoff: any app on this Mac can read these items. Acceptable for an
    /// unsandboxed personal dev tool; the user opted into this.
    private func trustAllAccess(label: String) -> SecAccess? {
        var access: SecAccess?
        guard SecAccessCreate(label as CFString, nil, &access) == errSecSuccess,
              let access else { return nil }
        var aclList: CFArray?
        guard SecAccessCopyACLList(access, &aclList) == errSecSuccess,
              let acls = aclList as? [SecACL] else { return access }
        for acl in acls {
            var apps: CFArray?
            var desc: CFString?
            var prompt = SecKeychainPromptSelector()
            guard SecACLCopyContents(acl, &apps, &desc, &prompt) == errSecSuccess
            else { continue }
            // applicationList == nil => all applications may access, no prompt.
            SecACLSetContents(acl, nil, desc ?? (label as CFString), prompt)
        }
        return access
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
