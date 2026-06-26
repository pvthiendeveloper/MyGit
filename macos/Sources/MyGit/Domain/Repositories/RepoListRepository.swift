import Foundation
import Combine

@MainActor
protocol RepoListRepository: AnyObject {
    var workspaces: [Workspace] { get }
    var selected: Workspace? { get }
    var workspacesPublisher: AnyPublisher<[Workspace], Never> { get }
    var selectedPublisher: AnyPublisher<Workspace?, Never> { get }

    func reload()
    /// Add a folder: scanned into a workspace (single repo or nested repos).
    func add(_ url: URL)
    func remove(_ workspace: Workspace)
    func select(_ workspace: Workspace)
}
