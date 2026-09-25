import SwiftUI

/// Settings ▸ AI ▸ Local: download coding models and run them on this Mac.
struct LocalModelsSettingsView: View {
    @EnvironmentObject var settings: SettingsViewModel
    @ObservedObject private var local = LocalModelsViewModel.shared

    private var provider: AIProvider { .local }
    private var isActive: Bool { settings.activeProvider == provider }
    private var selected: String { settings.model(for: provider) }

    var body: some View {
        Form {
            Section {
                Toggle("Use for AI features", isOn: Binding(
                    get: { isActive },
                    set: { if $0 { settings.setActive(provider) } }
                ))
                .disabled(isActive || !local.installed.contains(selected))
                .help(local.installed.contains(selected)
                      ? "Commit messages, PR descriptions, completions and the UI Inspector's AI pick use the selected local model."
                      : "Download the selected model first.")
                HStack {
                    Button("Test Model") { settings.testConnection(for: provider) }
                        .disabled(settings.status(for: provider) == .testing || !local.installed.contains(selected))
                    testStatusView
                }
                Text(provider.hint)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section {
                ForEach(local.catalog) { spec in
                    ModelRow(spec: spec, isSelected: spec.id == selected,
                             select: { settings.setModel(spec.id, for: provider) })
                }
            } header: {
                HStack {
                    Text("Models")
                    Spacer()
                    Text("This Mac: \(local.physicalMemoryGB) GB memory")
                        .foregroundStyle(.secondary)
                }
            } footer: {
                Text("GGUF builds from Hugging Face, checked against their SHA-256 after download. Pick one that fits in memory with room to spare: a model that doesn't fit swaps and crawls.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("Runtime") {
                LabeledContent("llama.cpp \(LocalModelCatalog.runtimeBuild)") {
                    if let state = local.downloads[LocalModelsViewModel.runtimeKey] {
                        ProgressView(value: state.fraction).frame(width: 120)
                    } else if local.runtimeInstalled {
                        Label("Installed", systemImage: "checkmark.circle.fill").foregroundStyle(.green)
                    } else {
                        Button("Install (\(ByteCountFormatter.string(fromByteCount: LocalModelCatalog.runtimeSizeBytes, countStyle: .file)))") {
                            local.installRuntime()
                        }
                    }
                }
                if let error = local.errors[LocalModelsViewModel.runtimeKey] {
                    Label(error, systemImage: "xmark.octagon.fill").foregroundStyle(.red).font(.caption)
                }
                LabeledContent("Loaded model") {
                    HStack {
                        Text(local.loadedModel.flatMap { LocalModelCatalog.model(id: $0)?.name } ?? "None")
                            .foregroundStyle(.secondary)
                        if local.loadedModel != nil {
                            Button("Unload") { local.unload() }
                        }
                    }
                }
                Text("Installed with the first model download. The model loads on first use and unloads after 15 minutes idle.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Button("Show Models in Finder") { local.revealInFinder() }
            }
        }
        .formStyle(.grouped)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .navigationTitle(provider.displayName)
        .onAppear { local.refresh() }
    }

    @ViewBuilder
    private var testStatusView: some View {
        switch settings.status(for: provider) {
        case .idle:
            EmptyView()
        case .testing:
            HStack(spacing: 6) {
                ProgressView().controlSize(.small)
                Text("Loading model…").foregroundStyle(.secondary)
            }
            .font(.caption)
        case .success(let detail):
            Label(detail, systemImage: "checkmark.circle.fill").foregroundStyle(.green).font(.caption)
        case .failure(let msg):
            Label(msg, systemImage: "xmark.octagon.fill").foregroundStyle(.red).font(.caption)
                .lineLimit(3).help(msg)
        }
    }
}

/// One catalog model: what it is, whether it fits, and download / use / delete.
private struct ModelRow: View {
    let spec: LocalModelSpec
    let isSelected: Bool
    let select: () -> Void
    @ObservedObject private var local = LocalModelsViewModel.shared
    @State private var confirmDelete = false

    private var isInstalled: Bool { local.installed.contains(spec.id) }
    private var tooBig: Bool { spec.recommendedRAMGB > local.physicalMemoryGB }

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: isSelected ? "largecircle.fill.circle" : "circle")
                .foregroundStyle(isSelected ? Color.accentColor : .secondary)
                .onTapGesture(perform: select)
                .padding(.top, 2)
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(spec.name).fontWeight(.medium)
                    if spec.recommended { tag("Recommended", .accentColor) }
                    if tooBig { tag("Needs \(spec.recommendedRAMGB) GB", .orange) }
                }
                Text(spec.summary).font(.caption).foregroundStyle(.secondary)
                Text("\(spec.parameters) · \(spec.quantization) · \(size(spec.sizeBytes)) · \(spec.contextLength / 1024)K context")
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(.tertiary)
                if let state = local.downloads[spec.id] {
                    ProgressView(value: state.fraction)
                    Text(progressText(state)).font(.caption2.monospacedDigit()).foregroundStyle(.secondary)
                }
                if let error = local.errors[spec.id] {
                    Text(error).font(.caption).foregroundStyle(.red)
                }
            }
            Spacer()
            actions
        }
        .contentShape(Rectangle())
        .onTapGesture(perform: select)
        .padding(.vertical, 2)
        .confirmationDialog("Delete \(spec.name)?", isPresented: $confirmDelete) {
            Button("Delete \(size(spec.sizeBytes))", role: .destructive) { local.delete(spec) }
        }
    }

    @ViewBuilder
    private var actions: some View {
        if local.isDownloading(spec.id) {
            Button("Cancel") { local.cancel(spec.id) }
        } else if isInstalled {
            HStack {
                Label("Downloaded", systemImage: "checkmark.circle.fill")
                    .labelStyle(.iconOnly)
                    .foregroundStyle(.green)
                    .help("Downloaded")
                Button(role: .destructive) { confirmDelete = true } label: { Image(systemName: "trash") }
                    .buttonStyle(.borderless)
                    .help("Delete the model file")
            }
        } else {
            let partial = local.partialBytes(spec)
            Button(partial > 0 ? "Resume" : "Download") {
                local.download(spec)
                select()
            }
        }
    }

    private func tag(_ text: String, _ color: Color) -> some View {
        Text(text)
            .font(.caption2.weight(.medium))
            .padding(.horizontal, 5)
            .padding(.vertical, 1)
            .background(color.opacity(0.15), in: Capsule())
            .foregroundStyle(color)
    }

    private func size(_ bytes: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
    }

    private func progressText(_ s: LocalModelsViewModel.DownloadState) -> String {
        var text = "\(size(s.received)) of \(size(s.total))"
        if s.rate > 0 {
            text += " · \(size(Int64(s.rate)))/s"
            let left = Double(s.total - s.received) / s.rate
            if left.isFinite, left > 0 {
                let f = DateComponentsFormatter()
                f.allowedUnits = left > 3600 ? [.hour, .minute] : [.minute, .second]
                f.unitsStyle = .abbreviated
                text += " · \(f.string(from: left) ?? "") left"
            }
        }
        return text
    }
}
