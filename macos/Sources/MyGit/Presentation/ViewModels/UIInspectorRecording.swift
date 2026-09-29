import AppKit
import AVFoundation

/// Record the inspected app's screen to a movie, like Simulator's
/// File ▸ Record Screen. A simulator records through `simctl io recordVideo`
/// (every frame, the whole screen); a device has no such tool, so its frames
/// come from the agent, as fast as it renders them, at the screen's scale.
@MainActor
final class InspectorScreenRecorder {
    let started = Date()
    let url: URL
    let isSimulator: Bool
    private var process: Process?
    private var frameTask: Task<Void, Never>?
    private var writer: FrameMovieWriter?

    private init(url: URL, isSimulator: Bool) {
        self.url = url
        self.isSimulator = isSimulator
    }

    static func simulator(udid: String, to url: URL) throws -> InspectorScreenRecorder {
        let recorder = InspectorScreenRecorder(url: url, isSimulator: true)
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/usr/bin/xcrun")
        proc.arguments = ["simctl", "io", udid, "recordVideo", "--codec=h264", "--force", url.path]
        proc.standardOutput = FileHandle.nullDevice
        proc.standardError = FileHandle.nullDevice
        try proc.run()
        recorder.process = proc
        return recorder
    }

    /// `frame` fetches the screen as it is now.
    static func frames(to url: URL, frame: @escaping () async -> NSImage?) -> InspectorScreenRecorder {
        let recorder = InspectorScreenRecorder(url: url, isSimulator: false)
        recorder.frameTask = Task { [weak recorder] in
            while !Task.isCancelled {
                guard let image = await frame(),
                      let cg = image.cgImage(forProposedRect: nil, context: nil, hints: nil),
                      let recorder, !Task.isCancelled else {
                    try? await Task.sleep(nanoseconds: 50_000_000)
                    continue
                }
                if recorder.writer == nil { recorder.writer = FrameMovieWriter(url: url, width: cg.width, height: cg.height) }
                recorder.writer?.append(cg, at: Date().timeIntervalSince(recorder.started))
            }
        }
        return recorder
    }

    /// Stops and returns the finished movie, or nil when nothing was recorded.
    func stop() async -> URL? {
        if let process {
            process.interrupt()   // simctl finishes the file on SIGINT.
            for _ in 0..<200 where process.isRunning { try? await Task.sleep(nanoseconds: 50_000_000) }
            return FileManager.default.fileExists(atPath: url.path) ? url : nil
        }
        frameTask?.cancel()
        guard let writer else { return nil }
        return await writer.finish(at: Date().timeIntervalSince(started)) ? url : nil
    }
}

/// H.264 `.mov` from frames that arrive at their own pace (variable frame rate).
private final class FrameMovieWriter {
    private let writer: AVAssetWriter
    private let input: AVAssetWriterInput
    private let adaptor: AVAssetWriterInputPixelBufferAdaptor
    private let width: Int, height: Int
    private var last: (image: CGImage, time: Double)?

    init?(url: URL, width: Int, height: Int) {
        // H.264 wants even dimensions.
        self.width = width & ~1
        self.height = height & ~1
        guard self.width > 0, self.height > 0,
              let writer = try? AVAssetWriter(outputURL: url, fileType: .mov) else { return nil }
        input = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: AVVideoCodecType.h264,
            AVVideoWidthKey: self.width,
            AVVideoHeightKey: self.height,
        ])
        input.expectsMediaDataInRealTime = true
        adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input, sourcePixelBufferAttributes: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            kCVPixelBufferWidthKey as String: self.width,
            kCVPixelBufferHeightKey as String: self.height,
        ])
        guard writer.canAdd(input) else { return nil }
        writer.add(input)
        guard writer.startWriting() else { return nil }
        writer.startSession(atSourceTime: .zero)
        self.writer = writer
    }

    func append(_ image: CGImage, at seconds: Double) {
        // The first frame opens the movie; times must only go forward.
        let time = last == nil ? 0 : seconds
        if let last, time <= last.time { return }
        guard input.isReadyForMoreMediaData, let pool = adaptor.pixelBufferPool else { return }
        var buffer: CVPixelBuffer?
        CVPixelBufferPoolCreatePixelBuffer(nil, pool, &buffer)
        guard let buffer else { return }
        CVPixelBufferLockBaseAddress(buffer, [])
        defer { CVPixelBufferUnlockBaseAddress(buffer, []) }
        guard let context = CGContext(
            data: CVPixelBufferGetBaseAddress(buffer), width: width, height: height, bitsPerComponent: 8,
            bytesPerRow: CVPixelBufferGetBytesPerRow(buffer), space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue
        ) else { return }
        context.interpolationQuality = .high
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        if adaptor.append(buffer, withPresentationTime: CMTime(seconds: time, preferredTimescale: 600)) {
            last = (image, time)
        }
    }

    /// Holds the last frame until `seconds`, so the movie lasts as long as the recording.
    func finish(at seconds: Double) async -> Bool {
        guard let last else { writer.cancelWriting(); return false }
        append(last.image, at: seconds)
        input.markAsFinished()
        await writer.finishWriting()
        return writer.status == .completed
    }
}

extension UIInspectorViewModel {
    func toggleRecording() {
        if let recorder {
            self.recorder = nil
            recordingSaving = true
            Task { @MainActor [weak self] in
                let movie = await recorder.stop()
                self?.recordingSaving = false
                guard let self, let movie else {
                    self?.errorMessage = "The recording is empty."
                    return
                }
                saveRecording(movie)
            }
            return
        }
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("MyGit Recording \(UUID().uuidString).mov")
        Task { @MainActor [weak self] in
            guard let self else { return }
            if snapshot?.info?.simulator == true,
               let udid = await Self.bootedSimulator(named: snapshot?.info?.device) {
                do { recorder = try .simulator(udid: udid, to: url) } catch { errorMessage = error.localizedDescription }
            } else {
                let scale = Double(nativeScale)
                recorder = .frames(to: url) { [weak self] in await self?.sharpFrame(scale: scale, quality: 0.8) }
            }
        }
    }

    private func saveRecording(_ movie: URL) {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.quickTimeMovie]
        panel.nameFieldStringValue = "\(snapshot?.info?.appName ?? "Recording") \(Self.fileDate()).mov"
        guard panel.runModal() == .OK, let target = panel.url else {
            try? FileManager.default.removeItem(at: movie)
            return
        }
        try? FileManager.default.removeItem(at: target)
        do { try FileManager.default.moveItem(at: movie, to: target) } catch { errorMessage = error.localizedDescription }
    }

    /// The booted simulator the app runs on: by name, or the only booted one.
    private static func bootedSimulator(named name: String?) async -> String? {
        let listed = await ProcessRunner.run("/usr/bin/xcrun", ["simctl", "list", "devices", "booted", "-j"])
        guard let data = listed.stdout.data(using: .utf8),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let byRuntime = root["devices"] as? [String: [[String: Any]]] else { return nil }
        let booted = byRuntime.values.flatMap { $0 }.filter { ($0["state"] as? String) == "Booted" }
        let match = booted.filter { ($0["name"] as? String) == name }
        return ((match.count == 1 ? match : booted.count == 1 ? booted : []).first)?["udid"] as? String
    }
}
