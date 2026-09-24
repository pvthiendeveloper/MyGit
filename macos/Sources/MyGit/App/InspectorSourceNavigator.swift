import AppKit

/// Finds the code behind an inspected iOS view in the repos open in MyGit
/// and opens it in the editor. SwiftUI's debug data has no source locations,
/// so this goes by what it does carry: type names (→ their declarations)
/// and visible text (→ string literals).
@MainActor
protocol InspectorSourceNavigating: AnyObject {
    func declarations(ofType name: String) async -> [InspectorSourceHit]
    /// `literal` is searched as-is (quotes included by the caller).
    func occurrences(ofLiteral literal: String) async -> [InspectorSourceHit]
    func open(_ hit: InspectorSourceHit)
}

extension AppCoordinator: InspectorSourceNavigating {
    func declarations(ofType name: String) async -> [InspectorSourceHit] {
        guard let regex = Self.declarationRegex(for: name) else { return [] }
        var hits: [InspectorSourceHit] = []
        for bundle in bundles {
            let matches = (try? await container.git.searchSymbol(name, at: bundle.repo.url)) ?? []
            for m in matches where regex.firstMatch(in: m.preview, range: NSRange(m.preview.startIndex..., in: m.preview)) != nil {
                hits.append(InspectorSourceHit(repo: bundle.repo.url, repoName: bundle.name,
                                               path: m.path, line: m.line, preview: m.preview))
            }
        }
        // Real declarations before extensions; app code before tests.
        return hits.sorted {
            let a = ($0.preview.contains("extension "), $0.path.contains("Tests"))
            let b = ($1.preview.contains("extension "), $1.path.contains("Tests"))
            if a != b { return (a.0 ? 1 : 0) + (a.1 ? 1 : 0) < (b.0 ? 1 : 0) + (b.1 ? 1 : 0) }
            return $0.path < $1.path
        }
    }

    func occurrences(ofLiteral literal: String) async -> [InspectorSourceHit] {
        var hits: [InspectorSourceHit] = []
        for bundle in bundles {
            let matches = (try? await container.git.grep(query: literal, at: bundle.repo.url)) ?? []
            hits += matches.map {
                InspectorSourceHit(repo: bundle.repo.url, repoName: bundle.name,
                                   path: $0.path, line: $0.line, preview: $0.preview)
            }
        }
        return hits
    }

    /// Activate the hit's repo, switch to Files, open the file at the line,
    /// and bring the main window forward.
    func open(_ hit: InspectorSourceHit) {
        guard let bundle = bundles.first(where: { $0.repo.url == hit.repo }) else { return }
        setActive(bundle)
        main.tab = .files
        bundle.editor.reveal(path: hit.path, line: hit.line)
        if let window = NSApp.windows.first(where: { $0.title == "MyGit" }) {
            window.makeKeyAndOrderFront(nil)
        }
    }

    /// `struct Name` / `final class Name` / `extension Name` … as a declaration line.
    private static func declarationRegex(for name: String) -> NSRegularExpression? {
        let escaped = NSRegularExpression.escapedPattern(for: name)
        return try? NSRegularExpression(
            pattern: "(?:^|[^\\w.])(?:struct|class|enum|actor|protocol|typealias|extension)\\s+\(escaped)\\b"
        )
    }
}
