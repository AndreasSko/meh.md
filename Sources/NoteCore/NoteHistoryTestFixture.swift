#if DEBUG
import Automerge
import Foundation

/// Fictional data for isolated preview and simulator performance checks.
public enum NoteHistoryTestFixture {
    public static func makeSnapshot(
        lines: Int = 1_800, edits: Int = 600
    ) throws -> NoteSnapshot {
        let bytes = try makeBytes(lines: lines, edits: edits)
        return try NoteDocument(serializedData: bytes).snapshot()
    }

    public static func seed(directory: URL) async throws {
        let catalogStorage = NotebookCatalogStorage(directory: directory)
        guard !FileManager.default.fileExists(atPath: catalogStorage.currentURL.path) else {
            return
        }
        let snapshot = try makeSnapshot()
        let catalog = try NotebookCatalogDocument(notebookID:
            UUID(uuidString: "22222222-3333-4444-8555-666666666666")!)
        try catalog.add(id: snapshot.noteID, kind: .note, name: "Aurora Observatory")
        try await NoteFileStorage(directory: directory.appending(path:
            "notes/\(snapshot.noteID.uuidString)")).save(snapshot)
        try await catalogStorage.save(catalog.snapshot())
    }

    static func makeBytes(lines: Int, edits: Int) throws -> Data {
        let identity = UUID(uuidString: "11111111-2222-4333-8444-555555555555")!
        let raw = Document(textEncoding: .unicodeScalar)
        raw.actor = ActorId(uuid: identity)
        try raw.put(obj: .ROOT, key: "noteID", value: .String(identity.uuidString))
        try raw.put(obj: .ROOT, key: "schemaVersion", value: .Uint(1))
        let body = try raw.putObject(obj: .ROOT, key: "text", ty: .Text)
        let text = "# Fictional Observatory\n" + String(repeating:
            "Café e\u{301} 👋🏽 observations from a fictional mountain station.\n",
            count: lines)
        try raw.spliceText(obj: body, start: 0, delete: 0, value: text)
        let start = Date(timeIntervalSince1970: 1_000)
        try raw.put(obj: .ROOT, key: "createdAt", value: .Timestamp(start))
        try raw.put(obj: .ROOT, key: "modifiedAt", value: .Timestamp(start))
        raw.commitWith(timestamp: start)
        var position = UInt64(text.unicodeScalars.count)
        for edit in 0..<edits {
            let date = start.addingTimeInterval(Double(edit + 1))
            try raw.spliceText(obj: body, start: position, delete: 0,
                value: edit % 19 == 0 ? "\n" : "x")
            try raw.put(obj: .ROOT, key: "modifiedAt", value: .Timestamp(date))
            raw.commitWith(timestamp: date)
            position += 1
        }
        return raw.save()
    }
}
#endif
