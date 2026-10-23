import Darwin
import Foundation

final class TranscriptionJob: @unchecked Sendable {
    private let lock = NSLock()
    private var process: Process?
    private var cancelled = false
    private var suspended = false

    func launch(_ process: Process) throws {
        lock.lock(); defer { lock.unlock() }
        guard !cancelled else { throw CancellationError() }
        self.process = process
        try process.run()
        if suspended { kill(process.processIdentifier, SIGSTOP) }
    }
    func suspend() {
        lock.lock(); defer { lock.unlock() }
        guard !cancelled, !suspended else { return }
        suspended = true
        if let process, process.isRunning { kill(process.processIdentifier, SIGSTOP) }
    }
    func resume() {
        lock.lock(); defer { lock.unlock() }
        guard !cancelled, suspended else { return }
        suspended = false
        if let process, process.isRunning { kill(process.processIdentifier, SIGCONT) }
    }
    func cancel() {
        lock.lock(); defer { lock.unlock() }
        cancelled = true
        if let process, process.isRunning {
            // A stopped child cannot handle termination until it is continued.
            kill(process.processIdentifier, SIGCONT)
            process.terminate()
        }
    }
    func checkCancellation() throws {
        lock.lock(); defer { lock.unlock() }
        if cancelled { throw CancellationError() }
    }
}

enum Transcriber {
    static var threadCount: Int {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/sbin/sysctl")
        process.arguments = ["-n", "hw.perflevel0.physicalcpu"]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            if process.terminationStatus == 0, let count = Int(String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)) {
                return max(4, count)
            }
        } catch { }
        return max(4, ProcessInfo.processInfo.activeProcessorCount)
    }
    static func arguments(paths: AppPaths, wav: URL, temporaryBase: URL, lecture: String) -> [String] {
        var args = ["-m", paths.model.path, "-f", wav.path, "-l", "en", "-otxt", "-of", temporaryBase.path, "-np", "-pp", "-t", String(threadCount),
                    "-mc", "0"]
        let vocab = paths.lectureFolder(lecture).appendingPathComponent("vocab.txt")
        if let text = try? String(contentsOf: vocab, encoding: .utf8),
           let prompt = Vocabulary.prompt(text, model: paths.model) {
            // N static tokens + the previous-token marker leave no room for decoded history.
            // whisper.cpp omits prompts at fallback temperatures >= 0.5 and in its short tail.
            args[args.count - 1] = String(prompt.tokens + 1)
            args += ["--prompt", prompt.text, "--carry-initial-prompt"]
        }
        if FileManager.default.fileExists(atPath: paths.vadModel.path) { args += ["--vad", "-vm", paths.vadModel.path] }
        return args
    }
    static func transcribe(record: SessionRecord, paths: AppPaths, job: TranscriptionJob = TranscriptionJob(),
                           progress: @escaping @Sendable (Double) -> Void = { _ in }) async throws -> SessionRecord {
        try await Task.detached(priority: .utility) {
            try await run(record: record, paths: paths, job: job, progress: progress)
        }.value
    }
    private static func readStderr(_ input: FileHandle, log: FileHandle,
                                   progress: @Sendable (Double) -> Void) throws {
        defer { try? input.close() }
        var pending = ""
        while true {
            // On macOS read(upToCount:) may wait to fill the requested count.
            // availableData blocks only until some bytes arrive, so progress stays live.
            let data = input.availableData
            if data.isEmpty { break }
            try log.write(contentsOf: data)
            pending += String(decoding: data, as: UTF8.self)
            // Pipe reads can split a percentage anywhere, including immediately before '%'.
            while let end = pending.firstIndex(where: { $0.isNewline }) {
                let line = String(pending[..<end])
                pending.removeSubrange(...end)
                if let value = Core.parseProgress(line) { progress(value) }
            }
            if pending.count > 8192 { pending = String(pending.suffix(8192)) }
        }
        if let value = Core.parseProgress(pending) { progress(value) }
    }
    private static func run(record: SessionRecord, paths: AppPaths, job: TranscriptionJob,
                            progress: @escaping @Sendable (Double) -> Void) async throws -> SessionRecord {
        var record = record
        do {
            try job.checkCancellation()
            progress(0)
            record.status = .transcribing
            record.error = nil
            record.endedAt = record.endedAt ?? Date()
            try record.save(in: paths)
            let wav = try AudioFiles.decodeToWAV(id: record.id, paths: paths)
            if let warning = paths.dependencyWarning { throw LectureError.message(warning) }
            guard let executable = paths.whisper else { throw LectureError.message("whisper-cli is missing. Audio is kept; install whisper.cpp and Retry.") }
            let base = paths.audio.appendingPathComponent(".whisper-\(record.id)-\(UUID().uuidString)")
            let stderrURL = base.appendingPathExtension("stderr")
            let textURL = base.appendingPathExtension("txt")
            let louderURL = base.appendingPathExtension("wav")
            defer {
                try? FileManager.default.removeItem(at: stderrURL)
                try? FileManager.default.removeItem(at: textURL)
                try? FileManager.default.removeItem(at: louderURL)
            }
            let input = (try? AudioFiles.boosted(wav, to: louderURL)) ?? wav
            guard FileManager.default.createFile(atPath: stderrURL.path, contents: nil) else {
                throw LectureError.message("Could not create transcription log file.")
            }
            let stderrFile = try FileHandle(forWritingTo: stderrURL)
            defer { try? stderrFile.close() }
            let process = Process()
            process.qualityOfService = .utility
            process.executableURL = executable
            process.arguments = arguments(paths: paths, wav: input, temporaryBase: base, lecture: record.lecture)
            process.standardOutput = FileHandle.nullDevice
            let stderrPipe = Pipe()
            defer {
                try? stderrPipe.fileHandleForWriting.close()
                try? stderrPipe.fileHandleForReading.close()
            }
            process.standardError = stderrPipe
            try job.launch(process)
            // Close our writer so the reader sees EOF when the child exits.
            try? stderrPipe.fileHandleForWriting.close()
            let stderrReader = Task.detached(priority: .utility) {
                try readStderr(stderrPipe.fileHandleForReading, log: stderrFile, progress: progress)
            }
            process.waitUntilExit()
            try await stderrReader.value
            try job.checkCancellation()
            guard process.terminationStatus == 0 else {
                let tail = try FileHandle(forReadingFrom: stderrURL)
                defer { try? tail.close() }
                let length = try tail.seekToEnd()
                try tail.seek(toOffset: length > 1200 ? length - 1200 : 0)
                let detail = String(decoding: try tail.readToEnd() ?? Data(), as: UTF8.self)
                throw LectureError.message("whisper-cli exited \(process.terminationStatus): \(String(detail.trimmingCharacters(in: .whitespacesAndNewlines).suffix(300)))")
            }
            let text = try String(contentsOf: textURL, encoding: .utf8)
            let markdown = Core.markdown(record: record, duration: Core.audioDuration(id: record.id, paths: paths), text: text)
            try job.checkCancellation()
            let target = try Core.writeTranscript(markdown, folder: paths.lectureFolder(record.lecture), session: record.session)
            record.transcriptPath = target.path
            record.status = .done
            record.transcribedAt = Date()
            try record.save(in: paths)
            if UserDefaults.standard.object(forKey: "compressAudio") as? Bool ?? true {
                try? AudioFiles.compress(id: record.id, paths: paths)
            }
            try? Core.applyRetention(paths: paths)
            progress(1)
            return record
        } catch {
            if !(error is CancellationError) {
                record.status = .failed
                record.error = error.localizedDescription
                try? record.save(in: paths)
            }
            throw error
        }
    }
}
