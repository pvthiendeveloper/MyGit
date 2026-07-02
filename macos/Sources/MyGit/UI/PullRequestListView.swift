import SwiftUI

/// The PR list for one repo: filter bar + selectable rows + Load More.
struct PullRequestListView: View {
    @ObservedObject var vm: PullRequestsViewModel
    /// Called when a row is picked (multi-repo uses it to activate the repo).
    var onSelect: () -> Void = {}

    var body: some View {
        VStack(spacing: 0) {
            PullRequestFilterBar(vm: vm)
            Divider()
            content
        }
    }

    @ViewBuilder
    private var content: some View {
        if !vm.hasToken {
            message("No access token stored.\nOpen the account panel and add a token to view pull requests.")
        } else if vm.isLoading && vm.loaded.isEmpty {
            ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if vm.filtered.isEmpty {
            message(vm.loaded.isEmpty ? "No pull requests." : "No pull requests match the filters.")
        } else {
            ScrollView {
                LazyVStack(spacing: 0) {
                    ForEach(vm.filtered) { pr in
                        PullRequestRow(pr: pr)
                            .padding(.horizontal, 10)
                            .padding(.vertical, 2)
                            .background(vm.selected == pr
                                        ? Color.accentColor.opacity(0.15) : Color.clear)
                            .contentShape(Rectangle())
                            .onTapGesture {
                                vm.selected = pr
                                onSelect()
                            }
                        Divider()
                    }
                    if vm.hasMore {
                        LoadMoreButton(isLoading: vm.isLoadingMore) { await vm.loadMore() }
                    }
                }
            }
        }
    }

    private func message(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 12))
            .foregroundStyle(.secondary)
            .multilineTextAlignment(.center)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .padding(20)
    }
}

/// Search field + state menu + author menu.
struct PullRequestFilterBar: View {
    @ObservedObject var vm: PullRequestsViewModel

    var body: some View {
        HStack(spacing: 8) {
            HStack(spacing: 4) {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 11)).foregroundStyle(.secondary)
                TextField("Title or #number", text: $vm.searchText)
                    .textFieldStyle(.plain).font(.system(size: 12))
            }
            .padding(.horizontal, 6).padding(.vertical, 4)
            .background(RoundedRectangle(cornerRadius: 6).fill(Color(NSColor.textBackgroundColor)))
            .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(Color.secondary.opacity(0.25)))
            .frame(maxWidth: 240)

            stateMenu
            authorMenu
            Spacer()
        }
        .padding(.horizontal, 8).padding(.vertical, 6)
    }

    private var stateMenu: some View {
        Menu {
            ForEach(PullRequestsViewModel.StateFilter.allCases, id: \.self) { s in
                Button {
                    vm.stateFilter = s
                } label: {
                    if vm.stateFilter == s { Label(s.label, systemImage: "checkmark") }
                    else { Text(s.label) }
                }
            }
        } label: {
            Label(vm.stateFilter.label, systemImage: "line.3.horizontal.decrease.circle")
                .font(.system(size: 12))
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
    }

    private var authorMenu: some View {
        Menu {
            Button {
                vm.authorFilter = nil
            } label: {
                if vm.authorFilter == nil { Label("All authors", systemImage: "checkmark") }
                else { Text("All authors") }
            }
            Divider()
            ForEach(vm.authors, id: \.self) { name in
                Button {
                    vm.authorFilter = name
                } label: {
                    if vm.authorFilter == name { Label(name, systemImage: "checkmark") }
                    else { Text(name) }
                }
            }
        } label: {
            Label(vm.authorFilter ?? "Author", systemImage: "person.circle")
                .font(.system(size: 12)).lineLimit(1)
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
    }
}

/// One PR row: state badge, title, meta line, branch chips, comment count, avatar.
struct PullRequestRow: View {
    let pr: PullRequestSummary

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            avatar
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    StateBadge(state: pr.state)
                    Text(pr.title)
                        .font(.system(size: 13, weight: .medium))
                        .lineLimit(1)
                }
                Text("\(pr.authorName) · #\(pr.number) · \(PRDate.relativeLabel(pr.updatedAt))")
                    .font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(1)
                HStack(spacing: 4) {
                    branchChip(pr.sourceBranch)
                    Image(systemName: "arrow.right").font(.system(size: 8)).foregroundStyle(.secondary)
                    branchChip(pr.destBranch)
                }
            }
            Spacer()
            if pr.commentCount > 0 {
                HStack(spacing: 3) {
                    Image(systemName: "bubble.left")
                    Text("\(pr.commentCount)")
                }
                .font(.system(size: 11)).foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 4)
    }

    private var avatar: some View {
        AsyncImage(url: pr.authorAvatarURL) { phase in
            if case .success(let img) = phase {
                img.resizable().interpolation(.high)
            } else {
                Image(systemName: "person.crop.circle.fill").resizable().foregroundStyle(.secondary)
            }
        }
        .frame(width: 24, height: 24).clipShape(Circle())
    }

    private func branchChip(_ name: String) -> some View {
        Text(name)
            .font(.system(size: 10, design: .monospaced))
            .lineLimit(1).truncationMode(.middle)
            .padding(.horizontal, 6).padding(.vertical, 1)
            .background(Capsule().fill(Color.secondary.opacity(0.15)))
    }
}

/// Colored state chip (OPEN / MERGED / DECLINED …).
struct StateBadge: View {
    let state: PullRequestState
    var body: some View {
        Text(state.label)
            .font(.system(size: 9, weight: .bold))
            .foregroundStyle(state.color)
            .padding(.horizontal, 5).padding(.vertical, 1)
            .background(Capsule().fill(state.color.opacity(0.15)))
    }
}
