import Foundation

/// Where a Claude Code asset comes from. Claude Code merges these three scopes;
/// the panel shows which one you're looking at so overrides are obvious.
enum ClaudeScope: String, Hashable {
    case user       // ~/.claude
    case project    // <working dir>/.claude
    case plugin     // ~/.claude/plugins/cache/<marketplace>/<plugin>

    var label: String {
        switch self {
        case .user: return "user"
        case .project: return "project"
        case .plugin: return "plugin"
        }
    }
}

/// A skill directory (`SKILL.md` + assets).
struct ClaudeSkill: Identifiable, Hashable {
    let name: String
    let description: String
    let scope: ClaudeScope
    /// Plugin that ships it, when `scope == .plugin`.
    let origin: String?
    let path: String            // SKILL.md
    /// The skill's own folder — SKILL.md plus whatever it ships (references/,
    /// assets/, scripts/), which the panel shows as a tree.
    let directory: String
    var id: String { path }

    /// "User" / "Project" / plugin name — the grouping the panel uses.
    var group: String { origin ?? scope.label.capitalized }
}

/// A `.md` prompt file that isn't a skill — agents and slash commands.
struct ClaudePromptFile: Identifiable, Hashable {
    enum Kind: String { case agent, command }
    let name: String
    let description: String
    let kind: Kind
    let scope: ClaudeScope
    let path: String
    var id: String { path }
}

/// One installed plugin, read from `~/.claude/plugins/installed_plugins.json`.
struct ClaudePlugin: Identifiable, Hashable {
    let name: String            // "cds-fetch-assets"
    let marketplace: String     // "cds"
    let version: String
    let scope: String           // "user" / "project"
    let installPath: String
    var id: String { "\(name)@\(marketplace)" }
}

/// A config file Claude Code reads, and whether it exists yet.
struct ClaudeConfigFile: Identifiable, Hashable {
    let title: String
    let detail: String
    let path: String
    let scope: ClaudeScope
    var exists: Bool { FileManager.default.fileExists(atPath: path) }
    var id: String { path }
}
