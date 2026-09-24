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

    /// Which half of the Markdown split the user is scrolling; the other one
    /// follows. Without a driver the two panes would fight each other.
    @State private var scrollDriver: MarkdownPane = .source
    @State private var scrollFraction: CGFloat = 0

    private enum MarkdownPane { case source, preview }

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
                if tab.isMarkdown, !tab.isBinary {
                    Picker("", selection: $tab.markdownMode) {
                        ForEach(MarkdownViewMode.allCases) { mode in
                            Image(systemName: mode.symbol)
                                .help(mode.label)
                                .tag(mode)
                        }
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    .fixedSize()
                    .help("Markdown view mode")
                }
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

            if !tab.isLoading, !tab.isBinary {
                FindBarHost(find: tab.find)
            }

            if tab.diskConflict != nil {
                conflictBanner
            }

            if tab.isLoading {
                ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if tab.isBinary, let image = tab.image {
                ImagePreview(image: image)
            } else if tab.isBinary {
                VStack {
                    Spacer()
                    Text("Binary file — cannot edit.").foregroundStyle(.secondary)
                    Spacer()
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if tab.isMarkdown {
                markdownBody
            } else {
                editorBody
            }
        }
    }

    /// Source / split / preview for Markdown.
    @ViewBuilder
    private var markdownBody: some View {
        switch tab.markdownMode {
        case .editor:
            editorBody
        case .preview:
            MarkdownPreview(text: tab.content)
        case .split:
            HSplitView {
                editorBody(
                    scrollFraction: scrollDriver == .preview ? scrollFraction : nil,
                    onScrollFraction: { fraction in
                        guard scrollDriver == .source else { return }
                        scrollFraction = fraction
                    }
                )
                .frame(minWidth: 280)
                .onHover { if $0 { scrollDriver = .source } }

                MarkdownPreview(
                    text: tab.content,
                    scrollFraction: scrollDriver == .source ? scrollFraction : nil,
                    onScrollFraction: { fraction in
                        guard scrollDriver == .preview else { return }
                        scrollFraction = fraction
                    }
                )
                .frame(minWidth: 280)
                .onHover { if $0 { scrollDriver = .preview } }
            }
        }
    }

    /// Shown while another program's edit to this file is unresolved.
    private var conflictBanner: some View {
        HStack(spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
            Text("This file changed on disk while you had unsaved edits. Auto-save is paused.")
                .font(.system(size: 12))
                .lineLimit(2)
            Spacer(minLength: 8)
            Button("Compare") { vm.compareWithDisk(tab) }
            Button("Use Disk Version") { vm.useDiskVersion(tab) }
            Button("Keep My Version") { vm.keepMyVersion(tab) }
        }
        .controlSize(.small)
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(Color.orange.opacity(0.15))
    }

    private var editorBody: some View { editorBody(scrollFraction: nil, onScrollFraction: nil) }

    private func editorBody(
        scrollFraction: CGFloat?,
        onScrollFraction: ((CGFloat) -> Void)?
    ) -> some View {
        Group {
                CodeEditor(
                    text: $tab.content,
                    syntaxExt: (tab.name as NSString).pathExtension,
                    goto: tab.goto,
                    onCommandClick: { symbol, line in
                        vm.goToDefinition(symbol: symbol, line: line, in: tab)
                    },
                    completionSymbols: { vm.repoSymbols },
                    semanticCompletion: (tab.name as NSString).pathExtension == "swift"
                        ? { text, caret in await vm.swiftCompletions(for: tab, text: text, caret: caret) }
                        : nil,
                    autocompleteWhileTyping: settings.autocompleteWhileTyping,
                    aiSuggest: settings.aiInlineCompletion
                        ? { prefix, suffix in
                            await vm.aiSuggestion(
                                prefix: prefix,
                                suffix: suffix,
                                language: (tab.name as NSString).pathExtension
                            )
                          }
                        : nil,
                    scrollFraction: scrollFraction,
                    onScrollFraction: onScrollFraction,
                    onCaretLine: { line, userInitiated in
                        vm.caretMoved(in: tab, to: line, userInitiated: userInitiated)
                    },
                    onSelectionChange: { range in vm.selectionChanged(in: tab, to: range) },
                    onMention: { vm.mentionInClaude(tab) },
                    blame: tab.blame,
                    // Unsaved edits shift lines; blank the cells until the save reloads blame.
                    blameStale: tab.isDirty,
                    onToggleBlame: tab.path.hasPrefix("/") ? nil : { vm.toggleBlame(tab) },
                    onBlameClick: { line, view, rect in
                        CommitCardPopover.show(line.commit, relativeTo: rect, of: view)
                    },
                    find: tab.find
                )
                .background(Color(NSColor.textBackgroundColor))
                .task { await vm.loadRepoSymbols() }
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

/// Shows the ⌘F bar only while it's open; observing `find` here keeps the rest
/// of the editor from re-rendering on every keystroke in the search field.
private struct FindBarHost: View {
    @ObservedObject var find: EditorFindState

    var body: some View {
        if find.isVisible {
            EditorFindBar(find: find)
            Divider()
        }
    }
}
