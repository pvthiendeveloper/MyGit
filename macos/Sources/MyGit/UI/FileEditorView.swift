import SwiftUI

struct FileEditorView: View {
    @EnvironmentObject var vm: FileEditorViewModel

    var body: some View {
        if vm.openFileTabs.isEmpty {
            VStack {
                Spacer()
                Text("Select a file to preview.").foregroundStyle(.secondary)
                Spacer()
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            VStack(spacing: 0) {
                FileTabBar()
                Divider()
                if let tab = vm.activeFileTab {
                    FileEditorContent(tab: tab)
                }
            }
        }
    }
}

private struct FileTabBar: View {
    @EnvironmentObject var vm: FileEditorViewModel

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 0) {
                ForEach(vm.openFileTabs) { tab in
                    FileTabItem(tab: tab)
                    Divider().frame(height: 22)
                }
            }
        }
        .frame(height: 30)
        .background(Color(NSColor.windowBackgroundColor))
    }
}

private struct FileTabItem: View {
    @ObservedObject var tab: OpenFileTab
    @EnvironmentObject var vm: FileEditorViewModel
    @State private var isHovered = false

    private var isActive: Bool { vm.activeFileTabId == tab.id }

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "doc")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
            Text(tab.name)
                .font(.system(size: 12))
                .lineLimit(1)
            if tab.isDirty {
                Circle().fill(Color.accentColor).frame(width: 6, height: 6)
            }
            Button {
                vm.closeFileTab(id: tab.id)
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .frame(width: 16, height: 16)
                    .background(isHovered ? Color.secondary.opacity(0.2) : Color.clear)
                    .clipShape(Circle())
                    .frame(width: 24, height: 24)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 10)
        .frame(height: 30)
        .background(isActive ? Color(NSColor.textBackgroundColor) : Color.clear)
        .contentShape(Rectangle())
        .onHover { isHovered = $0 }
        .onTapGesture { vm.activeFileTabId = tab.id }
        .help(tab.path)
        .contextMenu { contextMenu }
    }

    @ViewBuilder
    private var contextMenu: some View {
        Button("Close") { vm.closeFileTab(id: tab.id) }
        Button("Close Others") { vm.closeOtherFileTabs(keep: tab.id) }
            .disabled(vm.openFileTabs.count < 2)
        Button("Close All") { vm.closeAllFileTabs() }
        Button("Close Saved") { vm.closeSavedFileTabs() }
            .disabled(!vm.openFileTabs.contains { !$0.isDirty })

        Divider()

        Button("Copy Full Path") {
            if let abs = vm.absolutePath(for: tab) { FileActions.copyToPasteboard(abs) }
        }
        Button("Copy Relative Path") { FileActions.copyToPasteboard(tab.path) }
        Button("Reveal in Finder") {
            if let abs = vm.absolutePath(for: tab) { FileActions.reveal(absPath: abs) }
        }
        Button("Open in Default App") {
            if let abs = vm.absolutePath(for: tab) { FileActions.openDefault(absPath: abs) }
        }
        Button("Open in Terminal") {
            if let abs = vm.absolutePath(for: tab) {
                FileActions.openTerminal(dir: (abs as NSString).deletingLastPathComponent)
            }
        }

        Divider()

        Button("Reopen Closed Tab") { vm.reopenClosedTab() }
            .keyboardShortcut("t", modifiers: [.command, .shift])
            .disabled(vm.closedPaths.isEmpty)

        Divider()

        Menu("Git") {
            Button("Show Diff in New Tab") { vm.showDiffInNewTab(for: tab) }
        }
    }
}

private struct FileEditorContent: View {
    @ObservedObject var tab: OpenFileTab
    @EnvironmentObject var vm: FileEditorViewModel

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Text(tab.path)
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer()
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
                TextEditor(text: $tab.content)
                    .font(.system(size: 12, design: .monospaced))
                    .background(Color(NSColor.textBackgroundColor))
            }
        }
    }
}
