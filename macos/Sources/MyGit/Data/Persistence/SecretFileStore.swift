import Foundation

// Plaintext fallback for secrets when the keychain is unavailable (locked keychain,
// denied ACL, missing signing identity). LESS SECURE than the keychain: the value is
// stored unencrypted on disk. Mitigations: the file lives in the app's Application
// Support dir and is created with 0600 perms (owner read/write only). Only written when
// a keychain save actually fails — never as a mirror of a working keychain entry.
//
// Layout: ~/Library/Application Support/MyGit/secrets.json — a flat {account: secret} map.
struct SecretFileStore {
    private let url: URL

    init(filename: String = "secrets.json") {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.homeDirectoryForCurrentUser
        let dir = base.appendingPathComponent("MyGit", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true,
                                                 attributes: [.posixPermissions: 0o700])
        self.url = dir.appendingPathComponent(filename)
    }

    func get(account: String) -> String? {
        load()[account]
    }

    func set(_ secret: String, account: String) {
        var map = load()
        map[account] = secret
        save(map)
    }

    func delete(account: String) {
        var map = load()
        guard map.removeValue(forKey: account) != nil else { return }
        save(map)
    }

    private func load() -> [String: String] {
        guard let data = try? Data(contentsOf: url),
              let map = try? JSONDecoder().decode([String: String].self, from: data) else { return [:] }
        return map
    }

    private func save(_ map: [String: String]) {
        guard let data = try? JSONEncoder().encode(map) else { return }
        // Write then clamp perms to owner-only; atomic so a crash can't leave a partial file.
        try? data.write(to: url, options: [.atomic])
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }
}
