import Foundation

/// Drives the toolbar's run controls for one repo: what kind of project it is,
/// which devices are available, and the script that builds + installs onto the
/// selected one. The script runs in the terminal panel (see `runInTerminal`).
@MainActor
final class RunViewModel: ObservableObject {
    @Published private(set) var kind: ProjectKind = .unknown
    @Published private(set) var devices: [RunDevice] = []
    @Published private(set) var schemes: [String] = []
    /// Android modules + their build variants (Build Variants panel).
    @Published private(set) var modules: [GradleModule] = []
    @Published private(set) var isLoadingModules = false
    /// Active variant per module path, as the panel shows it.
    @Published private(set) var activeVariants: [String: String] = [:]
    /// Which application module the Run button installs.
    @Published var activeModulePath: String? {
        didSet { persist(Keys.module, activeModulePath) }
    }
    /// Build Variants panel visibility (per repo).
    @Published var showVariantsPanel = false
    /// Why the scheme list is empty or possibly stale (xcodebuild's own error).
    @Published private(set) var schemeWarning: String?
    @Published private(set) var isLoading = false
    @Published var selectedDeviceID: String? {
        didSet { persist(Keys.device, selectedDeviceID) }
    }
    @Published var selectedScheme: String? {
        didSet { persist(Keys.scheme, selectedScheme) }
    }
    /// User-defined commands the ▶ button can run instead of the app.
    @Published private(set) var configurations: [RunConfiguration] = []
    /// Which configuration ▶ runs; nil = the built-in build-and-launch.
    @Published var selectedConfigurationID: UUID? {
        didSet { persist(Keys.selectedConfiguration, selectedConfigurationID?.uuidString) }
    }
    /// With no custom configuration: ▶ builds the app with source tags for
    /// the UI Inspector ("App with Inspector") instead of a plain run.
    @Published var inspectMode = false {
        didSet { persist(Keys.inspect, inspectMode ? "1" : nil) }
    }

    private let repoSource: () -> Repository?
    private let main: MainViewModel
    private let defaults: UserDefaults
    private var runInTerminal: (String) -> Void = { _ in }
    private var didLoadOnce = false

    private enum Keys {
        static let device = "device"
        static let scheme = "scheme"
        static let module = "module"
        static let variants = "variants"
        static let configurations = "configurations"
        static let selectedConfiguration = "configuration"
        static let inspect = "inspect"
    }

    init(main: MainViewModel, repoSource: @escaping () -> Repository?, defaults: UserDefaults = .standard) {
        self.main = main
        self.repoSource = repoSource
        self.defaults = defaults
        self.kind = repoSource().map { ProjectKind.detect(at: $0.url) } ?? .unknown
        self.selectedDeviceID = restore(Keys.device)
        self.selectedScheme = restore(Keys.scheme)
        self.inspectMode = restore(Keys.inspect) == "1"
        self.activeModulePath = restore(Keys.module)
        if let raw = restore(Keys.variants),
           let data = raw.data(using: .utf8),
           let stored = try? JSONDecoder().decode([String: String].self, from: data) {
            self.activeVariants = stored
        }
        if let raw = restore(Keys.configurations),
           let data = raw.data(using: .utf8),
           let stored = try? JSONDecoder().decode([RunConfiguration].self, from: data) {
            self.configurations = stored
        }
        let selected = restore(Keys.selectedConfiguration).flatMap(UUID.init(uuidString:))
        self.selectedConfigurationID = configurations.contains { $0.id == selected } ? selected : nil
    }

    // MARK: - Run configurations

    var selectedConfiguration: RunConfiguration? {
        configurations.first { $0.id == selectedConfigurationID }
    }

    /// Toolbar label for the current run target.
    var configurationLabel: String {
        selectedConfiguration?.name ?? (runsWithInspector ? "App + Inspector" : "App")
    }

    /// Adds or replaces a configuration (matched by id) and selects it.
    func save(_ config: RunConfiguration) {
        if let idx = configurations.firstIndex(where: { $0.id == config.id }) {
            configurations[idx] = config
        } else {
            configurations.append(config)
        }
        selectedConfigurationID = config.id
        persistConfigurations()
        // Write the script now, so its path is real before the first run.
        writeScript(for: config)
    }

    /// Absolute path of a configuration's script file.
    func scriptPath(for config: RunConfiguration) -> String? {
        repoSource().map { ProjectToolchain.customScriptURL(for: config, repo: $0.url).path }
    }

    @discardableResult
    private func writeScript(for config: RunConfiguration) -> String? {
        guard let repo = repoSource() else { return nil }
        return ProjectToolchain.customScript(config, device: selectedDevice, scheme: selectedScheme, repo: repo.url)
    }

    func delete(_ config: RunConfiguration) {
        if let repo = repoSource() { ProjectToolchain.removeCustomScript(config, repo: repo.url) }
        configurations.removeAll { $0.id == config.id }
        if selectedConfigurationID == config.id { selectedConfigurationID = nil }
        persistConfigurations()
    }

    private func persistConfigurations() {
        guard let data = try? JSONEncoder().encode(configurations),
              let raw = String(data: data, encoding: .utf8) else { return }
        persist(Keys.configurations, raw)
    }

    /// Starter command for the configuration editor (iOS only for now).
    func template(record: Bool) -> String {
        guard let repo = repoSource(), kind == .ios else { return "" }
        // Snapshot tests usually live in their own scheme; the toolbar's scheme
        // is the app, so name that one directly when recording.
        let snapshotScheme = record ? schemes.first { $0.localizedCaseInsensitiveContains("snapshot") } : nil
        return ProjectToolchain.iosTestTemplate(at: repo.url, scheme: snapshotScheme, record: record)
    }

    // MARK: - Build variants (Android)

    var applicationModules: [GradleModule] { modules.filter { $0.isApplication } }

    var activeModule: GradleModule? {
        applicationModules.first { $0.path == activeModulePath } ?? applicationModules.first
    }

    func variant(for module: GradleModule) -> String? {
        activeVariants[module.path]
            // Default to the first debug variant — release needs signing.
            ?? module.variants.first { $0.lowercased().hasSuffix("debug") }
            ?? module.variants.first
    }

    func setVariant(_ variant: String, for module: GradleModule) {
        activeVariants[module.path] = variant
        if let data = try? JSONEncoder().encode(activeVariants),
           let raw = String(data: data, encoding: .utf8) {
            persist(Keys.variants, raw)
        }
    }

    /// Gradle task the Run button invokes; falls back to plain `assembleDebug`
    /// when the module list couldn't be read.
    var buildTask: String {
        guard let module = activeModule, let variant = variant(for: module) else { return "assembleDebug" }
        return module.assembleTask(variant)
    }

    /// Variant the APK is picked for after the build (matches the metadata's
    /// `variantName`), or nil when we're on the blind `assembleDebug` path.
    var buildVariant: String? {
        guard let module = activeModule else { return nil }
        return variant(for: module)
    }

    /// Short "\:demoApp gosaDebug" label for the toolbar.
    var variantLabel: String? {
        guard let module = activeModule, let variant = variant(for: module) else { return nil }
        return applicationModules.count > 1 ? "\(module.display) · \(variant)" : variant
    }

    /// Reload the module/variant matrix (a Gradle configuration pass).
    func refreshModules() async {
        guard let repo = repoSource(), kind == .android else { return }
        isLoadingModules = true
        defer { isLoadingModules = false }
        modules = await ProjectToolchain.androidModules(at: repo.url)
        if activeModulePath == nil || !applicationModules.contains(where: { $0.path == activeModulePath }) {
            activeModulePath = applicationModules.first?.path
        }
    }

    func setRunner(_ block: @escaping (String) -> Void) { runInTerminal = block }

    var selectedDevice: RunDevice? {
        devices.first { $0.id == selectedDeviceID } ?? devices.first
    }

    var canRun: Bool {
        if let config = selectedConfiguration { return !config.command.isEmpty }
        guard kind != .unknown, selectedDevice != nil else { return false }
        return kind == .android || selectedScheme != nil
    }

    var isBusy: Bool { isLoading || isLoadingModules }

    /// Re-detect the project and refresh devices/schemes. Cheap enough to call
    /// whenever the picker opens; `force` skips the once-per-session guard.
    func refresh(force: Bool = false) async {
        guard let repo = repoSource() else { return }
        if didLoadOnce && !force { return }
        didLoadOnce = true
        kind = ProjectKind.detect(at: repo.url)
        guard kind != .unknown else {
            devices = []
            schemes = []
            return
        }
        isLoading = true
        defer { isLoading = false }

        devices = await ProjectToolchain.devices(for: kind)
        if selectedDeviceID == nil || !devices.contains(where: { $0.id == selectedDeviceID }) {
            selectedDeviceID = devices.first(where: { $0.isBooted })?.id ?? devices.first?.id
        }

        if kind == .android {
            // Variants come from a Gradle pass; don't block the device picker.
            Task { await refreshModules() }
        }

        if kind == .ios {
            let list = await ProjectToolchain.iosSchemes(at: repo.url)
            schemes = list.schemes
            schemeWarning = list.warning
            if selectedScheme == nil || !schemes.contains(selectedScheme ?? "") {
                // Prefer a scheme named after the repo, then the first one that
                // isn't a test scheme (those can't be run on a device).
                selectedScheme = schemes.first { $0.caseInsensitiveCompare(repo.name) == .orderedSame }
                    ?? schemes.first { !$0.lowercased().contains("test") }
                    ?? schemes.first
            }
        }
    }

    /// ▶ runs "App with Inspector" rather than the plain app.
    var runsWithInspector: Bool { selectedConfiguration == nil && inspectMode && kind == .ios }

    /// Build + install + launch on the selected device, in the terminal panel.
    func run() {
        guard let repo = repoSource() else { return }
        if runsWithInspector {
            runWithInspector()
            return
        }
        if let config = selectedConfiguration {
            guard let script = writeScript(for: config) else {
                main.errorMessage = "Couldn't write the run script."
                return
            }
            runInTerminal(script)
            return
        }
        guard let device = selectedDevice else { return }
        guard let script = ProjectToolchain.runScript(
            kind: kind,
            device: device,
            scheme: selectedScheme,
            buildTask: buildTask,
            variant: buildVariant,
            repo: repo.url
        ) else {
            main.errorMessage = missingToolchainMessage()
            return
        }
        runInTerminal(script)
    }

    var canRunWithInspector: Bool {
        kind == .ios && selectedDevice != nil && selectedScheme != nil
    }

    /// Build + run with every SwiftUI view tagged with its source line, so
    /// the UI Inspector can open the exact code behind a view.
    func runWithInspector() {
        guard let repo = repoSource() else { return }
        guard kind == .ios, let device = selectedDevice, let scheme = selectedScheme else {
            main.errorMessage = "Run with Inspector needs an iOS project with a scheme and a device picked in the Run bar."
            return
        }
        switch ProjectToolchain.inspectRunScript(device: device, scheme: scheme, repo: repo.url) {
        case let .success(script):
            runInTerminal(script)
            // The inspector is what this run is for: have it waiting.
            NotificationCenter.default.post(name: .inspectorRunStarted, object: nil)
        case .failure(.toolsMissing):
            main.errorMessage = "This MyGit build doesn't include the source tagger. Build MyGit with ./run.sh."
        case .failure(.scriptNotWritten):
            main.errorMessage = "Couldn't write the run script."
        case .failure(.noXcodeProject):
            main.errorMessage = "No .xcworkspace or .xcodeproj at the top of \(repo.name)."
        }
    }

    private func missingToolchainMessage() -> String {
        switch kind {
        case .android:
            return "Android SDK tools not found. Set ANDROID_HOME, or install the SDK at ~/Library/Android/sdk."
        case .ios:
            if let schemeWarning, schemes.isEmpty {
                return "No Xcode scheme found. xcodebuild said: \(schemeWarning)"
            }
            return schemes.isEmpty
                ? "No Xcode scheme found for this project."
                : "Couldn't build a run command for this project."
        case .unknown:
            return "This repo isn't a recognised Android or iOS project."
        }
    }

    // Selections are per repo, so two projects don't fight over one default.
    private func key(_ suffix: String) -> String? {
        guard let repo = repoSource() else { return nil }
        return "MyGit.run.\(suffix).\(repo.url.path)"
    }

    private func persist(_ suffix: String, _ value: String?) {
        guard let key = key(suffix) else { return }
        if let value { defaults.set(value, forKey: key) } else { defaults.removeObject(forKey: key) }
    }

    private func restore(_ suffix: String) -> String? {
        key(suffix).flatMap { defaults.string(forKey: $0) }
    }
}

extension Notification.Name {
    /// A "Run with Inspector" build started; the UI Inspector window opens.
    static let inspectorRunStarted = Notification.Name("MyGit.inspectorRunStarted")
}
