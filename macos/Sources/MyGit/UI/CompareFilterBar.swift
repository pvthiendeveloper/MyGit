import SwiftUI

struct CompareFilterBar: View {
    @Binding var filter: CompareFilter
    let authors: [String]

    @State private var showAuthorPicker = false
    @State private var showDatePicker = false
    @State private var showPathsPicker = false
    @State private var pathsText = ""

    var body: some View {
        HStack(spacing: 6) {
            HStack(spacing: 4) {
                Image(systemName: "magnifyingglass")
                    .foregroundStyle(.secondary)
                    .font(.caption)
                TextField("Text or hash", text: $filter.text)
                    .textFieldStyle(.plain)
                    .font(.system(size: 12))
                if !filter.text.isEmpty {
                    Button { filter.text = "" } label: {
                        Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 6)
            .padding(.vertical, 3)
            .background(Color(NSColor.textBackgroundColor))
            .clipShape(RoundedRectangle(cornerRadius: 5))
            .frame(maxWidth: 180)

            filterButton("person", label: filter.author ?? "User", active: filter.author != nil) {
                showAuthorPicker.toggle()
            }
            .popover(isPresented: $showAuthorPicker, arrowEdge: .bottom) {
                AuthorPickerPopover(selected: $filter.author, authors: authors)
            }

            filterButton("calendar", label: dateLabel, active: filter.dateFrom != nil || filter.dateTo != nil) {
                showDatePicker.toggle()
            }
            .popover(isPresented: $showDatePicker, arrowEdge: .bottom) {
                DateRangePickerPopover(dateFrom: $filter.dateFrom, dateTo: $filter.dateTo)
            }

            filterButton("folder", label: pathsLabel, active: !filter.paths.isEmpty) {
                pathsText = filter.paths.joined(separator: "\n")
                showPathsPicker.toggle()
            }
            .popover(isPresented: $showPathsPicker, arrowEdge: .bottom) {
                PathsPickerPopover(pathsText: $pathsText) { newPaths in
                    filter.paths = newPaths
                }
            }

            Spacer(minLength: 0)

            Button {
                filter.sort = filter.sort == .newestFirst ? .oldestFirst : .newestFirst
            } label: {
                HStack(spacing: 3) {
                    Image(systemName: filter.sort == .newestFirst ? "arrow.down" : "arrow.up")
                        .font(.caption)
                    Text(filter.sort == .newestFirst ? "Newest" : "Oldest")
                        .font(.system(size: 11))
                }
                .foregroundStyle(.primary)
            }
            .buttonStyle(.plain)
            .padding(.horizontal, 6)
            .padding(.vertical, 3)
            .background(Color(NSColor.controlBackgroundColor))
            .clipShape(RoundedRectangle(cornerRadius: 5))
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
    }

    private var dateLabel: String {
        switch (filter.dateFrom, filter.dateTo) {
        case (let f?, let t?): return "\(f.formatted(.dateTime.month().day())) – \(t.formatted(.dateTime.month().day()))"
        case (let f?, nil): return "From \(f.formatted(.dateTime.month().day()))"
        case (nil, let t?): return "To \(t.formatted(.dateTime.month().day()))"
        default: return "Date"
        }
    }

    private var pathsLabel: String {
        filter.paths.isEmpty ? "Paths" : "\(filter.paths.count) path\(filter.paths.count == 1 ? "" : "s")"
    }

    private func filterButton(_ icon: String, label: String, active: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 3) {
                Image(systemName: icon).font(.caption)
                Text(label).font(.system(size: 11))
                Image(systemName: "chevron.down").font(.system(size: 8))
            }
            .foregroundStyle(active ? Color.accentColor : Color.primary)
        }
        .buttonStyle(.plain)
        .padding(.horizontal, 6)
        .padding(.vertical, 3)
        .background(active ? Color.accentColor.opacity(0.12) : Color(NSColor.controlBackgroundColor))
        .clipShape(RoundedRectangle(cornerRadius: 5))
    }
}

private struct AuthorPickerPopover: View {
    @Binding var selected: String?
    let authors: [String]
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if selected != nil {
                Button("Clear") { selected = nil; dismiss() }
                    .padding(8)
                Divider()
            }
            ForEach(authors as [String], id: \.self) { (author: String) in
                Button {
                    selected = author
                    dismiss()
                } label: {
                    HStack {
                        Text(author).font(.system(size: 12))
                        Spacer()
                        if selected == author {
                            Image(systemName: "checkmark").foregroundStyle(Color.accentColor)
                        }
                    }
                    .contentShape(Rectangle())
                    .padding(.horizontal, 12)
                    .padding(.vertical, 6)
                }
                .buttonStyle(.plain)
            }
            if authors.isEmpty {
                Text("No commits loaded").foregroundStyle(.secondary).font(.caption).padding(12)
            }
        }
        .frame(minWidth: 180)
        .padding(.vertical, 4)
    }
}

private struct DateRangePickerPopover: View {
    @Binding var dateFrom: Date?
    @Binding var dateTo: Date?
    @State private var from: Date = Calendar.current.date(byAdding: .month, value: -1, to: Date()) ?? Date()
    @State private var to: Date = Date()
    @State private var useFrom = false
    @State private var useTo = false
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Date Range").font(.headline).padding(.top, 8).padding(.horizontal, 12)
            Divider()
            Toggle("From", isOn: $useFrom)
                .padding(.horizontal, 12)
            if useFrom {
                DatePicker("", selection: $from, displayedComponents: .date)
                    .labelsHidden()
                    .padding(.horizontal, 12)
            }
            Toggle("To", isOn: $useTo)
                .padding(.horizontal, 12)
            if useTo {
                DatePicker("", selection: $to, displayedComponents: .date)
                    .labelsHidden()
                    .padding(.horizontal, 12)
            }
            Divider()
            HStack {
                Button("Clear") {
                    dateFrom = nil; dateTo = nil
                    dismiss()
                }
                Spacer()
                Button("Apply") {
                    dateFrom = useFrom ? from : nil
                    dateTo = useTo ? to : nil
                    dismiss()
                }
                .buttonStyle(.borderedProminent)
            }
            .padding(.horizontal, 12)
            .padding(.bottom, 8)
        }
        .frame(width: 240)
        .onAppear {
            useFrom = dateFrom != nil; useTo = dateTo != nil
            if let f = dateFrom { from = f }
            if let t = dateTo { to = t }
        }
    }
}

private struct PathsPickerPopover: View {
    @Binding var pathsText: String
    let onApply: ([String]) -> Void
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Paths Filter").font(.headline).padding(.top, 8).padding(.horizontal, 12)
            Text("One glob per line (e.g. src/**/*.swift)")
                .font(.caption)
                .foregroundStyle(.secondary)
                .padding(.horizontal, 12)
            TextEditor(text: $pathsText)
                .font(.system(size: 12, design: .monospaced))
                .frame(width: 240, height: 80)
                .padding(.horizontal, 8)
            Divider()
            HStack {
                Button("Clear") {
                    pathsText = ""
                    onApply([])
                    dismiss()
                }
                Spacer()
                Button("Apply") {
                    let paths = pathsText
                        .components(separatedBy: .newlines)
                        .map { $0.trimmingCharacters(in: .whitespaces) }
                        .filter { !$0.isEmpty }
                    onApply(paths)
                    dismiss()
                }
                .buttonStyle(.borderedProminent)
            }
            .padding(.horizontal, 12)
            .padding(.bottom, 8)
        }
    }
}
