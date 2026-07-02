import Foundation

/// Opens pull requests via the GitHub REST API. Works against github.com and
/// GitHub Enterprise (host-derived API base). Auth is a bearer PAT — the same
/// token MyGit stores for the host and uses for HTTPS git.
struct GitHubPullRequestRepository: PullRequestRepository {
    private let session: URLSession

    init(session: URLSession = .shared) {
        self.session = session
    }

    /// API base for a host: github.com → api.github.com; GHE → https://host/api/v3.
    private static func apiBase(host: String) -> String {
        host.lowercased() == "github.com"
            ? "https://api.github.com"
            : "https://\(host)/api/v3"
    }

    private func request(_ url: URL, token: String) -> URLRequest {
        var req = URLRequest(url: url)
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        req.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        req.setValue("2022-11-28", forHTTPHeaderField: "X-GitHub-Api-Version")
        return req
    }

    func defaultBranch(host: String, owner: String, repo: String, token: String) async throws -> String {
        guard let url = URL(string: "\(Self.apiBase(host: host))/repos/\(owner)/\(repo)") else {
            throw PullRequestError.badResponse("bad repo URL")
        }
        let (data, resp) = try await session.data(for: request(url, token: token))
        try Self.checkStatus(resp, data)
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let branch = json["default_branch"] as? String else {
            throw PullRequestError.badResponse(Self.snippet(data))
        }
        return branch
    }

    func create(
        host: String, owner: String, repo: String,
        head: String, base: String, title: String, body: String,
        token: String
    ) async throws -> PullRequestInfo {
        guard let url = URL(string: "\(Self.apiBase(host: host))/repos/\(owner)/\(repo)/pulls") else {
            throw PullRequestError.badResponse("bad repo URL")
        }
        var req = request(url, token: token)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try JSONSerialization.data(withJSONObject: [
            "title": title,
            "head": head,
            "base": base,
            "body": body
        ])

        let (data, resp) = try await session.data(for: req)
        try Self.checkStatus(resp, data)

        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let number = json["number"] as? Int,
              let htmlURL = (json["html_url"] as? String).flatMap(URL.init(string:)) else {
            throw PullRequestError.badResponse(Self.snippet(data))
        }
        return PullRequestInfo(number: number, url: htmlURL)
    }

    private static let perPage = 30

    func list(
        host: String, owner: String, repo: String,
        page: Int, token: String
    ) async throws -> PullRequestPage {
        var comps = URLComponents(string: "\(Self.apiBase(host: host))/repos/\(owner)/\(repo)/pulls")
        comps?.queryItems = [
            .init(name: "state", value: "all"),
            .init(name: "sort", value: "updated"),
            .init(name: "direction", value: "desc"),
            .init(name: "per_page", value: String(Self.perPage)),
            .init(name: "page", value: String(page))
        ]
        guard let url = comps?.url else { throw PullRequestError.badResponse("bad list URL") }

        let (data, resp) = try await session.data(for: request(url, token: token))
        try Self.checkStatus(resp, data)

        guard let arr = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] else {
            throw PullRequestError.badResponse(Self.snippet(data))
        }
        let items = arr.compactMap(Self.parseSummary)
        // Prefer the Link header's rel="next"; fall back to a full page heuristic.
        let hasMore: Bool = {
            if let link = (resp as? HTTPURLResponse)?.value(forHTTPHeaderField: "Link") {
                return link.contains("rel=\"next\"")
            }
            return arr.count >= Self.perPage
        }()
        return PullRequestPage(items: items, hasMore: hasMore)
    }

    func detail(
        host: String, owner: String, repo: String,
        number: Int, token: String
    ) async throws -> PullRequestDetail {
        let base = "\(Self.apiBase(host: host))/repos/\(owner)/\(repo)/pulls/\(number)"
        guard let url = URL(string: base) else { throw PullRequestError.badResponse("bad detail URL") }

        let (data, resp) = try await session.data(for: request(url, token: token))
        try Self.checkStatus(resp, data)
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let summary = Self.parseSummary(json) else {
            throw PullRequestError.badResponse(Self.snippet(data))
        }
        let description = (json["body"] as? String) ?? ""
        let createdAt = PRDate.parse(json["created_at"] as? String)
        let closedBy = (json["merged_by"] as? [String: Any])?["login"] as? String
        let headSHA = ((json["head"] as? [String: Any])?["sha"] as? String) ?? ""

        // Reviewers via the reviews endpoint (best-effort).
        let participants = (try? await Self.reviewers(base: base, token: token, request: request)) ?? []
        // Checks via the head commit's check-runs (best-effort).
        let checks = try? await Self.checkRuns(
            host: host, owner: owner, repo: repo, sha: headSHA, token: token, request: request
        )

        return PullRequestDetail(
            summary: summary, description: description, createdAt: createdAt,
            participants: participants, checks: checks, closedBy: closedBy
        )
    }

    func files(
        host: String, owner: String, repo: String,
        number: Int, token: String
    ) async throws -> [PRFileChange] {
        guard let url = URL(string: "\(Self.apiBase(host: host))/repos/\(owner)/\(repo)/pulls/\(number)/files?per_page=100")
        else { throw PullRequestError.badResponse("bad files URL") }
        let (data, resp) = try await session.data(for: request(url, token: token))
        try Self.checkStatus(resp, data)
        guard let arr = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] else {
            throw PullRequestError.badResponse(Self.snippet(data))
        }
        return arr.compactMap(Self.parseFile)
    }

    func commitFiles(
        host: String, owner: String, repo: String,
        sha: String, token: String
    ) async throws -> [PRFileChange] {
        guard let url = URL(string: "\(Self.apiBase(host: host))/repos/\(owner)/\(repo)/commits/\(sha)")
        else { throw PullRequestError.badResponse("bad commit URL") }
        let (data, resp) = try await session.data(for: request(url, token: token))
        try Self.checkStatus(resp, data)
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let arr = json["files"] as? [[String: Any]] else {
            throw PullRequestError.badResponse(Self.snippet(data))
        }
        return arr.compactMap(Self.parseFile)
    }

    /// Map a GitHub file object (from PR-files or commit endpoints) to a change.
    private static func parseFile(_ f: [String: Any]) -> PRFileChange? {
        guard let path = f["filename"] as? String else { return nil }
        let status: PRFileChange.Status
        switch f["status"] as? String {
        case "added": status = .added
        case "removed": status = .removed
        case "renamed": status = .renamed
        default: status = .modified
        }
        return PRFileChange(
            path: path,
            oldPath: f["previous_filename"] as? String,
            status: status,
            additions: (f["additions"] as? Int) ?? 0,
            deletions: (f["deletions"] as? Int) ?? 0,
            patch: f["patch"] as? String
        )
    }

    func commits(
        host: String, owner: String, repo: String,
        number: Int, token: String
    ) async throws -> [PRCommit] {
        guard let url = URL(string: "\(Self.apiBase(host: host))/repos/\(owner)/\(repo)/pulls/\(number)/commits?per_page=100")
        else { throw PullRequestError.badResponse("bad commits URL") }
        let (data, resp) = try await session.data(for: request(url, token: token))
        try Self.checkStatus(resp, data)
        guard let arr = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] else {
            throw PullRequestError.badResponse(Self.snippet(data))
        }
        return arr.compactMap { c in
            guard let sha = c["sha"] as? String else { return nil }
            let commit = c["commit"] as? [String: Any]
            let author = commit?["author"] as? [String: Any]
            return PRCommit(
                id: sha,
                message: (commit?["message"] as? String) ?? "",
                author: (author?["name"] as? String) ?? "unknown",
                date: PRDate.parse(author?["date"] as? String)
            )
        }
    }

    /// Map a GitHub PR JSON object (from list or single-PR endpoints) to a summary.
    private static func parseSummary(_ json: [String: Any]) -> PullRequestSummary? {
        guard let number = json["number"] as? Int,
              let htmlURL = (json["html_url"] as? String).flatMap(URL.init(string:)) else {
            return nil
        }
        let user = json["user"] as? [String: Any]
        let head = json["head"] as? [String: Any]
        let base = json["base"] as? [String: Any]
        let isDraft = (json["draft"] as? Bool) ?? false
        let merged = json["merged_at"] is String
        let stateStr = (json["state"] as? String) ?? "open"
        let state: PullRequestState = merged ? .merged
            : (stateStr == "closed" ? .closed : (isDraft ? .draft : .open))
        return PullRequestSummary(
            id: number,
            title: (json["title"] as? String) ?? "(untitled)",
            authorName: (user?["login"] as? String) ?? "unknown",
            authorAvatarURL: (user?["avatar_url"] as? String).flatMap(URL.init(string:)),
            sourceBranch: (head?["ref"] as? String) ?? "?",
            destBranch: (base?["ref"] as? String) ?? "?",
            state: state,
            isDraft: isDraft,
            // The list endpoint omits issue-comment totals; review_comments is the
            // closest available count without an extra request.
            commentCount: (json["review_comments"] as? Int) ?? (json["comments"] as? Int) ?? 0,
            updatedAt: PRDate.parse(json["updated_at"] as? String),
            url: htmlURL
        )
    }

    private static func reviewers(
        base: String, token: String,
        request: (URL, String) -> URLRequest
    ) async throws -> [PRParticipant] {
        guard let url = URL(string: base + "/reviews") else { return [] }
        let (data, resp) = try await URLSession.shared.data(for: request(url, token))
        try checkStatus(resp, data)
        guard let arr = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] else { return [] }
        // Keep the latest review state per reviewer.
        var byName: [String: PRParticipant] = [:]
        for r in arr {
            guard let user = r["user"] as? [String: Any],
                  let login = user["login"] as? String else { continue }
            let approved = (r["state"] as? String) == "APPROVED"
            byName[login] = PRParticipant(
                name: login,
                avatarURL: (user["avatar_url"] as? String).flatMap(URL.init(string:)),
                isReviewer: true,
                approved: approved || (byName[login]?.approved ?? false)
            )
        }
        return Array(byName.values).sorted { $0.name < $1.name }
    }

    private static func checkRuns(
        host: String, owner: String, repo: String, sha: String, token: String,
        request: (URL, String) -> URLRequest
    ) async throws -> PRChecksSummary? {
        guard !sha.isEmpty,
              let url = URL(string: "\(apiBase(host: host))/repos/\(owner)/\(repo)/commits/\(sha)/check-runs")
        else { return nil }
        let (data, resp) = try await URLSession.shared.data(for: request(url, token))
        try checkStatus(resp, data)
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let runs = json["check_runs"] as? [[String: Any]] else { return nil }
        let total = runs.count
        let passed = runs.filter { ($0["conclusion"] as? String) == "success" }.count
        guard total > 0 else { return nil }
        return PRChecksSummary(passed: passed, total: total, buildsPassed: passed, buildsTotal: total)
    }

    // MARK: - Helpers

    private static func checkStatus(_ resp: URLResponse, _ data: Data) throws {
        guard let http = resp as? HTTPURLResponse else { return }
        guard (200..<300).contains(http.statusCode) else {
            throw PullRequestError.httpError(http.statusCode, message(data))
        }
    }

    /// Prefer GitHub's structured error message (and first validation error)
    /// over a raw JSON dump.
    private static func message(_ data: Data) -> String {
        if let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let msg = json["message"] as? String {
            if let errs = json["errors"] as? [[String: Any]],
               let first = errs.first?["message"] as? String {
                return "\(msg) — \(first)"
            }
            return msg
        }
        return snippet(data)
    }

    private static func snippet(_ data: Data) -> String {
        let s = String(data: data, encoding: .utf8) ?? ""
        return s.count > 300 ? String(s.prefix(300)) + "…" : s
    }
}
