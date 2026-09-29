import Foundation

/// One simulator OS version: installed on this Mac, downloadable, or both.
struct SimulatorRuntime: Identifiable, Hashable {
    enum Platform: String, CaseIterable, Identifiable {
        case iOS, watchOS, tvOS, visionOS
        var id: String { rawValue }

        /// `com.apple.platform.iphoneos` (catalog) / `…iphonesimulator` (simctl).
        init?(platformIdentifier: String) {
            switch platformIdentifier.replacingOccurrences(of: "com.apple.platform.", with: "") {
            case "iphoneos", "iphonesimulator": self = .iOS
            case "watchos", "watchsimulator": self = .watchOS
            case "appletvos", "appletvsimulator": self = .tvOS
            case "xros", "xrsimulator": self = .visionOS
            default: return nil
            }
        }
    }

    /// How Xcode gets it — each needs a different download path.
    enum Source: Hashable {
        /// Modern cryptex runtimes: `xcodebuild -downloadPlatform`.
        case xcodebuild
        /// Old runtimes: a public .dmg holding an installer package.
        case package(URL)
        /// A runtime .dmg behind the Apple Developer sign-in; imported with `simctl runtime add`.
        case developerPortal(URL)
    }

    let platform: Platform
    let version: String
    let build: String
    let name: String
    let sizeBytes: Int64?
    let isBeta: Bool
    /// simctl's identifier, when installed (what `simctl runtime delete` takes).
    var installedID: String?
    var deletable = false
    var lastUsed: Date?
    /// Why this Mac/Xcode can't use it (from the catalog's host requirements).
    var incompatibility: String?
    /// Installed: `com.apple.CoreSimulator.SimRuntime.iOS-26-4`, what `simctl create` takes.
    var runtimeIdentifier: String?
    /// Installed: the devices this version can run as.
    var deviceTypes: [SimDeviceType] = []
    var source: Source = .xcodebuild

    var id: String { "\(platform.rawValue)-\(build)" }
    var isInstalled: Bool { installedID != nil }
}

struct SimDeviceType: Hashable, Identifiable {
    let id: String
    let name: String
    /// "iPhone", "iPad", "Apple Watch", …
    let family: String
}

struct SimDevice: Hashable, Identifiable {
    let udid: String
    let name: String
    /// "Booted", "Shutdown", "Booting", …
    let state: String
    let isAvailable: Bool
    var id: String { udid }
    var isBooted: Bool { state == "Booted" }
}

enum SimulatorRuntimeCatalog {
    /// Xcode's own list of downloadable simulator runtimes.
    static let catalogURL = URL(string: "https://devimages-cdn.apple.com/downloads/xcode/simulators/index2.dvtdownloadableindex")!
    private static let xcrun = "/usr/bin/xcrun"

    /// Installed runtimes, from `simctl runtime list` (disk-image runtimes) and
    /// `simctl list runtimes` (also the ones bundled with Xcode).
    static func installed() async -> [SimulatorRuntime] {
        var byBuild: [String: SimulatorRuntime] = [:]
        let listed = await ProcessRunner.run(xcrun, ["simctl", "list", "runtimes", "-j"])
        if let root = json(listed.stdout) as? [String: Any], let runtimes = root["runtimes"] as? [[String: Any]] {
            for r in runtimes {
                guard let build = r["buildversion"] as? String, let version = r["version"] as? String,
                      let identifier = r["identifier"] as? String,
                      let platform = platform(ofRuntimeIdentifier: identifier) else { continue }
                var runtime = SimulatorRuntime(platform: platform, version: version, build: build,
                                               name: r["name"] as? String ?? "\(platform.rawValue) \(version)",
                                               sizeBytes: nil, isBeta: false)
                runtime.installedID = identifier
                runtime.runtimeIdentifier = identifier
                runtime.deviceTypes = (r["supportedDeviceTypes"] as? [[String: Any]] ?? []).compactMap { t in
                    guard let id = t["identifier"] as? String, let name = t["name"] as? String else { return nil }
                    return SimDeviceType(id: id, name: name, family: t["productFamily"] as? String ?? "")
                }
                if (r["isAvailable"] as? Bool) == false {
                    runtime.incompatibility = r["availabilityError"] as? String ?? "Unavailable"
                }
                byBuild[build] = runtime
            }
        }
        let images = await ProcessRunner.run(xcrun, ["simctl", "runtime", "list", "-j"])
        if let root = json(images.stdout) as? [String: [String: Any]] {
            let dates = ISO8601DateFormatter()
            for (uuid, r) in root {
                guard let build = r["build"] as? String, let version = r["version"] as? String,
                      let platform = (r["platformIdentifier"] as? String).flatMap(SimulatorRuntime.Platform.init(platformIdentifier:))
                else { continue }
                var runtime = byBuild[build] ?? SimulatorRuntime(platform: platform, version: version, build: build,
                                                                 name: "\(platform.rawValue) \(version)",
                                                                 sizeBytes: nil, isBeta: false)
                runtime = SimulatorRuntime(platform: runtime.platform, version: runtime.version, build: build,
                                           name: runtime.name, sizeBytes: (r["sizeBytes"] as? NSNumber)?.int64Value,
                                           isBeta: false, installedID: uuid,
                                           deletable: r["deletable"] as? Bool ?? false,
                                           lastUsed: (r["lastUsedAt"] as? String).flatMap(dates.date(from:)),
                                           incompatibility: runtime.incompatibility,
                                           runtimeIdentifier: runtime.runtimeIdentifier ?? r["runtimeIdentifier"] as? String,
                                           deviceTypes: runtime.deviceTypes)
                if let state = r["state"] as? String, state != "Ready" { runtime.incompatibility = state }
                byBuild[build] = runtime
            }
        }
        return Array(byBuild.values)
    }

    /// Simulators by runtime identifier.
    static func devices() async -> [String: [SimDevice]] {
        let listed = await ProcessRunner.run(xcrun, ["simctl", "list", "devices", "-j"])
        guard let root = json(listed.stdout) as? [String: Any],
              let byRuntime = root["devices"] as? [String: [[String: Any]]] else { return [:] }
        return byRuntime.mapValues { entries in
            entries.compactMap { d -> SimDevice? in
                guard let udid = d["udid"] as? String, let name = d["name"] as? String else { return nil }
                return SimDevice(udid: udid, name: name, state: d["state"] as? String ?? "",
                                 isAvailable: d["isAvailable"] as? Bool ?? true)
            }.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        }
    }

    /// The catalog's runtimes, marked when this macOS / Xcode can't use them.
    static func downloadable(xcodeVersion: String?) async throws -> [SimulatorRuntime] {
        let (data, _) = try await URLSession.shared.data(from: catalogURL)
        guard let root = try PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
              let items = root["downloadables"] as? [[String: Any]] else { return [] }
        let os = ProcessInfo.processInfo.operatingSystemVersion
        let host = "\(os.majorVersion).\(os.minorVersion).\(os.patchVersion)"
        return items.compactMap { item in
            guard (item["category"] as? String) == "simulator",
                  let platform = (item["platform"] as? String).flatMap(SimulatorRuntime.Platform.init(platformIdentifier:)),
                  let sim = item["simulatorVersion"] as? [String: Any],
                  let version = sim["version"] as? String, let build = sim["buildUpdate"] as? String else { return nil }
            let name = (item["name"] as? String ?? "\(platform.rawValue) \(version)")
                .replacingOccurrences(of: " Simulator Runtime", with: "")
                .replacingOccurrences(of: " Simulator", with: "")
            var runtime = SimulatorRuntime(platform: platform, version: version, build: build, name: name,
                                           sizeBytes: (item["fileSize"] as? NSNumber)?.int64Value,
                                           isBeta: name.localizedCaseInsensitiveContains("beta")
                                               || name.localizedCaseInsensitiveContains("RC"))
            let url = (item["source"] as? String).flatMap(URL.init(string:))
            if (item["downloadMethod"] as? String) != "mobileAsset", let url {
                runtime.source = (item["contentType"] as? String) == "package"
                    && (item["authentication"] as? String ?? "none") == "none"
                    ? .package(url) : .developerPortal(url)
            }
            let needs = item["hostRequirements"] as? [String: Any] ?? [:]
            if let min = needs["minHostVersion"] as? String, compare(host, min) == .orderedAscending {
                runtime.incompatibility = "Needs macOS \(min)+"
            } else if let max = needs["maxHostVersion"] as? String, compare(host, max) == .orderedDescending {
                runtime.incompatibility = "macOS \(trimmed(max)) or earlier"
            } else if let xcode = xcodeVersion, let min = needs["minXcodeVersion"] as? String,
                      compare(xcode, min) == .orderedAscending {
                runtime.incompatibility = "Needs Xcode \(trimmed(min))+"
            } else if let xcode = xcodeVersion, let max = needs["maxXcodeVersion"] as? String,
                      compare(xcode, max) == .orderedDescending {
                runtime.incompatibility = "Xcode \(trimmed(max)) or earlier"
            }
            return runtime
        }
    }

    /// "26.4" from `xcodebuild -version`.
    static func xcodeVersion() async -> String? {
        let out = await ProcessRunner.run(xcrun, ["xcodebuild", "-version"]).stdout
        return out.split(separator: "\n").first.flatMap { line in
            line.hasPrefix("Xcode ") ? String(line.dropFirst(6)) : nil
        }
    }

    /// Dotted versions compared numerically ("26.10" > "26.9").
    static func compare(_ a: String, _ b: String) -> ComparisonResult {
        let x = a.split(separator: ".").map { Int($0) ?? 0 }, y = b.split(separator: ".").map { Int($0) ?? 0 }
        for i in 0..<max(x.count, y.count) {
            let l = i < x.count ? x[i] : 0, r = i < y.count ? y[i] : 0
            if l != r { return l < r ? .orderedAscending : .orderedDescending }
        }
        return .orderedSame
    }

    private static func trimmed(_ version: String) -> String {
        var parts = version.split(separator: ".").map(String.init)
        while parts.count > 1, parts.last == "0" || parts.last == "99" { parts.removeLast() }
        return parts.joined(separator: ".")
    }

    private static func platform(ofRuntimeIdentifier id: String) -> SimulatorRuntime.Platform? {
        // com.apple.CoreSimulator.SimRuntime.iOS-26-4
        let name = id.components(separatedBy: "SimRuntime.").last?.split(separator: "-").first.map(String.init)
        switch name {
        case "iOS": return .iOS
        case "watchOS": return .watchOS
        case "tvOS": return .tvOS
        case "xrOS", "visionOS": return .visionOS
        default: return nil
        }
    }

    private static func json(_ text: String) -> Any? {
        text.data(using: .utf8).flatMap { try? JSONSerialization.jsonObject(with: $0) }
    }
}
