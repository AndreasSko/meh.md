import Foundation
import XCTest

@testable import NoteCore

@MainActor
final class NotebookIntegrationUpdatesTests: XCTestCase {
    private var roots: [URL] = []
    private let iPhone = NotebookIntegrationDevice(id: UUID(), kind: "iPhone")
    private let iPad = NotebookIntegrationDevice(id: UUID(), kind: "iPad")
    private let date = Date(timeIntervalSince1970: 1_800_000_000)

    override func tearDown() async throws {
        for root in roots { try? FileManager.default.removeItem(at: root) }
        roots = []
    }

    func testTheFirstSyncCreatesFoldersAndNotes() async throws {
        let (replica, updates) = try await connected()
        let report = try await updates.apply([book("1", "Atomic Habits", ["> one", "> two"])], at: date)

        XCTAssertEqual(report.created.count, 1)
        let note = try XCTUnwrap(placement(replica, report.created[0]))
        XCTAssertEqual(note.item.name, "Atomic Habits.md")
        XCTAssertEqual(placement(replica, note.item.parentID!)?.item.name, "Books")
        let created = try await text(replica, report.created[0])
        XCTAssertEqual(created, "# Atomic Habits\n\n> one\n\n> two")
        XCTAssertNotNil(try updates.status()?.lastSync)

        let again = try await updates.apply([book("1", "Atomic Habits", ["> one", "> two"])], at: date)
        XCTAssertEqual(again, NotebookIntegrationUpdates.Report())
    }

    func testAMovedAndRenamedNoteKeepsUpdatingAndKeepsItsPlace() async throws {
        let (replica, updates) = try await connected()
        let id = try await updates.apply([book("1", "Old", ["> one"])], at: date).created[0]
        let mine = try await replica.createFolder(name: "Mine")
        try await replica.move(id, to: mine)
        try await replica.rename(id, to: "My name.md")

        let report = try await updates.apply([book("1", "New title", ["> one", "> two"])], at: date)
        XCTAssertEqual(report.updated, [id])
        XCTAssertEqual(placement(replica, id)?.item.name, "My name.md")
        XCTAssertEqual(placement(replica, id)?.item.parentID, mine)
        let updated = try await text(replica, id)
        XCTAssertTrue(updated.hasSuffix("> one\n\n> two"))
    }

    func testANoteTheServiceRenamesFollowsWhenThePersonDidNot() async throws {
        let (replica, updates) = try await connected()
        let id = try await updates.apply([book("1", "Old", ["> one"])], at: date).created[0]
        _ = try await updates.apply([book("1", "New", ["> one"], category: "articles")], at: date)
        XCTAssertEqual(placement(replica, id)?.item.name, "New.md")
        XCTAssertEqual(placement(replica, placement(replica, id)!.item.parentID!)?.item.name, "Articles")
    }

    func testAnOpenNoteReceivesTheUpdate() async throws {
        let (replica, updates) = try await connected()
        let id = try await updates.apply([book("1", "Book", ["> one"])], at: date).created[0]
        let session = try await replica.openNote(id)
        try session.replaceText(in: NSRange(location: 0, length: 0), with: "Mine\n\n")

        _ = try await updates.apply([book("1", "Book", ["> one changed"])], at: date)
        XCTAssertEqual(session.text, "Mine\n\n# Book\n\n> one changed")
    }

    func testADeletedNoteStaysDeletedUnlessBroughtBack() async throws {
        let (replica, updates) = try await connected()
        let id = try await updates.apply([book("1", "Book", ["> one"])], at: date).created[0]
        try await replica.setTrashed(id, true)
        let whileTrashed = try await updates.apply([book("1", "Book", ["> two"])], at: date)
        XCTAssertEqual(whileTrashed.created, [])
        XCTAssertEqual(whileTrashed.updated, [])
        try await replica.permanentlyDelete(try replica.deletionSelection())

        let afterDeletion = try await updates.apply([book("1", "Book", ["> three"])], at: date)
        XCTAssertEqual(afterDeletion.created, [])
        let back = try await updates.apply(
            [book("1", "Book", ["> three"])], bringingBack: ["1"], at: date)
        XCTAssertEqual(back.created.count, 1)
        XCTAssertNotEqual(back.created[0], id)
    }

    func testAnItemRemovedInTheServiceKeepsItsNote() async throws {
        let (replica, updates) = try await connected()
        let id = try await updates.apply([book("1", "Book", ["> one"])], at: date).created[0]
        _ = try await updates.apply([book("1", "Book", ["> gone"], removed: true)], at: date)
        let kept = try await text(replica, id)
        XCTAssertEqual(kept, "# Book\n\n> one")
        XCTAssertEqual(try updates.record(forNote: id)?.record.state, NotebookIntegrationRecord.removed)
    }

    func testADeletedCategoryFolderIsCreatedAgain() async throws {
        let (replica, updates) = try await connected()
        let id = try await updates.apply([book("1", "Book", ["> one"])], at: date).created[0]
        let folder = try XCTUnwrap(placement(replica, id)?.item.parentID)
        try await replica.setTrashed(folder, true)
        let report = try await updates.apply([book("2", "Other", ["> two"])], at: date)
        let newFolder = try XCTUnwrap(placement(replica, report.created[0])?.item.parentID)
        XCTAssertNotEqual(newFolder, folder)
        XCTAssertEqual(placement(replica, newFolder)?.item.name, "Books")
    }

    func testOnlyTheSyncingDeviceSyncsUntilThePersonSwitches() async throws {
        let (left, right, leftUpdates, rightUpdates, sync) = try await twoDevices()
        _ = try await leftUpdates.apply([book("1", "Book", ["> one"])], at: date)
        await sync()
        do {
            _ = try await rightUpdates.apply([book("1", "Book", ["> two"])], at: date)
            XCTFail("The iPad synced without being the syncing device")
        } catch let error as NotebookIntegrationError {
            XCTAssertEqual(error, .notSyncingDevice)
        }
        try await rightUpdates.claimSyncingDevice()
        await sync()
        XCTAssertEqual(try rightUpdates.status()?.syncingDevice, iPad)
        await assertThrows { _ = try await leftUpdates.apply([], at: self.date) }
        _ = (left, right)
    }

    func testAnOlderVersionPausesAndSaysWhichDeviceNeedsAnUpdate() async throws {
        let (replica, newer) = try await connected(rendererVersion: 2)
        let older = NotebookIntegrationUpdates(
            replica: replica, connection: newer.connection, device: iPhone, rendererVersion: 1)
        do {
            _ = try await older.apply([book("1", "Book", ["> one"])], at: date)
            XCTFail("An older renderer synced")
        } catch let error as NotebookIntegrationError {
            XCTAssertEqual(error, .updateRequired)
        }
        XCTAssertEqual(try newer.status()?.deviceNeedingUpdate, iPhone)
    }

    func testANewerRendererAsksForAFullRefetchOnce() async throws {
        let (replica, old) = try await connected(rendererVersion: 1)
        _ = try await old.apply([book("1", "Book", ["> one"])], at: date)
        let newer = NotebookIntegrationUpdates(
            replica: replica, connection: old.connection, device: iPhone, rendererVersion: 2)
        let first = try await newer.apply([], at: date)
        let second = try await newer.apply([], at: date)
        XCTAssertTrue(first.rendererUpgraded)
        XCTAssertFalse(second.rendererUpgraded)
    }

    func testANoteWhoseTextHasNotArrivedIsPending() async throws {
        let (replica, updates) = try await connected()
        let id = try await updates.apply([book("1", "Book", ["> one"])], at: date).created[0]
        try FileManager.default.removeItem(
            at: replica.directory.appending(path: "notes/\(id.uuidString)"))
        let report = try await updates.apply([book("1", "Book", ["> two"])], at: date)
        XCTAssertEqual(report.pending, ["1"])
        XCTAssertEqual(report.updated, [])
    }

    func testDisconnectingStopsUpdatesAndKeepsNotes() async throws {
        let (replica, updates) = try await connected()
        let id = try await updates.apply([book("1", "Book", ["> one"])], at: date).created[0]
        try await updates.disconnect()
        await assertThrows { _ = try await updates.apply([], at: self.date) }
        let kept = try await text(replica, id)
        XCTAssertEqual(kept, "# Book\n\n> one")
    }

    /// The old syncing device was offline when the person switched, so
    /// both import the same new book and update the same highlight.
    func testAnOverlapDuringASwitchLeavesOneLinkedNoteAndOneCopy() async throws {
        let (left, right, leftUpdates, rightUpdates, sync) = try await twoDevices()
        let existing = try await leftUpdates.apply([book("1", "Old", ["> one"])], at: date).created[0]
        await sync()
        try await rightUpdates.claimSyncingDevice()
        // The iPhone has not seen the switch yet.
        let fromLeft = try await leftUpdates.apply(
            [book("1", "Old", ["> one left"]), book("2", "New", ["> a"])], at: date)
        let fromRight = try await rightUpdates.apply(
            [book("1", "Old", ["> one right"]), book("2", "New", ["> a"])], at: date)
        await sync()

        let winner = [fromLeft.created[0], fromRight.created[0]]
            .min { $0.uuidString < $1.uuidString }!
        let loser = winner == fromLeft.created[0] ? fromRight.created[0] : fromLeft.created[0]
        _ = try await rightUpdates.apply(
            [book("1", "Old", ["> one right"]), book("2", "New", ["> a"])], at: date)
        await sync()
        for replica in [left, right] {
            let shown = try await text(replica, existing)
            XCTAssertEqual(shown, "# Old\n\n> one right")
        }
        XCTAssertEqual(try rightUpdates.record(forNote: winner)?.isDuplicate, false)
        XCTAssertEqual(try rightUpdates.record(forNote: loser)?.isDuplicate, true)
        XCTAssertNotNil(placement(right, loser), "a duplicate is left for the person")
    }

    func testARenameDuringABatchIsKept() async throws {
        let (replica, updates) = try await connected()
        let id = try await updates.apply([book("1", "Old", ["> one"])], at: date).created[0]
        let mine = try await replica.createFolder(name: "Mine")
        updates.afterNotes = {
            try await replica.rename(id, to: "Mine.md")
            try await replica.move(id, to: mine)
        }
        _ = try await updates.apply([book("1", "New", ["> two"], category: "articles")], at: date)
        XCTAssertEqual(placement(replica, id)?.item.name, "Mine.md")
        XCTAssertEqual(placement(replica, id)?.item.parentID, mine)
    }

    func testOverlappingBatchesAndRepeatedItemsCreateOneNote() async throws {
        let (replica, updates) = try await connected()
        let item = book("1", "Book", ["> one"])
        let first = Task { try await updates.apply([item], at: self.date) }
        let second = Task { try await updates.apply([item, item], at: self.date) }
        let created = try await first.value.created + second.value.created
        XCTAssertEqual(created.count, 1)
        let notes = try XCTUnwrap(replica.integrationCatalog()).placements()
            .filter { $0.item.kind == .note && $0.item.name == "Book.md" }
        XCTAssertEqual(notes.count, 1)
    }

    /// The person typed inside a highlight on an offline device. The
    /// syncing device replaced that highlight and its catalog entry has
    /// settled before the typing arrives; Readwise does not change the book
    /// again, so the cleanup has to happen when the typing arrives.
    func testLateTypingInsideAReplacedHighlightIsRemovedWhenItArrives() async throws {
        let (left, right, leftUpdates, _, sync) = try await twoDevices()
        let id = try await leftUpdates.apply([book("1", "Book", ["> one", "> two"])], at: date).created[0]
        await sync()
        let session = try await right.openNote(id)
        let range = (session.text as NSString).range(of: "> one")
        try session.replaceText(in: NSRange(location: range.location + 3, length: 0), with: "LATE")
        try await session.flush()
        _ = try await leftUpdates.apply([book("1", "Book", ["> one changed", "> two"])], at: date)
        await sync()
        for replica in [left, right] {
            let shown = try await text(replica, id)
            XCTAssertEqual(shown, "# Book\n\n> one changed\n\n> two")
        }
    }

    func testAnItemWhoseNoteArrivedDuringABatchIsPending() async throws {
        let (replica, updates) = try await connected()
        updates.afterNotes = {
            let other = try await replica.createNote(name: "Arrived.md", text: "x")
            try await replica.integrationCatalogWrite { next in
                try next.setIntegrationRecord(NotebookIntegrationRecord(
                    item: "1", note: other, hash: nil, name: "Arrived.md", folder: nil,
                    state: NotebookIntegrationRecord.active), connection: updates.connection)
            }
        }
        let report = try await updates.apply([book("1", "Book", ["> one"])], at: date)
        XCTAssertEqual(report.created, [])
        XCTAssertEqual(report.pending, ["1"])
    }

    func testAnUpdateForANoteThatLostMeanwhileIsPending() async throws {
        let (replica, updates) = try await connected()
        let id = try await updates.apply([book("1", "Book", ["> one"])], at: date).created[0]
        let other = try await replica.createNote(name: "Other.md", text: "x")
        updates.afterNotes = {
            try await replica.integrationCatalogWrite { next in
                try next.setIntegrationRecord(NotebookIntegrationRecord(
                    item: "1", note: other, hash: nil, name: "Other.md", folder: nil,
                    state: NotebookIntegrationRecord.active, duplicates: [id]),
                    connection: updates.connection)
            }
        }
        let report = try await updates.apply([book("1", "Book", ["> two"])], at: date)
        XCTAssertEqual(report.pending, ["1"])
        XCTAssertEqual(try updates.record(forNote: other)?.record.duplicates, [id])
    }

    func testAStateChangeDuringABatchIsKept() async throws {
        let (replica, updates) = try await connected()
        let id = try await updates.apply([book("1", "Book", ["> one"])], at: date).created[0]
        updates.afterNotes = {
            try await replica.integrationCatalogWrite { next in
                try next.setIntegrationRecord(NotebookIntegrationRecord(
                    item: "1", note: id, hash: nil, name: "Book.md", folder: nil,
                    state: "archived"), connection: updates.connection)
            }
        }
        let report = try await updates.apply([book("1", "Book", ["> two"])], at: date)
        XCTAssertEqual(report.pending, ["1"])
        XCTAssertEqual(try updates.record(forNote: id)?.record.state, "archived")
    }

    func testADisconnectDuringABatchStopsItsWrites() async throws {
        let (replica, updates) = try await connected()
        updates.afterNotes = { try await updates.disconnect() }
        await assertThrows { _ = try await updates.apply([book("1", "Book", ["> one"])], at: self.date) }
        let notes = try XCTUnwrap(replica.integrationCatalog()).placements().filter { $0.item.kind == .note }
        XCTAssertEqual(notes.count, 0)
    }

    /// A late change from another device set a block back to an older
    /// version, and the service does not change the item again. A forced
    /// apply repairs it although the item's hash is unchanged.
    func testAForcedApplyRepairsABlockSetBack() async throws {
        let (replica, updates) = try await connected()
        let id = try await updates.apply([book("1", "Book", ["> one"])], at: date).created[0]
        _ = try await updates.apply([book("1", "Book", ["> one changed"])], at: date)
        let loaded = try await replica.integrationNote(id)
        let note = try XCTUnwrap(loaded)
        try note.applyIntegration(
            book("1", "Book", ["> one"]).blocks, link: .init(connection: updates.connection, item: "1"),
            at: date)
        try await replica.mergeNote(note.snapshot())
        let report = try await updates.apply([book("1", "Book", ["> one changed"])], at: date)
        XCTAssertEqual(report.updated, [])
        _ = try await updates.apply([book("1", "Book", ["> one changed"])], force: true, at: date)
        let shown = try await text(replica, id)
        XCTAssertTrue(shown.contains("> one changed"), shown)
    }

    func testAWriteWaitsForItsCheckInsideTheCatalogWriter() async throws {
        struct Stopped: Error {}
        let (replica, updates) = try await connected()
        let id = try await updates.apply([book("1", "Book", ["> one"])], at: date).created[0]
        let loaded = try await replica.integrationNote(id)
        let note = try XCTUnwrap(loaded)
        try note.applyIntegration(
            book("1", "Book", ["> two"]).blocks, link: .init(connection: updates.connection, item: "1"),
            at: date)
        // The disconnect holds the catalog writer while the merge arrives
        // and waits; only then is it released.
        var release: CheckedContinuation<Void, Never>?
        let entered = expectation(description: "disconnect is writing")
        replica.catalogWriteSuspension = {
            entered.fulfill()
            await withCheckedContinuation { release = $0 }
        }
        let disconnect = Task { try await updates.disconnect() }
        await fulfillment(of: [entered], timeout: 10)
        replica.catalogWriteSuspension = nil
        let merge = Task {
            try await replica.mergeNote(note.snapshot()) {
                if try replica.integrationCatalog()?.integrationSettings(updates.connection)["state"]?
                    .first != "active" { throw Stopped() }
            }
        }
        while replica.catalogWriteWaiterCount == 0 { await Task.yield() }
        release?.resume()
        try await disconnect.value
        do {
            try await merge.value
            XCTFail("Expected the check to see the disconnect")
        } catch is Stopped {}
        let shown = try await text(replica, id)
        XCTAssertFalse(shown.contains("> two"), shown)
    }

    func testABatchStopsBeforeWritingWhenAskedTo() async throws {
        struct Paused: Error {}
        let (replica, updates) = try await connected()
        updates.beforeWrite = { throw Paused() }
        await assertThrows { _ = try await updates.apply([book("1", "Book", ["> one"])], at: self.date) }
        let notes = try XCTUnwrap(replica.integrationCatalog()).placements().filter { $0.item.kind == .note }
        XCTAssertEqual(notes.count, 0)
    }

    func testAPauseDuringABatchStopsItBeforeTheCatalogWrite() async throws {
        struct Paused: Error {}
        let (replica, updates) = try await connected()
        var paused = false
        updates.beforeWrite = { if paused { throw Paused() } }
        updates.afterNotes = { paused = true }
        await assertThrows { _ = try await updates.apply([book("1", "Book", ["> one"])], at: self.date) }
        let notes = try XCTUnwrap(replica.integrationCatalog()).placements().filter { $0.item.kind == .note }
        XCTAssertEqual(notes.count, 0)
        updates.afterNotes = nil
        paused = false
        let report = try await updates.apply([book("1", "Book", ["> one"])], at: date)
        XCTAssertEqual(report.created.count, 1)
    }

    func testABatchCannotStartAnotherForTheSameNotebook() async throws {
        let (_, updates) = try await connected()
        updates.afterNotes = { _ = try await updates.apply([], at: self.date) }
        await assertThrows { _ = try await updates.apply([], at: self.date) }
    }

    /// An import during an exchange uploads the note before the catalog,
    /// so another device can receive a note's text before the catalog
    /// lists it.
    func testStaleCopiesAreRemovedWhenTheCatalogArrivesAfterTheText() async throws {
        let (left, right, leftUpdates, _, sync) = try await twoDevices()
        let id = try await leftUpdates.apply([book("1", "Book", ["> one"])], at: date).created[0]
        let loaded = try await left.integrationNote(id)
        let base = try XCTUnwrap(loaded)
        let link = NotebookIntegrationLink(connection: leftUpdates.connection, item: "1")
        let copies = [try base.fork(), try base.fork()]
        for (copy, text) in zip(copies, ["> one left", "> one right"]) {
            try copy.applyIntegration(
                [.init(key: "header", text: "# Book"), .init(key: "h0", text: text)],
                link: link, at: date)
        }
        try copies[0].merge(copies[1])
        try await left.mergeNote(copies[0].snapshot())

        let records = try await left.records()
        let note = try XCTUnwrap(records.first { $0.kind == .note && $0.snapshot.noteID == id })
        let catalog = try XCTUnwrap(records.first { $0.kind == .catalog })
        try await right.apply(note)
        try await right.apply(catalog)
        let shown = try await text(right, id)
        XCTAssertEqual(shown.components(separatedBy: "> one").count, 2, shown)
        _ = sync
    }

    func testCombiningNotebooksBringsTheConnectionAlong() throws {
        let connection = UUID()
        let other = try NotebookCatalogDocument()
        try other.setIntegrationSetting("service", "readwise", connection: connection)
        try other.setIntegrationRecord(NotebookIntegrationRecord(
            item: "1", note: UUID(), hash: nil, name: nil, folder: nil, state: "active"),
            connection: connection)
        let combined = try NotebookCatalogDocument().forkCombining(other, intoFolderNamed: "Other")
        XCTAssertEqual(try combined.integrationSettings(connection)["service"], ["readwise"])
        XCTAssertEqual(try combined.integrationRecords(connection).count, 1)
    }

    /// Two devices wrote at once in the other notebook. Combining keeps
    /// both notes for the item and the newer renderer.
    func testCombiningNotebooksKeepsConcurrentRecordsAndTheNewestRenderer() throws {
        let connection = UUID()
        let other = try NotebookCatalogDocument()
        try other.setIntegrationSetting("renderer", "1", connection: connection)
        let left = try other.fork(), right = try other.fork()
        let notes = [UUID(), UUID()].sorted { $0.uuidString < $1.uuidString }
        // The higher note ID tends to be the register's winner; the merge
        // rule still keeps the lower one.
        try left.setIntegrationRecord(NotebookIntegrationRecord(
            item: "1", note: notes[1], hash: nil, name: nil, folder: nil, state: "active"),
            connection: connection)
        try right.setIntegrationRecord(NotebookIntegrationRecord(
            item: "1", note: notes[0], hash: nil, name: nil, folder: nil, state: "active"),
            connection: connection)
        try left.setIntegrationSetting("renderer", "2", connection: connection)
        try right.setIntegrationSetting("renderer", "1", connection: connection)
        try left.merge(right)
        let combined = try NotebookCatalogDocument().forkCombining(left, intoFolderNamed: "Other")
        let record = try XCTUnwrap(combined.integrationRecords(connection)["1"]?.first)
        XCTAssertEqual(record.note, notes[0])
        XCTAssertEqual(record.duplicates, [notes[1]])
        XCTAssertEqual(try combined.integrationSettings(connection)["renderer"], ["2"])
    }

    func testRecordsFromANewerVersionAreKeptAndLeftAlone() throws {
        let catalog = try NotebookCatalogDocument()
        let connection = UUID()
        let note = UUID()
        try catalog.setIntegrationRecord(NotebookIntegrationRecord(
            item: "1", note: note, hash: nil, name: nil, folder: nil, state: "archived"),
            connection: connection)
        XCTAssertEqual(try catalog.integrationRecords(connection)["1"]?.first?.state, "archived")
        _ = try NotebookCatalogDocument(snapshot: catalog.snapshot())
    }

    // MARK: - Helpers

    private func assertThrows(
        _ body: () async throws -> Void, file: StaticString = #filePath, line: UInt = #line
    ) async {
        do {
            try await body()
            XCTFail("Expected an error", file: file, line: line)
        } catch {}
    }

    private func directory() -> URL {
        let root = FileManager.default.temporaryDirectory
            .appending(path: "integration-updates-\(UUID())")
        roots.append(root)
        return root
    }

    private func connected(
        rendererVersion: Int = 1
    ) async throws -> (NotebookReplica, NotebookIntegrationUpdates) {
        let replica = NotebookReplica(directory: directory())
        try await replica.createLocalNotebook()
        let connection = try await NotebookIntegrationUpdates.connect(
            replica: replica, service: "readwise", folderName: "Readwise",
            device: iPhone, rendererVersion: rendererVersion)
        return (replica, NotebookIntegrationUpdates(
            replica: replica, connection: connection, device: iPhone,
            rendererVersion: rendererVersion))
    }

    private func twoDevices() async throws -> (
        NotebookReplica, NotebookReplica, NotebookIntegrationUpdates, NotebookIntegrationUpdates,
        () async -> Void
    ) {
        let transport = InMemorySyncTransport(scope: "integration-\(UUID())")
        let left = NotebookReplica(directory: directory())
        let right = NotebookReplica(directory: directory())
        let leftSync = NotebookSyncCoordinator(replica: left, transport: transport)
        let rightSync = NotebookSyncCoordinator(replica: right, transport: transport)
        await leftSync.synchronize()
        await rightSync.synchronize()
        let connection = try await NotebookIntegrationUpdates.connect(
            replica: left, service: "readwise", folderName: "Readwise",
            device: iPhone, rendererVersion: 1)
        let sync: () async -> Void = {
            for _ in 0..<2 {
                await leftSync.synchronize()
                await rightSync.synchronize()
            }
        }
        await sync()
        return (left, right,
                NotebookIntegrationUpdates(replica: left, connection: connection,
                                           device: iPhone, rendererVersion: 1),
                NotebookIntegrationUpdates(replica: right, connection: connection,
                                           device: iPad, rendererVersion: 1),
                sync)
    }

    private func book(
        _ key: String, _ title: String, _ highlights: [String],
        category: String = "books", removed: Bool = false
    ) -> NotebookIntegrationItem {
        var blocks = [NotebookIntegrationBlock(key: "header", text: "# \(title)")]
        for (index, text) in highlights.enumerated() {
            blocks.append(NotebookIntegrationBlock(key: "h\(index)", text: text))
        }
        return NotebookIntegrationItem(
            key: key, name: NotebookIntegrationItem.noteName(for: title),
            folder: .init(key: category, name: category.capitalized),
            blocks: blocks, isRemoved: removed)
    }

    private func placement(_ replica: NotebookReplica, _ id: UUID) -> NotebookPlacement? {
        try? replica.integrationCatalog()?.placements().first { $0.item.id == id }
    }

    private func text(_ replica: NotebookReplica, _ id: UUID) async throws -> String {
        let note = try await replica.integrationNote(id)
        return try XCTUnwrap(note).text
    }
}
