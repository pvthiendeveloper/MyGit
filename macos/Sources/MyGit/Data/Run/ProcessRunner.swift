import Foundation

/// Minimal out-of-process command runner for the run controls (adb, xcrun,
/// gradle queries). `GitRunner` is git-only, and these tools live outside the
/// app's PATH, so each call takes an absolute executable path.
enum ProcessRunner {
    struct Result {
        let stdout: String
        let stderr: String
        let exitCode: Int32
    }

    static func run(_ executable: String, _ args: [String], cwd: URL? = nil,
                    timeout: TimeInterval = 20) async -> Result {
        await withCheckedContinuation { (cont: CheckedContinuation<Result, Never>) in
            DispatchQueue.global(qos: .userInitiated).async {
                let proc = Process()
                proc.executableURL = URL(fileURLWithPath: executable)
                proc.arguments = args
                if let cwd { proc.currentDirectoryURL = cwd }
                var env = ProcessInfo.processInfo.environment
                env["LC_ALL"] = "C"
                proc.environment = env

                let out = Pipe(), err = Pipe()
                proc.standardOutput = out
                proc.standardError = err
                do { try proc.run() } catch {
                    cont.resume(returning: Result(stdout: "", stderr: "\(error)", exitCode: -1))
                    return
                }
                // Kill runaway tools (an unresponsive adb server would hang the picker).
                let deadline = DispatchWorkItem { if proc.isRunning { proc.terminate() } }
                DispatchQueue.global().asyncAfter(deadline: .now() + timeout, execute: deadline)

                // Drain both pipes in parallel: xcodebuild is noisy on stderr,
                // and reading them one after the other deadlocks once the other
                // pipe's 64K buffer fills.
                var outData = Data(), errData = Data()
                let group = DispatchGroup()
                for (handle, sink) in [(out.fileHandleForReading, 0), (err.fileHandleForReading, 1)] {
                    group.enter()
                    DispatchQueue.global(qos: .userInitiated).async {
                        let data = handle.readDataToEndOfFile()
                        if sink == 0 { outData = data } else { errData = data }
                        group.leave()
                    }
                }
                group.wait()
                proc.waitUntilExit()
                deadline.cancel()
                cont.resume(returning: Result(
                    stdout: String(data: outData, encoding: .utf8) ?? "",
                    stderr: String(data: errData, encoding: .utf8) ?? "",
                    exitCode: proc.terminationStatus
                ))
            }
        }
    }
}
