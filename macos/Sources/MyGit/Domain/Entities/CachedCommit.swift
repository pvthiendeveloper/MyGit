import Foundation

/// Lightweight snapshot of a repo's most recent commit, persisted so each
/// project's last commit shows instantly on launch (before the log loads).
struct CachedCommit: Codable, Equatable {
    let subject: String
    let shortHash: String
    let dateEpoch: TimeInterval

    var date: Date { Date(timeIntervalSince1970: dateEpoch) }
}

/// Per-repo last-commit cache, keyed by repo path in UserDefaults.
struct LastCommitStore {
    private let defaults: UserDefaults
    init(defaults: UserDefaults = .standard) { self.defaults = defaults }

    private func key(_ repoPath: String) -> String { "MyGit.lastCommit.\(repoPath)" }

    func get(_ repoPath: String) -> CachedCommit? {
        guard let data = defaults.data(forKey: key(repoPath)) else { return nil }
        return try? JSONDecoder().decode(CachedCommit.self, from: data)
    }

    func set(_ commit: CachedCommit, repoPath: String) {
        guard let data = try? JSONEncoder().encode(commit) else { return }
        defaults.set(data, forKey: key(repoPath))
    }
}

/// Persisted commit-message draft (summary + description) per repo, so a
/// half-written message survives relaunch. Keyed by repo path.
struct CommitDraftStore {
    private let defaults: UserDefaults
    init(defaults: UserDefaults = .standard) { self.defaults = defaults }

    private func sKey(_ p: String) -> String { "MyGit.draft.summary.\(p)" }
    private func dKey(_ p: String) -> String { "MyGit.draft.desc.\(p)" }

    func get(_ repoPath: String) -> (summary: String, description: String) {
        (defaults.string(forKey: sKey(repoPath)) ?? "",
         defaults.string(forKey: dKey(repoPath)) ?? "")
    }

    func set(summary: String, description: String, repoPath: String) {
        store(summary, key: sKey(repoPath))
        store(description, key: dKey(repoPath))
    }

    private func store(_ value: String, key: String) {
        if value.isEmpty { defaults.removeObject(forKey: key) }
        else { defaults.set(value, forKey: key) }
    }
}
