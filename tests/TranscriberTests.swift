import Foundation

private final class ProgressProbe: @unchecked Sendable {
    private let lock = NSLock()
    private var values: [Double] = []
    let marker: URL
    init(marker: URL) { self.marker = marker }
    func receive(_ value: Double) {
        lock.lock(); values.append(value); lock.unlock()
        if value == 0.25 { try? Data().write(to: marker) }
    }
    func snapshot() -> [Double] { lock.lock(); defer { lock.unlock() }; return values }
}

private func processState(_ process: Process) -> String {
    let probe = Process()
    probe.executableURL = URL(fileURLWithPath: "/bin/ps")
    probe.arguments = ["-o", "state=", "-p", String(process.processIdentifier)]
    let pipe = Pipe()
    probe.standardOutput = pipe
    probe.standardError = FileHandle.nullDevice
    guard (try? probe.run()) != nil else { return "" }
    let data = pipe.fileHandleForReading.readDataToEndOfFile()
    probe.waitUntilExit()
    return String(decoding: data, as: UTF8.self)
}

private final class TerminationProbe: Process, @unchecked Sendable {
    let child = Process()
    private(set) var continuedBeforeTermination = false
    override var processIdentifier: Int32 { child.processIdentifier }
    override var isRunning: Bool { child.isRunning }
    override func run() throws { try child.run() }
    override func waitUntilExit() { child.waitUntilExit() }
    override func terminate() {
        let state = processState(self)
        continuedBeforeTermination = !state.isEmpty && !state.contains("T")
        child.terminate()
    }
}

@main
enum TranscriberTests {
    static func main() async throws {
        // Keep test preferences process-local and independent of the user's Settings.
        UserDefaults.standard.setVolatileDomain(["compressAudio": true], forName: UserDefaults.argumentDomain)
        let manager = FileManager.default
        let root = manager.temporaryDirectory.appendingPathComponent("nosy-transcriber-unit-\(UUID().uuidString)")
        defer { try? manager.removeItem(at: root) }
        let cli = root.appendingPathComponent("whisper-cli")
        let paths = AppPaths(environment: ["NOSY_SUPPORT_DIR": root.appendingPathComponent("support").path,
                                          "NOSY_TRANSCRIPTS_DIR": root.appendingPathComponent("transcripts").path,
                                          "NOSY_WHISPER_CLI": cli.path])
        try paths.prepareSupport()
        var model = Data()
        func integer(_ value: UInt32) { var value = value.littleEndian; withUnsafeBytes(of: &value) { model.append(contentsOf: $0) } }
        integer(0x67676d6c)
        for _ in 0..<11 { integer(0) }
        integer(1); integer(1); integer(0)
        integer(128)
        for byte in UInt8(0)...127 { integer(1); model.append(byte) }
        try model.write(to: paths.model)
        var assertions = 0
        func check(_ value: Bool, _ message: String) {
            assertions += 1
            guard value else { fatalError("FAIL: \(message)") }
        }
        func installCLI(_ script: String) throws {
            try Data(("#!/bin/bash\nset -eu\n" + script + "\n").utf8).write(to: cli)
            try manager.setAttributes([.posixPermissions: 0o755], ofItemAtPath: cli.path)
        }
        func record(_ id: String) throws -> SessionRecord {
            let record = SessionRecord(id: id, lecture: "Biology", session: "Progress", startedAt: Date(), status: .recording)
            try record.save(in: paths)
            let samples = [Int16](repeating: 100, count: 1600)
            try samples.withUnsafeBytes { Data($0) }.write(to: paths.audioFile(id, "pcm"))
            return record
        }
        func temporaryOutputs() throws -> [URL] {
            try manager.contentsOfDirectory(at: paths.audio, includingPropertiesForKeys: nil)
                .filter { $0.lastPathComponent.hasPrefix(".whisper-") }
        }

        let folder = paths.lectureFolder("Biology")
        try manager.createDirectory(at: folder, withIntermediateDirectories: true)
        let vocab = folder.appendingPathComponent("vocab.txt")
        let base = root.appendingPathComponent("arguments")
        let wav = root.appendingPathComponent("input.wav")
        let plain = Transcriber.arguments(paths: paths, wav: wav, temporaryBase: base, lecture: "Biology")
        check(!plain.contains("--prompt") && plain[plain.firstIndex(of: "-mc")! + 1] == "0", "plain arguments retain no-history loop guard")
        try Data("  interferon,  ICAM\nCD4   CD8 ".utf8).write(to: vocab)
        try Data().write(to: paths.vadModel)
        let prompted = Transcriber.arguments(paths: paths, wav: wav, temporaryBase: base, lecture: "Biology")
        let expectedPrompt = "interferon, ICAM, CD4 CD8"
        check(prompted[prompted.firstIndex(of: "--prompt")! + 1] == expectedPrompt, "vocab.txt preserves complete terms and collapses whitespace")
        check(prompted[prompted.firstIndex(of: "-mc")! + 1] == String(expectedPrompt.utf8.count + 1), "context fits exactly the native prompt tokens plus marker, with no history slots")
        check(prompted.contains("--carry-initial-prompt"), "vocabulary prompt is retained across decoder windows")
        check(prompted.contains("--vad") && prompted[prompted.firstIndex(of: "-vm")! + 1] == paths.vadModel.path, "vocabulary preserves VAD arguments")
        let bytes = Set((UInt8(0)...127).map { Data([$0]) })
        let long = Vocabulary.prompt(Array(repeating: "ICAM", count: 74).joined(separator: ", "), vocabulary: bytes)!
        check(long.tokens <= Vocabulary.tokenBudget && long.tokens == long.text.utf8.count, "long vocabulary respects the native token budget")
        check(long.text.hasSuffix("ICAM") && long.text.split(separator: ",").count < 74, "prompt truncation keeps complete terms")
        let pieces = Set(["inter", "feron", " ICAM", ",", " ", "CD", "4"].map { Data($0.utf8) })
        check(Vocabulary.prompt("interferon, ICAM\nCD4", vocabulary: pieces)?.tokens == 8, "tokenizer uses longest matches within the CLI regex pieces")
        check(Vocabulary.prompt("   ", vocabulary: bytes) == nil, "empty vocabulary supplies no prompt")
        check(Vocabulary.prompt("β", vocabulary: bytes) == nil, "unknown tokens cannot enable decoded history")
        try Data().write(to: paths.model)
        let invalid = Transcriber.arguments(paths: paths, wav: wav, temporaryBase: base, lecture: "Biology")
        check(!invalid.contains("--prompt") && invalid[invalid.firstIndex(of: "-mc")! + 1] == "0", "unreadable tokenizer safely retains the loop guard")
        try model.write(to: paths.model)
        try manager.removeItem(at: vocab)
        try manager.removeItem(at: paths.vadModel)

        // Exercise real stop/continue signals, including stress during preparation and quit while stopped.
        let suspendedJob = TranscriptionJob()
        let child = TerminationProbe()
        child.child.executableURL = URL(fileURLWithPath: "/bin/sleep")
        child.child.arguments = ["30"]
        child.child.qualityOfService = .utility
        suspendedJob.suspend()
        try suspendedJob.launch(child)
        func waitFor(_ condition: () -> Bool) async throws -> Bool {
            for _ in 0..<100 {
                if condition() { return true }
                try await Task.sleep(for: .milliseconds(20))
            }
            return false
        }
        check(try await waitFor { processState(child).contains("T") }, "suspend before launch stops the child immediately after launch")
        suspendedJob.suspend()
        suspendedJob.resume()
        suspendedJob.resume()
        check(try await waitFor { child.isRunning && !processState(child).contains("T") }, "repeated suspend/resume is idempotent")
        suspendedJob.suspend()
        check(try await waitFor { processState(child).contains("T") }, "running child can be suspended again without losing its process")
        suspendedJob.cancel()
        check(child.continuedBeforeTermination, "cancel sends SIGCONT before terminate on a suspended child")
        check(try await waitFor { !child.isRunning }, "cancelled suspended child exits promptly")
        child.waitUntilExit()
        suspendedJob.resume()
        suspendedJob.cancel()
        do { try suspendedJob.checkCancellation(); fatalError("Accepted cancelled suspended job") }
        catch { check(error is CancellationError, "resume cannot undo cancellation") }

        // Wait for a callback acknowledgement before exiting. This fails if stderr is
        // buffered until EOF, and also exercises a percentage split over two writes.
        try installCLI(#"""
        base=''
        input=''
        context=''
        progress=0
        while [[ $# -gt 0 ]]; do
            case "$1" in
                -of) base="$2"; shift 2 ;;
                -f) input="$2"; shift 2 ;;
                -mc) context="$2"; shift 2 ;;
                -pp|--print-progress) progress=1; shift ;;
                *) shift ;;
            esac
        done
        [[ "$progress" == 1 ]] || exit 89
        [[ "$context" == 0 ]] || exit 88
        if [[ "$base" == *".whisper-streaming-"* ]]; then
            [[ "$input" == "$base.wav" && -s "$input" ]] || exit 88
        fi
        printf 'whisper_print_progress_callback: progress = 2' >&2
        /bin/sleep 0.05
        printf '5%%\rprogress = 50%%\n' >&2
        marker="$(dirname "$base")/progress-observed"
        for attempt in {1..200}; do
            [[ -f "$marker" ]] && break
            /bin/sleep 0.01
        done
        if [[ ! -f "$marker" ]]; then
            printf 'progress was not delivered while the process was running\n' >&2
            exit 90
        fi
        printf 'progress = 75%%' >&2
        printf 'Cells use energy.\n' > "$base.txt"
        """#)
        let probe = ProgressProbe(marker: paths.audio.appendingPathComponent("progress-observed"))
        let completed = try await Transcriber.transcribe(record: record("streaming"), paths: paths, progress: { probe.receive($0) })
        check(probe.snapshot() == [0, 0.25, 0.5, 0.75, 1], "live progress, split percentage, CR separator, EOF flush, success callback")
        check(completed.status == .done && completed.transcriptPath != nil, "progress run publishes transcript")
        check(try temporaryOutputs().isEmpty, "successful run cleans boosted WAV, stderr and text")

        UserDefaults.standard.setVolatileDomain(["compressAudio": false], forName: UserDefaults.argumentDomain)
        let uncompressed = try await Transcriber.transcribe(record: record("keep-wav"), paths: paths)
        check(uncompressed.status == .done && manager.fileExists(atPath: paths.audioFile("keep-wav", "wav").path), "compression preference keeps WAV")
        check(!manager.fileExists(atPath: paths.audioFile("keep-wav", "m4a").path), "compression preference does not create M4A")
        UserDefaults.standard.setVolatileDomain(["compressAudio": true], forName: UserDefaults.argumentDomain)
        var invalidAudio = try record("bad-compression")
        try manager.removeItem(at: paths.audioFile(invalidAudio.id, "pcm"))
        try Data("invalid WAV".utf8).write(to: paths.audioFile(invalidAudio.id, "wav"))
        invalidAudio = try await Transcriber.transcribe(record: invalidAudio, paths: paths)
        check(invalidAudio.status == .done && invalidAudio.error == nil, "compression failure does not fail transcript")
        check(manager.fileExists(atPath: paths.audioFile(invalidAudio.id, "wav").path), "compression failure leaves WAV")

        // Output exceeds the pipe capacity, ensuring the reader drains stderr while
        // Whisper is running and preserves the existing error tail on failure.
        try installCLI(#"""
        for line in {1..2000}; do printf '%080d\n' "$line" >&2; done
        printf 'unique failure detail at the end\n' >&2
        exit 23
        """#)
        let failedRecord = try record("failed")
        do {
            _ = try await Transcriber.transcribe(record: failedRecord, paths: paths)
            fatalError("Accepted failing CLI")
        } catch {
            check(error.localizedDescription.hasPrefix("whisper-cli exited 23:"), "preserves exit status")
            check(error.localizedDescription.hasSuffix("unique failure detail at the end"), "preserves stderr tail")
            check(error.localizedDescription.count < 340, "stderr detail remains capped around 300 characters")
        }
        check(try SessionRecord.read(paths.audioFile("failed", "json")).status == .failed, "failure saved to sidecar")
        check(manager.fileExists(atPath: paths.audioFile("failed", "wav").path), "failure retains audio")
        check(try temporaryOutputs().isEmpty, "failed run cleans temporary outputs")

        try installCLI(#"touch "$0.launched""#)
        let beforeLaunch = TranscriptionJob()
        do {
            _ = try await Transcriber.transcribe(record: record("cancel-before-launch"), paths: paths, job: beforeLaunch,
                                                 progress: { if $0 == 0 { beforeLaunch.cancel() } })
            fatalError("Accepted cancelled job")
        } catch { check(error is CancellationError, "cancellation during preparation is preserved") }
        check(!manager.fileExists(atPath: cli.path + ".launched"), "cancelled preparation never launches Whisper")
        check(try temporaryOutputs().isEmpty, "cancelled preparation cleans boosted WAV and log")

        try installCLI(#"printf 'progress = 25%%\n' >&2; exec /bin/sleep 30"#)
        let running = TranscriptionJob()
        do {
            _ = try await Transcriber.transcribe(record: record("cancel-running"), paths: paths, job: running,
                                                 progress: { if $0 == 0.25 { running.cancel() } })
            fatalError("Accepted cancelled process")
        } catch { check(error is CancellationError, "running cancellation terminates Whisper and is preserved") }
        check(manager.fileExists(atPath: paths.audioFile("cancel-running", "wav").path), "cancellation preserves original audio")
        check(try temporaryOutputs().isEmpty, "running cancellation cleans boosted WAV and log")
        check(try SessionRecord.read(paths.audioFile("cancel-running", "json")).transcriptPath == nil,
              "cancelled transcription publishes no transcript")
        print("TRANSCRIBER PASS: \(assertions) assertions (live progress, split stderr, error tail, boost, cancellation, audio safety)")
    }
}
