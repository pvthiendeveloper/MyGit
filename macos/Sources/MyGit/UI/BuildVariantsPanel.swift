import SwiftUI

/// Android Studio-style "Build Variants" panel: one row per Gradle module with
/// the variant it builds. The application module's variant is what the Run
/// button installs (`:demoApp:installGosaDebug`).
struct BuildVariantsPanel: View {
    @EnvironmentObject var vm: RunViewModel

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            if vm.isLoadingModules && vm.modules.isEmpty {
                loading
            } else if vm.modules.isEmpty {
                empty
            } else {
                table
            }
        }
        .background(Color(NSColor.windowBackgroundColor))
    }

    private var header: some View {
        HStack(spacing: 8) {
            Image(systemName: "square.stack.3d.up")
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
            Text("Build Variants")
                .font(.system(size: 12, weight: .semibold))
            if vm.isLoadingModules {
                ProgressView().controlSize(.small)
            }
            Spacer()
            Button {
                Task { await vm.refreshModules() }
            } label: {
                Image(systemName: "arrow.clockwise").font(.system(size: 11))
            }
            .buttonStyle(.plain)
            .help("Re-read the variants from Gradle")
            Button {
                vm.showVariantsPanel = false
            } label: {
                Image(systemName: "minus").font(.system(size: 11))
            }
            .buttonStyle(.plain)
            .help("Hide panel")
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 7)
    }

    private var loading: some View {
        VStack(spacing: 6) {
            Text("Asking Gradle for the variant list…")
                .font(.system(size: 12)).foregroundStyle(.secondary)
            Text("First run configures the build, so it can take a minute.")
                .font(.system(size: 11)).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var empty: some View {
        VStack(spacing: 8) {
            Text("No Gradle variants found.")
                .font(.system(size: 12)).foregroundStyle(.secondary)
            Button("Load Variants") { Task { await vm.refreshModules() } }
                .controlSize(.small)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var table: some View {
        VStack(spacing: 0) {
            HStack(spacing: 0) {
                Text("Module")
                    .frame(width: 280, alignment: .leading)
                Text("Active Build Variant")
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .font(.system(size: 11, weight: .medium))
            .foregroundStyle(.secondary)
            .padding(.horizontal, 12)
            .padding(.vertical, 5)
            Divider()

            ScrollView {
                LazyVStack(spacing: 0) {
                    ForEach(vm.modules) { module in
                        moduleRow(module)
                        Divider()
                    }
                }
            }
        }
    }

    private func moduleRow(_ module: GradleModule) -> some View {
        let isRunTarget = module.isApplication && module.path == vm.activeModule?.path
        return HStack(spacing: 0) {
            HStack(spacing: 6) {
                Image(systemName: module.isApplication ? "shippingbox.fill" : "building.columns")
                    .font(.system(size: 11))
                    .foregroundStyle(module.isApplication ? Color.green : Color.secondary)
                Text(module.display)
                    .font(.system(size: 12, weight: isRunTarget ? .semibold : .regular))
                    .lineLimit(1)
                    .truncationMode(.head)
                if isRunTarget {
                    Text("run target")
                        .font(.system(size: 9))
                        .foregroundStyle(Color.accentColor)
                }
                Spacer(minLength: 4)
            }
            .frame(width: 280, alignment: .leading)
            .contentShape(Rectangle())
            // Several application modules → clicking one picks what Run builds.
            .onTapGesture { if module.isApplication { vm.activeModulePath = module.path } }

            Picker("", selection: Binding(
                get: { vm.variant(for: module) ?? "" },
                set: { vm.setVariant($0, for: module) }
            )) {
                ForEach(module.variants, id: \.self) { variant in
                    Text(variant).tag(variant)
                }
            }
            .labelsHidden()
            .frame(maxWidth: 260, alignment: .leading)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 4)
    }
}
