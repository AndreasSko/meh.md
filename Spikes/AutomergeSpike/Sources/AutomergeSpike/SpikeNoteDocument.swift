import Automerge
import Foundation

public enum SpikeNoteError: Error, Equatable {
    case missingNoteID
    case missingSchemaVersion
    case missingText
    case unexpectedNoteID
    case unexpectedSchemaVersion
    case unsupportedSchemaVersion
    case unexpectedText
    case unexpectedTextEncoding
}

public final class SpikeNoteDocument: @unchecked Sendable {
    public static let testedAutomergeVersion = "0.7.2"
    public static let supportedSchemaVersion: UInt64 = 1

    private static let noteIDKey = "noteID"
    private static let schemaVersionKey = "schemaVersion"
    private static let textKey = "text"

    private let document: Document
    private let textObject: ObjId

    public let noteID: UUID

    public var actorID: String {
        document.actor.description
    }

    public var historyCount: Int {
        document.getHistory().count
    }

    public var historyHashes: Set<String> {
        Set(document.getHistory().map(\.debugDescription))
    }

    public var headsSnapshot: Set<String> {
        Set(document.heads().map(\.debugDescription))
    }

    public var text: String {
        get throws {
            try document.text(obj: textObject)
        }
    }

    public init(noteID: UUID = UUID(), text: String = "") throws {
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

    public convenience init(serializedData: Data) throws {
        let document = try Document(serializedData)
        try self.init(validating: document)
    }

    private init(validating document: Document) throws {
        guard case .unicodeScalar = document.textEncoding else {
            throw SpikeNoteError.unexpectedTextEncoding
        }

        guard let noteIDValue = try document.get(
            obj: .ROOT,
            key: Self.noteIDKey
        ) else {
            throw SpikeNoteError.missingNoteID
        }
        guard case let .Scalar(.String(noteIDString)) = noteIDValue,
              let noteID = UUID(uuidString: noteIDString) else {
            throw SpikeNoteError.unexpectedNoteID
        }

        guard let schemaVersionValue = try document.get(
            obj: .ROOT,
            key: Self.schemaVersionKey
        ) else {
            throw SpikeNoteError.missingSchemaVersion
        }
        guard case let .Scalar(.Uint(schemaVersion)) = schemaVersionValue else {
            throw SpikeNoteError.unexpectedSchemaVersion
        }
        guard schemaVersion == Self.supportedSchemaVersion else {
            throw SpikeNoteError.unsupportedSchemaVersion
        }

        guard let textValue = try document.get(
            obj: .ROOT,
            key: Self.textKey
        ) else {
            throw SpikeNoteError.missingText
        }
        guard case let .Object(textObject, .Text) = textValue else {
            throw SpikeNoteError.unexpectedText
        }

        self.document = document
        self.textObject = textObject
        self.noteID = noteID
    }

    public func replaceUTF16(
        range: NSRange,
        with replacement: String
    ) throws {
        let currentText = try text
        let scalarRange = try AutomergeTextIndex.unicodeScalarRange(
            forUTF16Range: range,
            in: currentText
        )

        try document.spliceText(
            obj: textObject,
            start: scalarRange.start,
            delete: Int64(scalarRange.length),
            value: replacement
        )
    }

    public func replaceAll(with newText: String) throws {
        try document.updateText(obj: textObject, value: newText)
    }

    public func serializedData() -> Data {
        document.save()
    }

    public func fork() throws -> SpikeNoteDocument {
        try SpikeNoteDocument(validating: document.fork())
    }

    public func merge(_ other: SpikeNoteDocument) throws {
        guard noteID == other.noteID else {
            throw SpikeNoteError.unexpectedNoteID
        }
        try document.merge(other: other.document)
    }
}
