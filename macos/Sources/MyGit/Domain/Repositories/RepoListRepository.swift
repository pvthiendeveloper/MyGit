import Foundation
import Combine

@MainActor
protocol RepoListRepository: AnyObject {
    var repositories: [Repository] { get }
    var selected: Repository? { get }
    var repositoriesPublisher: AnyPublisher<[Repository], Never> { get }
    var selectedPublisher: AnyPublisher<Repository?, Never> { get }

    func reload()
    func add(_ url: URL)
    func remove(_ repo: Repository)
    func select(_ repo: Repository)
}
