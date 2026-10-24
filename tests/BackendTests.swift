import AVFoundation
import AudioToolbox
import Foundation

@main
enum BackendTests {
    static func main() throws {
        let manager = FileManager.default
        let root = manager.temporaryDirectory.appendingPathComponent("nosy-backend-\(UUID().uuidString)")
        defer { try? manager.removeItem(at: root) }
        let paths = AppPaths(environment: ["NOSY_SUPPORT_DIR": root.appendingPathComponent("support").path,
                                          "NOSY_TRANSCRIPTS_DIR": root.appendingPathComponent("transcripts").path,
                                          "NOSY_WHISPER_CLI": "/bin/echo"], retentionDays: 7)
        try paths.prepareSupport()
        var assertions = 0
        func check(_ value: Bool, _ message: String) {
            assertions += 1
            guard value else { fatalError("FAIL: \(message)") }
        }
        func rejects(_ message: String, _ body: () throws -> Void) {
            do { try body(); fatalError("FAIL: \(message)") } catch { assertions += 1 }
        }
        let whisperMessage = Core.missingEngineMessage
        let modelMessage = "Nosy needs its speech model (1.6 GB) before it can transcribe."
        let missing = AppPaths(environment: ["NOSY_SUPPORT_DIR": paths.support.path, "NOSY_WHISPER_CLI": "/missing"])
        check(Core.setupMessage(paths: missing) == whisperMessage + "\n" + modelMessage, "setup lists whisper first")
        check(Core.setupMessage(paths: paths) == modelMessage, "model-only setup message")
        try Data([0]).write(to: paths.model)
        check(Core.setupMessage(paths: missing) == whisperMessage, "whisper-only setup message")
        check(Core.setupMessage(paths: paths) == nil, "ready setup has no message")
        check(Core.friendlyError("App closed unexpectedly").contains("Choose Retry"), "crash says choose Retry")
        check(Core.friendlyError("Quit before transcription").contains("Choose Retry"), "quit says choose Retry")

        let rehearsalRoot = root.appendingPathComponent("rehearsal", isDirectory: true)
        let rehearsal = paths.rehearsal(in: rehearsalRoot)
        check(rehearsal.support == rehearsalRoot && rehearsal.audio == rehearsalRoot.appendingPathComponent("audio", isDirectory: true), "rehearsal support and audio")
        check(rehearsal.transcripts == rehearsalRoot.appendingPathComponent("transcripts", isDirectory: true), "rehearsal transcripts")
        check(rehearsal.model == paths.model && rehearsal.vadModel == paths.vadModel && rehearsal.whisper == paths.whisper, "rehearsal shares dependencies")
        check(rehearsal.retentionDays == 7 && !rehearsal.usesDefaultSupport, "rehearsal preserves retention and disables migration")
        check(rehearsal.rehearsal(in: root.appendingPathComponent("nested")).model == paths.model, "nested rehearsal shares model")
        try rehearsal.prepareSupport()

        let fake = root.appendingPathComponent("fake-model.bin")
        let magic = Data([0x6c, 0x6d, 0x67, 0x67])
        try (magic + Data(repeating: 1, count: 28)).write(to: fake)
        check(!SpeechModel.validate(fake), "production floor rejects small model")
        check(SpeechModel.validate(fake, minimumBytes: 16), "real ggml magic with test size floor")
        check(!SpeechModel.validate(fake, minimumBytes: 33), "test floor enforced")
        let invalid = root.appendingPathComponent("invalid.bin")
        try Data([0x67, 0x67, 0x6d, 0x6c] + Array(repeating: UInt8(0), count: 28)).write(to: invalid)
        check(!SpeechModel.validate(invalid, minimumBytes: 16), "reversed magic rejected")
        check(!SpeechModel.validate(root.appendingPathComponent("absent"), minimumBytes: 4), "missing model rejected")
        let truncated = root.appendingPathComponent("truncated.bin")
        try magic.prefix(3).write(to: truncated)
        check(!SpeechModel.validate(truncated, minimumBytes: 0), "truncated header rejected even with test floor")
        rejects("production install must validate size") { try SpeechModel.install(from: fake, paths: paths) }
        try manager.setAttributes([.posixPermissions: 0o444], ofItemAtPath: fake.path)
        try SpeechModel.install(from: fake, paths: paths, minimumBytes: 16)
        check(try Data(contentsOf: fake) == Data(contentsOf: paths.model), "install copies readonly source and atomically replaces target")
        check(manager.fileExists(atPath: fake.path), "install retains original")
        let linkedModel = root.appendingPathComponent("linked-model.bin")
        try magic.write(to: linkedModel)
        try manager.removeItem(at: paths.model)
        try manager.createSymbolicLink(at: paths.model, withDestinationURL: linkedModel)
        try SpeechModel.install(from: fake, paths: paths, minimumBytes: 16)
        check(Core.fileSize(linkedModel) == 4 && SpeechModel.validate(paths.model, minimumBytes: 16), "atomic install replaces symlink without modifying its target")
        rejects("invalid install must fail") { try SpeechModel.install(from: invalid, paths: paths, minimumBytes: 16) }
        check(SpeechModel.validate(paths.model, minimumBytes: 16), "failed install preserves previous model")
        check(try manager.contentsOfDirectory(at: paths.model.deletingLastPathComponent(), includingPropertiesForKeys: nil)
            .allSatisfy { !$0.lastPathComponent.hasPrefix(".") }, "model temp files removed")

        check(AudioFiles.playable(id: "absent", paths: paths) == nil, "no playable audio")
        try Data([0, 0]).write(to: paths.audioFile("choice", "pcm"))
        check(AudioFiles.playable(id: "choice", paths: paths) == nil, "raw PCM is not playable")
        try Data([0]).write(to: paths.audioFile("choice", "wav"))
        check(AudioFiles.playable(id: "choice", paths: paths) == paths.audioFile("choice", "wav"), "WAV playback fallback")
        try Data([0]).write(to: paths.audioFile("choice", "m4a"))
        try Data([0]).write(to: paths.audioFile("choice", "json"))
        try Data([0]).write(to: paths.audioFile("choice-other", "wav"))
        check(AudioFiles.playable(id: "choice", paths: paths) == paths.audioFile("choice", "m4a"), "M4A preferred")
        try AudioFiles.deleteAudio(id: "choice", paths: paths)
        check(["pcm", "wav", "m4a", "json"].allSatisfy { !manager.fileExists(atPath: paths.audioFile("choice", $0).path) }, "all audio and sidecar extensions removed")
        check(manager.fileExists(atPath: paths.audioFile("choice-other", "wav").path), "delete respects ID boundary")
        try AudioFiles.deleteAudio(id: "choice", paths: paths)
        do { _ = try AudioFiles.decodeToWAV(id: "absent", paths: paths); fatalError("missing audio accepted") }
        catch { check(error.localizedDescription == "Recorded audio is missing.", "missing audio message") }

        // Span several boost buffers, with exact sample levels for checking gain and clipping.
        func syntheticWAV(_ name: String, peak: Int16, spike: Bool = false) throws -> URL {
            var samples = (0..<160_000).map { $0.isMultiple(of: 2) ? peak : -peak }
            if spike { samples[samples.count - 1] = .min }
            let pcm = samples.withUnsafeBytes { Data($0) }
            let url = root.appendingPathComponent(name + ".wav")
            try (Core.wavHeader(pcmBytes: Int64(pcm.count)) + pcm).write(to: url)
            return url
        }
        func readPCM(_ url: URL) throws -> [Int16] {
            let file = try AVAudioFile(forReading: url, commonFormat: .pcmFormatInt16, interleaved: true)
            let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: 65_536)!
            var samples: [Int16] = []
            while file.framePosition < file.length {
                try file.read(into: buffer)
                guard buffer.frameLength > 0 else { throw LectureError.message("Test WAV ended unexpectedly.") }
                samples.append(contentsOf: UnsafeBufferPointer(start: buffer.int16ChannelData![0],
                    count: Int(buffer.frameLength) * Int(file.processingFormat.channelCount)))
            }
            return samples
        }
        let quiet = try syntheticWAV("quiet", peak: 100)
        let original = try Data(contentsOf: quiet)
        let boosted = root.appendingPathComponent("boosted.wav")
        check(try AudioFiles.boosted(quiet, to: boosted) == boosted, "quiet WAV gets boosted")
        let boostedFile = try AVAudioFile(forReading: boosted)
        check(boostedFile.fileFormat.commonFormat == .pcmFormatInt16 && boostedFile.fileFormat.sampleRate == 16_000
              && boostedFile.fileFormat.channelCount == 1, "boosted WAV is valid 16-bit mono at the original rate")
        check(boostedFile.length == 160_000, "boost preserves frame count")
        if #available(macOS 15, *) { boostedFile.close() }
        let boostedPCM = try readPCM(boosted)
        check(boostedPCM.count == 160_000 && (0..<160_000).allSatisfy {
            boostedPCM[$0] == ($0.isMultiple(of: 2) ? 4000 : -4000)
        }, "quiet peak rises 40x across all buffers without changing samples or length")
        check(try Data(contentsOf: quiet) == original, "boost preserves original WAV")
        let spiked = try syntheticWAV("spiked", peak: 2000, spike: true)
        check(try AudioFiles.boosted(spiked, to: boosted) == boosted, "isolated full-scale spike does not block boost")
        let spikedPCM = try readPCM(boosted)
        check((0..<159_999).allSatisfy {
            spikedPCM[$0] == ($0.isMultiple(of: 2) ? 29_000 : -29_000)
        } && spikedPCM[159_999] == -32_767, "percentile gain targets 29000 and clips Int16.min safely")
        let loud = try syntheticWAV("loud", peak: 24_000)
        let skipped = root.appendingPathComponent("skipped.wav")
        check(try AudioFiles.boosted(loud, to: skipped) == nil, "loud WAV skips boost")
        check(!manager.fileExists(atPath: skipped.path), "skipped boost creates no file")

        let stereoQuiet = root.appendingPathComponent("stereo-quiet.wav")
        let stereoFormat = AVAudioFormat(standardFormatWithSampleRate: 16_000, channels: 2)!
        let stereoPCM = AVAudioPCMBuffer(pcmFormat: stereoFormat, frameCapacity: 1024)!
        stereoPCM.frameLength = stereoPCM.frameCapacity
        for index in 0..<1024 {
            stereoPCM.floatChannelData![0][index] = 0.003
            stereoPCM.floatChannelData![1][index] = -0.006
        }
        var stereoSettings = stereoFormat.settings
        stereoSettings[AVLinearPCMIsNonInterleaved] = false
        try autoreleasepool {
            let stereoFile = try AVAudioFile(forWriting: stereoQuiet, settings: stereoSettings)
            try stereoFile.write(from: stereoPCM)
            if #available(macOS 15, *) { stereoFile.close() }
        }
        check(try AudioFiles.boosted(stereoQuiet, to: boosted) == boosted, "quiet float WAV gets boosted")
        let stereoResult = try AVAudioFile(forReading: boosted)
        check(stereoResult.fileFormat.commonFormat == .pcmFormatInt16 && stereoResult.length == 1024
              && stereoResult.fileFormat.channelCount == 2, "float input becomes 16-bit with channels and length preserved")
        if #available(macOS 15, *) { stereoResult.close() }
        let stereoBoosted = try readPCM(boosted)
        check((0..<1024).allSatisfy {
            abs(Int(stereoBoosted[$0 * 2]) - 3920) <= 40
                && abs(Int(stereoBoosted[$0 * 2 + 1]) + 7880) <= 40
        }, "boost processes every interleaved sample in both channels")

        // A stereo 44.1 kHz source proves channel conversion and resampling rather than copying.
        let source = root.appendingPathComponent("stereo.wav")
        let format = AVAudioFormat(standardFormatWithSampleRate: 44_100, channels: 2)!
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 44_100)!
        buffer.frameLength = buffer.frameCapacity
        for channel in 0..<2 {
            for index in 0..<Int(buffer.frameLength) {
                buffer.floatChannelData![channel][index] = Float(sin(Double(index) * 2 * .pi * 440 / 44_100)) * 0.2
            }
        }
        try autoreleasepool {
            let sourceFile = try AVAudioFile(forWriting: source, settings: [AVFormatIDKey: kAudioFormatLinearPCM,
                AVSampleRateKey: 44_100, AVNumberOfChannelsKey: 2, AVLinearPCMBitDepthKey: 16,
                AVLinearPCMIsFloatKey: false, AVLinearPCMIsNonInterleaved: false])
            try sourceFile.write(from: buffer)
            if #available(macOS 15, *) { sourceFile.close() }
        }
        let created = Date(timeIntervalSince1970: 1_700_000_000)
        try manager.setAttributes([.creationDate: created], ofItemAtPath: source.path)
        let record = try AudioFiles.importRecording(from: source, lecture: " Test/Lecture ", session: " Session ", paths: paths)
        check(record.status == .failed && record.error == nil, "import is retryable without error")
        check(record.lecture == "Test-Lecture" && record.session == "Session", "import names sanitized")
        check(abs(record.startedAt.timeIntervalSince(created)) < 1, "source creation date preserved")
        check(abs(record.endedAt!.timeIntervalSince(record.startedAt) - 1) < 0.01, "import end uses decoded duration")
        check(try SessionRecord.read(paths.audioFile(record.id, "json")) == record, "import saves sidecar")
        let wav = try AudioFiles.decodeToWAV(id: record.id, paths: paths)
        let imported = try AVAudioFile(forReading: wav)
        check(imported.fileFormat.sampleRate == 16_000 && imported.fileFormat.channelCount == 1
              && imported.fileFormat.commonFormat == .pcmFormatInt16, "import is 16 kHz mono Int16")
        check(abs(Core.audioDuration(id: record.id, paths: paths) - 1) < 0.01, "resampled duration")
        check(!manager.fileExists(atPath: paths.audioFile(record.id, "pcm").path), "import finalizes PCM")
        let m4a = paths.audioFile(record.id, "m4a")
        var aacFormat = kAudioFormatMPEG4AAC
        var encoderSize: UInt32 = 0
        let aacAvailable = AudioFormatGetPropertyInfo(kAudioFormatProperty_Encoders, 4, &aacFormat, &encoderSize) == noErr && encoderSize > 0
        if aacAvailable {
            try AudioFiles.compress(id: record.id, paths: paths)
            check(!manager.fileExists(atPath: wav.path), "verified compression removes WAV")
        } else {
            rejects("unavailable encoder must fail compression") { try AudioFiles.compress(id: record.id, paths: paths) }
            check(manager.fileExists(atPath: wav.path), "unavailable encoder preserves WAV")
            // The sandbox blocks AudioComponentRegistrar. A real PCM-in-M4A container
            // still exercises container decoding and the m4a-only Retry branch.
            try autoreleasepool {
                let input = try AVAudioFile(forReading: wav)
                let output = try AVAudioFile(forWriting: m4a, settings: input.fileFormat.settings)
                let chunk = AVAudioPCMBuffer(pcmFormat: input.processingFormat, frameCapacity: 8192)!
                while input.framePosition < input.length {
                    try input.read(into: chunk)
                    try output.write(from: chunk)
                }
                if #available(macOS 15, *) { output.close() }
            }
            try manager.removeItem(at: wav)
            print("AAC SKIPPED: sandbox exposes no AAC codecs; testing WAV preservation and real PCM-in-M4A Retry instead.")
        }
        let compressed = try AVAudioFile(forReading: m4a)
        check(compressed.length > 0 && compressed.processingFormat.channelCount == 1, "M4A is readable mono")
        check(abs(Core.audioDuration(id: record.id, paths: paths) - 1) < 0.1, "compressed duration supported")
        let decoded = try AudioFiles.decodeToWAV(id: record.id, paths: paths)
        let retryAudio = try AVAudioFile(forReading: decoded)
        check(retryAudio.fileFormat.sampleRate == 16_000 && retryAudio.fileFormat.commonFormat == .pcmFormatInt16, "compressed Retry decodes to PCM WAV")
        check(manager.fileExists(atPath: m4a.path), "decode preserves compressed original")
        let reimported = try AudioFiles.importRecording(from: m4a, lecture: "M4A", session: "Container", paths: paths)
        check(reimported.status == .failed && abs(Core.audioDuration(id: reimported.id, paths: paths) - 1) < 0.1, "import from M4A container")
        try Data("no audio".utf8).write(to: root.appendingPathComponent("text.txt"))
        do {
            _ = try AudioFiles.importRecording(from: root.appendingPathComponent("text.txt"), lecture: "Test", session: "No audio", paths: paths)
            fatalError("non-audio accepted")
        } catch { check(error is LectureError && error.localizedDescription.contains("audio track"), "clear no-audio error") }
        try Data([0, 0, 0, 0]).write(to: paths.audioFile("raw", "pcm"))
        check(try Core.fileSize(AudioFiles.decodeToWAV(id: "raw", paths: paths)) == 48, "raw recovery path")
        try Data("invalid WAV".utf8).write(to: paths.audioFile("bad", "wav"))
        rejects("compression of invalid WAV fails") { try AudioFiles.compress(id: "bad", paths: paths) }
        check(manager.fileExists(atPath: paths.audioFile("bad", "wav").path), "compression failure preserves WAV")

        var transcriptRecord = record
        let transcript = paths.lectureFolder(record.lecture).appendingPathComponent("Session.md")
        transcriptRecord.transcriptPath = transcript.deletingLastPathComponent().appendingPathComponent("sub/../Session.md").path
        try transcriptRecord.save(in: paths)
        check(Core.record(forTranscript: transcript, paths: paths)?.id == record.id, "transcript lookup standardizes paths")
        check(Core.record(forTranscript: root.appendingPathComponent("unknown.md"), paths: paths) == nil, "unknown transcript lookup")
        var records: [SessionRecord] = []
        for (offset, status) in [RecordStatus.failed, .recording, .transcribing, .done, .failed].enumerated() {
            let id = "unfinished-\(offset)"
            let r = SessionRecord(id: id, lecture: "Test", session: "Session", startedAt: Date(timeIntervalSince1970: Double(offset)),
                                  status: status, dismissed: true)
            try r.save(in: rehearsal)
            if offset != 4 { try Data([0]).write(to: rehearsal.audioFile(id, ["pcm", "wav", "m4a"][offset % 3])) }
            records.append(r)
        }
        check(Core.unfinished(paths: rehearsal).map(\.id) == [records[2].id, records[1].id, records[0].id], "unfinished includes dismissed, requires audio, sorts newest first")
        check(Core.recoveryCandidates(records).isEmpty, "dismissal still hides automatic recovery")
        let now = Date()
        var old = records[3]
        old.startedAt = now.addingTimeInterval(-8 * 86_400)
        try old.save(in: rehearsal)
        try Data([0]).write(to: rehearsal.audioFile(old.id, "m4a"))
        try Core.applyRetention(paths: rehearsal, now: now)
        check(!manager.fileExists(atPath: rehearsal.audioFile(old.id, "m4a").path)
              && !manager.fileExists(atPath: rehearsal.audioFile(old.id, "json").path), "retention deletes M4A and sidecar")
        check(manager.fileExists(atPath: rehearsal.audioFile(records[2].id, "m4a").path), "retention preserves unfinished compressed audio")
        let id = Core.newID(in: paths, now: now)
        try Data([0]).write(to: paths.audioFile(id, "m4a"))
        check(Core.newID(in: paths, now: now) != id, "new ID avoids orphan M4A collision")
        check(try manager.contentsOfDirectory(at: paths.audio, includingPropertiesForKeys: nil)
            .allSatisfy { !$0.lastPathComponent.hasPrefix(".") }, "audio temp files removed")
        print("BACKEND PASS: \(assertions) assertions (audio boost/import/compression/Retry, model validation/install, rehearsal, recovery, setup, retention)")
    }
}
