import Foundation

/// Scripts that run the tests of one source file — a whole class/suite or
/// single functions — from the editor's ▶ buttons.
extension ProjectToolchain {
    enum TestScriptError: LocalizedError {
        case noXcodeProject
        case noTarget(String)
        case noScheme(String)
        case noDevice
        case noGradleModule(String)

        var errorDescription: String? {
            switch self {
            case .noXcodeProject: return "No .xcworkspace or .xcodeproj at the top of the repository."
            case let .noTarget(file): return "Couldn't tell which test target builds \(file)."
            case let .noScheme(target): return "No shared scheme runs the tests of \(target). Share one in Xcode (Manage Schemes ▸ Shared)."
            case .noDevice: return "Pick a simulator or device in the Run bar to run iOS tests on."
            case let .noGradleModule(file): return "Couldn't find the Gradle module (src/test or src/androidTest) of \(file)."
            }
        }
    }

    /// A script running `tests` (all from the file at `relativePath`), or why not.
    static func testScript(for tests: [DiscoveredTest], relativePath: String, repo: URL, kind: ProjectKind,
                           device: RunDevice?, fallbackScheme: String?) -> Result<String, TestScriptError> {
        let isAndroidFile = ["kt", "kts", "java"].contains((relativePath as NSString).pathExtension.lowercased())
        if kind == .android || isAndroidFile {
            return androidTestScript(tests, relativePath: relativePath, repo: repo, device: device)
        }
        return iosTestScript(tests, relativePath: relativePath, repo: repo, device: device, fallbackScheme: fallbackScheme)
    }

    // MARK: - iOS

    private static func iosTestScript(_ tests: [DiscoveredTest], relativePath: String, repo: URL, device: RunDevice?,
                                      fallbackScheme: String?) -> Result<String, TestScriptError> {
        let container: String
        if let ws = xcodeContainer(at: repo, ext: "xcworkspace") { container = "-workspace \(q(ws))" }
        else if let p = xcodeContainer(at: repo, ext: "xcodeproj") { container = "-project \(q(p))" }
        else { return .failure(.noXcodeProject) }
        guard let target = XcodeTestTargets.target(forFile: relativePath, repo: repo) else {
            return .failure(.noTarget((relativePath as NSString).lastPathComponent))
        }
        guard let scheme = XcodeTestTargets.scheme(testing: target, repo: repo) ?? fallbackScheme else {
            return .failure(.noScheme(target))
        }
        guard let device else { return .failure(.noDevice) }
        // `Target/Suite/test` (XCTest), `Target/Suite/test()` or `Target/test()` (Swift Testing).
        let filters = tests.map { t -> String in
            "-only-testing:" + ([target, t.suite, t.function].compactMap { $0 }.joined(separator: "/"))
        }
        let what = tests.count == 1 ? tests[0].title : "\(tests.count) tests"
        // A new file in an XcodeGen project needs the project regenerated first.
        let regenerate = FileManager.default.fileExists(atPath: repo.appendingPathComponent("project.yml").path)
            ? " New file? Regenerate the project: xcodegen generate" : " Is it in the target's Compile Sources?"
        let body = """
        #!/bin/bash
        cd \(q(repo.path))
        LOG=".mygit/test.log"
        mkdir -p .mygit
        echo "▶ \(what) — \(target) (scheme \(scheme)) on \(device.name)"
        set -o pipefail
        xcrun xcodebuild test \(container) -scheme \(q(scheme)) -destination \(q("id=\(device.id)")) \\
          \(filters.map(q).joined(separator: " ")) 2>&1 | tee "$LOG" \\
          | grep -E --line-buffered '(Test Case .*(passed|failed)|Test Suite .*(passed|failed)|: error:|error: -|\\*\\* TEST|Executed [0-9]+ test|[✔✘] Test|Test run with|Testing failed)'
        STATUS=${PIPESTATUS[0]}
        if [ $STATUS -eq 0 ] && ! grep -qE 'Executed [1-9][0-9]* test|Test run with [1-9]' "$LOG"; then
          echo "⚠︎ No test ran: \(relativePath.split(separator: "/").last ?? "") isn't compiled into \(target).\(regenerate)"
          exit 1
        fi
        [ $STATUS -eq 0 ] && echo "✔ tests passed" || echo "✘ tests failed (exit $STATUS) — full log: $LOG"
        exit $STATUS
        """
        return writeScript(body, name: "test-\(repo.lastPathComponent).sh").map(Result.success) ?? .failure(.noXcodeProject)
    }

    // MARK: - Android

    private static func androidTestScript(_ tests: [DiscoveredTest], relativePath: String, repo: URL,
                                          device: RunDevice?) -> Result<String, TestScriptError> {
        // `feature/login/src/test/java/…` → module `:feature:login`, source set `test`.
        let parts = relativePath.split(separator: "/").map(String.init)
        guard let src = parts.firstIndex(of: "src"), src + 1 < parts.count else {
            return .failure(.noGradleModule((relativePath as NSString).lastPathComponent))
        }
        let moduleDir = parts[..<src].joined(separator: "/")
        let module = ":" + parts[..<src].joined(separator: ":")
        let instrumented = parts[src + 1].hasPrefix("androidTest")
        let buildFile = ["build.gradle.kts", "build.gradle"].lazy
            .map { repo.appendingPathComponent(moduleDir).appendingPathComponent($0) }
            .first { FileManager.default.fileExists(atPath: $0.path) }
        let isAndroid = buildFile.flatMap { try? String(contentsOf: $0, encoding: .utf8) }
            .map { $0.contains("com.android") || $0.contains("android {") } ?? true
        let gradle = FileManager.default.isExecutableFile(atPath: repo.appendingPathComponent("gradlew").path) ? "./gradlew" : "gradle"
        func className(_ t: DiscoveredTest) -> String { [t.package, t.suite].compactMap { $0 }.joined(separator: ".") }

        let command: String
        if instrumented {
            // Instrumentation runner: `pkg.Class` or `pkg.Class#method`, comma-separated.
            let classes = tests.map { t in className(t) + (t.function.map { "#\($0)" } ?? "") }.joined(separator: ",")
            command = "\(gradle) \(module.count > 1 ? module + ":" : "")connectedDebugAndroidTest "
                + q("-Pandroid.testInstrumentationRunnerArguments.class=\(classes)")
        } else {
            let task = isAndroid ? "testDebugUnitTest" : "test"
            let filters = tests.map { t in "--tests " + q(className(t) + (t.function.map { ".\($0)" } ?? "")) }.joined(separator: " ")
            command = "\(gradle) \(module.count > 1 ? module + ":" : "")\(task) \(filters)"
        }
        let what = tests.count == 1 ? tests[0].title : "\(tests.count) tests"
        let serial = instrumented ? device.map { "export ANDROID_SERIAL=\(q($0.id))\n" } ?? "" : ""
        let body = """
        #!/bin/bash
        cd \(q(repo.path))
        \(serial)echo "▶ \(what) — \(module == ":" ? "root" : module) (\(instrumented ? "instrumented" : "unit"))"
        \(command)
        STATUS=$?
        [ $STATUS -eq 0 ] && echo "✔ tests passed" || echo "✘ tests failed (exit $STATUS)"
        exit $STATUS
        """
        return writeScript(body, name: "test-\(repo.lastPathComponent).sh").map(Result.success)
            ?? .failure(.noGradleModule(relativePath))
    }
}

/// Which Xcode test target builds a file, and which shared scheme tests it.
enum XcodeTestTargets {
    /// XcodeGen's `project.yml` (most specific source path wins, excludes
    /// honoured), else the `.pbxproj`'s build phases, else a `…Tests` folder
    /// in the path.
    static func target(forFile relativePath: String, repo: URL) -> String? {
        if let yml = try? String(contentsOf: repo.appendingPathComponent("project.yml"), encoding: .utf8),
           let target = xcodegenTarget(forFile: relativePath, yml: yml) {
            return target
        }
        if let target = pbxprojTarget(forFile: relativePath, repo: repo) { return target }
        return relativePath.split(separator: "/").map(String.init).last { $0.hasSuffix("Tests") && !$0.contains(".") }
    }

    /// The shared scheme whose Test action includes `target`, else a scheme named like it.
    static func scheme(testing target: String, repo: URL) -> String? {
        let fm = FileManager.default
        let containers = ((try? fm.contentsOfDirectory(atPath: repo.path)) ?? [])
            .filter { $0.hasSuffix(".xcodeproj") || $0.hasSuffix(".xcworkspace") }
        var named: String?
        for container in containers {
            let dir = repo.appendingPathComponent(container).appendingPathComponent("xcshareddata/xcschemes")
            for file in (try? fm.contentsOfDirectory(atPath: dir.path)) ?? [] where file.hasSuffix(".xcscheme") {
                let name = String(file.dropLast(".xcscheme".count))
                if name == target { named = name }
                guard let xml = try? String(contentsOf: dir.appendingPathComponent(file), encoding: .utf8),
                      let testAction = xml.range(of: "<TestAction"), let end = xml.range(of: "</TestAction>") else { continue }
                if xml[testAction.lowerBound..<end.upperBound].contains("BlueprintName = \"\(target)\"") { return name }
            }
        }
        return named
    }

    /// `targets: Name: sources: - path: dir (excludes: [...])` from project.yml.
    static func xcodegenTarget(forFile file: String, yml: String) -> String? {
        var best: (target: String, length: Int)?
        var inTargets = false
        var target: String?
        var sourcePath: String?
        var inExcludes = false
        var excludes: [String: [String]] = [:]          // "target|path" → excludes
        var sources: [(target: String, path: String)] = []
        for raw in yml.components(separatedBy: "\n") {
            let indent = raw.prefix { $0 == " " }.count
            let line = raw.trimmingCharacters(in: .whitespaces)
            guard !line.isEmpty, !line.hasPrefix("#") else { continue }
            if indent == 0 { inTargets = line == "targets:"; target = nil; continue }
            guard inTargets else { continue }
            if indent == 2, line.hasSuffix(":") { target = String(line.dropLast()); sourcePath = nil; continue }
            guard let t = target else { continue }
            var value: String?
            if line.hasPrefix("- path:") { value = String(line.dropFirst(7)) }
            else if line.hasPrefix("- "), !inExcludes, !line.contains(":") { value = String(line.dropFirst(2)) }
            if let v = value?.trimmingCharacters(in: CharacterSet(charactersIn: " \"'")), !inExcludes || line.hasPrefix("- path:") {
                sourcePath = v
                inExcludes = false
                sources.append((t, v))
                continue
            }
            if line == "excludes:" { inExcludes = true; continue }
            if inExcludes, line.hasPrefix("- "), let p = sourcePath {
                excludes["\(t)|\(p)", default: []].append(String(line.dropFirst(2)).trimmingCharacters(in: CharacterSet(charactersIn: " \"'")))
                continue
            }
            if !line.hasPrefix("- ") { inExcludes = false }
        }
        for (t, path) in sources where file == path || file.hasPrefix(path + "/") {
            let inside = file == path ? "" : String(file.dropFirst(path.count + 1))
            let excluded = (excludes["\(t)|\(path)"] ?? []).contains { ex in
                let prefix = ex.replacingOccurrences(of: "/**", with: "").replacingOccurrences(of: "**", with: "")
                return !prefix.isEmpty && (inside == prefix || inside.hasPrefix(prefix + "/"))
            }
            guard !excluded else { continue }
            if best == nil || path.count > best!.length { best = (t, path.count) }
        }
        return best?.target
    }

    /// The native target whose Sources phase compiles a file with this name.
    private static func pbxprojTarget(forFile relativePath: String, repo: URL) -> String? {
        let fm = FileManager.default
        let name = (relativePath as NSString).lastPathComponent
        for project in ((try? fm.contentsOfDirectory(atPath: repo.path)) ?? []) where project.hasSuffix(".xcodeproj") {
            guard let pbx = try? String(contentsOf: repo.appendingPathComponent(project).appendingPathComponent("project.pbxproj"),
                                        encoding: .utf8) else { continue }
            // `ID /* Name.swift in Sources */ = {isa = PBXBuildFile; …}`
            let buildFiles = pbx.components(separatedBy: "\n").compactMap { line -> String? in
                guard line.contains("/* \(name) in Sources */"), line.contains("isa = PBXBuildFile") else { return nil }
                return line.trimmingCharacters(in: .whitespaces).split(separator: " ").first.map(String.init)
            }
            guard let buildFile = buildFiles.first,
                  let phase = section(of: pbx, containing: buildFile, isa: "PBXSourcesBuildPhase"),
                  let target = targetName(in: pbx, phase: phase) else { continue }
            return target
        }
        return nil
    }

    /// The id of the object of type `isa` whose body lists `member`.
    private static func section(of pbx: String, containing member: String, isa: String) -> String? {
        let regex = try? NSRegularExpression(pattern: "\\n\\s*(\\w+) /\\*[^*]*\\*/ = \\{\\s*isa = \(isa);([\\s\\S]*?)\\n\\s*\\};")
        for m in regex?.matches(in: pbx, range: NSRange(pbx.startIndex..., in: pbx)) ?? [] {
            guard let id = Range(m.range(at: 1), in: pbx), let body = Range(m.range(at: 2), in: pbx) else { continue }
            if pbx[body].contains(member) { return String(pbx[id]) }
        }
        return nil
    }

    private static func targetName(in pbx: String, phase: String) -> String? {
        let regex = try? NSRegularExpression(pattern: "isa = PBXNativeTarget;([\\s\\S]*?)\\n\\s*\\};")
        for m in regex?.matches(in: pbx, range: NSRange(pbx.startIndex..., in: pbx)) ?? [] {
            guard let body = Range(m.range(at: 1), in: pbx) else { continue }
            let text = pbx[body]
            guard text.contains(phase), let nameRange = text.range(of: #"\bname = ([^;]+);"#, options: .regularExpression) else { continue }
            return String(text[nameRange]).replacingOccurrences(of: "name = ", with: "")
                .trimmingCharacters(in: CharacterSet(charactersIn: " ;\""))
        }
        return nil
    }
}
