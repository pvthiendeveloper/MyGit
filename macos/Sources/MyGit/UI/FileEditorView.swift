import SwiftUI

/// Fallback pane shown when the Files sidebar is active but no editor tab is the
/// current detail tab. Editor tabs themselves now live in the unified detail tab
/// bar (see `DetailPanel`); their content is rendered via `FileEditorContent`.
struct FileEditorView: View {
    @EnvironmentObject var vm: FileEditorViewModel

    var body: some View {
        if let tab = vm.activeFileTab {
            FileEditorContent(tab: tab)
        } else {
            VStack {
                Spacer()
                Text("Select a file to preview.").foregroundStyle(.secondary)
                Spacer()
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }
}

struct FileEditorContent: View {
    @ObservedObject var tab: OpenFileTab
    @EnvironmentObject var vm: FileEditorViewModel
    @EnvironmentObject var terminal: TerminalViewModel
    @EnvironmentObject var settings: SettingsViewModel

    private var isShellScript: Bool {
        (tab.name as NSString).pathExtension.lowercased() == "sh"
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                if isShellScript {
                    Menu {
                        Section("Open URLs during run with") {
                            ForEach(ScriptBrowser.allCases) { choice in
                                Button {
                                    terminal.scriptBrowser = choice
                                    runScript(browser: choice)
                                } label: {
                                    if terminal.scriptBrowser == choice {
                                        Label(choice.label, systemImage: "checkmark")
                                    } else {
                                        Text(choice.label)
                                    }
                                }
                            }
                        }
                    } label: {
                        Image(systemName: "play.fill")
                            .foregroundStyle(.green)
                    } primaryAction: {
                        runScript(browser: terminal.scriptBrowser)
                    }
                    .menuStyle(.borderlessButton)
                    .fixedSize()
                    .help("Run script in terminal — ▾ picks which browser it opens")
                    .disabled(tab.isBinary)
                }
                Text(tab.path)
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer()
                if let symbol = vm.resolvingSymbol {
                    HStack(spacing: 4) {
                        ProgressView().controlSize(.small)
                        Text("Finding \(symbol)…").font(.caption).foregroundStyle(.secondary)
                    }
                }
                if tab.isBinary {
                    Text("binary").font(.caption).foregroundStyle(.secondary)
                }
                if let err = tab.loadError {
                    Text(err).font(.caption).foregroundStyle(.red).lineLimit(1)
                }
                Button("Revert") {
                    tab.content = tab.originalContent
                }
                .disabled(!tab.isDirty || tab.isBinary)
                Button("Save") {
                    Task { await vm.saveFileTab(tab) }
                }
                .keyboardShortcut("s", modifiers: .command)
                .disabled(!tab.isDirty || tab.isBinary)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .background(Color(NSColor.windowBackgroundColor))

            Divider()

            if tab.isLoading {
                ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if tab.isBinary {
                VStack {
                    Spacer()
                    Text("Binary file — cannot edit.").foregroundStyle(.secondary)
                    Spacer()
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                CodeEditor(
                    text: $tab.content,
                    syntaxExt: (tab.name as NSString).pathExtension,
                    goto: tab.goto,
                    onCommandClick: { symbol, line in
                        vm.goToDefinition(symbol: symbol, line: line, in: tab)
                    },
                    completionSymbols: { vm.repoSymbols },
                    autocompleteWhileTyping: settings.autocompleteWhileTyping
                )
                .background(Color(NSColor.textBackgroundColor))
                .task { await vm.loadRepoSymbols() }
            }
        }
    }

    /// Save any unsaved edits first (IntelliJ runs the on-disk file), then run
    /// the script in the bottom terminal panel.
    private func runScript(browser: ScriptBrowser) {
        Task {
            if tab.isDirty { await vm.saveFileTab(tab) }
            guard let abs = vm.absolutePath(for: tab) else { return }
            terminal.runShellScript(absolutePath: abs, browser: browser)
        }
    }
}
