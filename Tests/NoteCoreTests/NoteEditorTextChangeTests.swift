import Foundation
import XCTest

@testable import NoteCore

@MainActor
final class NoteEditorTextChangeTests: XCTestCase {
    func testUnicodeInsertionDeletionAndReplacementRoundTrip() async throws {
        for (source, target, replacement) in [
            ("café e\u{0301} 🪐 tail", "🪐", "moon 🌕"),
            ("café e\u{0301} 🪐 tail", "e\u{0301}", ""),
            ("First\nsecond", "\n", "\n\nNew paragraph\n"),
            ("café e\u{0301} 🪐 tail", "tail", "tail!"),
            ("", "", "🪐 e\u{0301}"),
        ] {
            let range = target.isEmpty ? NSRange(location: 0, length: 0)
                : (source as NSString).range(of: target)
            let expected = (source as NSString).replacingCharacters(in: range, with: replacement)
            let storage = NativeChangeStorage(try NoteDocument(text: source).snapshot())
            let session = NoteSession(storage: storage)
            await session.load()
            let revision = try XCTUnwrap(session.editorRevision)
            let updated = try session.commitEditorText(expected, basedOn: revision,
                change: NoteEditorTextChange(range: range, replacement: replacement))
            XCTAssertTrue(session.text.utf8.elementsEqual(expected.utf8))
            XCTAssertEqual(updated, session.editorRevision)
            try await session.flush()
            let saved = await storage.latest
            XCTAssertTrue(try NoteDocument(snapshot: saved).text.utf8.elementsEqual(expected.utf8))
        }
    }

    func testNoOpKeepsRevisionAndSavedState() async throws {
        let storage = NativeChangeStorage(try NoteDocument(text: "café 🪐").snapshot())
        let session = NoteSession(storage: storage)
        await session.load()
        let revision = try XCTUnwrap(session.editorRevision)
        let updated = try session.commitEditorText(session.text, basedOn: revision,
            change: NoteEditorTextChange(range: NSRange(location: 5, length: 2),
                                         replacement: "🪐"))
        XCTAssertEqual(updated, revision)
        XCTAssertEqual(session.editorRevision, revision)
        XCTAssertEqual(session.status, .saved)
    }

    func testInvalidOrIncorrectHintsFallBackToWholeText() async throws {
        let source = "A 🪐 e\u{0301}"
        for change in [
            NoteEditorTextChange(range: NSRange(location: 3, length: 0), replacement: "x"),
            NoteEditorTextChange(range: NSRange(location: 99, length: 0), replacement: "x"),
            NoteEditorTextChange(range: NSRange(location: NSNotFound, length: 0), replacement: "x"),
            NoteEditorTextChange(range: NSRange(location: 0, length: Int.max), replacement: "x"),
            NoteEditorTextChange(range: NSRange(location: 0, length: 1), replacement: "wrong"),
        ] {
            let storage = NativeChangeStorage(try NoteDocument(text: source).snapshot())
            let session = NoteSession(storage: storage)
            await session.load()
            let expected = source + "!"
            try session.commitEditorText(expected, basedOn: XCTUnwrap(session.editorRevision),
                                         change: change)
            XCTAssertTrue(session.text.utf8.elementsEqual(expected.utf8))
            try await session.flush()
            let saved = await storage.latest
            XCTAssertTrue(try NoteDocument(snapshot: saved).text.utf8.elementsEqual(expected.utf8))
        }
    }

    func testStaleDeltaPreservesRemoteEdits() async throws {
        let document = try NoteDocument(text: "hello world")
        let storage = NativeChangeStorage(document.snapshot())
        let session = NoteSession(storage: storage)
        await session.load()
        let displayed = try XCTUnwrap(session.editorRevision)
        let remote = try document.fork()
        try remote.replaceUTF16(range: NSRange(location: 0, length: 0), with: "remote ")
        try session.mergeRemote(remote.snapshot())
        try session.commitEditorText("hello world!", basedOn: displayed,
            change: NoteEditorTextChange(range: NSRange(location: 11, length: 0),
                                         replacement: "!"))
        XCTAssertEqual(session.text, "remote hello world!")
        try await session.flush()
        let saved = await storage.latest
        XCTAssertEqual(try NoteDocument(snapshot: saved).text, session.text)
        try remote.merge(NoteDocument(snapshot: saved))
        XCTAssertEqual(try remote.text, session.text)
    }

    func testForeignIdentityCannotUseValidDelta() async throws {
        let snapshot = try NoteDocument(text: "original").snapshot()
        let a = NoteSession(storage: NativeChangeStorage(snapshot))
        let b = NoteSession(storage: NativeChangeStorage(snapshot))
        await a.load()
        await b.load()
        XCTAssertThrowsError(try a.commitEditorText("original!",
            basedOn: XCTUnwrap(b.editorRevision),
            change: NoteEditorTextChange(range: NSRange(location: 8, length: 0),
                                         replacement: "!")))
        XCTAssertEqual(a.text, "original")
        XCTAssertEqual(a.status, .saved)
    }

    func testNativeChangesRetainExistingHistoryAndSave() async throws {
        let document = try NoteDocument(text: "Fictional history.\n")
        for index in 0..<100 {
            try document.replaceUTF16(range: NSRange(location: 0, length: 0),
                                      with: "\(index) ")
        }
        let previousHistory = document.historyCount
        let storage = NativeChangeStorage(document.snapshot())
        let session = NoteSession(storage: storage)
        await session.load()
        var expected = session.text
        for _ in 0..<10 {
            let change = NoteEditorTextChange(
                range: NSRange(location: expected.utf16.count, length: 0), replacement: "x")
            expected += "x"
            try session.commitEditorText(expected, basedOn: XCTUnwrap(session.editorRevision),
                                         change: change)
        }
        try await session.flush()
        let saved = await storage.latest
        let restored = try NoteDocument(snapshot: saved)
        XCTAssertTrue(try restored.text.utf8.elementsEqual(expected.utf8))
        XCTAssertEqual(restored.historyCount, previousHistory + 10)
    }
}

private actor NativeChangeStorage: NoteStorage {
    var latest: NoteSnapshot
    init(_ snapshot: NoteSnapshot) { latest = snapshot }
    func load() -> NoteLoadResult { .current(latest) }
    func save(_ snapshot: NoteSnapshot) { latest = snapshot }
    func recover(_ recovery: NoteRecovery) -> NoteSnapshot { recovery.previous }
}
