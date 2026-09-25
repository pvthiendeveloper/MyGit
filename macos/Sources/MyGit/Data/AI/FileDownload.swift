import Foundation
import CryptoKit

/// Streams a large file to `<destination>.part`, hashing as it goes, and
/// moves it into place once the SHA-256 matches. Resumes a leftover `.part`
/// with a `Range` request (re-hashing what's already there first).
final class FileDownload: NSObject, URLSessionDataDelegate, @unchecked Sendable {
    struct Progress: Sendable {
        let received: Int64
        let total: Int64
        /// Bytes per second over the last few seconds.
        let rate: Double
    }

    enum Failure: LocalizedError {
        case http(Int)
        case checksum
        case io(String)

        var errorDescription: String? {
            switch self {
            case .http(let code): return "Download failed (HTTP \(code))."
            case .checksum: return "The downloaded file is corrupt (checksum mismatch). Try again."
            case .io(let s): return s
            }
        }
    }

    private let url: URL
    private let destination: URL
    private let expectedSHA256: String?
    private let expectedSize: Int64
    private let onProgress: @Sendable (Progress) -> Void
    private let onFinish: @Sendable (Result<URL, Error>) -> Void

    private var session: URLSession?
    private var handle: FileHandle?
    private var hasher = SHA256()
    private var received: Int64 = 0
    private var total: Int64 = 0
    private var lastReport = Date.distantPast
    private var rateWindow: (date: Date, bytes: Int64) = (Date(), 0)
    private var rate: Double = 0
    private var failure: Error?
    private let queue = OperationQueue()

    private var partURL: URL { destination.appendingPathExtension("part") }

    init(url: URL, to destination: URL, sha256: String?, expectedSize: Int64,
         onProgress: @escaping @Sendable (Progress) -> Void,
         onFinish: @escaping @Sendable (Result<URL, Error>) -> Void) {
        self.url = url
        self.destination = destination
        self.expectedSHA256 = sha256?.lowercased()
        self.expectedSize = expectedSize
        self.onProgress = onProgress
        self.onFinish = onFinish
        queue.maxConcurrentOperationCount = 1
        super.init()
    }

    func start() {
        queue.addOperation { [self] in
            do {
                let fm = FileManager.default
                try fm.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
                if !fm.fileExists(atPath: partURL.path) { fm.createFile(atPath: partURL.path, contents: nil) }
                // Resume: hash what's already there.
                let existing = try FileHandle(forReadingFrom: partURL)
                while let chunk = try existing.read(upToCount: 8 << 20), !chunk.isEmpty {
                    hasher.update(data: chunk)
                    received += Int64(chunk.count)
                }
                try existing.close()
                handle = try FileHandle(forWritingTo: partURL)
                try handle?.seekToEnd()
            } catch {
                finish(.failure(Failure.io(error.localizedDescription)))
                return
            }
            var request = URLRequest(url: url)
            if received > 0 { request.setValue("bytes=\(received)-", forHTTPHeaderField: "Range") }
            let session = URLSession(configuration: .default, delegate: self, delegateQueue: queue)
            self.session = session
            rateWindow = (Date(), received)
            session.dataTask(with: request).resume()
        }
    }

    func cancel() {
        queue.addOperation { [self] in
            session?.invalidateAndCancel()
            session = nil
            try? handle?.close()
            handle = nil
        }
    }

    // MARK: URLSessionDataDelegate (on `queue`)

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse,
                    completionHandler: @escaping (URLSession.ResponseDisposition) -> Void) {
        let http = response as? HTTPURLResponse
        let code = http?.statusCode ?? 200
        if code == 200, received > 0 {
            // Server ignored the range: start over.
            do {
                try handle?.truncate(atOffset: 0)
                hasher = SHA256()
                received = 0
            } catch {
                failure = Failure.io(error.localizedDescription)
                completionHandler(.cancel)
                return
            }
        } else if code == 416 {
            // Already complete.
            completionHandler(.cancel)
            return
        } else if !(200..<300).contains(code) {
            failure = Failure.http(code)
            completionHandler(.cancel)
            return
        }
        let remaining = response.expectedContentLength
        total = remaining > 0 ? received + remaining : expectedSize
        completionHandler(.allow)
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        do {
            try handle?.write(contentsOf: data)
        } catch {
            failure = Failure.io(error.localizedDescription)
            dataTask.cancel()
            return
        }
        hasher.update(data: data)
        received += Int64(data.count)
        let now = Date()
        if now.timeIntervalSince(rateWindow.date) >= 2 {
            rate = Double(received - rateWindow.bytes) / now.timeIntervalSince(rateWindow.date)
            rateWindow = (now, received)
        }
        if now.timeIntervalSince(lastReport) > 0.25 {
            lastReport = now
            onProgress(Progress(received: received, total: max(total, expectedSize), rate: rate))
        }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        try? handle?.close()
        handle = nil
        session.finishTasksAndInvalidate()
        self.session = nil
        if let failure { return finish(.failure(failure)) }
        if let error {
            if (error as? URLError)?.code == .cancelled, received < expectedSize || expectedSize == 0 {
                return   // cancelled by the user: keep the .part for a resume
            }
            if (error as? URLError)?.code != .cancelled { return finish(.failure(error)) }
        }
        let digest = hasher.finalize().map { String(format: "%02x", $0) }.joined()
        if let expectedSHA256, digest != expectedSHA256 {
            try? FileManager.default.removeItem(at: partURL)
            return finish(.failure(Failure.checksum))
        }
        do {
            let fm = FileManager.default
            if fm.fileExists(atPath: destination.path) { try fm.removeItem(at: destination) }
            try fm.moveItem(at: partURL, to: destination)
            finish(.success(destination))
        } catch {
            finish(.failure(Failure.io(error.localizedDescription)))
        }
    }

    private func finish(_ result: Result<URL, Error>) {
        onFinish(result)
    }
}
