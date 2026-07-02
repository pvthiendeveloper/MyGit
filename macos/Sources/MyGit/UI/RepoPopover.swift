import SwiftUI

struct RepoPopover: View {
    @EnvironmentObject var repos: RepositoryListViewModel
    @Environment(\.dismiss) private var dismiss
    @State private var searchText = ""

    private var filtered: [Workspace] {
        guard !searchText.isEmpty else { return repos.workspaces }
        return repos.workspaces.filter {
            $0.name.localizedCaseInsensitiveContains(searchText)
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(alignment: .center, spacing: 8) {
                Image(systemName: "rectangle.stack").font(.system(size: 16))
                Text("Current Repository")
                    .font(.system(size: 15, weight: .bold))
                    .lineLimit(1)
                Spacer()
                Button { dismiss() } label: {
                    Image(systemName: "xmark").font(.caption2).foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)

            HStack(spacing: 8) {
                HStack(spacing: 6) {
                    Image(systemName: "magnifyingglass").foregroundStyle(.secondary).font(.caption)
                    TextField("Filter", text: $searchText)
                        .textFieldStyle(.plain)
                        .font(.system(size: 12))
                    if !searchText.isEmpty {
                        Button { searchText = "" } label: {
                            Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary).font(.caption)
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 6)
                .background(Color(NSColor.controlBackgroundColor))
                .clipShape(RoundedRectangle(cornerRadius: 6))
                .overlay(RoundedRectangle(cornerRadius: 6).stroke(Color.accentColor, lineWidth: 1))

                Menu {
                    Button("Add Local Repository…") {
                        dismiss()
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
                            repos.pickRepository()
                        }
                    }
                    Button("Add by Path…") {
                        dismiss()
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
                            repos.promptAddByPath()
                        }
                    }
                } label: {
                    HStack(spacing: 4) {
                        Text("Add").font(.system(size: 12, weight: .medium))
                        Image(systemName: "chevron.down").font(.system(size: 9))
                    }
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
                    .background(Color(NSColor.controlBackgroundColor))
                    .clipShape(RoundedRectangle(cornerRadius: 6))
                }
                .menuStyle(.borderlessButton)
                .fixedSize()
            }
            .padding(.horizontal, 12)
            .padding(.bottom, 8)

            Divider()

            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    if !filtered.isEmpty {
                        sectionHeader("Other")
                        ForEach(filtered) { workspace in
                            RepoRow(workspace: workspace) {
                                repos.select(workspace)
                                dismiss()
                            } onRemove: {
                                repos.remove(workspace)
                            }
                        }
                    } else {
                        Text("No repositories match")
                            .font(.system(size: 12))
                            .foregroundStyle(.secondary)
                            .padding(16)
                    }
                }
                .padding(.vertical, 4)
            }
        }
        .frame(width: 340, height: 420)
    }

    private func sectionHeader(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 11, weight: .semibold))
            .foregroundStyle(.secondary)
            .padding(.horizontal, 12)
            .padding(.vertical, 4)
            .frame(maxWidth: .infinity, alignment: .leading)
    }
}

private struct RepoRow: View {
    let workspace: Workspace
    let onSelect: () -> Void
    let onRemove: () -> Void

    @EnvironmentObject var repos: RepositoryListViewModel
    @State private var isHovered = false

    private var isCurrent: Bool { repos.selected?.url == workspace.url }

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: workspace.isSingle ? "desktopcomputer" : "rectangle.stack")
                .font(.system(size: 13))
                .foregroundStyle(isCurrent ? Color.white : Color.primary)
                .frame(width: 18)

            VStack(alignment: .leading, spacing: 1) {
                Text(workspace.name)
                    .font(.system(size: 12, weight: isCurrent ? .semibold : .regular))
                    .foregroundStyle(isCurrent ? Color.white : Color.primary)
                    .lineLimit(1)
                if !workspace.isSingle {
                    Text("\(workspace.repos.count) repos")
                        .font(.system(size: 10))
                        .foregroundStyle(isCurrent ? Color.white.opacity(0.85) : Color.secondary)
                }
            }

            Spacer()

            if isHovered {
                Button(action: onRemove) {
                    Image(systemName: "minus.circle.fill")
                        .foregroundStyle(isCurrent ? Color.white : Color.red)
                        .font(.system(size: 12))
                }
                .buttonStyle(.plain)
                .help("Remove from list")
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 7)
        .background(
            isCurrent ? Color.accentColor :
            (isHovered ? Color.accentColor.opacity(0.15) : Color.clear)
        )
        .clipShape(RoundedRectangle(cornerRadius: 4))
        .contentShape(Rectangle())
        .onHover { isHovered = $0 }
        .onTapGesture(perform: onSelect)
        .padding(.horizontal, 4)
    }
}
