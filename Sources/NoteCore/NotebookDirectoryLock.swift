import Foundation
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

/// Keeps a second process from opening a notebook that another process
/// already uses, for example two copies of the Mac app. The lock is a
/// kernel lock on an open file, so it ends when the holder exits, even after
/// a crash or `kill -9`. The lock file itself is never deleted: a process
/// that recreated it could lock a different file at the same path.
public enum NotebookDirectoryLock {
    public struct InUse: Error, LocalizedError, Equatable {
        public init() {}

        public var errorDescription: String? {
            "This notebook is already open in another copy of meh.md. "
                + "Quit the other copy, then try again."
        }
    }

    private static let lock = NSLock()
    // Access is always under lock. Descriptors stay open until the process
    // exits, which is what keeps the notebook claimed.
    nonisolated(unsafe) private static var held = [String: Int32]()

    /// Claims `directory` for this process until it exits. Repeated claims
    /// from this process succeed; claims from other processes throw `InUse`.
    public static func claim(_ directory: URL) throws {
        let url = lockFile(for: directory)
        lock.lock()
        defer { lock.unlock() }
        guard held[url.path] == nil else { return }
        held[url.path] = try acquire(url)
    }

    /// A sibling of the notebook folder, so resetting local storage, which
    /// deletes that folder, keeps the lock in place.
    static func lockFile(for directory: URL) -> URL {
        let directory = directory.standardizedFileURL
        return directory.deletingLastPathComponent()
            .appending(path: directory.lastPathComponent + ".lock")
    }

    /// Returns the open descriptor that holds the lock.
    static func acquire(_ url: URL) throws -> Int32 {
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let fd = open(url.path, O_RDWR | O_CREAT | O_CLOEXEC, 0o600)
        guard fd >= 0 else { throw posixError(errno) }
        var result: Int32
        repeat { result = flock(fd, LOCK_EX | LOCK_NB) }
        while result != 0 && errno == EINTR
        guard result == 0 else {
            let code = errno
            close(fd)
            if code == EWOULDBLOCK { throw InUse() }
            throw posixError(code)
        }
        return fd
    }

    private static func posixError(_ code: Int32) -> POSIXError {
        POSIXError(POSIXErrorCode(rawValue: code) ?? .EIO)
    }
}
