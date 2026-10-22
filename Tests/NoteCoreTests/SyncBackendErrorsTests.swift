import CloudKit
import Foundation
import XCTest

@testable import NoteCore

final class SyncBackendErrorsTests: XCTestCase {
    /// Shared sync code must stay usable by any backend. Only files that
    /// belong to the CloudKit backend may depend on CloudKit.
    func testSharedSyncCodeDoesNotImportCloudKit() throws {
        let sources = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appending(path: "Sources/NoteCore")
        let files = try XCTUnwrap(
            FileManager.default.enumerator(at: sources, includingPropertiesForKeys: nil)
        ).compactMap { $0 as? URL }.filter { $0.pathExtension == "swift" }
        XCTAssertFalse(files.isEmpty)
        for file in files where !file.lastPathComponent.hasPrefix("CloudKit") {
            let source = try String(contentsOf: file, encoding: .utf8)
            XCTAssertFalse(
                source.contains("import CloudKit"),
                "\(file.lastPathComponent) belongs to shared sync code"
            )
        }
    }

    @MainActor
    func testCloudKitDiagnosticCodesStayStable() {
        let documentID = UUID()
        XCTAssertEqual(
            NotebookSyncEventLog.errorCode(CKError(.quotaExceeded)),
            "CKError.\(CKError.quotaExceeded.rawValue)"
        )
        XCTAssertEqual(
            NotebookSyncEventLog.errorCode(
                CloudKitSyncTransportError.uploadFailed(code: 3)
            ),
            "CloudKitSyncTransportError.uploadFailed.3"
        )
        XCTAssertEqual(
            NotebookSyncEventLog.errorCode(
                CloudKitSyncTransportError.snapshotTooLarge(documentID: documentID)
            ),
            "CloudKitSyncTransportError.snapshotTooLarge." + documentID.uuidString
        )
        XCTAssertEqual(
            NotebookSyncEventLog.errorCode(
                CloudKitStateWriteFailure(underlyingError: SyncError.invalidCursor)
            ),
            "CloudKitStateWriteFailure.SyncError.invalidCursor"
        )
    }

    func testOversizedSnapshotIsNamedByItsBackend() throws {
        let documentID = UUID()
        let error = CloudKitSyncTransportError.snapshotTooLarge(
            documentID: documentID, kind: .catalog
        )
        XCTAssertEqual(SyncBackends.oversizedDocumentID(in: error), documentID)
        let named = try XCTUnwrap(
            SyncBackends.naming(error, displayName: "Plans")
                as? CloudKitSyncTransportError
        )
        XCTAssertEqual(
            named,
            .snapshotTooLarge(
                documentID: documentID, kind: .catalog, displayName: "Plans"
            )
        )

        let other = CloudKitSyncTransportError.corruptState
        XCTAssertNil(SyncBackends.oversizedDocumentID(in: other))
        XCTAssertEqual(
            SyncBackends.naming(other, displayName: "Plans")
                as? CloudKitSyncTransportError,
            other
        )
    }

    func testRawCloudKitDomainErrorKeepsItsCause() {
        let error = NSError(
            domain: CKErrorDomain, code: CKError.quotaExceeded.rawValue
        )
        let presentation = SyncFailurePresentation(
            error: error, retryWillOccurAutomatically: false
        )
        XCTAssertEqual(
            String(localized: presentation.title), "iCloud storage is full"
        )
    }

    func testUnknownBackendErrorsUseSharedHandling() {
        struct OtherBackendError: Error {}
        let error = OtherBackendError()
        XCTAssertNil(SyncBackends.isTransient(error))
        XCTAssertNil(SyncBackends.oversizedDocumentID(in: error))
        XCTAssertNil(
            SyncBackends.failure(of: error, nested: { _ in
                SyncFailurePresentation.unknownFailure
            })
        )
        var policy = NotebookSyncRetryPolicy()
        XCTAssertNil(policy.retryDate(for: error, now: Date()))
        let presentation = SyncFailurePresentation(
            error: error, retryWillOccurAutomatically: false
        )
        XCTAssertEqual(String(localized: presentation.title), "Sync failed")
    }
}
