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

        let syntaxCache = MarkdownSyntaxCache()
        layoutManager.renderingAttributesValidator = {
            [weak textView] manager, fragment in
            guard let textView else { return }
            applyRenderingAttributes(
                to: manager,
                fragment: fragment,
                result: syntaxCache.result(for: textView.string)
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
            bodyFont: .preferredFont(forTextStyle: .body),
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

        let syntaxCache = MarkdownSyntaxCache()
        layoutManager.renderingAttributesValidator = {
            [weak textView] manager, fragment in
            guard let textView else { return }
            applyRenderingAttributes(
                to: manager,
                fragment: fragment,
                result: syntaxCache.result(for: textView.text ?? "")
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
            bodyFont: .preferredFont(forTextStyle: .body),
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
        let result = MarkdownSyntax.parse(text)
        for run in result.fontRuns {
            let font = layoutFont(for: run, bodyFont: bodyFont)
            textStorage.addAttribute(.font, value: font, range: run.range)
        }
        textStorage.endEditing()
    }

    private static func applyRenderingAttributes(
        to layoutManager: NSTextLayoutManager,
        fragment: NSTextLayoutFragment,
        result: MarkdownSyntaxResult
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

        for span in result.spans {
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

    static func renderingAttributes(
        for role: MarkdownStyleRole
    ) -> [NSAttributedString.Key: Any] {
        switch role {
        case .code:
            return [
                .backgroundColor: PlatformColor.secondarySystemFill,
                .foregroundColor: primaryTextColor,
            ]
        case .link:
            return [.foregroundColor: PlatformColor.systemBlue]
        case .listMarker:
            return [.foregroundColor: PlatformColor.systemOrange]
        case .heading, .strong, .emphasis:
            return [:]
        }
    }

    private static func layoutFont(
        for run: MarkdownFontRun,
        bodyFont: PlatformFont
    ) -> PlatformFont {
        let size = bodyFont.pointSize * headingScale(for: run.headingLevel)
        var font = run.traits.contains(.monospaced)
            ? monospacedFont(size: size)
            : fontWithSize(bodyFont, size: size)
        if run.traits.contains(.bold) {
            font = strongFont(font)
        }
        if run.traits.contains(.italic) {
            font = emphasisFont(font)
        }
        return font
    }

    private static func headingScale(for level: Int?) -> CGFloat {
        switch level {
        case 1: 2
        case 2: 1.65
        case 3: 1.4
        case 4: 1.25
        case 5: 1.15
        case 6: 1.08
        default: 1
        }
    }

#if os(macOS)
    private static func strongFont(_ font: NSFont) -> NSFont {
        NSFontManager.shared.convert(font, toHaveTrait: .boldFontMask)
    }

    private static func emphasisFont(_ font: NSFont) -> NSFont {
        NSFontManager.shared.convert(font, toHaveTrait: .italicFontMask)
    }

    private static func fontWithSize(_ font: NSFont, size: CGFloat) -> NSFont {
        NSFont(descriptor: font.fontDescriptor, size: size) ?? font
    }

    private static func monospacedFont(size: CGFloat) -> NSFont {
        .monospacedSystemFont(ofSize: size, weight: .regular)
    }

    private static var primaryTextColor: NSColor { .textColor }
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

    private static func fontWithSize(_ font: UIFont, size: CGFloat) -> UIFont {
        UIFont(descriptor: font.fontDescriptor, size: size)
    }

    private static func monospacedFont(size: CGFloat) -> UIFont {
        .monospacedSystemFont(ofSize: size, weight: .regular)
    }

    private static var primaryTextColor: UIColor { .label }
#endif
}

private final class MarkdownSyntaxCache {
    private var cachedText: String?
    private var cachedResult: MarkdownSyntaxResult?

    func result(for text: String) -> MarkdownSyntaxResult {
        if let cachedText, cachedText.utf8.elementsEqual(text.utf8),
           let cachedResult {
            return cachedResult
        }
        let result = MarkdownSyntax.parse(text)
        cachedText = text
        cachedResult = result
        return result
    }
}
