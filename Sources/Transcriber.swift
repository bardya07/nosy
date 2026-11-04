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
            // A CLI may ignore SIGTERM. Quit and timeout must still settle, even when paused.
            DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 2) { [self, process] in
                lock.lock(); defer { lock.unlock() }
                if self.process === process, process.isRunning { kill(process.processIdentifier, SIGKILL) }
            }
        }
    }
    func checkCancellation() throws {
        lock.lock(); defer { lock.unlock() }
        if cancelled { throw CancellationError() }
    }
}

enum Transcriber {
    static var threadCount: Int {
        let available = max(1, ProcessInfo.processInfo.activeProcessorCount)
        if let count = TranscriptionQuality.Hardware.current.performanceCores, count > 0 {
            return min(count, available)
        }
        return min(4, available)
    }
    static func arguments(paths: AppPaths, wav: URL, temporaryBase: URL, lecture: String,
                          vocabularyText: String? = nil, quality: TranscriptionQuality = .detailed) -> [String] {
        var args = ["-m", paths.model.path, "-f", wav.path, "-l", "en", "-otxt", "-of", temporaryBase.path, "-np", "-pp", "-t", String(threadCount),
                    "-mc", "0"]
        let vocab = paths.lectureFolder(lecture).appendingPathComponent("vocab.txt")
        if let text = vocabularyText ?? (try? String(contentsOf: vocab, encoding: .utf8)),
           let prompt = Vocabulary.prompt(text, model: paths.model) {
            // N static tokens + the previous-token marker leave no room for decoded history.
            // whisper.cpp omits prompts at fallback temperatures >= 0.5 and in its short tail.
            args[args.count - 1] = String(prompt.tokens + 1)
            args += ["--prompt", prompt.text, "--carry-initial-prompt"]
        }
        if SpeechModel.validateVAD(paths.vadModel) { args += ["--vad", "-vm", paths.vadModel.path] }
        args += quality.whisperArguments
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
        // Freeze folder subject choices and user terms before audio preparation or inference.
        let folder = paths.lectureFolder(record.lecture)
        let vocabularyText = (try? String(contentsOf: folder.appendingPathComponent("vocab.txt"), encoding: .utf8)) ?? ""
        let settings = (try? SubjectSettings.load(folder: folder)) ?? SubjectSettings(subject: "general")
        let resolvedSubjects = settings.resolved(course: record.lecture)
        let userTerms = Vocabulary.entries(vocabularyText)
        record.vocabularyTerms = Array(Set(userTerms)).sorted()
        let smart = settings.isEnabled && resolvedSubjects.contains { $0 != "general" }
        let flags = ProcessInfo.processInfo.environment["NOSY_VOCAB_STAGES"].map { Set($0.split(separator: ",").map(String.init)) }
        // Quit cancels the job, not this detached task, so every long audio pass polls the job itself.
        let checkCancellation: () throws -> Void = { try job.checkCancellation() }
        do {
            try job.checkCancellation()
            try paths.validateLectureFolder(record.lecture)
            guard try Core.sanitize(record.session) == record.session else { throw LectureError.message("Invalid session name in recording.") }
            progress(0)
            record.status = .transcribing
            record.error = nil
            record.endedAt = record.endedAt ?? Date()
            try record.save(in: paths)
            let wav = try AudioFiles.decodeToWAV(id: record.id, paths: paths, checkCancellation: checkCancellation)
            guard Core.fileSize(wav) != 44 else { throw LectureError.message(Core.emptyRecordingMessage) } // Header only.
            if let warning = paths.dependencyWarning { throw LectureError.message(warning) }
            guard let executable = paths.whisper else { throw LectureError.message(Core.missingEngineMessage) }
            let base = paths.audio.appendingPathComponent(".whisper-\(record.id)-\(UUID().uuidString)")
            let stderrURL = base.appendingPathExtension("stderr")
            let textURL = base.appendingPathExtension("txt")
            let jsonURL = base.appendingPathExtension("json")
            let louderURL = base.appendingPathExtension("wav")
            defer {
                try? paths.removeSupportFile(stderrURL)
                try? paths.removeSupportFile(textURL)
                try? paths.removeSupportFile(jsonURL)
                try? paths.removeSupportFile(louderURL)
            }
            let input: URL
            do { input = try AudioFiles.boosted(wav, to: louderURL, paths: paths, checkCancellation: checkCancellation) ?? wav }
            catch is CancellationError { throw CancellationError() }
            catch { input = wav }
            guard paths.safeSupportItem(paths.audio, directory: true) else { throw LectureError.message("Unsafe audio storage.") }
            guard FileManager.default.createFile(atPath: stderrURL.path, contents: nil, attributes: [.posixPermissions: 0o600]) else {
                throw LectureError.message("Could not create transcription log file.")
            }
            let stderrFile = try FileHandle(forWritingTo: stderrURL)
            defer { try? stderrFile.close() }
            let process = Process()
            process.qualityOfService = .background
            process.executableURL = URL(fileURLWithPath: "/bin/sh")
            let quality = TranscriptionQuality.loadOrSelect()
            process.arguments = ["-c", "umask 077; exec \"$@\"", "nosy-whisper", executable.path] +
                arguments(paths: paths, wav: input, temporaryBase: base, lecture: record.lecture,
                          vocabularyText: vocabularyText, quality: quality)
            // JSON always: its segment timings feed Find key moments and marker insertion.
            if smart { process.arguments! += ["-ojf"] }
            else { process.arguments! += ["-oj"] }
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
            var text = try String(contentsOf: textURL, encoding: .utf8)
            if smart {
                do {
                    let refined = try VocabularyRefinement.refine(original: text, data: Data(contentsOf: jsonURL), catalog: .bundled,
                                                                 subjects: resolvedSubjects, userTerms: userTerms,
                                                                 router: flags?.contains("router") ?? true, substitute: flags?.contains("substitute") ?? true, job: job)
                    try job.checkCancellation()
                    text = refined.text
                }
                catch is CancellationError { throw CancellationError() }
                catch { /* Optional refinement failure keeps the successful first pass. */ }
            }
            let segments = try? JSONDecoder().decode(TranscriptSegments.self, from: Data(contentsOf: jsonURL))
            let body: String?
            if record.markers.isEmpty { body = nil }
            else {
                guard let segments else {
                    throw LectureError.message("Could not match marker timestamps to transcript segments. Your recording and markers are kept; try Retry.")
                }
                body = try Core.markedParagraphs(text, markers: record.markers, segments: segments)
            }
            let markdown = Core.markdown(record: record, duration: Core.audioDuration(id: record.id, paths: paths), text: text, body: body)
            try job.checkCancellation()
            let target = try TranscriptCoordination.withLock(paths: paths) {
                let target = try Core.writeTranscript(markdown, folder: paths.lectureFolder(record.lecture), session: record.session)
                let transcriptID = UUID().uuidString
                do {
                    try TranscriptIdentity.bind(target, id: transcriptID)
                    record.transcriptID = transcriptID
                } catch {
                    // The transcript is already published. Keep it and its audio, and report the
                    // failure rather than treating the recording as a failed transcription.
                    record.error = "Transcript saved, but its identity could not be established: \(error.localizedDescription) Audio will be kept; automatic retention and key moments are unavailable until this is resolved."
                }
                record.transcriptPath = target.path
                record.status = .done
                record.transcribedAt = Date()
                try record.save(in: paths)
                return target
            }
            // Timings sit beside the transcript for later key moments, so they outlive the audio. A failure never fails the transcript.
            if record.transcriptID != nil { try? KeyMomentStore.start(transcript: target, segments: segments?.transcription, text: text) }
            // The transcript is already committed: cancellation here leaves it .done and stops the optional work.
            if UserDefaults.standard.object(forKey: "compressAudio") as? Bool ?? true {
                do { try AudioFiles.compress(id: record.id, paths: paths, checkCancellation: checkCancellation) }
                catch is CancellationError { throw CancellationError() }
                catch { /* Compression is optional; the WAV is kept when it fails. */ }
            }
            do { try Core.applyRetention(paths: paths, checkCancellation: checkCancellation) }
            catch is CancellationError { throw CancellationError() }
            catch { /* Retention is best effort; the next launch tries again. */ }
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
