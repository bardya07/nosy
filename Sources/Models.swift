import Foundation

enum SpeechModel {
    static let remoteURL = URL(string: "https://huggingface.co/ggerganov/whisper.cpp/resolve/main/ggml-large-v3-turbo.bin")!
    static let expectedBytes: Int64 = 1_624_555_275
    static let vadURL = URL(string: "https://huggingface.co/ggml-org/whisper-vad/resolve/main/ggml-silero-v5.1.2.bin")!

    static func validate(_ url: URL) -> Bool { validate(url, minimumBytes: 100_000_000) }

    // The on-disk UInt32 magic is little endian: 6c 6d 67 67 ("lmgg").
    // Read only the header, even for the 1.6 GB model. Tests can lower the size floor.
    static func validate(_ url: URL, minimumBytes: Int64) -> Bool {
        guard Core.fileSize(url) >= max(4, minimumBytes),
              let file = try? FileHandle(forReadingFrom: url) else { return false }
        defer { try? file.close() }
        return (try? file.read(upToCount: 4)) == Data([0x6c, 0x6d, 0x67, 0x67])
    }

    static func install(from url: URL, paths: AppPaths) throws {
        try install(from: url, paths: paths, minimumBytes: 100_000_000)
    }

    static func install(from url: URL, paths: AppPaths, minimumBytes: Int64) throws {
        guard validate(url, minimumBytes: minimumBytes) else {
            throw LectureError.message("This is not a valid speech model. Choose the speech model file.")
        }
        try place(url, at: paths.model, copy: true, minimumBytes: minimumBytes)
    }

    fileprivate static func place(_ source: URL, at target: URL, copy: Bool, minimumBytes: Int64? = nil) throws {
        let manager = FileManager.default
        try manager.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
        let temporary = target.deletingLastPathComponent().appendingPathComponent(".\(UUID().uuidString).download")
        defer { try? manager.removeItem(at: temporary) }
        if copy { try copyInChunks(from: source, to: temporary) }
        else { try manager.moveItem(at: source, to: temporary) }
        if let minimumBytes, !validate(temporary, minimumBytes: minimumBytes) {
            throw LectureError.message("The downloaded speech model is invalid or incomplete. Please try again.")
        }
        // A cancelled copy never reaches the final name; the defer above removes the temporary file.
        try Task.checkCancellation()
        let file = try FileHandle(forReadingFrom: temporary)
        defer { try? file.close() }
        try file.synchronize()
        try file.close()
        try Task.checkCancellation()
        let result = temporary.path.withCString { from in target.path.withCString { to in rename(from, to) } }
        guard result == 0 else { throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno)) }
    }

    // A bounded copy loop, so Cancel can stop a multi-gigabyte copy between chunks.
    private static func copyInChunks(from source: URL, to destination: URL) throws {
        guard FileManager.default.createFile(atPath: destination.path, contents: nil) else {
            throw CocoaError(.fileWriteUnknown)
        }
        let input = try FileHandle(forReadingFrom: source)
        defer { try? input.close() }
        let output = try FileHandle(forWritingTo: destination)
        defer { try? output.close() }
        while true {
            try Task.checkCancellation()
            let block = try input.read(upToCount: 1_048_576) ?? Data()
            if block.isEmpty { break }
            try output.write(contentsOf: block)
        }
        try output.synchronize()
    }
}

// All mutable state (including delegate callbacks) lives on control. URLSession's
// serial delegate queue uses that same queue; callers can start/cancel from any actor.
final class ModelDownload: NSObject, URLSessionDownloadDelegate, @unchecked Sendable {
    private let paths: AppPaths
    private let control = DispatchQueue(label: "com.bardya.nosy.model-download")
    private var session: URLSession?
    private var task: URLSessionDownloadTask?
    private var resumeData: Data?
    private var progress: (@Sendable (Double, Int64, Int64) -> Void)?
    private var completion: (@Sendable (Result<Void, Error>) -> Void)?
    private var mainInstalled = false
    private var cancelling = false
    private var waiters: [CheckedContinuation<Void, Never>] = []
    private var finishing: Result<Void, Error>?

    init(paths: AppPaths) {
        self.paths = paths
        super.init()
    }

    func start(progress: @escaping @Sendable (_ fraction: Double, _ received: Int64, _ total: Int64) -> Void,
               completion: @escaping @Sendable (Result<Void, Error>) -> Void) {
        control.async {
            guard self.session == nil else {
                completion(.failure(LectureError.message("A speech model download is already running.")))
                return
            }
            self.progress = progress
            self.completion = completion
            self.mainInstalled = false
            self.cancelling = false
            let queue = OperationQueue()
            queue.maxConcurrentOperationCount = 1
            queue.underlyingQueue = self.control
            let session = URLSession(configuration: .default, delegate: self, delegateQueue: queue)
            self.session = session
            let task = self.resumeData.map { session.downloadTask(withResumeData: $0) }
                ?? session.downloadTask(with: SpeechModel.remoteURL)
            self.resumeData = nil
            self.task = task
            task.resume()
        }
    }

    func cancel() {
        control.async { self.beginCancel() }
    }

    // Returns once the active transfer has stopped and its session is gone. Idle downloads return at once.
    func cancelAndWait() async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            control.async {
                guard self.session != nil else {
                    continuation.resume()
                    return
                }
                self.waiters.append(continuation)
                self.beginCancel()
            }
        }
    }

    private func beginCancel() {
        guard let task = self.task, !self.cancelling else { return }
        self.cancelling = true
        task.cancel { data in
            self.control.async {
                guard self.task === task else { return }
                if !self.mainInstalled, let data { self.resumeData = data }
                // Wait for resume data before delivering completion so a start from
                // the completion callback can immediately resume the previous task.
                self.finish(self.mainInstalled ? .success(()) : .failure(CancellationError()))
            }
        }
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask,
                    didWriteData bytesWritten: Int64, totalBytesWritten: Int64, totalBytesExpectedToWrite: Int64) {
        guard task === downloadTask, !mainInstalled, !cancelling else { return }
        let total = totalBytesExpectedToWrite > 0 ? totalBytesExpectedToWrite : SpeechModel.expectedBytes
        progress?(min(1, max(0, Double(totalBytesWritten) / Double(total))), totalBytesWritten, total)
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {
        guard task === downloadTask, !cancelling else { return }
        do {
            guard let response = downloadTask.response as? HTTPURLResponse, (200...299).contains(response.statusCode) else {
                throw LectureError.message("The model server could not complete the download. Please try again.")
            }
            if mainInstalled {
                guard Core.fileSize(location) > 0 else { throw LectureError.message("The voice activity model download was empty.") }
                try SpeechModel.place(location, at: paths.vadModel, copy: false)
                finish(.success(()))
            } else {
                try SpeechModel.place(location, at: paths.model, copy: false, minimumBytes: 100_000_000)
                mainInstalled = true
                resumeData = nil
                progress?(1, Core.fileSize(paths.model), Core.fileSize(paths.model))
                if FileManager.default.isReadableFile(atPath: paths.vadModel.path), Core.fileSize(paths.vadModel) > 0 {
                    finish(.success(()))
                } else {
                    let vadTask = session.downloadTask(with: SpeechModel.vadURL)
                    task = vadTask
                    vadTask.resume()
                }
            }
        } catch {
            finish(mainInstalled ? .success(()) : .failure(error))
        }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        guard self.task === task, let error else { return }
        if !mainInstalled, let data = (error as NSError).userInfo[NSURLSessionDownloadTaskResumeData] as? Data {
            resumeData = data
        }
        guard !cancelling else { return } // cancel's resume-data callback completes this run.
        finish(mainInstalled ? .success(()) : .failure(error))
    }

    private func finish(_ result: Result<Void, Error>) {
        guard finishing == nil else { return }
        finishing = result
        progress = nil
        task = nil
        // URLSession retains its delegate until invalidation finishes. Quit and setup's busy state
        // wait for that callback, rather than only for the request to invalidate the session.
        session?.finishTasksAndInvalidate()
    }

    func urlSession(_ session: URLSession, didBecomeInvalidWithError error: Error?) {
        guard self.session === session, let result = finishing else { return }
        self.session = nil
        finishing = nil
        let callback = completion
        completion = nil
        callback?(result)
        let finished = waiters
        waiters = []
        finished.forEach { $0.resume() }
    }
}
