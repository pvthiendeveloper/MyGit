import Foundation

/// What kind of app the repo builds, as far as the run controls care. Detected
/// from marker files at the repo root — no build-system integration.
enum ProjectKind: String {
    case android
    case ios
    case unknown

    var label: String {
        switch self {
        case .android: return "Android"
        case .ios: return "iOS"
        case .unknown: return "—"
        }
    }

    /// SF Symbol shown next to the device picker.
    var icon: String {
        switch self {
        case .android: return "cube.box"
        case .ios: return "iphone"
        case .unknown: return "questionmark.square.dashed"
        }
    }

    /// Cheap file-presence check at the repo root.
    static func detect(at repo: URL) -> ProjectKind {
        let fm = FileManager.default
        func exists(_ name: String) -> Bool {
            fm.fileExists(atPath: repo.appendingPathComponent(name).path)
        }
        let entries = (try? fm.contentsOfDirectory(atPath: repo.path)) ?? []

        if exists("gradlew") || exists("settings.gradle") || exists("settings.gradle.kts") {
            return .android
        }
        if entries.contains(where: { $0.hasSuffix(".xcworkspace") || $0.hasSuffix(".xcodeproj") }) {
            return .ios
        }
        return .unknown
    }
}

/// A target the app can be installed onto.
struct RunDevice: Identifiable, Hashable {
    enum Kind: Hashable {
        case androidDevice                 // physical, over adb
        case androidEmulator(avd: String)  // AVD, may or may not be booted
        case iosSimulator
        case iosDevice
    }

    /// adb serial, simulator UDID, or (for a cold AVD) the AVD name.
    let id: String
    let name: String
    let kind: Kind
    /// Booted/online right now. Cold targets are booted by the run script.
    let isBooted: Bool

    var icon: String {
        switch kind {
        case .androidDevice, .iosDevice: return "iphone"
        case .androidEmulator, .iosSimulator: return "iphone.gen3"
        }
    }

    var subtitle: String {
        switch kind {
        case .androidDevice: return isBooted ? "device" : "offline"
        case .androidEmulator: return isBooted ? "emulator" : "emulator · not running"
        case .iosSimulator: return isBooted ? "simulator · booted" : "simulator"
        case .iosDevice: return "device"
        }
    }
}


/// One Gradle module that produces build variants, as the Build Variants panel
/// lists it. Application modules are the ones that can be installed on a device.
struct GradleModule: Identifiable, Hashable {
    /// Gradle project path without the leading colon ("demoApp",
    /// "feature:androidDesignComponent"). Empty for a single-module root build.
    let path: String
    let variants: [String]
    let isApplication: Bool

    var id: String { path }
    var display: String { path.isEmpty ? ":" : ":\(path)" }

    /// `:demoApp:assembleGosaDebug` — builds the APK for a variant.
    ///
    /// Assemble + `adb install` rather than Gradle's `install<Variant>` task,
    /// which is what Android Studio does too. Build scripts routinely branch on
    /// `gradle.startParameter.taskNames` containing "assemble", so the install
    /// task can resolve a different dependency graph than the IDE's build.
    func assembleTask(_ variant: String) -> String {
        let capitalized = variant.prefix(1).uppercased() + variant.dropFirst()
        return path.isEmpty ? "assemble\(capitalized)" : ":\(path):assemble\(capitalized)"
    }
}

/// A user-defined run target: a named shell command the ▶ button runs in the
/// terminal panel instead of the built-in build-and-launch (e.g. recording
/// snapshot tests). Stored per repo.
struct RunConfiguration: Identifiable, Codable, Hashable {
    var id = UUID()
    var name: String
    var command: String

    /// Curly quotes (from pasting, or macOS smart quotes) mean nothing to bash.
    static func straightenQuotes(_ s: String) -> String {
        s.replacingOccurrences(of: "[‘’‚‛]", with: "'", options: .regularExpression)
            .replacingOccurrences(of: "[“”„‟]", with: "\"", options: .regularExpression)
    }
}
