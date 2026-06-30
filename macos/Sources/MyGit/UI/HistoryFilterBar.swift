import SwiftUI

/// Top toolbar of the history graph: text/hash search with regex + case
/// toggles, then Branch / User / Date / Paths menus and a sort toggle.
/// Mutates `HistoryViewModel.filter`, which re-queries the log (debounced).
struct HistoryFilterBar: View {
    @EnvironmentObject var vm: HistoryViewModel
    @EnvironmentObject var branches: BranchesViewModel

    private var authors: [String] {
        Array(Set(vm.commits.map { $0.author })).sorted()
    }

    var body: some View {
        HStack(spacing: 6) {
            // Search field
            HStack(spacing: 4) {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 11)).foregroundStyle(.secondary)
                TextField("Text or hash", text: $vm.filter.searchText)
                    .textFieldStyle(.plain)
                    .font(.system(size: 12))
                toggle(".*", isOn: $vm.filter.useRegex, help: "Regular expression")
                toggle("Cc", isOn: $vm.filter.caseSensitive, help: "Case sensitive")
            }
            .padding(.horizontal, 6).padding(.vertical, 4)
            .background(RoundedRectangle(cornerRadius: 6).fill(Color(NSColor.textBackgroundColor)))
            .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(Color.secondary.opacity(0.25)))
            .frame(maxWidth: 280)

            branchMenu
            userMenu
            dateMenu

            Spacer()

            Button {
                vm.filter.sort = vm.filter.sort == .topo ? .date : .topo
            } label: {
                Image(systemName: vm.filter.sort == .topo ? "arrow.triangle.branch" : "calendar")
            }
            .buttonStyle(.borderless)
            .help(vm.filter.sort == .topo ? "Topology order" : "Date order")
        }
        .padding(.horizontal, 8).padding(.vertical, 6)
    }

    private func toggle(_ label: String, isOn: Binding<Bool>, help: String) -> some View {
        Button { isOn.wrappedValue.toggle() } label: {
            Text(label)
                .font(.system(size: 11, weight: .semibold, design: .monospaced))
                .padding(.horizontal, 4).padding(.vertical, 1)
                .background(RoundedRectangle(cornerRadius: 4)
                    .fill(isOn.wrappedValue ? Color.accentColor.opacity(0.25) : .clear))
                .foregroundStyle(isOn.wrappedValue ? Color.accentColor : .secondary)
        }
        .buttonStyle(.plain)
        .help(help)
    }

    private var branchMenu: some View {
        Menu {
            Button("All branches") { vm.filter.branchScope = .all }
            Divider()
            ForEach(branches.branches) { b in
                Button(b.name) { vm.filter.branchScope = .ref(b.checkoutName) }
            }
        } label: {
            menuLabel("Branch", active: { if case .ref = vm.filter.branchScope { return true }; return false }())
        }
        .menuStyle(.borderlessButton).fixedSize()
    }

    private var userMenu: some View {
        Menu {
            Button("Any user") { vm.filter.author = nil }
            Divider()
            ForEach(authors, id: \.self) { a in
                Button(a) { vm.filter.author = a }
            }
        } label: {
            menuLabel("User", active: vm.filter.author != nil)
        }
        .menuStyle(.borderlessButton).fixedSize()
    }

    private var dateMenu: some View {
        Menu {
            Button("Any time") { vm.filter.since = nil }
            Button("Last 24 hours") { vm.filter.since = "1 day ago" }
            Button("Last week") { vm.filter.since = "1 week ago" }
            Button("Last month") { vm.filter.since = "1 month ago" }
            Button("Last year") { vm.filter.since = "1 year ago" }
        } label: {
            menuLabel("Date", active: vm.filter.since != nil)
        }
        .menuStyle(.borderlessButton).fixedSize()
    }

    private func menuLabel(_ text: String, active: Bool) -> some View {
        HStack(spacing: 2) {
            Text(text).font(.system(size: 12))
            Image(systemName: "chevron.down").font(.system(size: 8))
        }
        .foregroundStyle(active ? Color.accentColor : .secondary)
    }
}
