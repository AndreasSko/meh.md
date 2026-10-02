import CryptoKit
import Foundation
import NoteCore
import XCTest

final class NotebookAttachmentTransportTests: XCTestCase {
    private func descriptor(_ data: Data, id: UUID = UUID()) throws
        -> NotebookAttachmentDescriptor {
        let digest = SHA256.hash(data: data)
            .map { String(format: "%02x", $0) }.joined()
        return NotebookAttachmentDescriptor(id: id, content: try .init(
            sha256: digest, byteCount: Int64(data.count)))
    }

    func testCrossDeviceDownloadAndLostUploadAcknowledgement() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("attachment-transport-test-\(UUID())")
        try FileManager.default.createDirectory(at: directory,
            withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: directory) }
        let source = directory.appendingPathComponent("source")
        let destination = directory.appendingPathComponent("download")
        let data = Data(repeating: 0x7b, count: 200_000)
        try data.write(to: source)
        let item = try descriptor(data)
        let notebookID = UUID()
        let service = InMemoryAttachmentStore()
        let first = InMemoryAttachmentTransport(scope: "same-account", store: service)
        let second = InMemoryAttachmentTransport(scope: "same-account", store: service)
        await service.loseNextAcknowledgement()
        do {
            try await first.upload(item, notebookID: notebookID, from: source)
            XCTFail("Expected lost acknowledgement")
        } catch {
            XCTAssertEqual(error as? NotebookAttachmentTransferError,
                .unacknowledged)
        }
        try await first.upload(item, notebookID: notebookID, from: source)
        try await second.download(item, notebookID: notebookID,
            to: destination)
        XCTAssertEqual(try Data(contentsOf: destination), data)
    }

    func testTombstonePreventsLateUploadAndDownload() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("attachment-transport-test-\(UUID())")
        try FileManager.default.createDirectory(at: directory,
            withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: directory) }
        let source = directory.appendingPathComponent("source")
        let data = Data("gone".utf8)
        try data.write(to: source)
        let item = try descriptor(data)
        let notebookID = UUID()
        let transport = InMemoryAttachmentTransport(
            scope: "same-account", store: InMemoryAttachmentStore())
        try await transport.delete(attachmentIDs: [item.id],
            notebookID: notebookID)
        do {
            try await transport.upload(item, notebookID: notebookID,
                from: source)
            XCTFail("A deleted attachment was resurrected")
        } catch {
            XCTAssertEqual(error as? NotebookAttachmentTransferError, .deleted)
        }
        do {
            try await transport.download(item, notebookID: notebookID,
                to: directory.appendingPathComponent("download"))
            XCTFail("A tombstone was downloaded")
        } catch {
            XCTAssertEqual(error as? NotebookAttachmentTransferError, .deleted)
        }
    }

    func testMismatchedBytesDoNotUpload() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("attachment-transport-test-\(UUID())")
        try FileManager.default.createDirectory(at: directory,
            withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: directory) }
        let source = directory.appendingPathComponent("source")
        try Data("wrong".utf8).write(to: source)
        let item = try descriptor(Data("right".utf8))
        let transport = InMemoryAttachmentTransport(
            scope: "same-account", store: InMemoryAttachmentStore())
        do {
            try await transport.upload(item, notebookID: UUID(), from: source)
            XCTFail("Mismatched contents were uploaded")
        } catch {
            XCTAssertEqual(error as? NotebookAttachmentError,
                .checksumMismatch)
        }
    }
}
