import Foundation
import XCTest
import Automerge

@testable import NoteCore

@MainActor
final class NotebookTemplateTests: XCTestCase {
    private func replica() async throws -> NotebookReplica {
        let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        let replica = NotebookReplica(directory: directory)
        try await replica.createLocalNotebook()
        return replica
    }

    func testRecursiveFolderDiscoveryDeduplicatesAndRetainsIndependentRegistration() async throws {
        let replica = try await replica()
        let folder = try await replica.createFolder(name: "Templates")
        let nested = try await replica.createFolder(name: "Nested", parentID: folder)
        let note = try await replica.createNote(name: "Meeting.md", parentID: nested)
        let other = try await replica.createNote(name: "Other.md", parentID: folder)
        try await replica.setTemplateSource(folder, enabled: true)
        try await replica.setTemplateSource(note, enabled: true)
        XCTAssertEqual(Set(replica.templates.map(\.id)), [note, other])
        XCTAssertEqual(replica.templates.first { $0.id == note }?.path,
                       "Templates/Nested/Meeting.md")
        try await replica.setTemplateSource(folder, enabled: false)
        XCTAssertEqual(replica.templates.map(\.id), [note])
        XCTAssertTrue(replica.isTemplateSource(note))
        try await replica.setTemplateSource(note, enabled: false)
        XCTAssertTrue(replica.templates.isEmpty)
        XCTAssertTrue(replica.placements.contains { $0.item.id == note })
    }

    func testSettingsInheritPerFieldFromRegisteredAncestorsAndFollowIdentity() async throws {
        let replica = try await replica()
        let folder = try await replica.createFolder(name: "Templates")
        let nested = try await replica.createFolder(name: "Nested", parentID: folder)
        let target = try await replica.createFolder(name: "Meetings")
        let note = try await replica.createNote(name: "Meeting.md", parentID: nested)
        try await replica.setTemplateSource(folder, enabled: true)
        try await replica.setTemplateSource(nested, enabled: true)
        try await replica.setTemplateSettings(
            .init(destination: .folder(target), filenamePattern: "{{date}} Meeting"), for: folder)
        try await replica.setTemplateSettings(.init(filenamePattern: "{{template}}"), for: nested)
        let template = try XCTUnwrap(replica.templates.first)
        XCTAssertEqual(template.inheritedFromID, nested)
        XCTAssertEqual(template.effectiveSettings,
                       .init(destination: .folder(target), filenamePattern: "{{template}}"))
        try await replica.setTemplateSettings(.init(destination: .root), for: note)
        try await replica.rename(target, to: "Renamed Meetings")
        try await replica.rename(note, to: "Agenda.md")
        XCTAssertEqual(replica.templates.first?.effectiveSettings.destination, .root)
        let copied = try await replica.createNoteFromTemplate(note)
        XCTAssertNil(replica.placements.first { $0.item.id == copied }?.parentID)
        XCTAssertEqual(replica.placements.first { $0.item.id == copied }?.item.name, "Agenda.md")
        try await replica.setTemplateSettings(.init(), for: note)
        XCTAssertEqual(replica.templates.first?.effectiveSettings.destination, .folder(target))
        try await replica.move(note, to: nil)
        XCTAssertTrue(replica.templates.isEmpty)
    }

    func testCreationCopiesLatestUnflushedTextWithFreshHistoryAndLeavesSourceUnchanged() async throws {
        let replica = try await replica()
        let inbox = try await replica.createFolder(name: "Inbox")
        let destination = try await replica.createFolder(name: "Journal")
        try await replica.setDefaultNewNoteParentID(inbox)
        let id = try await replica.createNote(name: "Journal.md", text: "initial")
        let session = try await replica.openNote(id)
        try await replica.setTemplateSource(id, enabled: true)
        try await replica.setTemplateSettings(
            .init(destination: .folder(destination), filenamePattern: "{{template}}"), for: id)
        let body = "# {{date}}\n\n[[Meeting]]\n![Photo](../photo.png)\n- [ ] Next\n"
        try session.replaceAll(with: body)
        let source = try XCTUnwrap(session.currentSnapshot)
        let copied = try await replica.createNoteFromTemplate(id)
        XCTAssertNotEqual(id, copied)
        XCTAssertEqual(replica.placements.first { $0.item.id == copied }?.parentID, destination)
        let copySession = try await replica.openNote(copied)
        XCTAssertEqual(copySession.text, body)
        XCTAssertEqual(session.currentSnapshot, source)
        let copyDocument = try NoteDocument(snapshot: XCTUnwrap(copySession.currentSnapshot))
        XCTAssertTrue(source.heads.isDisjoint(with: copyDocument.heads))
        XCTAssertFalse(replica.isTemplateSource(copied))
        try copySession.replaceAll(with: "independent")
        XCTAssertEqual(session.text, body)
        let usual = try await replica.createNoteFromTemplate(id, destination: .inherit)
        XCTAssertEqual(replica.placements.first { $0.item.id == usual }?.parentID, inbox)
    }

    func testUnavailableConfiguredDestinationFailsUntilRestoredOrOverridden() async throws {
        let replica = try await replica()
        let folder = try await replica.createFolder(name: "Destination")
        let note = try await replica.createNote(name: "Source.md", text: "body")
        try await replica.setTemplateSource(note, enabled: true)
        try await replica.setTemplateSettings(.init(destination: .folder(folder)), for: note)
        try await replica.setTrashed(folder, true)
        let count = replica.placements.count
        do {
            _ = try await replica.createNoteFromTemplate(note)
            XCTFail("A missing destination must not silently change the filing location")
        } catch { XCTAssertEqual(error as? NotebookTemplateError, .destinationUnavailable) }
        XCTAssertEqual(replica.placements.count, count)
        let rootCopy = try await replica.createNoteFromTemplate(note, destination: .root)
        XCTAssertNil(replica.placements.first { $0.item.id == rootCopy }?.parentID)
        try await replica.setTrashed(folder, false)
        let restored = try await replica.createNoteFromTemplate(note)
        XCTAssertEqual(replica.placements.first { $0.item.id == restored }?.parentID, folder)
    }

    func testClosedSourcesAndMetadataSurviveReloadAndTrashExcludesDescendants() async throws {
        let first = try await replica()
        let folder = try await first.createFolder(name: "Templates")
        let note = try await first.createNote(name: "Source.md", text: "stored body", parentID: folder)
        try await first.setTemplateSource(folder, enabled: true)
        try await first.setTemplateSettings(.init(filenamePattern: "Saved {{template}}"), for: note)
        let loaded = NotebookReplica(directory: first.directory)
        try await loaded.load()
        XCTAssertEqual(loaded.templates.count, 1)
        let copied = try await loaded.createNoteFromTemplate(note)
        let session = try await loaded.openNote(copied)
        XCTAssertEqual(session.text, "stored body")
        XCTAssertEqual(loaded.placements.first { $0.item.id == copied }?.item.name, "Saved Source.md")
        try await loaded.setTrashed(folder, true)
        XCTAssertTrue(loaded.templates.isEmpty)
        try await loaded.setTrashed(folder, false)
        XCTAssertEqual(loaded.templates.map(\.id), [note])
    }

    func testCollisionUsesCaseInsensitiveNumberedNamesWithoutOverwriting() async throws {
        let replica = try await replica()
        let note = try await replica.createNote(name: "Meeting.md", text: "source")
        try await replica.setTemplateSource(note, enabled: true)
        _ = try await replica.createNote(name: "AGENDA.MD", text: "existing")
        _ = try await replica.createNote(name: "Agenda (2).md", text: "existing two")
        let copied = try await replica.createNoteFromTemplate(note, name: "Agenda")
        XCTAssertEqual(replica.placements.first { $0.item.id == copied }?.item.name, "Agenda (3).md")
        XCTAssertEqual(replica.placements.filter { !$0.isInTrash }.count, 4)
    }

    func testIndependentOfflineMetadataFieldsMergeAndOldCatalogLoads() throws {
        let initial = try NotebookCatalogDocument()
        let note = try initial.add(kind: .note, name: "Source.md")
        XCTAssertTrue(try initial.templateMetadata().sources.isEmpty)
        let first = try initial.fork()
        let second = try initial.fork()
        try first.setTemplateSource(note, enabled: true)
        try first.setTemplateSettings(.init(destination: .root), for: note)
        try second.setTemplateSettings(.init(filenamePattern: "{{template}}"), for: note)
        try first.merge(second)
        let reloaded = try NotebookCatalogDocument(snapshot: first.snapshot())
        let metadata = try reloaded.templateMetadata()
        XCTAssertEqual(metadata.sources, [note])
        XCTAssertEqual(metadata.settings[note], .init(destination: .root, filenamePattern: "{{template}}"))
    }

    func testConflictingRegistrationRegistersHaveSameProjectionOnBothReplicas() throws {
        let initial = try NotebookCatalogDocument()
        let note = try initial.add(kind: .note, name: "Source.md")
        let first = try initial.fork()
        let second = try initial.fork()
        try first.setTemplateSource(note, enabled: true)
        try second.setTemplateSource(note, enabled: false)
        let firstSnapshot = first.snapshot()
        try first.merge(second)
        try second.merge(NotebookCatalogDocument(snapshot: firstSnapshot))
        XCTAssertEqual(try first.templateMetadata().sources, try second.templateMetadata().sources)
    }

    func testFilenameVariablesAreDeterministicAndUnsafePatternsRejected() throws {
        let date = Date(timeIntervalSince1970: 0)
        let zone = try XCTUnwrap(TimeZone(secondsFromGMT: 0))
        XCTAssertEqual(try NotebookTemplateFilename.preview(
            pattern: "{{date}} {{time}} {{template}}", templateName: "Meeting.markdown",
            date: date, timeZone: zone), "1970-01-01 00-00 Meeting.md")
        XCTAssertEqual(try NotebookTemplateFilename.preview(
            pattern: nil, templateName: "Meeting.md", date: date, timeZone: zone), "1970-01-01.md")
        for pattern in ["../note", "bad\\name", "{{title}}", "{{date", "}}", "", "\nname",
                        String(repeating: "a", count: 253)] {
            XCTAssertThrowsError(try NotebookTemplateFilename.preview(
                pattern: pattern, templateName: "Meeting.md"), pattern)
        }
    }

    func testReceivedOfflineCatalogRulesRefreshProjectionAndCreateCorrectly() async throws {
        let local = try await replica()
        let folder = try await local.createFolder(name: "Templates")
        let target = try await local.createFolder(name: "Destination")
        let note = try await local.createNote(name: "Meeting.md", text: "synced body", parentID: folder)
        let remoteDirectory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        addTeardownBlock { try? FileManager.default.removeItem(at: remoteDirectory) }
        let remote = NotebookReplica(directory: remoteDirectory)
        try await remote.acceptSeed(SyncRecord(catalog: XCTUnwrap(local.catalogSnapshot)))
        for record in try await local.records() where record.kind == .note {
            try await remote.apply(record)
        }
        XCTAssertTrue(remote.templates.isEmpty)
        try await local.setTemplateSource(folder, enabled: true)
        try await local.setTemplateSettings(
            .init(destination: .folder(target), filenamePattern: "Local {{template}}"), for: folder)
        try await remote.setTemplateSettings(.init(filenamePattern: "Remote {{template}}"), for: note)
        let outgoingLocal = SyncRecord(catalog: try XCTUnwrap(local.catalogSnapshot))
        let outgoingRemote = SyncRecord(catalog: try XCTUnwrap(remote.catalogSnapshot))
        try await local.apply(outgoingRemote)
        try await remote.apply(outgoingLocal)
        XCTAssertEqual(local.templates, remote.templates)
        XCTAssertEqual(remote.templateSources.map(\.id), [folder])
        XCTAssertEqual(remote.templates.first?.effectiveSettings,
                       .init(destination: .folder(target), filenamePattern: "Remote {{template}}"))
        let copy = try await remote.createNoteFromTemplate(note)
        XCTAssertEqual(remote.placements.first { $0.item.id == copy }?.parentID, target)
        XCTAssertEqual(remote.placements.first { $0.item.id == copy }?.item.name, "Remote Meeting.md")
        let copiedSession = try await remote.openNote(copy)
        XCTAssertEqual(copiedSession.text, "synced body")
    }

    func testExplicitFilenameRemainsLiteral() async throws {
        let replica = try await replica()
        let note = try await replica.createNote(name: "Meeting.md")
        try await replica.setTemplateSource(note, enabled: true)
        let copy = try await replica.createNoteFromTemplate(note, name: "Literal {{date}}")
        XCTAssertEqual(replica.placements.first { $0.item.id == copy }?.item.name, "Literal {{date}}.md")
    }

    func testCatalogValidationUsesSourceIndependentFilenameSyntax() throws {
        let catalog = try NotebookCatalogDocument()
        let note = try catalog.add(kind: .note, name: "a.md")
        let pattern = String(repeating: "a", count: 248) + "{{template}}"
        try catalog.setTemplateSource(note, enabled: true)
        try catalog.setTemplateSettings(.init(filenamePattern: pattern), for: note)
        try catalog.rename(note, to: "A longer source name.md")
        let loaded = try NotebookCatalogDocument(snapshot: catalog.snapshot())
        XCTAssertEqual(try loaded.templateMetadata().settings[note]?.filenamePattern, pattern)
        XCTAssertThrowsError(try NotebookTemplateFilename.preview(
            pattern: pattern, templateName: "A longer source name.md"))
    }

    func testDeletionLedgerImmediatelyRemovesTemplatesWhenCatalogSaveFails() async throws {
        enum Failure: Error { case injected }
        for deletingAncestor in [false, true] {
            let replica = try await replica()
            let folder = try await replica.createFolder(name: "Templates")
            let note = try await replica.createNote(name: "Meeting.md", text: "body", parentID: folder)
            let source = deletingAncestor ? folder : note
            try await replica.setTemplateSource(source, enabled: true)
            XCTAssertEqual(replica.templates.map(\.id), [note])
            let catalogBeforeDeletion = replica.catalogSnapshot
            replica.catalogWriteSuspension = { throw Failure.injected }
            do {
                try await replica.rememberDeletions([source])
                XCTFail("Expected catalog save failure after the durable deletion ledger")
            } catch is Failure {}
            replica.catalogWriteSuspension = nil
            XCTAssertEqual(replica.catalogSnapshot, catalogBeforeDeletion)
            XCTAssertTrue(replica.templateSources.isEmpty)
            XCTAssertTrue(replica.templates.isEmpty)
            let count = replica.placements.count
            do {
                _ = try await replica.createNoteFromTemplate(note)
                XCTFail("Ledger-deleted sources and inherited templates cannot be copied")
            } catch {
                if deletingAncestor {
                    XCTAssertEqual(error as? NotebookTemplateError, .sourceUnavailable)
                } else {
                    XCTAssertEqual(error as? NotebookReplicaError, .permanentlyDeleted(note))
                }
            }
            XCTAssertEqual(replica.placements.count, count)
            XCTAssertTrue(FileManager.default.fileExists(atPath: replica.noteStorage(note).currentURL.path))
        }
    }

    func testCatalogRejectsMalformedTemplateRegisters() throws {
        let catalog = try NotebookCatalogDocument()
        let raw = try Document(catalog.snapshot().data)
        try raw.put(obj: .ROOT, key: "template.destination.invalid-id", value: .String("root"))
        XCTAssertThrowsError(try NotebookCatalogDocument(serializedData: raw.save()))
    }
}
