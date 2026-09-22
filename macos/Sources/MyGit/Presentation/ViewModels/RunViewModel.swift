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
    }

    init(main: MainViewModel, repoSource: @escaping () -> Repository?, defaults: UserDefaults = .standard) {
        self.main = main
        self.repoSource = repoSource
        self.defaults = defaults
        self.kind = repoSource().map { ProjectKind.detect(at: $0.url) } ?? .unknown
        self.selectedDeviceID = restore(Keys.device)
        self.selectedScheme = restore(Keys.scheme)
        self.activeModulePath = restore(Keys.module)
        if let raw = restore(Keys.variants),
           let data = raw.data(using: .utf8),
           let stored = try? JSONDecoder().decode([String: String].self, from: data) {
            self.activeVariants = stored
        }
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

    /// Build + install + launch on the selected device, in the terminal panel.
    func run() {
        guard let repo = repoSource(), let device = selectedDevice else { return }
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
