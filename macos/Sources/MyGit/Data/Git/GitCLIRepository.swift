import Foundation

struct GitCLIRepository: GitRepository {

    // MARK: - Inspect

    func configValue(_ key: String, at repo: URL) async -> String? {
        let r = try? await GitRunner.run(["config", "--get", key], cwd: repo)
        guard let out = r?.stdout.trimmingCharacters(in: .whitespacesAndNewlines), !out.isEmpty else {
            return nil
        }
        return out
    }

    func status(at repo: URL) async throws -> GitStatusSummary {
        let out = try await GitRunner.runOrThrow(
            ["status", "--porcelain=v1", "-z", "--branch", "--untracked-files=all"],
            cwd: repo
        )
        var summary = GitStatusParser.parse(out)
        // Robust across worktrees/submodules where `.git` is a file: ask git directly.
        let merge = try? await GitRunner.run(["rev-parse", "-q", "--verify", "MERGE_HEAD"], cwd: repo)
        summary.mergeInProgress = (merge?.exitCode == 0)
        let pick = try? await GitRunner.run(["rev-parse", "-q", "--verify", "CHERRY_PICK_HEAD"], cwd: repo)
        summary.cherryPickInProgress = (pick?.exitCode == 0)
        return summary
    }

    func listFiles(at repo: URL) async throws -> [String] {
        let out = try await GitRunner.runOrThrow(["ls-files", "-z"], cwd: repo)
        return out.split(separator: "\0", omittingEmptySubsequences: true).map(String.init)
    }

    func grep(query: String, at repo: URL) async throws -> [GitGrepMatch] {
        let q = query.trimmingCharacters(in: .whitespaces)
        guard !q.isEmpty else { return [] }
        // `-I` skips binaries; fixed-string + case-insensitive; one hit per file
        // (keeps SearchHit ids unique — it's a file finder, not a line finder).
        // grep exits 1 when there are no matches (like `diff`), so use `run`.
        let result = try await GitRunner.run(
            ["grep", "-n", "-I", "--fixed-strings", "--ignore-case",
             "--max-count=1", "-e", q],
            cwd: repo
        )
        guard result.exitCode == 0 else { return [] }   // 1 = no matches
        var hits: [GitGrepMatch] = []
        for line in result.stdout.split(separator: "\n", omittingEmptySubsequences: true) {
            // Format: <path>:<lineno>:<text>
            let parts = line.split(separator: ":", maxSplits: 2, omittingEmptySubsequences: false)
            guard parts.count == 3, let n = Int(parts[1]) else { continue }
            let preview = parts[2].trimmingCharacters(in: .whitespaces)
            hits.append(GitGrepMatch(path: String(parts[0]), line: n,
                                     preview: String(preview.prefix(200))))
            if hits.count >= 500 { break }
        }
        return hits
    }

    func searchSymbol(_ symbol: String, at repo: URL) async throws -> [GitGrepMatch] {
        let sym = symbol.trimmingCharacters(in: .whitespaces)
        guard !sym.isEmpty else { return [] }
        // Whole-word, case-sensitive, every hit per file (unlike `grep`, which
        // caps at one — here the line numbers are the point).
        let result = try await GitRunner.run(
            ["grep", "-n", "-I", "--word-regexp", "--fixed-strings", "-e", sym],
            cwd: repo
        )
        guard result.exitCode == 0 else { return [] }   // 1 = no matches
        return GitCLIRepository.parseGrepLines(result.stdout, limit: 2000)
    }

    /// `<path>:<lineno>:<text>` lines from `git grep -n`.
    private static func parseGrepLines(_ out: String, limit: Int) -> [GitGrepMatch] {
        var hits: [GitGrepMatch] = []
        for line in out.split(separator: "\n", omittingEmptySubsequences: true) {
            let parts = line.split(separator: ":", maxSplits: 2, omittingEmptySubsequences: false)
            guard parts.count == 3, let n = Int(parts[1]) else { continue }
            let preview = parts[2].trimmingCharacters(in: .whitespaces)
            hits.append(GitGrepMatch(path: String(parts[0]), line: n,
                                     preview: String(preview.prefix(200))))
            if hits.count >= limit { break }
        }
        return hits
    }

    func log(at repo: URL, limit: Int) async throws -> [GitCommit] {
        let out = try await GitRunner.runOrThrow(
            ["log", "-n", String(limit), "--pretty=format:\(GitLogParser.format)"],
            cwd: repo
        )
        return GitLogParser.parse(out)
    }

    func graphLog(at repo: URL, limit: Int, filter: HistoryFilter) async throws -> [GitCommit] {
        var args = ["log", "--decorate=full", "-n", String(limit),
                    "--pretty=format:\(GitLogParser.format)"]
        args.append(filter.sort == .date ? "--date-order" : "--topo-order")

        switch filter.branchScope {
        case .all: args.append("--all")
        case .ref(let r): args.append(r)
        }

        if let author = filter.author, !author.isEmpty { args.append("--author=\(author)") }
        if let since = filter.since, !since.isEmpty { args.append("--since=\(since)") }
        if let until = filter.until, !until.isEmpty { args.append("--until=\(until)") }

        let text = filter.searchText.trimmingCharacters(in: .whitespaces)
        if !text.isEmpty {
            args.append("--grep=\(text)")
            if !filter.caseSensitive { args.append("-i") }
            args.append(filter.useRegex ? "--extended-regexp" : "--fixed-strings")
        }

        if !filter.paths.isEmpty {
            args.append("--")
            args.append(contentsOf: filter.paths)
        }

        let out = try await GitRunner.runOrThrow(args, cwd: repo)
        return GitLogParser.parse(out)
    }

    func tags(at repo: URL) async throws -> [String] {
        let out = try await GitRunner.runOrThrow(["tag", "--sort=-creatordate"], cwd: repo)
        return out.split(separator: "\n")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
    }

    func diff(at repo: URL, change: FileChange) async throws -> FileDiff {
        let args: [String]
        if change.isUntracked {
            args = ["diff", "--no-index", "--no-color", "--", "/dev/null", change.path]
        } else if change.isStaged {
            args = ["diff", "--cached", "--no-color", "--", change.path]
        } else {
            args = ["diff", "--no-color", "--", change.path]
        }
        let r = try? await GitRunner.run(args, cwd: repo)
        return GitDiffParser.parse(r?.stdout ?? "", path: change.path)
    }

    func diff(at repo: URL, commit: GitCommit) async throws -> FileDiff {
        let out = try await GitRunner.runOrThrow(
            ["show", "--patch", "--no-color", "--first-parent", commit.hash],
            cwd: repo
        )
        return GitDiffParser.parse(out, path: commit.subject)
    }

    func lsTree(at repo: URL, path: String?) async throws -> [FileTreeNode] {
        let args = path.map { ["ls-tree", "HEAD", $0 + "/"] } ?? ["ls-tree", "HEAD"]
        let out = try await GitRunner.runOrThrow(args, cwd: repo)
        return GitFileTree.parse(output: out)
    }

    func account(at repo: URL) async -> GitAccount {
        await GitAccountLoader.load(cwd: repo)
    }

    func setRemoteURL(_ url: String, name: String, at repo: URL) async throws {
        _ = try await GitRunner.runOrThrow(
            ["remote", "set-url", name, url],
            cwd: repo
        )
    }

    func addRemote(name: String, url: String, at repo: URL) async throws {
        _ = try await GitRunner.runOrThrow(
            ["remote", "add", name, url],
            cwd: repo
        )
    }

    // MARK: - Commit

    func commit(at repo: URL, paths: [String], message: String) async throws {
        _ = try await GitRunner.runOrThrow(["reset", "--mixed", "-q"], cwd: repo)
        if !paths.isEmpty {
            _ = try await GitRunner.runOrThrow(["add", "--"] + paths, cwd: repo)
        }
        _ = try await GitRunner.runOrThrow(["commit", "-m", message], cwd: repo)
    }

    func amend(at repo: URL, paths: [String], newMessage: String?) async throws {
        _ = try await GitRunner.runOrThrow(["reset", "--mixed", "-q"], cwd: repo)
        if !paths.isEmpty {
            _ = try await GitRunner.runOrThrow(["add", "--"] + paths, cwd: repo)
        }
        if let msg = newMessage {
            _ = try await GitRunner.runOrThrow(["commit", "--amend", "-m", msg], cwd: repo)
        } else {
            _ = try await GitRunner.runOrThrow(["commit", "--amend", "--no-edit"], cwd: repo)
        }
    }

    func headExists(at repo: URL) async -> Bool {
        do {
            _ = try await GitRunner.runOrThrow(["rev-parse", "--verify", "--quiet", "HEAD"], cwd: repo)
            return true
        } catch {
            return false
        }
    }

    func headCommitMessage(at repo: URL) async throws -> String {
        let out = try await GitRunner.runOrThrow(["log", "-1", "--pretty=%B"], cwd: repo)
        return out.trimmingCharacters(in: CharacterSet.newlines)
    }

    func stashPush(message: String?, at repo: URL) async throws {
        var args = ["stash", "push", "--include-untracked"]
        if let m = message, !m.isEmpty { args += ["-m", m] }
        _ = try await GitRunner.runOrThrow(args, cwd: repo)
    }

    func stashList(at repo: URL) async throws -> [GitStash] {
        let out = try await GitRunner.runOrThrow(
            ["stash", "list", "--format=\(GitStashParser.format)"],
            cwd: repo
        )
        return GitStashParser.parse(out)
    }

    func stashApply(index: Int, at repo: URL) async throws {
        _ = try await GitRunner.runOrThrow(["stash", "apply", "stash@{\(index)}"], cwd: repo)
    }

    func stashPop(index: Int, at repo: URL) async throws {
        _ = try await GitRunner.runOrThrow(["stash", "pop", "stash@{\(index)}"], cwd: repo)
    }

    func stashDrop(index: Int, at repo: URL) async throws {
        _ = try await GitRunner.runOrThrow(["stash", "drop", "stash@{\(index)}"], cwd: repo)
    }

    func stashClear(at repo: URL) async throws {
        _ = try await GitRunner.runOrThrow(["stash", "clear"], cwd: repo)
    }

    func stashFiles(index: Int, at repo: URL) async throws -> [String] {
        let out = try await GitRunner.runOrThrow(
            ["stash", "show", "--name-only", "stash@{\(index)}"],
            cwd: repo
        )
        return out.split(separator: "\n").map(String.init).filter { !$0.isEmpty }
    }

    // MARK: - File ops

    func restore(at repo: URL, paths: [String]) async throws {
        guard !paths.isEmpty else { return }
        _ = try await GitRunner.runOrThrow(
            ["restore", "--staged", "--worktree", "--"] + paths,
            cwd: repo
        )
    }

    func addToIndex(at repo: URL, paths: [String]) async throws {
        guard !paths.isEmpty else { return }
        _ = try await GitRunner.runOrThrow(["add", "--"] + paths, cwd: repo)
    }

    func removeFile(at repo: URL, path: String, tracked: Bool) async throws {
        if tracked {
            _ = try await GitRunner.runOrThrow(["rm", "-f", "--", path], cwd: repo)
        } else {
            let url = repo.appendingPathComponent(path)
            try FileManager.default.removeItem(at: url)
        }
    }

    func discardAll(at repo: URL, includeUntracked: Bool) async throws {
        // `reset --hard` needs a commit to reset to; an unborn HEAD (no commits
        // yet) only has an index to clear. It also clears MERGE_HEAD, so a
        // rollback during a conflicted merge leaves the repo in a clean state.
        let head = try await GitRunner.run(["rev-parse", "--verify", "-q", "HEAD"], cwd: repo)
        if head.exitCode == 0 {
            _ = try await GitRunner.runOrThrow(["reset", "--hard", "HEAD"], cwd: repo)
        } else {
            _ = try await GitRunner.runOrThrow(["rm", "-r", "-q", "--cached", "--ignore-unmatch", "."], cwd: repo)
        }
        if includeUntracked {
            // -d removes untracked directories; no -x, so ignored files (build
            // output, .env, …) survive.
            _ = try await GitRunner.runOrThrow(["clean", "-f", "-d", "-q"], cwd: repo)
        }
    }

    func diffPatch(at repo: URL, changes: [FileChange]) async throws -> String {
        guard !changes.isEmpty else { return "" }
        var patch = ""
        let tracked = changes.filter { !$0.isUntracked }.map { $0.path }
        let untracked = changes.filter { $0.isUntracked }.map { $0.path }

        if !tracked.isEmpty {
            let r = try await GitRunner.run(
                ["diff", "HEAD", "--no-color", "--binary", "--"] + tracked,
                cwd: repo
            )
            patch += r.stdout
        }
        for path in untracked {
            let r = try? await GitRunner.run(
                ["diff", "--no-index", "--no-color", "--binary", "--", "/dev/null", path],
                cwd: repo
            )
            patch += r?.stdout ?? ""
        }
        return patch
    }

    // MARK: - Remote

    func fetch(at repo: URL, auth: AuthOverride?) async throws {
        _ = try await GitRunner.runOrThrow(authPrefix(auth) + ["fetch", "--prune", "origin"], cwd: repo)
    }

    func pull(at repo: URL, auth: AuthOverride?) async throws {
        _ = try await GitRunner.runOrThrow(authPrefix(auth) + ["pull", "--ff-only"], cwd: repo)
    }

    func push(at repo: URL, args: [String], auth: AuthOverride?) async throws {
        _ = try await GitRunner.runOrThrow(authPrefix(auth) + args, cwd: repo)
    }

    func upstreamRef(at repo: URL) async -> String? {
        let res = try? await GitRunner.run(
            ["rev-parse", "--abbrev-ref", "--symbolic-full-name", "@{upstream}"],
            cwd: repo
        )
        guard let res, res.exitCode == 0 else { return nil }
        let name = res.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        return name.isEmpty ? nil : name
    }

    private func authPrefix(_ auth: AuthOverride?) -> [String] {
        guard let auth else { return [] }
        return [
            "-c", "credential.helper=",
            "-c", "http.extraheader=AUTHORIZATION: bearer \(auth.bearerToken)"
        ]
    }

    // MARK: - Branches

    func branches(at repo: URL, currentBranch: String?) async throws -> [GitBranch] {
        let out = try await GitRunner.runOrThrow(
            ["for-each-ref",
             "--format=%(refname)%00%(upstream:short)%00%(HEAD)",
             "refs/heads", "refs/remotes"],
            cwd: repo
        )
        return GitBranchParser.parse(out, currentBranch: currentBranch)
    }

    func recentBranches(at repo: URL) async throws -> [String] {
        let out = try await GitRunner.runOrThrow(
            ["reflog", "-n", "500", "--pretty=%gs"],
            cwd: repo
        )
        var seen: Set<String> = []
        var result: [String] = []
        let pattern = #"^checkout: moving from .+ to (.+)$"#
        let regex = try! NSRegularExpression(pattern: pattern)
        for line in out.split(separator: "\n") {
            let s = String(line)
            guard let match = regex.firstMatch(in: s, range: NSRange(s.startIndex..., in: s)),
                  let r = Range(match.range(at: 1), in: s) else { continue }
            let name = String(s[r])
            if seen.insert(name).inserted {
                result.append(name)
                if result.count >= 10 { break }
            }
        }
        return result
    }

    func checkout(_ name: String, at repo: URL) async throws {
        _ = try await GitRunner.runOrThrow(["checkout", name], cwd: repo)
    }

    func createBranch(_ name: String, from: String, at repo: URL) async throws {
        _ = try await GitRunner.runOrThrow(["checkout", "-b", name, from], cwd: repo)
    }

    func checkoutAndRebase(branch: String, onto: String, at repo: URL) async throws {
        _ = try await GitRunner.runOrThrow(["checkout", branch], cwd: repo)
        _ = try await GitRunner.runOrThrow(["rebase", onto], cwd: repo)
    }

    func checkoutAndUpdate(branch: String, at repo: URL) async throws {
        _ = try await GitRunner.runOrThrow(["checkout", branch], cwd: repo)
        _ = try await GitRunner.runOrThrow(["pull", "--ff-only"], cwd: repo)
    }

    func compareBranches(a: String, b: String, at repo: URL) async throws -> String {
        try await GitRunner.runOrThrow(["log", "--oneline", "\(b)..\(a)"], cwd: repo)
    }

    func diffWithWorkingTree(branch: String, at repo: URL) async throws -> String {
        let r = try await GitRunner.run(["diff", "--no-color", branch], cwd: repo)
        return r.stdout
    }

    func rebase(base: String, onto: String, at repo: URL) async throws {
        _ = try await GitRunner.runOrThrow(["checkout", base], cwd: repo)
        _ = try await GitRunner.runOrThrow(["rebase", onto], cwd: repo)
    }

    func merge(source: String, into target: String, at repo: URL) async throws {
        _ = try await GitRunner.runOrThrow(["checkout", target], cwd: repo)
        _ = try await GitRunner.runOrThrow(["merge", source], cwd: repo)
    }

    func abortMerge(at repo: URL) async throws {
        _ = try await GitRunner.runOrThrow(["merge", "--abort"], cwd: repo)
    }

    func resolveConflict(path: String, using side: ConflictSide, at repo: URL) async throws {
        let flag = side == .ours ? "--ours" : "--theirs"
        // Take that side's whole version (works for files and submodule gitlinks)…
        _ = try await GitRunner.runOrThrow(["checkout", flag, "--", path], cwd: repo)
        // …then stage it to clear the unmerged index entry.
        _ = try await GitRunner.runOrThrow(["add", "--", path], cwd: repo)
    }

    func markResolved(paths: [String], at repo: URL) async throws {
        guard !paths.isEmpty else { return }
        _ = try await GitRunner.runOrThrow(["add", "--"] + paths, cwd: repo)
    }

    func commitMerge(at repo: URL) async throws {
        _ = try await GitRunner.runOrThrow(["commit", "--no-edit"], cwd: repo)
    }

    func readMergeStage(_ stage: Int, path: String, at repo: URL) async throws -> String {
        let r = try await GitRunner.run(["show", ":\(stage):\(path)"], cwd: repo)
        return r.exitCode == 0 ? r.stdout : ""
    }

    func readMergeConflict(path: String, at repo: URL) async throws -> (base: String, ours: String, theirs: String) {
        async let base = readMergeStage(1, path: path, at: repo)
        async let ours = readMergeStage(2, path: path, at: repo)
        async let theirs = readMergeStage(3, path: path, at: repo)
        return try await (base, ours, theirs)
    }

    func isTextConflict(path: String, at repo: URL) async -> Bool {
        // Gitlink (submodule) conflicts have no blob to `git show` as text and both
        // stages come back empty; binary blobs contain a NUL byte. Either -> not mergeable.
        let ours = (try? await readMergeStage(2, path: path, at: repo)) ?? ""
        let theirs = (try? await readMergeStage(3, path: path, at: repo)) ?? ""
        if ours.isEmpty && theirs.isEmpty { return false }
        if ours.contains("\0") || theirs.contains("\0") { return false }
        return true
    }

    func mergeSourceName(at repo: URL) async -> String? {
        guard let r = try? await GitRunner.run(["name-rev", "--name-only", "MERGE_HEAD"], cwd: repo),
              r.exitCode == 0 else { return nil }
        var name = r.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, name != "undefined" else { return nil }
        // "master~2" / "tags/x^0" -> drop the relative suffix; keep the leaf.
        if let cut = name.firstIndex(where: { $0 == "~" || $0 == "^" }) { name = String(name[..<cut]) }
        name = name.replacingOccurrences(of: "remotes/", with: "")
        return name.split(separator: "/").last.map(String.init) ?? name
    }

    func updateBranch(_ name: String, isCurrent: Bool, at repo: URL) async throws {
        if isCurrent {
            _ = try await GitRunner.runOrThrow(["pull", "--ff-only"], cwd: repo)
        } else {
            _ = try await GitRunner.runOrThrow(["fetch", "origin", "\(name):\(name)"], cwd: repo)
        }
    }

    func setUpstream(branch: String, upstream: String, at repo: URL) async throws {
        _ = try await GitRunner.runOrThrow(
            ["branch", "--set-upstream-to=\(upstream)", branch],
            cwd: repo
        )
    }

    func renameBranch(old: String, new: String, at repo: URL) async throws {
        _ = try await GitRunner.runOrThrow(["branch", "-m", old, new], cwd: repo)
    }

    func deleteBranch(_ name: String, force: Bool, at repo: URL) async throws {
        _ = try await GitRunner.runOrThrow(["branch", force ? "-D" : "-d", name], cwd: repo)
    }

    func newWorktree(path: URL, from: String, at repo: URL) async throws {
        _ = try await GitRunner.runOrThrow(["worktree", "add", path.path, from], cwd: repo)
    }

    func checkoutRevision(_ rev: String, at repo: URL) async throws {
        _ = try await GitRunner.runOrThrow(["checkout", rev], cwd: repo)
    }

    // MARK: - Commit actions

    @discardableResult
    func cherryPick(commit: String, at repo: URL) async throws -> CherryPickOutcome {
        let args = ["cherry-pick", commit]
        let r = try await GitRunner.run(args, cwd: repo)
        if r.exitCode == 0 { return .done }

        // Git reports both mid-flight endings on a non-zero exit; tell them
        // apart so the UI can offer skip/commit-empty vs. conflict resolution.
        let output = r.stderr + r.stdout
        if output.contains("is now empty") || output.contains("nothing to commit") {
            return .empty
        }
        if let s = try? await status(at: repo), s.cherryPickInProgress || s.hasConflicts {
            return .conflicts
        }
        throw GitError.nonZeroExit(args: args, code: r.exitCode, stderr: r.stderr)
    }

    func cherryPickSkip(at repo: URL) async throws {
        _ = try await GitRunner.runOrThrow(["cherry-pick", "--skip"], cwd: repo)
    }

    func cherryPickAbort(at repo: URL) async throws {
        _ = try await GitRunner.runOrThrow(["cherry-pick", "--abort"], cwd: repo)
    }

    func cherryPickContinue(at repo: URL) async throws {
        // `core.editor=true` keeps --continue from opening an editor for the
        // commit message (GIT_TERMINAL_PROMPT=0 would leave it hanging).
        _ = try await GitRunner.runOrThrow(
            ["-c", "core.editor=true", "cherry-pick", "--continue"], cwd: repo
        )
    }

    func cherryPickCommitEmpty(at repo: URL) async throws {
        _ = try await GitRunner.runOrThrow(["commit", "--allow-empty", "--no-edit"], cwd: repo)
        // Single-commit picks are finished by that commit and `--continue` then
        // errors with "no cherry-pick in progress"; only resume a live sequence.
        let r = try await GitRunner.run(["rev-parse", "-q", "--verify", "CHERRY_PICK_HEAD"], cwd: repo)
        if r.exitCode == 0 { try await cherryPickContinue(at: repo) }
    }

    func revertCommit(_ commit: String, at repo: URL) async throws {
        _ = try await GitRunner.runOrThrow(["revert", "--no-edit", commit], cwd: repo)
    }

    func resetTo(commit: String, mode: GitResetMode, at repo: URL) async throws {
        _ = try await GitRunner.runOrThrow(["reset", mode.flag, commit], cwd: repo)
    }

    func formatPatch(commit: String, at repo: URL) async throws -> String {
        try await GitRunner.runOrThrow(["format-patch", "-1", "--stdout", commit], cwd: repo)
    }

    func createTag(_ name: String, at commit: String, message: String?, at repo: URL) async throws {
        if let message, !message.isEmpty {
            _ = try await GitRunner.runOrThrow(["tag", "-a", "-m", message, name, commit], cwd: repo)
        } else {
            _ = try await GitRunner.runOrThrow(["tag", name, commit], cwd: repo)
        }
    }

    func lsTreeAtRevision(_ rev: String, at repo: URL) async throws -> [String] {
        let out = try await GitRunner.runOrThrow(["ls-tree", "-r", "--name-only", rev], cwd: repo)
        return out.split(separator: "\n").map(String.init)
    }

    func pushedHashes(at repo: URL) async throws -> Set<String> {
        // No upstream → no pushed commits. `run` (not runOrThrow) so a missing
        // upstream just yields an empty set instead of throwing.
        let r = try await GitRunner.run(["rev-list", "@{upstream}"], cwd: repo)
        guard r.exitCode == 0 else { return [] }
        return Set(r.stdout.split(separator: "\n").map(String.init))
    }

    func refsPointingAt(commit: String, at repo: URL) async throws -> [String] {
        let out = try await GitRunner.runOrThrow(
            ["for-each-ref", "--points-at", commit, "--format=%(refname)%00%(refname:short)",
             "refs/heads", "refs/remotes", "refs/tags"],
            cwd: repo
        )
        return GitCLIRepository.shortRefNames(out)
    }

    /// `<full ref>\0<short name>` lines → short names, minus each remote's
    /// symbolic `refs/remotes/<remote>/HEAD` (which shortens to just "origin").
    private static func shortRefNames(_ out: String) -> [String] {
        out.split(separator: "\n").compactMap { line in
            let parts = line.split(separator: "\0", omittingEmptySubsequences: false).map(String.init)
            guard parts.count == 2, !parts[0].hasSuffix("/HEAD") else { return nil }
            let name = parts[1].trimmingCharacters(in: .whitespaces)
            return name.isEmpty ? nil : name
        }
    }

    func branchesContaining(commit: String, at repo: URL) async throws -> (local: [String], remote: [String]) {
        // `run` (not runOrThrow): an unknown/unborn revision just yields nothing.
        @Sendable func names(_ args: [String]) async -> [String] {
            let r = try? await GitRunner.run(args, cwd: repo)
            guard let r, r.exitCode == 0 else { return [] }
            return GitCLIRepository.shortRefNames(r.stdout)
        }
        let fmt = "--format=%(refname)%00%(refname:short)"
        async let local = names(["branch", "--contains", commit, fmt])
        async let remote = names(["branch", "--remotes", "--contains", commit, fmt])
        return await (local: local, remote: remote)
    }

    func isAncestor(_ commit: String, of ref: String, at repo: URL) async -> Bool {
        let r = try? await GitRunner.run(["merge-base", "--is-ancestor", commit, ref], cwd: repo)
        return r?.exitCode == 0
    }

    func amendMessage(_ message: String, at repo: URL) async throws {
        _ = try await GitRunner.runOrThrow(["commit", "--amend", "-m", message], cwd: repo)
    }

    func interactiveRebase(todo: [RebaseStep], onto base: String, at repo: URL) async throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("mygit-rebase-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let todoFile = dir.appendingPathComponent("todo")
        let todoText = todo.map { $0.todoLine }.joined(separator: "\n") + "\n"
        try todoText.write(to: todoFile, atomically: true, encoding: .utf8)

        // Override the sequence editor so git never opens a terminal editor:
        // git runs `<value> <git-todo-file>`, i.e. cp our todo over git's.
        var cfg = ["-c", "sequence.editor=/bin/cp \(shellQuote(todoFile.path))"]

        // A single reworded commit: feed its message via core.editor the same way.
        if let msg = todo.compactMap({ $0.rewordMessage }).first {
            let msgFile = dir.appendingPathComponent("msg")
            try msg.write(to: msgFile, atomically: true, encoding: .utf8)
            cfg += ["-c", "core.editor=/bin/cp \(shellQuote(msgFile.path))"]
        }

        let r = try await GitRunner.run(cfg + ["rebase", "-i", base], cwd: repo)
        if r.exitCode != 0 {
            // Leave the repo clean rather than mid-rebase on conflict/failure.
            _ = try? await GitRunner.run(["rebase", "--abort"], cwd: repo)
            throw GitError.nonZeroExit(args: ["rebase", "-i", base], code: r.exitCode, stderr: r.stderr)
        }
    }

    private func shellQuote(_ path: String) -> String {
        "'" + path.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    // MARK: - Compare

    func commitsInRange(_ range: String, at repo: URL) async throws -> [GitCommit] {
        let out = try await GitRunner.runOrThrow(
            ["log", range, "--pretty=format:\(GitLogParser.format)"],
            cwd: repo
        )
        return GitLogParser.parse(out)
    }

    func changedFiles(commit: String, at repo: URL) async throws -> [ChangedFileEntry] {
        let r = try await GitRunner.run(
            ["diff-tree", "--no-color", "--no-commit-id", "--name-status", "-r", "-z", commit],
            cwd: repo
        )
        let out = r.stdout
        guard !out.isEmpty else { return [] }
        var result: [ChangedFileEntry] = []
        let records = out.split(separator: "\0", omittingEmptySubsequences: true).map(String.init)
        var i = 0
        while i < records.count {
            let statusField = records[i]
            let statusChar = String(statusField.prefix(1))
            let status = ChangedFileStatus(rawValue: statusChar) ?? .unknown
            i += 1
            if status == .renamed || status == .copied {
                let oldPath = i < records.count ? records[i] : ""
                i += 1
                let newPath = i < records.count ? records[i] : ""
                i += 1
                result.append(ChangedFileEntry(path: newPath, oldPath: oldPath.isEmpty ? nil : oldPath, status: status))
            } else {
                let path = i < records.count ? records[i] : ""
                i += 1
                guard !path.isEmpty else { continue }
                result.append(ChangedFileEntry(path: path, oldPath: nil, status: status))
            }
        }
        return result
    }

    func changedFiles(range: String, at repo: URL) async throws -> [ChangedFileEntry] {
        let r = try await GitRunner.run(
            ["diff", "--no-color", "--name-status", "-M", "-z", range],
            cwd: repo
        )
        let out = r.stdout
        guard !out.isEmpty else { return [] }
        var result: [ChangedFileEntry] = []
        let records = out.split(separator: "\0", omittingEmptySubsequences: true).map(String.init)
        var i = 0
        while i < records.count {
            let statusField = records[i]
            let statusChar = String(statusField.prefix(1))
            let status = ChangedFileStatus(rawValue: statusChar) ?? .unknown
            i += 1
            if status == .renamed || status == .copied {
                let oldPath = i < records.count ? records[i] : ""
                i += 1
                let newPath = i < records.count ? records[i] : ""
                i += 1
                result.append(ChangedFileEntry(path: newPath, oldPath: oldPath.isEmpty ? nil : oldPath, status: status))
            } else {
                let path = i < records.count ? records[i] : ""
                i += 1
                guard !path.isEmpty else { continue }
                result.append(ChangedFileEntry(path: path, oldPath: nil, status: status))
            }
        }
        return result
    }

    func rangeFilePatch(range: String, path: String, at repo: URL) async throws -> String {
        let r = try await GitRunner.run(["diff", "--no-color", range, "--", path], cwd: repo)
        return r.stdout
    }

    func rangeDiff(range: String, at repo: URL) async throws -> String {
        let r = try await GitRunner.run(["diff", "--no-color", range], cwd: repo)
        return r.stdout
    }

    func showFileAtCommit(commit: String, path: String, at repo: URL) async throws -> FileDiff {
        let r = try await GitRunner.run(
            ["show", "--no-color", "--format=", commit, "--", path],
            cwd: repo
        )
        return GitDiffParser.parse(r.stdout, path: path)
    }

    func touchedHashes(range: String, paths: [String], at repo: URL) async throws -> Set<String> {
        guard !paths.isEmpty else { return [] }
        let args = ["log", range, "--pretty=format:%H"] + ["--"] + paths
        let out = try await GitRunner.runOrThrow(args, cwd: repo)
        let hashes = Set(out.components(separatedBy: .newlines).map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty })
        return hashes
    }

    func diffFileVsWorking(commit: String, path: String, at repo: URL) async throws -> FileDiff {
        let r = try await GitRunner.run(["diff", "--no-color", commit, "--", path], cwd: repo)
        return GitDiffParser.parse(r.stdout, path: path)
    }

    func diffFileBeforeVsWorking(commit: String, path: String, at repo: URL) async throws -> FileDiff {
        let r = try await GitRunner.run(["diff", "--no-color", "\(commit)^1", "--", path], cwd: repo)
        return GitDiffParser.parse(r.stdout, path: path)
    }

    func extractFileAtCommit(commit: String, path: String, at repo: URL) async throws -> URL {
        let out = try await GitRunner.runOrThrow(["show", "\(commit):\(path)"], cwd: repo)
        let base = (path as NSString).lastPathComponent
        let shortCommit = String(commit.prefix(7))
        let tmpDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("MyGit-\(shortCommit)-\(UUID().uuidString.prefix(6))", isDirectory: true)
        try FileManager.default.createDirectory(at: tmpDir, withIntermediateDirectories: true)
        let outURL = tmpDir.appendingPathComponent(base)
        try out.write(to: outURL, atomically: true, encoding: .utf8)
        return outURL
    }

    func revertFileInCommit(commit: String, path: String, at repo: URL) async throws {
        let patch = try await GitRunner.runOrThrow(
            ["show", commit, "--no-color", "--format=", "--", path],
            cwd: repo
        )
        guard !patch.isEmpty else { return }
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("mygit-revert-\(UUID().uuidString).patch")
        try patch.write(to: tmp, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: tmp) }
        _ = try await GitRunner.runOrThrow(["apply", "--reverse", "--3way", tmp.path], cwd: repo)
    }

    func cherryPickFileFromCommit(commit: String, path: String, at repo: URL) async throws {
        let patch = try await GitRunner.runOrThrow(
            ["show", commit, "--no-color", "--format=", "--", path],
            cwd: repo
        )
        guard !patch.isEmpty else { return }
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("mygit-pick-\(UUID().uuidString).patch")
        try patch.write(to: tmp, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: tmp) }
        _ = try await GitRunner.runOrThrow(["apply", "--3way", tmp.path], cwd: repo)
    }

    func patchForFile(commit: String, path: String, at repo: URL) async throws -> String {
        try await GitRunner.runOrThrow(
            ["show", commit, "--no-color", "--format=", "--", path],
            cwd: repo
        )
    }

    func readFileAtCommit(commit: String, path: String, at repo: URL) async throws -> String {
        let r = try await GitRunner.run(["show", "\(commit):\(path)"], cwd: repo)
        return r.stdout
    }
}
