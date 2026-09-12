import Foundation

#if os(macOS)
import AppKit

typealias PlatformFont = NSFont
typealias PlatformColor = NSColor
#else
import UIKit

typealias PlatformFont = UIFont
typealias PlatformColor = UIColor
#endif

enum MarkdownPresentation {
#if os(macOS)
    static func configure(_ textView: NSTextView) {
        guard let layoutManager = textView.textLayoutManager else {
            assertionFailure("Markdown editor requires TextKit 2")
            return
        }

        layoutManager.renderingAttributesValidator = {
            [weak textView] manager, fragment in
            guard let textView else { return }
            applyRenderingAttributes(
                to: manager,
                fragment: fragment,
                text: textView.string
            )
        }
        refresh(textView)
    }

    static func refresh(_ textView: NSTextView) {
        guard !textView.hasMarkedText(),
              let textStorage = textView.textStorage else { return }

        let selection = textView.selectedRange()
        defer { textView.setSelectedRange(selection) }
        applyLayoutAttributes(
            to: textStorage,
            text: textView.string,
            bodyFont: textView.font ?? .preferredFont(forTextStyle: .body),
            undoManager: textView.undoManager
        )
        invalidateRenderingAttributes(in: textView.textLayoutManager)
    }
#else
    static func configure(_ textView: UITextView) {
        guard let layoutManager = textView.textLayoutManager else {
            assertionFailure("Markdown editor requires TextKit 2")
            return
        }

        layoutManager.renderingAttributesValidator = {
            [weak textView] manager, fragment in
            guard let textView else { return }
            applyRenderingAttributes(
                to: manager,
                fragment: fragment,
                text: textView.text ?? ""
            )
        }
        refresh(textView)
    }

    static func refresh(_ textView: UITextView) {
        guard textView.markedTextRange == nil else { return }

        let selection = textView.selectedRange
        defer { textView.selectedRange = selection }
        applyLayoutAttributes(
            to: textView.textStorage,
            text: textView.text ?? "",
            bodyFont: textView.font ?? .preferredFont(forTextStyle: .body),
            undoManager: textView.undoManager
        )
        invalidateRenderingAttributes(in: textView.textLayoutManager)
    }
#endif

    private static func applyLayoutAttributes(
        to textStorage: NSTextStorage,
        text: String,
        bodyFont: PlatformFont,
        undoManager: UndoManager?
    ) {
        let fullRange = NSRange(location: 0, length: (text as NSString).length)
        let undoRegistrationWasEnabled =
            undoManager?.isUndoRegistrationEnabled == true
        if undoRegistrationWasEnabled {
            undoManager?.disableUndoRegistration()
        }
        defer {
            if undoRegistrationWasEnabled {
                undoManager?.enableUndoRegistration()
            }
        }

        textStorage.beginEditing()
        textStorage.removeAttribute(.font, range: fullRange)
        textStorage.addAttribute(.font, value: bodyFont, range: fullRange)
        for run in MarkdownSyntax.fontRuns(in: text) {
            let font = layoutFont(for: run.traits, bodyFont: bodyFont)
            textStorage.addAttribute(.font, value: font, range: run.range)
        }
        textStorage.endEditing()
    }

    private static func applyRenderingAttributes(
        to layoutManager: NSTextLayoutManager,
        fragment: NSTextLayoutFragment,
        text: String
    ) {
        guard let contentManager = layoutManager.textContentManager else {
            return
        }
        let documentStart = contentManager.documentRange.location
        let fragmentRange = nsRange(
            for: fragment.rangeInElement,
            documentStart: documentStart,
            contentManager: contentManager
        )

        for span in MarkdownSyntax.spans(in: text) {
            let attributes = renderingAttributes(for: span.role)
            guard !attributes.isEmpty else { continue }

            let intersection = NSIntersectionRange(span.range, fragmentRange)
            guard intersection.length > 0,
                  let textRange = textRange(
                    for: intersection,
                    documentStart: documentStart,
                    contentManager: contentManager
                  ) else { continue }
            layoutManager.setRenderingAttributes(attributes, for: textRange)
        }
    }

    private static func invalidateRenderingAttributes(
        in layoutManager: NSTextLayoutManager?
    ) {
        guard let layoutManager,
              let contentManager = layoutManager.textContentManager else {
            return
        }
        layoutManager.invalidateRenderingAttributes(
            for: contentManager.documentRange
        )
    }

    private static func nsRange(
        for textRange: NSTextRange,
        documentStart: any NSTextLocation,
        contentManager: NSTextContentManager
    ) -> NSRange {
        let location = contentManager.offset(
            from: documentStart,
            to: textRange.location
        )
        let end = contentManager.offset(
            from: documentStart,
            to: textRange.endLocation
        )
        return NSRange(location: location, length: max(0, end - location))
    }

    private static func textRange(
        for range: NSRange,
        documentStart: any NSTextLocation,
        contentManager: NSTextContentManager
    ) -> NSTextRange? {
        guard let start = contentManager.location(
            documentStart,
            offsetBy: range.location
        ), let end = contentManager.location(
            start,
            offsetBy: range.length
        ) else { return nil }
        return NSTextRange(location: start, end: end)
    }

    private static func renderingAttributes(
        for role: MarkdownStyleRole
    ) -> [NSAttributedString.Key: Any] {
        switch role {
        case .code:
            return [.backgroundColor: PlatformColor.secondarySystemFill]
        case .link:
            return [.foregroundColor: PlatformColor.systemBlue]
        case .listMarker:
            return [.foregroundColor: PlatformColor.systemOrange]
        case .heading, .strong, .emphasis:
            return [:]
        }
    }

    private static func layoutFont(
        for traits: MarkdownFontTraits,
        bodyFont: PlatformFont
    ) -> PlatformFont {
        var font = traits.contains(.monospaced)
            ? monospacedFont(size: bodyFont.pointSize)
            : bodyFont
        if traits.contains(.bold) {
            font = strongFont(font)
        }
        if traits.contains(.italic) {
            font = emphasisFont(font)
        }
        return font
    }

#if os(macOS)
    private static func strongFont(_ font: NSFont) -> NSFont {
        NSFontManager.shared.convert(font, toHaveTrait: .boldFontMask)
    }

    private static func emphasisFont(_ font: NSFont) -> NSFont {
        NSFontManager.shared.convert(font, toHaveTrait: .italicFontMask)
    }

    private static func monospacedFont(size: CGFloat) -> NSFont {
        .monospacedSystemFont(ofSize: size, weight: .regular)
    }
#else
    private static func strongFont(_ font: UIFont) -> UIFont {
        fontAddingTrait(.traitBold, to: font)
    }

    private static func emphasisFont(_ font: UIFont) -> UIFont {
        fontAddingTrait(.traitItalic, to: font)
    }

    private static func fontAddingTrait(
        _ trait: UIFontDescriptor.SymbolicTraits,
        to value: UIFont
    ) -> UIFont {
        let traits = value.fontDescriptor.symbolicTraits.union(trait)
        guard let descriptor = value.fontDescriptor.withSymbolicTraits(traits)
        else { return value }
        return UIFont(descriptor: descriptor, size: value.pointSize)
    }

    private static func monospacedFont(size: CGFloat) -> UIFont {
        .monospacedSystemFont(ofSize: size, weight: .regular)
    }
#endif
}
