import Foundation

/// Opens pull requests via the Bitbucket Cloud REST API (v2.0).
///
/// Auth: the stored token is sent as either
///   • `Basic base64(user:app_password)` when it contains a colon (app password), or
///   • `Bearer <token>` otherwise (workspace/project/repo access token).
/// This mirrors the two credential styles Bitbucket Cloud accepts.
struct BitbucketPullRequestRepository: PullRequestRepository {
    private let session: URLSession
    private let redirectAuth = BitbucketRedirectAuth()
    private static let apiBase = "https://api.bitbucket.org/2.0"

    init(session: URLSession = .shared) {
        self.session = session
    }

    private func authHeader(_ token: String) -> String {
        if token.contains(":") {
            let b64 = Data(token.utf8).base64EncodedString()
            return "Basic \(b64)"
        }
        return "Bearer \(token)"
    }

    private func request(_ url: URL, token: String) -> URLRequest {
        var req = URLRequest(url: url)
        req.setValue(authHeader(token), forHTTPHeaderField: "Authorization")
        req.setValue("application/json", forHTTPHeaderField: "Accept")
        return req
    }

    /// GET with auth preserved across redirects. Bitbucket's `/diffstat` and
    /// `/diff` reply with a 302; Foundation strips the Authorization header on
    /// redirect, which turns a private-repo request into a 404. The task
    /// delegate re-attaches it.
    private func send(_ url: URL, token: String) async throws -> (Data, URLResponse) {
        try await session.data(for: request(url, token: token), delegate: redirectAuth)
    }

    /// `owner` is the Bitbucket workspace slug; `repo` is the repository slug.
    func defaultBranch(host: String, owner: String, repo: String, token: String) async throws -> String {
        guard let url = URL(string: "\(Self.apiBase)/repositories/\(owner)/\(repo)") else {
            throw PullRequestError.badResponse("bad repo URL")
        }
        let (data, resp) = try await send(url, token: token)
        try Self.checkStatus(resp, data)
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let mainBranch = json["mainbranch"] as? [String: Any],
              let name = mainBranch["name"] as? String else {
            throw PullRequestError.badResponse(Self.snippet(data))
        }
        return name
    }

    func create(
        host: String, owner: String, repo: String,
        head: String, base: String, title: String, body: String,
        reviewers: [String],
        token: String
    ) async throws -> PullRequestInfo {
        guard let url = URL(string: "\(Self.apiBase)/repositories/\(owner)/\(repo)/pullrequests") else {
            throw PullRequestError.badResponse("bad repo URL")
        }
        var req = request(url, token: token)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        var payload: [String: Any] = [
            "title": title,
            "description": body,
            "source": ["branch": ["name": head]],
            "destination": ["branch": ["name": base]]
        ]
        // Bitbucket wants account objects. A `{uuid}` token maps to `uuid`,
        // anything else is treated as an `account_id`. Empty → omit the key.
        let reviewerObjs: [[String: String]] = reviewers
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
            .map { $0.hasPrefix("{") ? ["uuid": $0] : ["account_id": $0] }
        if !reviewerObjs.isEmpty { payload["reviewers"] = reviewerObjs }
        req.httpBody = try JSONSerialization.data(withJSONObject: payload)

        let (data, resp) = try await session.data(for: req)
        try Self.checkStatus(resp, data)

        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let number = json["id"] as? Int,
              let links = json["links"] as? [String: Any],
              let html = links["html"] as? [String: Any],
              let href = (html["href"] as? String).flatMap(URL.init(string:)) else {
            throw PullRequestError.badResponse(Self.snippet(data))
        }
        return PullRequestInfo(number: number, url: href)
    }

    /// The repo's default reviewers. Readable with a plain `read:repository`
    /// token (unlike `/user` and branch-restrictions), so this works even when
    /// identity can't be resolved.
    func defaultReviewers(host: String, owner: String, repo: String, token: String) async throws -> [PRUser] {
        let values = try await jsonValues(
            "\(Self.apiBase)/repositories/\(owner)/\(repo)/default-reviewers?pagelen=100", token: token)
        return values.compactMap { u in
            guard let uuid = u["uuid"] as? String else { return nil }
            let name = (u["display_name"] as? String) ?? (u["nickname"] as? String) ?? uuid
            return PRUser(id: uuid, name: name)
        }
    }

    private static let pageLen = 30

    func list(
        host: String, owner: String, repo: String,
        page: Int, token: String
    ) async throws -> PullRequestPage {
        var comps = URLComponents(string: "\(Self.apiBase)/repositories/\(owner)/\(repo)/pullrequests")
        // `state` is repeatable — request every lifecycle state so filtering can
        // happen client-side.
        comps?.queryItems = [
            .init(name: "state", value: "OPEN"),
            .init(name: "state", value: "MERGED"),
            .init(name: "state", value: "DECLINED"),
            .init(name: "state", value: "SUPERSEDED"),
            .init(name: "pagelen", value: String(Self.pageLen)),
            .init(name: "page", value: String(page)),
            .init(name: "sort", value: "-updated_on")
        ]
        guard let url = comps?.url else { throw PullRequestError.badResponse("bad list URL") }

        let (data, resp) = try await send(url, token: token)
        try Self.checkStatus(resp, data)

        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let values = json["values"] as? [[String: Any]] else {
            throw PullRequestError.badResponse(Self.snippet(data))
        }
        let items = values.compactMap(Self.parseSummary)
        let hasMore = json["next"] is String
        return PullRequestPage(items: items, hasMore: hasMore)
    }

    func detail(
        host: String, owner: String, repo: String,
        number: Int, token: String
    ) async throws -> PullRequestDetail {
        let base = "\(Self.apiBase)/repositories/\(owner)/\(repo)/pullrequests/\(number)"
        guard let url = URL(string: base) else { throw PullRequestError.badResponse("bad detail URL") }

        let (data, resp) = try await send(url, token: token)
        try Self.checkStatus(resp, data)
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let summary = Self.parseSummary(json) else {
            throw PullRequestError.badResponse(Self.snippet(data))
        }
        let description = (json["description"] as? String) ?? ""
        let createdAt = PRDate.parse(json["created_on"] as? String)
        let closedBy = (json["closed_by"] as? [String: Any])?["display_name"] as? String
        let participants = ((json["participants"] as? [[String: Any]]) ?? []).compactMap(Self.parseParticipant)

        // Build statuses (best-effort).
        let checks = try? await statuses(base: base, token: token)

        return PullRequestDetail(
            summary: summary, description: description, createdAt: createdAt,
            participants: participants, checks: checks, closedBy: closedBy
        )
    }

    func files(
        host: String, owner: String, repo: String,
        number: Int, token: String
    ) async throws -> [PRFileChange] {
        let prBase = "\(Self.apiBase)/repositories/\(owner)/\(repo)/pullrequests/\(number)"
        return try await filesFrom(
            diffstatURL: "\(prBase)/diffstat?pagelen=100",
            diffURL: "\(prBase)/diff",
            token: token
        )
    }

    func commitFiles(
        host: String, owner: String, repo: String,
        sha: String, token: String
    ) async throws -> [PRFileChange] {
        // Commit diff/diffstat live at repo level, keyed by the commit spec.
        let repoBase = "\(Self.apiBase)/repositories/\(owner)/\(repo)"
        return try await filesFrom(
            diffstatURL: "\(repoBase)/diffstat/\(sha)?pagelen=100",
            diffURL: "\(repoBase)/diff/\(sha)",
            token: token
        )
    }

    /// Shared: read a diffstat (file list + counts) and split the raw diff into
    /// per-file patches, joining them by path.
    private func filesFrom(diffstatURL: String, diffURL: String, token: String) async throws -> [PRFileChange] {
        guard let url = URL(string: diffstatURL) else { throw PullRequestError.badResponse("bad diffstat URL") }
        let (data, resp) = try await send(url, token: token)
        try Self.checkStatus(resp, data)
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let values = json["values"] as? [[String: Any]] else {
            throw PullRequestError.badResponse(Self.snippet(data))
        }
        // diffstat has no per-file patch — fetch the raw unified diff and split
        // it per file so each row can show its diff. Best-effort (nil on failure).
        let patches = (try? await diffPatches(diffURL: diffURL, token: token)) ?? [:]
        func selfHref(_ side: [String: Any]?) -> URL? {
            (((side?["links"] as? [String: Any])?["self"] as? [String: Any])?["href"] as? String)
                .flatMap(URL.init(string:))
        }
        return values.compactMap { v in
            let new = v["new"] as? [String: Any]
            let old = v["old"] as? [String: Any]
            let newPath = new?["path"] as? String
            let oldPath = old?["path"] as? String
            guard let path = newPath ?? oldPath else { return nil }
            let status: PRFileChange.Status
            switch v["status"] as? String {
            case "added": status = .added
            case "removed": status = .removed
            case "renamed": status = .renamed
            default: status = .modified
            }
            return PRFileChange(
                path: path,
                oldPath: (oldPath != newPath) ? oldPath : nil,
                status: status,
                additions: (v["lines_added"] as? Int) ?? 0,
                deletions: (v["lines_removed"] as? Int) ?? 0,
                patch: patches[path] ?? oldPath.flatMap { patches[$0] },
                newBlobURL: selfHref(new),
                oldBlobURL: selfHref(old)
            )
        }
    }

    /// Fetch a raw unified diff and split it into per-file patches keyed by the
    /// file's (new) path.
    private func diffPatches(diffURL: String, token: String) async throws -> [String: String] {
        guard let url = URL(string: diffURL) else { return [:] }
        let (data, resp) = try await send(url, token: token)
        try Self.checkStatus(resp, data)
        let text = String(data: data, encoding: .utf8) ?? ""
        return Self.splitUnifiedDiff(text)
    }

    /// Split a full `git diff` into `{ path: patchText }`. Each file section
    /// starts with `diff --git a/<old> b/<new>`; the path is refined from the
    /// `+++ b/<path>` line (falling back to the header / `--- a/<path>`).
    static func splitUnifiedDiff(_ text: String) -> [String: String] {
        var result: [String: String] = [:]
        var current: [Substring] = []
        var path: String?
        func flush() {
            if let p = path, !current.isEmpty { result[p] = current.joined(separator: "\n") }
            current = []; path = nil
        }
        func strip(_ s: String) -> String {
            let t = s.trimmingCharacters(in: .whitespaces)
            return (t.hasPrefix("a/") || t.hasPrefix("b/")) ? String(t.dropFirst(2)) : t
        }
        for line in text.split(separator: "\n", omittingEmptySubsequences: false) {
            if line.hasPrefix("diff --git ") {
                flush()
                if let r = line.range(of: " b/") { path = String(line[r.upperBound...]) }
            } else if line.hasPrefix("+++ ") {
                let p = String(line.dropFirst(4))
                if !p.hasPrefix("/dev/null") { path = strip(p) }
            } else if line.hasPrefix("--- "), path == nil {
                let p = String(line.dropFirst(4))
                if !p.hasPrefix("/dev/null") { path = strip(p) }
            }
            current.append(line)
        }
        flush()
        return result
    }

    func commits(
        host: String, owner: String, repo: String,
        number: Int, token: String
    ) async throws -> [PRCommit] {
        guard let url = URL(string: "\(Self.apiBase)/repositories/\(owner)/\(repo)/pullrequests/\(number)/commits?pagelen=100")
        else { throw PullRequestError.badResponse("bad commits URL") }
        let (data, resp) = try await send(url, token: token)
        try Self.checkStatus(resp, data)
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let values = json["values"] as? [[String: Any]] else {
            throw PullRequestError.badResponse(Self.snippet(data))
        }
        return values.compactMap { c in
            guard let hash = c["hash"] as? String else { return nil }
            let author = c["author"] as? [String: Any]
            let user = author?["user"] as? [String: Any]
            let name = (user?["display_name"] as? String)
                ?? (author?["raw"] as? String)
                ?? "unknown"
            return PRCommit(
                id: hash,
                message: (c["message"] as? String) ?? "",
                author: name,
                date: PRDate.parse(c["date"] as? String)
            )
        }
    }

    private static func parseSummary(_ json: [String: Any]) -> PullRequestSummary? {
        guard let number = json["id"] as? Int else { return nil }
        let author = json["author"] as? [String: Any]
        let source = ((json["source"] as? [String: Any])?["branch"] as? [String: Any])?["name"] as? String
        let dest = ((json["destination"] as? [String: Any])?["branch"] as? [String: Any])?["name"] as? String
        let stateStr = (json["state"] as? String) ?? "OPEN"
        let isDraft = (json["draft"] as? Bool) ?? false
        let state: PullRequestState
        switch stateStr {
        case "MERGED":     state = .merged
        case "DECLINED":   state = .declined
        case "SUPERSEDED": state = .superseded
        default:           state = isDraft ? .draft : .open
        }
        let html = ((json["links"] as? [String: Any])?["html"] as? [String: Any])?["href"] as? String
        return PullRequestSummary(
            id: number,
            title: (json["title"] as? String) ?? "(untitled)",
            authorName: (author?["display_name"] as? String) ?? "unknown",
            // Author id is the account UUID — matches `currentUser`'s id.
            authorId: author?["uuid"] as? String,
            authorAvatarURL: avatarURL(author),
            sourceBranch: source ?? "?",
            destBranch: dest ?? "?",
            state: state,
            isDraft: isDraft,
            commentCount: (json["comment_count"] as? Int) ?? 0,
            updatedAt: PRDate.parse(json["updated_on"] as? String),
            url: html.flatMap(URL.init(string:)) ?? URL(string: "https://bitbucket.org")!
        )
    }

    private static func parseParticipant(_ json: [String: Any]) -> PRParticipant? {
        let user = json["user"] as? [String: Any]
        guard let name = user?["display_name"] as? String else { return nil }
        let role = (json["role"] as? String) ?? ""
        return PRParticipant(
            name: name,
            avatarURL: avatarURL(user),
            isReviewer: role == "REVIEWER",
            approved: (json["approved"] as? Bool) ?? false,
            id: user?["uuid"] as? String,
            requestedChanges: (json["state"] as? String) == "changes_requested"
        )
    }

    private static func avatarURL(_ userOrAuthor: [String: Any]?) -> URL? {
        (((userOrAuthor?["links"] as? [String: Any])?["avatar"] as? [String: Any])?["href"] as? String)
            .flatMap(URL.init(string:))
    }

    private func statuses(base: String, token: String) async throws -> PRChecksSummary? {
        guard let url = URL(string: base + "/statuses") else { return nil }
        let (data, resp) = try await send(url, token: token)
        try Self.checkStatus(resp, data)
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let values = json["values"] as? [[String: Any]] else { return nil }
        let total = values.count
        let passed = values.filter { ($0["state"] as? String) == "SUCCESSFUL" }.count
        guard total > 0 else { return nil }
        return PRChecksSummary(passed: passed, total: total, buildsPassed: passed, buildsTotal: total)
    }

    func currentUser(host: String, token: String) async throws -> PRUser {
        guard let url = URL(string: "\(Self.apiBase)/user") else {
            throw PullRequestError.badResponse("bad user URL")
        }
        let (data, resp) = try await session.data(for: request(url, token: token))
        try Self.checkStatus(resp, data)
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let uuid = json["uuid"] as? String else {
            throw PullRequestError.badResponse(Self.snippet(data))
        }
        // Match `PRParticipant.id`, which is the participant's account UUID.
        return PRUser(id: uuid, name: (json["display_name"] as? String) ?? uuid)
    }

    func review(
        host: String, owner: String, repo: String,
        number: Int, action: PRReviewAction, token: String
    ) async throws {
        let base = "\(Self.apiBase)/repositories/\(owner)/\(repo)/pullrequests/\(number)"
        // Bitbucket has dedicated reviewer endpoints: POST to set, DELETE to withdraw.
        let (path, method): (String, String) = {
            switch action {
            case .approve:          return ("/approve", "POST")
            case .unapprove:        return ("/approve", "DELETE")
            case .requestChanges:   return ("/request-changes", "POST")
            case .unrequestChanges: return ("/request-changes", "DELETE")
            }
        }()
        guard let url = URL(string: base + path) else {
            throw PullRequestError.badResponse("bad review URL")
        }
        var req = request(url, token: token)
        req.httpMethod = method
        let (data, resp) = try await session.data(for: req)
        try Self.checkStatus(resp, data)
    }

    func lifecycle(
        host: String, owner: String, repo: String,
        number: Int, action: PRLifecycleAction, token: String
    ) async throws {
        let base = "\(Self.apiBase)/repositories/\(owner)/\(repo)/pullrequests/\(number)"
        switch action {
        case .merge:
            try await post(base + "/merge", token: token)
        case .decline:
            try await post(base + "/decline", token: token)
        case .reopen:
            // Bitbucket Cloud has no API to reopen a declined PR.
            throw PullRequestError.unsupportedHost("Bitbucket (reopening a declined PR)")
        case .markDraft, .markReady:
            try await putDraft(base: base, draft: action == .markDraft, token: token)
        }
    }

    private func post(_ urlString: String, token: String, body: [String: Any] = [:]) async throws {
        guard let url = URL(string: urlString) else { throw PullRequestError.badResponse("bad URL") }
        var req = request(url, token: token)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        // Bitbucket rejects a JSON-typed POST with an empty body as HTTP 400, so
        // always send a JSON object (`{}` when there are no fields).
        req.httpBody = try JSONSerialization.data(withJSONObject: body)
        let (data, resp) = try await session.data(for: req)
        try Self.checkStatus(resp, data)
    }

    /// Toggle draft via a full PR update. Bitbucket's PUT requires the title, so
    /// fetch the current one and resend it alongside the new draft flag.
    private func putDraft(base: String, draft: Bool, token: String) async throws {
        guard let url = URL(string: base) else { throw PullRequestError.badResponse("bad PR URL") }
        let (data, resp) = try await send(url, token: token)
        try Self.checkStatus(resp, data)
        let title = (try? JSONSerialization.jsonObject(with: data) as? [String: Any])
            .flatMap { $0?["title"] as? String } ?? ""
        var req = request(url, token: token)
        req.httpMethod = "PUT"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try JSONSerialization.data(withJSONObject: ["title": title, "draft": draft])
        let (pdata, presp) = try await session.data(for: req)
        try Self.checkStatus(presp, pdata)
    }

    func mergeChecks(
        host: String, owner: String, repo: String,
        number: Int, token: String
    ) async throws -> [PRMergeCheck] {
        let base = "\(Self.apiBase)/repositories/\(owner)/\(repo)"
        let prBase = "\(base)/pullrequests/\(number)"

        // PR participants (approvals / changes-requested), fetched fresh.
        guard let prURL = URL(string: prBase) else { return [] }
        let (prData, prResp) = try await send(prURL, token: token)
        try Self.checkStatus(prResp, prData)
        let prJSON = (try? JSONSerialization.jsonObject(with: prData)) as? [String: Any] ?? [:]
        let participants = (prJSON["participants"] as? [[String: Any]]) ?? []
        let approvedUUIDs = Set(participants
            .filter { ($0["approved"] as? Bool) == true }
            .compactMap { ($0["user"] as? [String: Any])?["uuid"] as? String })
        let changesRequested = participants.contains { ($0["state"] as? String) == "changes_requested" }

        // Build statuses.
        let statuses = (try? await jsonValues(prBase + "/statuses?pagelen=100", token: token)) ?? []
        let states = statuses.compactMap { $0["state"] as? String }
        let hasFailed = states.contains { $0 == "FAILED" || $0 == "STOPPED" }
        let hasInProgress = states.contains("INPROGRESS")
        let passedBuilds = states.filter { $0 == "SUCCESSFUL" }.count

        // Tasks (any unresolved blocks).
        let tasks = (try? await jsonValues(prBase + "/tasks?pagelen=100", token: token)) ?? []
        let unresolvedTasks = tasks.filter { ($0["state"] as? String) != "RESOLVED" }.count

        // Default reviewers → how many approved.
        let defaultReviewers = (try? await jsonValues(base + "/default-reviewers?pagelen=100", token: token)) ?? []
        let defaultReviewerUUIDs = Set(defaultReviewers.compactMap { $0["uuid"] as? String })
        let defaultApprovals = approvedUUIDs.intersection(defaultReviewerUUIDs).count

        var checks: [PRMergeCheck] = []
        // A repo with configured default reviewers has a review policy, so treat
        // "needs approval" as blocking (conservative ≥1 minimum — the exact
        // threshold lives in branch restrictions, which need repo-admin scope we
        // don't have; Bitbucket enforces the real count on the merge POST).
        let requiresReview = !defaultReviewerUUIDs.isEmpty
        checks.append(PRMergeCheck(
            title: "At least 1 approval (\(approvedUUIDs.count) so far)",
            passed: approvedUUIDs.count > 0, blocking: requiresReview))
        if requiresReview {
            checks.append(PRMergeCheck(
                title: "Default reviewer approved (\(defaultApprovals) of \(defaultReviewerUUIDs.count))",
                passed: defaultApprovals > 0, blocking: true))
        }
        checks.append(PRMergeCheck(title: "No changes requested", passed: !changesRequested, blocking: true))
        checks.append(PRMergeCheck(title: "No failed builds", passed: !hasFailed, blocking: true))
        checks.append(PRMergeCheck(title: "No in-progress builds", passed: !hasInProgress, blocking: true))
        if !states.isEmpty {
            checks.append(PRMergeCheck(title: "1+ build passed", passed: passedBuilds > 0, blocking: true))
        }
        // Always shown (matches Bitbucket's own checklist); passes when there are
        // no unresolved tasks — including the zero-tasks case.
        checks.append(PRMergeCheck(title: "All tasks resolved", passed: unresolvedTasks == 0, blocking: true))
        return checks
    }

    func download(host: String, url: URL, token: String) async throws -> Data {
        // Bitbucket `src` links 302-redirect to a CDN; `send` re-attaches auth.
        let (data, resp) = try await send(url, token: token)
        try Self.checkStatus(resp, data)
        return data
    }

    /// GET a paginated Bitbucket collection and return its `values` array.
    private func jsonValues(_ urlString: String, token: String) async throws -> [[String: Any]] {
        guard let url = URL(string: urlString) else { return [] }
        let (data, resp) = try await send(url, token: token)
        try Self.checkStatus(resp, data)
        let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
        return (json?["values"] as? [[String: Any]]) ?? []
    }

    // MARK: - Helpers

    private static func checkStatus(_ resp: URLResponse, _ data: Data) throws {
        guard let http = resp as? HTTPURLResponse else { return }
        guard (200..<300).contains(http.statusCode) else {
            throw PullRequestError.httpError(http.statusCode, message(data))
        }
    }

    /// Prefer Bitbucket's structured `error.message` over a raw dump.
    private static func message(_ data: Data) -> String {
        if let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let error = json["error"] as? [String: Any],
           let msg = error["message"] as? String {
            return msg
        }
        return snippet(data)
    }

    private static func snippet(_ data: Data) -> String {
        let s = String(data: data, encoding: .utf8) ?? ""
        return s.count > 300 ? String(s.prefix(300)) + "…" : s
    }
}

/// Re-attaches the Authorization (and Accept) header when a request is
/// redirected. Foundation drops custom headers across redirects, which breaks
/// Bitbucket's `/diffstat` and `/diff` endpoints (302 → unauthenticated → 404).
final class BitbucketRedirectAuth: NSObject, URLSessionTaskDelegate {
    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest,
        completionHandler: @escaping (URLRequest?) -> Void
    ) {
        var req = request
        if let auth = task.originalRequest?.value(forHTTPHeaderField: "Authorization") {
            req.setValue(auth, forHTTPHeaderField: "Authorization")
        }
        req.setValue("application/json", forHTTPHeaderField: "Accept")
        completionHandler(req)
    }
}
