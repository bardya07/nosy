import AVFoundation
import Foundation
import IOKit.ps

enum LectureError: LocalizedError, Sendable {
    case message(String)
    var errorDescription: String? { if case .message(let text) = self { return text }; return nil }
}

struct AppPaths: Sendable {
    let transcripts: URL
    let support: URL
    let whisperOverride: String?
    let usesDefaultSupport: Bool
    private let engineBundle: URL
    private let engineSearchPath: String
    private let retentionOverride: Int?
    private let modelOverride: URL?
    private let vadModelOverride: URL?
    // Days to keep audio after a successful transcript; 0 keeps it forever. Read live, so a
    // change in Settings applies even to a transcription that started before it.
    var retentionDays: Int {
        max(0, retentionOverride ?? UserDefaults.standard.object(forKey: AppPaths.retentionKey) as? Int ?? 14)
    }

    static let transcriptsKey = "transcriptsFolder"
    static let retentionKey = "retentionDays"

    init(environment: [String: String] = ProcessInfo.processInfo.environment,
         home: URL = FileManager.default.homeDirectoryForCurrentUser,
         transcriptsFolder: String? = UserDefaults.standard.string(forKey: AppPaths.transcriptsKey),
         retentionDays: Int? = nil,
         bundleURL: URL = Bundle.main.bundleURL) {
        transcripts = environment["NOSY_TRANSCRIPTS_DIR"].map { URL(fileURLWithPath: $0, isDirectory: true) }
            ?? transcriptsFolder.map { URL(fileURLWithPath: $0, isDirectory: true) }
            ?? Self.defaultTranscripts(home: home)
        retentionOverride = retentionDays
        modelOverride = nil
        vadModelOverride = nil
        support = environment["NOSY_SUPPORT_DIR"].map { URL(fileURLWithPath: $0, isDirectory: true) }
            ?? home.appendingPathComponent("Library/Application Support/Nosy", isDirectory: true)
        whisperOverride = environment["NOSY_WHISPER_CLI"]
        engineBundle = bundleURL
        engineSearchPath = environment["PATH"] ?? ""
        usesDefaultSupport = environment["NOSY_SUPPORT_DIR"] == nil
    }

    // People who used Lecture Transcriber keep their Desktop folder; everyone else gets ~/Documents/Nosy.
    static func defaultTranscripts(home: URL) -> URL {
        let legacy = home.appendingPathComponent("Desktop/Lecture Transcripts", isDirectory: true)
        var isDirectory: ObjCBool = false
        if FileManager.default.fileExists(atPath: legacy.path, isDirectory: &isDirectory), isDirectory.boolValue { return legacy }
        return home.appendingPathComponent("Documents/Nosy", isDirectory: true)
    }
    var audio: URL { support.appendingPathComponent("audio", isDirectory: true) }
    var model: URL { modelOverride ?? support.appendingPathComponent("models/ggml-large-v3-turbo.bin") }
    var vadModel: URL { vadModelOverride ?? support.appendingPathComponent("models/ggml-silero-v5.1.2.bin") }
    func rehearsal(in directory: URL) -> AppPaths {
        AppPaths(rehearsal: directory, original: self)
    }
    private init(rehearsal directory: URL, original: AppPaths) {
        support = directory
        transcripts = directory.appendingPathComponent("transcripts", isDirectory: true)
        modelOverride = original.model
        vadModelOverride = original.vadModel
        whisperOverride = original.whisperOverride
        engineBundle = original.engineBundle
        engineSearchPath = original.engineSearchPath
        retentionOverride = original.retentionOverride
        usesDefaultSupport = false
    }
    var whisper: URL? {
        // Shipped apps are self-contained. Only unbundled development/test
        // executables may use an override or search Homebrew/PATH.
        if engineBundle.pathExtension == "app" {
            let bundled = engineBundle.appendingPathComponent("Contents/Helpers/whisper-cli")
            return FileManager.default.isExecutableFile(atPath: bundled.path) ? bundled : nil
        }
        let choices = whisperOverride.map { [$0] } ?? (engineSearchPath.split(separator: ":")
            .map { URL(fileURLWithPath: String($0)).appendingPathComponent("whisper-cli").path }
            + ["/opt/homebrew/bin/whisper-cli", "/usr/local/bin/whisper-cli"])
        return choices.first(where: { FileManager.default.isExecutableFile(atPath: $0) }).map { URL(fileURLWithPath: $0) }
    }
    var dependencyWarning: String? {
        var missing: [String] = []
        if whisper == nil { missing.append(Core.missingEngineMessage) }
        if !FileManager.default.isReadableFile(atPath: model.path) {
            missing.append("Model missing: \(model.path)")
        }
        return missing.isEmpty ? nil : missing.joined(separator: "\n")
    }
    func audioFile(_ id: String, _ ext: String) -> URL { audio.appendingPathComponent(id).appendingPathExtension(ext) }
    func prepareSupport() throws {
        try FileManager.default.createDirectory(at: audio, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: support.appendingPathComponent("models"), withIntermediateDirectories: true)
    }
    func lectureFolder(_ name: String) -> URL { transcripts.appendingPathComponent(name, isDirectory: true) }
    func lectures() -> [String] {
        let urls = (try? FileManager.default.contentsOfDirectory(at: transcripts, includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles])) ?? []
        return urls.filter { (try? $0.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true }
            .map(\.lastPathComponent).sorted { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }
    }
}

enum RecordStatus: String, Codable, Sendable { case recording, transcribing, done, failed }

struct SessionMarker: Codable, Sendable, Equatable {
    var t: TimeInterval
    var label = "Marker"

    var displayLabel: String {
        let clean = label.components(separatedBy: .newlines).joined(separator: " ").trimmingCharacters(in: .whitespaces)
        return clean.isEmpty ? "Marker" : clean
    }
    var markdown: String { "> [\(Core.timer(t))] \(displayLabel)" }

    static func parse(_ text: String) -> (timestamp: String, label: String)? {
        guard text.hasPrefix("> ["), let end = text.range(of: "] ") else { return nil }
        let timestamp = String(text[text.index(text.startIndex, offsetBy: 3)..<end.lowerBound])
        let parts = timestamp.split(separator: ":", omittingEmptySubsequences: false)
        guard (2...3).contains(parts.count), parts.allSatisfy({ !$0.isEmpty && $0.allSatisfy(\.isNumber) }) else { return nil }
        return (timestamp, String(text[end.upperBound...]))
    }
}

// whisper.cpp JSON offsets are milliseconds, including when VAD is enabled.
struct TranscriptSegments: Decodable {
    struct Segment: Decodable {
        struct Offsets: Decodable { let from: Int; let to: Int }
        let offsets: Offsets
    }
    let transcription: [Segment]
}

struct SessionRecord: Codable, Sendable, Equatable {
    var id: String
    var lecture: String
    var session: String
    var startedAt: Date
    var endedAt: Date?
    var status: RecordStatus
    var transcriptPath: String?
    var error: String?
    var dismissed: Bool?
    // When the transcript was saved; retention counts from here (imports can have old start dates).
    var transcribedAt: Date?

    var markers: [SessionMarker] = []
    // Terms available to this transcription, frozen so later vocabulary edits do not
    // invent hits for an older lecture. Legacy recordings leave this unknown.
    var vocabularyTerms: [String]?

    // Old sidecars predate markers; keep recovery and Retry compatible with them.
    enum CodingKeys: String, CodingKey {
        case id, lecture, session, startedAt, endedAt, status, transcriptPath, error, dismissed, transcribedAt, markers, vocabularyTerms
    }

    func save(in paths: AppPaths) throws {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(self).write(to: paths.audioFile(id, "json"), options: .atomic)
    }
    static func read(_ url: URL) throws -> SessionRecord {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let record = try decoder.decode(SessionRecord.self, from: Data(contentsOf: url))
        guard record.id == url.deletingPathExtension().lastPathComponent,
              !record.id.contains("/"), !record.id.contains("..") else {
            throw LectureError.message("Invalid recording sidecar: \(url.lastPathComponent)")
        }
        return record
    }
}

extension SessionRecord {
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        lecture = try c.decode(String.self, forKey: .lecture)
        session = try c.decode(String.self, forKey: .session)
        startedAt = try c.decode(Date.self, forKey: .startedAt)
        status = try c.decode(RecordStatus.self, forKey: .status)
        endedAt = try c.decodeIfPresent(Date.self, forKey: .endedAt)
        transcriptPath = try c.decodeIfPresent(String.self, forKey: .transcriptPath)
        error = try c.decodeIfPresent(String.self, forKey: .error)
        dismissed = try c.decodeIfPresent(Bool.self, forKey: .dismissed)
        transcribedAt = try c.decodeIfPresent(Date.self, forKey: .transcribedAt)
        markers = try c.decodeIfPresent([SessionMarker].self, forKey: .markers) ?? []
        vocabularyTerms = try c.decodeIfPresent([String].self, forKey: .vocabularyTerms)
        guard markers.allSatisfy({ $0.t.isFinite && $0.t >= 0 && $0.t < Double(Int.max) }) else {
            throw LectureError.message("Invalid marker timestamp in recording sidecar.")
        }
    }
}

enum Core {
    static func spokenText(_ markdown: String) -> String {
        let body = markdown.range(of: "## Transcript").map { String(markdown[$0.upperBound...]) } ?? markdown
        return body
            .components(separatedBy: .newlines).filter { SessionMarker.parse($0) == nil }
            .joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
    }
    static func wordCount(_ markdown: String) -> Int {
        let speech = spokenText(markdown)
        return speech == "_No speech detected._" ? 0 : speech.split(whereSeparator: { $0.isWhitespace }).count
    }
    static let bytesPerSecond: Int64 = 32_000
    static let missingEngineMessage = "whisper-cli is missing from Nosy. Reinstall Nosy, then Retry — your audio is safe."

    static func stressReason(thermal: ProcessInfo.ThermalState, onBattery: Bool, percent: Double?) -> String? {
        if thermal == .serious || thermal == .critical { return "Mac is hot" }
        if onBattery, let percent, percent >= 0, percent < 20 { return "battery low" }
        return nil
    }

    static func powerState() -> (onBattery: Bool, percent: Double?) {
        guard let info = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
              let sources = IOPSCopyPowerSourcesList(info)?.takeRetainedValue() as? [CFTypeRef] else { return (false, nil) }
        for source in sources {
            guard let description = IOPSGetPowerSourceDescription(info, source)?.takeUnretainedValue() as? [String: Any],
                  description[kIOPSTypeKey] as? String == kIOPSInternalBatteryType else { continue }
            let onBattery = description[kIOPSPowerSourceStateKey] as? String == kIOPSBatteryPowerValue
            guard let current = description[kIOPSCurrentCapacityKey] as? Double,
                  let maximum = description[kIOPSMaxCapacityKey] as? Double, maximum > 0 else { return (onBattery, nil) }
            return (onBattery, current / maximum * 100)
        }
        return (false, nil)
    }

    static func setupMessage(paths: AppPaths) -> String? {
        var messages: [String] = []
        if paths.whisper == nil {
            messages.append(missingEngineMessage)
        }
        if !FileManager.default.isReadableFile(atPath: paths.model.path) {
            messages.append("Nosy needs its speech model (1.6 GB) before it can transcribe.")
        }
        return messages.isEmpty ? nil : messages.joined(separator: "\n")
    }

    static func migrateLegacy(
        paths: AppPaths,
        legacySupport: URL = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/Lecture Transcriber", isDirectory: true),
        defaults: UserDefaults = .standard,
        legacyDefaults: UserDefaults? = UserDefaults(suiteName: "com.bardya.lecturetranscriber")
    ) throws {
        guard paths.usesDefaultSupport else { return }
        for key in ["lastLecture", "requestedNotifications"] where defaults.object(forKey: key) == nil {
            if let value = legacyDefaults?.object(forKey: key) { defaults.set(value, forKey: key) }
        }
        let manager = FileManager.default
        guard manager.fileExists(atPath: legacySupport.path) else { return }
        if !manager.fileExists(atPath: paths.support.path) {
            try manager.createDirectory(at: paths.support.deletingLastPathComponent(), withIntermediateDirectories: true)
            try manager.moveItem(at: legacySupport, to: paths.support)
            return
        }
        // Merge only immediate model/audio files. Existing files and all other legacy data stay put.
        for directory in ["models", "audio"] {
            let source = legacySupport.appendingPathComponent(directory, isDirectory: true)
            guard manager.fileExists(atPath: source.path) else { continue }
            let destination = paths.support.appendingPathComponent(directory, isDirectory: true)
            let files = try manager.contentsOfDirectory(at: source, includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey])
            for file in files {
                let attributes = try file.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
                guard attributes.isRegularFile == true || attributes.isSymbolicLink == true else { continue }
                let target = destination.appendingPathComponent(file.lastPathComponent)
                // attributesOfItem also detects dangling symlinks, which must never be replaced.
                guard (try? manager.attributesOfItem(atPath: target.path)) == nil else { continue }
                try manager.createDirectory(at: destination, withIntermediateDirectories: true)
                try manager.moveItem(at: file, to: target)
            }
        }
    }

    static func parseProgress(_ chunk: String) -> Double? {
        let pattern = #"(?<![\d.])([+-]?\d+(?:\.\d+)?)\s*%"#
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let match = regex.matches(in: chunk, range: NSRange(chunk.startIndex..., in: chunk)).last,
              let range = Range(match.range(at: 1), in: chunk),
              let percentage = Double(chunk[range]), (0...100).contains(percentage) else { return nil }
        return percentage / 100
    }

    static func friendlyError(_ raw: String) -> String {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        let text = trimmed.lowercased()
        func contains(_ fragments: [String]) -> Bool { fragments.contains { text.contains($0) } }
        if contains(["enospc", "no space left", "disk full", "disk is full", "not enough space", "not enough free space", "errno 28", "code=28", "nscocoaerrordomain code=640", "nscocoaerrordomain error 640"]) {
            return "Your disk is full. Free up some space, then Retry — your saved audio is safe."
        }
        if text.contains("whisper-cli"), !text.contains("whisper-cli exited"),
           contains(["missing", "not found", "no such file", "does not exist", "doesn’t exist", "doesn't exist"]) {
            return "Nosy's speech engine is missing. Reinstall Nosy, then Retry — your audio is safe."
        }
        if contains(["model missing", "missing model", "model is missing", "model not found", "failed to open model", "failed to load model"])
            || (text.contains("model") && contains(["no such file", "does not exist", "not been downloaded"])) {
            return "The speech model hasn't been downloaded yet. Your audio is safe — Retry once it's ready."
        }
        if text.contains("whisper"), contains(["exited", "exit code", "exit status"]) {
            return "Transcription hit a snag. Your audio is safe — try Retry."
        }
        if text.contains("microphone"), !contains(["save", "write", "file"]), contains(["denied", "permission", "not authorized"]) {
            return "Nosy can't access your microphone. Allow access in System Settings, then try again."
        }
        if contains(["microphone changed", "device changed", "device change", "microphone disconnected", "device disconnected"]) {
            return "Your microphone changed or disconnected. Check your input, then start a new recording — your saved audio is safe."
        }
        if contains(["could not save", "couldn't save", "failed to save", "error saving", "could not write", "failed to write", "error writing", "could not create recording file", "could not create transcription log file", "could not finalize wav", "file write", "write failed", "couldn’t be saved", "couldn't be saved", "could not be saved", "permission denied", "nscocoaerrordomain code=513"]) {
            return "Nosy couldn't save the file. Check the folder's permissions and available space, then Retry."
        }
        if contains(["microphone", "audio conversion", "audio input", "could not start audio", "avfaudio"]) {
            return "Nosy couldn't record from your microphone. Check your input and try again — your saved audio is safe."
        }
        if text.contains("app closed unexpectedly") {
            return "Nosy closed before this lecture finished. Your audio is safe — click Retry to transcribe it."
        }
        if text.contains("quit before transcription") {
            return "Nosy quit before transcription finished. Your audio is safe — click Retry."
        }
        return String(trimmed.prefix(160))
    }

    static func sanitize(_ value: String) throws -> String {
        let forbidden = CharacterSet(charactersIn: "/\\:*?\"<>|").union(.controlCharacters)
        let replaced = String(String.UnicodeScalarView(value.trimmingCharacters(in: .whitespacesAndNewlines).unicodeScalars.map {
            forbidden.contains($0) ? UnicodeScalar(45)! : $0
        }))
        let result = String(collapseWhitespace(replaced).prefix(80)).trimmingCharacters(in: .whitespaces)
        guard !result.isEmpty, result.contains(where: { $0 != "." }) else {
            throw LectureError.message("Enter a lecture and session name; names cannot be empty or only dots.")
        }
        return result
    }

    static func collapseWhitespace(_ value: String) -> String {
        value.split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
    }
    static func dateString(_ date: Date, format: String) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = format
        return formatter.string(from: date)
    }
    static func newID(in paths: AppPaths, now: Date = Date()) -> String {
        var candidate = now
        while true {
            let id = dateString(candidate, format: "yyyyMMdd-HHmmss")
            if !["pcm", "wav", "m4a", "json"].contains(where: { FileManager.default.fileExists(atPath: paths.audioFile(id, $0).path) }) { return id }
            candidate = candidate.addingTimeInterval(1)
        }
    }
    static func uniqueTranscript(in folder: URL, session: String) -> URL {
        var number = 1
        while true {
            let name = number == 1 ? session : "\(session)-\(number)"
            let url = folder.appendingPathComponent(name).appendingPathExtension("md")
            if !FileManager.default.fileExists(atPath: url.path) { return url }
            number += 1
        }
    }
    // Publish a complete file atomically, using a hard link to guarantee no overwrite.
    static func writeTranscript(_ markdown: String, folder: URL, session: String) throws -> URL {
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let temporary = folder.appendingPathComponent(".\(UUID().uuidString).tmp")
        try Data(markdown.utf8).write(to: temporary, options: .atomic)
        defer { try? FileManager.default.removeItem(at: temporary) }
        while true {
            let target = uniqueTranscript(in: folder, session: session)
            do { try FileManager.default.linkItem(at: temporary, to: target); return target }
            catch {
                if FileManager.default.fileExists(atPath: target.path) { continue }
                // Some drives (exFAT, network shares) can't hard-link; create exclusively instead.
                if try exclusiveWrite(Data(markdown.utf8), to: target) { return target }
            }
        }
    }
    // Writes only if nothing exists at `url`; false means another file took the name first.
    static func exclusiveWrite(_ data: Data, to url: URL) throws -> Bool {
        let descriptor = open(url.path, O_WRONLY | O_CREAT | O_EXCL, 0o644)
        if descriptor < 0 {
            if errno == EEXIST { return false }
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno))
        }
        let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
        do {
            try handle.write(contentsOf: data)
            try handle.synchronize()
        } catch {
            try? FileManager.default.removeItem(at: url)
            throw error
        }
        return true
    }
    static func fileSize(_ url: URL) -> Int64 {
        ((try? FileManager.default.attributesOfItem(atPath: url.path)[.size]) as? NSNumber)?.int64Value ?? 0
    }
    static func duration(pcmBytes: Int64) -> TimeInterval { Double(max(0, pcmBytes)) / Double(bytesPerSecond) }
    static func audioDuration(id: String, paths: AppPaths) -> TimeInterval {
        let pcm = paths.audioFile(id, "pcm")
        if FileManager.default.fileExists(atPath: pcm.path) { return duration(pcmBytes: fileSize(pcm)) }
        let wav = paths.audioFile(id, "wav")
        if FileManager.default.fileExists(atPath: wav.path) { return duration(pcmBytes: max(0, fileSize(wav) - 44)) }
        if let audio = try? AVAudioFile(forReading: paths.audioFile(id, "m4a")), audio.processingFormat.sampleRate > 0 {
            return Double(audio.length) / audio.processingFormat.sampleRate
        }
        return 0
    }
    static func minutes(_ seconds: TimeInterval) -> Int { max(1, Int((seconds / 60).rounded())) }
    static func timer(_ seconds: TimeInterval) -> String {
        let n = max(0, Int(seconds))
        return n >= 3600 ? String(format: "%d:%02d:%02d", n / 3600, (n / 60) % 60, n % 60)
            : String(format: "%d:%02d", n / 60, n % 60)
    }
    static func reminderTime(_ seconds: TimeInterval) -> String {
        let n = max(0, Int(seconds))
        return String(format: "%d:%02d", n / 3600, (n / 60) % 60)
    }
    static func wavHeader(pcmBytes: Int64) throws -> Data {
        guard pcmBytes >= 0, pcmBytes <= Int64(UInt32.max) - 36, pcmBytes % 2 == 0 else {
            throw LectureError.message("Recording is too large for WAV, or has an incomplete PCM sample. Raw audio is kept.")
        }
        var data = Data()
        func ascii(_ string: String) { data.append(contentsOf: string.utf8) }
        func u16(_ value: UInt16) { var v = value.littleEndian; withUnsafeBytes(of: &v) { data.append(contentsOf: $0) } }
        func u32(_ value: UInt32) { var v = value.littleEndian; withUnsafeBytes(of: &v) { data.append(contentsOf: $0) } }
        ascii("RIFF"); u32(UInt32(pcmBytes) + 36); ascii("WAVEfmt "); u32(16)
        u16(1); u16(1); u32(16_000); u32(32_000); u16(2); u16(16)
        ascii("data"); u32(UInt32(pcmBytes))
        return data
    }
    @discardableResult static func finalizeWAV(id: String, paths: AppPaths) throws -> URL {
        let pcm = paths.audioFile(id, "pcm")
        let wav = paths.audioFile(id, "wav")
        guard FileManager.default.fileExists(atPath: pcm.path) else {
            guard FileManager.default.fileExists(atPath: wav.path) else { throw LectureError.message("Recorded audio is missing.") }
            return wav
        }
        let source = try FileHandle(forReadingFrom: pcm)
        defer { try? source.close() }
        // A process can die during a sample write; preserve every complete sample.
        let size = fileSize(pcm) / 2 * 2
        let temporary = paths.audio.appendingPathComponent(".\(id)-\(UUID().uuidString).wav")
        defer { try? FileManager.default.removeItem(at: temporary) }
        try wavHeader(pcmBytes: size).write(to: temporary)
        let output = try FileHandle(forWritingTo: temporary)
        do {
            try output.seekToEnd()
            var remaining = size
            while remaining > 0 {
                let chunk = try source.read(upToCount: Int(min(remaining, 1_048_576))) ?? Data()
                guard !chunk.isEmpty else { throw LectureError.message("PCM file ended unexpectedly; raw audio is kept.") }
                try output.write(contentsOf: chunk)
                remaining -= Int64(chunk.count)
            }
            try output.synchronize()
            try output.close()
        } catch { try? output.close(); throw error }
        // rename is atomic, including replacement of a WAV left by an interrupted finalization.
        let result = temporary.path.withCString { from in wav.path.withCString { to in rename(from, to) } }
        guard result == 0 else { throw LectureError.message("Could not finalize WAV (errno \(errno)); raw audio is kept.") }
        try FileManager.default.removeItem(at: pcm)
        return wav
    }
    static func paragraphs(_ text: String) -> String {
        let markers = Set(["blank_audio", "blank audio", "music", "silence", "no speech", "no speech detected", "applause", "laughter", "inaudible", "noise", "background noise"])
        var paragraphs: [String] = []
        var current = ""
        for raw in text.components(separatedBy: .newlines) {
            let line = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            if line.isEmpty { continue }
            if ((line.hasPrefix("[") && line.hasSuffix("]")) || (line.hasPrefix("(") && line.hasSuffix(")"))),
               markers.contains(String(line.dropFirst().dropLast()).trimmingCharacters(in: .whitespaces).lowercased()) { continue }
            current += (current.isEmpty ? "" : " ") + line
            if current.count >= 600, let last = line.last, ".?!".contains(last) {
                paragraphs.append(current); current = ""
            }
        }
        if !current.isEmpty { paragraphs.append(current) }
        return paragraphs.isEmpty ? "_No speech detected._" : paragraphs.joined(separator: "\n\n")
    }
    // Insert only at segment boundaries, retaining the normal paragraph formatter for speech.
    // The final segment end is also a boundary, so a marker near Stop follows the speech.
    static func markedParagraphs(_ text: String, markers: [SessionMarker], segments: TranscriptSegments) throws -> String {
        guard !markers.isEmpty else { return paragraphs(text) }
        var lines = text.components(separatedBy: "\n")
        if lines.last == "" { lines.removeLast() }
        let times = segments.transcription
        guard times.count == lines.count || (times.isEmpty && text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty),
              times.allSatisfy({ $0.offsets.from >= 0 && $0.offsets.to >= $0.offsets.from }) else {
            throw LectureError.message("Could not match marker timestamps to transcript segments. Your recording and markers are kept; try Retry.")
        }
        let boundaries = times.enumerated().flatMap {
            [(line: $0.offset, t: Double($0.element.offsets.from) / 1000),
             (line: $0.offset + 1, t: Double($0.element.offsets.to) / 1000)]
        }
        var insertions: [Int: [SessionMarker]] = [:]
        for item in markers.enumerated().sorted(by: { $0.element.t == $1.element.t ? $0.offset < $1.offset : $0.element.t < $1.element.t }) {
            let marker = item.element
            let nearest = boundaries.min { abs($0.t - marker.t) < abs($1.t - marker.t) }?.line ?? 0
            insertions[nearest, default: []].append(marker)
        }
        var chunks: [String] = [], start = 0
        for boundary in insertions.keys.sorted() {
            let speech = paragraphs(lines[start..<boundary].joined(separator: "\n"))
            if speech != "_No speech detected._" { chunks.append(speech) }
            chunks += insertions[boundary]!.map(\.markdown)
            start = boundary
        }
        let tail = paragraphs(lines[start...].joined(separator: "\n"))
        if tail != "_No speech detected._" { chunks.append(tail) }
        if paragraphs(text) == "_No speech detected._" { chunks.append("_No speech detected._") }
        return chunks.joined(separator: "\n\n")
    }
    static func markdown(record: SessionRecord, duration: TimeInterval, text: String, body: String? = nil) -> String {
        """
        # \(record.lecture) — \(record.session)

        - Date: \(dateString(record.startedAt, format: "yyyy-MM-dd"))
        - Started: \(dateString(record.startedAt, format: "HH:mm"))
        - Length: \(minutes(duration)) min

        ## Transcript

        \(body ?? paragraphs(text))

        """
    }
    static func records(in paths: AppPaths) -> [SessionRecord] {
        let urls = (try? FileManager.default.contentsOfDirectory(at: paths.audio, includingPropertiesForKeys: nil)) ?? []
        return urls.filter { $0.pathExtension == "json" }.compactMap { try? SessionRecord.read($0) }
            .sorted { $0.startedAt > $1.startedAt }
    }
    static func record(forTranscript url: URL, paths: AppPaths) -> SessionRecord? {
        records(in: paths).first {
            guard let path = $0.transcriptPath else { return false }
            return URL(fileURLWithPath: path).standardizedFileURL.path == url.standardizedFileURL.path
        }
    }
    static func unfinished(paths: AppPaths) -> [SessionRecord] {
        records(in: paths).filter { record in
            record.status != .done && ["pcm", "wav", "m4a"].contains {
                FileManager.default.fileExists(atPath: paths.audioFile(record.id, $0).path)
            }
        }
    }
    static func retentionCandidates(_ records: [SessionRecord], now: Date = Date(), days: Int = 14) -> [SessionRecord] {
        guard days > 0 else { return [] }
        return records.filter { $0.status == .done && ($0.transcribedAt ?? $0.startedAt) < now.addingTimeInterval(-Double(days) * 86_400) }
    }
    static func applyRetention(paths: AppPaths, now: Date = Date()) throws {
        for record in retentionCandidates(records(in: paths), now: now, days: paths.retentionDays) {
            let files = try FileManager.default.contentsOfDirectory(at: paths.audio, includingPropertiesForKeys: nil)
            for url in files where url.lastPathComponent.hasPrefix(record.id + ".") {
                try FileManager.default.removeItem(at: url)
            }
        }
    }
    static func recoveryCandidates(_ records: [SessionRecord]) -> [SessionRecord] {
        records.filter { $0.dismissed != true && ($0.status == .recording || $0.status == .transcribing || $0.status == .failed) }
            .sorted { $0.startedAt > $1.startedAt }
    }
    static func recover(paths: AppPaths) throws -> [SessionRecord] {
        var recovered: [SessionRecord] = []
        for var record in recoveryCandidates(records(in: paths)) {
            let unfinished = record.status == .recording || record.status == .transcribing
            do {
                if FileManager.default.fileExists(atPath: paths.audioFile(record.id, "pcm").path) {
                    try finalizeWAV(id: record.id, paths: paths)
                }
                if unfinished {
                    record.status = .failed
                    record.error = "App closed unexpectedly"
                    record.endedAt = record.endedAt ?? Date()
                    try record.save(in: paths)
                }
            } catch {
                record.status = .failed
                record.error = "App closed unexpectedly. \(error.localizedDescription)"
                try record.save(in: paths)
            }
            recovered.append(record)
        }
        return recovered
    }
    static func availableDiskSpace(at url: URL) throws -> Int64 {
        let attributes = try FileManager.default.attributesOfFileSystem(forPath: url.path)
        return (attributes[.systemFreeSize] as? NSNumber)?.int64Value ?? 0
    }
}
