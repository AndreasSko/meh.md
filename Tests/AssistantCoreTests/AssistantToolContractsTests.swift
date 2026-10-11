import Foundation
import XCTest
@testable import AssistantCore

final class AssistantToolContractsTests: XCTestCase {
    func testOlderChatPersistenceDecodesWithoutToolMetadata() throws {
        let id = UUID()
        let old = """
        {"id":"\(id)","title":"Existing chat","messages":[
        {"id":"\(UUID())","role":"assistant","text":"Earlier reply",
        "status":"complete","createdAt":0}],"updatedAt":0}
        """
        let thread = try JSONDecoder().decode(AssistantThread.self, from: Data(old.utf8))
        XCTAssertEqual(thread.id, id)
        XCTAssertNil(thread.notebookID)
        XCTAssertEqual(thread.messages.first?.toolActivities, [])
        XCTAssertNil(thread.messages.first?.providerContext)
    }

    func testToolActionsAndOpaqueContextRoundTripWithInterruptedTurn() throws {
        let notebook = UUID()
        let reference = AssistantNoteReference(notebookID: notebook, noteID: UUID(), title: "Fictional note")
        let activity = AssistantToolActivity(callID: "call_saved", name: "create_note",
            phase: .completed, summary: "Created Fictional note", noteReferences: [reference],
            output: #"{"saved":true}"#)
        let thread = AssistantThread(messages: [AssistantMessage(role: .assistant,
            text: "Partial reply", status: .interrupted, toolActivities: [activity],
            providerContext: "opaque-provider-context")], notebookID: notebook)
        let decoded = try JSONDecoder().decode(AssistantThread.self, from: JSONEncoder().encode(thread))
        XCTAssertEqual(decoded, thread)
        XCTAssertEqual(decoded.messages[0].toolActivities[0].noteReferences[0], reference)
        XCTAssertEqual(decoded.messages[0].toolActivities[0].output, #"{"saved":true}"#)
    }
}
