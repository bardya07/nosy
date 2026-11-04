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
    #if NOSY_UI_TEST
    private var testModelValidation: (@Sendable (URL) -> Bool)? = nil
    mutating func useTestModelValidation(_ validate: @escaping @Sendable (URL) -> Bool) { testModelValidation = validate }
    #endif
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

    static let dedicatedFolderName = "Nosy Transcripts"
    // A chosen location gets its own "Nosy Transcripts" folder, so picking ~/Downloads never mixes
    // transcripts with the owner's files. A folder that already is a Nosy library is used as is.
    static func dedicatedTranscripts(for chosen: URL, home: URL = FileManager.default.homeDirectoryForCurrentUser) -> URL {
        let folder = chosen.standardizedFileURL
        let known = [home.appendingPathComponent("Desktop/Lecture Transcripts"), home.appendingPathComponent("Documents/Nosy")]
            .map { $0.standardizedFileURL.path }
        if folder.lastPathComponent == dedicatedFolderName || known.contains(folder.path) || Core.containsTranscripts(folder) {
            return folder
        }
        return folder.appendingPathComponent(dedicatedFolderName, isDirectory: true)
    }
    // People who used Lecture Transcriber keep their Desktop folder; everyone else gets ~/Documents/Nosy.
    static func defaultTranscripts(home: URL) -> URL {
        let legacy = home.appendingPathComponent("Desktop/Lecture Transcripts", isDirectory: true)
        var isDirectory: ObjCBool = false
        if FileManager.default.fileExists(atPath: legacy.path, isDirectory: &isDirectory), isDirectory.boolValue { return legacy }
        return home.appendingPathComponent("Documents/Nosy", isDirectory: true)
    }
    var audio: URL { support.appendingPathComponent("audio", isDirectory: true) }
    func browsingLibrary(at folder: URL) -> AppPaths { AppPaths(transcripts: folder, original: self) }
    private init(transcripts: URL, original: AppPaths) {
        self.transcripts = transcripts
        support = original.support
        whisperOverride = original.whisperOverride
        usesDefaultSupport = original.usesDefaultSupport
        engineBundle = original.engineBundle
        engineSearchPath = original.engineSearchPath
        retentionOverride = original.retentionOverride
        modelOverride = original.modelOverride
        #if NOSY_UI_TEST
        testModelValidation = original.testModelValidation
        #endif
        vadModelOverride = original.vadModelOverride
    }
    static func libraryLocations(current: URL, previous: [String], home: URL = FileManager.default.homeDirectoryForCurrentUser) -> [URL] {
        let candidates = [current] + previous.map { URL(fileURLWithPath: $0, isDirectory: true) }
            + [home.appendingPathComponent("Desktop/Lecture Transcripts"), home.appendingPathComponent("Documents/Nosy")]
        var seen = Set<String>()
        return candidates.filter { url in
            guard seen.insert(url.resolvingSymlinksInPath().standardizedFileURL.path).inserted else { return false }
            return url == current || Core.containsTranscripts(url)
        }
    }
    var model: URL { modelOverride ?? support.appendingPathComponent("models/ggml-large-v3-turbo.bin") }
    var vadModel: URL { vadModelOverride ?? support.appendingPathComponent("models/ggml-silero-v5.1.2.bin") }
    func rehearsal(in directory: URL) -> AppPaths {
        AppPaths(rehearsal: directory, original: self)
    }
    private init(rehearsal directory: URL, original: AppPaths) {
        support = directory
        transcripts = directory.appendingPathComponent("transcripts", isDirectory: true)
        modelOverride = original.model
        #if NOSY_UI_TEST
        testModelValidation = original.testModelValidation
        #endif
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
        #if NOSY_UI_TEST
        let modelValid = testModelValidation?(model) ?? SpeechModel.validate(model)
        #else
        let modelValid = SpeechModel.validate(model)
        #endif
        if !modelValid {
            missing.append("Speech model missing or invalid. Download it again in setup.")
        }
        return missing.isEmpty ? nil : missing.joined(separator: "\n")
    }
    func audioFile(_ id: String, _ ext: String) -> URL { audio.appendingPathComponent(id).appendingPathExtension(ext) }
    // Check every component from the support root without following links. The transcript
    // library may itself be linked, so compare canonical paths in both directions.
    func safeSupportItem(_ url: URL, directory: Bool, checkOverlap: Bool = true) -> Bool {
        let root = support.standardizedFileURL.path
        let path = url.standardizedFileURL.path
        guard path == root || path.hasPrefix(root + "/") else { return false }
        // macOS exposes /tmp and /var as root-owned aliases of /private. Do not
        // follow any other linked ancestor of the configured support directory.
        var ancestor = support.standardizedFileURL.deletingLastPathComponent()
        while ancestor.path != "/" {
            var info = stat()
            guard lstat(ancestor.path, &info) == 0 else { return false }
            if (info.st_mode & S_IFMT) == S_IFLNK {
                let aliases = ["/tmp": "/private/tmp", "/var": "/private/var"]
                guard info.st_uid == 0, let target = aliases[ancestor.path],
                      ancestor.resolvingSymlinksInPath().standardizedFileURL.path == target else { return false }
            } else {
                guard (info.st_mode & S_IFMT) == S_IFDIR,
                      info.st_uid == 0 || info.st_uid == getuid() else { return false }
            }
            ancestor.deleteLastPathComponent()
        }
        let library = transcripts.resolvingSymlinksInPath().standardizedFileURL.path
        let canonical = url.resolvingSymlinksInPath().standardizedFileURL.path
        if checkOverlap {
            guard canonical != library, !canonical.hasPrefix(library + "/"),
                  !library.hasPrefix(canonical + "/") else { return false }
        }
        let suffix = String(path.dropFirst(root.count)).split(separator: "/")
        var current = root
        let components = suffix.map(String.init)
        for index in 0...components.count {
            if index > 0 { current += "/" + components[index - 1] }
            var info = stat()
            guard lstat(current, &info) == 0, info.st_uid == getuid(),
                  (info.st_mode & S_IFMT) != S_IFLNK else { return false }
            if index < components.count || directory {
                guard (info.st_mode & S_IFMT) == S_IFDIR else { return false }
            } else {
                guard (info.st_mode & S_IFMT) == S_IFREG else { return false }
            }
        }
        return true
    }

    // Validate each existing component before creating any missing directory. The
    // support root and everything below it must be owned by the current user.
    func createSupportDirectory(_ url: URL) throws {
        let root = support.standardizedFileURL.path
        let path = url.standardizedFileURL.path
        guard path == root || path.hasPrefix(root + "/") else { throw LectureError.message("Unsafe support storage.") }
        let library = transcripts.resolvingSymlinksInPath().standardizedFileURL.path
        let canonical = url.resolvingSymlinksInPath().standardizedFileURL.path
        guard canonical != library, !canonical.hasPrefix(library + "/"), !library.hasPrefix(canonical + "/") else {
            throw LectureError.message("Unsafe support storage.")
        }
        var current = URL(fileURLWithPath: "/", isDirectory: true)
        for component in url.standardizedFileURL.pathComponents.dropFirst() {
            current.appendPathComponent(component, isDirectory: true)
            var info = stat()
            if lstat(current.path, &info) == 0 {
                if (info.st_mode & S_IFMT) == S_IFLNK {
                    let aliases = ["/tmp": "/private/tmp", "/var": "/private/var"]
                    guard current.path != root, !current.path.hasPrefix(root + "/"),
                          info.st_uid == 0, let target = aliases[current.path],
                          current.resolvingSymlinksInPath().standardizedFileURL.path == target else { throw LectureError.message("Unsafe support storage.") }
                } else {
                    let inside = current.path == root || current.path.hasPrefix(root + "/")
                    guard (info.st_mode & S_IFMT) == S_IFDIR,
                          inside ? info.st_uid == getuid() : (info.st_uid == 0 || info.st_uid == getuid()) else {
                        throw LectureError.message("Unsafe support storage.")
                    }
                }
            } else {
                guard errno == ENOENT else { throw LectureError.message("Unsafe support storage.") }
                // Parent must already have been checked; create one component at a time.
                try FileManager.default.createDirectory(at: current, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
            }
        }
        guard safeSupportItem(url, directory: true) else { throw LectureError.message("Unsafe support storage.") }
    }

    func safeSupportTree(_ root: URL) -> Bool {
        guard safeSupportItem(root, directory: true),
              let entries = try? FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil) else { return false }
        for entry in entries {
            var info = stat()
            guard lstat(entry.path, &info) == 0 else { return false }
            let kind = info.st_mode & S_IFMT
            if kind == S_IFDIR {
                guard safeSupportTree(entry) else { return false }
            } else {
                guard kind == S_IFREG, safeSupportItem(entry, directory: false) else { return false }
            }
        }
        return true
    }

    func safeSupportDestination(_ url: URL) -> Bool {
        guard safeSupportItem(url.deletingLastPathComponent(), directory: true) else { return false }
        var info = stat()
        if lstat(url.path, &info) == 0 { return safeSupportItem(url, directory: false) }
        return errno == ENOENT
    }

    func removeSupportFile(_ url: URL) throws {
        guard safeSupportItem(url, directory: false) else { throw LectureError.message("Unsafe support file; it was preserved.") }
        try FileManager.default.removeItem(at: url)
    }

    func prepareSupport() throws {
        try repairSupportPermissions()
        purgeLegacyNotes()
        purgeLegacyRouting()
    }

    // Old vocabulary refinement wrote unused transcript copies here. Recognize only
    // the timestamp IDs generated by Core.newID, and never follow links or remove directories.
    func purgeLegacyRouting() {
        let directory = support.appendingPathComponent("routing", isDirectory: true)
        guard safeSupportItem(directory, directory: true),
              let files = try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil) else { return }
        for file in files where file.pathExtension == "json" {
            let id = Array(file.deletingPathExtension().lastPathComponent.utf8)
            guard id.count == 15, id[8] == 45,
                  id.enumerated().allSatisfy({ $0.offset == 8 || (48...57).contains($0.element) }),
                  safeSupportItem(file, directory: false),
                  let data = try? Data(contentsOf: file),
                  let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
                  object["schemaVersion"] as? Int == 1, object["baseline"] is String else { continue }
            try? removeSupportFile(file)
        }
    }

    private func repairSupportPermissions() throws {
        let manager = FileManager.default
        try createSupportDirectory(support)
        try manager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: support.path)
        for root in [audio, support.appendingPathComponent("models"), support.appendingPathComponent("routing")] {
            if !manager.fileExists(atPath: root.path), root != support.appendingPathComponent("routing") {
                try createSupportDirectory(root)
            }
            guard safeSupportItem(root, directory: true) else { continue }
            try manager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: root.path)
            if let entries = manager.enumerator(at: root, includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey]) {
                for case let url as URL in entries {
                    let values = try url.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
                    let isDirectory = values.isDirectory == true
                    guard values.isSymbolicLink != true, safeSupportItem(url, directory: isDirectory) else {
                        entries.skipDescendants(); continue
                    }
                    try manager.setAttributes([.posixPermissions: isDirectory ? 0o700 : 0o600], ofItemAtPath: url.path)
                }
            }
        }
    }

    // Older versions wrote only SHA-256-named JSON files in per-model folders.
    // Leave directories and any unrecognized content intact.
    func purgeLegacyNotes() {
        let manager = FileManager.default
        let notes = support.appendingPathComponent("models/llm/notes")
        guard safeSupportItem(notes, directory: true) else { return }
        for modelID in ["qwen", "smol"] {
            let folder = notes.appendingPathComponent(modelID)
            guard safeSupportItem(folder, directory: true),
                  let files = try? manager.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil) else { continue }
            for file in files {
                let name = file.deletingPathExtension().lastPathComponent
                guard file.pathExtension == "json", name.count == 64,
                      name.allSatisfy({ "0123456789abcdef".contains($0) }),
                      safeSupportItem(file, directory: false) else { continue }
                try? manager.removeItem(at: file)
            }
        }
    }
    func lectureFolder(_ name: String) -> URL { transcripts.appendingPathComponent(name, isDirectory: true) }
    func lectures() -> [String] {
        let urls = (try? FileManager.default.contentsOfDirectory(at: transcripts, includingPropertiesForKeys: [.isDirectoryKey], options: [])) ?? []
        return urls.filter { Core.isContained($0, in: transcripts)
            && (try? $0.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true }
            .map(\.lastPathComponent).sorted { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }
    }
    func validateLectureFolder(_ name: String) throws {
        guard !name.isEmpty, name != ".", name != "..", !name.contains("/"), !name.contains("\\"),
              !name.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains),
              Core.isContained(lectureFolder(name), in: transcripts) else {
            throw LectureError.message("This folder points outside your transcript library. Choose another folder.")
        }
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
        let text: String?
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
    // Independent of the editable Markdown and recording file name.
    var transcriptID: String?
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
        case id, lecture, session, startedAt, endedAt, status, transcriptPath, transcriptID, error, dismissed, transcribedAt, markers, vocabularyTerms
    }

    func save(in paths: AppPaths) throws {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let file = paths.audioFile(id, "json")
        guard paths.safeSupportItem(paths.audio, directory: true) else { throw LectureError.message("Unsafe audio storage.") }
        guard paths.safeSupportDestination(file) else { throw LectureError.message("Unsafe audio file.") }
        try encoder.encode(self).write(to: file, options: .atomic)
        guard paths.safeSupportItem(file, directory: false) else { throw LectureError.message("Unsafe audio file.") }
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
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
        transcriptID = try c.decodeIfPresent(String.self, forKey: .transcriptID)
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
    static func isContained(_ url: URL, in root: URL) -> Bool {
        let base = root.resolvingSymlinksInPath().standardizedFileURL.path
        return url.resolvingSymlinksInPath().standardizedFileURL.path.hasPrefix(base == "/" ? base : base + "/")
    }
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
    // A recording that ended (or crashed) before its first audio buffer leaves a header-only WAV.
    static let emptyRecordingMessage = "This recording has no audio because it stopped before any sound was captured. Nothing to transcribe."
    static let missingEngineMessage = "Nosy's speech engine is missing. Reinstall Nosy, then try again. Your audio is safe."

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
        if !SpeechModel.validate(paths.model) {
            messages.append("Nosy needs a valid speech model (1.6 GB). Download it again in setup.")
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
        var legacyInfo = stat()
        guard lstat(legacySupport.path, &legacyInfo) == 0 else { return }
        let legacyPaths = AppPaths(environment: ["NOSY_SUPPORT_DIR": legacySupport.path,
                                                  "NOSY_TRANSCRIPTS_DIR": paths.transcripts.path])
        let legacyRoot = legacySupport.resolvingSymlinksInPath().standardizedFileURL.path
        let destinationRoot = paths.support.resolvingSymlinksInPath().standardizedFileURL.path
        guard legacyRoot != destinationRoot, !legacyRoot.hasPrefix(destinationRoot + "/"),
              !destinationRoot.hasPrefix(legacyRoot + "/"), legacyPaths.safeSupportTree(legacySupport) else {
            NSLog("Skipping legacy migration: unsafe source storage.")
            return
        }
        // Validate both trees completely before the first move, including existing
        // destination entries. Do not move a linked file or linked ancestor.
        var destinationInfo = stat()
        let destinationExists = lstat(paths.support.path, &destinationInfo) == 0
        if destinationExists {
            guard paths.safeSupportTree(paths.support) else {
                NSLog("Skipping legacy migration: unsafe destination storage.")
                return
            }
        }
        do { try paths.createSupportDirectory(paths.support) }
        catch { NSLog("Skipping legacy migration: unsafe destination storage."); return }
        if !destinationExists {
            for file in try manager.contentsOfDirectory(at: legacySupport, includingPropertiesForKeys: nil) {
                var info = stat()
                guard lstat(file.path, &info) == 0,
                      legacyPaths.safeSupportItem(file, directory: (info.st_mode & S_IFMT) == S_IFDIR),
                      paths.safeSupportItem(paths.support, directory: true) else {
                    NSLog("Skipping legacy migration: storage changed."); return
                }
                try manager.moveItem(at: file, to: paths.support.appendingPathComponent(file.lastPathComponent))
            }
            return
        }
        for directory in ["models", "audio"] {
            let source = legacySupport.appendingPathComponent(directory, isDirectory: true)
            var info = stat()
            guard lstat(source.path, &info) == 0 else { continue }
            guard legacyPaths.safeSupportItem(source, directory: true) else {
                NSLog("Skipping legacy migration: unsafe source storage."); return
            }
            let destination = paths.support.appendingPathComponent(directory, isDirectory: true)
            try paths.createSupportDirectory(destination)
            for file in try manager.contentsOfDirectory(at: source, includingPropertiesForKeys: nil) {
                guard legacyPaths.safeSupportItem(file, directory: false) else { continue }
                let target = destination.appendingPathComponent(file.lastPathComponent)
                var targetInfo = stat()
                guard lstat(target.path, &targetInfo) != 0, errno == ENOENT,
                      legacyPaths.safeSupportItem(file, directory: false),
                      paths.safeSupportItem(destination, directory: true) else { continue }
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
            return "Your disk is full. Free up some space, then try again. Your saved audio is safe."
        }
        if text.contains("whisper-cli"), !text.contains("whisper-cli exited"),
           contains(["missing", "not found", "no such file", "does not exist", "doesn’t exist", "doesn't exist"]) {
            return missingEngineMessage
        }
        if contains(["model missing", "missing model", "model is missing", "model not found", "failed to open model", "failed to load model"])
            || (text.contains("model") && contains(["no such file", "does not exist", "not been downloaded"])) {
            return "The speech model hasn't been downloaded yet. Your audio is safe. Try again once it's ready."
        }
        if trimmed == emptyRecordingMessage { return emptyRecordingMessage }
        if text.contains("whisper"), contains(["exited", "exit code", "exit status"]) {
            return "Transcription hit a snag. Your audio is safe. Try again."
        }
        if text.contains("microphone"), !contains(["save", "write", "file"]), contains(["denied", "permission", "not authorized"]) {
            return "Nosy can't access your microphone. Allow access in System Settings, then try again."
        }
        if contains(["microphone changed", "device changed", "device change", "microphone disconnected", "device disconnected"]) {
            return "Your microphone changed or disconnected. Check your input, then start a new recording. Your saved audio is safe."
        }
        if contains(["could not save", "couldn't save", "failed to save", "error saving", "could not write", "failed to write", "error writing", "could not create recording file", "could not create transcription log file", "could not finalize wav", "file write", "write failed", "couldn’t be saved", "couldn't be saved", "could not be saved", "permission denied", "nscocoaerrordomain code=513"]) {
            return "Nosy couldn't save the file. Check the folder's permissions and available space, then Retry."
        }
        if contains(["microphone", "audio conversion", "audio input", "could not start audio", "avfaudio"]) {
            return "Nosy couldn't record from your microphone. Check your input and try again. Your saved audio is safe."
        }
        if text.contains("app closed unexpectedly") {
            return "Nosy closed before this recording finished. Your audio is safe. Choose Retry to transcribe it."
        }
        if text.contains("quit before transcription") {
            return "Nosy quit before transcription finished. Your audio is safe. Choose Retry."
        }
        return String(trimmed.prefix(160))
            .replacingOccurrences(of: "—", with: ". ")
            .replacingOccurrences(of: "–", with: ". ")
            .replacingOccurrences(of: "-", with: " ")
    }

    static func sanitize(_ value: String) throws -> String {
        let forbidden = CharacterSet(charactersIn: "/\\:*?\"<>|").union(.controlCharacters)
        let replaced = String(String.UnicodeScalarView(value.trimmingCharacters(in: .whitespacesAndNewlines).unicodeScalars.map {
            forbidden.contains($0) ? UnicodeScalar(45)! : $0
        }))
        let result = String(collapseWhitespace(replaced).prefix(80)).trimmingCharacters(in: .whitespaces)
        guard !result.isEmpty, result.contains(where: { $0 != "." }) else {
            throw LectureError.message("Enter a folder and session name; names cannot be empty or only dots.")
        }
        guard !result.hasPrefix(".") else {
            throw LectureError.message("Folder and session names cannot start with a dot.")
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
            let summary = folder.appendingPathComponent(name + " summary.md")
            if !pathEntryExists(at: url), !pathEntryExists(at: summary),
               !pathEntryExists(at: KeyMomentStore.url(for: url)),
               !pathEntryExists(at: TranscriptIdentity.url(for: url)) { return url }
            number += 1
        }
    }
    private static func pathEntryExists(at url: URL) -> Bool {
        var metadata = stat()
        return url.path.withCString { lstat($0, &metadata) == 0 }
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
                if pathEntryExists(at: target) { continue }
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
    static func saveTranscriptEdits(_ text: String, to url: URL, expectedText: String) throws {
        guard try String(contentsOf: url, encoding: .utf8) == expectedText else {
            throw LectureError.message("This transcript changed outside Nosy. Copy your draft before reloading the updated file.")
        }
        try KeyMomentStore.invalidateForEdit(url)
        let identity = TranscriptIdentity.attributeValue(url)
        try Data(text.utf8).write(to: url, options: .atomic)
        if let identity { try? TranscriptIdentity.setAttribute(identity, on: url) }
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
    static func minutes(_ seconds: TimeInterval) -> Int {
        guard seconds.isFinite else { return 1 }
        return max(1, Int(min(Double(Int.max / 60), max(0, seconds / 60)).rounded()))
    }
    static func timer(_ seconds: TimeInterval) -> String {
        let n = seconds.isFinite ? Int(min(Double(Int.max / 2), max(0, seconds))) : 0
        return n >= 3600 ? String(format: "%d:%02d:%02d", n / 3600, (n / 60) % 60, n % 60)
            : String(format: "%d:%02d", n / 60, n % 60)
    }
    static func reminderTime(_ seconds: TimeInterval) -> String {
        let n = seconds.isFinite ? Int(min(Double(Int.max / 2), max(0, seconds))) : 0
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
    // checkCancellation runs between buffers and before publication and deletion; the default never cancels.
    @discardableResult static func finalizeWAV(id: String, paths: AppPaths, checkCancellation: () throws -> Void = {}) throws -> URL {
        try checkCancellation()
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
        defer { try? paths.removeSupportFile(temporary) }
        guard paths.safeSupportItem(paths.audio, directory: true) else { throw LectureError.message("Unsafe audio storage.") }
        guard FileManager.default.createFile(atPath: temporary.path, contents: try wavHeader(pcmBytes: size),
                                             attributes: [.posixPermissions: 0o600]) else { throw CocoaError(.fileWriteUnknown) }
        let output = try FileHandle(forWritingTo: temporary)
        do {
            try output.seekToEnd()
            var remaining = size
            while remaining > 0 {
                try checkCancellation()
                let chunk = try source.read(upToCount: Int(min(remaining, 1_048_576))) ?? Data()
                guard !chunk.isEmpty else { throw LectureError.message("PCM file ended unexpectedly; raw audio is kept.") }
                try output.write(contentsOf: chunk)
                remaining -= Int64(chunk.count)
            }
            try output.synchronize()
            try output.close()
        } catch { try? output.close(); throw error }
        try checkCancellation()
        // rename is atomic, including replacement of a WAV left by an interrupted finalization.
        guard paths.safeSupportItem(temporary, directory: false), paths.safeSupportDestination(wav) else { throw LectureError.message("Unsafe audio storage.") }
        let result = temporary.path.withCString { from in wav.path.withCString { to in rename(from, to) } }
        guard result == 0 else { throw LectureError.message("Could not finalize WAV (errno \(errno)); raw audio is kept.") }
        try checkCancellation()
        try paths.removeSupportFile(pcm)
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
    // The header markdown(record:) writes. Only files that start with it are transcripts, so a
    // transcripts folder that also holds other notes never lists them. Keep in sync with
    // TranscriptStore.isTranscript in the connector.
    static func isTranscript(_ text: String) -> Bool {
        let lines = text.split(maxSplits: 16, omittingEmptySubsequences: true, whereSeparator: \.isNewline).prefix(16)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
        guard let title = lines.first(where: { !$0.isEmpty }), title.hasPrefix("# ") else { return false }
        return lines.contains { $0.hasPrefix("- Date: ") } && lines.contains { $0.hasPrefix("- Length: ") }
            && lines.contains("## Transcript")
    }
    static func isTranscript(at url: URL) -> Bool {
        guard url.pathExtension.lowercased() == "md", let handle = try? FileHandle(forReadingFrom: url) else { return false }
        defer { try? handle.close() }
        return isTranscript(String(decoding: (try? handle.read(upToCount: 4096)) ?? Data(), as: UTF8.self))
    }
    // True when a subfolder of `folder` holds at least one Nosy transcript.
    static func containsTranscripts(_ folder: URL) -> Bool {
        let manager = FileManager.default
        let subfolders = (try? manager.contentsOfDirectory(at: folder, includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles])) ?? []
        return subfolders.contains { sub in
            guard isContained(sub, in: folder), (try? sub.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true else { return false }
            let files = (try? manager.contentsOfDirectory(at: sub, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles])) ?? []
            return files.contains { file in
                guard isContained(file, in: folder), file.pathExtension.lowercased() == "md" else { return false }
                var info = stat()
                guard file.path.withCString({ lstat($0, &info) }) == 0,
                      (info.st_mode & S_IFMT) == S_IFREG else { return false }
                if isTranscript(at: file) { return true }
                guard let id = TranscriptIdentity.indexID(file) else { return false }
                return TranscriptIdentity.attributeValue(file) == id
            }
        }
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
        return urls.filter { $0.pathExtension == "json" && !KeyMomentStore.isLegacySegmentsFile($0) }.compactMap { try? SessionRecord.read($0) }
            .sorted { $0.startedAt > $1.startedAt }
    }
    static func record(forTranscript url: URL, paths: AppPaths) -> SessionRecord? {
        guard let identity = TranscriptIdentity.indexID(url),
              TranscriptIdentity.attributeValue(url) == identity else { return nil }
        return records(in: paths).first {
            guard $0.transcriptID == identity, let path = $0.transcriptPath else { return false }
            return URL(fileURLWithPath: path).standardizedFileURL.path == url.standardizedFileURL.path
        }
    }
    // Detach before a Trash operation, so even a reused pathname can never authorize deletion.
    static func detachTranscripts(in url: URL, folder: Bool, paths: AppPaths) throws {
        let path = url.standardizedFileURL.path
        for var record in records(in: paths) {
            guard let stored = record.transcriptPath else { continue }
            let candidate = URL(fileURLWithPath: stored).standardizedFileURL.path
            guard candidate == path || (folder && candidate.hasPrefix(path + "/")) else { continue }
            record.transcriptPath = nil
            record.transcriptID = nil
            try record.save(in: paths)
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
    static func applyRetention(paths: AppPaths, now: Date = Date(), checkCancellation: () throws -> Void = {}) throws {
        try TranscriptCoordination.withLock(paths: paths) {
            try applyRetentionLocked(paths: paths, now: now, checkCancellation: checkCancellation)
        }
    }
    private static func applyRetentionLocked(paths: AppPaths, now: Date, checkCancellation: () throws -> Void) throws {
        try checkCancellation()
        paths.purgeLegacyRouting()
        guard paths.safeSupportItem(paths.audio, directory: true) else { return }
        // Poll while reading sidecars too; a large library must not delay Quit before deletion starts.
        let files = (try? FileManager.default.contentsOfDirectory(at: paths.audio, includingPropertiesForKeys: nil)) ?? []
        for sidecar in files where sidecar.pathExtension == "json" && !KeyMomentStore.isLegacySegmentsFile(sidecar) {
            try checkCancellation()
            guard let record = try? SessionRecord.read(sidecar),
                  !retentionCandidates([record], now: now, days: paths.retentionDays).isEmpty else { continue }
            // A lost or trashed transcript must never cost the owner the only remaining audio.
            guard let transcript = record.transcriptPath, let identity = record.transcriptID,
                  FileManager.default.isReadableFile(atPath: transcript),
                  TranscriptIdentity.indexID(URL(fileURLWithPath: transcript)) == identity,
                  TranscriptIdentity.attributeValue(URL(fileURLWithPath: transcript)) == identity else { continue }
            // AI markers and timings from before KeyMomentStore move beside the transcript first. If that fails, keep the audio.
            do { try KeyMomentStore.preserveLegacy(record: record, transcript: URL(fileURLWithPath: transcript), paths: paths) }
            catch { continue }
            let prefix = record.id + "."
            var owned: [URL] = []
            for url in files {
                try checkCancellation()
                if url.lastPathComponent.hasPrefix(prefix) { owned.append(url) }
            }
            // The sidecar goes last: an interrupted pass leaves the record discoverable for the next one.
            let audioFiles = owned.filter { $0.pathExtension != "json" }
            let sidecars = owned.filter { $0.pathExtension == "json" }
            for url in audioFiles + sidecars {
                try checkCancellation()
                try paths.removeSupportFile(url)
            }
        }
    }
    static func recoveryCandidates(_ records: [SessionRecord]) -> [SessionRecord] {
        records.filter { $0.dismissed != true && ($0.status == .recording || $0.status == .transcribing || $0.status == .failed) }
            .sorted { $0.startedAt > $1.startedAt }
    }
    static func recover(paths: AppPaths) throws -> [SessionRecord] {
        guard paths.safeSupportItem(paths.audio, directory: true) else { return [] }
        // Only helper scratch files are disposable; preserve all recordings and sidecars.
        if paths.safeSupportItem(paths.audio, directory: true),
           let files = try? FileManager.default.contentsOfDirectory(at: paths.audio, includingPropertiesForKeys: nil) {
            for file in files {
                let name = file.deletingPathExtension().lastPathComponent
                guard ["stderr", "txt", "json", "wav"].contains(file.pathExtension),
                      name.hasPrefix(".whisper-"), name.count > 46,
                      UUID(uuidString: String(name.suffix(36))) != nil,
                      name.dropLast(36).last == "-" else { continue }
                try? paths.removeSupportFile(file)
            }
        }
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
