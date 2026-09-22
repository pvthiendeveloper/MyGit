import SwiftUI

/// A selectable leaf in the settings sidebar.
enum SettingsItem: Hashable {
    case provider(AIProvider)
    case files
    case editor
}

/// Settings shell — sidebar (search + collapsible groups) on the left,
/// content on the right. Master-detail à la Warp/Xcode settings.
struct SettingsView: View {
    @EnvironmentObject var settings: SettingsViewModel
    @State private var selection: SettingsItem?
    @State private var search = ""
    @State private var aiExpanded = true

    var body: some View {
        NavigationSplitView {
            VStack(spacing: 0) {
                searchField
                Divider()
                List(selection: $selection) {
                    let providers = filteredProviders
                    if !providers.isEmpty {
                        DisclosureGroup(isExpanded: $aiExpanded) {
                            ForEach(providers) { p in
                                Label(p.tabTitle, systemImage: p.tabIcon)
                                    .tag(SettingsItem.provider(p))
                            }
                        } label: {
                            Label("AI", systemImage: "sparkles")
                        }
                    }
                    if matchesSearch("files navigator reveal editor") {
                        Label("Files", systemImage: "folder")
                            .tag(SettingsItem.files)
                    }
                    if matchesSearch("editor autocomplete completion code") {
                        Label("Editor", systemImage: "curlybraces")
                            .tag(SettingsItem.editor)
                    }
                }
                .listStyle(.sidebar)
            }
            .frame(minWidth: 220)
        } detail: {
            content
        }
        .frame(minWidth: 720, minHeight: 440)
        .onAppear {
            if selection == nil { selection = .provider(settings.activeProvider) }
        }
    }

    private var searchField: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(.secondary)
            TextField("Search", text: $search)
                .textFieldStyle(.plain)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
    }

    /// Sidebar rows that aren't providers filter on their own keyword blob.
    private func matchesSearch(_ keywords: String) -> Bool {
        let q = search.trimmingCharacters(in: .whitespaces).lowercased()
        return q.isEmpty || keywords.contains(q)
    }

    private var filteredProviders: [AIProvider] {
        let q = search.trimmingCharacters(in: .whitespaces).lowercased()
        guard !q.isEmpty else { return AIProvider.allCases }
        return AIProvider.allCases.filter {
            $0.tabTitle.lowercased().contains(q)
                || $0.displayName.lowercased().contains(q)
                || "ai".contains(q)
        }
    }

    @ViewBuilder
    private var content: some View {
        switch selection {
        case .provider(let p):
            AICommitSettingsView(provider: p)
        case .files:
            FilesSettingsView()
        case .editor:
            EditorSettingsView()
        case nil:
            Text("Select a setting")
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }
}

/// File-tree behaviour settings.
struct FilesSettingsView: View {
    @EnvironmentObject var settings: SettingsViewModel

    var body: some View {
        Form {
            Section("Navigator") {
                Toggle("Auto-expand to the active file", isOn: $settings.autoRevealActiveFile)
                Text("Expands the file tree down to whichever file the editor is showing and selects it. With this off, use View ▸ Reveal Active File (⌘⇧1).")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }
}

/// Code-editor behaviour settings.
struct EditorSettingsView: View {
    @EnvironmentObject var settings: SettingsViewModel

    var body: some View {
        Form {
            Section("Completion") {
                Toggle("Suggest while typing", isOn: $settings.autocompleteWhileTyping)
                Text("Candidates are the identifiers in the open file plus every declaration in the repo (types, functions, properties). Press ⌥⎋ to ask for them explicitly; ⎋ dismisses the list.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Section("AI") {
                Toggle("AI continuation on ⌘⇧P", isOn: $settings.aiInlineCompletion)
                Text("Asks the active AI provider to continue the code at the caret and shows it dimmed; ⇥ accepts, ⎋ dismisses. The shortcut only fires while editing code — elsewhere ⌘⇧P still means Pull. Uses the same key as commit-message generation and spends tokens per request.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }
}

/// AI commit-message settings for a single provider.
struct AICommitSettingsView: View {
    let provider: AIProvider
    @EnvironmentObject var settings: SettingsViewModel
    @State private var savedFlash = false

    private var isActive: Bool { settings.activeProvider == provider }

    var body: some View {
        Form {
            Section("Commit Message Generation") {
                Toggle("Use for commit messages", isOn: Binding(
                    get: { isActive },
                    set: { if $0 { settings.setActive(provider) } }
                ))
                .disabled(isActive)
                .help(isActive
                      ? "This provider generates commit messages."
                      : "Make this the active provider.")

                modelField

                if provider == .custom || provider == .anthropic {
                    HStack {
                        TextField("Base URL", text: Binding(
                            get: { settings.baseURL(for: provider) },
                            set: { settings.setBaseURL($0, for: provider) }
                        ))
                        .textFieldStyle(.roundedBorder)
                        Button("Default") { settings.resetBaseURL(for: provider) }
                    }
                }

                HStack {
                    SecureField("API Key", text: Binding(
                        get: { settings.apiKey(for: provider) },
                        set: { settings.setAPIKey($0, for: provider) }
                    ))
                    .textFieldStyle(.roundedBorder)
                    Button(savedFlash ? "Saved ✓" : "Save Key") {
                        settings.saveKey(for: provider)
                        savedFlash = true
                        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
                            savedFlash = false
                        }
                    }
                }

                HStack {
                    Button("Test Connection") { settings.testConnection(for: provider) }
                        .disabled(settings.status(for: provider) == .testing)
                    testStatusView
                }

                Text(provider.hint)
                    .font(.caption)
                    .foregroundStyle(.secondary)

                if settings.isKeyInFile(provider) {
                    Label("Keychain unavailable — saved to a plaintext file (~/Library/Application Support/MyGit). Less secure.",
                          systemImage: "exclamationmark.triangle.fill")
                        .font(.caption)
                        .foregroundStyle(.orange)
                }
            }
        }
        .formStyle(.grouped)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .navigationTitle(provider.displayName)
        .onAppear { settings.loadKey(for: provider) }
    }

    @ViewBuilder
    private var testStatusView: some View {
        switch settings.status(for: provider) {
        case .idle:
            EmptyView()
        case .testing:
            HStack(spacing: 6) {
                ProgressView().controlSize(.small)
                Text("Testing…").foregroundStyle(.secondary)
            }
            .font(.caption)
        case .success(let detail):
            Label(detail, systemImage: "checkmark.circle.fill")
                .foregroundStyle(.green)
                .font(.caption)
        case .failure(let msg):
            Label(msg, systemImage: "xmark.octagon.fill")
                .foregroundStyle(.red)
                .font(.caption)
                .lineLimit(3)
                .help(msg)
        }
    }

    @ViewBuilder
    private var modelField: some View {
        let models = settings.availableModels(for: provider)
        let current = settings.model(for: provider)
        Picker("Model", selection: Binding(
            get: { current },
            set: { settings.setModel($0, for: provider) }
        )) {
            ForEach(models, id: \.self) { Text($0).tag($0) }
            if !models.contains(current) {
                Text(current).tag(current)
            }
        }
        TextField("Custom model id", text: Binding(
            get: { settings.model(for: provider) },
            set: { settings.setModel($0, for: provider) }
        ))
        .textFieldStyle(.roundedBorder)
    }
}
