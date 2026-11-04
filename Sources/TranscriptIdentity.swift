import Foundation
import Darwin

// The index is beside the document and survives audio retention and edits to its Markdown.
// The extended attribute separately proves that a recording still owns the file at that path.
enum TranscriptIdentity {
    private struct Index: Codable { let version: Int; let id: String }
    private static let attribute = "com.bardya.nosy.transcript-id"
    static func url(for transcript: URL) -> URL {
        transcript.deletingLastPathComponent().appendingPathComponent(
            "." + transcript.deletingPathExtension().lastPathComponent + ".nosy-identity.json")
    }
    static func indexID(_ transcript: URL) -> String? {
        let index = url(for: transcript)
        var info = stat()
        guard index.path.withCString({ lstat($0, &info) }) == 0, (info.st_mode & S_IFMT) == S_IFREG,
              let data = try? Data(contentsOf: index), let value = try? JSONDecoder().decode(Index.self, from: data),
              value.version == 1, UUID(uuidString: value.id) != nil else { return nil }
        return value.id
    }
    static func indexed(_ transcript: URL) -> Bool { indexID(transcript) != nil }
    // Existing libraries gain an index without guessing which recording owns the document.
    static func index(_ transcript: URL, id: String = UUID().uuidString) throws {
        let data = try JSONEncoder().encode(Index(version: 1, id: id))
        guard try Core.exclusiveWrite(data, to: url(for: transcript)) else {
            throw LectureError.message("A different item already occupies the transcript identity file name.")
        }
    }
    static func bind(_ transcript: URL, id: String) throws {
        try index(transcript, id: id)
        try setAttribute(id, on: transcript)
    }
    static func attributeValue(_ transcript: URL) -> String? {
        let size = getxattr(transcript.path, attribute, nil, 0, 0, XATTR_NOFOLLOW)
        guard size > 0 && size < 256 else { return nil }
        var bytes = [UInt8](repeating: 0, count: size)
        let read = getxattr(transcript.path, attribute, &bytes, size, 0, XATTR_NOFOLLOW)
        guard read == size else { return nil }
        return String(bytes: bytes, encoding: .utf8)
    }
    static func setAttribute(_ id: String, on transcript: URL) throws {
        let bytes = Array(id.utf8)
        guard bytes.withUnsafeBytes({ setxattr(transcript.path, attribute, $0.baseAddress, $0.count, 0, XATTR_NOFOLLOW) }) == 0 else {
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno))
        }
    }
    static func move(from old: URL, to new: URL) throws {
        guard indexed(old) else { return }
        try FileManager.default.moveItem(at: url(for: old), to: url(for: new))
    }
    static func trash(_ transcript: URL) throws {
        guard indexed(transcript) else { return }
        try FileManager.default.trashItem(at: url(for: transcript), resultingItemURL: nil)
    }
}
