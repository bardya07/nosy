import Foundation

enum SpeechModel {
    static let remoteURL = URL(string: "https://huggingface.co/ggerganov/whisper.cpp/resolve/5359861c739e955e79d9a303bcbc70fb988958b1/ggml-large-v3-turbo.bin")!
    static let expectedBytes: Int64 = 1_624_555_275
    static let checksum = "1fc70f774d38eb169993ac391eea357ef47c88757ef72ee5943879b7e8e2bc69"
    static let vadURL = URL(string: "https://huggingface.co/ggml-org/whisper-vad/resolve/9ffd54a1e1ee413ddf265af9913beaf518d1639b/ggml-silero-v5.1.2.bin")!
    static let vadBytes: Int64 = 885_098
    static let vadChecksum = "29940d98d42b91fbd05ce489f3ecf7c72f0a42f027e4875919a28fb4c04ea2cf"

    static func validate(_ url: URL) -> Bool {
        verified(url, bytes: expectedBytes, checksum: checksum)
    }
    static func validateVAD(_ url: URL) -> Bool {
        verified(url, bytes: vadBytes, checksum: vadChecksum)
    }
    private final class VerificationCache: @unchecked Sendable {
        let lock = NSLock()
        var entries: [String: (String, Bool)] = [:]
    }
    private static let verificationCache = VerificationCache()
    static func verified(_ url: URL, bytes: Int64, checksum: String) -> Bool {
        let target = url.resolvingSymlinksInPath().standardizedFileURL
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: target.path),
              let size = attributes[.size] as? NSNumber, size.int64Value == bytes,
              let modified = attributes[.modificationDate] as? Date,
              let inode = attributes[.systemFileNumber] as? NSNumber else { return false }
        let identity = "\(inode)-\(modified.timeIntervalSince1970)-\(bytes)-\(checksum)"
        verificationCache.lock.lock()
        defer { verificationCache.lock.unlock() }
        if let cached = verificationCache.entries[target.path], cached.0 == identity { return cached.1 }
        let valid = (try? LocalModelDownload.sha256(target)) == checksum
        // Never cache a result for a file changed while it was being read.
        if let after = try? FileManager.default.attributesOfItem(atPath: target.path),
           (after[.modificationDate] as? Date) == modified,
           (after[.systemFileNumber] as? NSNumber) == inode,
           (after[.size] as? NSNumber)?.int64Value == bytes {
            verificationCache.entries[target.path] = (identity, valid)
            return valid
        }
        return false
    }
    static func install(from url: URL, paths: AppPaths) throws {
        try place(url, at: paths.model, paths: paths, copy: true, vad: false)
    }
    fileprivate static func place(_ source: URL, at target: URL, paths: AppPaths, copy: Bool, vad: Bool) throws {
        let manager = FileManager.default
        try manager.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true,
                                    attributes: [.posixPermissions: 0o700])
        guard paths.safeSupportItem(target.deletingLastPathComponent(), directory: true) else { throw LectureError.message("Unsafe model storage.") }
        let temporary = target.deletingLastPathComponent().appendingPathComponent(".\(UUID().uuidString).download")
        defer { try? paths.removeSupportFile(temporary) }
        if copy { try copyInChunks(from: source, to: temporary) }
        else { try manager.moveItem(at: source, to: temporary) }
        guard vad ? validateVAD(temporary) : validate(temporary) else {
            throw LectureError.message("Model verification failed. Choose or download the correct model again.")
        }
        guard paths.safeSupportItem(temporary, directory: false) else { throw LectureError.message("Unsafe model file.") }
        try manager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: temporary.path)
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
        guard FileManager.default.createFile(atPath: destination.path, contents: nil, attributes: [.posixPermissions: 0o600]) else {
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
                try SpeechModel.place(location, at: paths.vadModel, paths: paths, copy: false, vad: true)
                finish(.success(()))
            } else {
                try SpeechModel.place(location, at: paths.model, paths: paths, copy: false, vad: false)
                mainInstalled = true
                resumeData = nil
                progress?(1, Core.fileSize(paths.model), Core.fileSize(paths.model))
                if SpeechModel.validateVAD(paths.vadModel) {
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

// The optional encoder is installed only after the complete archive is verified and unpacked.
enum CoreMLEncoderDownload {
    static func install(paths: AppPaths, job: TranscriptionJob) async throws {
        let manager = FileManager.default
        let folder = paths.model.deletingLastPathComponent()
        let name = "ggml-large-v3-turbo-encoder.mlmodelc"
        let target = folder.appendingPathComponent(name, isDirectory: true)
        guard !manager.fileExists(atPath: target.path) else { return }
        let partial = folder.appendingPathComponent(".coreml-encoder.zip.partial")
        let url = URL(string: "https://huggingface.co/ggerganov/whisper.cpp/resolve/87cd18b47b941d2f65d09981dad23bb7d0481c77/ggml-large-v3-turbo-encoder.mlmodelc.zip")!
        try await LocalModelDownload.transfer(url: url, partial: partial, expectedBytes: 1_173_393_014,
            checksum: "84bedfe895bd7b5de6e8e89a0803dfc5addf8c0c5bc4c937451716bf7cf7988a", job: job, paths: paths)
        try await withTaskCancellationHandler {
            try await Task.detached(priority: .utility) {
                let manager = FileManager.default
                let temporary = folder.appendingPathComponent(".coreml-encoder-\(UUID().uuidString)", isDirectory: true)
                try manager.createDirectory(at: temporary, withIntermediateDirectories: true)
                defer { if paths.safeSupportItem(temporary, directory: true) { try? manager.removeItem(at: temporary) } }
                let process = Process()
                process.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
                process.arguments = ["-x", "-k", partial.path, temporary.path]
                process.standardOutput = FileHandle.nullDevice
                process.standardError = FileHandle.nullDevice
                try job.launch(process)
                process.waitUntilExit()
                try job.checkCancellation()
                guard process.terminationStatus == 0 else { throw LectureError.message("Could not unpack the Core ML encoder.") }
                let unpacked = temporary.appendingPathComponent(name, isDirectory: true)
                var directory: ObjCBool = false
                guard manager.fileExists(atPath: unpacked.path, isDirectory: &directory), directory.boolValue else {
                    throw LectureError.message("The Core ML encoder archive is incomplete.")
                }
                try job.checkCancellation()
                // Never replace an existing encoder; the directory becomes visible in one move.
                try manager.moveItem(at: unpacked, to: target)
                try? paths.removeSupportFile(partial)
            }.value
        } onCancel: { job.cancel() }
    }
}
