import Foundation

// Keep preference migration tests entirely in memory, outside real preference domains.
private final class MemoryDefaults: UserDefaults, @unchecked Sendable {
    private var values: [String: Any]
    init(_ values: [String: Any] = [:]) {
        self.values = values
        super.init(suiteName: nil)!
    }
    override func object(forKey key: String) -> Any? { values[key] }
    override func set(_ value: Any?, forKey key: String) { values[key] = value }
}

@main
enum CoreTests {
    static func migrationTests(root: URL, check: (Bool, String) -> Void) throws {
        let manager = FileManager.default
        let home = root.appendingPathComponent("migration-home", isDirectory: true)
        let paths = AppPaths(environment: [:], home: home, transcriptsFolder: nil, retentionDays: nil)
        let legacy = home.appendingPathComponent("Library/Application Support/Lecture Transcriber", isDirectory: true)
        let defaults = MemoryDefaults()
        let oldDefaults = MemoryDefaults(["lastLecture": "Biology", "requestedNotifications": false, "unrelated": "keep"])
        func migrate(_ paths: AppPaths = paths, from source: URL = legacy) throws {
            try Core.migrateLegacy(paths: paths, legacySupport: source, defaults: defaults, legacyDefaults: oldDefaults)
        }
        func write(_ text: String, to url: URL) throws {
            try manager.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data(text.utf8).write(to: url)
        }
        check(paths.support == home.appendingPathComponent("Library/Application Support/Nosy", isDirectory: true), "Nosy default support")
        check(paths.transcripts == home.appendingPathComponent("Documents/Nosy", isDirectory: true), "new-user transcript default")
        try write("model", to: legacy.appendingPathComponent("models/model.bin"))
        try write("audio", to: legacy.appendingPathComponent("audio/lecture.pcm"))
        try write("other", to: legacy.appendingPathComponent("other/keep.txt"))
        try migrate()
        check(!manager.fileExists(atPath: legacy.path), "legacy directory renamed")
        check(try String(contentsOf: paths.support.appendingPathComponent("models/model.bin"), encoding: .utf8) == "model", "move preserves model")
        check(try String(contentsOf: paths.audio.appendingPathComponent("lecture.pcm"), encoding: .utf8) == "audio", "move preserves audio")
        check(manager.fileExists(atPath: paths.support.appendingPathComponent("other/keep.txt").path), "whole move preserves other data")
        check(defaults.object(forKey: "lastLecture") as? String == "Biology", "migrates lecture preference")
        check(defaults.object(forKey: "requestedNotifications") as? Bool == false, "migrates false notification preference")
        check(defaults.object(forKey: "unrelated") == nil && oldDefaults.object(forKey: "unrelated") as? String == "keep", "only selected preferences copied")

        // Both roots exist: migrate only absent files in models/ and audio/.
        try write("legacy conflict", to: legacy.appendingPathComponent("models/model.bin"))
        try write("legacy audio conflict", to: legacy.appendingPathComponent("audio/lecture.pcm"))
        try write("new model", to: legacy.appendingPathComponent("models/extra.bin"))
        try write("new audio", to: legacy.appendingPathComponent("audio/extra.wav"))
        try write("sidecar", to: legacy.appendingPathComponent("audio/extra.json"))
        try write("keep outside merge", to: legacy.appendingPathComponent("keep.txt"))
        try write("keep nested", to: legacy.appendingPathComponent("audio/nested/keep.txt"))
        try write("preserve dangling target", to: legacy.appendingPathComponent("models/dangling.bin"))
        let dangling = paths.support.appendingPathComponent("models/dangling.bin")
        try manager.createSymbolicLink(atPath: dangling.path, withDestinationPath: "absent.bin")
        try manager.createSymbolicLink(atPath: legacy.appendingPathComponent("models/linked.bin").path, withDestinationPath: "model.bin")
        defaults.set("Chemistry", forKey: "lastLecture")
        oldDefaults.set(true, forKey: "requestedNotifications")
        try migrate()
        check(try String(contentsOf: paths.model.deletingLastPathComponent().appendingPathComponent("model.bin"), encoding: .utf8) == "model", "merge never overwrites model")
        check(try String(contentsOf: paths.audio.appendingPathComponent("lecture.pcm"), encoding: .utf8) == "audio", "merge never overwrites audio")
        check(manager.fileExists(atPath: legacy.appendingPathComponent("models/model.bin").path), "conflicting legacy model retained")
        check(manager.fileExists(atPath: legacy.appendingPathComponent("audio/lecture.pcm").path), "conflicting legacy audio retained")
        for file in ["models/extra.bin", "audio/extra.wav", "audio/extra.json", "models/linked.bin"] {
            check(manager.fileExists(atPath: paths.support.appendingPathComponent(file).path), "merge transfers \(file)")
            check(!manager.fileExists(atPath: legacy.appendingPathComponent(file).path), "merge moves rather than copies \(file)")
        }
        check(try manager.destinationOfSymbolicLink(atPath: dangling.path) == "absent.bin", "merge preserves dangling destination symlink")
        check(manager.fileExists(atPath: legacy.appendingPathComponent("models/dangling.bin").path), "dangling conflict leaves source intact")
        check(manager.fileExists(atPath: legacy.appendingPathComponent("keep.txt").path), "unrelated legacy file retained")
        check(manager.fileExists(atPath: legacy.appendingPathComponent("audio/nested/keep.txt").path), "nested directory left intact")
        check(defaults.object(forKey: "lastLecture") as? String == "Chemistry", "existing new lecture preference wins")
        check(defaults.object(forKey: "requestedNotifications") as? Bool == false, "existing false preference wins")
        try migrate()
        check(manager.fileExists(atPath: legacy.appendingPathComponent("keep.txt").path), "migration is repeatable without deleting legacy root")

        let override = AppPaths(environment: ["NOSY_SUPPORT_DIR": root.appendingPathComponent("custom-support").path], home: home)
        let untouched = MemoryDefaults()
        try Core.migrateLegacy(paths: override, legacySupport: legacy, defaults: untouched, legacyDefaults: oldDefaults)
        check(!manager.fileExists(atPath: override.support.path), "support override disables filesystem migration")
        check(untouched.object(forKey: "lastLecture") == nil, "support override disables preference migration")
        try migrate(from: home.appendingPathComponent("missing-legacy"))
        check(manager.fileExists(atPath: paths.audio.appendingPathComponent("extra.wav").path), "absent legacy root is harmless")
    }

    static func main() throws {
        var assertions = 0
        func check(_ value: Bool, _ message: String) {
            assertions += 1
            guard value else { fatalError("FAIL: \(message)") }
        }
        func rejects(_ name: String) {
            do { _ = try Core.sanitize(name); fatalError("Accepted invalid name: \(name)") }
            catch { assertions += 1 }
        }
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("nosy-unit-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let paths = AppPaths(environment: ["NOSY_SUPPORT_DIR": root.appendingPathComponent("support").path,
                                          "NOSY_TRANSCRIPTS_DIR": root.appendingPathComponent("transcripts").path,
                                          "NOSY_WHISPER_CLI": "/does/not/exist"])
        try paths.prepareSupport()
        check(paths.whisper == nil, "explicit missing CLI override")
        check(paths.dependencyWarning?.contains("Model missing") == true, "dependency banner")
        // A shipped app must never depend on Homebrew, PATH, or a developer override.
        let bundle = root.appendingPathComponent("Nosy.app", isDirectory: true)
        let helper = bundle.appendingPathComponent("Contents/Helpers/whisper-cli")
        try FileManager.default.createDirectory(at: helper.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("#!/bin/sh\nexit 0\n".utf8).write(to: helper)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: helper.path)
        let bundledPaths = AppPaths(environment: ["NOSY_WHISPER_CLI": "/bin/echo", "PATH": "/bin"], bundleURL: bundle)
        check(bundledPaths.whisper == helper, "bundled helper wins over developer override and PATH")
        check(bundledPaths.rehearsal(in: root.appendingPathComponent("rehearsal")).whisper == helper, "rehearsal keeps bundled engine")
        try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: helper.path)
        check(bundledPaths.whisper == nil, "non-executable bundled helper cannot fall back to an installed engine")
        try FileManager.default.removeItem(at: helper)
        check(bundledPaths.whisper == nil, "missing bundled helper cannot fall back to an installed engine")
        check(bundledPaths.dependencyWarning?.contains("Reinstall Nosy") == true, "damaged bundle offers reinstall")
        let devBin = root.appendingPathComponent("dev-bin", isDirectory: true)
        try FileManager.default.createDirectory(at: devBin, withIntermediateDirectories: true)
        let devCLI = devBin.appendingPathComponent("whisper-cli")
        try FileManager.default.createSymbolicLink(at: devCLI, withDestinationURL: URL(fileURLWithPath: "/bin/echo"))
        check(AppPaths(environment: ["PATH": devBin.path], bundleURL: root).whisper == devCLI, "unbundled development binary searches PATH")
        check(AppPaths(environment: ["NOSY_WHISPER_CLI": "/bin/echo"], bundleURL: root).whisper?.path == "/bin/echo", "unbundled development binary accepts override")
        try migrationTests(root: root, check: check)
        check(Core.parseProgress("whisper_print_progress_callback: progress = 10%") == 0.1, "real CLI progress format")
        check(Core.parseProgress("progress = 10%\rprogress = 75%\n") == 0.75, "last percentage in chunk")
        check(Core.parseProgress("progress = 0%") == 0, "zero progress")
        check(Core.parseProgress("progress = 100%") == 1, "complete progress")
        check(Core.parseProgress("… progress = 12.5 %") == 0.125, "decimal progress and Unicode prefix")
        check(Core.parseProgress("progress = 12") == nil, "incomplete percentage")
        check(Core.parseProgress("whisper timing = 0.25 ms") == nil, "unrelated output")
        check(Core.parseProgress("") == nil, "empty progress")
        check(Core.parseProgress("progress = -5%") == nil, "negative progress rejected")
        check(Core.parseProgress("progress = 101%") == nil, "out of range progress rejected")
        check(Core.parseProgress("progress = 10% then 105%") == nil, "last percentage must be valid")
        check(Core.parseProgress("progress = 10% then -5%") == nil, "negative final percentage rejected")
        let missingEngine = "Nosy's speech engine is missing. Reinstall Nosy, then Retry — your audio is safe."
        let missingModel = "The speech model hasn't been downloaded yet. Your audio is safe — Retry once it's ready."
        let snag = "Transcription hit a snag. Your audio is safe — try Retry."
        check(Core.friendlyError(Core.missingEngineMessage) == missingEngine, "missing CLI friendly error")
        check(Core.friendlyError("The file “whisper-cli” doesn’t exist.") == missingEngine, "missing CLI Cocoa error")
        check(Core.friendlyError("Model missing: /tmp/models/model.bin") == missingModel, "missing model friendly error")
        check(Core.friendlyError("whisper-cli exited 1: failed to open model '/tmp/ggml.bin'") == missingModel, "missing model takes priority over exit code")
        check(Core.friendlyError("whisper-cli exited 1: model: no such file") == missingModel, "model file absence is not engine absence")
        check(Core.friendlyError("whisper-cli exited 134: assertion failed") == snag, "CLI exit friendly error")
        check(Core.friendlyError("Microphone changed and could not restart: device unavailable").hasPrefix("Your microphone changed or disconnected."), "device change friendly error")
        check(Core.friendlyError("The selected microphone has no usable audio input.").hasPrefix("Nosy couldn't record from your microphone."), "mic input friendly error")
        check(Core.friendlyError("Microphone access is denied.").hasPrefix("Nosy can't access your microphone."), "mic permission friendly error")
        check(Core.friendlyError("Could not save microphone audio: permission denied").hasPrefix("Nosy couldn't save the file."), "file write friendly error")
        check(Core.friendlyError("Could not write microphone audio: I/O error").hasPrefix("Nosy couldn't save the file."), "write failure takes priority over microphone failure")
        check(Core.friendlyError("Could not create recording file.").hasPrefix("Nosy couldn't save the file."), "file creation friendly error")
        for message in ["Could not save microphone audio: ENOSPC", "No space left on device", "Could not finalize WAV (errno 28)", "NSCocoaErrorDomain Code=640"] {
            check(Core.friendlyError(message).hasPrefix("Your disk is full."), "disk full priority: \(message)")
        }
        check(Core.friendlyError("App closed unexpectedly").hasPrefix("Nosy closed before this lecture finished."), "crash friendly error")
        check(Core.friendlyError("Quit before transcription").hasPrefix("Nosy quit before transcription finished."), "quit friendly error")
        check(Core.friendlyError(" \nUnexpected detail\t ") == "Unexpected detail", "unknown error trimmed")
        check(Core.friendlyError("  " + String(repeating: "é", count: 200) + "\n") == String(repeating: "é", count: 160), "unknown error capped by characters")
        check(Core.friendlyError(" \n ") == "", "empty friendly error")
        check(try Core.sanitize("  Biology   101  ") == "Biology 101", "trim and collapse")
        check(try Core.sanitize("a/b\\c:d*e?f\"g<h>i|j\u{0001}k") == "a-b-c-d-e-f-g-h-i-j-k", "forbidden characters")
        check(try Core.sanitize("Lecture\tOne\nTwo") == "Lecture-One-Two", "controls replaced")
        check(try Core.sanitize(String(repeating: "é", count: 100)).count == 80, "unicode character limit")
        check(try Core.sanitize(".biology.") == ".biology.", "valid dots")
        rejects(""); rejects("  \n  "); rejects("."); rejects("...")
        let folder = paths.lectureFolder("Biology")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let first = try Core.writeTranscript("original", folder: folder, session: "Lesson")
        check(first.lastPathComponent == "Lesson.md", "first unique name")
        let second = try Core.writeTranscript("second", folder: folder, session: "Lesson")
        check(second.lastPathComponent == "Lesson-2.md", "second unique name")
        check(Core.uniqueTranscript(in: folder, session: "Lesson").lastPathComponent == "Lesson-3.md", "third unique name")
        check(try String(contentsOf: first, encoding: .utf8) == "original", "never overwrites")
        let third = try Core.writeTranscript("third", folder: folder, session: "Lesson")
        check(third.lastPathComponent == "Lesson-3.md", "third atomic write")
        check(paths.lectures() == ["Biology"], "lecture folder list")

        let header = try Core.wavHeader(pcmBytes: 32_000)
        func ascii(_ offset: Int, _ length: Int) -> String { String(decoding: header[offset..<offset + length], as: UTF8.self) }
        func number(_ offset: Int, _ length: Int) -> UInt32 {
            header[offset..<offset + length].enumerated().reduce(0) { $0 | (UInt32($1.element) << ($1.offset * 8)) }
        }
        check(header.count == 44, "44-byte header")
        check(ascii(0, 4) == "RIFF" && ascii(8, 4) == "WAVE" && ascii(12, 4) == "fmt " && ascii(36, 4) == "data", "WAV chunks")
        check(number(4, 4) == 32_036 && number(40, 4) == 32_000, "RIFF and data sizes")
        check(number(16, 4) == 16 && number(20, 2) == 1, "PCM format")
        check(number(22, 2) == 1 && number(24, 4) == 16_000, "mono 16 kHz")
        check(number(28, 4) == 32_000 && number(32, 2) == 2 && number(34, 2) == 16, "PCM bit rate and alignment")
        do { _ = try Core.wavHeader(pcmBytes: Int64(UInt32.max)); fatalError("oversized WAV accepted") } catch { assertions += 1 }
        var record = SessionRecord(id: "20261021-123456", lecture: "Biology", session: "Lesson", startedAt: Date(timeIntervalSince1970: 1_700_000_000), status: .recording)
        try record.save(in: paths)
        check(try SessionRecord.read(paths.audioFile(record.id, "json")) == record, "sidecar round trip")
        try Data(repeating: 0, count: 32_001).write(to: paths.audioFile(record.id, "pcm"))
        let wav = try Core.finalizeWAV(id: record.id, paths: paths)
        check(Core.fileSize(wav) == 32_044, "stream finalization trims partial sample")
        check(!FileManager.default.fileExists(atPath: paths.audioFile(record.id, "pcm").path), "PCM removed after durable WAV")
        check(Core.audioDuration(id: record.id, paths: paths) == 1, "WAV duration excludes header")
        let probe = Process()
        probe.executableURL = URL(fileURLWithPath: "/usr/bin/afinfo")
        probe.arguments = [wav.path]
        let pipe = Pipe(); probe.standardOutput = pipe; probe.standardError = pipe
        try probe.run()
        let info = String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        probe.waitUntilExit()
        check(probe.terminationStatus == 0 && info.contains("16000") && info.contains("1 ch"), "afinfo validates WAV")
        check(Core.duration(pcmBytes: 1_920_000) == 60, "duration math")
        check(Core.duration(pcmBytes: -1) == 0, "nonnegative duration")
        check(Core.minutes(0) == 1 && Core.minutes(89) == 1 && Core.minutes(90) == 2, "rounded minutes")
        check(Core.timer(61) == "1:01" && Core.timer(3661) == "1:01:01", "timer formatting")
        check(Core.reminderTime(10800) == "3:00", "hour reminder")
        check(Core.paragraphs(" [BLANK_AUDIO]\n[Music]\n(silence)\n\n") == "_No speech detected._", "empty and marker stripping")
        check(Core.paragraphs(" Hello. \n\n World!\n[mUsIc]") == "Hello. World!", "segment joining")
        check(Core.paragraphs("[ATP is important]") == "[ATP is important]", "speech in brackets kept")
        let long = String(repeating: "a", count: 610)
        check(Core.paragraphs(long + "\ncontinues.\nNext.") == long + " continues.\n\nNext.", "paragraph at sentence after threshold")
        check(Core.paragraphs(String(repeating: "b", count: 599) + ".\nNext") == String(repeating: "b", count: 599) + ".\n\nNext", "600-character boundary")
        let markdown = Core.markdown(record: record, duration: 90, text: "[Music]\nGlycolysis produces NADH.")
        check(markdown.hasPrefix("# Biology — Lesson\n\n- Date: "), "markdown title/date")
        check(markdown.contains("- Started: ") && markdown.contains("- Length: 2 min\n\n## Transcript\n\nGlycolysis produces NADH."), "markdown metadata and speech")
        check(Core.markdown(record: record, duration: 0, text: "").contains("_No speech detected._"), "empty markdown")
        let now = Date()
        record.startedAt = now.addingTimeInterval(-15 * 86_400)
        record.status = .done
        var recent = record; recent.id = "20261021-123457"; recent.startedAt = now
        var failed = record; failed.id = "20261021-123458"; failed.status = .failed
        var unfinished = record; unfinished.id = "20261021-123459"; unfinished.status = .transcribing
        check(Core.retentionCandidates([record, recent, failed, unfinished], now: now).map(\.id) == [record.id], "retention only old done")
        check(Set(Core.recoveryCandidates([record, recent, failed, unfinished]).map(\.id)) == Set([failed.id, unfinished.id]), "recovery excludes done")
        var dismissedOld = failed; dismissedOld.id = "dismissed"; dismissedOld.dismissed = true; dismissedOld.startedAt = now.addingTimeInterval(-15 * 86_400)
        check(!Core.recoveryCandidates([dismissedOld]).contains(dismissedOld), "recovery skips dismissed")
        check(Core.retentionCandidates([dismissedOld], now: now).isEmpty, "retention never deletes untranscribed audio")
        check(Core.retentionCandidates([record], now: now, days: 0).isEmpty, "retention 0 keeps audio forever")
        let exclusive = root.appendingPathComponent("exclusive.md")
        check(try Core.exclusiveWrite(Data("first".utf8), to: exclusive), "exclusive write creates file")
        check(!(try Core.exclusiveWrite(Data("second".utf8), to: exclusive)), "exclusive write never overwrites")
        check((try? String(contentsOf: exclusive, encoding: .utf8)) == "first", "exclusive write kept original")
        check(Core.retentionCandidates([record], now: now, days: 30).isEmpty, "retention 30 keeps 15-day-old audio")
        check(Core.retentionCandidates([record], now: now, days: 7).map(\.id) == [record.id], "retention 7 deletes 15-day-old audio")
        var imported = record; imported.id = "imported"; imported.transcribedAt = now
        check(Core.retentionCandidates([imported], now: now, days: 7).isEmpty, "retention counts from transcript time, not an old import date")
        let freshHome = root.appendingPathComponent("fresh-home", isDirectory: true)
        check(AppPaths.defaultTranscripts(home: freshHome).path.hasSuffix("Documents/Nosy"), "new users default to Documents/Nosy")
        try FileManager.default.createDirectory(at: freshHome.appendingPathComponent("Desktop/Lecture Transcripts"), withIntermediateDirectories: true)
        check(AppPaths.defaultTranscripts(home: freshHome).path.hasSuffix("Desktop/Lecture Transcripts"), "legacy users keep Desktop folder")
        check(AppPaths(environment: [:], home: freshHome, transcriptsFolder: "/tmp/elsewhere", retentionDays: 0).transcripts.path == "/tmp/elsewhere", "chosen folder wins")
        try record.save(in: paths)
        try failed.save(in: paths)
        try Data(repeating: 0, count: 64_000).write(to: paths.audioFile(failed.id, "pcm"))
        unfinished.startedAt = now
        try unfinished.save(in: paths)
        try Data(repeating: 0, count: 96_000).write(to: paths.audioFile(unfinished.id, "pcm"))
        let recovered = try Core.recover(paths: paths)
        check(recovered.first?.id == unfinished.id && recovered.count == 2, "most recent recovery first")
        check(recovered.first?.status == .failed && recovered.first?.error == "App closed unexpectedly", "unfinished becomes failed")
        check(Core.audioDuration(id: unfinished.id, paths: paths) == 3, "recovered actual byte length")
        check(try Core.recover(paths: paths).count == 2, "recovery survives another launch")
        try Core.applyRetention(paths: paths, now: now)
        check(!FileManager.default.fileExists(atPath: wav.path), "retention deletes old done audio")
        check(!FileManager.default.fileExists(atPath: paths.audioFile(record.id, "json").path), "retention deletes sidecar")
        check(FileManager.default.fileExists(atPath: paths.audioFile(failed.id, "wav").path), "retention keeps failed audio")
        check(FileManager.default.fileExists(atPath: first.path), "retention keeps transcripts")
        check(Core.stressReason(thermal: .nominal, onBattery: false, percent: nil) == nil, "desktop has no battery stress")
        check(Core.stressReason(thermal: .fair, onBattery: true, percent: 20) == nil, "fair temperature and exactly 20 percent can transcribe")
        check(Core.stressReason(thermal: .nominal, onBattery: true, percent: 19.9) == "battery low", "battery below 20 pauses transcription")
        check(Core.stressReason(thermal: .nominal, onBattery: true, percent: 0) == "battery low", "empty battery pauses transcription")
        check(Core.stressReason(thermal: .nominal, onBattery: false, percent: 1) == nil, "plugged-in low battery can transcribe")
        check(Core.stressReason(thermal: .nominal, onBattery: true, percent: nil) == nil, "unknown battery capacity does not block queue")
        check(Core.stressReason(thermal: .nominal, onBattery: true, percent: -1) == nil, "invalid battery capacity does not block queue")
        check(Core.stressReason(thermal: .serious, onBattery: false, percent: 100) == "Mac is hot", "serious thermal state pauses on AC")
        check(Core.stressReason(thermal: .critical, onBattery: true, percent: 1) == "Mac is hot", "thermal stress takes precedence")
        print("UNIT PASS: \(assertions) assertions (including afinfo WAV validation)")
    }
}
