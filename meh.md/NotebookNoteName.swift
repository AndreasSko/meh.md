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
        // An untouched title keeps its name, even one without ".md", so
        // submitting it does not rename the note.
        if title == self.title(from: originalFilename) {
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
        return uniqueFilename(stem: stem, existingNames: existingNames)
    }

    /// The name of a note made outside a window, such as from Shortcuts:
    /// `title` with ".md", or today's date when it's empty, like a new
    /// note in the app.
    nonisolated static func newFilename(
        named title: String?,
        on date: Date = Date(),
        existingNames: some Sequence<String>,
        calendar: Calendar = .current
    ) -> String {
        let title = title?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let stem = markdownExtension(in: title)
            .map { String(title.dropLast($0.count)) } ?? title
        guard !stem.isEmpty else {
            return defaultFilename(
                on: date, existingNames: existingNames, calendar: calendar)
        }
        return uniqueFilename(stem: stem, existingNames: existingNames)
    }

    nonisolated static func restoredFilename(
        for title: String,
        existingNames: some Sequence<String>
    ) -> String {
        uniqueFilename(stem: "\(title) (Restored)", existingNames: existingNames)
    }

    nonisolated private static func uniqueFilename(
        stem: String, existingNames: some Sequence<String>
    ) -> String {
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
