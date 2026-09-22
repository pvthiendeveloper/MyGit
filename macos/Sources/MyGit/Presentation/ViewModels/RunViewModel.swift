import Foundation

/// Drives the toolbar's run controls for one repo: what kind of project it is,
/// which devices are available, and the script that builds + installs onto the
/// selected one. The script runs in the terminal panel (see `runInTerminal`).
@MainActor
final class RunViewModel: ObservableObject {
    @Published private(set) var kind: ProjectKind = .unknown
    @Published private(set) var devices: [RunDevice] = []
    @Published private(set) var schemes: [String] = []
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
    }

    init(main: MainViewModel, repoSource: @escaping () -> Repository?, defaults: UserDefaults = .standard) {
        self.main = main
        self.repoSource = repoSource
        self.defaults = defaults
        self.kind = repoSource().map { ProjectKind.detect(at: $0.url) } ?? .unknown
        self.selectedDeviceID = restore(Keys.device)
        self.selectedScheme = restore(Keys.scheme)
    }

    func setRunner(_ block: @escaping (String) -> Void) { runInTerminal = block }

    var selectedDevice: RunDevice? {
        devices.first { $0.id == selectedDeviceID } ?? devices.first
    }

    var canRun: Bool {
        guard kind != .unknown, selectedDevice != nil else { return false }
        return kind == .android || selectedScheme != nil
    }

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

        if kind == .ios {
            schemes = await ProjectToolchain.iosSchemes(at: repo.url)
            if selectedScheme == nil || !schemes.contains(selectedScheme ?? "") {
                // Prefer a scheme named after the repo, else the first one.
                selectedScheme = schemes.first { $0.caseInsensitiveCompare(repo.name) == .orderedSame }
                    ?? schemes.first
            }
        }
    }

    /// Build + install + launch on the selected device, in the terminal panel.
    func run() {
        guard let repo = repoSource(), let device = selectedDevice else { return }
        guard let script = ProjectToolchain.runScript(
            kind: kind, device: device, scheme: selectedScheme, repo: repo.url
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
