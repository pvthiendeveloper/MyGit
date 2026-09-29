import SwiftUI
import AppKit

/// Standalone window listing simulator OS versions (View ▸ Simulator Runtimes).
/// Its model outlives the window, so downloads keep going once it's closed.
@MainActor
final class SimulatorRuntimesWindow: NSObject, NSWindowDelegate {
    private static var shared: SimulatorRuntimesWindow?
    static let model = SimulatorRuntimesViewModel()
    private var window: NSWindow?
    private var viewModel: SimulatorRuntimesViewModel { Self.model }

    static func open() {
        if let existing = shared?.window {
            existing.makeKeyAndOrderFront(nil)
            return
        }
        let instance = SimulatorRuntimesWindow()
        let hosting = NSHostingController(rootView: SimulatorRuntimesView().environmentObject(instance.viewModel))
        let win = NSWindow(contentViewController: hosting)
        win.title = "Simulator Runtimes"
        win.styleMask = [.titled, .closable, .miniaturizable, .resizable]
        win.setContentSize(NSSize(width: 720, height: 620))
        win.setFrameAutosaveName("MyGit.SimulatorRuntimes")
        win.delegate = instance
        win.makeKeyAndOrderFront(nil)
        instance.window = win
        instance.viewModel.refresh()
        shared = instance
    }

    func windowWillClose(_ notification: Notification) {
        SimulatorRuntimesWindow.shared = nil
        window = nil
    }
}

struct SimulatorRuntimesView: View {
    @EnvironmentObject var vm: SimulatorRuntimesViewModel
    @State private var confirmDelete: SimulatorRuntime?
    @State private var creatingFor: SimulatorRuntime?
    @State private var confirmDeleteDevice: SimDevice?
    @State private var expanded: Set<String> = []

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            if vm.loading && vm.runtimes.isEmpty {
                ProgressView("Loading runtimes…").frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                list
            }
            Divider()
            footer
        }
        .frame(minWidth: 560, minHeight: 400)
        .alert("Simulator Runtimes", isPresented: Binding(get: { vm.errorMessage != nil },
                                                          set: { if !$0 { vm.errorMessage = nil } })) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(vm.errorMessage ?? "")
        }
        .sheet(item: $creatingFor) { runtime in
            NewSimulatorSheet(runtime: runtime) { name, type, boot in
                vm.createSimulator(name: name, type: type, runtime: runtime, boot: boot)
                if let id = runtime.runtimeIdentifier { expanded.insert(id) }
            }
        }
        .confirmationDialog("Delete simulator \(confirmDeleteDevice?.name ?? "")?", isPresented: Binding(
            get: { confirmDeleteDevice != nil }, set: { if !$0 { confirmDeleteDevice = nil } }),
            presenting: confirmDeleteDevice) { device in
            Button("Delete", role: .destructive) { vm.deleteSimulator(device.udid) }
        } message: { _ in
            Text("Its apps and data are removed.")
        }
        .confirmationDialog("Delete \(confirmDelete?.name ?? "")?", isPresented: Binding(
            get: { confirmDelete != nil }, set: { if !$0 { confirmDelete = nil } }), presenting: confirmDelete) { runtime in
            Button("Delete", role: .destructive) { vm.delete(runtime) }
        } message: { runtime in
            Text("Frees \(Self.size(runtime.sizeBytes) ?? "its disk space"). Simulators on this version stop working until it's downloaded again.")
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 10) {
            Picker("", selection: $vm.platform) {
                ForEach(SimulatorRuntime.Platform.allCases) { p in
                    Text("\(p.rawValue) (\(vm.count(installed: true, for: p)))").tag(p)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            HStack(spacing: 16) {
                stat(vm.installed.count, "downloaded", color: .green, icon: "checkmark.circle.fill")
                stat(vm.notInstalled.count, "not downloaded", color: .secondary, icon: "arrow.down.circle")
                Spacer()
                Toggle("Betas", isOn: $vm.showBetas).toggleStyle(.checkbox)
                Toggle("Unsupported", isOn: $vm.showIncompatible).toggleStyle(.checkbox)
                    .help("Also versions this macOS or Xcode can't run")
                if vm.importing {
                    ProgressView().controlSize(.small)
                    Text("Importing…").foregroundStyle(.secondary)
                } else {
                    Button("Import Runtime…") { vm.importRuntime() }
                        .help("Add a runtime .dmg you downloaded (e.g. from developer.apple.com)")
                }
                Button { vm.refresh() } label: { Image(systemName: "arrow.clockwise") }
                    .buttonStyle(.borderless)
                    .disabled(vm.loading)
                    .help("Reload")
            }
        }
        .padding(12)
    }

    private func stat(_ n: Int, _ label: String, color: Color, icon: String) -> some View {
        Label {
            Text("\(n)").font(.title3.monospacedDigit().bold()) + Text(" \(label)").foregroundColor(.secondary)
        } icon: {
            Image(systemName: icon).foregroundStyle(color)
        }
    }

    private var list: some View {
        List {
            Section("Downloaded (\(vm.installed.count))") {
                if vm.installed.isEmpty {
                    Text("No \(vm.platform.rawValue) simulator runtime installed.").foregroundStyle(.secondary)
                }
                ForEach(vm.installed) { installedRow($0) }
            }
            Section("Not downloaded (\(vm.notInstalled.count))") {
                if let error = vm.catalogError {
                    Label(error, systemImage: "wifi.exclamationmark").foregroundStyle(.orange)
                } else if vm.notInstalled.isEmpty {
                    Text("Nothing else to download.").foregroundStyle(.secondary)
                }
                ForEach(vm.notInstalled) { row($0) }
            }
        }
        .listStyle(.inset(alternatesRowBackgrounds: true))
    }

    /// An installed runtime, expanding into its simulators.
    private func installedRow(_ r: SimulatorRuntime) -> some View {
        let key = r.runtimeIdentifier ?? r.id
        let sims = vm.devices(of: r)
        return DisclosureGroup(isExpanded: Binding(
            get: { expanded.contains(key) },
            set: { if $0 { expanded.insert(key) } else { expanded.remove(key) } })) {
            ForEach(sims) { deviceRow($0) }
            HStack {
                if sims.isEmpty { Text("No simulator on this version yet.").foregroundStyle(.secondary) }
                Spacer()
                if let id = r.runtimeIdentifier, vm.busy.contains(id) {
                    ProgressView().controlSize(.small)
                }
                Button { creatingFor = r } label: { Label("New Simulator…", systemImage: "plus") }
                    .disabled(r.deviceTypes.isEmpty || r.incompatibility != nil)
            }
            .padding(.leading, 26)
        } label: {
            row(r, simulators: sims)
        }
    }

    private func deviceRow(_ d: SimDevice) -> some View {
        HStack(spacing: 8) {
            Circle().fill(d.isBooted ? Color.green : Color.secondary.opacity(0.4)).frame(width: 7, height: 7)
            Image(systemName: d.name.contains("iPad") ? "ipad" : d.name.contains("Watch") ? "applewatch" : "iphone")
                .foregroundStyle(.secondary)
            Text(d.name)
            Text(d.state).font(.caption).foregroundStyle(.secondary)
            if !d.isAvailable { badge("Unavailable", .red) }
            Spacer()
            if vm.busy.contains(d.udid) {
                ProgressView().controlSize(.small)
            } else {
                if d.isBooted {
                    Button("Show") { vm.bootSimulator(d.udid) }
                    Button("Shut Down") { vm.shutdownSimulator(d.udid) }
                } else {
                    Button("Start") { vm.bootSimulator(d.udid) }.disabled(!d.isAvailable)
                }
                Button(role: .destructive) { confirmDeleteDevice = d } label: { Image(systemName: "trash") }
                    .buttonStyle(.borderless)
                    .help("Delete this simulator")
            }
        }
        .padding(.leading, 26)
        .contextMenu {
            Button("Copy UDID") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(d.udid, forType: .string)
            }
        }
    }

    private func row(_ r: SimulatorRuntime, simulators: [SimDevice]? = nil) -> some View {
        HStack(spacing: 10) {
            Image(systemName: r.isInstalled ? "checkmark.circle.fill" : "circle.dashed")
                .foregroundStyle(r.isInstalled ? .green : .secondary)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(r.name).fontWeight(.medium)
                    if r.isBeta { badge("Beta", .orange) }
                    if let why = r.incompatibility { badge(why, .red) }
                }
                Text(details(r, simulators: simulators)).font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            actions(r)
        }
        .padding(.vertical, 2)
    }

    @ViewBuilder
    private func actions(_ r: SimulatorRuntime) -> some View {
        if let progress = vm.downloads[r.build] {
            if let progress {
                ProgressView(value: progress).frame(width: 100)
                Text("\(Int(progress * 100))%").monospacedDigit().font(.caption).frame(width: 34, alignment: .trailing)
            } else {
                ProgressView().controlSize(.small)
            }
            Button("Cancel") { vm.cancelDownload(r) }
        } else if r.isInstalled {
            if let id = r.installedID, vm.deleting.contains(id) {
                ProgressView().controlSize(.small)
            } else if r.deletable {
                Button(role: .destructive) { confirmDelete = r } label: { Image(systemName: "trash") }
                    .buttonStyle(.borderless)
                    .help("Delete this runtime")
            } else {
                Text("Bundled with Xcode").font(.caption).foregroundStyle(.secondary)
            }
        } else {
            switch r.source {
            case .developerPortal:
                Button { vm.download(r) } label: { Label("Apple Developer", systemImage: "safari") }
                    .disabled(r.incompatibility != nil)
                    .help("Needs your Apple ID: downloads in the browser, then Import Runtime…")
            case .package:
                Button("Download") { vm.download(r) }
                    .disabled(r.incompatibility != nil)
                    .help("Downloads the disk image, then installs it (asks for your password)")
            case .xcodebuild:
                Button("Download") { vm.download(r) }
                    .disabled(r.incompatibility != nil)
            }
        }
    }

    private func details(_ r: SimulatorRuntime, simulators: [SimDevice]?) -> String {
        var parts = ["\(r.platform.rawValue) \(r.version)", r.build]
        if let simulators {
            let booted = simulators.filter(\.isBooted).count
            parts.append("\(simulators.count) simulator\(simulators.count == 1 ? "" : "s")" + (booted > 0 ? " (\(booted) running)" : ""))
        }
        if let size = Self.size(r.sizeBytes) { parts.append(size) }
        if let used = r.lastUsed {
            parts.append("used " + used.formatted(.relative(presentation: .named)))
        }
        return parts.joined(separator: " · ")
    }

    private func badge(_ text: String, _ color: Color) -> some View {
        Text(text)
            .font(.caption2.weight(.semibold))
            .padding(.horizontal, 5).padding(.vertical, 1)
            .background(color.opacity(0.15), in: Capsule())
            .foregroundStyle(color)
    }

    private var footer: some View {
        HStack {
            if let xcode = vm.xcodeVersion {
                Text("Xcode \(xcode)").foregroundStyle(.secondary)
            }
            Spacer()
            let total = vm.runtimes.filter(\.isInstalled).compactMap(\.sizeBytes).reduce(0, +)
            if let size = Self.size(total), total > 0 {
                Text("Runtimes use \(size) on disk").foregroundStyle(.secondary)
            }
        }
        .font(.caption)
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
    }

    static func size(_ bytes: Int64?) -> String? {
        bytes.map { ByteCountFormatter.string(fromByteCount: $0, countStyle: .file) }
    }
}

/// Pick a device type and name for `simctl create`.
private struct NewSimulatorSheet: View {
    let runtime: SimulatorRuntime
    let create: (String, SimDeviceType, Bool) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var typeID = ""
    @State private var name = ""
    @State private var nameEdited = false
    @State private var boot = true

    private var families: [(String, [SimDeviceType])] {
        Dictionary(grouping: runtime.deviceTypes, by: \.family)
            .map { ($0.key, $0.value) }   // simctl lists newest first
            .sorted { $0.0 < $1.0 }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("New Simulator").font(.headline)
            Form {
                LabeledContent("OS", value: runtime.name)
                Picker("Device", selection: $typeID) {
                    ForEach(families, id: \.0) { family, types in
                        Section(family.isEmpty ? "Other" : family) {
                            ForEach(types) { Text($0.name).tag($0.id) }
                        }
                    }
                }
                TextField("Name", text: Binding(get: { name }, set: { name = $0; nameEdited = true }))
                Toggle("Start it now", isOn: $boot)
            }
            HStack {
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("Create") {
                    guard let type = runtime.deviceTypes.first(where: { $0.id == typeID }) else { return }
                    create(name.trimmingCharacters(in: .whitespaces), type, boot)
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(typeID.isEmpty || name.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
        .padding(20)
        .frame(width: 420)
        .onAppear {
            // The newest iPhone (simctl lists newest first), else the first type.
            let pick = runtime.deviceTypes.first { $0.family == "iPhone" } ?? runtime.deviceTypes.first
            typeID = pick?.id ?? ""
        }
        .onChange(of: typeID) { _, id in
            // Follow the device until the user names it.
            if !nameEdited { name = runtime.deviceTypes.first { $0.id == id }.map { "\($0.name) (\(runtime.version))" } ?? "" }
        }
    }
}
