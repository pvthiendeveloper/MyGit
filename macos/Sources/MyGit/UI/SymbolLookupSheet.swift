import SwiftUI

/// Picker shown when a ⌘-click can't resolve to a single spot.
///
/// A common name (`CGFloat`, `id`, `name`) can hit hundreds of lines, so the
/// list is grouped per file and collapsed by default — the user scans files
/// first, then lines. A scope menu (top-level folder) and a text filter cut the
/// set down further, and the declarations/usages switch avoids a second search.
struct SymbolLookupSheet: View {
    let lookup: SymbolLookup
    var onPick: (SymbolOccurrence) -> Void

    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var editor: FileEditorViewModel
    @State private var kind: SymbolLookup.Kind
    @State private var query = ""
    @State private var scope: String = Self.allScopes
    @State private var selection: SymbolOccurrence.ID?
    @State private var expanded: Set<String> = []
    @State private var didSeedExpansion = false
    // Preview pane: the whole file, scrolled to the selected hit.
    @State private var previewPath: String?
    @State private var previewText = ""
    @State private var previewGoto: EditorGoto?
    /// Last tab the user picked — the sheet reopens on it when it has results.
    @AppStorage("MyGit.symbolLookup.kind") private var rememberedKind = ""

    private static let allScopes = "\u{0}all"

    init(lookup: SymbolLookup, onPick: @escaping (SymbolOccurrence) -> Void) {
        self.lookup = lookup
        self.onPick = onPick
        _kind = State(initialValue: lookup.initialKind)
    }

    // MARK: - Derived data

    private var all: [SymbolOccurrence] { lookup.results(for: kind) }

    /// Top-level folder of each path ("Sources", "Tests", …) with hit counts.
    private var scopes: [(name: String, count: Int)] {
        Dictionary(grouping: all, by: { Self.topLevel($0.path) })
            .map { ($0.key, $0.value.count) }
            .sorted { $0.count == $1.count ? $0.name < $1.name : $0.count > $1.count }
    }

    private var filtered: [SymbolOccurrence] {
        let q = query.trimmingCharacters(in: .whitespaces).lowercased()
        return all.filter { hit in
            (scope == Self.allScopes || Self.topLevel(hit.path) == scope)
                && (q.isEmpty
                    || hit.path.lowercased().contains(q)
                    || hit.preview.lowercased().contains(q))
        }
    }

    private var groups: [SymbolFileGroup] {
        SymbolFileGroup.group(filtered, originPath: lookup.originPath)
    }

    private var selectedOccurrence: SymbolOccurrence? {
        guard let selection else { return nil }
        return filtered.first { $0.id == selection }
    }

    // MARK: - Body

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            header
            controls
            HStack(spacing: 10) {
                list.frame(width: 420)
                Divider()
                preview
            }
            footer
        }
        .padding(16)
        .frame(width: 940, height: 600)
        .onAppear(perform: restoreAndSeed)
        .onChange(of: kind) { _, newKind in
            rememberedKind = newKind.rawValue
            resetForNewSet()
        }
        .onChange(of: scope) { _, _ in resetForNewSet() }
        .onChange(of: selection) { _, _ in loadPreview() }
    }

    /// Right-hand pane: the selected hit's file, syntax-highlighted and
    /// scrolled to the line — scroll freely to read the rest of the file.
    @ViewBuilder
    private var preview: some View {
        VStack(alignment: .leading, spacing: 6) {
            if let hit = selectedOccurrence {
                HStack(spacing: 6) {
                    Text((hit.path as NSString).lastPathComponent)
                        .font(.system(size: 12, weight: .semibold))
                    Text(":\(hit.line)")
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundStyle(.secondary)
                    Spacer()
                    Button("Open") { onPick(hit); dismiss() }
                        .controlSize(.small)
                }
                if previewText.isEmpty {
                    placeholder("Can't preview this file (binary or unreadable).")
                } else {
                    CodeEditor(
                        text: .constant(previewText),
                        syntaxExt: (hit.path as NSString).pathExtension,
                        isEditable: false,
                        goto: previewGoto
                    )
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .clipShape(RoundedRectangle(cornerRadius: 6))
                }
            } else {
                placeholder("Select a match to preview it here.")
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private func placeholder(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 12))
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    /// Load the selected hit's file (cached per path) and point the preview at
    /// its line.
    private func loadPreview() {
        guard let hit = selectedOccurrence else {
            previewPath = nil
            previewText = ""
            previewGoto = nil
            return
        }
        if previewPath != hit.path {
            previewPath = hit.path
            previewText = editor.fileContents(path: hit.path) ?? ""
        }
        previewGoto = previewText.isEmpty ? nil : EditorGoto(line: hit.line)
    }

    private var header: some View {
        HStack(spacing: 10) {
            Text(lookup.symbol)
                .font(.system(size: 14, weight: .semibold, design: .monospaced))
            Picker("", selection: $kind) {
                Text("Usages (\(lookup.usages.count))").tag(SymbolLookup.Kind.usages)
                Text("Declarations (\(lookup.definitions.count))").tag(SymbolLookup.Kind.definitions)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .fixedSize()
            Spacer()
            Text("\(filtered.count) in \(groups.count) file\(groups.count == 1 ? "" : "s")")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private var controls: some View {
        HStack(spacing: 8) {
            HStack(spacing: 5) {
                Image(systemName: "line.3.horizontal.decrease.circle")
                    .foregroundStyle(.secondary)
                TextField("Filter by path or line", text: $query)
                    .textFieldStyle(.plain)
                    .font(.system(size: 12))
                if !query.isEmpty {
                    Button { query = "" } label: {
                        Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 8).padding(.vertical, 5)
            .background(RoundedRectangle(cornerRadius: 6).fill(Color(NSColor.textBackgroundColor)))

            Picker("", selection: $scope) {
                Text("All folders").tag(Self.allScopes)
                ForEach(scopes, id: \.name) { s in
                    Text("\(s.name) (\(s.count))").tag(s.name)
                }
            }
            .labelsHidden()
            .frame(maxWidth: 220)

            Button(expanded.count == groups.count ? "Collapse All" : "Expand All") {
                expanded = expanded.count == groups.count ? [] : Set(groups.map { $0.path })
            }
            .controlSize(.small)
            .disabled(groups.isEmpty)
        }
    }

    @ViewBuilder
    private var list: some View {
        if groups.isEmpty {
            Text("Nothing matches this filter.")
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            List(selection: $selection) {
                ForEach(groups) { group in
                    fileRow(group)
                    if expanded.contains(group.path) {
                        ForEach(group.occurrences) { hit in
                            lineRow(hit).tag(hit.id)
                        }
                    }
                }
            }
            .listStyle(.inset)
            .frame(maxHeight: .infinity)
        }
    }

    private func fileRow(_ group: SymbolFileGroup) -> some View {
        HStack(spacing: 6) {
            Image(systemName: expanded.contains(group.path) ? "chevron.down" : "chevron.right")
                .font(.system(size: 9, weight: .semibold))
                .foregroundStyle(.secondary)
                .frame(width: 10)
            Text(group.name)
                .font(.system(size: 12, weight: .semibold))
            Text(group.directory)
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.head)
            Spacer(minLength: 6)
            if group.path == lookup.originPath {
                Text("this file")
                    .font(.system(size: 10))
                    .foregroundStyle(Color.accentColor)
            }
            Text("\(group.occurrences.count)")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .padding(.horizontal, 5).padding(.vertical, 1)
                .background(Capsule().fill(Color.secondary.opacity(0.15)))
        }
        .padding(.vertical, 2)
        .contentShape(Rectangle())
        .onTapGesture { toggle(group.path) }
        // Headers only fold/unfold — selection belongs to the lines under them.
        .selectionDisabled()
    }

    private func lineRow(_ hit: SymbolOccurrence) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text("\(hit.line)")
                .font(.system(size: 11, design: .monospaced))
                .foregroundStyle(.secondary)
                .frame(width: 44, alignment: .trailing)
            Text(highlighted(hit.preview))
                .font(.system(size: 11, design: .monospaced))
                .lineLimit(1)
                .truncationMode(.tail)
            Spacer(minLength: 0)
            if hit.isDefinition {
                Text("decl")
                    .font(.system(size: 9, weight: .medium))
                    .foregroundStyle(.orange)
            }
        }
        .padding(.leading, 16)
        .contentShape(Rectangle())
        // Single click previews on the right; double click jumps to the file.
        .onTapGesture(count: 2) { onPick(hit); dismiss() }
        .onTapGesture { selection = hit.id }
    }

    private var footer: some View {
        HStack {
            Text("Double-click a line to jump. Backed by `git grep` — unrelated names can appear.")
                .font(.caption)
                .foregroundStyle(.secondary)
            Spacer()
            Button("Close") { dismiss() }.keyboardShortcut(.cancelAction)
            Button("Go") {
                if let hit = selectedOccurrence { onPick(hit) }
                dismiss()
            }
            .keyboardShortcut(.defaultAction)
            .disabled(selectedOccurrence == nil)
        }
    }

    // MARK: - Behaviour

    /// Reopen on the tab the user last used, then expand. The remembered tab is
    /// skipped when it has nothing to show, so an empty list never greets them.
    private func restoreAndSeed() {
        guard !didSeedExpansion else { return }
        didSeedExpansion = true
        if let remembered = SymbolLookup.Kind(rawValue: rememberedKind),
           remembered != kind,
           !lookup.results(for: remembered).isEmpty {
            kind = remembered   // triggers resetForNewSet, which expands
        } else {
            applyDefaultExpansion()
        }
    }

    private func resetForNewSet() {
        selection = nil
        applyDefaultExpansion()
    }

    private func applyDefaultExpansion() {
        let groups = self.groups
        if groups.count <= 4 {
            expanded = Set(groups.map { $0.path })
        } else {
            expanded = Set(groups.filter { $0.path == lookup.originPath }.map { $0.path })
        }
    }

    private func toggle(_ path: String) {
        if expanded.contains(path) { expanded.remove(path) } else { expanded.insert(path) }
    }

    /// Bold the symbol inside the matched line so the eye lands on it.
    private func highlighted(_ line: String) -> AttributedString {
        var text = AttributedString(line)
        var cursor = text.startIndex
        while let range = text[cursor...].range(of: lookup.symbol) {
            text[range].font = .system(size: 11, weight: .bold, design: .monospaced)
            text[range].foregroundColor = .accentColor
            cursor = range.upperBound
            if cursor >= text.endIndex { break }
        }
        return text
    }

    private static func topLevel(_ path: String) -> String {
        path.split(separator: "/").first.map(String.init) ?? path
    }
}
