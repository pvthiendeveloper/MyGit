import Foundation

/// Filter/scoping state for the commit-graph history view. Translated into
/// `git log` flags by `GitCLIRepository.graphLog`.
struct HistoryFilter: Equatable {
    enum Scope: Equatable {
        case all                 // --all (every branch)
        case ref(String)         // a single branch/tag/rev
    }
    enum Sort: Equatable {
        case topo                // --topo-order
        case date                // --date-order
    }

    var searchText: String = ""
    var useRegex: Bool = false
    var caseSensitive: Bool = false
    var author: String? = nil
    var since: String? = nil     // git date expr, e.g. "2024-01-01", "1 week ago"
    var until: String? = nil
    var paths: [String] = []
    var branchScope: Scope = .all
    var sort: Sort = .topo
}
