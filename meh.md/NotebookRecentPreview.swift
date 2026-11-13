import Foundation
import NoteCore

enum NotebookRecentPreview {
    /// A note of only headings still shows them, rather than looking empty.
    nonisolated static func text(
        from markdown: String,
        characterLimit: Int = 160,
        skippingHeadings: Bool = false
    ) -> String {
        guard characterLimit > 0 else { return "" }
        let boundedSource = String(markdown.prefix(max(1_024, characterLimit * 8)))
        func excerpt(skippingHeadings: Bool) -> String {
            String(MarkdownExcerpt.plain(boundedSource, skippingHeadings: skippingHeadings)
                .text.prefix(characterLimit))
                .trimmingCharacters(in: .whitespaces)
        }
        let text = excerpt(skippingHeadings: skippingHeadings)
        return text.isEmpty && skippingHeadings ? excerpt(skippingHeadings: false) : text
    }

    /// The line Recents and Files show under a note's name.
    nonisolated static func rowText(from markdown: String) -> String {
        text(from: markdown, skippingHeadings: true)
    }
}
