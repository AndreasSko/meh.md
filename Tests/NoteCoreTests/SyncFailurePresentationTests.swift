import CloudKit
import Foundation
import XCTest
@testable import NoteCore

final class SyncFailurePresentationTests: XCTestCase {
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
