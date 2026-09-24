import Foundation

/// Reads what Claude Code has on disk — skills, agents, commands, plugins and
/// config files — for the panel. Pure filesystem work: nothing here shells out
/// to the `claude` CLI, so it stays fast and works while a session is running.
enum ClaudeEnvironment {
    /// Default config root: `$CLAUDE_CONFIG_DIR` when the app inherited it,
    /// else `~/.claude`.
    static var defaultConfigRoot: URL {
        if let override = ProcessInfo.processInfo.environment["CLAUDE_CONFIG_DIR"], !override.isEmpty {
            return URL(fileURLWithPath: (override as NSString).expandingTildeInPath)
        }
        return FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".claude", isDirectory: true)
    }

    /// Config roots on this machine — people keep several (`~/.claude`,
    /// `~/.claude-work`, `~/.claude-personal`) and switch with
    /// `CLAUDE_CONFIG_DIR`, so the panel lets you pick which one it shows.
    static func discoverConfigRoots() -> [URL] {
        let fm = FileManager.default
        let home = fm.homeDirectoryForCurrentUser
        let entries = (try? fm.contentsOfDirectory(atPath: home.path)) ?? []
        var roots = entries
            .filter { $0.hasPrefix(".claude") }
            .map { home.appendingPathComponent($0, isDirectory: true) }
            .filter { url in
                var isDir: ObjCBool = false
                guard fm.fileExists(atPath: url.path, isDirectory: &isDir), isDir.boolValue else { return false }
                // A config root has settings or assets, not just a stray file.
                return ["settings.json", "skills", "plugins", "CLAUDE.md"].contains {
                    fm.fileExists(atPath: url.appendingPathComponent($0).path)
                }
            }
        let fallback = defaultConfigRoot
        if !roots.contains(where: { $0.standardizedFileURL == fallback.standardizedFileURL }),
           fm.fileExists(atPath: fallback.path) {
            roots.append(fallback)
        }
        return roots.sorted { $0.lastPathComponent < $1.lastPathComponent }
    }

    static func projectRoot(for directory: URL) -> URL {
        directory.appendingPathComponent(".claude", isDirectory: true)
    }

    // MARK: - Config files

    /// The files Claude Code merges, in the order it applies them.
    static func configFiles(for directory: URL, configRoot: URL) -> [ClaudeConfigFile] {
        let user = configRoot
        let project = projectRoot(for: directory)
        return [
            ClaudeConfigFile(title: "settings.json",
                             detail: "User settings — permissions, hooks, env",
                             path: user.appendingPathComponent("settings.json").path,
                             scope: .user),
            ClaudeConfigFile(title: "CLAUDE.md",
                             detail: "User instructions, applied to every project",
                             path: user.appendingPathComponent("CLAUDE.md").path,
                             scope: .user),
            ClaudeConfigFile(title: "settings.json",
                             detail: "Project settings, checked into the repo",
                             path: project.appendingPathComponent("settings.json").path,
                             scope: .project),
            ClaudeConfigFile(title: "settings.local.json",
                             detail: "Project settings, yours only (gitignored)",
                             path: project.appendingPathComponent("settings.local.json").path,
                             scope: .project),
            ClaudeConfigFile(title: "CLAUDE.md",
                             detail: "Project instructions for this codebase",
                             path: directory.appendingPathComponent("CLAUDE.md").path,
                             scope: .project),
            ClaudeConfigFile(title: ".mcp.json",
                             detail: "MCP servers for this project",
                             path: directory.appendingPathComponent(".mcp.json").path,
                             scope: .project),
        ]
    }

    // MARK: - Skills

    static func skills(for directory: URL, configRoot: URL) -> [ClaudeSkill] {
        var result = scanSkills(in: configRoot.appendingPathComponent("skills"), scope: .user, origin: nil)
        result += scanSkills(in: projectRoot(for: directory).appendingPathComponent("skills"),
                             scope: .project, origin: nil)
        for plugin in installedPlugins(configRoot: configRoot) {
            let dir = URL(fileURLWithPath: plugin.installPath).appendingPathComponent("skills")
            result += scanSkills(in: dir, scope: .plugin, origin: plugin.name)
        }
        return result.sorted {
            $0.scope == $1.scope
                ? $0.name.localizedStandardCompare($1.name) == .orderedAscending
                : $0.scope.rawValue < $1.scope.rawValue
        }
    }

    private static func scanSkills(in dir: URL, scope: ClaudeScope, origin: String?) -> [ClaudeSkill] {
        let fm = FileManager.default
        guard let entries = try? fm.contentsOfDirectory(atPath: dir.path) else { return [] }
        return entries.compactMap { entry in
            let folder = dir.appendingPathComponent(entry)
            let file = folder.appendingPathComponent("SKILL.md")
            guard fm.fileExists(atPath: file.path) else { return nil }
            let front = frontmatter(of: file)
            return ClaudeSkill(
                name: front["name"] ?? entry,
                description: front["description"] ?? "",
                scope: scope,
                origin: origin,
                path: file.path,
                directory: folder.path
            )
        }
    }

    // MARK: - Agents & commands

    static func prompts(for directory: URL, configRoot: URL) -> [ClaudePromptFile] {
        var result: [ClaudePromptFile] = []
        for (root, scope) in [(configRoot, ClaudeScope.user), (projectRoot(for: directory), .project)] {
            result += scanPrompts(in: root.appendingPathComponent("agents"), kind: .agent, scope: scope)
            result += scanPrompts(in: root.appendingPathComponent("commands"), kind: .command, scope: scope)
        }
        return result
    }

    private static func scanPrompts(in dir: URL, kind: ClaudePromptFile.Kind, scope: ClaudeScope) -> [ClaudePromptFile] {
        guard let entries = try? FileManager.default.contentsOfDirectory(atPath: dir.path) else { return [] }
        return entries.filter { $0.hasSuffix(".md") }.sorted().map { entry in
            let file = dir.appendingPathComponent(entry)
            let front = frontmatter(of: file)
            return ClaudePromptFile(
                name: front["name"] ?? (entry as NSString).deletingPathExtension,
                description: front["description"] ?? "",
                kind: kind,
                scope: scope,
                path: file.path
            )
        }
    }

    // MARK: - Plugins

    static func installedPlugins(configRoot: URL) -> [ClaudePlugin] {
        let file = configRoot.appendingPathComponent("plugins/installed_plugins.json")
        guard let data = try? Data(contentsOf: file),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let plugins = root["plugins"] as? [String: [[String: Any]]] else { return [] }

        return plugins.flatMap { key, installs -> [ClaudePlugin] in
            // Key is "<plugin>@<marketplace>".
            let parts = key.split(separator: "@", maxSplits: 1).map(String.init)
            let name = parts.first ?? key
            let marketplace = parts.count > 1 ? parts[1] : ""
            return installs.map { install in
                ClaudePlugin(
                    name: name,
                    marketplace: marketplace,
                    version: install["version"] as? String ?? "?",
                    scope: install["scope"] as? String ?? "user",
                    installPath: install["installPath"] as? String ?? ""
                )
            }
        }
        .sorted { $0.id.localizedStandardCompare($1.id) == .orderedAscending }
    }

    static func marketplaces(configRoot: URL) -> [String] {
        let dir = configRoot.appendingPathComponent("plugins/marketplaces")
        return ((try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? []).sorted()
    }

    // MARK: - Frontmatter

    /// Minimal `---` YAML frontmatter reader: top-level `key: value`, plus the
    /// folded/literal block forms (`description: >` with the text indented
    /// underneath), which skills use for long trigger lists.
    private static func frontmatter(of file: URL) -> [String: String] {
        guard let handle = try? FileHandle(forReadingFrom: file) else { return [:] }
        defer { try? handle.close() }
        let head = (try? handle.read(upToCount: 32_768)) ?? Data()
        // `String(decoding:)` instead of `init?(data:encoding:)`: a read that
        // lands mid-character, or a file with a stray byte, would otherwise
        // throw the whole frontmatter away.
        let text = String(decoding: head, as: UTF8.self)

        var fields: [String: String] = [:]
        var inBlock = false
        var pendingKey: String?
        var pendingLines: [String] = []
        var isLiteral = false

        func flushPending() {
            guard let key = pendingKey else { return }
            let joined = isLiteral
                ? pendingLines.joined(separator: "\n")
                : pendingLines.joined(separator: " ")
            let value = joined.trimmingCharacters(in: .whitespacesAndNewlines)
            if !value.isEmpty { fields[key] = value }
            pendingKey = nil
            pendingLines = []
        }

        for line in text.components(separatedBy: "\n") {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed == "---" {
                if inBlock { break }
                inBlock = true
                continue
            }
            guard inBlock else { continue }

            let isIndented = line.hasPrefix(" ") || line.hasPrefix("\t")
            if pendingKey != nil {
                // Block scalar body: keep taking indented lines.
                if isIndented || trimmed.isEmpty {
                    pendingLines.append(trimmed)
                    continue
                }
                flushPending()
            }
            // Nested keys of a mapping (metadata:, allowed-tools:) aren't ours.
            guard !isIndented, let colon = line.firstIndex(of: ":") else { continue }
            let key = String(line[..<colon]).trimmingCharacters(in: .whitespaces)
            guard !key.isEmpty else { continue }
            let rawValue = String(line[line.index(after: colon)...]).trimmingCharacters(in: .whitespaces)

            if rawValue.isEmpty || rawValue.first == ">" || rawValue.first == "|" {
                // `>` folds newlines into spaces, `|` keeps them.
                pendingKey = key
                isLiteral = rawValue.first == "|"
                pendingLines = []
                continue
            }
            let value = rawValue.trimmingCharacters(in: CharacterSet(charactersIn: "\"'"))
            if !value.isEmpty { fields[key] = value }
        }
        flushPending()
        return fields
    }
}
