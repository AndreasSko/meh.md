import CryptoKit
import Foundation

/// Stores chat transcripts separately from notebook Markdown and sync data.
/// Callers choose the app-local directory; records are partitioned by provider
/// and account and excluded from device backups.
public actor AssistantThreadStore {
    private struct StoredThreads: Codable {
        let version: Int
        let threads: [AssistantThread]
    }

    private let directory: URL
    private let fileManager: FileManager

    public init(
        directory: URL,
        fileManager: FileManager = .default
    ) {
        self.directory = directory
        self.fileManager = fileManager
    }

    public func load(
        providerID: String,
        accountID: String
    ) throws -> [AssistantThread] {
        let file = try fileURL(providerID: providerID, accountID: accountID)
        guard fileManager.fileExists(atPath: file.path) else { return [] }
        let stored = try JSONDecoder().decode(
            StoredThreads.self, from: Data(contentsOf: file)
        )
        guard stored.version == 1 else {
            throw AssistantThreadStoreError.unsupportedVersion(stored.version)
        }
        return Self.ordered(stored.threads)
    }

    public func save(
        _ threads: [AssistantThread],
        providerID: String,
        accountID: String
    ) throws {
        let file = try fileURL(providerID: providerID, accountID: accountID)
        let stored = StoredThreads(version: 1, threads: Self.ordered(threads))
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        try encoder.encode(stored).write(to: file, options: .atomic)
        try excludeFromBackup(file)
        try applyFileProtection(to: file)
    }

    private func fileURL(providerID: String, accountID: String) throws -> URL {
        guard !providerID.isEmpty, !accountID.isEmpty else {
            throw AssistantThreadStoreError.missingPartition
        }
        try fileManager.createDirectory(
            at: directory, withIntermediateDirectories: true
        )
        try excludeFromBackup(directory)
        try applyFileProtection(to: directory)
        let partition = SHA256.hash(data: Data((providerID + "\0" + accountID).utf8))
            .map { String(format: "%02x", $0) }
            .joined()
        return directory.appending(path: "threads-\(partition).json")
    }

    private func excludeFromBackup(_ url: URL) throws {
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        var mutableURL = url
        try mutableURL.setResourceValues(values)
    }

    private func applyFileProtection(to url: URL) throws {
        #if os(iOS)
        try fileManager.setAttributes(
            [.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication],
            ofItemAtPath: url.path
        )
        #endif
    }

    private static func ordered(_ threads: [AssistantThread]) -> [AssistantThread] {
        threads.sorted {
            if $0.updatedAt != $1.updatedAt { return $0.updatedAt > $1.updatedAt }
            return $0.id.uuidString < $1.id.uuidString
        }
    }
}

public enum AssistantThreadStoreError: LocalizedError, Equatable, Sendable {
    case missingPartition
    case unsupportedVersion(Int)

    public var errorDescription: String? {
        switch self {
        case .missingPartition:
            "A provider and account are required to save assistant chats."
        case .unsupportedVersion:
            "These assistant chats were saved by a newer app version."
        }
    }
}
