import Foundation

struct GitCLIRepository: GitRepository {

    // MARK: - Inspect

    func status(at repo: URL) async throws -> GitStatusSummary {
        let out = try await GitRunner.runOrThrow(
            ["status", "--porcelain=v1", "-z", "--branch"],
            cwd: repo
        )
        return GitStatusParser.parse(out)
    }

    func log(at repo: URL, limit: Int) async throws -> [GitCommit] {
        let out = try await GitRunner.runOrThrow(
            ["log", "-n", String(limit), "--pretty=format:\(GitLogParser.format)"],
            cwd: repo
        )
        return GitLogParser.parse(out)
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

    func stashPush(message: String?, at repo: URL) async throws {
        var args = ["stash", "push", "--include-untracked"]
        if let m = message, !m.isEmpty { args += ["-m", m] }
        _ = try await GitRunner.runOrThrow(args, cwd: repo)
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

    func cherryPick(commit: String, at repo: URL) async throws {
        _ = try await GitRunner.runOrThrow(["cherry-pick", commit], cwd: repo)
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
            ["diff-tree", "--no-color", "--name-status", "-r", "-z", commit],
            cwd: repo
        )
        let out = r.stdout
        guard !out.isEmpty else { return [] }
        var result: [ChangedFileEntry] = []
        let records = out.split(separator: "\0", omittingEmptySubsequences: false).map(String.init)
        var i = 0
        while i < records.count {
            let rec = records[i]
            guard !rec.isEmpty else { i += 1; continue }
            let statusChar = String(rec.prefix(1))
            let status = ChangedFileStatus(rawValue: statusChar) ?? .unknown
            if status == .renamed || status == .copied {
                let oldPath = String(rec.dropFirst())
                i += 1
                let newPath = i < records.count ? records[i] : ""
                result.append(ChangedFileEntry(path: newPath, oldPath: oldPath.isEmpty ? nil : oldPath, status: status))
            } else {
                result.append(ChangedFileEntry(path: String(rec.dropFirst()), oldPath: nil, status: status))
            }
            i += 1
        }
        return result
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
}
