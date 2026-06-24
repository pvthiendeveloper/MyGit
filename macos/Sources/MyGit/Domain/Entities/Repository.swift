import Foundation

struct Repository: Identifiable, Hashable {
    var id: URL { url }
    let url: URL
    var name: String { url.lastPathComponent }
}
