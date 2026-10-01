import AppKit
import UserNotifications

/// Simulator OS versions: what's installed, and what Xcode could download.
@MainActor
final class SimulatorRuntimesViewModel: ObservableObject {
    @Published private(set) var runtimes: [SimulatorRuntime] = []
    @Published private(set) var loading = false
    @Published private(set) var xcodeVersion: String?
    /// The catalog couldn't be fetched: only installed runtimes are shown.
    @Published private(set) var catalogError: String?
    @Published var errorMessage: String?
    @Published var platform: SimulatorRuntime.Platform = .iOS
    @Published var showBetas = false
    /// Also versions this macOS / Xcode can't run.
    @Published var showIncompatible = false
    /// Build being downloaded → progress 0...1 (nil until xcodebuild reports one).
    @Published private(set) var downloads: [String: Double?] = [:] { didSet { updateDockBadge() } }
    @Published private(set) var deleting: Set<String> = []
    /// Simulators by runtime identifier.
    @Published private(set) var devices: [String: [SimDevice]] = [:]
    /// Simulators (udid) or runtimes (for a create) with a simctl call in flight.
    @Published private(set) var busy: Set<String> = []
    private var processes: [String: Process] = [:]
    private var transfers: [String: URLSessionDownloadTask] = [:]
    private var observations: [String: NSKeyValueObservation] = [:]
    /// `simctl runtime add` of a downloaded .dmg in flight.
    @Published private(set) var importing = false

    var installed: [SimulatorRuntime] {
        runtimes.filter { $0.platform == platform && $0.isInstalled }.sorted(by: Self.newestFirst)
    }

    var notInstalled: [SimulatorRuntime] {
        runtimes.filter { r in
            r.platform == platform && !r.isInstalled
                && (showBetas || !r.isBeta) && (showIncompatible || r.incompatibility == nil)
        }.sorted(by: Self.newestFirst)
    }

    func count(installed: Bool, for platform: SimulatorRuntime.Platform) -> Int {
        runtimes.filter { $0.platform == platform && $0.isInstalled == installed
            && (installed || ((showBetas || !$0.isBeta) && (showIncompatible || $0.incompatibility == nil))) }.count
    }

    private static func newestFirst(_ a: SimulatorRuntime, _ b: SimulatorRuntime) -> Bool {
        let order = SimulatorRuntimeCatalog.compare(a.version, b.version)
        return order == .orderedSame ? a.build > b.build : order == .orderedDescending
    }

    func refresh() {
        guard !loading else { return }
        loading = true
        Task {
            async let xcode = SimulatorRuntimeCatalog.xcodeVersion()
            async let local = SimulatorRuntimeCatalog.installed()
            async let sims = SimulatorRuntimeCatalog.devices()
            let version = await xcode
            var catalog: [SimulatorRuntime] = []
            do {
                catalog = try await SimulatorRuntimeCatalog.downloadable(xcodeVersion: version)
                catalogError = nil
            } catch {
                catalogError = "Couldn't load Apple's runtime list: \(error.localizedDescription)"
            }
            xcodeVersion = version
            runtimes = Self.merge(installed: await local, catalog: catalog)
            devices = await sims
            loading = false
        }
    }

    /// One row per build; an installed one keeps the catalog's name and size.
    private static func merge(installed: [SimulatorRuntime], catalog: [SimulatorRuntime]) -> [SimulatorRuntime] {
        var byID: [String: SimulatorRuntime] = [:]
        for r in catalog where byID[r.id] == nil { byID[r.id] = r }
        for var r in installed {
            if let listed = byID[r.id] {
                r = SimulatorRuntime(platform: r.platform, version: r.version, build: r.build, name: listed.name,
                                     sizeBytes: r.sizeBytes ?? listed.sizeBytes, isBeta: listed.isBeta,
                                     installedID: r.installedID, deletable: r.deletable, lastUsed: r.lastUsed,
                                     incompatibility: r.incompatibility, runtimeIdentifier: r.runtimeIdentifier,
                                     deviceTypes: r.deviceTypes)
            }
            byID[r.id] = r
        }
        return Array(byID.values)
    }

    // MARK: - Download / delete

    func download(_ runtime: SimulatorRuntime) {
        guard downloads[runtime.build] == nil else { return }
        // Downloads keep going with the window closed: say when one is done.
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in }
        switch runtime.source {
        case .xcodebuild: downloadWithXcodebuild(runtime)
        case let .package(url): downloadPackage(runtime, from: url)
        case let .developerPortal(url):
            // Needs the user's Apple Developer sign-in: the browser does the
            // download, Import Runtime… adds the .dmg.
            NSWorkspace.shared.open(url)
            errorMessage = "\(runtime.name) is only downloadable from developer.apple.com with your Apple ID. "
                + "Your browser is opening it — sign in, let the .dmg download, then click Import Runtime… here."
        }
    }

    /// `xcodebuild -downloadPlatform`, the same download as Xcode ▸ Settings ▸ Components.
    private func downloadWithXcodebuild(_ runtime: SimulatorRuntime) {
        downloads[runtime.build] = .some(nil)
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/usr/bin/xcrun")
        // Without the variant, xcodebuild answers "not available" for runtimes the
        // catalog lists per architecture (e.g. iOS 26.2 23C54 under Xcode 26.4).
        var variant = utsname()
        uname(&variant)
        let isARM = withUnsafeBytes(of: &variant.machine) { String(decoding: $0.prefix { $0 != 0 }, as: UTF8.self) } == "arm64"
        proc.arguments = ["xcodebuild", "-downloadPlatform", runtime.platform.rawValue, "-buildVersion", runtime.build,
                          "-architectureVariant", isARM ? "arm64" : "universal"]
        let pipe = Pipe()
        proc.standardOutput = pipe
        proc.standardError = pipe
        var output = ""
        let build = runtime.build
        pipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            guard let text = String(data: handle.availableData, encoding: .utf8), !text.isEmpty else { return }
            // "Downloading iOS 26.2 Simulator (23C54) (arm64): 12,3% (1,1 GB of 8,39 GB)" —
            // the decimal separator follows the user's locale.
            let percent = text.matches(of: #/([0-9]+(?:[.,][0-9]+)?)%/#).last
                .flatMap { Double($0.output.1.replacingOccurrences(of: ",", with: ".")) }
            DispatchQueue.main.async {
                output += text
                if let percent, self?.downloads[build] != nil { self?.downloads[build] = .some(percent / 100) }
            }
        }
        proc.terminationHandler = { [weak self] p in
            pipe.fileHandleForReading.readabilityHandler = nil
            let status = p.terminationStatus
            DispatchQueue.main.async {
                guard let self else { return }
                let cancelled = self.processes[build] == nil
                self.processes[build] = nil
                self.downloads[build] = nil
                if status != 0, !cancelled {
                    let lastLines = output.split(separator: "\n").suffix(3).joined(separator: "\n")
                    self.errorMessage = "Download of \(runtime.name) failed (exit \(status)).\n\(lastLines)"
                    self.notify("Download of \(runtime.name) failed", lastLines)
                } else if !cancelled {
                    self.notify("\(runtime.name) is ready", "The simulator runtime finished downloading.")
                }
                self.refresh()
            }
        }
        do {
            try proc.run()
            processes[build] = proc
        } catch {
            downloads[build] = nil
            errorMessage = error.localizedDescription
        }
    }

    func cancelDownload(_ runtime: SimulatorRuntime) {
        if let task = transfers.removeValue(forKey: runtime.build) {
            task.cancel()
            observations[runtime.build] = nil
            downloads[runtime.build] = nil
            return
        }
        guard let proc = processes.removeValue(forKey: runtime.build) else { return }
        proc.interrupt()
    }

    func delete(_ runtime: SimulatorRuntime) {
        guard let id = runtime.installedID, runtime.deletable, !deleting.contains(id) else { return }
        deleting.insert(id)
        Task {
            let result = await ProcessRunner.run("/usr/bin/xcrun", ["simctl", "runtime", "delete", id], timeout: 300)
            deleting.remove(id)
            if result.exitCode != 0 {
                errorMessage = "Couldn't delete \(runtime.name): \(result.stderr.trimmingCharacters(in: .whitespacesAndNewlines))"
            }
            refresh()
        }
    }

    func stopAll() {
        for task in transfers.values { task.cancel() }
        transfers.removeAll()
        observations.removeAll()
        for proc in processes.values { proc.interrupt() }
        processes.removeAll()
    }

    /// Old runtimes: fetch the public .dmg, then run its installer package
    /// (as admin — it installs into /Library/Developer/CoreSimulator).
    private func downloadPackage(_ runtime: SimulatorRuntime, from url: URL) {
        let build = runtime.build
        downloads[build] = .some(0)
        let folder = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("MyGit/Runtimes", isDirectory: true)
        // A previous attempt left the image (its install failed): reuse it.
        // Only finished downloads are moved here, so it's complete.
        let cached = folder.appendingPathComponent(url.lastPathComponent)
        if let size = (try? FileManager.default.attributesOfItem(atPath: cached.path))?[.size] as? NSNumber,
           size.int64Value > 0 {
            transfers[build] = URLSession.shared.downloadTask(with: url)   // marks it in flight; never resumed
            installPackage(runtime, dmg: cached, error: nil)
            return
        }
        let task = URLSession.shared.downloadTask(with: url) { [weak self] temp, _, error in
            // The temp file is gone once this returns: move it first.
            var dmg: URL?
            if let temp {
                let target = folder.appendingPathComponent(url.lastPathComponent)
                try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
                try? FileManager.default.removeItem(at: target)
                if (try? FileManager.default.moveItem(at: temp, to: target)) != nil { dmg = target }
            }
            DispatchQueue.main.async { self?.installPackage(runtime, dmg: dmg, error: error) }
        }
        observations[build] = task.progress.observe(\.fractionCompleted) { [weak self] progress, _ in
            let fraction = progress.fractionCompleted
            DispatchQueue.main.async {
                guard let self, self.transfers[build] != nil else { return }
                self.downloads[build] = .some(fraction)
            }
        }
        transfers[build] = task
        task.resume()
    }

    private func installPackage(_ runtime: SimulatorRuntime, dmg: URL?, error: Error?) {
        let build = runtime.build
        observations[build] = nil
        guard transfers.removeValue(forKey: build) != nil else { return }   // cancelled
        guard let dmg else {
            downloads[build] = nil
            errorMessage = "Download of \(runtime.name) failed: \(error?.localizedDescription ?? "no file")"
            notify("Download of \(runtime.name) failed", error?.localizedDescription ?? "")
            return
        }
        downloads[build] = .some(nil)
        let script = FileManager.default.temporaryDirectory.appendingPathComponent("mygit-install-runtime-\(build).sh")
        // The package has no install-location, so `installer` would unpack it
        // at / (the read-only system volume). Xcode points it at the runtimes
        // folder; do the same: expand, add install-location, re-flatten.
        let location = "/Library/Developer/CoreSimulator/Profiles/Runtimes/\(runtime.platform.rawValue) \(runtime.version).simruntime"
        let work = dmg.deletingLastPathComponent().appendingPathComponent("work-\(build)")
        let body = """
        set -e
        M="$(mktemp -d)"
        W=\(Self.shellQuote(work.path))
        cleanup() { hdiutil detach "$M" -force >/dev/null 2>&1 || true; rm -rf "$W"; }
        trap cleanup EXIT
        hdiutil attach -nobrowse -readonly -mountpoint "$M" \(Self.shellQuote(dmg.path)) >/dev/null
        PKG="$(ls "$M"/*.pkg | head -1)"
        [ -n "$PKG" ] || { echo "no installer package in the disk image" >&2; exit 1; }
        rm -rf "$W"
        pkgutil --expand "$PKG" "$W/expanded"
        INFO="$W/expanded/PackageInfo"
        if ! head -c 2000 "$INFO" | grep -q 'install-location='; then
          sed -i '' '1,/<pkg-info /s#<pkg-info #<pkg-info install-location="\(location)" #' "$INFO"
        fi
        pkgutil --flatten "$W/expanded" "$W/runtime.pkg"
        rm -rf "$W/expanded"
        installer -pkg "$W/runtime.pkg" -target /
        """
        try? body.write(to: script, atomically: true, encoding: .utf8)
        Task {
            let result = await ProcessRunner.run("/usr/bin/osascript", [
                "-e", "do shell script \"/bin/bash \" & quoted form of \"\(script.path)\" with administrator privileges",
            ], timeout: 3600)
            try? FileManager.default.removeItem(at: script)
            downloads[build] = nil
            if result.exitCode == 0 {
                try? FileManager.default.removeItem(at: dmg)
                notify("\(runtime.name) is ready", "The simulator runtime is installed.")
            } else if !result.stderr.contains("User canceled") {
                errorMessage = "Installing \(runtime.name) failed: \(result.stderr.trimmingCharacters(in: .whitespacesAndNewlines))\n"
                    + "The disk image is kept at \(dmg.path)."
                notify("Installing \(runtime.name) failed", "The disk image is kept at \(dmg.path).")
            }
            refresh()
        }
    }

    /// Add a runtime .dmg downloaded by hand (e.g. from developer.apple.com).
    func importRuntime() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.diskImage]
        panel.message = "Choose a simulator runtime disk image (.dmg)"
        panel.directoryURL = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first
        guard panel.runModal() == .OK, let dmg = panel.url else { return }
        importing = true
        Task {
            let result = await ProcessRunner.run("/usr/bin/xcrun", ["simctl", "runtime", "add", dmg.path], timeout: 3600)
            importing = false
            if result.exitCode != 0 {
                errorMessage = "Couldn't import \(dmg.lastPathComponent): \(result.stderr.trimmingCharacters(in: .whitespacesAndNewlines))"
            }
            refresh()
        }
    }

    private static func shellQuote(_ s: String) -> String {
        "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    // MARK: - Background

    var isDownloading: Bool { !downloads.isEmpty }

    /// Overall progress on the Dock icon, so it shows with the window closed.
    private func updateDockBadge() {
        let known = downloads.values.compactMap { $0 }
        NSApp.dockTile.badgeLabel = downloads.isEmpty ? nil
            : known.isEmpty ? "↓" : "↓\(Int(known.reduce(0, +) / Double(known.count) * 100))%"
    }

    private func notify(_ title: String, _ body: String) {
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = .default
        UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil))
    }

    // MARK: - Simulators

    func devices(of runtime: SimulatorRuntime) -> [SimDevice] {
        runtime.runtimeIdentifier.flatMap { devices[$0] } ?? []
    }

    /// `simctl create`, then boot it and bring up Simulator when `boot`.
    func createSimulator(name: String, type: SimDeviceType, runtime: SimulatorRuntime, boot: Bool) {
        guard let runtimeID = runtime.runtimeIdentifier else { return }
        busy.insert(runtimeID)
        Task {
            let created = await simctl(["create", name, type.id, runtimeID])
            busy.remove(runtimeID)
            let udid = created?.trimmingCharacters(in: .whitespacesAndNewlines)
            await reloadDevices()
            if boot, let udid, !udid.isEmpty { bootSimulator(udid) }
        }
    }

    func bootSimulator(_ udid: String) {
        run(udid) { vm in
            // Already booted is fine: just show it.
            _ = await vm.simctl(["boot", udid], allowFailure: true)
            _ = await ProcessRunner.run("/usr/bin/open", ["-a", "Simulator", "--args", "-CurrentDeviceUDID", udid])
        }
    }

    func shutdownSimulator(_ udid: String) {
        run(udid) { vm in _ = await vm.simctl(["shutdown", udid]) }
    }

    func deleteSimulator(_ udid: String) {
        run(udid) { vm in _ = await vm.simctl(["delete", udid]) }
    }

    private func run(_ udid: String, _ work: @escaping (SimulatorRuntimesViewModel) async -> Void) {
        guard !busy.contains(udid) else { return }
        busy.insert(udid)
        Task {
            await work(self)
            busy.remove(udid)
            await reloadDevices()
        }
    }

    private func reloadDevices() async {
        devices = await SimulatorRuntimeCatalog.devices()
    }

    /// stdout, or nil (and the error shown) when simctl fails.
    private func simctl(_ args: [String], allowFailure: Bool = false) async -> String? {
        let result = await ProcessRunner.run("/usr/bin/xcrun", ["simctl"] + args, timeout: 120)
        if result.exitCode != 0 {
            if !allowFailure {
                errorMessage = "simctl \(args.first ?? "") failed: \(result.stderr.trimmingCharacters(in: .whitespacesAndNewlines))"
            }
            return nil
        }
        return result.stdout
    }
}
