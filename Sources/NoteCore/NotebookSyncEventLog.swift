import CloudKit
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

    public init(directory: URL) {
        fileURL = directory.appending(path: "notebook-sync-events.json")
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
        persist()
    }

    public func clear() {
        entries = []
        persist()
    }

    public static func errorCode(_ error: any Error) -> String {
        if let error = error as? CloudKitStateWriteFailure {
            return "CloudKitStateWriteFailure."
                + errorCode(error.underlyingError)
        }
        if let error = error as? CKError {
            return "CKError.\(error.code.rawValue)"
        }
        if let error = error as? SyncError {
            switch error {
            case .invalidRecord: return "SyncError.invalidRecord"
            case .identityConflict: return "SyncError.identityConflict"
            case .disconnectedHistory: return "SyncError.disconnectedHistory"
            case .scopeChanged: return "SyncError.scopeChanged"
            case .invalidCursor: return "SyncError.invalidCursor"
            case .localSaveRequired: return "SyncError.localSaveRequired"
            case .unavailable: return "SyncError.unavailable"
            }
        }
        if let error = error as? CloudKitSyncTransportError {
            switch error {
            case .accountUnavailable: return "CloudKitSyncTransportError.accountUnavailable"
            case .corruptState: return "CloudKitSyncTransportError.corruptState"
            case .invalidRemoteRecord:
                return "CloudKitSyncTransportError.invalidRemoteRecord"
            case .unexpectedDeletion:
                return "CloudKitSyncTransportError.unexpectedDeletion"
            case .uploadFailed(let code):
                return "CloudKitSyncTransportError.uploadFailed.\(code)"
            case .uploadNotAcknowledged:
                return "CloudKitSyncTransportError.uploadNotAcknowledged"
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
            }
        }
        if let error = error as? CocoaError {
            return "CocoaError.\(error.code.rawValue)"
        }
        if error is CancellationError { return "CancellationError" }
        let typeName = String(describing: type(of: error))
        return "\(typeName).\((error as NSError).code)"
    }

    private func persist() {
        do {
            try SyncFileIO.replace(JSONEncoder().encode(entries), at: fileURL)
        } catch {
            persistenceError = true
        }
    }
}
