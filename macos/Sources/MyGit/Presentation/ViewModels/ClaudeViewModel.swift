import Foundation
import AppKit

/// Backs the Claude Code panel: which directory a session runs in, and what
/// Claude Code would load there (config, skills, agents/commands, plugins).
@MainActor
final class ClaudeViewModel: ObservableObject {
    /// Directory a `claude` session runs in. Defaults to the active repo, but
    /// stays put once the user pins one — monorepo work often runs Claude from
    /// a parent folder.
    @Published private(set) var directory: URL?
    @Published private(set) var isPinnedDirectory = false
    /// Which `CLAUDE_CONFIG_DIR` the panel reads (and launches sessions with).
    @Published private(set) var configRoot: URL = ClaudeEnvironment.defaultConfigRoot
    @Published private(set) var availableConfigRoots: [URL] = []

    @Published private(set) var configFiles: [ClaudeConfigFile] = []
    @Published private(set) var skills: [ClaudeSkill] = []
    @Published private(set) var prompts: [ClaudePromptFile] = []
    @Published private(set) var plugins: [ClaudePlugin] = []
    @Published private(set) var marketplaces: [String] = []
    @Published private(set) var isScanning = false

    @Published var skillFilter = ""
    /// Lazily-built file tree per skill folder, keyed by that folder's path.
    @Published private(set) var skillTrees: [String: FileTreeNode] = [:]
    @Published var claudeCommand = "claude"

    private var runInTerminal: (String, URL) -> Void = { _, _ in }
    private var openInEditor: (String) -> Void = { _ in }
    private let defaults: UserDefaults
    private enum Keys {
        static let pinnedDirectory = "MyGit.claude.directory"
        static let command = "MyGit.claude.command"
        static let configRoot = "MyGit.claude.configRoot"
    }

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        if let saved = defaults.string(forKey: Keys.pinnedDirectory) {
            directory = URL(fileURLWithPath: saved)
            isPinnedDirectory = true
        }
        claudeCommand = defaults.string(forKey: Keys.command) ?? "claude"
        availableConfigRoots = ClaudeEnvironment.discoverConfigRoots()
        if let saved = defaults.string(forKey: Keys.configRoot) {
            configRoot = URL(fileURLWithPath: saved)
        } else {
            configRoot = ClaudeEnvironment.defaultConfigRoot
        }
    }

    /// The config root's short name, e.g. ".claude-personal".
    var configRootName: String { configRoot.lastPathComponent }

    /// Non-default roots need `CLAUDE_CONFIG_DIR` set for the session to match
    /// what the panel is showing.
    var needsConfigEnv: Bool {
        configRoot.standardizedFileURL != ClaudeEnvironment.defaultConfigRoot.standardizedFileURL
    }

    func selectConfigRoot(_ url: URL) {
        configRoot = url
        defaults.set(url.path, forKey: Keys.configRoot)
        Task { await scan() }
    }

    func pickConfigRoot() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.directoryURL = configRoot
        panel.message = "Pick a Claude Code config directory (CLAUDE_CONFIG_DIR)"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        if !availableConfigRoots.contains(where: { $0.standardizedFileURL == url.standardizedFileURL }) {
            availableConfigRoots.append(url)
        }
        selectConfigRoot(url)
    }

    func setRunner(_ block: @escaping (String, URL) -> Void) { runInTerminal = block }
    func setEditorOpener(_ block: @escaping (String) -> Void) { openInEditor = block }

    /// Follow the active repo unless the user pinned a directory.
    func repositoryDidChange(to repo: URL?) {
        guard !isPinnedDirectory else { return }
        directory = repo
        Task { await scan() }
    }

    func pickDirectory() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.directoryURL = directory
        guard panel.runModal() == .OK, let url = panel.url else { return }
        directory = url
        isPinnedDirectory = true
        defaults.set(url.path, forKey: Keys.pinnedDirectory)
        Task { await scan() }
    }

    /// Go back to following whichever repo is active.
    func useActiveRepo(_ repo: URL?) {
        isPinnedDirectory = false
        defaults.removeObject(forKey: Keys.pinnedDirectory)
        directory = repo
        Task { await scan() }
    }

    func setCommand(_ command: String) {
        let trimmed = command.trimmingCharacters(in: .whitespaces)
        claudeCommand = trimmed.isEmpty ? "claude" : trimmed
        defaults.set(claudeCommand, forKey: Keys.command)
    }

    /// Re-read everything Claude Code would load for this directory.
    func scan() async {
        guard let directory else {
            configFiles = []; skills = []; prompts = []; plugins = []; marketplaces = []
            return
        }
        isScanning = true
        defer { isScanning = false }
        let dir = directory
        let root = configRoot
        // Filesystem walk — keep it off the main actor.
        let scanned = await Task.detached(priority: .userInitiated) {
            (
                config: ClaudeEnvironment.configFiles(for: dir, configRoot: root),
                skills: ClaudeEnvironment.skills(for: dir, configRoot: root),
                prompts: ClaudeEnvironment.prompts(for: dir, configRoot: root),
                plugins: ClaudeEnvironment.installedPlugins(configRoot: root),
                marketplaces: ClaudeEnvironment.marketplaces(configRoot: root)
            )
        }.value
        configFiles = scanned.config
        // Folders may have changed on disk; drop the cached trees.
        skillTrees = [:]
        skills = scanned.skills
        prompts = scanned.prompts
        plugins = scanned.plugins
        marketplaces = scanned.marketplaces
    }

    var filteredSkills: [ClaudeSkill] {
        let query = skillFilter.trimmingCharacters(in: .whitespaces).lowercased()
        guard !query.isEmpty else { return skills }
        return skills.filter {
            $0.name.lowercased().contains(query)
                || $0.description.lowercased().contains(query)
                || ($0.origin?.lowercased().contains(query) ?? false)
        }
    }

    var filteredPrompts: [ClaudePromptFile] {
        let query = skillFilter.trimmingCharacters(in: .whitespaces).lowercased()
        guard !query.isEmpty else { return prompts }
        return prompts.filter {
            $0.name.lowercased().contains(query) || $0.description.lowercased().contains(query)
        }
    }

    // MARK: - Skill folder trees

    /// Skills grouped the way Claude Code layers them: user, project, then one
    /// group per plugin that ships skills.
    var skillGroups: [(name: String, skills: [ClaudeSkill])] {
        let grouped = Dictionary(grouping: filteredSkills, by: { $0.group })
        return grouped
            .map { (name: $0.key, skills: $0.value.sorted { $0.name < $1.name }) }
            .sorted { lhs, rhs in
                // User and Project first, plugins after, each alphabetical.
                let order = ["User": 0, "Project": 1]
                let l = order[lhs.name] ?? 2
                let r = order[rhs.name] ?? 2
                return l == r ? lhs.name.localizedStandardCompare(rhs.name) == .orderedAscending : l < r
            }
    }

    /// Root node for a skill's folder, created on first use.
    func tree(for skill: ClaudeSkill) -> FileTreeNode {
        if let existing = skillTrees[skill.directory] { return existing }
        let node = FileTreeNode(
            id: skill.directory,
            name: (skill.directory as NSString).lastPathComponent,
            isDirectory: true
        )
        skillTrees[skill.directory] = node
        return node
    }

    /// Expand/collapse a folder node, listing it from disk the first time.
    func toggle(_ node: FileTreeNode) {
        if !node.isLoaded { loadChildren(of: node) }
        node.isExpanded.toggle()
    }

    /// Directory listing by absolute path (these files live outside any repo).
    func loadChildren(of node: FileTreeNode) {
        guard node.isDirectory, !node.isLoaded else { return }
        let fm = FileManager.default
        let base = URL(fileURLWithPath: node.id)
        let entries = (try? fm.contentsOfDirectory(
            at: base, includingPropertiesForKeys: [.isDirectoryKey], options: []
        )) ?? []
        var dirs: [FileTreeNode] = []
        var files: [FileTreeNode] = []
        for url in entries {
            let isDir = (try? url.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory ?? false
            let child = FileTreeNode(id: url.path, name: url.lastPathComponent, isDirectory: isDir)
            if isDir { dirs.append(child) } else { files.append(child) }
        }
        let byName: (FileTreeNode, FileTreeNode) -> Bool = {
            $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending
        }
        node.children = dirs.sorted(by: byName) + files.sorted(by: byName)
        node.isLoaded = true
    }

    // MARK: - Actions

    /// Start a Claude Code session in the chosen directory, in the terminal panel.
    func launch(extraArguments: String = "") {
        guard let directory else { return }
        var command = claudeCommand
        if !extraArguments.isEmpty { command += " \(extraArguments)" }
        // Match the session to the config root the panel is showing.
        if needsConfigEnv {
            command = "CLAUDE_CONFIG_DIR=\(shellQuote(configRoot.path)) \(command)"
        }
        runInTerminal(command, directory)
    }

    private func shellQuote(_ path: String) -> String {
        "'" + path.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    func open(path: String) { openInEditor(path) }

    func reveal(path: String) { FileActions.reveal(absPath: path) }

    /// Create an empty config file so it can be edited (Claude Code treats a
    /// missing file as "no settings", so an empty object is the safe seed).
    func createConfig(_ file: ClaudeConfigFile) {
        let url = URL(fileURLWithPath: file.path)
        let seed = file.path.hasSuffix(".json") ? "{\n}\n" : "# \(file.title)\n"
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                                 withIntermediateDirectories: true)
        if !FileManager.default.fileExists(atPath: file.path) {
            try? seed.write(to: url, atomically: true, encoding: .utf8)
        }
        openInEditor(file.path)
        Task { await scan() }
    }
}
