import Foundation

enum NotebookName {
    enum Error: Swift.Error, Equatable {
        case empty
        case whitespaceOnly
        case reserved
        case pathSeparator
        case controlCharacter
        case componentTooLong
    }

    static func validate(_ name: String) throws {
        guard !name.isEmpty else {
            throw Error.empty
        }
        guard name != ".", name != ".." else {
            throw Error.reserved
        }
        guard !name.contains("/"), !name.contains("\\") else {
            throw Error.pathSeparator
        }
        guard
            name.unicodeScalars.allSatisfy({
                $0.properties.generalCategory != .control
            })
        else {
            throw Error.controlCharacter
        }
        guard
            !name.unicodeScalars.allSatisfy({
                CharacterSet.whitespacesAndNewlines.contains($0)
            })
        else {
            throw Error.whitespaceOnly
        }
        guard name.utf8.count <= 255 else {
            throw Error.componentTooLong
        }
    }

    static func collisionKey(_ name: String) -> String {
        name
            .precomposedStringWithCanonicalMapping
            .folding(
                options: [.caseInsensitive],
                locale: Locale(identifier: "en_US_POSIX")
            )
            .precomposedStringWithCanonicalMapping
    }

    static func collisionName(
        _ name: String,
        id: UUID,
        attempt: Int = 1
    ) -> String {
        let lowercased = name.lowercased(with: Locale(identifier: "en_US_POSIX"))
        let extensionLength: Int
        if lowercased.hasSuffix(".markdown") {
            extensionLength = 9
        } else if lowercased.hasSuffix(".md") {
            extensionLength = 3
        } else {
            extensionLength = 0
        }

        let markdownExtension = String(name.suffix(extensionLength))
        var stem = String(name.dropLast(extensionLength))
        let shortID = id.uuidString.prefix(8)
        let suffix =
            attempt > 1
            ? " (\(shortID)-\(attempt))"
            : " (\(shortID))"
        let stemByteLimit = 255 - suffix.utf8.count - markdownExtension.utf8.count

        while stem.utf8.count > stemByteLimit {
            stem.removeLast()
        }
        return stem + suffix + markdownExtension
    }
}
