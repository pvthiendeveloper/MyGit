import Foundation

struct FileSystemFileEditorRepository: FileEditorRepository {
    func read(at repo: URL, path: String) throws -> Data {
        try Data(contentsOf: repo.appendingPathComponent(path))
    }

    func write(at repo: URL, path: String, content: String) throws {
        try content.write(
            to: repo.appendingPathComponent(path),
            atomically: true,
            encoding: .utf8
        )
    }
}
