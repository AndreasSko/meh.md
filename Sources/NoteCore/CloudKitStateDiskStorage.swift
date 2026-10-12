import CryptoKit
import Foundation

/// Local disk representation only. Cloud records and exported SyncRecords keep
/// their existing inline Codable format. Payloads are committed before the
/// small manifest; an interrupted commit can only leave an unused payload.
final class CloudKitStateDiskStorage {
    static let contextKey = CodingUserInfoKey(rawValue: "cloudkitDiskStorage")!
    static let formatVersion = 1

    struct Reference: Codable, Equatable {
        let digest: String
        let recordID: String
    }

    private struct Header: Decodable {
        let diskFormatVersion: Int?
    }

    private let directory: URL
    private var cached: [String: (record: SyncRecord, reference: Reference)] = [:]

    init(directory: URL) {
        self.directory = directory.appendingPathComponent("cloudkit-sync-payloads")
    }

    func decode(_ data: Data) throws -> (state: CloudKitTransportState, legacy: Bool) {
        let decoder = JSONDecoder()
        let version = try decoder.decode(Header.self, from: data).diskFormatVersion
        if let version {
            guard version == Self.formatVersion else {
                throw CloudKitSyncTransportError.corruptState
            }
            decoder.userInfo[Self.contextKey] = self
        }
        return (try decoder.decode(CloudKitTransportState.self, from: data), version == nil)
    }

    func encode(_ state: CloudKitTransportState) throws -> Data {
        try Task.checkCancellation()
        let encoder = JSONEncoder()
        encoder.userInfo[Self.contextKey] = self
        return try encoder.encode(state)
    }

    func reference(for record: SyncRecord) throws -> Reference {
        if let entry = cached[record.id], entry.record == record {
            return entry.reference
        }
        try Task.checkCancellation()
        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys
        let data = try encoder.encode(record)
        let digest = Self.digest(data)
        let reference = Reference(digest: digest, recordID: record.id)
        try Task.checkCancellation()
        let url = try payloadURL(reference)
        if FileManager.default.fileExists(atPath: url.path) {
            // A preexisting file may be an orphan from an earlier interrupted
            // commit. Never trust its name alone or overwrite corrupt bytes.
            guard try Data(contentsOf: url) == data else {
                throw CloudKitSyncTransportError.corruptState
            }
        } else {
            try SyncFileIO.replace(data, at: url)
        }
        cached[record.id] = (record, reference)
        return reference
    }

    func record(for reference: Reference) throws -> SyncRecord {
        if let entry = cached[reference.recordID], entry.reference == reference {
            return entry.record
        }
        let data = try Data(contentsOf: payloadURL(reference))
        guard Self.digest(data) == reference.digest else {
            throw CloudKitSyncTransportError.corruptState
        }
        let record = try JSONDecoder().decode(SyncRecord.self, from: data)
        guard record.id == reference.recordID else {
            throw CloudKitSyncTransportError.corruptState
        }
        cached[record.id] = (record, reference)
        return record
    }

    /// Release in-memory evidence for retired records. Disk payloads remain
    /// available to the old manifest and any interrupted/local replay.
    func didCommit(_ state: CloudKitTransportState) {
        let retained = Set(state.inbox.map(\.id)).union(state.outbox.keys)
        cached = cached.filter { retained.contains($0.key) }
    }

    private func payloadURL(_ reference: Reference) throws -> URL {
        guard Self.isDigest(reference.digest), Self.isDigest(reference.recordID) else {
            throw CloudKitSyncTransportError.corruptState
        }
        let url = directory.appendingPathComponent(reference.digest + ".json")
        for candidate in [directory, url] {
            if (try? candidate.resourceValues(
                forKeys: [.isSymbolicLinkKey]
            ).isSymbolicLink) == true {
                throw CloudKitSyncTransportError.corruptState
            }
        }
        return url
    }

    private static func isDigest(_ value: String) -> Bool {
        value.utf8.count == 64 && value.utf8.allSatisfy {
            (48...57).contains($0) || (97...102).contains($0)
        }
    }

    private static func digest(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
}
