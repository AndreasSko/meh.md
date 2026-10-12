import Foundation
import XCTest
@testable import AssistantCore

final class AssistantThreadStoreTests: XCTestCase {
    func testThreadsRoundTripInUpdatedOrderAndStayPartitioned() async throws {
        let root = FileManager.default.temporaryDirectory
            .appending(path: "AssistantThreadStoreTests-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let store = AssistantThreadStore(directory: root)
        let earlier = AssistantThread(
            title: "Earlier", messages: [
                AssistantMessage(role: .user, text: "Question"),
                AssistantMessage(role: .assistant, text: "Answer"),
            ], updatedAt: Date(timeIntervalSince1970: 10)
        )
        let later = AssistantThread(
            title: "Later", messages: [
                AssistantMessage(
                    role: .assistant, text: "Partial", status: .interrupted
                ),
            ], updatedAt: Date(timeIntervalSince1970: 20)
        )

        try await store.save(
            [earlier, later], providerID: "chatgpt", accountID: "account-a"
        )

        let loaded = try await store.load(
            providerID: "chatgpt", accountID: "account-a"
        )
        let otherAccount = try await store.load(
            providerID: "chatgpt", accountID: "account-b"
        )
        let otherProvider = try await store.load(
            providerID: "another-provider", accountID: "account-a"
        )
        XCTAssertEqual(loaded, [later, earlier])
        XCTAssertTrue(otherAccount.isEmpty)
        XCTAssertTrue(otherProvider.isEmpty)
    }

    func testMissingPartitionIsRejected() async throws {
        let root = FileManager.default.temporaryDirectory
            .appending(path: "AssistantThreadStoreTests-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let store = AssistantThreadStore(directory: root)

        do {
            try await store.save([], providerID: "", accountID: "account-a")
            XCTFail("Expected empty provider to be rejected")
        } catch let error as AssistantThreadStoreError {
            XCTAssertEqual(error, .missingPartition)
        }
    }
}
