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
            var hasPreviousText = false
            for run in attributed.runs {
                let block = run.presentationIntent
                let text = String(attributed[run.range].characters)
                guard !text.isEmpty else { continue }

                if text.allSatisfy(\.isWhitespace) {
                    // A whitespace-only run that changes intent represents an
                    // empty block; keep it out so it cannot create duplicate
                    // separators around the next non-empty block.
                    if block == previousBlock {
                        rendered.append(contentsOf: text)
                    }
                    continue
                }

                if hasPreviousText, block != previousBlock {
                    if rendered.last?.isWhitespace == true {
                        rendered.append("· ")
                    } else {
                        rendered.append(" · ")
                    }
                }
                rendered.append(contentsOf: text)
                previousBlock = block
                hasPreviousText = true
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
