import Automerge
import Foundation
import XCTest

@testable import NoteCore

@MainActor
final class NotebookTextRuleTests: XCTestCase {
    private func replica() async throws -> NotebookReplica {
        let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        let replica = NotebookReplica(directory: directory)
        try await replica.createLocalNotebook()
        return replica
    }

    func testRulesSurviveReloadInListOrder() async throws {
        let replica = try await replica()
        let bible = NotebookTextRule(source: .script(source: "rule({ name: \"Bible\" })"), order: 1,
                                     options: ["open": .text("web")])
        let script = NotebookTextRule(source: .script(source: "rule({ block() {} })"),
                                      isEnabled: false, appliesToAllNotes: false, order: 0)
        let link = NotebookTextRule(source: .link(rule: NotebookTextLinkRule(
            name: "Tickets", find: "[A-Z]+-\\d+", isRegularExpression: true,
            url: "https://tracker.example.com/$0")), order: 2)
        for rule in [bible, script, link] { try await replica.saveTextRule(rule) }
        XCTAssertEqual(replica.textRules, [script, bible, link])

        let loaded = NotebookReplica(directory: replica.directory)
        try await loaded.load()
        XCTAssertEqual(loaded.textRules, [script, bible, link])

        try await loaded.reorderTextRules([link.id, bible.id])
        XCTAssertEqual(loaded.textRules.map(\.id), [link.id, bible.id, script.id])
        try await loaded.deleteTextRule(bible.id)
        XCTAssertEqual(loaded.textRules.map(\.id), [link.id, script.id])
    }

    func testNoteChoicesFollowTheRuleAndTheNote() async throws {
        let replica = try await replica()
        let note = try await replica.createNote(name: "Study.md")
        let other = try await replica.createNote(name: "Other.md")
        let rule = NotebookTextRule(source: .script(source: "rule({ name: \"Times\" })"), appliesToAllNotes: false)
        try await replica.saveTextRule(rule)
        try await replica.setTextRule(rule.id, note: note, enabled: true)
        try await replica.setTextRule(rule.id, note: other, enabled: true)
        try await replica.setTextRule(rule.id, note: other, enabled: false)
        XCTAssertEqual(replica.textRuleNoteIDs, [rule.id: [note]])

        do {
            try await replica.setTextRule(rule.id, note: UUID(), enabled: true)
            XCTFail("Only notes can turn a rule on")
        } catch {
            XCTAssertEqual(error as? NotebookCatalogError, .itemNotFound)
        }

        try await replica.rememberDeletions([note])
        XCTAssertEqual(replica.textRuleNoteIDs[rule.id], [])
        try await replica.deleteTextRule(rule.id)
        XCTAssertTrue(replica.textRuleNoteIDs.isEmpty)
    }

    func testAnUpdateChangesOnlyItsField() async throws {
        let replica = try await replica()
        let rule = NotebookTextRule(source: .script(source: "rule({ block() {} })"))
        try await replica.saveTextRule(rule)
        var edited = rule
        edited.source = .script(source: "rule({ name: 'New', block() {} })")
        try await replica.saveTextRule(edited)
        // A toggle made from the old copy keeps the newer script.
        try await replica.updateTextRule(rule.id) { $0.isEnabled = false }
        XCTAssertEqual(replica.textRules.first?.source, edited.source)
        XCTAssertEqual(replica.textRules.first?.isEnabled, false)
    }

    func testUpdatingADeletedRuleFailsWithoutBringingItBack() async throws {
        let replica = try await replica()
        let rule = NotebookTextRule(source: .script(source: "rule({ block() {} })"))
        try await replica.saveTextRule(rule)
        try await replica.deleteTextRule(rule.id)
        do {
            try await replica.updateTextRule(rule.id) { $0.source = .script(source: "edited") }
            XCTFail("A deleted rule can't be edited")
        } catch {
            XCTAssertEqual(error as? NotebookCatalogError, .itemNotFound)
        }
        XCTAssertTrue(replica.textRules.isEmpty)
    }

    func testEditsOnTwoDevicesMergeFieldByField() throws {
        let base = try NotebookCatalogDocument()
        let rule = NotebookTextRule(source: .script(source: "rule({ name: \"Bible\" })"))
        try base.setTextRule(rule)
        let left = try base.fork()
        let right = try base.fork()
        var disabled = rule
        disabled.isEnabled = false
        try left.setTextRule(disabled)
        var changed = rule
        changed.options = ["open": .text("web")]
        try right.setTextRule(changed)
        try left.merge(right)

        let reloaded = try NotebookCatalogDocument(snapshot: left.snapshot())
        let merged = try XCTUnwrap(reloaded.textRuleMetadata().rules.first)
        XCTAssertFalse(merged.isEnabled)
        XCTAssertEqual(merged.options, ["open": .text("web")])
    }

    func testARuleDeletedWhileEditedElsewhereStaysDeleted() throws {
        let base = try NotebookCatalogDocument()
        let rule = NotebookTextRule(source: .script(source: "rule({ name: \"Bible\" })"))
        try base.setTextRule(rule)
        let left = try base.fork()
        let right = try base.fork()
        try left.deleteTextRule(rule.id)
        var disabled = rule
        disabled.isEnabled = false
        try right.setTextRule(disabled)
        try left.merge(right)
        XCTAssertTrue(try left.textRuleMetadata().rules.isEmpty)
    }

    func testASourceEditedWhileDeletedElsewhereStaysDeleted() throws {
        let base = try NotebookCatalogDocument()
        let rule = NotebookTextRule(source: .script(source: "rule({ block() {} })"),
                                    isEnabled: false, appliesToAllNotes: false)
        try base.setTextRule(rule)
        let left = try base.fork()
        let right = try base.fork()
        try left.deleteTextRule(rule.id)
        var edited = rule
        edited.source = .script(source: "rule({ name: 'New', block() {} })")
        try right.setTextRule(edited)
        try left.merge(right)
        XCTAssertTrue(try left.textRuleMetadata().rules.isEmpty)
    }

    func testAFullEditElsewhereDoesNotBringBackADeletedRule() throws {
        let base = try NotebookCatalogDocument()
        let rule = NotebookTextRule(source: .script(source: "rule({ block() {} })"),
                                    isEnabled: false, appliesToAllNotes: false)
        try base.setTextRule(rule)
        let left = try base.fork()
        let right = try base.fork()
        try left.deleteTextRule(rule.id)
        var edited = rule
        edited.source = .script(source: "rule({ name: 'New', block() {} })")
        edited.isEnabled = true
        edited.appliesToAllNotes = true
        try right.setTextRule(edited)
        try left.merge(right)
        XCTAssertTrue(try left.textRuleMetadata().rules.isEmpty)
    }

    func testValuesInUnknownFormsAreSkippedNotFatal() throws {
        let catalog = try NotebookCatalogDocument()
        let valid = NotebookTextRule(source: .script(source: "rule({ name: \"Valid\" })"))
        let yes = NotebookTextRule(source: .script(source: "rule({ name: \"Yes\" })"))
        let scoped = NotebookTextRule(source: .script(source: "rule({ name: \"Scoped\" })"))
        for rule in [valid, yes, scoped] { try catalog.setTextRule(rule) }
        let raw = try Document(catalog.snapshot().data)
        let future = UUID().uuidString
        try raw.put(obj: .ROOT, key: "textRule.\(future).source",
                    value: .String(#"{"plugin":{"url":"x"}}"#))
        try raw.put(obj: .ROOT, key: "textRule.\(future).enabled", value: .Boolean(true))
        try raw.put(obj: .ROOT, key: "textRule.\(future).scope", value: .String("all"))
        try raw.put(obj: .ROOT, key: "textRule.not-an-id.source", value: .Boolean(true))
        try raw.put(obj: .ROOT, key: "textRule.\(yes.id.uuidString).enabled", value: .String("yes"))
        try raw.put(obj: .ROOT, key: "textRule.\(scoped.id.uuidString).scope", value: .String("folder"))
        try raw.put(obj: .ROOT, key: "textRuleNote.\(valid.id.uuidString).x", value: .Boolean(true))
        let reopened = try NotebookCatalogDocument(serializedData: raw.save())
        XCTAssertEqual(try reopened.textRuleMetadata().rules, [valid])
        XCTAssertEqual(try reopened.textRuleMetadata().noteIDs, [:])
    }

    func testOptionsThisVersionCannotReadSurviveOtherEdits() throws {
        let rule = NotebookTextRule(source: .script(source: "rule({ name: \"Bible\" })"))
        let original = try NotebookCatalogDocument()
        try original.setTextRule(rule)
        let raw = try Document(original.snapshot().data)
        let key = "textRule.\(rule.id.uuidString).options"
        let stored = #"{"future":3,"open":"web"}"#
        try raw.put(obj: .ROOT, key: key, value: .String(stored))
        let catalog = try NotebookCatalogDocument(serializedData: raw.save())
        func storedOptions() throws -> Value? {
            try Document(catalog.snapshot().data).get(obj: .ROOT, key: key)
        }

        var read = try XCTUnwrap(catalog.textRuleMetadata().rules.first)
        XCTAssertEqual(read.options, ["open": .text("web")])
        read.isEnabled = false
        try catalog.setTextRule(read)
        XCTAssertEqual(try storedOptions(), .Scalar(.String(stored)))

        read.options["open"] = .text("app")
        try catalog.setTextRule(read)
        XCTAssertEqual(try catalog.textRuleMetadata().rules.first?.options, ["open": .text("app")])
    }

    func testCombiningNotebooksKeepsTheirRules() throws {
        let catalog = try NotebookCatalogDocument()
        let mine = NotebookTextRule(source: .script(source: "rule({ name: \"Bible\" })"))
        try catalog.setTextRule(mine)
        let other = try NotebookCatalogDocument()
        let note = try other.add(kind: .note, name: "Talk.md")
        let theirs = NotebookTextRule(source: .script(source: "rule({ name: \"Times\" })"),
                                      appliesToAllNotes: false, order: 1)
        try other.setTextRule(theirs)
        try other.setTextRule(theirs.id, note: note, enabled: true)

        let combined = try catalog.forkCombining(other, intoFolderNamed: "Other")
        let metadata = try combined.textRuleMetadata()
        XCTAssertEqual(metadata.rules, [mine, theirs])
        XCTAssertEqual(metadata.noteIDs, [theirs.id: [note]])
    }

    func testCombiningKeepsARuleTheOtherNotebookDeleted() throws {
        let catalog = try NotebookCatalogDocument()
        let rule = NotebookTextRule(source: .script(source: "rule({ name: \"Bible\" })"))
        try catalog.setTextRule(rule)
        let other = try catalog.fork()
        try other.deleteTextRule(rule.id)

        let combined = try catalog.forkCombining(other, intoFolderNamed: "Other")
        XCTAssertEqual(try combined.textRuleMetadata().rules, [rule])
    }

    func testCombiningLeavesNotesBothHaveAsTheyWere() throws {
        let catalog = try NotebookCatalogDocument()
        let shared = try catalog.add(kind: .note, name: "Welcome.md")
        let other = try catalog.fork()
        let rule = NotebookTextRule(source: .script(source: "rule({ name: \"Times\" })"),
                                    appliesToAllNotes: false)
        try other.setTextRule(rule)
        try other.setTextRule(rule.id, note: shared, enabled: true)

        let combined = try catalog.forkCombining(other, intoFolderNamed: "Other")
        XCTAssertEqual(try combined.textRuleMetadata().rules, [rule])
        XCTAssertEqual(try combined.textRuleMetadata().noteIDs, [:])
    }
}
