import XCTest

@testable import NoteCore

final class NotebookNameTests: XCTestCase {
    func testAcceptsAndPreservesValidNames() throws {
        let names = [
            "Personal Notes",
            "  Padded  ",
            "Résumé ✍️",
            "👨‍👩‍👧‍👦 Family",
            "می‌نویسم",
            "notes.md",
            "name:with?punctuation",
        ]

        for name in names {
            XCTAssertNoThrow(try NotebookName.validate(name))
        }
    }

    func testRejectsEmptyWhitespaceAndReservedNames() {
        assertInvalid("", as: .empty)
        assertInvalid(" ", as: .whitespaceOnly)
        assertInvalid("\t\n", as: .controlCharacter)
        assertInvalid(".", as: .reserved)
        assertInvalid("..", as: .reserved)
    }

    func testRejectsPathSeparatorsAndControlCharacters() {
        assertInvalid("Work/Ideas", as: .pathSeparator)
        assertInvalid("Work\\Ideas", as: .pathSeparator)
        assertInvalid("Work\u{0}Ideas", as: .controlCharacter)
        assertInvalid("Work\u{7F}Ideas", as: .controlCharacter)
    }

    func testEnforcesUTF8FilesystemComponentLimit() throws {
        XCTAssertNoThrow(try NotebookName.validate(String(repeating: "a", count: 255)))
        assertInvalid(String(repeating: "a", count: 256), as: .componentTooLong)

        XCTAssertNoThrow(try NotebookName.validate(String(repeating: "é", count: 127)))
        assertInvalid(String(repeating: "é", count: 128), as: .componentTooLong)
    }

    func testCollisionKeyIsCaseInsensitiveAndLocaleIndependent() {
        XCTAssertEqual(
            NotebookName.collisionKey("Project I"),
            NotebookName.collisionKey("project i")
        )
        XCTAssertEqual(
            NotebookName.collisionKey("Straße"),
            NotebookName.collisionKey("STRASSE")
        )
    }

    func testCollisionKeyUsesCanonicalUnicodeEquivalence() {
        XCTAssertEqual(
            NotebookName.collisionKey("Caf\u{E9}"),
            NotebookName.collisionKey("Cafe\u{301}")
        )
    }

    func testCollisionKeyDoesNotFoldDiacritics() {
        XCTAssertNotEqual(
            NotebookName.collisionKey("café"),
            NotebookName.collisionKey("cafe")
        )
    }

    func testCollisionNameTruncatesDerivedASCIIStemToComponentLimit() {
        let original = String(repeating: "a", count: 255)
        let derived = NotebookName.collisionName(original, id: collisionID)

        XCTAssertEqual(derived.utf8.count, 255)
        XCTAssertTrue(derived.hasSuffix(" (12345678)"))
        XCTAssertEqual(original, String(repeating: "a", count: 255))
    }

    func testCollisionNameTruncatesOnlyAtCharacterBoundaries() {
        let family = "👨‍👩‍👧‍👦"
        let original = String(repeating: family, count: 10)
        let derived = NotebookName.collisionName(original, id: collisionID)
        let stem = String(derived.dropLast(" (12345678)".count))

        XCTAssertLessThanOrEqual(derived.utf8.count, 255)
        XCTAssertTrue(stem.allSatisfy { String($0) == family })
        XCTAssertTrue(derived.hasSuffix(" (12345678)"))
    }

    func testCollisionNamePreservesMarkdownExtensionAndAddsAttempt() {
        let name = String(repeating: "é", count: 120) + ".MARKDOWN"
        let derived = NotebookName.collisionName(
            name,
            id: collisionID,
            attempt: 2
        )

        XCTAssertLessThanOrEqual(derived.utf8.count, 255)
        XCTAssertTrue(derived.hasSuffix(" (12345678-2).MARKDOWN"))
    }

    func testCollisionNamePreservesShortMarkdownExtension() {
        XCTAssertEqual(
            NotebookName.collisionName("Notes.Md", id: collisionID),
            "Notes (12345678).Md"
        )
    }

    private func assertInvalid(
        _ name: String,
        as expected: NotebookName.Error,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        XCTAssertThrowsError(
            try NotebookName.validate(name),
            file: file,
            line: line
        ) { error in
            XCTAssertEqual(error as? NotebookName.Error, expected)
        }
    }

    private var collisionID: UUID {
        UUID(uuidString: "12345678-1234-1234-1234-123456789ABC")!
    }
}
