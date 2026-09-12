import Darwin
import Foundation
import XCTest

@testable import NoteCore

final class MarkdownCopyWriterTests: XCTestCase, @unchecked Sendable {
    private let noteID = UUID(
        uuidString: "A19A0197-E641-4805-A4B4-B69EB1525F87"
    )!

    func testPublishWritesExactBytesAndPersistsHeads() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let snapshot = copy(
            text: "# Note\n\nLiteral 👋\n",
            heads: ["head-b", "head-a"]
        )

        let result = try await fixture.writer.publish(snapshot)
        XCTAssertEqual(result, .current(heads: snapshot.heads))
        XCTAssertEqual(try Data(contentsOf: fixture.copyURL), snapshot.utf8)

        let state = try fixture.bookkeeping()
        let last = try XCTUnwrap(state["last"] as? [String: Any])
        XCTAssertEqual(last["heads"] as? [String], ["head-a", "head-b"])
        XCTAssertNotNil(last["fingerprint"] as? String)
    }

    func testPreexistingFileIsNeverClaimedEvenWhenBytesMatch() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let snapshot = copy(text: "same")
        try snapshot.utf8.write(to: fixture.copyURL)

        let result = try await fixture.writer.publish(snapshot)

        XCTAssertEqual(result, .paused(.preexistingFile))
        XCTAssertEqual(try Data(contentsOf: fixture.copyURL), snapshot.utf8)
        XCTAssertFalse(
            FileManager.default.fileExists(
                atPath: fixture.writer.metadataURL.path
            )
        )
    }

    func testLargeSparsePreexistingFileIsNotRead() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        XCTAssertTrue(
            FileManager.default.createFile(
                atPath: fixture.copyURL.path,
                contents: nil
            )
        )
        let handle = try FileHandle(forWritingTo: fixture.copyURL)
        try handle.truncate(atOffset: 1 << 40)
        try handle.close()
        try FileManager.default.setAttributes(
            [.posixPermissions: 0],
            ofItemAtPath: fixture.copyURL.path
        )

        let result = try await fixture.writer.publish(copy(text: "saved"))

        XCTAssertEqual(result, .paused(.preexistingFile))
        let attributes = try FileManager.default.attributesOfItem(
            atPath: fixture.copyURL.path
        )
        XCTAssertEqual(attributes[.size] as? NSNumber, NSNumber(value: 1 << 40))
    }

    func testStreamingFingerprintCoversMultipleUnicodeChunks() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let text = String(repeating: "Markdown 👋\n", count: 20_000)
        let snapshot = copy(text: text, heads: ["large"])

        let result = try await fixture.writer.publish(snapshot)

        XCTAssertEqual(result, .current(heads: ["large"]))
        XCTAssertEqual(try Data(contentsOf: fixture.copyURL), snapshot.utf8)
    }

    func testExternalEditIsOverwrittenByReconcile() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let snapshot = copy(text: "authoritative", heads: ["saved"])
        _ = try await fixture.writer.publish(snapshot)
        try Data("external edit".utf8).write(to: fixture.copyURL)

        let result = try await fixture.newWriter().reconcile(with: snapshot)

        XCTAssertEqual(result, .current(heads: ["saved"]))
        XCTAssertEqual(try Data(contentsOf: fixture.copyURL), snapshot.utf8)
        XCTAssertTrue(fixture.conflictCopies().isEmpty)
    }

    func testExternalDeletionIsRecreatedByReconcile() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let snapshot = copy(text: "recreated", heads: ["saved"])
        _ = try await fixture.writer.publish(snapshot)
        try FileManager.default.removeItem(at: fixture.copyURL)

        let result = try await fixture.newWriter().reconcile(with: snapshot)

        XCTAssertEqual(result, .current(heads: ["saved"]))
        XCTAssertEqual(try Data(contentsOf: fixture.copyURL), snapshot.utf8)
    }

    func testInterruptedReplacementFinishesAfterRestart() async throws {
        for initiallyManaged in [false, true] {
            for stage in [
                MarkdownCopyWriteStage.pendingRecorded,
                .stagedFileSynced,
                .destinationReplaced,
                .replacementVerified,
                .bookkeepingRecorded,
            ] {
                let fixture = try Fixture()
                defer { fixture.remove() }
                if initiallyManaged {
                    _ = try await fixture.writer.publish(
                        copy(text: "old", heads: ["old"])
                    )
                }
                let snapshot = copy(text: "new", heads: ["new"])

                do {
                    _ = try await fixture.writer.publish(snapshot) { reached in
                        if reached == stage { throw InjectedFailure.stop }
                    }
                    XCTFail("Expected interruption at \(stage)")
                } catch InjectedFailure.stop {
                    // A reopened writer must recover every durable boundary.
                }

                let result = try await fixture.newWriter().reconcile(
                    with: snapshot
                )
                XCTAssertEqual(result, .current(heads: ["new"]))
                XCTAssertEqual(
                    try Data(contentsOf: fixture.copyURL),
                    snapshot.utf8
                )
            }
        }
    }

    func testInterruptedInitialWriteDoesNotClaimIdenticalFile() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let snapshot = copy(text: "identical bytes")

        do {
            _ = try await fixture.writer.publish(snapshot) { stage in
                if stage == .stagedFileSynced { throw InjectedFailure.stop }
            }
            XCTFail("Expected interruption before the initial replacement")
        } catch InjectedFailure.stop {
            try snapshot.utf8.write(to: fixture.copyURL)
        }

        let result = try await fixture.newWriter().reconcile(with: snapshot)
        XCTAssertEqual(result, .paused(.preexistingFile))
        XCTAssertEqual(try Data(contentsOf: fixture.copyURL), snapshot.utf8)
    }

    func testPartialStagedFileIsRebuiltAfterRestart() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let snapshot = copy(text: "complete saved text", heads: ["saved"])

        do {
            _ = try await fixture.writer.publish(snapshot) { stage in
                guard stage == .stagedFileSynced else { return }
                let pending = try XCTUnwrap(
                    fixture.bookkeeping()["pending"] as? [String: Any]
                )
                let name = try XCTUnwrap(pending["stageName"] as? String)
                try Data("partial".utf8).write(
                    to: fixture.destination.appendingPathComponent(name)
                )
                throw InjectedFailure.stop
            }
            XCTFail("Expected the staged-write interruption")
        } catch InjectedFailure.stop {
            // Reconciliation replaces a corrupt managed stage from saved data.
        }

        let result = try await fixture.newWriter().reconcile(with: snapshot)
        XCTAssertEqual(result, .current(heads: ["saved"]))
        XCTAssertEqual(try Data(contentsOf: fixture.copyURL), snapshot.utf8)
    }

    func testConcurrentRegularReplacementIsOverwritten() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        _ = try await fixture.writer.publish(copy(text: "old"))
        let snapshot = copy(text: "saved wins", heads: ["new"])

        let result = try await fixture.writer.publish(
            snapshot,
            afterStage: { _ in },
            beforeReplacement: {
                try Data("external race".utf8).write(to: fixture.copyURL)
            }
        )

        XCTAssertEqual(result, .current(heads: ["new"]))
        XCTAssertEqual(try Data(contentsOf: fixture.copyURL), snapshot.utf8)
        XCTAssertTrue(fixture.conflictCopies().isEmpty)
    }

    func testDirectoryReplacementDuringStagingIsRejected() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        _ = try await fixture.writer.publish(copy(text: "old"))
        let displaced = fixture.root.appendingPathComponent("displaced")

        let result = try await fixture.writer.publish(
            copy(text: "new"),
            afterStage: { _ in },
            beforeReplacement: {
                try FileManager.default.moveItem(
                    at: fixture.destination,
                    to: displaced
                )
                try FileManager.default.createDirectory(
                    at: fixture.destination,
                    withIntermediateDirectories: false
                )
            }
        )

        XCTAssertEqual(result, .paused(.destinationReplaced))
        XCTAssertFalse(
            FileManager.default.fileExists(atPath: fixture.copyURL.path)
        )
        XCTAssertEqual(
            try String(
                contentsOf: displaced.appendingPathComponent("note.md"),
                encoding: .utf8
            ),
            "old"
        )
    }

    func testEditAfterReplacementIsRetriedOnNextReconcile() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        _ = try await fixture.writer.publish(copy(text: "old"))
        let snapshot = copy(text: "saved", heads: ["new"])

        do {
            _ = try await fixture.writer.publish(snapshot) { stage in
                guard stage == .replacementVerified else { return }
                try Data("late edit".utf8).write(to: fixture.copyURL)
            }
            XCTFail("Expected verification to detect the late edit")
        } catch let MarkdownCopyError.fileSystem(operation, domain, code) {
            XCTAssertEqual(operation, "verify Markdown copy")
            XCTAssertEqual(domain, NSPOSIXErrorDomain)
            XCTAssertEqual(code, Int(EAGAIN))
        }

        let retried = try await fixture.newWriter().reconcile(with: snapshot)
        XCTAssertEqual(retried, .current(heads: ["new"]))
        XCTAssertEqual(try Data(contentsOf: fixture.copyURL), snapshot.utf8)
    }

    func testActorSerializesConcurrentPublishes() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        _ = try await fixture.writer.publish(copy(text: "initial"))
        let first = copy(text: "first", heads: ["first"])
        let second = copy(text: "second", heads: ["second"])

        async let firstResult = fixture.writer.publish(first)
        async let secondResult = fixture.writer.publish(second)
        _ = try await (firstResult, secondResult)

        let data = try Data(contentsOf: fixture.copyURL)
        let reopened = fixture.newWriter()
        if data == first.utf8 {
            let result = try await reopened.reconcile(with: first)
            XCTAssertEqual(result, .current(heads: first.heads))
        } else {
            XCTAssertEqual(data, second.utf8)
            let result = try await reopened.reconcile(with: second)
            XCTAssertEqual(result, .current(heads: second.heads))
        }
    }

    func testUnsafeCopyAndChangedDirectoryIdentityPause() async throws {
        let unsafe = try Fixture()
        defer { unsafe.remove() }
        try FileManager.default.createDirectory(
            at: unsafe.copyURL,
            withIntermediateDirectories: false
        )
        let unsafeResult = try await unsafe.writer.publish(copy(text: "text"))
        XCTAssertEqual(unsafeResult, .paused(.unsafeDestination))

        let replaced = try Fixture()
        defer { replaced.remove() }
        let snapshot = copy(text: "owned")
        _ = try await replaced.writer.publish(snapshot)
        try FileManager.default.removeItem(at: replaced.destination)
        try FileManager.default.createDirectory(
            at: replaced.destination,
            withIntermediateDirectories: false
        )
        let replacedResult = try await replaced.newWriter().reconcile(
            with: snapshot
        )
        XCTAssertEqual(replacedResult, .paused(.destinationReplaced))
    }

    func testSymlinkCopyIsNotFollowed() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let target = fixture.root.appendingPathComponent("target.md")
        try Data("outside".utf8).write(to: target)
        try FileManager.default.createSymbolicLink(
            at: fixture.copyURL,
            withDestinationURL: target
        )

        let result = try await fixture.writer.publish(copy(text: "saved"))
        XCTAssertEqual(result, .paused(.unsafeDestination))
        XCTAssertEqual(
            try String(contentsOf: target, encoding: .utf8),
            "outside"
        )
    }

    private func copy(
        text: String,
        heads: Set<String> = ["head"]
    ) -> MarkdownCopySnapshot {
        MarkdownCopySnapshot(text: text, heads: heads, noteID: noteID)
    }
}

private enum InjectedFailure: Error {
    case stop
}

private final class Fixture: @unchecked Sendable {
    let root: URL
    let destination: URL
    let metadata: URL
    let writer: MarkdownCopyWriter

    init() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent(
            "MarkdownCopyWriterTests-\(UUID().uuidString)",
            isDirectory: true
        )
        destination = root.appendingPathComponent("destination")
        metadata = root.appendingPathComponent("metadata")
        try FileManager.default.createDirectory(
            at: destination,
            withIntermediateDirectories: true
        )
        writer = MarkdownCopyWriter(
            destinationDirectory: destination,
            metadataDirectory: metadata
        )
    }

    var copyURL: URL { destination.appendingPathComponent("note.md") }

    func newWriter() -> MarkdownCopyWriter {
        MarkdownCopyWriter(
            destinationDirectory: destination,
            metadataDirectory: metadata
        )
    }

    func bookkeeping() throws -> [String: Any] {
        try XCTUnwrap(
            JSONSerialization.jsonObject(
                with: Data(contentsOf: writer.metadataURL)
            ) as? [String: Any]
        )
    }

    func conflictCopies() -> [URL] {
        let contents = (try? FileManager.default.contentsOfDirectory(
            at: destination,
            includingPropertiesForKeys: nil
        )) ?? []
        return contents.filter { $0.lastPathComponent.contains("conflict") }
    }

    func remove() {
        try? FileManager.default.removeItem(at: root)
    }
}
