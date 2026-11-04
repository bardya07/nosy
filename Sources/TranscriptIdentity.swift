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
    // Install the attribute first. An orphaned UUID attribute can be reused after an
    // interrupted initialization; an index alone is never proof of document ownership.
    static func index(_ transcript: URL, id requestedID: String? = nil) throws {
        let existing = attributeValue(transcript)
        if let existing, UUID(uuidString: existing) == nil || (requestedID != nil && requestedID != existing) {
            throw LectureError.message("This transcript has a different identity; its existing metadata was kept.")
        }
        let id = requestedID ?? existing ?? UUID().uuidString
        var installed = false
        if existing == nil {
            try createAttribute(id, on: transcript)
            installed = true
        }
        do {
            let data = try JSONEncoder().encode(Index(version: 1, id: id))
            guard try Core.exclusiveWrite(data, to: url(for: transcript)) else {
                throw LectureError.message("A different item already occupies the transcript identity file name.")
            }
        } catch {
            if installed && attributeValue(transcript) == id {
                _ = removexattr(transcript.path, attribute, XATTR_NOFOLLOW)
            }
            throw error
        }
    }
    static func bind(_ transcript: URL, id: String) throws {
        try index(transcript, id: id)
    }
    // User-initiated repair deliberately allocates a new identity. A missing attribute
    // cannot authenticate the old index or reauthorize any associated recording.
    static func repairMissingAttribute(_ transcript: URL) throws {
        guard let oldID = indexID(transcript) else {
            throw LectureError.message("This transcript has no usable identity to repair.")
        }
        guard attributeValue(transcript) == nil, indexID(transcript) == oldID else {
            throw LectureError.message("The transcript identity changed during repair. Try again.")
        }
        let id = UUID().uuidString
        let data = try JSONEncoder().encode(Index(version: 1, id: id))
        // Replace the old index first. If interrupted or attribute creation fails, the
        // document still has no attribute and the explicit repair can be retried. No
        // recording can acquire authority from this newly generated index alone.
        try data.write(to: url(for: transcript), options: .atomic)
        try createAttribute(id, on: transcript)
    }
    private static func createAttribute(_ id: String, on transcript: URL) throws {
        let bytes = Array(id.utf8)
        guard bytes.withUnsafeBytes({ setxattr(transcript.path, attribute, $0.baseAddress, $0.count, 0, XATTR_NOFOLLOW | XATTR_CREATE) }) == 0 else {
            let code = errno
            if code == EEXIST {
                throw LectureError.message("This transcript already has an identity attribute; its metadata was kept.")
            }
            throw LectureError.message("Nosy could not save the transcript identity attribute (error \(code)). Choose a writable library on storage that supports extended attributes.")
        }
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
