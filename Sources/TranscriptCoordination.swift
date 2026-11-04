import Foundation
import Darwin

// Retention and library mutations must agree about ownership through the entire
// check-and-delete operation, including when a headless Nosy process is running.
enum TranscriptCoordination {
    private static let processLock = NSLock()

    static func withLock<T>(paths: AppPaths, _ operation: () throws -> T) throws -> T {
        processLock.lock()
        defer { processLock.unlock() }
        try paths.createSupportDirectory(paths.support)
        let file = paths.support.appendingPathComponent("transcript-mutation.lock")
        let fd = open(file.path, O_RDWR | O_CREAT | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard fd >= 0 else { throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno)) }
        defer { close(fd) }
        var info = stat()
        guard fstat(fd, &info) == 0, (info.st_mode & S_IFMT) == S_IFREG,
              info.st_uid == getuid(), info.st_nlink == 1,
              paths.safeSupportItem(file, directory: false) else {
            throw LectureError.message("Unsafe transcript coordination storage.")
        }
        while flock(fd, LOCK_EX) != 0 {
            guard errno == EINTR else { throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno)) }
        }
        defer { _ = flock(fd, LOCK_UN) }
        return try operation()
    }
}
