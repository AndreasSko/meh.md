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
        let sceneID = UUID()
        state.prepare(enabled: true)
        XCTAssertTrue(state.isPresented(in: sceneID))
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.path))
        state.dismiss(in: sceneID)
        let relaunched = welcome()
        relaunched.prepare(enabled: true)
        XCTAssertFalse(relaunched.isPresented(in: sceneID))
        relaunched.show(in: sceneID)
        XCTAssertTrue(relaunched.isPresented(in: sceneID))
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
            XCTAssertFalse(state.isPresented(in: UUID()))
            XCTAssertEqual(try Data(contentsOf: directory.appending(path: filename)),
                           Data("retained damaged bytes".utf8))
        }
    }

    func testDisabledFixtureDoesNotCompleteRealFirstUse() {
        welcome().prepare(enabled: false)
        let state = welcome()
        state.prepare(enabled: true)
        XCTAssertTrue(state.isPresented(in: UUID()))
    }

    func testFirstUseIsSharedButChoiceBelongsToTheSelectedScene() {
        let firstScene = UUID()
        let secondScene = UUID()
        let state = welcome()
        state.prepare(enabled: true)

        XCTAssertTrue(state.isPresented(in: firstScene))
        XCTAssertTrue(state.isPresented(in: secondScene))
        state.choose(.newNote, from: secondScene)
        state.choose(.examples, from: firstScene)

        XCTAssertEqual(state.requestID, 1)
        XCTAssertFalse(state.isPresented(in: firstScene))
        XCTAssertFalse(state.isPresented(in: secondScene))
        XCTAssertNil(state.takeChoice(for: firstScene))
        XCTAssertEqual(state.takeChoice(for: secondScene), .newNote)
        XCTAssertNil(state.takeChoice(for: secondScene))
        state.prepare(enabled: true)
        XCTAssertFalse(state.isPresented(in: firstScene))
        let next = welcome()
        next.prepare(enabled: true)
        XCTAssertFalse(next.isPresented(in: secondScene))
    }

    func testSettingsWelcomePresentationIsScopedToOneScene() {
        let firstScene = UUID()
        let secondScene = UUID()
        let state = welcome()
        state.prepare(enabled: true)
        state.dismiss(in: firstScene)
        state.show(in: secondScene)

        XCTAssertFalse(state.isPresented(in: firstScene))
        XCTAssertTrue(state.isPresented(in: secondScene))
        state.dismiss(in: secondScene)
        XCTAssertFalse(state.isPresented(in: firstScene))
        XCTAssertFalse(state.isPresented(in: secondScene))
    }

    func testClosingRequestingSceneAllowsAnotherSceneToChoose() {
        let workspace = workspace()
        let state = workspace.welcome
        let closedScene = UUID()
        let remainingScene = UUID()
        state.prepare(enabled: true)
        state.choose(.examples, from: closedScene)

        workspace.sceneDidClose(id: closedScene)
        XCTAssertNil(state.takeChoice(for: closedScene))
        state.show(in: remainingScene)
        state.choose(.newNote, from: remainingScene)
        XCTAssertEqual(state.takeChoice(for: remainingScene), .newNote)
        XCTAssertNil(state.takeChoice(for: remainingScene))
    }

    func testClosingOtherScenePreservesChoiceAndScopedPresentation() {
        let workspace = workspace()
        let state = workspace.welcome
        let closedScene = UUID()
        let remainingScene = UUID()
        state.prepare(enabled: true)
        state.choose(.importNotes, from: remainingScene)
        state.show(in: closedScene)
        state.show(in: remainingScene)

        workspace.sceneDidClose(id: closedScene)
        XCTAssertFalse(state.isPresented(in: closedScene))
        XCTAssertTrue(state.isPresented(in: remainingScene))
        XCTAssertNil(state.takeChoice(for: closedScene))
        XCTAssertEqual(state.takeChoice(for: remainingScene), .importNotes)
    }

    func testClosingSceneDoesNotCompleteFirstUse() {
        let workspace = workspace()
        workspace.welcome.prepare(enabled: true)
        workspace.sceneDidClose(id: UUID())
        XCTAssertTrue(workspace.welcome.isPresented(in: UUID()))
        let relaunched = welcome()
        relaunched.prepare(enabled: true)
        XCTAssertTrue(relaunched.isPresented(in: UUID()))
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
        XCTAssertEqual(
            template.settings,
            NotebookTemplateSettings(destination: .root,
                                     filenamePattern: "{{date}} - {{template}}")
        )
        let source = try await replica.openNote(template.id)
        let copiedID = try await replica.createNoteFromTemplate(template.id)
        let copied = try await replica.openNote(copiedID)
        let copiedName = try XCTUnwrap(replica.placements.first {
            $0.item.id == copiedID
        }?.item.name)
        XCTAssertTrue(copiedName.hasSuffix(" - Meeting.md"))
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
            XCTAssertTrue(error.localizedDescription.contains("unavailable"))
        }
        XCTAssertEqual(replica.placements.count, 4)
        XCTAssertTrue(replica.placements.allSatisfy(\.isInTrash))
    }

    func testReopeningExamplesAfterPartialPermanentDeletionLeavesSurvivors() async throws {
        let replica = try await replica()
        let state = welcome()
        let introductionID = try await state.installExamples(in: replica)
        let introduction = try await replica.openNote(introductionID)
        try introduction.replaceAll(with: "My retained Start Here edit")
        try await introduction.flush()

        let removedID = try XCTUnwrap(replica.placements.first {
            $0.item.name == "Try Markdown.md"
        }?.item.id)
        try await permanentlyDelete(removedID, in: replica)

        let returnedID = try await welcome().installExamples(in: replica)
        XCTAssertEqual(returnedID, introductionID)
        XCTAssertFalse(replica.placements.contains { $0.item.id == removedID })
        XCTAssertEqual(replica.placements.count, 3)
        XCTAssertEqual(replica.templates.count, 1)
        let returned = try await replica.openNote(returnedID)
        XCTAssertEqual(returned.text, "My retained Start Here edit")
    }

    func testReopeningExamplesAfterPermanentDeletionDoesNotReimport() async throws {
        let replica = try await replica()
        let introductionID = try await welcome().installExamples(in: replica)
        let folderID = try XCTUnwrap(replica.placements.first {
            $0.item.id == introductionID
        }?.parentID)
        try await permanentlyDelete(folderID, in: replica)
        XCTAssertTrue(replica.placements.isEmpty)

        do {
            _ = try await welcome().installExamples(in: replica)
            XCTFail("Permanently deleted examples must not be imported again")
        } catch {
            XCTAssertTrue(error.localizedDescription.contains("Start Here is unavailable"))
        }
        XCTAssertTrue(replica.placements.isEmpty)
        XCTAssertTrue(replica.templates.isEmpty)
    }

    func testInterruptedExampleReceiptDoesNotReplayDeletedIdentities() async throws {
        enum Interruption: Error { case stop }
        let replica = try await replica()
        let state = welcome()
        replica.importFaultInjector = { stage in
            if stage == .catalogSaved { throw Interruption.stop }
        }
        do {
            _ = try await state.installExamples(in: replica)
            XCTFail("Expected the interrupted import")
        } catch is Interruption {}

        try await replica.resumePendingImport()
        let templateID = try XCTUnwrap(replica.placements.first {
            $0.item.name == "Meeting.md"
        }?.item.id)
        let customizedSettings = NotebookTemplateSettings(
            destination: .root, filenamePattern: "My meeting filename")
        try await replica.setTemplateSettings(customizedSettings, for: templateID)
        try await replica.setTemplateSource(templateID, enabled: true)
        let removedID = try XCTUnwrap(replica.placements.first {
            $0.item.name == "Try Markdown.md"
        }?.item.id)
        try await permanentlyDelete(removedID, in: replica)

        let introductionID = try await welcome().installExamples(in: replica)
        XCTAssertTrue(replica.placements.contains {
            $0.item.id == introductionID && $0.item.name == "Start Here.md"
        })
        XCTAssertFalse(replica.placements.contains { $0.item.id == removedID })
        XCTAssertEqual(replica.placements.count, 3)
        XCTAssertEqual(replica.templates.first?.settings, customizedSettings)
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

    private func permanentlyDelete(
        _ id: UUID, in replica: NotebookReplica
    ) async throws {
        try await replica.setTrashed(id, true)
        try await replica.permanentlyDelete(replica.deletionSelection(rootID: id))
    }

    private func workspace() -> NotebookWorkspace {
        let workspace = NotebookWorkspace(
            directory: root, documentsDirectory: root.appending(path: "Documents"),
            transport: nil, automaticSync: false, mode: .local)
        workspace.welcome = welcome()
        return workspace
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
