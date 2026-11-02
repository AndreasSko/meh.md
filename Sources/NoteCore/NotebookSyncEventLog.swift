import Foundation
import Observation

@MainActor
@Observable
public final class NotebookSyncEventLog {
    public struct Entry: Codable, Equatable, Sendable {
        public let timestamp: Date
        public let event: String
        public let counts: [String: Int]
    }

    public private(set) var entries: [Entry]
    public private(set) var persistenceError = false
    @ObservationIgnored private let fileURL: URL
    @ObservationIgnored private let maximumEntries = 500
    @ObservationIgnored private let writer: NotebookSyncEventLogWriter
    @ObservationIgnored private var generation: UInt64 = 0
    @ObservationIgnored private var scheduledWrite: Task<Void, Never>?

    private static let writeDelay: Duration = .milliseconds(500)

    public init(directory: URL) {
        fileURL = directory.appending(path: "notebook-sync-events.json")
        writer = NotebookSyncEventLogWriter()
        do {
            let decoded = try JSONDecoder().decode(
                [Entry].self,
                from: Data(contentsOf: fileURL)
            )
            entries = Array(decoded.suffix(maximumEntries))
        } catch CocoaError.fileReadNoSuchFile {
            entries = []
        } catch {
            entries = []
            persistenceError = true
        }
    }

    init(
        directory: URL,
        write: @escaping @Sendable (Data, URL) throws -> Void
    ) {
        fileURL = directory.appending(path: "notebook-sync-events.json")
        writer = NotebookSyncEventLogWriter(write: write)
        do {
            let decoded = try JSONDecoder().decode(
                [Entry].self,
                from: Data(contentsOf: fileURL)
            )
            entries = Array(decoded.suffix(maximumEntries))
        } catch CocoaError.fileReadNoSuchFile {
            entries = []
        } catch {
            entries = []
            persistenceError = true
        }
    }

    public var exportText: String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let lines = entries.map { entry in
            let counts = entry.counts.keys.sorted().map {
                "\($0)=\(entry.counts[$0]!)"
            }.joined(separator: " ")
            return "\(formatter.string(from: entry.timestamp)) \(entry.event)" +
                (counts.isEmpty ? "" : " | " + counts)
        }
        return "Sync event log v1; latest 500 events; times in UTC\n" +
            (lines.isEmpty ? "No recorded events." : lines.joined(separator: "\n"))
    }

    public func record(_ event: String, counts: [String: Int] = [:]) {
        entries.append(Entry(timestamp: Date(), event: event, counts: counts))
        if entries.count > maximumEntries {
            entries.removeFirst(entries.count - maximumEntries)
        }
        scheduleWrite()
    }

    public func clear() {
        entries = []
        scheduleWrite()
    }

    /// Waits until the latest event-log snapshot has been durably replaced.
    public func flush() async {
        scheduledWrite?.cancel()
        scheduledWrite = nil
        while true {
            let currentGeneration = generation
            let data: Data
            do {
                data = try JSONEncoder().encode(entries)
            } catch {
                persistenceError = true
                return
            }
            let succeeded = await writer.write(
                data, at: fileURL, generation: currentGeneration
            )
            if generation == currentGeneration {
                persistenceError = !succeeded
                return
            }
        }
    }

    public static func errorCode(_ error: any Error) -> String {
        if let error = error as? LocalNoteSaveFailure {
            return "LocalNoteSaveFailure." + errorCode(error.underlyingError)
        }
        if let code = SyncBackends.diagnosticCode(of: error, nested: errorCode) {
            return code
        }
        if let error = error as? SyncError {
            switch error {
            case .invalidRecord: return "SyncError.invalidRecord"
            case .identityConflict: return "SyncError.identityConflict"
            case .disconnectedHistory: return "SyncError.disconnectedHistory"
            case .scopeChanged: return "SyncError.scopeChanged"
            case .invalidCursor: return "SyncError.invalidCursor"
            case .localSaveRequired: return "SyncError.localSaveRequired"
            case .updateRequired: return "SyncError.updateRequired"
            case .unavailable: return "SyncError.unavailable"
            }
        }
        if let error = error as? NotebookReplicaError {
            switch error {
            case .notJoined: return "NotebookReplicaError.notJoined"
            case .busy: return "NotebookReplicaError.busy"
            case .catalogNeedsRecovery:
                return "NotebookReplicaError.catalogNeedsRecovery"
            case .catalogUnavailable:
                return "NotebookReplicaError.catalogUnavailable"
            case .noteUnavailable: return "NotebookReplicaError.noteUnavailable"
            case .permanentlyDeleted:
                return "NotebookReplicaError.permanentlyDeleted"
            case .pinLimitReached:
                return "NotebookReplicaError.pinLimitReached"
            case .resetPending:
                return "NotebookReplicaError.resetPending"
            }
        }
        if let error = error as? CocoaError {
            return "CocoaError.\(error.code.rawValue)"
        }
        if error is CancellationError { return "CancellationError" }
        let typeName = String(describing: type(of: error))
        return "\(typeName).\((error as NSError).code)"
    }

    private func scheduleWrite() {
        generation &+= 1
        scheduledWrite?.cancel()
        scheduledWrite = Task { [weak self] in
            do {
                try await Task.sleep(for: Self.writeDelay)
                await self?.flush()
            } catch is CancellationError {
                return
            } catch {
                self?.markPersistenceError()
            }
        }
    }

    private func markPersistenceError() {
        persistenceError = true
    }
}

/// Serializes atomic file replacements away from the main actor.
private final class NotebookSyncEventLogWriter: @unchecked Sendable {
    private let queue = DispatchQueue(
        label: "meh.notebook-sync-event-log-writer",
        qos: .utility
    )
    private let writeFile: @Sendable (Data, URL) throws -> Void

    init(write: @escaping @Sendable (Data, URL) throws -> Void = {
        try SyncFileIO.replace($0, at: $1)
    }) {
        writeFile = write
    }

    func write(_ data: Data, at url: URL, generation: UInt64) async -> Bool {
        await withCheckedContinuation { continuation in
            queue.async { [self] in
                guard generation >= latestGeneration else {
                    continuation.resume(returning: false)
                    return
                }
                latestGeneration = generation
                do {
                    try writeFile(data, url)
                    continuation.resume(returning: true)
                } catch {
                    continuation.resume(returning: false)
                }
            }
        }
    }

    // Accessed only by the serial utility queue.
    private var latestGeneration: UInt64 = 0
}
