import CryptoKit
import Darwin
import Foundation
import XCTest

@testable import NoteCore

final class CloudKitAttachmentAssetCopyTests: XCTestCase {
    private final class Mutation: @unchecked Sendable {
        let source: URL
        let persistent: Bool
        let changeBytes: Bool
        let corruptSameSize: Bool
        let changeTimeOnly: Bool
        private let lock = NSLock()
        private var reads = 0

        init(source: URL, persistent: Bool = false, changeBytes: Bool = false,
             changeTimeOnly: Bool = false, corruptSameSize: Bool = false) {
            self.source = source
            self.persistent = persistent
            self.changeBytes = changeBytes
            self.changeTimeOnly = changeTimeOnly
            self.corruptSameSize = corruptSameSize
        }

        var count: Int { lock.withLock { reads } }

        func apply() throws {
            try lock.withLock {
                reads += 1
                guard persistent || reads == 1 else { return }
                if corruptSameSize {
                    var original = stat()
                    guard lstat(source.path, &original) == 0 else { throw CocoaError(.fileReadUnknown) }
                    let file = try FileHandle(forWritingTo: source)
                    try file.write(contentsOf: Data([255]))
                    try file.synchronize()
                    try file.close()
                    var times = [original.st_atimespec, original.st_mtimespec]
                    guard utimensat(AT_FDCWD, source.path, &times, 0) == 0 else {
                        throw CocoaError(.fileWriteUnknown)
                    }
                } else if changeBytes {
                    let file = try FileHandle(forWritingTo: source)
                    defer { try? file.close() }
                    try file.seekToEnd()
                    try file.write(contentsOf: Data([99]))
                    try file.synchronize()
                } else if changeTimeOnly {
                    try FileManager.default.setAttributes([
                        .posixPermissions: reads % 2 == 1 ? 0o640 : 0o600
                    ], ofItemAtPath: source.path)
                } else {
                    try FileManager.default.setAttributes([
                        .modificationDate: Date(timeIntervalSince1970:
                            1_000_000 + Double(reads))
                    ], ofItemAtPath: source.path)
                }
            }
        }
    }

    private func fixture() throws -> (
        root: URL, source: URL, descriptor: NotebookAttachmentDescriptor
    ) {
        let root = FileManager.default.temporaryDirectory
            .appending(path: "CloudKitAssetCopy-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let source = root.appending(path: "Fictional.bin")
        let bytes = Data((0..<200_000).map { UInt8($0 % 251) })
        try bytes.write(to: source)
        let hash = SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined()
        return (root, source, .init(id: UUID(), content: try .init(
            sha256: hash, byteCount: Int64(bytes.count))))
    }

    func testCloudAssetAcceptsOnlyChangeTimeDriftWithTrustedContent() async throws {
        let fixture = try fixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        var before = stat()
        XCTAssertEqual(lstat(fixture.source.path, &before), 0)
        let mutation = Mutation(source: fixture.source, changeTimeOnly: true)
        let store = NotebookAttachmentStore(directory: fixture.root.appending(path: "files"),
            sourceReadHook: { try mutation.apply() })

        let copied = try await CloudKitAttachmentAssetCopy.store(
            fixture.source, descriptor: fixture.descriptor, in: store)

        var after = stat()
        XCTAssertEqual(lstat(fixture.source.path, &after), 0)
        XCTAssertEqual(before.st_mtimespec.tv_sec, after.st_mtimespec.tv_sec)
        XCTAssertEqual(before.st_mtimespec.tv_nsec, after.st_mtimespec.tv_nsec)
        XCTAssertTrue(before.st_ctimespec.tv_sec != after.st_ctimespec.tv_sec
            || before.st_ctimespec.tv_nsec != after.st_ctimespec.tv_nsec)
        XCTAssertEqual(copied, fixture.descriptor)
        XCTAssertEqual(mutation.count, 1)
        let url = try await store.verifiedFileURL(for: copied)
        XCTAssertEqual(try Data(contentsOf: url), try Data(contentsOf: fixture.source))
    }

    func testSameSizeCorruptionWithRestoredMtimePublishesNothing() async throws {
        let fixture = try fixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        var before = stat()
        XCTAssertEqual(lstat(fixture.source.path, &before), 0)
        let mutation = Mutation(source: fixture.source, corruptSameSize: true)
        let directory = fixture.root.appending(path: "files")
        let store = NotebookAttachmentStore(directory: directory,
            sourceReadHook: { try mutation.apply() })
        do {
            _ = try await CloudKitAttachmentAssetCopy.store(
                fixture.source, descriptor: fixture.descriptor, in: store)
            XCTFail("Trusted checksum must reject corruption despite restored mtime")
        } catch {
            XCTAssertEqual(error as? NotebookAttachmentError, .checksumMismatch)
        }
        var after = stat()
        XCTAssertEqual(lstat(fixture.source.path, &after), 0)
        XCTAssertEqual(before.st_size, after.st_size)
        XCTAssertEqual(before.st_mtimespec.tv_sec, after.st_mtimespec.tv_sec)
        XCTAssertEqual(before.st_mtimespec.tv_nsec, after.st_mtimespec.tv_nsec)
        XCTAssertTrue(before.st_ctimespec.tv_sec != after.st_ctimespec.tv_sec
            || before.st_ctimespec.tv_nsec != after.st_ctimespec.tv_nsec)
        XCTAssertEqual(mutation.count, 1)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: directory.path), [])
    }

    func testLocalImportStillRejectsChangeTimeOnlyMutation() async throws {
        let fixture = try fixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let mutation = Mutation(source: fixture.source, changeTimeOnly: true)
        let directory = fixture.root.appending(path: "files")
        let store = NotebookAttachmentStore(directory: directory,
            sourceReadHook: { try mutation.apply() })

        do {
            _ = try await store.storeFile(at: fixture.source,
                attachmentID: fixture.descriptor.id)
            XCTFail("Original-file imports must keep strict metadata checks")
        } catch {
            XCTAssertEqual(error as? NotebookAttachmentError, .sourceChanged)
        }
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: directory.path), [])
    }

    func testTransientMetadataChangeRetriesStrictCopyAndVerifiesBytes() async throws {
        let fixture = try fixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let mutation = Mutation(source: fixture.source)
        let store = NotebookAttachmentStore(directory: fixture.root.appending(path: "files"),
            sourceReadHook: { try mutation.apply() })

        let copied = try await CloudKitAttachmentAssetCopy.store(
            fixture.source, descriptor: fixture.descriptor, in: store)

        XCTAssertEqual(copied, fixture.descriptor)
        XCTAssertEqual(mutation.count, 2)
        let url = try await store.verifiedFileURL(for: copied)
        XCTAssertEqual(try Data(contentsOf: url), try Data(contentsOf: fixture.source))
    }

    func testPersistentMutationFailsAfterThreeAttemptsAndPublishesNothing() async throws {
        let fixture = try fixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let mutation = Mutation(source: fixture.source, persistent: true)
        let directory = fixture.root.appending(path: "files")
        let store = NotebookAttachmentStore(directory: directory,
            sourceReadHook: { try mutation.apply() })

        do {
            _ = try await CloudKitAttachmentAssetCopy.store(
                fixture.source, descriptor: fixture.descriptor, in: store)
            XCTFail("Persistent source mutation must fail")
        } catch {
            XCTAssertEqual(error as? NotebookAttachmentError, .sourceChanged)
        }
        XCTAssertEqual(mutation.count, 3)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: directory.path), [])
    }

    func testChangedBytesRemainChecksumFailureAfterSourceSettles() async throws {
        let fixture = try fixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let mutation = Mutation(source: fixture.source, changeBytes: true)
        let directory = fixture.root.appending(path: "files")
        let store = NotebookAttachmentStore(directory: directory,
            sourceReadHook: { try mutation.apply() })

        do {
            _ = try await CloudKitAttachmentAssetCopy.store(
                fixture.source, descriptor: fixture.descriptor, in: store)
            XCTFail("A stable changed source must still fail the trusted checksum")
        } catch {
            XCTAssertEqual(error as? NotebookAttachmentError, .checksumMismatch)
        }
        XCTAssertEqual(mutation.count, 2)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: directory.path), [])
    }
}
