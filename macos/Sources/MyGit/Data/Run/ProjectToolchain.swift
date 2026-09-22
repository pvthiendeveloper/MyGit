import Foundation

/// Finds the Android/Xcode command-line tools, lists what they can install onto,
/// and writes the shell script that builds + installs + launches the app.
///
/// The run itself happens in the built-in terminal panel rather than in-process:
/// a Gradle or xcodebuild run is long, chatty and occasionally interactive, and
/// the terminal already gives live output, scrollback and ⌃C for free.
enum ProjectToolchain {

    // MARK: - Tool discovery

    /// `adb`, from the usual SDK locations (the app's PATH is the launchd one,
    /// so `which adb` isn't available to us).
    static var adbPath: String? { androidTool("platform-tools/adb", fallbacks: ["adb"]) }
    static var emulatorPath: String? { androidTool("emulator/emulator", fallbacks: ["emulator"]) }

    private static func androidTool(_ relative: String, fallbacks: [String]) -> String? {
        let env = ProcessInfo.processInfo.environment
        var roots = [env["ANDROID_HOME"], env["ANDROID_SDK_ROOT"]].compactMap { $0 }
        roots.append(FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Android/sdk").path)
        let candidates = roots.map { "\($0)/\(relative)" }
            + fallbacks.flatMap { ["/opt/homebrew/bin/\($0)", "/usr/local/bin/\($0)"] }
        return candidates.first { FileManager.default.isExecutableFile(atPath: $0) }
    }

    private static let xcrun = "/usr/bin/xcrun"

    // MARK: - Devices

    static func devices(for kind: ProjectKind) async -> [RunDevice] {
        switch kind {
        case .android: return await androidDevices()
        case .ios: return await iosDevices()
        case .unknown: return []
        }
    }

    /// Online adb targets first, then AVDs that aren't running.
    private static func androidDevices() async -> [RunDevice] {
        guard let adb = adbPath else { return [] }
        var result: [RunDevice] = []
        var runningAVDs: Set<String> = []

        let listed = await ProcessRunner.run(adb, ["devices", "-l"])
        for line in listed.stdout.split(separator: "\n").dropFirst() {
            let fields = line.split(separator: " ", omittingEmptySubsequences: true).map(String.init)
            guard fields.count >= 2, fields[1] == "device" else { continue }
            let serial = fields[0]
            let model = fields.first { $0.hasPrefix("model:") }?
                .replacingOccurrences(of: "model:", with: "")
                .replacingOccurrences(of: "_", with: " ")

            if serial.hasPrefix("emulator-") {
                let avd = await ProcessRunner.run(adb, ["-s", serial, "emu", "avd", "name"])
                let name = avd.stdout.split(separator: "\n").first.map(String.init)?
                    .trimmingCharacters(in: .whitespacesAndNewlines) ?? serial
                runningAVDs.insert(name)
                result.append(RunDevice(id: serial, name: model ?? name,
                                        kind: .androidEmulator(avd: name), isBooted: true))
            } else {
                result.append(RunDevice(id: serial, name: model ?? serial,
                                        kind: .androidDevice, isBooted: true))
            }
        }

        if let emulator = emulatorPath {
            let avds = await ProcessRunner.run(emulator, ["-list-avds"])
            for name in avds.stdout.split(separator: "\n").map(String.init) {
                let avd = name.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !avd.isEmpty, !runningAVDs.contains(avd) else { continue }
                result.append(RunDevice(id: "avd:\(avd)", name: avd.replacingOccurrences(of: "_", with: " "),
                                        kind: .androidEmulator(avd: avd), isBooted: false))
            }
        }
        return result
    }

    /// Booted simulators first, then the rest, then physical devices.
    private static func iosDevices() async -> [RunDevice] {
        var simulators: [RunDevice] = []
        let listed = await ProcessRunner.run(xcrun, ["simctl", "list", "devices", "available", "-j"])
        if let data = listed.stdout.data(using: .utf8),
           let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let byRuntime = root["devices"] as? [String: [[String: Any]]] {
            for (runtime, entries) in byRuntime where runtime.contains("iOS") {
                for entry in entries {
                    guard let udid = entry["udid"] as? String,
                          let name = entry["name"] as? String else { continue }
                    let booted = (entry["state"] as? String) == "Booted"
                    simulators.append(RunDevice(id: udid, name: name, kind: .iosSimulator, isBooted: booted))
                }
            }
        }
        simulators.sort {
            $0.isBooted == $1.isBooted
                ? $0.name.localizedStandardCompare($1.name) == .orderedAscending
                : $0.isBooted
        }

        // Physical devices (Xcode 15+). Absent/older Xcode just yields nothing.
        var physical: [RunDevice] = []
        let devicectl = await ProcessRunner.run(
            xcrun, ["devicectl", "list", "devices", "--json-output", "/dev/stdout", "--quiet"]
        )
        if let data = devicectl.stdout.data(using: .utf8),
           let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let result = root["result"] as? [String: Any],
           let devices = result["devices"] as? [[String: Any]] {
            for device in devices {
                guard let props = device["deviceProperties"] as? [String: Any],
                      let name = props["name"] as? String,
                      let hardware = device["hardwareProperties"] as? [String: Any],
                      let udid = hardware["udid"] as? String else { continue }
                physical.append(RunDevice(id: udid, name: name, kind: .iosDevice, isBooted: true))
            }
        }
        return physical + simulators
    }

    // MARK: - Project metadata

    struct SchemeList {
        let schemes: [String]
        /// Why `xcodebuild` couldn't answer, when it couldn't. Non-nil even if
        /// `schemes` is filled from disk, so the UI can explain a stale list.
        let warning: String?
    }

    /// Schemes for the repo. `xcodebuild -list` is authoritative but fails
    /// whenever the project can't resolve its packages/pods, so fall back to the
    /// `.xcscheme` files on disk — enough to build with.
    static func iosSchemes(at repo: URL) async -> SchemeList {
        var attempts: [[String]] = []
        if let workspace = xcodeContainer(at: repo, ext: "xcworkspace") {
            attempts.append(["-workspace", workspace])
        }
        if let project = xcodeContainer(at: repo, ext: "xcodeproj") {
            attempts.append(["-project", project])
        }

        var lastError: String?
        for container in attempts {
            let listed = await ProcessRunner.run(
                xcrun, ["xcodebuild", "-list", "-json"] + container, cwd: repo, timeout: 90
            )
            // xcodebuild prefixes its JSON with log lines often enough to matter.
            if let start = listed.stdout.firstIndex(of: "{"),
               let data = String(listed.stdout[start...]).data(using: .utf8),
               let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               let info = (root["workspace"] ?? root["project"]) as? [String: Any],
               let schemes = info["schemes"] as? [String], !schemes.isEmpty {
                return SchemeList(schemes: schemes, warning: nil)
            }
            let stderr = listed.stderr.trimmingCharacters(in: .whitespacesAndNewlines)
            if !stderr.isEmpty { lastError = Self.firstErrorLine(stderr) }
        }

        let onDisk = schemesOnDisk(at: repo)
        return SchemeList(
            schemes: onDisk,
            warning: lastError ?? (onDisk.isEmpty ? "No schemes found in this project." : nil)
        )
    }

    /// Shared + per-user `.xcscheme` files inside the root project/workspace.
    private static func schemesOnDisk(at repo: URL) -> [String] {
        let fm = FileManager.default
        let containers = ((try? fm.contentsOfDirectory(atPath: repo.path)) ?? [])
            .filter { $0.hasSuffix(".xcodeproj") || $0.hasSuffix(".xcworkspace") }
        var names: Set<String> = []
        for container in containers {
            let base = repo.appendingPathComponent(container)
            var roots = [base.appendingPathComponent("xcshareddata/xcschemes")]
            let userData = base.appendingPathComponent("xcuserdata")
            for user in (try? fm.contentsOfDirectory(atPath: userData.path)) ?? [] {
                roots.append(userData.appendingPathComponent(user).appendingPathComponent("xcschemes"))
            }
            for root in roots {
                for file in (try? fm.contentsOfDirectory(atPath: root.path)) ?? []
                where file.hasSuffix(".xcscheme") {
                    names.insert((file as NSString).deletingPathExtension)
                }
            }
        }
        return names.sorted()
    }

    /// The first line that actually names the problem, skipping timestamps.
    private static func firstErrorLine(_ stderr: String) -> String {
        let lines = stderr.split(separator: "\n").map(String.init)
        let meaningful = lines.first { $0.contains("error:") } ?? lines.last ?? stderr
        return String(meaningful.prefix(200))
    }

    /// `<name>.xcworkspace` / `.xcodeproj` at the repo root, if present.
    static func xcodeContainer(at repo: URL, ext: String) -> String? {
        let entries = (try? FileManager.default.contentsOfDirectory(atPath: repo.path)) ?? []
        // Skip the project bundled *inside* a workspace-style Pods setup.
        return entries.filter { $0.hasSuffix(".\(ext)") }.sorted().first
    }

    /// Modules and their build variants, read from Gradle's own task list.
    ///
    /// `gradlew tasks --all` is the only source that knows the real flavor
    /// matrix (`installGosaDebug`, …); parsing the Gradle files would have to
    /// re-implement flavor dimensions. It needs a Gradle configuration pass, so
    /// it's slow on a cold daemon — callers cache the result.
    static func androidModules(at repo: URL) async -> [GradleModule] {
        let gradlew = repo.appendingPathComponent("gradlew")
        guard FileManager.default.isExecutableFile(atPath: gradlew.path) else { return [] }
        let listed = await ProcessRunner.run(
            gradlew.path, ["-q", "tasks", "--all", "--console=plain"], cwd: repo, timeout: 300
        )
        guard !listed.stdout.isEmpty else { return [] }

        // "demoApp:installGosaDebug - Installs the Debug build for flavor Gosa."
        let pattern = try? NSRegularExpression(
            pattern: #"^(?:([A-Za-z0-9_.:-]+):)?(install|assemble)([A-Za-z0-9]+)\s+-\s+(.*)$"#,
            options: [.anchorsMatchLines]
        )
        var installs: [String: Set<String>] = [:]
        var assembles: [String: Set<String>] = [:]
        let text = listed.stdout
        pattern?.enumerateMatches(in: text, range: NSRange(text.startIndex..., in: text)) { match, _, _ in
            guard let match else { return }
            func group(_ i: Int) -> String? {
                guard let range = Range(match.range(at: i), in: text) else { return nil }
                return String(text[range])
            }
            let module = group(1) ?? ""
            guard let verb = group(2), var variant = group(3), let description = group(4) else { return }
            // AGP's own wording is the only reliable filter: `installGophDebug`
            // and `installGophDebugPrivateArtifact` are both install tasks, but
            // only the first is a build variant (the second pushes an Internal
            // Sharing artifact for it). Same for the test/aggregate tasks.
            switch verb {
            case "install":
                guard description.hasPrefix("Installs the") else { return }
            default:
                // Library modules say "Assembles main output for variant debug";
                // the aggregate tasks say "…for all Debug variants" / "Test
                // applications", which aren't variants to pick.
                guard description.hasPrefix("Assembles main output for variant") else { return }
            }
            guard !variant.hasSuffix("AndroidTest"), !variant.hasSuffix("UnitTest") else { return }
            variant = variant.prefix(1).lowercased() + variant.dropFirst()
            if verb == "install" { installs[module, default: []].insert(variant) }
            else { assembles[module, default: []].insert(variant) }
        }

        var modules: [GradleModule] = installs.map {
            GradleModule(path: $0.key, variants: $0.value.sorted(), isApplication: true)
        }
        for (module, variants) in assembles where installs[module] == nil {
            // Library modules: shown in the panel, not installable.
            guard !module.isEmpty else { continue }
            modules.append(GradleModule(path: module, variants: variants.sorted(), isApplication: false))
        }
        return modules.sorted {
            $0.isApplication == $1.isApplication
                ? $0.path.localizedStandardCompare($1.path) == .orderedAscending
                : $0.isApplication
        }
    }

    /// `applicationId` from the app module's Gradle file — needed to launch the
    /// app after installing it. Nil when it's set somewhere we can't parse.
    static func androidApplicationId(at repo: URL) -> String? {
        let fm = FileManager.default
        var candidates = ["app/build.gradle.kts", "app/build.gradle"]
            .map { repo.appendingPathComponent($0) }
            .filter { fm.fileExists(atPath: $0.path) }
        if candidates.isEmpty {
            // Non-standard module name: scan one level down.
            for entry in (try? fm.contentsOfDirectory(atPath: repo.path)) ?? [] {
                for name in ["build.gradle.kts", "build.gradle"] {
                    let url = repo.appendingPathComponent(entry).appendingPathComponent(name)
                    if fm.fileExists(atPath: url.path) { candidates.append(url) }
                }
            }
        }
        let pattern = try? NSRegularExpression(pattern: #"applicationId\s*=?\s*["']([^"']+)["']"#)
        for url in candidates {
            guard let text = try? String(contentsOf: url, encoding: .utf8),
                  let match = pattern?.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
                  let range = Range(match.range(at: 1), in: text) else { continue }
            return String(text[range])
        }
        return nil
    }

    // MARK: - Run scripts

    /// Write the build-install-launch script for a target and return its path.
    /// Returns nil when the toolchain needed for it isn't installed.
    static func runScript(
        kind: ProjectKind,
        device: RunDevice,
        scheme: String?,
        buildTask: String,
        variant: String?,
        repo: URL
    ) -> String? {
        let body: String?
        switch kind {
        case .android:
            body = androidScript(device: device, repo: repo, buildTask: buildTask, variant: variant)
        case .ios: body = iosScript(device: device, scheme: scheme, repo: repo)
        case .unknown: body = nil
        }
        guard let body else { return nil }
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("mygit-run", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let file = dir.appendingPathComponent("run-\(repo.lastPathComponent).sh")
        do {
            try body.write(to: file, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: file.path)
        } catch {
            return nil
        }
        return file.path
    }

    private static func androidScript(
        device: RunDevice,
        repo: URL,
        buildTask: String,
        variant: String?
    ) -> String? {
        guard let adb = adbPath else { return nil }
        let gradle = FileManager.default.isExecutableFile(atPath: repo.appendingPathComponent("gradlew").path)
            ? "./gradlew" : "gradle"

        var script = """
        #!/bin/bash
        set -euo pipefail
        cd \(q(repo.path))
        ADB=\(q(adb))

        """

        switch device.kind {
        case .androidEmulator(let avd) where !device.isBooted:
            guard let emulator = emulatorPath else { return nil }
            // Poll for the serial: the AVD appears in `adb devices` a moment
            // after `wait-for-device` returns, and an empty serial would make
            // every later adb call target "".
            script += """
            echo "▶ booting emulator \(avd) ..."
            \(q(emulator)) -avd \(q(avd)) >/dev/null 2>&1 &
            "$ADB" wait-for-device
            SERIAL=""
            for _ in $(seq 1 150); do
              SERIAL="$("$ADB" devices | awk '/^emulator-/ {print $1; exit}')"
              [ -n "${SERIAL}" ] && break
              sleep 2
            done
            if [ -z "${SERIAL}" ]; then
              echo "emulator never showed up in adb devices"
              exit 1
            fi
            echo "▶ waiting for boot ..."
            until [ "$("$ADB" -s "${SERIAL}" shell getprop sys.boot_completed 2>/dev/null | tr -d '\\r')" = "1" ]; do
              sleep 2
            done

            """
        default:
            script += "SERIAL=\(q(device.id))\n\n"
        }

        // Every expansion is braced: bash folds a following multi-byte
        // character (…, ▶) into the variable name, and `set -u` then aborts
        // with "SERIAL…: unbound variable".
        script += """
        export ANDROID_SERIAL="${SERIAL}"
        echo "▶ building \(buildTask) ..."
        \(gradle) \(buildTask)

        """

        // The APK's own metadata carries both the file name and the real
        // applicationId (flavors add `applicationIdSuffix`), so read it instead
        // of guessing either.
        let variantFilter = variant.map { "'\($0)'" } ?? "None"
        script += """
        META="$(/usr/bin/python3 - <<'PY' 2>/dev/null || true
        import glob, json, os
        want = \(variantFilter)
        # `outputs/` is where assemble lands; `intermediates/` is what older
        # builds (and the install task) leave behind — accept both, prefer the
        # first group that yields a match.
        groups = [
            '**/build/outputs/apk/**/output-metadata.json',
            '**/build/intermediates/apk/**/output-metadata.json',
        ]
        best = None
        for pattern in groups:
            for path in glob.glob(pattern, recursive=True):
                try:
                    meta = json.load(open(path))
                except Exception:
                    continue
                if want and meta.get('variantName') != want:
                    continue
                element = (meta.get('elements') or [{}])[0]
                apk = os.path.join(os.path.dirname(path), element.get('outputFile', ''))
                if not os.path.exists(apk):
                    continue
                stamp = os.path.getmtime(apk)
                if best is None or stamp > best[0]:
                    best = (stamp, apk, meta.get('applicationId', ''))
            if best:
                break
        if best:
            print(best[1])
            print(best[2])
        PY
        )"
        APK="$(printf '%s\n' "${META}" | sed -n '1p')"
        PKG="$(printf '%s\n' "${META}" | sed -n '2p')"

        if [ -z "${APK}" ]; then
          echo "✖ no APK found for \(variant ?? "the build") — check the Gradle output above"
          exit 1
        fi

        echo "▶ installing ${APK} on ${SERIAL} ..."
        "$ADB" -s "${SERIAL}" install -r "${APK}"

        if [ -n "${PKG}" ]; then
          echo "▶ launching ${PKG} ..."
          "$ADB" -s "${SERIAL}" shell monkey -p "${PKG}" -c android.intent.category.LAUNCHER 1 >/dev/null
          echo "✔ running"
        else
          echo "✔ installed — couldn't read the package name, so launch it by hand."
        fi
        """
        return script
    }

    private static func iosScript(device: RunDevice, scheme: String?, repo: URL) -> String? {
        guard let scheme else { return nil }
        let container: String
        if let workspace = xcodeContainer(at: repo, ext: "xcworkspace") {
            container = "-workspace \(q(workspace))"
        } else if let project = xcodeContainer(at: repo, ext: "xcodeproj") {
            container = "-project \(q(project))"
        } else {
            return nil
        }

        let isSimulator = device.kind == .iosSimulator
        let sdkFlags = isSimulator ? "-sdk iphonesimulator" : "-allowProvisioningUpdates"
        let productsDir = isSimulator ? "Debug-iphonesimulator" : "Debug-iphoneos"

        var script = """
        #!/bin/bash
        set -euo pipefail
        cd \(q(repo.path))
        DERIVED=".mygit-build"

        echo "▶ building \(scheme) ..."
        xcrun xcodebuild \(container) -scheme \(q(scheme)) -configuration Debug \(sdkFlags) \\
          -destination 'id=\(device.id)' -derivedDataPath "${DERIVED}" build

        APP="$(ls -d "${DERIVED}"/Build/Products/\(productsDir)/*.app | head -1)"
        BUNDLE_ID="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "${APP}/Info.plist")"

        """

        if isSimulator {
            script += """
            echo "▶ booting simulator ..."
            xcrun simctl boot \(q(device.id)) 2>/dev/null || true
            open -a Simulator
            xcrun simctl install \(q(device.id)) "${APP}"
            xcrun simctl launch \(q(device.id)) "${BUNDLE_ID}"
            echo "✔ running"
            """
        } else {
            script += """
            echo "▶ installing on device ..."
            xcrun devicectl device install app --device \(q(device.id)) "${APP}"
            xcrun devicectl device process launch --device \(q(device.id)) "${BUNDLE_ID}"
            echo "✔ running"
            """
        }
        return script
    }

    private static func q(_ s: String) -> String {
        "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
}
