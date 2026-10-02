import Foundation
import XCTest
@testable import NotebookAppModel
@testable import NoteCore

@MainActor
final class NotebookWelcomeTests: XCTestCase {
    private var root: URL!
    private var defaults: UserDefaults!
    private var suite: String!

    override func setUp() async throws {
        root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        suite = "WelcomeTests.\(UUID())"
        defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
    }

    override func tearDown() async throws {
        defaults.removePersistentDomain(forName: suite)
        try? FileManager.default.removeItem(at: root)
    }

    func testFirstLaunchIsOptionalAndCompletionSurvivesRelaunch() {
        let state = welcome()
        state.prepare(enabled: true)
        XCTAssertTrue(state.isPresented)
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.path))
        state.dismiss()
        let relaunched = welcome()
        relaunched.prepare(enabled: true)
        XCTAssertFalse(relaunched.isPresented)
        relaunched.show()
        XCTAssertTrue(relaunched.isPresented)
    }

    func testExistingAndDamagedNotebooksKeepTheirOpeningFlow() throws {
        for filename in ["catalog.automerge", "catalog.previous.automerge"] {
            let directory = root.appending(path: filename)
            try FileManager.default.createDirectory(at: directory,
                                                     withIntermediateDirectories: true)
            try Data("retained damaged bytes".utf8)
                .write(to: directory.appending(path: filename))
            let state = NotebookWelcomeState(directory: directory, store: defaults)
            state.prepare(enabled: true)
            XCTAssertFalse(state.isPresented)
            XCTAssertEqual(try Data(contentsOf: directory.appending(path: filename)),
                           Data("retained damaged bytes".utf8))
        }
    }

    func testDisabledFixtureDoesNotCompleteRealFirstUse() {
        welcome().prepare(enabled: false)
        let state = welcome()
        state.prepare(enabled: true)
        XCTAssertTrue(state.isPresented)
    }

    func testMultipleScenesConsumeOneChoiceAndExplicitHandoffCanSkipPreparation() {
        let state = welcome()
        state.choose(.newNote)
        state.choose(.examples)
        XCTAssertEqual(state.requestID, 1)
        XCTAssertEqual(state.takeChoice(), .newNote)
        XCTAssertNil(state.takeChoice())
        state.prepare(enabled: true)
        XCTAssertFalse(state.isPresented)
        let next = welcome()
        next.prepare(enabled: true)
        XCTAssertFalse(next.isPresented)
    }

    func testExamplesKeepExistingNotesAndProvideAnIndependentTemplate() async throws {
        let replica = try await replica()
        let existingFolder = try await replica.createFolder(name: "Example Notes")
        let existing = try await replica.createNote(
            name: "Start Here.md", text: "My existing text", parentID: existingFolder)
        try await replica.setDefaultNewNoteParentID(existingFolder)
        let introductionID = try await welcome().installExamples(in: replica)
        XCTAssertEqual(replica.placements.count, 6)
        XCTAssertEqual(replica.defaultNewNoteParentID, existingFolder)
        let original = try await replica.openNote(existing)
        XCTAssertEqual(original.text, "My existing text")
        let introduction = try await replica.openNote(introductionID)
        XCTAssertTrue(introduction.text.contains("[[Try Markdown]]"))
        let template = try XCTUnwrap(replica.templates.first)
        XCTAssertEqual(template.name, "Meeting.md")
        let source = try await replica.openNote(template.id)
        let copiedID = try await replica.createNoteFromTemplate(template.id)
        let copied = try await replica.openNote(copiedID)
        XCTAssertEqual(copied.text, source.text)
        XCTAssertNotEqual(copiedID, template.id)
        try copied.replaceAll(with: "My actual meeting")
        XCTAssertTrue(source.text.contains("## Next steps"))
        XCTAssertEqual(replica.templates.count, 1)
    }

    func testReopeningExamplesPreservesEditsAndTemplateSettingsAfterRelaunch() async throws {
        let replica = try await replica()
        let introductionID = try await welcome().installExamples(in: replica)
        let introduction = try await replica.openNote(introductionID)
        try introduction.replaceAll(with: "My revised introduction")
        try await introduction.flush()
        let template = try XCTUnwrap(replica.templates.first)
        let settings = NotebookTemplateSettings(filenamePattern: "My custom filename")
        try await replica.setTemplateSettings(settings, for: template.id)
        let reopened = NotebookReplica(directory: root)
        try await reopened.load()
        let returnedID = try await welcome().installExamples(in: reopened)
        XCTAssertEqual(returnedID, introductionID)
        XCTAssertEqual(reopened.placements.count, 4)
        XCTAssertEqual(reopened.templates.first?.settings, settings)
        let returned = try await reopened.openNote(returnedID)
        XCTAssertEqual(returned.text, "My revised introduction")
    }

    func testInterruptedExamplesUseTheDurableImportWithoutDuplicates() async throws {
        enum Interruption: Error { case stop }
        let replica = try await replica()
        replica.importFaultInjector = { stage in
            if stage == .catalogSaved { throw Interruption.stop }
        }
        do {
            _ = try await welcome().installExamples(in: replica)
            XCTFail("Expected the interrupted import")
        } catch is Interruption {}
        let reopened = NotebookReplica(directory: root)
        try await reopened.load()
        XCTAssertTrue(reopened.hasPendingImport)
        do {
            _ = try await welcome().installExamples(in: reopened)
            XCTFail("The normal importer must finish recovery first")
        } catch NotebookImportError.pendingImportExists {}
        XCTAssertTrue(reopened.templates.isEmpty)
        try await reopened.resumePendingImport()
        _ = try await welcome().installExamples(in: reopened)
        XCTAssertEqual(reopened.placements.count, 4)
        XCTAssertEqual(reopened.templates.count, 1)
    }

    func testReopeningTrashedExamplesDoesNotResurrectThem() async throws {
        let replica = try await replica()
        let id = try await welcome().installExamples(in: replica)
        let folder = try XCTUnwrap(replica.placements.first {
            $0.item.id == id
        }?.parentID)
        try await replica.setTrashed(folder, true)
        do {
            _ = try await welcome().installExamples(in: replica)
            XCTFail("Removed examples must stay removed")
        } catch {
            XCTAssertTrue(error.localizedDescription.contains("Trash"))
        }
        XCTAssertEqual(replica.placements.count, 4)
        XCTAssertTrue(replica.placements.allSatisfy(\.isInTrash))
    }

    func testExamplesAndTemplateConvergeThroughOrdinaryNotebookSync() async throws {
        let store = InMemorySyncStore()
        let transport = InMemorySyncTransport(scope: "welcome", store: store)
        let left = try await replica()
        let introductionID = try await welcome().installExamples(in: left)
        let leftSync = NotebookSyncCoordinator(replica: left, transport: transport)
        await leftSync.synchronize()
        XCTAssertNil(leftSync.lastError)
        let right = NotebookReplica(directory: root.appending(path: "second-device"))
        let rightSync = NotebookSyncCoordinator(replica: right, transport: transport)
        await rightSync.synchronize()
        XCTAssertNil(rightSync.lastError)
        XCTAssertEqual(left.placements, right.placements)
        XCTAssertEqual(left.templates, right.templates)
        let introduction = try await right.openNote(introductionID)
        XCTAssertTrue(introduction.text.contains("[[Meeting]]"))
    }

    private func welcome() -> NotebookWelcomeState {
        NotebookWelcomeState(directory: root, store: defaults)
    }

    private func replica() async throws -> NotebookReplica {
        let replica = NotebookReplica(directory: root)
        try await replica.createLocalNotebook()
        return replica
    }
}
