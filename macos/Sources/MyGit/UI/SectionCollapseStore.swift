import SwiftUI

/// Remembers per-repo section expand/collapse state across launches, keyed by a
/// namespace (the tab) + repo id. Backed by UserDefaults; sections default to
/// expanded. Shared singleton so an "Expand/Collapse All" action bar and the
/// individual section headers stay in sync.
@MainActor
final class SectionCollapseStore: ObservableObject {
    static let shared = SectionCollapseStore()

    private let defaults = UserDefaults.standard

    private func key(_ ns: String, _ id: String) -> String { "MyGit.section.\(ns).\(id)" }

    func isExpanded(_ ns: String, _ id: String) -> Bool {
        defaults.object(forKey: key(ns, id)) as? Bool ?? true
    }

    func set(_ ns: String, _ id: String, _ value: Bool) {
        objectWillChange.send()
        defaults.set(value, forKey: key(ns, id))
    }

    func setAll(_ ns: String, _ ids: [String], _ value: Bool) {
        objectWillChange.send()
        for id in ids { defaults.set(value, forKey: key(ns, id)) }
    }

    /// A two-way binding for a single section, so headers persist on toggle.
    func binding(_ ns: String, _ id: String) -> Binding<Bool> {
        Binding(get: { self.isExpanded(ns, id) }, set: { self.set(ns, id, $0) })
    }
}

/// Expand-All / Collapse-All bar shown atop each multi-repo tab.
struct SectionActionBar: View {
    @ObservedObject private var store = SectionCollapseStore.shared
    let namespace: String
    let ids: [String]

    var body: some View {
        HStack(spacing: 2) {
            Spacer()
            Button { store.setAll(namespace, ids, true) } label: {
                Image(systemName: "rectangle.expand.vertical")
            }
            .help("Expand All")
            Button { store.setAll(namespace, ids, false) } label: {
                Image(systemName: "rectangle.compress.vertical")
            }
            .help("Collapse All")
        }
        .buttonStyle(.borderless)
        .foregroundStyle(.secondary)
        .font(.system(size: 13))
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
    }
}
