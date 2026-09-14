import SwiftUI

/// Synchronously commits the native buffer and freezes input before an
/// asynchronous navigation/save operation can replace the editor.
@MainActor
final class MarkdownEditorNavigation {
    var prepareToLeave: (() -> Bool)?
    var resumeEditing: (() -> Void)?
}

struct MarkdownEditorCommit {
    let text: String
    let revision: Data

    init(text: String, revision: Data) {
        self.text = text
        self.revision = revision
    }
}

private enum MarkdownEditorSelection {
    static func map(
        _ selection: NSRange,
        from oldText: String,
        to newText: String
    ) -> NSRange {
        let oldLength = (oldText as NSString).length
        let newLength = (newText as NSString).length
        let span = changedSpan(from: oldText, to: newText)
        let start = min(max(0, selection.location), oldLength)
        let rawEnd = selection.location.addingReportingOverflow(selection.length)
        let oldEnd = rawEnd.overflow
            ? oldLength
            : min(max(start, rawEnd.partialValue), oldLength)

        let mappedStart = mapOffset(
            start,
            oldRange: span.old,
            newRange: span.new
        )
        let mappedEnd = mapOffset(
            oldEnd,
            oldRange: span.old,
            newRange: span.new
        )
        let result = NSRange(
            location: min(mappedStart, newLength),
            length: max(0, min(mappedEnd, newLength) - mappedStart)
        )
        return newText.clampedSelection(result)
    }

    private static func changedSpan(
        from oldText: String,
        to newText: String
    ) -> (old: NSRange, new: NSRange) {
        let old = oldText as NSString
        let new = newText as NSString
        var prefix = 0
        while prefix < old.length, prefix < new.length,
              old.character(at: prefix) == new.character(at: prefix) {
            prefix += 1
        }
        prefix = scalarBoundary(at: prefix, in: old)
        prefix = min(prefix, scalarBoundary(at: prefix, in: new))

        var suffix = 0
        while suffix < old.length - prefix,
              suffix < new.length - prefix,
              old.character(at: old.length - suffix - 1)
                == new.character(at: new.length - suffix - 1) {
            suffix += 1
        }

        let oldEnd = scalarBoundary(at: old.length - suffix, in: old)
        let newEnd = scalarBoundary(at: new.length - suffix, in: new)
        return (
            NSRange(location: prefix, length: oldEnd - prefix),
            NSRange(location: prefix, length: newEnd - prefix)
        )
    }

    private static func scalarBoundary(
        at offset: Int,
        in text: NSString
    ) -> Int {
        guard offset > 0, offset < text.length else { return offset }
        let previous = text.character(at: offset - 1)
        let next = text.character(at: offset)
        let splitsSurrogatePair = (0xD800...0xDBFF).contains(previous)
            && (0xDC00...0xDFFF).contains(next)
        return splitsSurrogatePair ? offset - 1 : offset
    }

    private static func mapOffset(
        _ offset: Int,
        oldRange: NSRange,
        newRange: NSRange
    ) -> Int {
        let oldEnd = NSMaxRange(oldRange)
        let newEnd = NSMaxRange(newRange)
        if oldRange.length == 0 {
            return offset < oldRange.location
                ? offset
                : offset + newRange.length
        }
        if offset <= oldRange.location { return offset }
        if offset >= oldEnd { return newEnd + offset - oldEnd }
        return newEnd
    }
}

#if os(macOS)
import AppKit

final class MarkdownTextView: NSTextView {
    let markdownSyntaxCache = MarkdownSyntaxCache()

    override func drawBackground(in rect: NSRect) {
        super.drawBackground(in: rect)
        MarkdownPresentation.drawBlockBackgrounds(in: self, dirtyRect: rect)
    }
}

struct MarkdownEditor: NSViewRepresentable {
    @Binding var text: String
    var editRevision: Data?
    var commitEdit: ((String, Data) throws -> MarkdownEditorCommit)?
    var onEditError: ((Error) -> Void)?
    var navigation: MarkdownEditorNavigation?
    var fontSize: Double

    init(
        text: Binding<String>,
        editRevision: Data? = nil,
        commitEdit: ((String, Data) throws -> MarkdownEditorCommit)? = nil,
        onEditError: ((Error) -> Void)? = nil,
        navigation: MarkdownEditorNavigation? = nil,
        fontSize: Double = 17
    ) {
        _text = text
        self.editRevision = editRevision
        self.commitEdit = commitEdit
        self.onEditError = onEditError
        self.navigation = navigation
        self.fontSize = fontSize
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(parent: self)
    }

    func makeNSView(context: Context) -> NSScrollView {
        let scrollView = NSScrollView()
        let textView = MarkdownTextView(usingTextLayoutManager: true)

        scrollView.hasVerticalScroller = true
        scrollView.drawsBackground = false
        scrollView.documentView = textView

        textView.delegate = context.coordinator
        textView.string = text
        textView.isRichText = false
        textView.allowsUndo = true
        textView.drawsBackground = false
        textView.font = .systemFont(
            ofSize: MarkdownPresentation.normalizedFontSize(fontSize)
        )
        textView.textColor = .textColor
        textView.textContainerInset = NSSize(width: 22, height: 20)
        textView.textContainer?.lineFragmentPadding = 4
        textView.isHorizontallyResizable = false
        textView.isVerticallyResizable = true
        textView.autoresizingMask = [.width]
        textView.textContainer?.widthTracksTextView = true
        textView.setAccessibilityIdentifier("markdown-editor")
        MarkdownPresentation.configure(textView, fontSize: fontSize)
        context.coordinator.observeUndoAndRedo(for: textView)

        context.coordinator.attachNavigation(to: textView)
        return scrollView
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        guard let textView = scrollView.documentView as? NSTextView else {
            return
        }
        context.coordinator.update(parent: self, textView: textView)
    }

    final class Coordinator: NSObject, NSTextViewDelegate {
        var parent: MarkdownEditor
        private var displayedText: String
        private var displayedRevision: Data?
        private var staleParentRevision: Data?
        private var hasUncommittedText = false
        private var isUpdating = false
        private weak var observedTextView: NSTextView?
        private var displayedFontSize: CGFloat
        private var presentationRefreshScheduled = false

        init(parent: MarkdownEditor) {
            self.parent = parent
            displayedText = parent.text
            displayedRevision = parent.editRevision
            displayedFontSize = MarkdownPresentation.normalizedFontSize(
                parent.fontSize
            )
        }

        deinit {
            NotificationCenter.default.removeObserver(self)
        }

        func observeUndoAndRedo(for textView: NSTextView) {
            observedTextView = textView

            let center = NotificationCenter.default
            for name in [
                Notification.Name.NSUndoManagerDidUndoChange,
                Notification.Name.NSUndoManagerDidRedoChange,
            ] {
                center.removeObserver(self, name: name, object: nil)
                center.addObserver(
                    self,
                    selector: #selector(undoManagerDidChange(_:)),
                    name: name,
                    object: nil
                )
            }
        }

        func attachNavigation(to textView: NSTextView) {
            parent.navigation?.prepareToLeave = { [weak self, weak textView] in
                guard let self, let textView else { return true }
                guard !textView.hasMarkedText() else { return false }
                self.synchronizeBinding(from: textView)
                guard !self.hasUncommittedText else { return false }
                textView.isEditable = false
                return true
            }
            parent.navigation?.resumeEditing = { [weak textView] in
                textView?.isEditable = true
            }
        }

        func update(parent: MarkdownEditor, textView: NSTextView) {
            self.parent = parent
            guard !textView.hasMarkedText() else { return }

            let fontSize = MarkdownPresentation.normalizedFontSize(
                parent.fontSize
            )
            if displayedFontSize != fontSize {
                displayedFontSize = fontSize
                schedulePresentationRefresh(for: textView)
            }
            guard !hasUncommittedText else { return }

            if textView.string.utf8.elementsEqual(parent.text.utf8) {
                displayedText = textView.string
                acceptParentRevision(parent.editRevision)
                return
            }

            if let staleParentRevision,
               parent.editRevision == staleParentRevision {
                return
            }
            staleParentRevision = nil

            replaceDisplayedText(
                with: parent.text,
                revision: parent.editRevision,
                in: textView
            )
        }

        @objc private func undoManagerDidChange(_ notification: Notification) {
            guard let textView = observedTextView,
                  let undoManager = notification.object as? UndoManager,
                  undoManager === textView.undoManager else {
                return
            }
            synchronizeBinding(from: textView)
        }

        func textDidChange(_ notification: Notification) {
            guard let textView = notification.object as? NSTextView else {
                return
            }
            synchronizeBinding(from: textView)
        }

        private func synchronizeBinding(from textView: NSTextView) {
            guard !isUpdating, !textView.hasMarkedText() else { return }
            let nativeText = textView.string
            guard !displayedText.utf8.elementsEqual(nativeText.utf8) else {
                return
            }

            guard let commitEdit = parent.commitEdit,
                  let baseRevision = displayedRevision else {
                displayedText = nativeText
                parent.text = nativeText
                schedulePresentationRefresh(for: textView)
                return
            }

            do {
                let commit = try commitEdit(nativeText, baseRevision)
                hasUncommittedText = false
                staleParentRevision = baseRevision
                if nativeText.utf8.elementsEqual(commit.text.utf8) {
                    displayedText = nativeText
                    displayedRevision = commit.revision
                    parent.text = commit.text
                    schedulePresentationRefresh(for: textView)
                } else {
                    replaceDisplayedText(
                        with: commit.text,
                        revision: commit.revision,
                        in: textView
                    )
                    parent.text = commit.text
                }
            } catch {
                hasUncommittedText = true
                parent.onEditError?(error)
            }
        }

        private func acceptParentRevision(_ revision: Data?) {
            guard revision != staleParentRevision else { return }
            staleParentRevision = nil
            displayedRevision = revision
        }

        private func schedulePresentationRefresh(for textView: NSTextView) {
            guard !presentationRefreshScheduled else { return }
            presentationRefreshScheduled = true
            DispatchQueue.main.async { [weak self, weak textView] in
                guard let self else { return }
                self.presentationRefreshScheduled = false
                guard let textView, !textView.hasMarkedText() else { return }
                MarkdownPresentation.refresh(
                    textView,
                    fontSize: self.parent.fontSize
                )
                // Deferred TextKit styling can leave the native indicator
                // hidden after successive empty lines. Restore its normal
                // focus and blink lifecycle after presentation settles.
                textView.updateInsertionPointStateAndRestartTimer(true)
            }
        }

        private func replaceDisplayedText(
            with newText: String,
            revision: Data?,
            in textView: NSTextView
        ) {
            let oldText = textView.string
            let selection = MarkdownEditorSelection.map(
                textView.selectedRange(),
                from: oldText,
                to: newText
            )

            isUpdating = true
            defer { isUpdating = false }
            let undoManager = textView.undoManager
            let undoRegistrationWasEnabled =
                undoManager?.isUndoRegistrationEnabled == true
            if undoRegistrationWasEnabled {
                undoManager?.disableUndoRegistration()
            }
            let oldRange = NSRange(
                location: 0,
                length: (oldText as NSString).length
            )
            textView.textStorage?.replaceCharacters(in: oldRange, with: newText)
            if undoRegistrationWasEnabled {
                undoManager?.enableUndoRegistration()
            }

            textView.setSelectedRange(selection)
            displayedText = newText
            displayedRevision = revision
            hasUncommittedText = false
            // Native undo ranges refer to the replaced buffer. Clear them only
            // for external replacements; later local edits start a fresh chain.
            undoManager?.removeAllActions()
            MarkdownPresentation.refresh(
                textView,
                fontSize: parent.fontSize
            )
        }

        func textDidEndEditing(_ notification: Notification) {
            guard let textView = notification.object as? NSTextView else {
                return
            }
            MarkdownPresentation.refresh(
                textView,
                fontSize: parent.fontSize
            )
        }
    }
}

#else
import UIKit
import ObjectiveC

nonisolated(unsafe) private var markdownTextViewStateKey: UInt8 = 0

// UIKit's TextKit factory can bypass Swift subclass property initializers.
// Keep editor state in a normally initialized object attached to the view.
final class MarkdownTextView: UITextView {
    private var markdownState: MarkdownTextViewState {
        if let state = objc_getAssociatedObject(
            self,
            &markdownTextViewStateKey
        ) as? MarkdownTextViewState {
            return state
        }
        let state = MarkdownTextViewState()
        objc_setAssociatedObject(
            self,
            &markdownTextViewStateKey,
            state,
            .OBJC_ASSOCIATION_RETAIN_NONATOMIC
        )
        return state
    }

    var markdownSyntaxCache: MarkdownSyntaxCache {
        markdownState.syntaxCache
    }

    func installMarkdownLayoutManagerDelegate(
        on layoutManager: NSTextLayoutManager
    ) {
        if layoutManager.delegate === markdownState.layoutDelegate { return }
        let fragmentSelector = NSSelectorFromString(
            "textLayoutManager:textLayoutFragmentForLocation:inTextElement:"
        )
        if layoutManager.delegate?.responds(to: fragmentSelector) == true {
            assertionFailure(
                "Cannot replace an existing TextKit 2 fragment factory"
            )
            return
        }
        let delegate = MarkdownLayoutManagerDelegate(
            textView: self,
            forwardingTo: layoutManager.delegate
        )
        markdownState.layoutDelegate = delegate
        layoutManager.delegate = delegate
    }
}

private final class MarkdownTextViewState: NSObject {
    let syntaxCache = MarkdownSyntaxCache()
    var layoutDelegate: MarkdownLayoutManagerDelegate?
}

private final class MarkdownLayoutManagerDelegate:
    NSObject, NSTextLayoutManagerDelegate {
    private weak var textView: MarkdownTextView?
    nonisolated(unsafe) private weak var forwardedDelegate:
        (any NSTextLayoutManagerDelegate)?

    init(
        textView: MarkdownTextView,
        forwardingTo delegate: (any NSTextLayoutManagerDelegate)?
    ) {
        self.textView = textView
        forwardedDelegate = delegate
    }

    nonisolated override func responds(to selector: Selector!) -> Bool {
        super.responds(to: selector)
            || forwardedDelegate?.responds(to: selector) == true
    }

    nonisolated override func forwardingTarget(
        for selector: Selector!
    ) -> Any? {
        if forwardedDelegate?.responds(to: selector) == true {
            return forwardedDelegate
        }
        return super.forwardingTarget(for: selector)
    }

    func textLayoutManager(
        _ textLayoutManager: NSTextLayoutManager,
        textLayoutFragmentFor location: any NSTextLocation,
        in textElement: NSTextElement
    ) -> NSTextLayoutFragment {
        guard let textView else {
            return NSTextLayoutFragment(
                textElement: textElement,
                range: nil
            )
        }
        return MarkdownTextLayoutFragment(
            textElement: textElement,
            range: nil,
            textView: textView
        )
    }
}

nonisolated private final class MarkdownTextLayoutFragment:
    NSTextLayoutFragment {
    private struct UnsafeTransfer<Value>: @unchecked Sendable {
        let value: Value
    }

    nonisolated(unsafe) private weak var textView: MarkdownTextView?

    nonisolated init(
        textElement: NSTextElement,
        range: NSTextRange?,
        textView: MarkdownTextView
    ) {
        self.textView = textView
        super.init(textElement: textElement, range: range)
    }

    nonisolated required init?(coder: NSCoder) {
        super.init(coder: coder)
    }

    nonisolated override var renderingSurfaceBounds: CGRect {
        let defaultBounds = super.renderingSurfaceBounds
        let fragment = UnsafeTransfer(value: self)
        return MainActor.assumeIsolated {
            guard let textView = fragment.value.textView else {
                return defaultBounds
            }
            let fragmentFrame = fragment.value.layoutFragmentFrame
            let verticalPadding = max(
                textView.font?.lineHeight ?? 0,
                MarkdownPresentation.editorBodyFont.lineHeight
            ) * 0.3
            let panelBounds = CGRect(
                x: -fragmentFrame.minX - 3,
                y: -verticalPadding,
                width: textView.textContainer.size.width + 3,
                height: fragmentFrame.height + 2 * verticalPadding
            )
            return defaultBounds.union(panelBounds)
        }
    }

    nonisolated override func draw(at point: CGPoint, in context: CGContext) {
        let fragment = UnsafeTransfer(value: self)
        let drawingContext = UnsafeTransfer(value: context)
        MainActor.assumeIsolated {
            if let textView = fragment.value.textView {
                MarkdownPresentation.drawBlockBackgrounds(
                    in: fragment.value,
                    textView: textView,
                    at: point,
                    context: drawingContext.value
                )
            }
        }
        super.draw(at: point, in: context)
    }
}

struct MarkdownEditor: UIViewRepresentable {
    @Binding var text: String
    var editRevision: Data?
    var commitEdit: ((String, Data) throws -> MarkdownEditorCommit)?
    var onEditError: ((Error) -> Void)?
    var navigation: MarkdownEditorNavigation?
    var fontSize: Double

    init(
        text: Binding<String>,
        editRevision: Data? = nil,
        commitEdit: ((String, Data) throws -> MarkdownEditorCommit)? = nil,
        onEditError: ((Error) -> Void)? = nil,
        navigation: MarkdownEditorNavigation? = nil,
        fontSize: Double = 17
    ) {
        _text = text
        self.editRevision = editRevision
        self.commitEdit = commitEdit
        self.onEditError = onEditError
        self.navigation = navigation
        self.fontSize = fontSize
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(parent: self)
    }

    func makeUIView(context: Context) -> UITextView {
        let textView = MarkdownTextView(usingTextLayoutManager: true)
        if let layoutManager = textView.textLayoutManager {
            textView.installMarkdownLayoutManagerDelegate(on: layoutManager)
        }

        textView.delegate = context.coordinator
        textView.keyboardDismissMode = .onDrag
        textView.alwaysBounceVertical = true
        textView.text = text
        textView.allowsEditingTextAttributes = false
        textView.font = .systemFont(
            ofSize: MarkdownPresentation.normalizedFontSize(fontSize)
        )
        textView.textColor = .label
        textView.backgroundColor = .clear
        textView.textContainerInset = UIEdgeInsets(
            top: 18,
            left: 16,
            bottom: 18,
            right: 16
        )
        textView.textContainer.lineFragmentPadding = 4
        textView.accessibilityIdentifier = "markdown-editor"
        MarkdownPresentation.configure(textView, fontSize: fontSize)

        context.coordinator.attachNavigation(to: textView)
        return textView
    }

    func updateUIView(_ textView: UITextView, context: Context) {
        context.coordinator.update(parent: self, textView: textView)
    }

    final class Coordinator: NSObject, UITextViewDelegate {
        var parent: MarkdownEditor
        private var displayedText: String
        private var displayedRevision: Data?
        private var staleParentRevision: Data?
        private var hasUncommittedText = false
        private var isUpdating = false
        private var displayedFontSize: CGFloat
        private var presentationRefreshScheduled = false

        func scrollViewWillBeginDragging(_ scrollView: UIScrollView) {
            scrollView.endEditing(false)
        }

        init(parent: MarkdownEditor) {
            self.parent = parent
            displayedText = parent.text
            displayedRevision = parent.editRevision
            displayedFontSize = MarkdownPresentation.normalizedFontSize(
                parent.fontSize
            )
        }

        func attachNavigation(to textView: UITextView) {
            parent.navigation?.prepareToLeave = { [weak self, weak textView] in
                guard let self, let textView else { return true }
                guard textView.markedTextRange == nil else { return false }
                self.textViewDidChange(textView)
                guard !self.hasUncommittedText else { return false }
                textView.isEditable = false
                return true
            }
            parent.navigation?.resumeEditing = { [weak textView] in
                textView?.isEditable = true
            }
        }

        func update(parent: MarkdownEditor, textView: UITextView) {
            self.parent = parent
            guard textView.markedTextRange == nil else { return }

            let fontSize = MarkdownPresentation.normalizedFontSize(
                parent.fontSize
            )
            if displayedFontSize != fontSize {
                displayedFontSize = fontSize
                schedulePresentationRefresh(for: textView)
            }
            guard !hasUncommittedText else { return }

            if textView.text.utf8.elementsEqual(parent.text.utf8) {
                displayedText = textView.text
                acceptParentRevision(parent.editRevision)
                return
            }

            if let staleParentRevision,
               parent.editRevision == staleParentRevision {
                return
            }
            staleParentRevision = nil

            replaceDisplayedText(
                with: parent.text,
                revision: parent.editRevision,
                in: textView
            )
        }

        func textViewDidChange(_ textView: UITextView) {
            guard !isUpdating, textView.markedTextRange == nil else { return }
            let nativeText = textView.text ?? ""
            guard !displayedText.utf8.elementsEqual(nativeText.utf8) else {
                return
            }

            guard let commitEdit = parent.commitEdit,
                  let baseRevision = displayedRevision else {
                displayedText = nativeText
                parent.text = nativeText
                schedulePresentationRefresh(for: textView)
                return
            }

            do {
                let commit = try commitEdit(nativeText, baseRevision)
                hasUncommittedText = false
                staleParentRevision = baseRevision
                if nativeText.utf8.elementsEqual(commit.text.utf8) {
                    displayedText = nativeText
                    displayedRevision = commit.revision
                    parent.text = commit.text
                    schedulePresentationRefresh(for: textView)
                } else {
                    replaceDisplayedText(
                        with: commit.text,
                        revision: commit.revision,
                        in: textView
                    )
                    parent.text = commit.text
                }
            } catch {
                hasUncommittedText = true
                parent.onEditError?(error)
            }
        }

        private func acceptParentRevision(_ revision: Data?) {
            guard revision != staleParentRevision else { return }
            staleParentRevision = nil
            displayedRevision = revision
        }

        private func schedulePresentationRefresh(for textView: UITextView) {
            guard !presentationRefreshScheduled else { return }
            presentationRefreshScheduled = true
            DispatchQueue.main.async { [weak self, weak textView] in
                guard let self else { return }
                self.presentationRefreshScheduled = false
                guard let textView, textView.markedTextRange == nil else {
                    return
                }
                MarkdownPresentation.refresh(
                    textView,
                    fontSize: self.parent.fontSize
                )
            }
        }

        private func replaceDisplayedText(
            with newText: String,
            revision: Data?,
            in textView: UITextView
        ) {
            let oldText = textView.text ?? ""
            let selection = MarkdownEditorSelection.map(
                textView.selectedRange,
                from: oldText,
                to: newText
            )

            isUpdating = true
            defer { isUpdating = false }
            let oldRange = NSRange(
                location: 0,
                length: (oldText as NSString).length
            )
            textView.textStorage.replaceCharacters(in: oldRange, with: newText)

            textView.selectedRange = selection
            displayedText = newText
            displayedRevision = revision
            hasUncommittedText = false
            // Native undo ranges refer to the replaced buffer. Clear them only
            // for external replacements; later local edits start a fresh chain.
            // UIKit can replace its private undo manager while text storage is
            // changed, so do not balance registration calls across this edit.
            textView.undoManager?.removeAllActions()
            MarkdownPresentation.refresh(
                textView,
                fontSize: parent.fontSize
            )
        }

        func textViewDidEndEditing(_ textView: UITextView) {
            MarkdownPresentation.refresh(
                textView,
                fontSize: parent.fontSize
            )
        }
    }
}
#endif
