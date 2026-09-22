import SwiftUI

/// Toolbar controls for Android/iOS repos: pick a target device (and, on iOS, a
/// scheme), then build + install + launch it. Hidden for every other project.
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

    var body: some View {
        if vm.kind != .unknown {
            HStack(spacing: 0) {
                separator
                devicePicker
                if vm.kind == .ios {
                    separator
                    schemePicker
                }
                if vm.kind == .android {
                    separator
                    variantButton
                }
                separator
                runButton
                separator
            }
            .task { await vm.refresh() }
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
        guard let device = vm.selectedDevice else { return "Pick a device first" }
        switch vm.kind {
        case .android: return "Build and install on \(device.name)"
        case .ios: return "Build \(vm.selectedScheme ?? "scheme") and run on \(device.name)"
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
