import Darwin
import Foundation

struct SyncState: Codable, Equatable, Sendable {
    var version = 1
    let scope: String
    var cursor: String?
    var acknowledgedHeads: Set<String> = []
    var appliedHeads: Set<String>?
    var lastExchange: Date?
}

actor SyncStateStorage {
    let url: URL

    init(url: URL) { self.url = url }

    func load(scope: String) throws -> SyncState {
        let data: Data
        do {
            data = try Data(contentsOf: url)
        } catch CocoaError.fileReadNoSuchFile {
            return SyncState(scope: scope)
        }
        let state = try JSONDecoder().decode(SyncState.self, from: data)
        guard state.version == 1 else { throw SyncError.invalidRecord }
        guard state.scope == scope else { throw SyncError.scopeChanged }
        return state
    }

    func save(_ state: SyncState) throws {
        try SyncFileIO.replace(JSONEncoder().encode(state), at: url)
    }
}

/// Local sync metadata follows the same flush/rename discipline as note files.
enum SyncFileIO {
    static func replace(_ data: Data, at url: URL) throws {
        let directory = url.deletingLastPathComponent()
        try FileManager.default.createDirectory(
            at: directory, withIntermediateDirectories: true
        )
        let temporary = directory.appendingPathComponent(".sync-\(UUID())")
        defer { try? FileManager.default.removeItem(at: temporary) }
        try data.write(to: temporary, options: .withoutOverwriting)
        let handle = try FileHandle(forWritingTo: temporary)
        defer { try? handle.close() }
        try handle.synchronize()
        guard rename(temporary.path, url.path) == 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
        let descriptor = open(directory.path, O_RDONLY)
        guard descriptor >= 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
        defer { close(descriptor) }
        guard fsync(descriptor) == 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
    }
}
