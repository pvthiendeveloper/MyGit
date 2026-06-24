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
}
