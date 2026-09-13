import Darwin
import Foundation

enum DurableFileIO {
    static func writeAndSync(_ data: Data, to url: URL) throws {
        let descriptor = open(
            url.path,
            O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC,
            S_IRUSR | S_IWUSR
        )
        guard descriptor >= 0 else { throw posixError() }
        defer { close(descriptor) }

        try data.withUnsafeBytes { rawBuffer in
            guard let baseAddress = rawBuffer.baseAddress else { return }
            var written = 0
            while written < rawBuffer.count {
                let result = Darwin.write(
                    descriptor,
                    baseAddress.advanced(by: written),
                    rawBuffer.count - written
                )
                if result < 0, errno == EINTR {
                    continue
                }
                guard result > 0 else { throw posixError() }
                written += result
            }
        }
        guard fsync(descriptor) == 0 else { throw posixError() }
    }

    static func renameReplacing(
        _ source: URL,
        with destination: URL
    ) throws {
        let result = source.withUnsafeFileSystemRepresentation { sourcePath in
            destination.withUnsafeFileSystemRepresentation {
                destinationPath in
                rename(sourcePath, destinationPath)
            }
        }
        guard result == 0 else { throw posixError() }
    }

    static func syncDirectory(_ directory: URL) throws {
        let descriptor = open(directory.path, O_RDONLY | O_CLOEXEC)
        guard descriptor >= 0 else { throw posixError() }
        defer { close(descriptor) }
        guard fsync(descriptor) == 0 else { throw posixError() }
    }

    static func posixError() -> NSError {
        NSError(domain: NSPOSIXErrorDomain, code: Int(errno))
    }
}
