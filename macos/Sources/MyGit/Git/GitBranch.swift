import Foundation

struct GitBranch: Identifiable, Hashable {
    let fullRef: String
    let name: String
    let isRemote: Bool
    let upstream: String?
    let isCurrent: Bool

    var id: String { fullRef }

    var group: String? {
        guard name.contains("/") else { return nil }
        return String(name.split(separator: "/").first!)
    }

    var leaf: String {
        guard let g = group else { return name }
        return String(name.dropFirst(g.count + 1))
    }

    /// Branch to land on when checking out. For remote-tracking refs
    /// (`origin/feature/x`) strip the remote prefix so git DWIM-creates or
    /// switches to the local tracking branch instead of detaching HEAD.
    var checkoutName: String {
        guard isRemote else { return name }
        let parts = name.split(separator: "/", maxSplits: 1, omittingEmptySubsequences: false)
        return parts.count == 2 ? String(parts[1]) : name
    }
}

enum GitBranchParser {
    // Format: %(refname)%00%(upstream:short)%00%(HEAD)
    static func parse(_ output: String, currentBranch: String?) -> [GitBranch] {
        output.split(separator: "\n", omittingEmptySubsequences: true).compactMap { line in
            let parts = line.split(separator: "\0", omittingEmptySubsequences: false).map(String.init)
            guard parts.count >= 3 else { return nil }
            let fullRef = parts[0]
            let upstreamRaw = parts[1]
            let headMarker = parts[2]

            let isRemote = fullRef.hasPrefix("refs/remotes/")
            let name: String
            if isRemote {
                name = String(fullRef.dropFirst("refs/remotes/".count))
            } else {
                name = String(fullRef.dropFirst("refs/heads/".count))
            }
            let upstream = upstreamRaw.isEmpty ? nil : upstreamRaw
            let isCurrent = headMarker == "*" || name == currentBranch

            return GitBranch(
                fullRef: fullRef,
                name: name,
                isRemote: isRemote,
                upstream: upstream,
                isCurrent: isCurrent
            )
        }
    }
}
