import Foundation
import XCTest

@testable import NoteCore

@MainActor
final class NoteEditorCommitTests: XCTestCase {
    func testTypingKeepsSmallRevisionsAndSavesLatestText() async throws {
        let original = String(repeating: "A paragraph with **Markdown**.\n", count: 400)
        let document = try NoteDocument(text: original)
        for index in 0..<100 {
            try document.replaceUTF16(range: NSRange(location: 0, length: 0),
                                      with: "\(index) ")
        }
        let storage = EditorCommitStorage(document.snapshot())
        let session = NoteSession(storage: storage)
        await session.load()
        var revision = try XCTUnwrap(session.editorRevision)
        var text = session.text
        let start = ContinuousClock.now
        for _ in 0..<20 {
            text += "x"
            revision = try session.commitEditorText(text, basedOn: revision)
            XCTAssertLessThan(revision.count, 256)
        }
        let elapsed = start.duration(to: .now)
        if ProcessInfo.processInfo.environment["MEH_MEASURE_EDITOR_COMMITS"] == "1" {
            print("20 commits, 12KB+ text, 100 prior edits: \(elapsed)")
        }
        XCTAssertEqual(session.text, text)
        XCTAssertEqual(session.status, .saving)
        XCTAssertEqual(session.editorRevision, revision)
        try await session.flush()
        let saved = await storage.latest
        XCTAssertEqual(try NoteDocument(snapshot: saved).text, text)
        XCTAssertEqual(session.status, .saved)
    }

    func testStaleRevisionPreservesRemoteAndComposedText() async throws {
        let document = try NoteDocument(text: "hello world")
        let storage = EditorCommitStorage(document.snapshot())
        let session = NoteSession(storage: storage)
        await session.load()
        let displayed = try XCTUnwrap(session.editorRevision)
        let remote = try document.fork()
        try remote.replaceUTF16(range: NSRange(location: 0, length: 0),
                                with: "remote ")
        try session.mergeRemote(remote.snapshot())
        let revision = try session.commitEditorText(
            "hello world世界", basedOn: displayed
        )
        XCTAssertEqual(session.text, "remote hello world世界")
        XCTAssertEqual(revision, session.editorRevision)
        try await session.flush()
        try remote.merge(NoteDocument(snapshot: XCTUnwrap(session.currentSnapshot)))
        XCTAssertEqual(try remote.text, session.text)
    }

    func testStaleLocalRevisionPreservesInterveningEdit() async throws {
        let storage = EditorCommitStorage(try NoteDocument(text: "hello").snapshot())
        let session = NoteSession(storage: storage)
        await session.load()
        let displayed = try XCTUnwrap(session.editorRevision)
        try session.replaceText(in: NSRange(location: 0, length: 0), with: "prefix ")
        try session.commitEditorText("hello!", basedOn: displayed)
        XCTAssertEqual(session.text, "prefix hello!")
        try await session.flush()
    }

    func testForeignAndMalformedRevisionsDoNotChangeText() async throws {
        let snapshot = try NoteDocument(text: "original").snapshot()
        let a = NoteSession(storage: EditorCommitStorage(snapshot))
        let b = NoteSession(storage: EditorCommitStorage(snapshot))
        await a.load()
        await b.load()
        XCTAssertThrowsError(try a.commitEditorText(
            "wrong", basedOn: XCTUnwrap(b.editorRevision)
        ))
        XCTAssertThrowsError(try a.commitEditorText("wrong", basedOn: Data()))
        var malformed = try XCTUnwrap(a.editorRevision)
        malformed.removeLast()
        XCTAssertThrowsError(try a.commitEditorText("wrong", basedOn: malformed))
        XCTAssertEqual(a.text, "original")
        XCTAssertEqual(a.status, .saved)
    }

    func testSnapshotCacheChangesOnlyWhenRevisionChanges() async throws {
        let snapshot = try NoteDocument(text: "original").snapshot()
        let session = NoteSession(storage: EditorCommitStorage(snapshot))
        await session.load()
        let initial = try XCTUnwrap(session.currentSnapshot)
        let revision = try XCTUnwrap(session.editorRevision)
        XCTAssertEqual(try session.commitEditorText("original", basedOn: revision), revision)
        XCTAssertEqual(session.currentSnapshot, initial)
        try session.commitEditorText("changed", basedOn: revision)
        let changed = try XCTUnwrap(session.currentSnapshot)
        XCTAssertNotEqual(changed.heads, initial.heads)
        XCTAssertEqual(try NoteDocument(snapshot: changed).text, "changed")
        try await session.flush()
        XCTAssertEqual(session.persistedSnapshot, changed)
    }
}

private actor EditorCommitStorage: NoteStorage {
    var latest: NoteSnapshot
    init(_ snapshot: NoteSnapshot) { latest = snapshot }
    func load() -> NoteLoadResult { .current(latest) }
    func save(_ snapshot: NoteSnapshot) { latest = snapshot }
    func recover(_ recovery: NoteRecovery) -> NoteSnapshot { recovery.previous }
}
