import SwiftUI

/// Sidebar panel for working with Claude Code: pick the directory a session
/// runs in, launch it, and reach everything Claude Code would load there —
/// config files, skills, agents/commands and installed plugins.
struct ClaudePanelView: View {
    @EnvironmentObject var vm: ClaudeViewModel
    @EnvironmentObject var coordinator: AppCoordinator
    @State private var expanded: Set<String> = ["config", "skills"]
    @State private var launchArguments = ""

    var body: some View {
        VStack(spacing: 0) {
            directoryHeader
            Divider()
            filterField
            Divider()
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    section("config", "Configuration", count: vm.configFiles.count) { configRows }
                    section("skills", "Skills", count: vm.skills.count) { skillRows }
                    section("prompts", "Agents & Commands", count: vm.prompts.count) { promptRows }
                    section("plugins", "Plugins", count: vm.plugins.count) { pluginRows }
                }
                .padding(.vertical, 4)
            }
        }
        .task(id: coordinator.activeBundle.id) {
            vm.repositoryDidChange(to: coordinator.activeBundle.repo.url)
            if vm.directory != nil && vm.skills.isEmpty { await vm.scan() }
        }
    }

    // MARK: - Header

    private var directoryHeader: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Image(systemName: "folder.badge.gearshape")
                    .foregroundStyle(Color.accentColor)
                    .font(.system(size: 12))
                Text(vm.directory.map { ($0.path as NSString).abbreviatingWithTildeInPath } ?? "No directory")
                    .font(.system(size: 12, weight: .medium))
                    .lineLimit(1)
                    .truncationMode(.head)
                    .help(vm.directory?.path ?? "")
                if vm.isPinnedDirectory {
                    Text("pinned")
                        .font(.system(size: 9))
                        .foregroundStyle(Color.accentColor)
                }
                Spacer(minLength: 4)
                if vm.isScanning { ProgressView().controlSize(.small) }
            }

            // Config root (CLAUDE_CONFIG_DIR) is separate from the working
            // directory: one machine often has ~/.claude, ~/.claude-work, …
            HStack(spacing: 6) {
                Image(systemName: "gearshape.2")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                Menu {
                    Section("CLAUDE_CONFIG_DIR") {
                        ForEach(vm.availableConfigRoots, id: \.self) { root in
                            Button {
                                vm.selectConfigRoot(root)
                            } label: {
                                if root.standardizedFileURL == vm.configRoot.standardizedFileURL {
                                    Label(root.lastPathComponent, systemImage: "checkmark")
                                } else {
                                    Text(root.lastPathComponent)
                                }
                            }
                        }
                    }
                    Divider()
                    Button("Choose Folder…") { vm.pickConfigRoot() }
                } label: {
                    Text(vm.configRootName)
                        .font(.system(size: 11))
                        .lineLimit(1)
                }
                .menuStyle(.borderlessButton)
                .fixedSize()
                .help("Config directory the panel reads and sessions run with")
                Spacer()
            }

            HStack(spacing: 6) {
                Button("Change…") { vm.pickDirectory() }
                    .controlSize(.small)
                if vm.isPinnedDirectory {
                    Button("Use Repo") { vm.useActiveRepo(coordinator.activeBundle.repo.url) }
                        .controlSize(.small)
                        .help("Follow whichever repository is active")
                }
                Spacer()
                Button {
                    Task { await vm.scan() }
                } label: {
                    Image(systemName: "arrow.clockwise").font(.system(size: 11))
                }
                .buttonStyle(.plain)
                .help("Rescan")
            }

            HStack(spacing: 6) {
                TextField("extra flags, e.g. --resume", text: $launchArguments)
                    .textFieldStyle(.roundedBorder)
                    .font(.system(size: 11))
                Button {
                    vm.launch(extraArguments: launchArguments)
                } label: {
                    Label("Run", systemImage: "play.fill")
                        .font(.system(size: 11, weight: .medium))
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
                .disabled(vm.directory == nil)
                .help(vm.needsConfigEnv
                      ? "Runs CLAUDE_CONFIG_DIR=\(vm.configRoot.path) \(vm.claudeCommand) in the terminal panel"
                      : "Start Claude Code in the terminal panel")
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
    }

    private var filterField: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass").foregroundStyle(.secondary).font(.caption)
            TextField("Filter skills, agents, commands", text: $vm.skillFilter)
                .textFieldStyle(.plain)
                .font(.system(size: 12))
            if !vm.skillFilter.isEmpty {
                Button { vm.skillFilter = "" } label: {
                    Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary).font(.caption)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
    }

    // MARK: - Sections

    @ViewBuilder
    private func section<Content: View>(
        _ key: String,
        _ title: String,
        count: Int,
        @ViewBuilder content: () -> Content
    ) -> some View {
        let isOpen = expanded.contains(key)
        Button {
            if isOpen { expanded.remove(key) } else { expanded.insert(key) }
        } label: {
            HStack(spacing: 5) {
                Image(systemName: isOpen ? "chevron.down" : "chevron.right")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .frame(width: 10)
                Text(title).font(.system(size: 11, weight: .semibold))
                Text("\(count)")
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 5).padding(.vertical, 1)
                    .background(Capsule().fill(Color.secondary.opacity(0.15)))
                Spacer()
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        if isOpen { content() }
    }

    // MARK: - Rows

    @ViewBuilder
    private var configRows: some View {
        ForEach(vm.configFiles) { file in
            ClaudeRow(
                title: file.title,
                subtitle: file.detail,
                badge: file.scope.label,
                icon: file.path.hasSuffix(".md") ? "doc.text" : "curlybraces",
                dimmed: !file.exists,
                trailing: file.exists ? nil : "create"
            ) {
                if file.exists { vm.open(path: file.path) } else { vm.createConfig(file) }
            } onReveal: {
                vm.reveal(path: file.path)
            }
        }
    }

    /// Skills as a folder tree: grouped by scope/plugin, each skill expanding
    /// into its own directory (SKILL.md plus whatever it ships).
    @ViewBuilder
    private var skillRows: some View {
        if vm.filteredSkills.isEmpty {
            emptyRow("No skills found for this directory.")
        } else {
            ForEach(vm.skillGroups, id: \.name) { group in
                Text(group.name)
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 22)
                    .padding(.top, 6).padding(.bottom, 2)
                ForEach(group.skills) { skill in
                    ClaudeSkillTree(skill: skill, node: vm.tree(for: skill), vm: vm)
                }
            }
        }
    }

    @ViewBuilder
    private var promptRows: some View {
        if vm.filteredPrompts.isEmpty {
            emptyRow("No agents or slash commands here.")
        } else {
            ForEach(vm.filteredPrompts) { prompt in
                ClaudeRow(
                    title: prompt.kind == .command ? "/\(prompt.name)" : prompt.name,
                    subtitle: prompt.description,
                    badge: "\(prompt.scope.label) · \(prompt.kind.rawValue)",
                    icon: prompt.kind == .agent ? "person.2" : "terminal",
                    dimmed: false,
                    trailing: nil
                ) {
                    vm.open(path: prompt.path)
                } onReveal: {
                    vm.reveal(path: prompt.path)
                }
            }
        }
    }

    @ViewBuilder
    private var pluginRows: some View {
        if vm.plugins.isEmpty {
            emptyRow("No plugins installed.")
        } else {
            ForEach(vm.plugins) { plugin in
                ClaudeRow(
                    title: plugin.name,
                    subtitle: "\(plugin.marketplace) · \(plugin.version)",
                    badge: plugin.scope,
                    icon: "puzzlepiece.extension",
                    dimmed: false,
                    trailing: nil
                ) {
                    vm.reveal(path: plugin.installPath)
                } onReveal: {
                    vm.reveal(path: plugin.installPath)
                }
            }
            if !vm.marketplaces.isEmpty {
                Text("Marketplaces: \(vm.marketplaces.joined(separator: ", "))")
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 26)
                    .padding(.vertical, 4)
            }
        }
    }

    private func emptyRow(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 11))
            .foregroundStyle(.secondary)
            .padding(.horizontal, 26)
            .padding(.vertical, 6)
    }
}

/// One clickable asset row: click opens it, ⌃-click / context menu reveals it.
private struct ClaudeRow: View {
    let title: String
    let subtitle: String
    let badge: String
    let icon: String
    let dimmed: Bool
    let trailing: String?
    let onOpen: () -> Void
    let onReveal: () -> Void
    @State private var hovered = false

    var body: some View {
        Button(action: onOpen) {
            HStack(alignment: .top, spacing: 7) {
                Image(systemName: icon)
                    .font(.system(size: 11))
                    .foregroundStyle(dimmed ? .tertiary : .secondary)
                    .frame(width: 14)
                VStack(alignment: .leading, spacing: 1) {
                    HStack(spacing: 5) {
                        Text(title)
                            .font(.system(size: 12, weight: .medium))
                            .foregroundStyle(dimmed ? .secondary : .primary)
                            .lineLimit(1)
                        Text(badge)
                            .font(.system(size: 9))
                            .foregroundStyle(.secondary)
                            .padding(.horizontal, 4).padding(.vertical, 1)
                            .background(Capsule().fill(Color.secondary.opacity(0.12)))
                    }
                    if !subtitle.isEmpty {
                        Text(subtitle)
                            .font(.system(size: 10))
                            .foregroundStyle(.secondary)
                            .lineLimit(2)
                            .multilineTextAlignment(.leading)
                    }
                }
                Spacer(minLength: 4)
                if let trailing {
                    Text(trailing)
                        .font(.system(size: 9, weight: .medium))
                        .foregroundStyle(Color.accentColor)
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(hovered ? Color.accentColor.opacity(0.10) : .clear)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovered = $0 }
        .contextMenu {
            Button("Open") { onOpen() }
            Button("Reveal in Finder") { onReveal() }
        }
    }
}


/// One skill folder: a header row that toggles the folder, and the folder's
/// contents underneath (lazily listed, nested folders expand too).
private struct ClaudeSkillTree: View {
    let skill: ClaudeSkill
    @ObservedObject var node: FileTreeNode
    @ObservedObject var vm: ClaudeViewModel
    @State private var hovered = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Button {
                vm.toggle(node)
            } label: {
                HStack(alignment: .top, spacing: 6) {
                    Image(systemName: node.isExpanded ? "chevron.down" : "chevron.right")
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundStyle(.secondary)
                        .frame(width: 10)
                    Image(systemName: node.isExpanded ? "folder.fill" : "folder")
                        .font(.system(size: 11))
                        .foregroundStyle(Color.yellow.opacity(0.85))
                        .frame(width: 14)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(skill.name)
                            .font(.system(size: 12, weight: .medium))
                            .lineLimit(1)
                        if !skill.description.isEmpty {
                            Text(skill.description)
                                .font(.system(size: 10))
                                .foregroundStyle(.secondary)
                                .lineLimit(2)
                                .multilineTextAlignment(.leading)
                        }
                    }
                    Spacer(minLength: 4)
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 4)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(hovered ? Color.accentColor.opacity(0.10) : .clear)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .onHover { hovered = $0 }
            .contextMenu {
                Button("Open SKILL.md") { vm.open(path: skill.path) }
                Button("Reveal in Finder") { vm.reveal(path: skill.directory) }
            }

            if node.isExpanded {
                ForEach(node.children) { child in
                    ClaudeFileNode(node: child, depth: 1, vm: vm)
                }
            }
        }
    }
}

/// A file or folder inside a skill; folders expand, files open in the editor.
private struct ClaudeFileNode: View {
    @ObservedObject var node: FileTreeNode
    let depth: Int
    @ObservedObject var vm: ClaudeViewModel
    @State private var hovered = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Button {
                if node.isDirectory { vm.toggle(node) } else { vm.open(path: node.id) }
            } label: {
                HStack(spacing: 5) {
                    Rectangle().fill(.clear).frame(width: CGFloat(depth) * 14)
                    if node.isDirectory {
                        Image(systemName: node.isExpanded ? "chevron.down" : "chevron.right")
                            .font(.system(size: 8, weight: .semibold))
                            .foregroundStyle(.secondary)
                            .frame(width: 10)
                    } else {
                        Rectangle().fill(.clear).frame(width: 10)
                    }
                    Image(systemName: node.isDirectory
                          ? (node.isExpanded ? "folder.fill" : "folder")
                          : (node.name.hasSuffix(".md") ? "doc.text" : "doc"))
                        .font(.system(size: 10))
                        .foregroundStyle(node.isDirectory ? Color.yellow.opacity(0.85) : Color.secondary)
                        .frame(width: 13)
                    Text(node.name)
                        .font(.system(size: 11))
                        .lineLimit(1)
                    Spacer(minLength: 0)
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 3)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(hovered ? Color.accentColor.opacity(0.10) : .clear)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .onHover { hovered = $0 }
            .contextMenu {
                if !node.isDirectory { Button("Open") { vm.open(path: node.id) } }
                Button("Reveal in Finder") { vm.reveal(path: node.id) }
            }

            if node.isDirectory, node.isExpanded {
                ForEach(node.children) { child in
                    ClaudeFileNode(node: child, depth: depth + 1, vm: vm)
                }
            }
        }
    }
}
