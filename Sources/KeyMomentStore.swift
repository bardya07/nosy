import Foundation
import CryptoKit

// Durable storage for Find key moments. New files use the transcript identity in their name and
// contents. Older name-based files are readable but are never overwritten, moved or trashed.

struct AIMarker: Codable, Sendable, Equatable {
    var t: TimeInterval
    var label: String
    // The first words of the marked segment. The reader uses them to sit the marker beside its paragraph.
    var anchor: String
    // True when the time came from text position because the transcript kept no segment timings.
    var approximate: Bool

    init(t: TimeInterval, label: String, anchor: String = "", approximate: Bool = false) {
        self.t = t
        self.label = label
        self.anchor = anchor
        self.approximate = approximate
    }
    private enum CodingKeys: String, CodingKey { case t, label, anchor, approximate }
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        t = try c.decode(TimeInterval.self, forKey: .t)
        label = try c.decode(String.self, forKey: .label)
        anchor = try c.decodeIfPresent(String.self, forKey: .anchor) ?? ""
        approximate = try c.decodeIfPresent(Bool.self, forKey: .approximate) ?? false
    }
    // Times must be finite and inside the file's range. A marker that fails this is dropped.
    var isUsable: Bool { t.isFinite && t >= 0 && t < Double(Int.max) }
}

// Whisper segment timings, saved when a transcript is written. Milliseconds, compact.
struct SavedSegments: Codable, Sendable, Equatable {
    struct Item: Codable, Sendable, Equatable {
        var from: Int
        var to: Int
        var text: String
    }
    var version = 1
    var transcriptHash: String? = nil
    var segments: [Item]
}

// Decodes one element, or nil when that element is damaged, so one bad entry never costs the others.
private struct Lossy<Value: Decodable & Sendable>: Decodable, Sendable {
    let value: Value?
    init(from decoder: Decoder) throws { value = try? Value(from: decoder) }
}

// Everything one transcript keeps for Find key moments.
struct KeyMomentsFile: Codable, Sendable, Equatable {
    var version = 1
    var ownerID: String?
    var transcriptHash: String?
    var segments: SavedSegments?
    var markers: [AIMarker] = []

    init(transcriptHash: String? = nil, segments: SavedSegments? = nil, markers: [AIMarker] = []) {
        self.transcriptHash = transcriptHash
        self.segments = segments
        self.markers = markers
    }
    private enum CodingKeys: String, CodingKey { case version, ownerID, transcriptHash, segments, markers }
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        version = try c.decodeIfPresent(Int.self, forKey: .version) ?? 1
        ownerID = try c.decodeIfPresent(String.self, forKey: .ownerID)
        transcriptHash = try c.decodeIfPresent(String.self, forKey: .transcriptHash)
        segments = try? c.decodeIfPresent(SavedSegments.self, forKey: .segments)
        markers = (try c.decodeIfPresent([Lossy<AIMarker>].self, forKey: .markers) ?? []).compactMap(\.value).filter(\.isUsable)
    }
}

enum KeyMomentStore {
    static let suffix = ".key-moments.json"

    // `.<name>.key-moments.json`, in the same folder as the transcript.
    static func url(for transcript: URL) -> URL {
        transcript.deletingLastPathComponent()
            .appendingPathComponent("." + transcript.deletingPathExtension().lastPathComponent + suffix)
    }
    // Files from before this store are named `<id>.segments.json` in the audio folder.
    static func isLegacySegmentsFile(_ url: URL) -> Bool { url.lastPathComponent.hasSuffix(".segments.json") }

    private static func ownedURL(_ transcript: URL, id: String) -> URL {
        transcript.deletingLastPathComponent().appendingPathComponent(".nosy-" + id + suffix)
    }
    private static func entryExists(_ url: URL) -> Bool {
        var info = stat()
        return url.path.withCString { lstat($0, &info) } == 0
    }
    private static func decode(_ url: URL) -> KeyMomentsFile? {
        var info = stat()
        guard url.path.withCString({ lstat($0, &info) }) == 0, (info.st_mode & S_IFMT) == S_IFREG,
              let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(KeyMomentsFile.self, from: data)
    }
    private static func rawRead(_ transcript: URL) -> (file: KeyMomentsFile, owned: Bool)? {
        if let id = TranscriptIdentity.indexID(transcript) {
            let destination = ownedURL(transcript, id: id)
            if entryExists(destination) {
                guard let file = decode(destination), file.ownerID == id else { return nil }
                return (file, true)
            }
        }
        // Older files have no proof of ownership. Read only; never change them.
        guard let file = decode(url(for: transcript)), file.ownerID == nil else { return nil }
        return (file, false)
    }
    static func hash(_ text: String) -> String {
        SHA256.hash(data: Data(text.utf8)).map { String(format: "%02x", $0) }.joined()
    }
    // Unbound legacy text and stale anchors are never trusted, even if rewriting fails.
    static func read(_ transcript: URL) -> KeyMomentsFile? {
        guard let stored = rawRead(transcript) else { return nil }
        var file = stored.file
        let current = try? String(contentsOf: transcript, encoding: .utf8)
        if current == nil || file.transcriptHash == nil || file.transcriptHash != current.map(hash) {
            let original = file
            scrub(&file)
            if stored.owned && file != original { try? write(file, for: transcript) }
        }
        return file
    }
    private static func scrub(_ file: inout KeyMomentsFile) {
        file.transcriptHash = nil
        file.segments?.transcriptHash = nil
        if var segments = file.segments {
            for index in segments.segments.indices { segments.segments[index].text = "" }
            file.segments = segments
        }
        for index in file.markers.indices { file.markers[index].anchor = "" }
    }
    // Invalidate before committing an edit, so old speech is not retained by the sidecar.
    static func invalidateForEdit(_ transcript: URL) throws {
        guard let stored = rawRead(transcript) else { return }
        var file = stored.file
        scrub(&file)
        // A legacy file or a transcript replaced by another program may have no verifiable
        // owner. Ignore its text in memory without overwriting that potentially unrelated file.
        if let id = TranscriptIdentity.indexID(transcript), TranscriptIdentity.attributeValue(transcript) != id { return }
        try write(file, for: transcript)
    }
    // Older versions kept segments and AI anchors with the recording instead.
    static func invalidateLegacyForEdit(_ transcript: URL, paths: AppPaths) throws {
        guard let record = Core.record(forTranscript: transcript, paths: paths) else { return }
        let segmentsURL = paths.audioFile(record.id, "segments.json")
        if FileManager.default.fileExists(atPath: segmentsURL.path) {
            guard paths.safeSupportItem(segmentsURL, directory: false) else { throw LectureError.message("Unsafe audio storage.") }
            let data = try Data(contentsOf: segmentsURL)
            if var segments = try? JSONDecoder().decode(SavedSegments.self, from: data) {
                segments.transcriptHash = nil
                for index in segments.segments.indices { segments.segments[index].text = "" }
                try JSONEncoder().encode(segments).write(to: segmentsURL, options: .atomic)
            }
        }
        let recordURL = paths.audioFile(record.id, "json")
        guard paths.safeSupportItem(recordURL, directory: false) else { throw LectureError.message("Unsafe audio storage.") }
        let data = try Data(contentsOf: recordURL)
        if var object = try JSONSerialization.jsonObject(with: data) as? [String: Any],
           var markers = object["aiMarkers"] as? [[String: Any]] {
            for index in markers.indices { markers[index]["anchor"] = "" }
            object["aiMarkers"] = markers
            try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]).write(to: recordURL, options: .atomic)
        }
    }
    static func write(_ file: KeyMomentsFile, for transcript: URL) throws {
        if TranscriptIdentity.indexID(transcript) == nil { try TranscriptIdentity.index(transcript) }
        guard let id = TranscriptIdentity.indexID(transcript) else {
            throw LectureError.message("This transcript has no usable identity.")
        }
        guard TranscriptIdentity.attributeValue(transcript) == id else {
            throw LectureError.message("The transcript identity could not be verified. Its existing key moments were kept.")
        }
        try writeOwned(file, for: transcript, id: id)
    }
    private static func writeOwned(_ file: KeyMomentsFile, for transcript: URL, id: String) throws {
        var file = file
        file.ownerID = id
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(file)
        let destination = ownedURL(transcript, id: id)
        if try Core.exclusiveWrite(data, to: destination) { return }
        // Never replace a directory, link, or unrecognised file at the reserved name.
        var info = stat()
        guard destination.path.withCString({ lstat($0, &info) }) == 0,
              (info.st_mode & S_IFMT) == S_IFREG, decode(destination)?.ownerID == id else {
            throw LectureError.message("A different item already occupies the key moments file name.")
        }
        try data.write(to: destination, options: .atomic)
    }

    // Called once a transcript is written. Never replace a file that took the name in the meantime.
    static func start(transcript: URL, segments: [TranscriptSegments.Segment]?, text: String) throws {
        let markdown = try String(contentsOf: transcript, encoding: .utf8)
        guard let segments else { return try create(KeyMomentsFile(transcriptHash: hash(markdown)), for: transcript) }
        var lines = text.components(separatedBy: "\n")
        if lines.last == "" { lines.removeLast() }
        // Lines match Whisper's segments one to one, so later anchors match the text the reader shows.
        let aligned = lines.count == segments.count
        let items = segments.enumerated().map { index, segment in
            SavedSegments.Item(from: segment.offsets.from, to: segment.offsets.to,
                               text: Core.collapseWhitespace(aligned ? lines[index] : (segment.text ?? "")))
        }
        try create(KeyMomentsFile(transcriptHash: hash(markdown), segments: SavedSegments(transcriptHash: hash(markdown), segments: items)), for: transcript)
    }

    private static func create(_ file: KeyMomentsFile, for transcript: URL) throws {
        if TranscriptIdentity.indexID(transcript) == nil { try TranscriptIdentity.index(transcript) }
        guard let id = TranscriptIdentity.indexID(transcript) else {
            throw LectureError.message("This transcript has no usable identity.")
        }
        guard TranscriptIdentity.attributeValue(transcript) == id else {
            throw LectureError.message("The transcript identity could not be verified.")
        }
        var file = file
        file.ownerID = id
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        guard try Core.exclusiveWrite(encoder.encode(file), to: ownedURL(transcript, id: id)) else {
            throw LectureError.message("A different item already occupies the key moments file name.")
        }
    }

    // The stored file. When this transcript has none yet, a recording sidecar from before this store is
    // read once and copied across. Nothing here needs the recording to still exist.
    static func file(for transcript: URL, paths: AppPaths) -> KeyMomentsFile? {
        if let stored = read(transcript) { return stored }
        guard let record = Core.record(forTranscript: transcript, paths: paths),
              let legacy = legacyFile(record: record, paths: paths) else { return nil }
        try? write(legacy, for: transcript)
        return legacy
    }
    // Retention deletes the audio and its sidecar, so legacy data is copied across first. Throws when the
    // copy fails, and the caller then keeps the audio.
    static func preserveLegacy(record: SessionRecord, transcript: URL, paths: AppPaths) throws {
        guard read(transcript) == nil, let legacy = legacyFile(record: record, paths: paths) else { return }
        try write(legacy, for: transcript)
    }
    private struct LegacySidecar: Decodable { let aiMarkers: [Lossy<AIMarker>]? }
    static func legacyFile(record: SessionRecord, paths: AppPaths) -> KeyMomentsFile? {
        let markers = legacyMarkers(id: record.id, paths: paths)
        let segments = (try? Data(contentsOf: paths.audioFile(record.id, "segments.json")))
            .flatMap { try? JSONDecoder().decode(SavedSegments.self, from: $0) }
        guard !markers.isEmpty || segments != nil else { return nil }
        var file = KeyMomentsFile(segments: segments, markers: markers)
        scrub(&file)
        return file
    }
    private static func legacyMarkers(id: String, paths: AppPaths) -> [AIMarker] {
        guard let data = try? Data(contentsOf: paths.audioFile(id, "json")),
              let sidecar = try? JSONDecoder().decode(LegacySidecar.self, from: data) else { return [] }
        return (sidecar.aiMarkers ?? []).compactMap(\.value).filter(\.isUsable)
    }

    static func segments(for transcript: URL, paths: AppPaths) -> SavedSegments? {
        file(for: transcript, paths: paths)?.segments
    }
    static func markers(for transcript: URL, paths: AppPaths) -> [AIMarker] {
        file(for: transcript, paths: paths)?.markers ?? []
    }

    // Read-modify-write of the AI markers only. Timings and manual markers are never touched here.
    static func update(transcript: URL, paths: AppPaths, _ change: (inout [AIMarker]) -> Void) throws {
        var file = file(for: transcript, paths: paths) ?? KeyMomentsFile()
        let before = file.markers
        change(&file.markers)
        guard file.markers != before else { return }
        if let text = try? String(contentsOf: transcript, encoding: .utf8) { file.transcriptHash = hash(text) }
        try write(file, for: transcript)
    }
    static func replace(_ markers: [AIMarker], transcript: URL, paths: AppPaths) throws {
        try update(transcript: transcript, paths: paths) { $0 = markers }
    }
    static func remove(at index: Int, transcript: URL, paths: AppPaths) throws {
        try update(transcript: transcript, paths: paths) { markers in
            if markers.indices.contains(index) { markers.remove(at: index) }
        }
    }
    static func removeAll(transcript: URL, paths: AppPaths) throws {
        try update(transcript: transcript, paths: paths) { $0.removeAll() }
    }

    // The identity-named file stays in the same folder on rename. Copy legacy data to an
    // owned file first, leaving the unowned original untouched.
    static func move(from old: URL, to new: URL) throws {
        guard old.deletingLastPathComponent().standardizedFileURL == new.deletingLastPathComponent().standardizedFileURL else {
            throw LectureError.message("Key moments can only be renamed within their folder.")
        }
        guard let stored = rawRead(old), !stored.owned, var file = read(old) else { return }
        guard let id = TranscriptIdentity.indexID(old), TranscriptIdentity.attributeValue(new) == id else { return }
        // `old` has already moved; its current contents are at `new`.
        if let text = try? String(contentsOf: new, encoding: .utf8), stored.file.transcriptHash == hash(text) {
            file = stored.file
        }
        try writeOwned(file, for: old, id: id)
    }
    // Trash moves the file to the Trash beside its transcript, so restoring either restores both.
    static func trash(transcript: URL, expectedID: String?) throws {
        guard let id = expectedID, TranscriptIdentity.indexID(transcript) == id else { return }
        let file = ownedURL(transcript, id: id)
        guard entryExists(file) else { return }
        var info = stat()
        guard file.path.withCString({ lstat($0, &info) }) == 0,
              (info.st_mode & S_IFMT) == S_IFREG, decode(file)?.ownerID == id else {
            throw LectureError.message("A different item occupies the key moments file name.")
        }
        try FileManager.default.trashItem(at: file, resultingItemURL: nil)
    }
}
