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

    /// Schemes `xcodebuild` knows about, for the workspace if there is one.
    static func iosSchemes(at repo: URL) async -> [String] {
        var args = ["xcodebuild", "-list", "-json"]
        if let workspace = xcodeContainer(at: repo, ext: "xcworkspace") {
            args += ["-workspace", workspace]
        } else if let project = xcodeContainer(at: repo, ext: "xcodeproj") {
            args += ["-project", project]
        } else {
            return []
        }
        let listed = await ProcessRunner.run(xcrun, args, cwd: repo, timeout: 60)
        guard let data = listed.stdout.data(using: .utf8),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return [] }
        let container = (root["workspace"] ?? root["project"]) as? [String: Any]
        return (container?["schemes"] as? [String]) ?? []
    }

    /// `<name>.xcworkspace` / `.xcodeproj` at the repo root, if present.
    static func xcodeContainer(at repo: URL, ext: String) -> String? {
        let entries = (try? FileManager.default.contentsOfDirectory(atPath: repo.path)) ?? []
        // Skip the project bundled *inside* a workspace-style Pods setup.
        return entries.filter { $0.hasSuffix(".\(ext)") }.sorted().first
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
    static func runScript(kind: ProjectKind, device: RunDevice, scheme: String?, repo: URL) -> String? {
        let body: String?
        switch kind {
        case .android: body = androidScript(device: device, repo: repo)
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

    private static func androidScript(device: RunDevice, repo: URL) -> String? {
        guard let adb = adbPath else { return nil }
        let gradle = FileManager.default.isExecutableFile(atPath: repo.appendingPathComponent("gradlew").path)
            ? "./gradlew" : "gradle"
        let appId = androidApplicationId(at: repo)

        var script = """
        #!/bin/bash
        set -euo pipefail
        cd \(q(repo.path))
        ADB=\(q(adb))

        """

        switch device.kind {
        case .androidEmulator(let avd) where !device.isBooted:
            guard let emulator = emulatorPath else { return nil }
            script += """
            echo "▶ booting emulator \(avd)…"
            \(q(emulator)) -avd \(q(avd)) >/dev/null 2>&1 &
            "$ADB" wait-for-device
            SERIAL="$("$ADB" devices | awk '/^emulator-/ {print $1; exit}')"
            until [ "$("$ADB" -s "$SERIAL" shell getprop sys.boot_completed 2>/dev/null | tr -d '\\r')" = "1" ]; do
              sleep 2
            done

            """
        default:
            script += "SERIAL=\(q(device.id))\n\n"
        }

        script += """
        export ANDROID_SERIAL="$SERIAL"
        echo "▶ installing on $SERIAL…"
        \(gradle) installDebug

        """
        if let appId {
            script += """
            echo "▶ launching \(appId)…"
            "$ADB" -s "$SERIAL" shell monkey -p \(q(appId)) -c android.intent.category.LAUNCHER 1 >/dev/null
            echo "✔ running"
            """
        } else {
            script += """
            echo "✔ installed — couldn't read applicationId from the Gradle files, so launch it by hand."
            """
        }
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

        echo "▶ building \(scheme)…"
        xcrun xcodebuild \(container) -scheme \(q(scheme)) -configuration Debug \(sdkFlags) \\
          -destination 'id=\(device.id)' -derivedDataPath "$DERIVED" build

        APP="$(ls -d "$DERIVED"/Build/Products/\(productsDir)/*.app | head -1)"
        BUNDLE_ID="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$APP/Info.plist")"

        """

        if isSimulator {
            script += """
            echo "▶ booting simulator…"
            xcrun simctl boot \(q(device.id)) 2>/dev/null || true
            open -a Simulator
            xcrun simctl install \(q(device.id)) "$APP"
            xcrun simctl launch \(q(device.id)) "$BUNDLE_ID"
            echo "✔ running"
            """
        } else {
            script += """
            echo "▶ installing on device…"
            xcrun devicectl device install app --device \(q(device.id)) "$APP"
            xcrun devicectl device process launch --device \(q(device.id)) "$BUNDLE_ID"
            echo "✔ running"
            """
        }
        return script
    }

    private static func q(_ s: String) -> String {
        "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
}
