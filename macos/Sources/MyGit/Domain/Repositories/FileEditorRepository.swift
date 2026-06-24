import Foundation

protocol FileEditorRepository: Sendable {
    func read(at repo: URL, path: String) throws -> Data
    func write(at repo: URL, path: String, content: String) throws
}
