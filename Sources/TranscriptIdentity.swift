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
    // Probe the actual attribute used by transcripts before accepting a new library.
    // The exclusive name belongs to this probe; only remove it if it still names the
    // same regular file, so an independently replaced item is left alone.
    static func checkStorage(at folder: URL) throws {
        let probe = folder.appendingPathComponent(".nosy-identity-check-\(UUID().uuidString)")
        let fd = open(probe.path, O_RDWR | O_CREAT | O_EXCL | O_NOFOLLOW, 0o600)
        guard fd >= 0 else {
            throw LectureError.message("Nosy could not create a file in this folder (error \(errno)). Choose a writable library on storage that supports extended attributes.")
        }
        defer {
            var opened = stat(), named = stat()
            if fstat(fd, &opened) == 0, lstat(probe.path, &named) == 0,
               (named.st_mode & S_IFMT) == S_IFREG,
               opened.st_dev == named.st_dev, opened.st_ino == named.st_ino {
                _ = unlink(probe.path)
            }
            close(fd)
        }
        let id = UUID().uuidString
        let bytes = Array(id.utf8)
        guard bytes.withUnsafeBytes({ fsetxattr(fd, attribute, $0.baseAddress, $0.count, 0, XATTR_CREATE) }) == 0 else {
            throw LectureError.message("Nosy could not save transcript identity attributes in this folder (error \(errno)). Choose a writable library on storage that supports extended attributes.")
        }
        var result = [UInt8](repeating: 0, count: bytes.count)
        let count = fgetxattr(fd, attribute, &result, result.count, 0, 0)
        guard count == bytes.count, result == bytes else {
            throw LectureError.message("Nosy could not read transcript identity attributes in this folder. Choose a writable library on storage that supports extended attributes.")
        }
    }
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
        try KeyMomentStore.withSidecarLock {
            guard let oldID = indexID(transcript) else {
                throw LectureError.message("This transcript has no usable identity to repair.")
            }
            guard attributeValue(transcript) == nil, indexID(transcript) == oldID else {
                throw LectureError.message("The transcript identity changed during repair. Try again.")
            }
            try KeyMomentStore.scrubObsoleteIdentity(transcript: transcript, id: oldID)
            let id = UUID().uuidString
            let data = try JSONEncoder().encode(Index(version: 1, id: id))
            // A missing attribute never authorizes a recording under this new identity.
            try data.write(to: url(for: transcript), options: .atomic)
            try createAttribute(id, on: transcript)
        }
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
