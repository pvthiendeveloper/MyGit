import Foundation

struct GitCLIRepository: GitRepository {

    // MARK: - Inspect

    func status(at repo: URL) async throws -> GitStatusSummary {
        let out = try await GitRunner.runOrThrow(
            ["status", "--porcelain=v1", "-z", "--branch", "--untracked-files=all"],
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
