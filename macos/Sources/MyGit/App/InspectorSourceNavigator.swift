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
    /// Open a repo-relative path at a line in whichever open repo has it.
    func open(relativePath: String, line: Int) -> Bool
    /// The source map "Run with Inspector" wrote for a repo-relative file.
    func sourceMapURL(forRelativePath path: String) -> URL?
    /// The property index of the repo holding a repo-relative file.
    func symbolIndexURL(forRelativePath path: String) -> URL?
    /// `<repo>/.mygit/inspect` of the repo holding a repo-relative file,
    /// when "Run with Inspector" has built it (mirror + index store).
    func inspectDirectory(forRelativePath path: String) -> URL?
    /// The original (untagged) file for a repo-relative path.
    func fileURL(forRelativePath path: String) -> URL?
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

    /// Repos to look in: the open workspace's (active first), then any other
    /// repo MyGit knows that has a "Run with Inspector" build — the app being
    /// inspected needn't be the repo on screen.
    private var inspectRoots: [URL] {
        let open = ([activeBundle] + bundles.filter { $0 !== activeBundle }).map(\.repo.url)
        let fm = FileManager.default
        let others = repos.workspaces.flatMap(\.repos).map(\.url)
            .filter { !open.contains($0) && fm.fileExists(atPath: $0.appendingPathComponent(".mygit/inspect/map").path) }
        return open + others
    }

    func sourceMapURL(forRelativePath path: String) -> URL? {
        inspectRoots.map { $0.appendingPathComponent(".mygit/inspect/map/\(path).json") }
            .first { FileManager.default.fileExists(atPath: $0.path) }
    }

    func inspectDirectory(forRelativePath path: String) -> URL? {
        let fm = FileManager.default
        for root in inspectRoots where fm.fileExists(atPath: root.appendingPathComponent(path).path) {
            let dir = root.appendingPathComponent(".mygit/inspect")
            return fm.fileExists(atPath: dir.appendingPathComponent("DerivedData/Index.noindex/DataStore").path) ? dir : nil
        }
        return nil
    }

    func symbolIndexURL(forRelativePath path: String) -> URL? {
        let fm = FileManager.default
        for root in inspectRoots where fm.fileExists(atPath: root.appendingPathComponent(path).path) {
            let url = root.appendingPathComponent(".mygit/inspect/map/_symbols.json")
            return fm.fileExists(atPath: url.path) ? url : nil
        }
        return nil
    }

    func fileURL(forRelativePath path: String) -> URL? {
        inspectRoots.map { $0.appendingPathComponent(path) }.first { FileManager.default.fileExists(atPath: $0.path) }
    }

    func open(relativePath: String, line: Int) -> Bool {
        let fm = FileManager.default
        // The active repo first: a workspace may hold several with the same layout.
        let ordered = [activeBundle] + bundles.filter { $0 !== activeBundle }
        guard let bundle = ordered.first(where: {
            fm.fileExists(atPath: $0.repo.url.appendingPathComponent(relativePath).path)
        }) else { return false }
        open(InspectorSourceHit(repo: bundle.repo.url, repoName: bundle.name, path: relativePath, line: line, preview: ""))
        return true
    }

    /// `struct Name` / `final class Name` / `extension Name` … as a declaration line.
    private static func declarationRegex(for name: String) -> NSRegularExpression? {
        let escaped = NSRegularExpression.escapedPattern(for: name)
        return try? NSRegularExpression(
            pattern: "(?:^|[^\\w.])(?:struct|class|enum|actor|protocol|typealias|extension)\\s+\(escaped)\\b"
        )
    }
}
