import CloudKit
import XCTest

@testable import NoteCore

@MainActor
final class CloudKitBootstrapZoneRetryTests: XCTestCase {
    func testExistingZoneReadsCanonicalWithoutZoneQuery() async throws {
        var calls: [String] = []
        let canonical = try await CloudKitBootstrapZoneRetry.perform {
            calls.append("read")
            return "canonical"
        } ensureZone: {
            calls.append("zone")
        }

        XCTAssertEqual(canonical, "canonical")
        XCTAssertEqual(calls, ["read"])
    }

    func testMissingZoneIsResolvedThenReadOnceMore() async throws {
        var calls: [String] = []
        var attempts = 0
        let canonical = try await CloudKitBootstrapZoneRetry.perform {
            calls.append("read")
            attempts += 1
            if attempts == 1 { throw CKError(.zoneNotFound) }
            return "canonical"
        } ensureZone: {
            calls.append("zone")
        }

        XCTAssertEqual(canonical, "canonical")
        XCTAssertEqual(calls, ["read", "zone", "read"])
    }

    func testMissingCanonicalPassesThroughWithoutZoneQuery() async {
        var calls: [String] = []
        do {
            let _: String = try await CloudKitBootstrapZoneRetry.perform {
                calls.append("read")
                throw CKError(.unknownItem)
            } ensureZone: {
                calls.append("zone")
            }
            XCTFail("The caller must create a missing canonical record")
        } catch let error as CKError {
            XCTAssertEqual(error.code, .unknownItem)
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
        XCTAssertEqual(calls, ["read"])
    }

    func testSaveRaceResolvesOnlyZoneNotFound() async throws {
        var calls: [String] = []
        var attempts = 0
        let saved = try await CloudKitBootstrapZoneRetry.perform {
            calls.append("save")
            attempts += 1
            if attempts == 1 { throw CKError(.zoneNotFound) }
            return "saved"
        } ensureZone: {
            calls.append("zone")
        }

        XCTAssertEqual(saved, "saved")
        XCTAssertEqual(calls, ["save", "zone", "save"])
    }

    func testOtherCloudKitFailuresDoNotCreateZone() async {
        let codes: [CKError.Code] = [
            .permissionFailure, .partialFailure, .serverRecordChanged,
            .userDeletedZone, .notAuthenticated, .requestRateLimited,
            .networkUnavailable, .operationCancelled,
        ]
        for code in codes {
            var calls: [String] = []
            do {
                let _: String = try await CloudKitBootstrapZoneRetry.perform {
                    calls.append("read")
                    throw CKError(code)
                } ensureZone: {
                    calls.append("zone")
                }
                XCTFail("Expected \(code) to propagate")
            } catch let error as CKError {
                XCTAssertEqual(error.code, code)
            } catch {
                XCTFail("Unexpected error: \(error)")
            }
            XCTAssertEqual(calls, ["read"])
        }
    }

    func testZoneResolutionFailureDoesNotRetryRead() async {
        var calls: [String] = []
        do {
            let _: String = try await CloudKitBootstrapZoneRetry.perform {
                calls.append("read")
                throw CKError(.zoneNotFound)
            } ensureZone: {
                calls.append("zone")
                throw CKError(.permissionFailure)
            }
            XCTFail("Failed zone resolution must stop bootstrap")
        } catch let error as CKError {
            XCTAssertEqual(error.code, .permissionFailure)
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
        XCTAssertEqual(calls, ["read", "zone"])
    }

    func testSecondMissingZoneErrorPropagatesWithoutAnotherQuery() async {
        var calls: [String] = []
        do {
            let _: String = try await CloudKitBootstrapZoneRetry.perform {
                calls.append("read")
                throw CKError(.zoneNotFound)
            } ensureZone: {
                calls.append("zone")
            }
            XCTFail("A second missing-zone error must stop bootstrap")
        } catch let error as CKError {
            XCTAssertEqual(error.code, .zoneNotFound)
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
        XCTAssertEqual(calls, ["read", "zone", "read"])
    }
}
