import Automerge
import Foundation

enum NoteDocumentError: Error, Equatable {
    case missingNoteID
    case invalidNoteID
    case missingSchemaVersion
    case invalidSchemaVersion
    case unsupportedSchemaVersion
    case missingText
    case invalidText
    case unexpectedTextEncoding
    case noteIdentityMismatch
}

final class NoteDocument {
    static let supportedSchemaVersion: UInt64 = 1

    private static let noteIDKey = "noteID"
    private static let schemaVersionKey = "schemaVersion"
    private static let textKey = "text"

    private let document: Document
    private let textObject: ObjId

    let noteID: UUID

    var text: String {
        get throws {
            try document.text(obj: textObject)
        }
    }

    var heads: Set<String> {
        Set(document.heads().map(\.debugDescription))
    }

    var historyHeads: Set<String> {
        Set(document.getHistory().map(\.debugDescription))
    }

    var historyCount: Int {
        document.getHistory().count
    }

    init(noteID: UUID = UUID(), text: String = "") throws {
        let document = Document(textEncoding: .unicodeScalar)
        try document.put(
            obj: .ROOT,
            key: Self.noteIDKey,
            value: .String(noteID.uuidString)
        )
        try document.put(
            obj: .ROOT,
            key: Self.schemaVersionKey,
            value: .Uint(Self.supportedSchemaVersion)
        )
        let textObject = try document.putObject(
            obj: .ROOT,
            key: Self.textKey,
            ty: .Text
        )
        if !text.isEmpty {
            try document.spliceText(
                obj: textObject,
                start: 0,
                delete: 0,
                value: text
            )
        }

        self.document = document
        self.textObject = textObject
        self.noteID = noteID
    }

    convenience init(snapshot: NoteSnapshot) throws {
        try self.init(serializedData: snapshot.data)
        guard noteID == snapshot.noteID, heads == snapshot.heads else {
            throw NoteDocumentError.noteIdentityMismatch
        }
    }

    convenience init(serializedData: Data) throws {
        let document = try Document(serializedData)
        try self.init(validating: document)
    }

    private init(validating document: Document) throws {
        guard case .unicodeScalar = document.textEncoding else {
            throw NoteDocumentError.unexpectedTextEncoding
        }

        guard let schemaValue = try document.get(
            obj: .ROOT,
            key: Self.schemaVersionKey
        ) else {
            throw NoteDocumentError.missingSchemaVersion
        }
        guard case let .Scalar(.Uint(schemaVersion)) = schemaValue else {
            throw NoteDocumentError.invalidSchemaVersion
        }
        guard schemaVersion == Self.supportedSchemaVersion else {
            throw NoteDocumentError.unsupportedSchemaVersion
        }

        guard let noteIDValue = try document.get(
            obj: .ROOT,
            key: Self.noteIDKey
        ) else {
            throw NoteDocumentError.missingNoteID
        }
        guard case let .Scalar(.String(noteIDString)) = noteIDValue,
              let noteID = UUID(uuidString: noteIDString) else {
            throw NoteDocumentError.invalidNoteID
        }

        guard let textValue = try document.get(
            obj: .ROOT,
            key: Self.textKey
        ) else {
            throw NoteDocumentError.missingText
        }
        guard case let .Object(textObject, .Text) = textValue else {
            throw NoteDocumentError.invalidText
        }

        self.document = document
        self.textObject = textObject
        self.noteID = noteID
    }

    func replaceUTF16(range: NSRange, with replacement: String) throws {
        let scalarRange = try AutomergeTextIndex.unicodeScalarRange(
            forUTF16Range: range,
            in: text
        )
        try document.spliceText(
            obj: textObject,
            start: scalarRange.start,
            delete: Int64(scalarRange.length),
            value: replacement
        )
    }

    func replaceAll(with text: String) throws {
        try document.updateText(obj: textObject, value: text)
    }

    func snapshot() -> NoteSnapshot {
        NoteSnapshot(
            data: document.save(),
            heads: heads,
            noteID: noteID
        )
    }

    func fork() throws -> NoteDocument {
        try NoteDocument(validating: document.fork())
    }

    func merge(_ other: NoteDocument) throws {
        guard noteID == other.noteID else {
            throw NoteDocumentError.noteIdentityMismatch
        }
        try document.merge(other: other.document)
    }
}
