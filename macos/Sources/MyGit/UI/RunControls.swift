import SwiftUI

/// Toolbar run controls. Android/iOS repos get a device (and, on iOS, scheme)
/// picker for the built-in build + install + launch; every repo gets the
/// configuration picker, so ▶ can run a user-defined command instead.
///
/// Built from plain buttons + popovers rather than `Menu`, so the whole cell is
/// the hit area and the hover highlight matches the branch/fetch buttons —
/// a borderless `Menu` only reacts on its label.
struct RunControls: View {
    @EnvironmentObject var vm: RunViewModel
    @State private var showDevices = false
    @State private var showSchemes = false
    @State private var hoveredRun = false
    @State private var hoveredDevice = false
    @State private var hoveredScheme = false
    @State private var hoveredVariant = false
    @State private var hoveredConfig = false
    @State private var showConfigs = false
    /// Configuration open in the editor sheet (new or existing).
    @State private var editingConfig: RunConfiguration?

    var body: some View {
        HStack(spacing: 0) {
            if vm.kind != .unknown {
                separator
                devicePicker
            }
            if vm.kind == .ios {
                separator
                schemePicker
            }
            if vm.kind == .android {
                separator
                variantButton
            }
            separator
            configurationPicker
            separator
            runButton
            separator
        }
        .task { await vm.refresh() }
        .sheet(item: $editingConfig) { config in
            RunConfigurationEditor(config: config, isNew: !vm.configurations.contains { $0.id == config.id })
                .environmentObject(vm)
        }
    }

    private var separator: some View {
        Color(NSColor.separatorColor).frame(width: 1)
    }

    // MARK: - Device

    private var devicePicker: some View {
        Button { showDevices.toggle() } label: {
            HStack(spacing: 8) {
                Image(systemName: vm.selectedDevice?.icon ?? vm.kind.icon)
                    .font(.system(size: 16))
                    .foregroundStyle(Color.accentColor)
                VStack(alignment: .leading, spacing: 1) {
                    Text(vm.kind == .android ? "Device" : "Destination")
                        .font(.caption).foregroundStyle(.secondary)
                    Text(vm.selectedDevice?.name ?? (vm.isLoading ? "Loading…" : "No device"))
                        .font(.system(size: 13, weight: .semibold))
                        .lineLimit(1)
                }
                .layoutPriority(1)
                Spacer(minLength: 4)
                DropdownBadge(isOpen: showDevices)
            }
            .padding(.horizontal, 12)
            .frame(minWidth: 150, maxWidth: 220, maxHeight: .infinity)
            .padding(.vertical, 8)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hoveredDevice = $0 }
        .background(hoveredDevice ? Color.primary.opacity(0.08) : .clear)
        .help("Device to install on")
        .popover(isPresented: $showDevices, arrowEdge: .bottom) {
            listPopover(
                title: "Available devices",
                empty: vm.isLoading ? "Looking…" : "No devices found",
                rows: vm.devices.map { device in
                    PopoverRow(
                        id: device.id,
                        title: device.name,
                        subtitle: device.subtitle,
                        icon: device.icon,
                        isSelected: device.id == vm.selectedDevice?.id
                    ) {
                        vm.selectedDeviceID = device.id
                        showDevices = false
                    }
                },
                footer: "Refresh Devices"
            ) {
                Task { await vm.refresh(force: true) }
            }
        }
    }

    // MARK: - Scheme

    private var schemePicker: some View {
        Button { showSchemes.toggle() } label: {
            HStack(spacing: 8) {
                VStack(alignment: .leading, spacing: 1) {
                    Text("Scheme").font(.caption).foregroundStyle(.secondary)
                    Text(vm.selectedScheme ?? (vm.isLoading ? "Loading…" : "No scheme"))
                        .font(.system(size: 13, weight: .semibold))
                        .lineLimit(1)
                }
                .layoutPriority(1)
                Spacer(minLength: 4)
                DropdownBadge(isOpen: showSchemes)
            }
            .padding(.horizontal, 12)
            .frame(minWidth: 120, maxWidth: 200, maxHeight: .infinity)
            .padding(.vertical, 8)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hoveredScheme = $0 }
        .background(hoveredScheme ? Color.primary.opacity(0.08) : .clear)
        .help(vm.schemeWarning ?? "Xcode scheme to build")
        .popover(isPresented: $showSchemes, arrowEdge: .bottom) {
            listPopover(
                title: "Schemes",
                empty: vm.isLoading ? "Looking…" : "No schemes found",
                warning: vm.schemeWarning,
                rows: vm.schemes.map { scheme in
                    PopoverRow(
                        id: scheme,
                        title: scheme,
                        subtitle: nil,
                        icon: "hammer",
                        isSelected: scheme == vm.selectedScheme
                    ) {
                        vm.selectedScheme = scheme
                        showSchemes = false
                    }
                },
                footer: "Reload Schemes"
            ) {
                Task { await vm.refresh(force: true) }
            }
        }
    }

    // MARK: - Build variant (Android)

    /// Opens the Build Variants panel; the panel itself does the picking, so a
    /// multi-module flavor matrix isn't crammed into a toolbar menu.
    private var variantButton: some View {
        Button { vm.showVariantsPanel.toggle() } label: {
            HStack(spacing: 8) {
                Image(systemName: "square.stack.3d.up")
                    .font(.system(size: 14))
                    .foregroundStyle(Color.accentColor)
                VStack(alignment: .leading, spacing: 1) {
                    Text("Build Variant").font(.caption).foregroundStyle(.secondary)
                    Text(vm.variantLabel ?? (vm.isLoadingModules ? "Loading…" : "installDebug"))
                        .font(.system(size: 13, weight: .semibold))
                        .lineLimit(1)
                }
                .layoutPriority(1)
                Spacer(minLength: 4)
                DropdownBadge(isOpen: vm.showVariantsPanel)
            }
            .padding(.horizontal, 12)
            .frame(minWidth: 140, maxWidth: 220, maxHeight: .infinity)
            .padding(.vertical, 8)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hoveredVariant = $0 }
        .background(hoveredVariant || vm.showVariantsPanel ? Color.primary.opacity(0.08) : .clear)
        .help("Pick the Gradle module + variant to install")
    }

    // MARK: - Run configuration

    private var configurationPicker: some View {
        Button { showConfigs.toggle() } label: {
            HStack(spacing: 8) {
                Image(systemName: vm.selectedConfiguration != nil ? "terminal"
                      : (vm.runsWithInspector ? "viewfinder" : "app.badge"))
                    .font(.system(size: 14))
                    .foregroundStyle(Color.accentColor)
                VStack(alignment: .leading, spacing: 1) {
                    Text("Run").font(.caption).foregroundStyle(.secondary)
                    Text(vm.kind == .unknown && vm.selectedConfiguration == nil
                         ? "No configuration" : vm.configurationLabel)
                        .font(.system(size: 13, weight: .semibold))
                        .lineLimit(1)
                }
                .layoutPriority(1)
                Spacer(minLength: 4)
                DropdownBadge(isOpen: showConfigs)
            }
            .padding(.horizontal, 12)
            .frame(minWidth: 110, maxWidth: 200, maxHeight: .infinity)
            .padding(.vertical, 8)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hoveredConfig = $0 }
        .background(hoveredConfig ? Color.primary.opacity(0.08) : .clear)
        .help("What ▶ runs: the app, or one of your commands")
        .popover(isPresented: $showConfigs, arrowEdge: .bottom) {
            configurationPopover
        }
    }

    private var configurationPopover: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("Run Configurations")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.secondary)
                .padding(.horizontal, 12).padding(.top, 10).padding(.bottom, 4)

            if vm.kind != .unknown {
                PopoverRowView(row: PopoverRow(
                    id: "app",
                    title: "App",
                    subtitle: "Build, install and launch",
                    icon: "app.badge",
                    isSelected: vm.selectedConfiguration == nil && !vm.runsWithInspector
                ) {
                    vm.selectedConfigurationID = nil
                    vm.inspectMode = false
                    showConfigs = false
                })
            }
            if vm.kind == .ios {
                PopoverRowView(row: PopoverRow(
                    id: "app-inspector",
                    title: "App with Inspector",
                    subtitle: "Source-tagged build: views open their exact line",
                    icon: "viewfinder",
                    isSelected: vm.runsWithInspector
                ) {
                    vm.selectedConfigurationID = nil
                    vm.inspectMode = true
                    showConfigs = false
                })
            }
            ScrollView {
                VStack(spacing: 0) {
                    ForEach(vm.configurations) { config in
                        ConfigRowView(
                            config: config,
                            isSelected: config.id == vm.selectedConfigurationID,
                            onSelect: {
                                vm.selectedConfigurationID = config.id
                                showConfigs = false
                            },
                            onEdit: {
                                showConfigs = false
                                editingConfig = config
                            },
                            onDelete: { vm.delete(config) }
                        )
                    }
                }
            }
            .frame(maxHeight: 280)
            .fixedSize(horizontal: false, vertical: true)

            Divider()
            Button {
                showConfigs = false
                editingConfig = RunConfiguration(name: "", command: vm.template(record: false))
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: "plus").font(.system(size: 11))
                    Text("Add Configuration…").font(.system(size: 12))
                    Spacer()
                }
                .padding(.horizontal, 12).padding(.vertical, 8)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
        }
        .frame(width: 300)
    }

    private struct ConfigRowView: View {
        let config: RunConfiguration
        let isSelected: Bool
        let onSelect: () -> Void
        let onEdit: () -> Void
        let onDelete: () -> Void
        @State private var hovered = false

        var body: some View {
            HStack(spacing: 8) {
                Image(systemName: isSelected ? "checkmark" : "terminal")
                    .font(.system(size: 11))
                    .foregroundStyle(isSelected ? Color.accentColor : .secondary)
                    .frame(width: 14)
                VStack(alignment: .leading, spacing: 1) {
                    Text(config.name)
                        .font(.system(size: 12, weight: isSelected ? .semibold : .regular))
                        .lineLimit(1)
                    Text(config.command.split(separator: "\n").first.map(String.init) ?? "")
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.tail)
                }
                Spacer(minLength: 0)
                if hovered {
                    Button(action: onEdit) { Image(systemName: "pencil") }
                        .buttonStyle(.borderless)
                        .help("Edit")
                    Button(action: onDelete) { Image(systemName: "trash") }
                        .buttonStyle(.borderless)
                        .help("Delete")
                }
            }
            .padding(.horizontal, 12).padding(.vertical, 6)
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
            .background(hovered ? Color.accentColor.opacity(0.15) : .clear)
            .onTapGesture(perform: onSelect)
            .onHover { hovered = $0 }
            .contextMenu {
                Button("Edit…", action: onEdit)
                Button("Delete", role: .destructive, action: onDelete)
            }
        }
    }

    // MARK: - Run

    private var runButton: some View {
        Button { vm.run() } label: {
            Image(systemName: "play.fill")
                .font(.system(size: 14))
                .foregroundStyle(vm.canRun ? Color.green : Color.secondary)
                .frame(width: 44)
                .frame(maxHeight: .infinity)
                .padding(.vertical, 8)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(!vm.canRun)
        .onHover { hoveredRun = $0 }
        .background(hoveredRun ? Color.primary.opacity(0.08) : .clear)
        .help(runHelp)
    }

    private var runHelp: String {
        if let config = vm.selectedConfiguration { return "Run “\(config.name)” in the terminal" }
        guard let device = vm.selectedDevice else { return "Pick a device first" }
        switch vm.kind {
        case .android: return "Build and install on \(device.name)"
        case .ios:
            return vm.runsWithInspector
                ? "Build \(vm.selectedScheme ?? "scheme") with source tags for the UI Inspector and run on \(device.name)"
                : "Build \(vm.selectedScheme ?? "scheme") and run on \(device.name)"
        case .unknown: return ""
        }
    }

    // MARK: - Popover plumbing

    private struct PopoverRow: Identifiable {
        let id: String
        let title: String
        let subtitle: String?
        let icon: String
        let isSelected: Bool
        let action: () -> Void
    }

    private func listPopover(
        title: String,
        empty: String,
        warning: String? = nil,
        rows: [PopoverRow],
        footer: String,
        footerAction: @escaping () -> Void
    ) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(title)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.secondary)
                .padding(.horizontal, 12).padding(.top, 10).padding(.bottom, 4)

            if let warning {
                Text(warning)
                    .font(.system(size: 11))
                    .foregroundStyle(.orange)
                    .lineLimit(3)
                    .padding(.horizontal, 12).padding(.bottom, 6)
            }

            if rows.isEmpty {
                Text(empty)
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 12).padding(.vertical, 8)
            } else {
                ScrollView {
                    VStack(spacing: 0) {
                        ForEach(rows) { row in PopoverRowView(row: row) }
                    }
                }
                .frame(maxHeight: 280)
            }

            Divider()
            Button(action: footerAction) {
                HStack(spacing: 6) {
                    Image(systemName: "arrow.clockwise").font(.system(size: 11))
                    Text(footer).font(.system(size: 12))
                    Spacer()
                }
                .padding(.horizontal, 12).padding(.vertical, 8)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
        }
        .frame(width: 280)
    }

    private struct PopoverRowView: View {
        let row: PopoverRow
        @State private var hovered = false

        var body: some View {
            Button(action: row.action) {
                HStack(spacing: 8) {
                    Image(systemName: row.isSelected ? "checkmark" : row.icon)
                        .font(.system(size: 11))
                        .foregroundStyle(row.isSelected ? Color.accentColor : .secondary)
                        .frame(width: 14)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(row.title)
                            .font(.system(size: 12, weight: row.isSelected ? .semibold : .regular))
                            .lineLimit(1)
                        if let subtitle = row.subtitle {
                            Text(subtitle).font(.system(size: 10)).foregroundStyle(.secondary)
                        }
                    }
                    Spacer(minLength: 0)
                }
                .padding(.horizontal, 12).padding(.vertical, 6)
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
                .background(hovered ? Color.accentColor.opacity(0.15) : .clear)
            }
            .buttonStyle(.plain)
            .onHover { hovered = $0 }
        }
    }
}

/// Sheet for adding or editing a run configuration: a name and a shell command
/// run from the repo root in the terminal panel.
private struct RunConfigurationEditor: View {
    @EnvironmentObject var vm: RunViewModel
    @Environment(\.dismiss) private var dismiss
    @State var config: RunConfiguration
    let isNew: Bool

    /// Path the script is written to — follows the name as it's typed.
    private var scriptPath: String? {
        var preview = config
        preview.name = config.name.trimmingCharacters(in: .whitespaces)
        return vm.scriptPath(for: preview)
    }

    private func scriptPathRow(_ path: String) -> some View {
        let exists = FileManager.default.fileExists(atPath: path)
        return VStack(alignment: .leading, spacing: 4) {
            Text("Script file").font(.subheadline).foregroundStyle(.secondary)
            HStack(spacing: 6) {
                Text(path)
                    .font(.system(size: 11, design: .monospaced))
                    .textSelection(.enabled)
                    .lineLimit(2)
                    .truncationMode(.middle)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .help(exists ? path : "\(path)\nWritten when you save or run.")
                Button { FileActions.copyToPasteboard(path) } label: {
                    Image(systemName: "doc.on.doc")
                }
                .buttonStyle(.borderless)
                .help("Copy path")
                Button { FileActions.reveal(absPath: path) } label: {
                    Image(systemName: "folder")
                }
                .buttonStyle(.borderless)
                .disabled(!exists)
                .help(exists ? "Reveal in Finder" : "Not written yet — save first")
            }
            .padding(8)
            .background(RoundedRectangle(cornerRadius: 4).fill(Color(NSColor.textBackgroundColor)))
        }
    }

    private var canSave: Bool {
        !config.name.trimmingCharacters(in: .whitespaces).isEmpty
            && !config.command.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(isNew ? "New Run Configuration" : "Edit Run Configuration")
                .font(.headline)

            TextField("Name (e.g. Record Snapshots)", text: $config.name)
                .textFieldStyle(.roundedBorder)

            HStack {
                Text("Command").font(.subheadline).foregroundStyle(.secondary)
                Spacer()
                if vm.kind == .ios {
                    Menu("Templates") {
                        Button("xcodebuild test") { config.command = vm.template(record: false) }
                        Button("xcodebuild test — record snapshots") {
                            config.command = vm.template(record: true)
                            if config.name.isEmpty { config.name = "Record Snapshots" }
                        }
                    }
                    .menuStyle(.borderlessButton)
                    .fixedSize()
                }
            }
            ShellCommandEditor(text: $config.command)
                .frame(minHeight: 140)
                .overlay(RoundedRectangle(cornerRadius: 4).stroke(Color(NSColor.separatorColor)))

            Text("Runs with bash from the repo root in the terminal panel. Available: $MYGIT_REPO, $MYGIT_SCHEME, $MYGIT_DEVICE_ID, $MYGIT_DEVICE_NAME (from the toolbar pickers).")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            if let path = scriptPath {
                scriptPathRow(path)
            }

            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button(isNew ? "Add" : "Save") {
                    config.name = config.name.trimmingCharacters(in: .whitespaces)
                    config.command = RunConfiguration.straightenQuotes(config.command)
                    vm.save(config)
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(!canSave)
            }
        }
        .padding(20)
        .frame(width: 520)
    }
}

/// Plain monospaced text view for shell commands. SwiftUI's `TextEditor`
/// inherits the system's smart quotes/dashes, which turn `'` into `’` and
/// break the command, so every substitution is switched off here.
private struct ShellCommandEditor: NSViewRepresentable {
    @Binding var text: String

    func makeNSView(context: Context) -> NSScrollView {
        let scroll = NSTextView.scrollableTextView()
        let tv = scroll.documentView as! NSTextView
        tv.delegate = context.coordinator
        tv.font = .monospacedSystemFont(ofSize: 12, weight: .regular)
        tv.isRichText = false
        tv.allowsUndo = true
        tv.isAutomaticQuoteSubstitutionEnabled = false
        tv.isAutomaticDashSubstitutionEnabled = false
        tv.isAutomaticTextReplacementEnabled = false
        tv.isAutomaticSpellingCorrectionEnabled = false
        tv.isContinuousSpellCheckingEnabled = false
        tv.isGrammarCheckingEnabled = false
        tv.isAutomaticLinkDetectionEnabled = false
        tv.isAutomaticDataDetectionEnabled = false
        tv.smartInsertDeleteEnabled = false
        tv.textContainerInset = NSSize(width: 4, height: 6)
        tv.string = text
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        guard let tv = scroll.documentView as? NSTextView, tv.string != text else { return }
        tv.string = text
    }

    func makeCoordinator() -> Coordinator { Coordinator(text: $text) }

    final class Coordinator: NSObject, NSTextViewDelegate {
        var text: Binding<String>
        init(text: Binding<String>) { self.text = text }

        func textDidChange(_ note: Notification) {
            guard let tv = note.object as? NSTextView else { return }
            text.wrappedValue = tv.string
        }
    }
}
