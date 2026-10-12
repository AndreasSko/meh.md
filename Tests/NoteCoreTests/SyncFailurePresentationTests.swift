import CloudKit
import Foundation
import XCTest
@testable import NoteCore

final class SyncFailurePresentationTests: XCTestCase {
    func testLocalSavePrerequisiteExplainsAutomaticContinuation() {
        let presentation = SyncFailurePresentation(
            error: SyncError.localSaveRequired,
            retryWillOccurAutomatically: true
        )
        XCTAssertEqual(String(localized: presentation.title), "Waiting to sync")
        XCTAssertTrue(presentation.isWaitingForLocalSave)
        XCTAssertEqual(presentation.retryDisposition, .automatic)
        XCTAssertEqual(
            String(localized: presentation.actionHint!),
            "Sync will retry automatically."
        )
        XCTAssertFalse(String(localized: presentation.message).contains("Save the note"))
    }

    func testLocalSaveWaitDoesNotPromiseAutomaticRetryWhenDisabled() {
        let presentation = SyncFailurePresentation(
            error: SyncError.localSaveRequired,
            retryWillOccurAutomatically: false
        )
        XCTAssertFalse(presentation.isWaitingForLocalSave)
        XCTAssertEqual(presentation.retryDisposition, .manual)
        XCTAssertEqual(String(localized: presentation.actionHint!), "Try syncing again.")
    }

    func testActualNoteWriteFailureAlwaysNeedsAttention() {
        let errors: [(any Error, String)] = [
            (POSIXError(.ENOSPC), "Device storage is full"),
            (CocoaError(.fileWriteOutOfSpace), "Device storage is full"),
            (POSIXError(.EACCES), "Sync data could not be saved"),
            (NSError(domain: "test-write", code: 1), "Changes could not be saved"),
            (SyncError.localSaveRequired, "Changes could not be saved"),
        ]
        for (error, expectedTitle) in errors {
            let presentation = SyncFailurePresentation(
                error: LocalNoteSaveFailure(underlyingError: error),
                retryWillOccurAutomatically: true
            )
            XCTAssertEqual(String(localized: presentation.title), expectedTitle)
            XCTAssertFalse(presentation.isWaitingForLocalSave)
            XCTAssertNotNil(presentation.actionHint)
        }
    }

    func testNewerNotebookRequiresAppUpdateWithoutRetryGuidance() {
        let presentation = SyncFailurePresentation(
            error: SyncError.updateRequired(requiredVersion: 3),
            retryWillOccurAutomatically: true
        )
        XCTAssertEqual(String(localized: presentation.title), "Update required")
        XCTAssertEqual(
            String(localized: presentation.message),
            "Update meh.md to resume iCloud sync. You can keep editing your notes on this device."
        )
        XCTAssertEqual(presentation.retryDisposition, .unavailable)
        XCTAssertNil(presentation.actionHint)
    }

    func testCancellationAllowsManualRetry() {
        for automaticRetry in [false, true] {
            let presentation = SyncFailurePresentation(
                error: CancellationError(),
                retryWillOccurAutomatically: automaticRetry
            )
            XCTAssertEqual(String(localized: presentation.title), "Sync stopped")
            XCTAssertEqual(presentation.retryDisposition, .manual)
            XCTAssertEqual(
                presentation.actionHint.map { String(localized: $0) },
                "Try syncing again."
            )
        }
    }

    func testKnownStorageErrorsAreSpecificAndDoNotMakeEditSafetyClaims() {
        let cases: [(any Error, String)] = [
            (POSIXError(.ENOSPC), "Device storage is full"),
            (CocoaError(.fileWriteOutOfSpace), "Device storage is full"),
            (POSIXError(.EACCES), "Sync data could not be saved"),
            (
                NSError(
                    domain: "wrapper",
                    code: 1,
                    userInfo: [NSUnderlyingErrorKey: POSIXError(.ENOSPC)]
                ),
                "Device storage is full"
            ),
        ]

        for (error, expectedTitle) in cases {
            let presentation = SyncFailurePresentation(
                error: error, retryWillOccurAutomatically: false
            )
            XCTAssertEqual(String(localized: presentation.title), expectedTitle)
            XCTAssertEqual(presentation.retryDisposition, .manual)
            XCTAssertFalse(String(localized: presentation.message).contains("safe"))
        }
    }

    func testCloudAccountQuotaPermissionAndTransientFailures() {
        let account = SyncFailurePresentation(
            error: CloudKitSyncTransportError.accountUnavailable,
            retryWillOccurAutomatically: false
        )
        XCTAssertEqual(
            String(localized: account.title), "iCloud account unavailable"
        )
        XCTAssertEqual(account.retryDisposition, .manual)

        let quota = SyncFailurePresentation(
            error: CKError(.quotaExceeded), retryWillOccurAutomatically: false
        )
        XCTAssertEqual(String(localized: quota.title), "iCloud storage is full")
        XCTAssertTrue(String(localized: quota.actionHint!).contains("iCloud storage"))

        let permission = SyncFailurePresentation(
            error: CKError(.permissionFailure),
            retryWillOccurAutomatically: false
        )
        XCTAssertEqual(
            String(localized: permission.title), "iCloud access unavailable"
        )

        let automatic = SyncFailurePresentation(
            error: URLError(.notConnectedToInternet),
            retryWillOccurAutomatically: true
        )
        XCTAssertEqual(automatic.retryDisposition, .automatic)
        XCTAssertEqual(
            String(localized: automatic.actionHint!),
            "Sync will retry automatically."
        )

        let manual = SyncFailurePresentation(
            error: URLError(.timedOut), retryWillOccurAutomatically: false
        )
        XCTAssertEqual(manual.retryDisposition, .manual)
        XCTAssertEqual(String(localized: manual.actionHint!), "Try syncing again.")
    }

    func testOversizedSnapshotShowsRecoveryGuidance() {
        let documentID = UUID()
        let presentation = SyncFailurePresentation(
            error: CloudKitSyncTransportError.snapshotTooLarge(
                documentID: documentID, displayName: "Fictional Note.md"
            ),
            retryWillOccurAutomatically: false
        )
        XCTAssertEqual(
            String(localized: presentation.title),
            "Snapshot too large to sync"
        )
        XCTAssertEqual(presentation.retryDisposition, .manual)
        XCTAssertTrue(
            String(localized: presentation.actionHint!).contains("backup")
        )
        XCTAssertTrue(
            String(localized: presentation.message).contains("Fictional Note.md")
        )
    }

    func testOversizedCatalogPausesNotebookSyncAndPreservesLocalData() {
        let presentation = SyncFailurePresentation(
            error: CloudKitSyncTransportError.snapshotTooLarge(
                documentID: UUID(), kind: .catalog,
                displayName: "Notebook catalog"
            ),
            retryWillOccurAutomatically: true
        )
        XCTAssertEqual(
            String(localized: presentation.title),
            "Notebook too large to sync"
        )
        XCTAssertEqual(presentation.retryDisposition, .unavailable)
        XCTAssertTrue(
            String(localized: presentation.message).contains("sync is paused")
        )
        let hint = String(localized: presentation.actionHint!)
        XCTAssertTrue(hint.contains("Keep your local data"))
        XCTAssertTrue(hint.contains("export a backup"))
        XCTAssertFalse(hint.contains("Other notes can still sync"))
        XCTAssertFalse(hint.contains("this note's history"))
    }

    func testPartialAndUnderlyingCloudErrorsKeepTheirKnownCause() {
        let partial = NSError(
            domain: CKErrorDomain,
            code: CKError.partialFailure.rawValue,
            userInfo: [
                CKPartialErrorsByItemIDKey: [
                    "note": CKError(.quotaExceeded)
                ]
            ]
        )
        let presentation = SyncFailurePresentation(
            error: partial, retryWillOccurAutomatically: false
        )
        XCTAssertEqual(
            String(localized: presentation.title), "iCloud storage is full"
        )

        let mixedPartial = NSError(
            domain: CKErrorDomain,
            code: CKError.partialFailure.rawValue,
            userInfo: [
                CKPartialErrorsByItemIDKey: [
                    "a-transient": CKError(.serviceUnavailable),
                    "b-corrupt": CloudKitSyncTransportError.corruptState,
                ]
            ]
        )
        let mixed = SyncFailurePresentation(
            error: mixedPartial, retryWillOccurAutomatically: true
        )
        XCTAssertEqual(
            String(localized: mixed.title), "Sync state needs recovery"
        )
        XCTAssertEqual(mixed.retryDisposition, .unavailable)

        let transport = SyncFailurePresentation(
            error: CloudKitSyncTransportError.uploadFailed(
                code: CKError.networkFailure.rawValue
            ),
            retryWillOccurAutomatically: false
        )
        XCTAssertEqual(
            String(localized: transport.title), "Sync temporarily unavailable"
        )
        XCTAssertEqual(transport.retryDisposition, .manual)

        let wrappedStorage = SyncFailurePresentation(
            error: CloudKitStateWriteFailure(underlyingError: POSIXError(.ENOSPC)),
            retryWillOccurAutomatically: false
        )
        XCTAssertEqual(
            String(localized: wrappedStorage.title), "Device storage is full"
        )
    }

    func testUnsafeStateAndDeletionNeverSuggestReset() {
        for error: any Error in [
            CloudKitSyncTransportError.corruptState,
            CloudKitSyncTransportError.unrecoverableRetryDelay,
            CloudKitSyncTransportError.invalidRemoteRecord,
            CloudKitSyncTransportError.unexpectedDeletion,
            SyncError.scopeChanged,
        ] {
            let presentation = SyncFailurePresentation(
                error: error, retryWillOccurAutomatically: false
            )
            XCTAssertNotNil(presentation.actionHint)
            XCTAssertFalse(
                String(localized: presentation.message).localizedCaseInsensitiveContains("reset")
            )
            XCTAssertFalse(
                String(localized: presentation.actionHint!).localizedCaseInsensitiveContains("reset")
            )
        }

        let unknown = SyncFailurePresentation(
            error: NSError(domain: "opaque-storage", code: 7),
            retryWillOccurAutomatically: false
        )
        XCTAssertEqual(String(localized: unknown.title), "Sync failed")
        XCTAssertEqual(unknown.retryDisposition, .manual)
        XCTAssertFalse(
            String(localized: unknown.message).localizedCaseInsensitiveContains("storage is full")
        )
    }
}
