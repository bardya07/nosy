import Foundation

// Read-only access to the transcripts folder Nosy writes: one folder per course, one markdown
// file per session, and an optional "<session> summary.md" beside it. Every file it opens must
// resolve inside the transcripts folder, so "..", odd names and symlinks pointing elsewhere are refused.
struct TranscriptStore: Sendable {
    struct Folder: Codable, Equatable, Sendable {
        let name: String
        let transcripts: Int
    }

    struct Entry: Codable, Equatable, Sendable {
        let folder: String
        let name: String
        let date: String?
        let duration: String?
        let path: String
    }

    struct Hit: Codable, Equatable, Sendable {
        let folder: String
        let name: String
        let date: String?
        let line: Int
        let snippet: String
    }

    struct Document: Equatable, Sendable {
        let folder: String
        let name: String
        let text: String
        let summary: String?
    }

    enum Failure: LocalizedError, Equatable {
        case invalidName(String)
        case notFound(String)
        case emptySearch
        case longSearch

        var errorDescription: String? {
            switch self {
            case .invalidName(let kind): "That \(kind) name is not valid."
            case .notFound(let what): "No \(what) was found in the Nosy transcripts folder."
            case .emptySearch: "Enter a word or phrase to search for."
            case .longSearch: "Search for at most \(TranscriptStore.maxSearchLength) characters."
            }
        }
    }

    static let maxNameLength = 200
    static let maxSearchLength = 200
    private static let summarySuffix = " summary"

    let root: URL

    init(root: URL) {
        self.root = root.resolvingSymlinksInPath().standardizedFileURL
    }

    // Only folders that hold Nosy transcripts: the transcripts folder may sit beside other notes.
    func folders() -> [Folder] {
        subfolders()
            .map { Folder(name: $0.lastPathComponent, transcripts: transcriptFiles(in: $0).count) }
            .filter { $0.transcripts > 0 }
            .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    // Newest first. Pass a folder to list only that one.
    func transcripts(folder: String?, limit: Int) throws -> [Entry] {
        let folders: [URL]
        if let folder {
            folders = [try existingFolder(folder)]
        } else {
            folders = subfolders()
        }
        let entries = folders.flatMap { folderURL in
            transcriptFiles(in: folderURL).map { entry(for: $0, folder: folderURL.lastPathComponent) }
        }
        return Array(entries.sorted(by: Self.newestFirst).prefix(max(0, limit)))
    }

    func read(folder: String, name: String) throws -> Document {
        let folderURL = try existingFolder(folder)
        let stem = try Self.stem(from: name)
        let file = folderURL.appendingPathComponent(stem + ".md")
        guard isFile(file), isContained(file), Self.isTranscript(at: file) else {
            throw Failure.notFound("transcript \"\(stem)\" in folder \"\(folderURL.lastPathComponent)\"")
        }
        let summaryFile = folderURL.appendingPathComponent(stem + " summary.md")
        let text = try String(contentsOf: file, encoding: .utf8)
        let summary = isFile(summaryFile) && isContained(summaryFile)
            ? try? String(contentsOf: summaryFile, encoding: .utf8)
            : nil
        return Document(folder: folderURL.lastPathComponent, name: stem, text: text, summary: summary)
    }

    // Matches ignore case and accents. Hits come newest transcript first, one per matching line.
    func search(query: String, limit: Int) throws -> [Hit] {
        let needle = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !needle.isEmpty else { throw Failure.emptySearch }
        guard needle.count <= Self.maxSearchLength else { throw Failure.longSearch }
        var hits: [Hit] = []
        guard limit > 0 else { return hits }
        for entry in try transcripts(folder: nil, limit: .max) {
            let text = (try? String(contentsOf: URL(fileURLWithPath: entry.path), encoding: .utf8)) ?? ""
            for (index, line) in text.components(separatedBy: .newlines).enumerated() {
                guard let match = line.range(of: needle, options: [.caseInsensitive, .diacriticInsensitive]) else { continue }
                hits.append(Hit(folder: entry.folder, name: entry.name, date: entry.date, line: index + 1,
                                snippet: Self.snippet(line, around: match)))
                if hits.count >= limit { return hits }
            }
        }
        return hits
    }

    // MARK: Paths

    // A folder or transcript name must be one plain path component.
    static func component(_ value: String, kind: String) throws -> String {
        let invalid = value.isEmpty || value.count > maxNameLength || value.hasPrefix(".")
            || value.contains("/") || value.contains("\\")
            || value.unicodeScalars.contains { $0.value < 0x20 || $0.value == 0x7F }
        guard !invalid else { throw Failure.invalidName(kind) }
        return value
    }

    private static func stem(from name: String) throws -> String {
        let bare = name.lowercased().hasSuffix(".md") ? String(name.dropLast(3)) : name
        return try component(bare, kind: "transcript")
    }

    private func existingFolder(_ name: String) throws -> URL {
        let component = try Self.component(name, kind: "folder")
        let url = root.appendingPathComponent(component, isDirectory: true)
        guard isDirectory(url), isContained(url) else { throw Failure.notFound("folder \"\(name)\"") }
        return url
    }

    private func subfolders() -> [URL] {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: root.path)) ?? []
        return names.filter { !$0.hasPrefix(".") }
            .map { root.appendingPathComponent($0, isDirectory: true) }
            .filter { isDirectory($0) && isContained($0) }
    }

    private func transcriptFiles(in folder: URL) -> [URL] {
        let names = ((try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? [])
            .filter { !$0.hasPrefix(".") && $0.lowercased().hasSuffix(".md") }
        let stems = Set(names.map { Self.stemOfFile($0) })
        return names
            .filter { name in
                // A "<session> summary.md" is read together with its transcript, not listed on its own.
                let stem = Self.stemOfFile(name)
                return !(stem.hasSuffix(Self.summarySuffix)
                    && stems.contains(String(stem.dropLast(Self.summarySuffix.count))))
            }
            .map { folder.appendingPathComponent($0) }
            .filter { isFile($0) && isContained($0) && Self.isTranscript(at: $0) }
    }

    // The header Nosy writes ("# Course — Session", "- Date:", "- Length:", "## Transcript").
    // Arbitrary markdown that shares the folder is never listed, read or searched.
    // Keep in sync with Core.isTranscript in the app.
    static func isTranscript(_ text: String) -> Bool {
        let lines = text.split(maxSplits: 16, omittingEmptySubsequences: true, whereSeparator: \.isNewline).prefix(16)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
        guard let title = lines.first(where: { !$0.isEmpty }), title.hasPrefix("# ") else { return false }
        return lines.contains { $0.hasPrefix("- Date: ") } && lines.contains { $0.hasPrefix("- Length: ") }
            && lines.contains("## Transcript")
    }
    static func isTranscript(at url: URL) -> Bool {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return false }
        defer { try? handle.close() }
        return isTranscript(String(decoding: (try? handle.read(upToCount: 4096)) ?? Data(), as: UTF8.self))
    }

    private func isDirectory(_ url: URL) -> Bool {
        var isDirectory: ObjCBool = false
        return FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory) && isDirectory.boolValue
    }

    private func isFile(_ url: URL) -> Bool {
        var isDirectory: ObjCBool = false
        return FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory) && !isDirectory.boolValue
    }

    private func isContained(_ url: URL) -> Bool {
        url.resolvingSymlinksInPath().standardizedFileURL.path.hasPrefix(root.path + "/")
    }

    private static func stemOfFile(_ name: String) -> String { String(name.dropLast(3)) }

    // MARK: Transcript details

    private func entry(for url: URL, folder: String) -> Entry {
        let header = Self.header(of: url)
        let created = (try? url.resourceValues(forKeys: [.creationDateKey]).creationDate)
            .map { Self.format($0, "yyyy-MM-dd HH:mm") }
        return Entry(folder: folder, name: Self.stemOfFile(url.lastPathComponent),
                     date: header.date ?? created, duration: header.duration, path: url.path)
    }

    // The header Nosy writes: "- Date: 2026-10-23", "- Started: 16:13", "- Length: 1 min".
    static func header(of url: URL) -> (date: String?, duration: String?) {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return (nil, nil) }
        defer { try? handle.close() }
        let data = (try? handle.read(upToCount: 4096)) ?? Data()
        var day: String?
        var started: String?
        var duration: String?
        for raw in String(decoding: data, as: UTF8.self).components(separatedBy: .newlines).prefix(12) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("- Date: ") { day = String(line.dropFirst(8)) }
            if line.hasPrefix("- Started: ") { started = String(line.dropFirst(11)) }
            if line.hasPrefix("- Length: ") { duration = String(line.dropFirst(10)) }
        }
        let date = [day, started].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: " ")
        return (date.isEmpty ? nil : date, duration)
    }

    private static func newestFirst(_ a: Entry, _ b: Entry) -> Bool {
        let left = a.date ?? "", right = b.date ?? ""
        if left != right { return left > right }
        return (a.folder, a.name) < (b.folder, b.name)
    }

    static func snippet(_ line: String, around match: Range<String.Index>) -> String {
        let start = line.index(match.lowerBound, offsetBy: -120, limitedBy: line.startIndex) ?? line.startIndex
        let end = line.index(match.upperBound, offsetBy: 160, limitedBy: line.endIndex) ?? line.endIndex
        var text = String(line[start..<end]).trimmingCharacters(in: .whitespaces)
        if start > line.startIndex { text = "..." + text }
        if end < line.endIndex { text += "..." }
        return text
    }

    private static func format(_ date: Date, _ pattern: String) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = pattern
        return formatter.string(from: date)
    }
}

// Where the transcripts are, resolved the same way the app does: environment override, then the
// folder chosen in Settings (stored in the app's preferences), then the default locations.
enum TranscriptRoot {
    static let preferenceKey = "transcriptsFolder"
    static let appDomain = "com.bardya.nosy"

    static func resolve(environment: [String: String] = ProcessInfo.processInfo.environment,
                        stored: String? = storedFolder(),
                        home: URL = FileManager.default.homeDirectoryForCurrentUser) -> URL {
        if let override = environment["NOSY_TRANSCRIPTS_DIR"], !override.isEmpty {
            return URL(fileURLWithPath: override, isDirectory: true)
        }
        if let stored, !stored.isEmpty {
            return URL(fileURLWithPath: stored, isDirectory: true)
        }
        // People who used Lecture Transcriber keep their Desktop folder; everyone else gets ~/Documents/Nosy.
        let legacy = home.appendingPathComponent("Desktop/Lecture Transcripts", isDirectory: true)
        var isDirectory: ObjCBool = false
        if FileManager.default.fileExists(atPath: legacy.path, isDirectory: &isDirectory), isDirectory.boolValue {
            return legacy
        }
        return home.appendingPathComponent("Documents/Nosy", isDirectory: true)
    }

    static func storedFolder() -> String? {
        CFPreferencesCopyAppValue(preferenceKey as CFString, appDomain as CFString) as? String
    }
}
