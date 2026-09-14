import Foundation

enum NotebookNoteName {
    nonisolated static func title(from filename: String) -> String {
        guard let markdownExtension = markdownExtension(in: filename) else {
            return filename
        }
        let stem = String(filename.dropLast(markdownExtension.count))
        return stem.isEmpty ? filename : stem
    }

    nonisolated static func filename(
        for title: String,
        preservingExtensionFrom originalFilename: String
    ) -> String {
        guard title != ".", title != "..",
              !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        else {
            return title
        }
        if title == originalFilename, title == markdownExtension(in: title) {
            return originalFilename
        }
        let titleWithoutExtension: String
        if let typedExtension = markdownExtension(in: title) {
            titleWithoutExtension = String(title.dropLast(typedExtension.count))
        } else {
            titleWithoutExtension = title
        }
        guard !titleWithoutExtension.isEmpty else { return titleWithoutExtension }
        return titleWithoutExtension
            + (markdownExtension(in: originalFilename) ?? ".md")
    }

    nonisolated static func defaultFilename(
        on date: Date = Date(),
        existingNames: some Sequence<String>,
        calendar: Calendar = .current
    ) -> String {
        let components = calendar.dateComponents([.year, .month, .day], from: date)
        let stem = String(
            format: "%04d-%02d-%02d",
            components.year ?? 0,
            components.month ?? 0,
            components.day ?? 0
        )
        let reserved = Set(existingNames.map(collisionKey))
        var attempt = 1
        var candidate = stem + ".md"
        while reserved.contains(collisionKey(candidate)) {
            attempt += 1
            candidate = "\(stem) \(attempt).md"
        }
        return candidate
    }

    nonisolated private static func markdownExtension(in filename: String) -> String? {
        let lowercase = filename.lowercased(with: Locale(identifier: "en_US_POSIX"))
        if lowercase.hasSuffix(".markdown") { return String(filename.suffix(9)) }
        if lowercase.hasSuffix(".md") { return String(filename.suffix(3)) }
        return nil
    }

    nonisolated private static func collisionKey(_ name: String) -> String {
        name
            .precomposedStringWithCanonicalMapping
            .folding(
                options: [.caseInsensitive],
                locale: Locale(identifier: "en_US_POSIX")
            )
            .precomposedStringWithCanonicalMapping
    }
}
