import Foundation

enum NotebookRecentPreview {
    nonisolated static func text(
        from markdown: String,
        characterLimit: Int = 160
    ) -> String {
        guard characterLimit > 0 else { return "" }

        let sourceLimit = max(1_024, characterLimit * 8)
        let boundedSource = String(markdown.prefix(sourceLimit))
        let plainText: String
        do {
            let attributed = try AttributedString(
                markdown: boundedSource,
                options: .init(interpretedSyntax: .full)
            )
            var rendered = ""
            var previousBlock: PresentationIntent?
            for run in attributed.runs {
                let block = run.presentationIntent
                if previousBlock != nil,
                   block != previousBlock,
                   rendered.last?.isWhitespace == false {
                    rendered.append(" ")
                }
                rendered.append(contentsOf: attributed[run.range].characters)
                previousBlock = block
            }
            plainText = rendered
        } catch {
            plainText = boundedSource
        }

        return plainText
            .split(whereSeparator: \.isWhitespace)
            .joined(separator: " ")
            .prefix(characterLimit)
            .trimmingCharacters(in: .whitespaces)
    }
}
