import Foundation

enum GitError: LocalizedError {
    case nonZeroExit(args: [String], code: Int32, stderr: String)
    case launchFailed(String)

    var errorDescription: String? {
        switch self {
        case let .nonZeroExit(args, code, stderr):
            let cmd = "git " + args.joined(separator: " ")
            return "\(cmd) exited \(code): \(stderr.trimmingCharacters(in: .whitespacesAndNewlines))"
        case let .launchFailed(reason):
            return "Failed to launch git: \(reason)"
        }
    }
}

struct GitResult {
    let stdout: String
    let stderr: String
    let exitCode: Int32
}

enum GitRunner {
    /// Shell out to /usr/bin/git. Returns even on non-zero exit so callers can
    /// inspect (some commands like `diff --no-index` exit 1 when diffs exist).
    static func run(_ args: [String], cwd: URL) async throws -> GitResult {
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<GitResult, Error>) in
            DispatchQueue.global(qos: .userInitiated).async {
                let proc = Process()
                proc.executableURL = URL(fileURLWithPath: "/usr/bin/git")
                proc.arguments = args
                proc.currentDirectoryURL = cwd

                var env = ProcessInfo.processInfo.environment
                env["GIT_TERMINAL_PROMPT"] = "0"
                env["LC_ALL"] = "C"
                proc.environment = env

                let outPipe = Pipe()
                let errPipe = Pipe()
                proc.standardOutput = outPipe
                proc.standardError = errPipe

                do {
                    try proc.run()
                } catch {
                    cont.resume(throwing: GitError.launchFailed("\(error)"))
                    return
                }

                let outData = outPipe.fileHandleForReading.readDataToEndOfFile()
                let errData = errPipe.fileHandleForReading.readDataToEndOfFile()
                proc.waitUntilExit()

                cont.resume(returning: GitResult(
                    stdout: String(data: outData, encoding: .utf8) ?? "",
                    stderr: String(data: errData, encoding: .utf8) ?? "",
                    exitCode: proc.terminationStatus
                ))
            }
        }
    }

    @discardableResult
    static func runOrThrow(_ args: [String], cwd: URL) async throws -> String {
        let r = try await run(args, cwd: cwd)
        if r.exitCode != 0 {
            throw GitError.nonZeroExit(args: args, code: r.exitCode, stderr: r.stderr)
        }
        return r.stdout
    }
}
