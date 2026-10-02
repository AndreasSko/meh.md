import CryptoKit
import Darwin
import Foundation
import XCTest

@testable import NoteCore

final class NotebookAttachmentStoreTests: XCTestCase {
    private var root: URL!
    private var storeDirectory: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("NotebookAttachmentTests-\(UUID())", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        storeDirectory = root.appendingPathComponent("Store", isDirectory: true)
    }

    override func tearDownWithError() throws {
        try FileManager.default.removeItem(at: root)
        root = nil
        storeDirectory = nil
    }

    func testBinaryAndEmptyFilesSurviveStoreReopen() async throws {
        let store = NotebookAttachmentStore(directory: storeDirectory)
        let bytes = Data([0x00, 0xFF, 0xC3, 0x28, 0x0D, 0x0A, 0x80])
        let source = try write(bytes, named: "binary.dat")
        let id = UUID()
        let descriptor = try await store.storeFile(at: source, attachmentID: id)

        let reopened = NotebookAttachmentStore(directory: storeDirectory)
        let reopenedDescriptor = try await reopened.descriptor(for: id)
        XCTAssertEqual(reopenedDescriptor, descriptor)
        let verified = try await reopened.verifiedFileURL(for: descriptor)
        XCTAssertEqual(try Data(contentsOf: verified), bytes)

        let emptySource = try write(Data(), named: "empty.dat")
        let emptyID = UUID()
        let emptyDescriptor = try await reopened.storeFile(
            at: emptySource,
            attachmentID: emptyID
        )
        let emptyURL = try await reopened.verifiedFileURL(for: emptyDescriptor)
        XCTAssertEqual(try Data(contentsOf: emptyURL), Data())
    }

    func testCoordinatedLocalReadKeepsExactBytes() async throws {
        let bytes = Data((0..<200_000).map { UInt8($0 % 251) })
        let source = try write(bytes, named: "coordinated.pdf")
        let store = NotebookAttachmentStore(directory: storeDirectory)
        let id = UUID()
        let descriptor = try await store.storeCoordinatedFile(
            at: source, attachmentID: id
        )
        XCTAssertEqual(descriptor.content.byteCount, Int64(bytes.count))
        let stored = try await store.verifiedFileURL(for: descriptor)
        XCTAssertEqual(try Data(contentsOf: stored), bytes)
    }

    func testIdenticalRetryIsIdempotentAndDifferentBytesConflict() async throws {
        let store = NotebookAttachmentStore(directory: storeDirectory)
        let id = UUID()
        let firstBytes = Data("A fictional nebula map".utf8)
        let first = try write(firstBytes, named: "first.bin")
        let descriptor = try await store.storeFile(at: first, attachmentID: id)
        let retry = try await store.storeFile(at: first, attachmentID: id)
        XCTAssertEqual(retry, descriptor)

        let conflicting = try write(Data("a different fictional map".utf8), named: "other.bin")
        do {
            _ = try await store.storeFile(at: conflicting, attachmentID: id)
            XCTFail("Expected an identity conflict")
        } catch {
            XCTAssertEqual(error as? NotebookAttachmentError, .identityConflict(id))
        }
        let verifiedURL = try await store.verifiedFileURL(for: descriptor)
        XCTAssertEqual(try Data(contentsOf: verifiedURL), firstBytes)
    }

    func testExpectedDigestOrLengthMismatchPublishesNoAttachment() async throws {
        let store = NotebookAttachmentStore(directory: storeDirectory)
        let bytes = Data("verified source".utf8)
        let source = try write(bytes, named: "source.bin")
        let id = UUID()
        let wrongDigest = try NotebookAttachmentContent(
            sha256: String(repeating: "0", count: 64), byteCount: Int64(bytes.count)
        )
        do {
            _ = try await store.storeFile(
                at: source,
                attachmentID: id,
                expectedContent: wrongDigest
            )
            XCTFail("Expected the supplied digest to be checked")
        } catch {
            XCTAssertEqual(error as? NotebookAttachmentError, .checksumMismatch)
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: targetURL(id).path))

        let wrongLength = try NotebookAttachmentContent(
            sha256: digest(bytes), byteCount: Int64(bytes.count + 1)
        )
        do {
            _ = try await store.storeFile(
                at: source,
                attachmentID: id,
                expectedContent: wrongLength
            )
            XCTFail("Expected the supplied byte count to be checked")
        } catch {
            XCTAssertEqual(error as? NotebookAttachmentError, .checksumMismatch)
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: targetURL(id).path))
    }

    func testCorruptStoredBytesAreNeitherVerifiedNorAcceptedAsRetry() async throws {
        let store = NotebookAttachmentStore(directory: storeDirectory)
        let source = try write(Data("original fictional data".utf8), named: "source.bin")
        let id = UUID()
        let descriptor = try await store.storeFile(at: source, attachmentID: id)
        let contentURL = targetURL(id).appendingPathComponent("content")
        try Data("tampered".utf8).write(to: contentURL)

        do {
            _ = try await store.verifiedFileURL(for: descriptor)
            XCTFail("Corrupted bytes must not be verified")
        } catch {
            XCTAssertEqual(error as? NotebookAttachmentError, .checksumMismatch)
        }
        do {
            _ = try await store.storeFile(at: source, attachmentID: id)
            XCTFail("A retry must not acknowledge corrupted committed bytes")
        } catch {
            XCTAssertEqual(error as? NotebookAttachmentError, .checksumMismatch)
        }
    }

    func testExportLeavesAnExistingDestinationUntouched() async throws {
        let store = NotebookAttachmentStore(directory: storeDirectory)
        let bytes = Data([0x01, 0x02, 0xFE])
        let source = try write(bytes, named: "source.bin")
        let descriptor = try await store.storeFile(at: source, attachmentID: UUID())
        let destination = root.appendingPathComponent("existing.bin")
        let originalDestination = Data("keep this file".utf8)
        try originalDestination.write(to: destination)

        do {
            try await store.export(descriptor, to: destination)
            XCTFail("Expected export to refuse an existing destination")
        } catch {
            XCTAssertEqual(error as? NotebookAttachmentError, .destinationExists)
        }
        XCTAssertEqual(try Data(contentsOf: destination), originalDestination)
    }

    func testExportCreatesAnExactCopy() async throws {
        let store = NotebookAttachmentStore(directory: storeDirectory)
        let bytes = Data([0x00, 0xFE, 0x80, 0x41, 0x0D, 0x0A])
        let source = try write(bytes, named: "export-source.bin")
        let descriptor = try await store.storeFile(at: source, attachmentID: UUID())
        let destination = root.appendingPathComponent("exported.bin")

        try await store.export(descriptor, to: destination)

        XCTAssertEqual(try Data(contentsOf: destination), bytes)
        XCTAssertEqual(try digestFile(destination), descriptor.content.sha256)
    }

    func testSymlinksAndDirectoriesAreRejectedAsSources() async throws {
        let store = NotebookAttachmentStore(directory: storeDirectory)
        let target = try write(Data("target".utf8), named: "target.bin")
        let symlink = root.appendingPathComponent("alias.bin")
        try FileManager.default.createSymbolicLink(at: symlink, withDestinationURL: target)
        let directory = root.appendingPathComponent("folder", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)

        for source in [symlink, directory] {
            do {
                _ = try await store.storeFile(at: source, attachmentID: UUID())
                XCTFail("Expected non-regular source to be rejected: \(source.lastPathComponent)")
            } catch {
                XCTAssertEqual(error as? NotebookAttachmentError, .unsupportedSource)
            }
        }
    }

    func testNamedPipeIsRejectedWithoutWaitingForAWriter() async throws {
        let store = NotebookAttachmentStore(directory: storeDirectory)
        let pipe = root.appendingPathComponent("source.pipe")
        XCTAssertEqual(mkfifo(pipe.path, mode_t(S_IRUSR | S_IWUSR)), 0)

        do {
            _ = try await store.storeFile(at: pipe, attachmentID: UUID())
            XCTFail("Expected a named pipe to be rejected")
        } catch {
            XCTAssertEqual(error as? NotebookAttachmentError, .unsupportedSource)
        }
    }

    func testUnsupportedManifestVersionDoesNotChangeStoredBytes() async throws {
        let store = NotebookAttachmentStore(directory: storeDirectory)
        let bytes = Data("versioned fictional data".utf8)
        let source = try write(bytes, named: "source.bin")
        let id = UUID()
        let descriptor = try await store.storeFile(at: source, attachmentID: id)
        let directory = storeDirectory.appendingPathComponent(id.uuidString, isDirectory: true)
        let content = directory.appendingPathComponent("content")
        let originalBytes = try Data(contentsOf: content)
        let manifest = directory.appendingPathComponent("manifest.json")
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: manifest)) as? [String: Any])
        object["schemaVersion"] = 99
        try JSONSerialization.data(withJSONObject: object).write(to: manifest)

        do {
            _ = try await store.descriptor(for: id)
            XCTFail("Expected an unknown manifest version to be rejected")
        } catch {
            XCTAssertEqual(error as? NotebookAttachmentError, .unsupportedFormat)
        }
        XCTAssertEqual(try Data(contentsOf: content), originalBytes)
        XCTAssertEqual(try Data(contentsOf: content), bytes)
        XCTAssertEqual(descriptor.content.byteCount, Int64(bytes.count))
    }

    func testMalformedOversizedAndMismatchedManifestsAreRejectedWithoutChangingContent() async throws {
        let store = NotebookAttachmentStore(directory: storeDirectory)
        let bytes = Data("manifest integrity fixture".utf8)
        let source = try write(bytes, named: "manifest-source.bin")

        for corruption in ["malformed", "oversized", "identity"] {
            let id = UUID()
            _ = try await store.storeFile(at: source, attachmentID: id)
            let item = targetURL(id)
            let manifestURL = item.appendingPathComponent("manifest.json")
            let contentURL = item.appendingPathComponent("content")
            let before = try Data(contentsOf: contentURL)

            switch corruption {
            case "malformed":
                try Data("{not json".utf8).write(to: manifestURL)
            case "oversized":
                try Data(repeating: 0x20, count: 20 * 1024).write(to: manifestURL)
            default:
                var object = try XCTUnwrap(
                    JSONSerialization.jsonObject(with: Data(contentsOf: manifestURL))
                        as? [String: Any]
                )
                var descriptor = try XCTUnwrap(object["descriptor"] as? [String: Any])
                descriptor["id"] = UUID().uuidString
                object["descriptor"] = descriptor
                try JSONSerialization.data(withJSONObject: object).write(to: manifestURL)
            }

            do {
                _ = try await store.descriptor(for: id)
                XCTFail("Expected \(corruption) manifest to be rejected")
            } catch {
                XCTAssertEqual(error as? NotebookAttachmentError, .invalidStoredAttachment)
            }
            XCTAssertEqual(try Data(contentsOf: contentURL), before)
            XCTAssertEqual(try Data(contentsOf: contentURL), bytes)
        }
    }

    func testStaleDescriptorIsRejectedWithoutChangingStoredContent() async throws {
        let store = NotebookAttachmentStore(directory: storeDirectory)
        let bytes = Data("current attachment content".utf8)
        let source = try write(bytes, named: "stale-source.bin")
        let stored = try await store.storeFile(at: source, attachmentID: UUID())
        let staleContent = try NotebookAttachmentContent(
            sha256: String(repeating: "0", count: 64),
            byteCount: stored.content.byteCount
        )
        let stale = NotebookAttachmentDescriptor(id: stored.id, content: staleContent)

        do {
            _ = try await store.verifiedFileURL(for: stale)
            XCTFail("Expected the stale descriptor to be rejected")
        } catch {
            XCTAssertEqual(error as? NotebookAttachmentError, .identityConflict(stored.id))
        }
        let validURL = try await store.verifiedFileURL(for: stored)
        XCTAssertEqual(try Data(contentsOf: validURL), bytes)
    }

    func testRemovalOnlyChangesItsOwnStoreDirectory() async throws {
        let firstDirectory = try XCTUnwrap(storeDirectory)
        let secondDirectory = root.appendingPathComponent("SiblingStore", isDirectory: true)
        let firstStore = NotebookAttachmentStore(directory: firstDirectory)
        let secondStore = NotebookAttachmentStore(directory: secondDirectory)
        let source = try write(Data("fictional shared test bytes".utf8), named: "source.bin")
        let firstID = UUID()
        let siblingID = UUID()
        _ = try await firstStore.storeFile(at: source, attachmentID: firstID)
        let siblingDescriptor = try await firstStore.storeFile(at: source, attachmentID: siblingID)
        let secondID = UUID()
        let secondDescriptor = try await secondStore.storeFile(at: source, attachmentID: secondID)

        try await firstStore.remove(id: firstID)
        try await firstStore.remove(id: firstID)

        XCTAssertFalse(FileManager.default.fileExists(
            atPath: firstDirectory.appendingPathComponent(firstID.uuidString).path
        ))
        XCTAssertTrue(FileManager.default.fileExists(
            atPath: firstDirectory.appendingPathComponent(siblingID.uuidString).path
        ))
        let siblingURL = try await firstStore.verifiedFileURL(for: siblingDescriptor)
        XCTAssertEqual(try Data(contentsOf: siblingURL), Data("fictional shared test bytes".utf8))
        let otherStoreURL = try await secondStore.verifiedFileURL(for: secondDescriptor)
        XCTAssertEqual(try Data(contentsOf: otherStoreURL), Data("fictional shared test bytes".utf8))
    }

    func testInterruptedWritesRecoverAtEachDurableBoundary() async throws {
        let bytes = Data("durable fictional payload".utf8)
        let source = try write(bytes, named: "recovery-source.bin")
        let stages: [NotebookAttachmentWriteStage] = [
            .contentSynced, .manifestSynced, .published,
        ]

        for stage in stages {
            let directory = root.appendingPathComponent("Recovery-\(stage)", isDirectory: true)
            let id = UUID()
            let interrupted = NotebookAttachmentStore(directory: directory) { reached in
                let isTarget: Bool
                switch (stage, reached) {
                case (.contentSynced, .contentSynced),
                     (.manifestSynced, .manifestSynced),
                     (.published, .published):
                    isTarget = true
                default:
                    isTarget = false
                }
                if isTarget { throw InjectedFailure() }
            }

            do {
                _ = try await interrupted.storeFile(at: source, attachmentID: id)
                XCTFail("Expected the injected \(stage) interruption")
            } catch is InjectedFailure {
            }

            let reopened = NotebookAttachmentStore(directory: directory)
            let committedPath = directory.appendingPathComponent(id.uuidString)
            if case .published = stage {
                XCTAssertTrue(FileManager.default.fileExists(atPath: committedPath.path))
            } else {
                XCTAssertFalse(FileManager.default.fileExists(atPath: committedPath.path))
            }
            let recovered = try await reopened.storeFile(at: source, attachmentID: id)
            let verified = try await reopened.verifiedFileURL(for: recovered)
            XCTAssertEqual(try Data(contentsOf: verified), bytes)
        }
    }

    func testCancellationBeforeImportDoesNotPublishTarget() async throws {
        let store = NotebookAttachmentStore(directory: storeDirectory)
        let source = try write(Data("cancel before import".utf8), named: "source.bin")
        let id = UUID()
        let task = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return try await store.storeFile(at: source, attachmentID: id)
        }
        do {
            _ = try await task.value
            XCTFail("Expected a pre-cancelled import to stop")
        } catch is CancellationError {
        } catch {
            XCTAssertTrue(error is CancellationError, "Unexpected error: \(error)")
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: targetURL(id).path))
    }

    func testMultiChunkPayloadRoundTripsExactly() async throws {
        let store = NotebookAttachmentStore(directory: storeDirectory)
        let source = root.appendingPathComponent("multi-chunk.bin")
        let pattern = Data((0..<(64 * 1024)).map { UInt8(($0 * 37) & 0xFF) })
        let handle = try FileHandle(forWritingTo: createEmptyFile(source))
        var expectedHasher = SHA256()
        for _ in 0..<3_200 {
            try handle.write(contentsOf: pattern)
            expectedHasher.update(data: pattern)
        }
        try handle.close()
        let expectedDigest = expectedHasher.finalize()
            .map { String(format: "%02x", $0) }.joined()

        let id = UUID()
        let descriptor = try await store.storeFile(at: source, attachmentID: id)
        XCTAssertEqual(descriptor.content.byteCount, Int64(200 * 1024 * 1024))
        XCTAssertEqual(descriptor.content.sha256, expectedDigest)
        let verified = try await store.verifiedFileURL(for: descriptor)
        XCTAssertEqual(try digestFile(verified), expectedDigest)
        XCTAssertEqual(try FileManager.default.attributesOfItem(atPath: verified.path)[.size] as? Int,
                       200 * 1024 * 1024)
        let exported = root.appendingPathComponent("multi-chunk-export.bin")
        try await store.export(descriptor, to: exported)
        XCTAssertEqual(try digestFile(exported), expectedDigest)
    }

    private func write(_ data: Data, named name: String) throws -> URL {
        let url = root.appendingPathComponent(name)
        try data.write(to: url)
        return url
    }

    private func createEmptyFile(_ url: URL) throws -> URL {
        guard FileManager.default.createFile(atPath: url.path, contents: Data()) else {
            throw CocoaError(.fileWriteUnknown)
        }
        return url
    }

    private func targetURL(_ id: UUID) -> URL {
        storeDirectory.appendingPathComponent(id.uuidString, isDirectory: true)
    }

    private func digest(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    private func digestFile(_ url: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var hasher = SHA256()
        while let chunk = try handle.read(upToCount: 64 * 1024), !chunk.isEmpty {
            hasher.update(data: chunk)
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    private struct InjectedFailure: Error {}
}
