import Foundation

// Durable storage for Find key moments. Each transcript gets a hidden file beside it, named
// `.<transcript name>.key-moments.json`. It moves with the transcript on rename, goes to the Trash with
// it, and recording retention never touches it, so AI markers and the timings they are placed by outlive
// the audio. Manual markers stay in the recording sidecar, and this file never holds them.

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
    var segments: SavedSegments?
    var markers: [AIMarker] = []

    init(segments: SavedSegments? = nil, markers: [AIMarker] = []) {
        self.segments = segments
        self.markers = markers
    }
    private enum CodingKeys: String, CodingKey { case version, segments, markers }
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        version = try c.decodeIfPresent(Int.self, forKey: .version) ?? 1
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

    static func read(_ transcript: URL) -> KeyMomentsFile? {
        guard let data = try? Data(contentsOf: url(for: transcript)) else { return nil }
        return try? JSONDecoder().decode(KeyMomentsFile.self, from: data)
    }
    static func write(_ file: KeyMomentsFile, for transcript: URL) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(file)
        let destination = url(for: transcript)
        if try Core.exclusiveWrite(data, to: destination) { return }
        // Never replace a directory, link, or unrecognised file at the reserved name.
        var info = stat()
        guard destination.path.withCString({ lstat($0, &info) }) == 0,
              (info.st_mode & S_IFMT) == S_IFREG, read(transcript) != nil else {
            throw LectureError.message("A different item already occupies the key moments file name.")
        }
        try data.write(to: destination, options: .atomic)
    }

    // Called once a transcript is written. Never replace a file that took the name in the meantime.
    static func start(transcript: URL, segments: [TranscriptSegments.Segment]?, text: String) throws {
        guard let segments else { return try create(KeyMomentsFile(), for: transcript) }
        var lines = text.components(separatedBy: "\n")
        if lines.last == "" { lines.removeLast() }
        // Lines match Whisper's segments one to one, so later anchors match the text the reader shows.
        let aligned = lines.count == segments.count
        let items = segments.enumerated().map { index, segment in
            SavedSegments.Item(from: segment.offsets.from, to: segment.offsets.to,
                               text: Core.collapseWhitespace(aligned ? lines[index] : (segment.text ?? "")))
        }
        try create(KeyMomentsFile(segments: SavedSegments(segments: items)), for: transcript)
    }

    private static func create(_ file: KeyMomentsFile, for transcript: URL) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        guard try Core.exclusiveWrite(encoder.encode(file), to: url(for: transcript)) else {
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
        return KeyMomentsFile(segments: segments, markers: markers)
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

    // Rename moves the file with its transcript without replacing an existing destination.
    static func move(from old: URL, to new: URL) throws {
        let source = url(for: old)
        guard FileManager.default.fileExists(atPath: source.path) else { return }
        try FileManager.default.moveItem(at: source, to: url(for: new))
    }
    // Trash moves the file to the Trash beside its transcript, so restoring either restores both.
    static func trash(transcript: URL) throws {
        let file = url(for: transcript)
        guard FileManager.default.fileExists(atPath: file.path) else { return }
        try FileManager.default.trashItem(at: file, resultingItemURL: nil)
    }
}
