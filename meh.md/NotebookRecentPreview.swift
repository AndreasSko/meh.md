import Foundation
import NoteCore

enum NotebookRecentPreview {
    nonisolated static func text(
        from markdown: String,
        characterLimit: Int = 160
    ) -> String {
        guard characterLimit > 0 else { return "" }
        let boundedSource = String(markdown.prefix(max(1_024, characterLimit * 8)))
        return String(MarkdownExcerpt.plain(boundedSource).text.prefix(characterLimit))
            .trimmingCharacters(in: .whitespaces)
    }
}
