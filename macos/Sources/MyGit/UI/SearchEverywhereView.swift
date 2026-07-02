import SwiftUI

/// IntelliJ-style Search Everywhere overlay (double-Shift). Fuzzy file search
/// across the workspace; Enter opens, ↑/↓ navigate, Esc dismisses.
struct SearchEverywhereView: View {
    @EnvironmentObject var coordinator: AppCoordinator
    @EnvironmentObject var search: SearchEverywhereViewModel
    @FocusState private var fieldFocused: Bool

    var body: some View {
        ZStack(alignment: .top) {
            // Dim + click-out to dismiss.
            Color.black.opacity(0.35)
                .ignoresSafeArea()
                .onTapGesture { search.dismiss() }

            VStack(spacing: 0) {
                searchField
                Divider()
                resultList
            }
            .frame(width: 720)
            .frame(maxHeight: 460)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .strokeBorder(Color.primary.opacity(0.12))
            )
            .shadow(color: .black.opacity(0.3), radius: 24, y: 12)
            .padding(.top, 80)
        }
        .onAppear { fieldFocused = true }
        .onExitCommand { search.dismiss() }
    }

    private var searchField: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(.secondary)
            TextField("Search files…", text: $search.query)
                .textFieldStyle(.plain)
                .font(.system(size: 16))
                .focused($fieldFocused)
                .onChange(of: search.query) { _, _ in search.selectedIndex = 0 }
                .onSubmit { open() }
                .onKeyPress(.downArrow) { search.moveSelection(1); return .handled }
                .onKeyPress(.upArrow) { search.moveSelection(-1); return .handled }
                .onKeyPress(.escape) { search.dismiss(); return .handled }
                .onChange(of: search.repoFilter) { _, _ in search.selectedIndex = 0 }
            if search.indexing {
                ProgressView().controlSize(.small)
            }
            if search.repoOptions.count > 1 {
                repoFilterMenu
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
    }

    private var repoFilterMenu: some View {
        Menu {
            Button {
                search.repoFilter = nil
            } label: {
                Label("All Repositories", systemImage: search.repoFilter == nil ? "checkmark" : "")
            }
            Divider()
            ForEach(search.repoOptions) { opt in
                Button {
                    search.repoFilter = opt.id
                } label: {
                    Label(opt.name, systemImage: search.repoFilter == opt.id ? "checkmark" : "")
                }
            }
        } label: {
            HStack(spacing: 4) {
                Image(systemName: "line.3.horizontal.decrease.circle")
                Text(filterLabel).lineLimit(1)
            }
            .font(.system(size: 12))
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
    }

    private var filterLabel: String {
        guard let f = search.repoFilter,
              let opt = search.repoOptions.first(where: { $0.id == f }) else { return "All" }
        return opt.name
    }

    private var resultList: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(spacing: 0) {
                    ForEach(Array(search.results.enumerated()), id: \.element.id) { idx, hit in
                        row(hit, selected: idx == search.selectedIndex)
                            .id(idx)
                            .contentShape(Rectangle())
                            .onTapGesture {
                                search.selectedIndex = idx
                                open()
                            }
                    }
                }
            }
            .onChange(of: search.selectedIndex) { _, new in
                withAnimation(.linear(duration: 0.05)) { proxy.scrollTo(new, anchor: .center) }
            }
            .overlay {
                if search.results.isEmpty && !search.indexing {
                    Text(search.query.isEmpty ? "Type to search files" : "No matches")
                        .font(.system(size: 13))
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
        }
    }

    private func row(_ hit: SearchHit, selected: Bool) -> some View {
        HStack(spacing: 8) {
            Image(systemName: "doc")
                .font(.system(size: 13))
                .foregroundStyle(selected ? Color.white : .secondary)
            Text(hit.name)
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(selected ? Color.white : .primary)
            if !hit.dir.isEmpty {
                Text(hit.dir)
                    .font(.system(size: 11))
                    .foregroundStyle(selected ? Color.white.opacity(0.8) : .secondary)
                    .lineLimit(1)
                    .truncationMode(.head)
            }
            Spacer(minLength: 8)
            Text(hit.repoName)
                .font(.system(size: 11))
                .foregroundStyle(selected ? Color.white.opacity(0.8) : .secondary)
                .lineLimit(1)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 7)
        .background(selected ? Color.accentColor : Color.clear)
    }

    private func open() {
        guard let hit = search.selectedHit else { return }
        coordinator.openSearchHit(hit)
    }
}
