import Foundation

enum RemoteTransport: Hashable {
    case ssh, https, http, git, local, unknown
}

struct GitAccount: Hashable {
    var userName: String?
    var userEmail: String?
    var remoteURL: String?
    var host: String?       // e.g. "github.com"
    var owner: String?      // e.g. "octocat"
    var repo: String?       // e.g. "Hello-World"
    var transport: RemoteTransport = .unknown

    var isGitHub: Bool { host?.lowercased() == "github.com" }
    var isBitbucket: Bool { host?.lowercased() == "bitbucket.org" }
    var isSSH: Bool { transport == .ssh }
    var isHTTPS: Bool { transport == .https || transport == .http }

    var webURL: URL? {
        guard let host, let owner, let repo else { return nil }
        return URL(string: "https://\(host)/\(owner)/\(repo)")
    }

    var avatarURL: URL? {
        guard isGitHub, let owner else { return nil }
        return URL(string: "https://github.com/\(owner).png?size=64")
    }
}

enum GitAccountLoader {
    static func load(cwd: URL) async -> GitAccount {
        async let name = readConfig("user.name", cwd: cwd)
        async let email = readConfig("user.email", cwd: cwd)
        async let remote = readRemoteURL(cwd: cwd)

        let remoteURL = await remote
        let (host, owner, repo) = parseRemote(remoteURL)
        return GitAccount(
            userName: await name,
            userEmail: await email,
            remoteURL: remoteURL,
            host: host,
            owner: owner,
            repo: repo,
            transport: detectTransport(remoteURL)
        )
    }

    static func detectTransport(_ url: String?) -> RemoteTransport {
        guard let s = url?.trimmingCharacters(in: .whitespaces), !s.isEmpty else { return .unknown }
        let lower = s.lowercased()
        if lower.hasPrefix("ssh://") { return .ssh }
        if lower.hasPrefix("git://") { return .git }
        if lower.hasPrefix("https://") { return .https }
        if lower.hasPrefix("http://") { return .http }
        if lower.hasPrefix("file://") || lower.hasPrefix("/") { return .local }
        // SCP-like: user@host:path  → SSH
        if !s.contains("://"), s.contains(":") { return .ssh }
        return .unknown
    }

    private static func readConfig(_ key: String, cwd: URL) async -> String? {
        let r = try? await GitRunner.run(["config", "--get", key], cwd: cwd)
        let v = r?.stdout.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return v.isEmpty ? nil : v
    }

    private static func readRemoteURL(cwd: URL) async -> String? {
        if let r = try? await GitRunner.run(["remote", "get-url", "origin"], cwd: cwd),
           r.exitCode == 0 {
            let v = r.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
            if !v.isEmpty { return v }
        }
        // Fallback: first remote if no origin.
        if let r = try? await GitRunner.run(["remote"], cwd: cwd),
           r.exitCode == 0,
           let first = r.stdout.split(separator: "\n").first {
            let name = String(first).trimmingCharacters(in: .whitespacesAndNewlines)
            if !name.isEmpty,
               let r2 = try? await GitRunner.run(["remote", "get-url", name], cwd: cwd),
               r2.exitCode == 0 {
                let v = r2.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
                if !v.isEmpty { return v }
            }
        }
        return nil
    }

    /// Parses common git remote URL forms:
    ///   git@github.com:owner/repo.git
    ///   ssh://git@github.com/owner/repo.git
    ///   https://github.com/owner/repo.git
    ///   https://user@github.com/owner/repo
    static func parseRemote(_ url: String?) -> (host: String?, owner: String?, repo: String?) {
        guard var s = url, !s.isEmpty else { return (nil, nil, nil) }

        // Strip trailing .git
        if s.hasSuffix(".git") { s.removeLast(4) }

        // SCP-like: git@host:owner/repo
        if !s.contains("://"), let colon = s.firstIndex(of: ":") {
            let hostPart = String(s[..<colon])
            let path = String(s[s.index(after: colon)...])
            let host = hostPart.components(separatedBy: "@").last
            let segs = path.split(separator: "/", omittingEmptySubsequences: true).map(String.init)
            return (host, segs.dropLast().last, segs.last)
        }

        // URL form
        guard let u = URL(string: s) else { return (nil, nil, nil) }
        let host = u.host
        let segs = u.path.split(separator: "/", omittingEmptySubsequences: true).map(String.init)
        return (host, segs.dropLast().last, segs.last)
    }
}
