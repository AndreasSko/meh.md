import Automerge
import Foundation
import XCTest

@testable import NoteCore

@MainActor
final class NotebookTimeCalculatorTests: XCTestCase {
    private func replica() async throws -> NotebookReplica {
        let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        let replica = NotebookReplica(directory: directory)
        try await replica.createLocalNotebook()
        return replica
    }

    func testNoteChoiceSurvivesReloadAndCanBeTurnedOff() async throws {
        let replica = try await replica()
        let note = try await replica.createNote(name: "Travel.md", text: "Flight 2h\n=")
        let other = try await replica.createNote(name: "Other.md")
        XCTAssertTrue(replica.timeCalculatorNoteIDs.isEmpty)

        try await replica.setTimeCalculator(note, enabled: true)
        XCTAssertEqual(replica.timeCalculatorNoteIDs, [note])
        let loaded = NotebookReplica(directory: replica.directory)
        try await loaded.load()
        XCTAssertEqual(loaded.timeCalculatorNoteIDs, [note])

        try await loaded.setTimeCalculator(note, enabled: false)
        try await loaded.setTimeCalculator(other, enabled: true)
        XCTAssertEqual(loaded.timeCalculatorNoteIDs, [other])
    }

    func testOnlyExistingNotesCanTurnItOn() async throws {
        let replica = try await replica()
        let folder = try await replica.createFolder(name: "Plans")
        for id in [folder, UUID()] {
            do {
                try await replica.setTimeCalculator(id, enabled: true)
                XCTFail("Only notes have a time calculator")
            } catch {
                XCTAssertEqual(error as? NotebookCatalogError, .itemNotFound)
            }
        }
        XCTAssertTrue(replica.timeCalculatorNoteIDs.isEmpty)
    }

    func testDeletedNotesLeaveTheProjection() async throws {
        let replica = try await replica()
        let note = try await replica.createNote(name: "Week.md")
        try await replica.setTimeCalculator(note, enabled: true)
        try await replica.rememberDeletions([note])
        XCTAssertTrue(replica.timeCalculatorNoteIDs.isEmpty)
    }

    func testChoicesFromTwoDevicesMerge() throws {
        let base = try NotebookCatalogDocument()
        let first = try base.add(kind: .note, name: "First.md")
        let second = try base.add(kind: .note, name: "Second.md")
        let left = try base.fork()
        let right = try base.fork()
        try left.setTimeCalculator(first, enabled: true)
        try right.setTimeCalculator(second, enabled: true)
        try left.merge(right)

        let reloaded = try NotebookCatalogDocument(snapshot: left.snapshot())
        XCTAssertEqual(try reloaded.timeCalculatorNoteIDs(), [first, second])
    }

    func testMalformedChoicesAreRejected() throws {
        let catalog = try NotebookCatalogDocument()
        let note = try catalog.add(kind: .note, name: "Source.md")
        for (key, value) in [
            ("timeCalculator.invalid-id", ScalarValue.Boolean(true)),
            ("timeCalculator." + note.uuidString, ScalarValue.String("true")),
            ("timeCalculator.extra." + note.uuidString, ScalarValue.Boolean(true)),
        ] {
            let raw = try Document(catalog.snapshot().data)
            try raw.put(obj: .ROOT, key: key, value: value)
            XCTAssertThrowsError(try NotebookCatalogDocument(serializedData: raw.save()))
        }
    }
}
