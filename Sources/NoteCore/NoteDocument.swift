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
    case invalidCreatedAt
    case invalidModifiedAt
    case unexpectedTextEncoding
    case noteIdentityMismatch
}

final class NoteDocument {
    static let supportedSchemaVersion: UInt64 = 1

    private static let noteIDKey = "noteID"
    private static let schemaVersionKey = "schemaVersion"
    private static let textKey = "text"
    private static let createdAtKey = "createdAt"
    private static let modifiedAtKey = "modifiedAt"

    private let document: Document
    private let textObject: ObjId

    let noteID: UUID

    var text: String {
        get throws {
            try document.text(obj: textObject)
        }
    }

    var metadata: NoteMetadata {
        get throws {
            NoteMetadata(
                createdAt: try date(
                    forKey: Self.createdAtKey,
                    invalid: .invalidCreatedAt,
                    reduce: min
                ),
                modifiedAt: try date(
                    forKey: Self.modifiedAtKey,
                    invalid: .invalidModifiedAt,
                    reduce: max
                )
            )
        }
    }

    var heads: Set<String> {
        Set(document.heads().map(\.debugDescription))
    }

    /// An editor revision contains only the current change heads, not a
    /// serialized document or its full history.
    var editorHeads: Data { document.heads().raw() }

    func applyEditorText(_ replacement: String, basedOn revision: Data) throws {
        guard let heads = revision.heads(), !heads.isEmpty else {
            throw SyncError.invalidRecord
        }
        if heads == document.heads() {
            try replaceAll(with: replacement)
        } else {
            // forkAt establishes ancestry using this document's own history.
            // Only the stale-editor path needs a fork; ordinary typing edits
            // the live document directly without loading or merging a copy.
            let branch = try NoteDocument(validating: document.forkAt(heads: heads))
            try branch.replaceAll(with: replacement)
            try document.merge(other: branch.document)
        }
    }

    var historyHeads: Set<String> {
        Set(document.getHistory().map(\.debugDescription))
    }

    var historyCount: Int {
        document.getHistory().count
    }

    init(
        noteID: UUID = UUID(),
        text: String = "",
        metadata: NoteMetadata = .now()
    ) throws {
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
        if let createdAt = metadata.createdAt {
            guard let createdAt = createdAt.noteTimestamp else {
                throw NoteDocumentError.invalidCreatedAt
            }
            try document.put(
                obj: .ROOT,
                key: Self.createdAtKey,
                value: .Timestamp(createdAt)
            )
        }
        if let modifiedAt = metadata.modifiedAt {
            guard let modifiedAt = modifiedAt.noteTimestamp else {
                throw NoteDocumentError.invalidModifiedAt
            }
            try document.put(
                obj: .ROOT,
                key: Self.modifiedAtKey,
                value: .Timestamp(modifiedAt)
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

        _ = try Self.date(
            in: document,
            forKey: Self.createdAtKey,
            invalid: .invalidCreatedAt,
            reduce: min
        )
        _ = try Self.date(
            in: document,
            forKey: Self.modifiedAtKey,
            invalid: .invalidModifiedAt,
            reduce: max
        )

        self.document = document
        self.textObject = textObject
        self.noteID = noteID
    }

    func replaceUTF16(
        range: NSRange,
        with replacement: String,
        at modificationDate: Date = Date()
    ) throws {
        let current = try text
        let scalarRange = try AutomergeTextIndex.unicodeScalarRange(
            forUTF16Range: range,
            in: current
        )
        let scalars = current.unicodeScalars
        let start = scalars.index(
            scalars.startIndex,
            offsetBy: Int(scalarRange.start)
        )
        let end = scalars.index(start, offsetBy: Int(scalarRange.length))
        let replaced = String(scalars[start ..< end])
        guard !replacement.utf8.elementsEqual(replaced.utf8) else { return }
        let modifiedAt = try nextModifiedAt(modificationDate)
        try document.spliceText(
            obj: textObject,
            start: scalarRange.start,
            delete: Int64(scalarRange.length),
            value: replacement
        )
        try setModifiedAt(modifiedAt)
    }

    func replaceAll(
        with text: String,
        at modificationDate: Date = Date()
    ) throws {
        guard !text.utf8.elementsEqual((try self.text).utf8) else { return }
        let modifiedAt = try nextModifiedAt(modificationDate)
        try document.updateText(obj: textObject, value: text)
        try setModifiedAt(modifiedAt)
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
        // ObjId's opaque bytes may contain replica-local lookup hints. Shared
        // change hashes, rather than byte equality of handles from different
        // Document instances, establish a common persisted history.
        guard !historyHeads.isDisjoint(with: other.historyHeads) else {
            throw SyncError.disconnectedHistory
        }
        try document.merge(other: other.document)
    }

    private func nextModifiedAt(_ proposed: Date) throws -> Date {
        guard let proposed = proposed.noteTimestamp else {
            throw NoteDocumentError.invalidModifiedAt
        }
        if let current = try metadata.modifiedAt {
            return max(current, proposed)
        }
        return proposed
    }

    private func setModifiedAt(_ date: Date) throws {
        try document.put(
            obj: .ROOT,
            key: Self.modifiedAtKey,
            value: .Timestamp(date)
        )
    }

    private func date(
        forKey key: String,
        invalid error: NoteDocumentError,
        reduce: (Date, Date) -> Date
    ) throws -> Date? {
        try Self.date(
            in: document,
            forKey: key,
            invalid: error,
            reduce: reduce
        )
    }

    private static func date(
        in document: Document,
        forKey key: String,
        invalid error: NoteDocumentError,
        reduce: (Date, Date) -> Date
    ) throws -> Date? {
        let values = try document.getAll(obj: .ROOT, key: key)
        guard !values.isEmpty else { return nil }
        var dates: [Date] = []
        for value in values {
            guard case let .Scalar(.Timestamp(date)) = value,
                  let normalized = date.noteTimestamp else {
                throw error
            }
            dates.append(normalized)
        }
        return dates.dropFirst().reduce(dates[0], reduce)
    }
}
