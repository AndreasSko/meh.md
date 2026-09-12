import SwiftUI

#if os(macOS)
import AppKit

struct MarkdownEditor: NSViewRepresentable {
    @Binding var text: String

    func makeCoordinator() -> Coordinator {
        Coordinator(parent: self)
    }

    func makeNSView(context: Context) -> NSScrollView {
        let scrollView = NSScrollView()
        let textView = NSTextView(usingTextLayoutManager: true)

        scrollView.hasVerticalScroller = true
        scrollView.drawsBackground = false
        scrollView.documentView = textView

        textView.delegate = context.coordinator
        textView.string = text
        textView.isRichText = false
        textView.allowsUndo = true
        textView.drawsBackground = false
        textView.font = .preferredFont(forTextStyle: .body)
        textView.textColor = .textColor
        textView.textContainerInset = NSSize(width: 16, height: 12)
        textView.isHorizontallyResizable = false
        textView.isVerticallyResizable = true
        textView.autoresizingMask = [.width]
        textView.textContainer?.widthTracksTextView = true
        textView.setAccessibilityIdentifier("markdown-editor")
        MarkdownPresentation.configure(textView)

        return scrollView
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        guard let textView = scrollView.documentView as? NSTextView else {
            return
        }

        context.coordinator.parent = self
        guard !textView.hasMarkedText() else { return }
        guard textView.string != text else { return }

        context.coordinator.isUpdating = true
        defer { context.coordinator.isUpdating = false }
        let selection = text.clampedSelection(textView.selectedRange())
        let undoRegistrationWasEnabled =
            textView.undoManager?.isUndoRegistrationEnabled == true
        if undoRegistrationWasEnabled {
            textView.undoManager?.disableUndoRegistration()
        }
        defer {
            if undoRegistrationWasEnabled {
                textView.undoManager?.enableUndoRegistration()
            }
        }

        let oldRange = NSRange(
            location: 0,
            length: (textView.string as NSString).length
        )
        textView.textStorage?.replaceCharacters(in: oldRange, with: text)
        textView.setSelectedRange(selection)
        MarkdownPresentation.refresh(textView)
    }

    final class Coordinator: NSObject, NSTextViewDelegate {
        var parent: MarkdownEditor
        var isUpdating = false

        init(parent: MarkdownEditor) {
            self.parent = parent
        }

        func textDidChange(_ notification: Notification) {
            guard !isUpdating,
                  let textView = notification.object as? NSTextView else {
                return
            }

            guard !textView.hasMarkedText() else { return }
            parent.text = textView.string
            MarkdownPresentation.refresh(textView)
        }

        func textDidEndEditing(_ notification: Notification) {
            guard let textView = notification.object as? NSTextView else {
                return
            }
            MarkdownPresentation.refresh(textView)
        }
    }
}

#else
import UIKit

struct MarkdownEditor: UIViewRepresentable {
    @Binding var text: String

    func makeCoordinator() -> Coordinator {
        Coordinator(parent: self)
    }

    func makeUIView(context: Context) -> UITextView {
        let textView = UITextView(usingTextLayoutManager: true)

        textView.delegate = context.coordinator
        textView.text = text
        textView.allowsEditingTextAttributes = false
        textView.font = .preferredFont(forTextStyle: .body)
        textView.textColor = .label
        textView.backgroundColor = .clear
        textView.textContainerInset = UIEdgeInsets(
            top: 12,
            left: 12,
            bottom: 12,
            right: 12
        )
        textView.accessibilityIdentifier = "markdown-editor"
        MarkdownPresentation.configure(textView)

        return textView
    }

    func updateUIView(_ textView: UITextView, context: Context) {
        context.coordinator.parent = self
        guard textView.markedTextRange == nil else { return }
        guard textView.text != text else { return }

        context.coordinator.isUpdating = true
        defer { context.coordinator.isUpdating = false }
        let selection = text.clampedSelection(textView.selectedRange)
        let undoRegistrationWasEnabled =
            textView.undoManager?.isUndoRegistrationEnabled == true
        if undoRegistrationWasEnabled {
            textView.undoManager?.disableUndoRegistration()
        }
        defer {
            if undoRegistrationWasEnabled {
                textView.undoManager?.enableUndoRegistration()
            }
        }

        let oldRange = NSRange(
            location: 0,
            length: (textView.text as NSString).length
        )
        textView.textStorage.replaceCharacters(in: oldRange, with: text)
        textView.selectedRange = selection
        MarkdownPresentation.refresh(textView)
    }

    final class Coordinator: NSObject, UITextViewDelegate {
        var parent: MarkdownEditor
        var isUpdating = false

        init(parent: MarkdownEditor) {
            self.parent = parent
        }

        func textViewDidChange(_ textView: UITextView) {
            guard !isUpdating else { return }

            guard textView.markedTextRange == nil else { return }
            parent.text = textView.text
            MarkdownPresentation.refresh(textView)
        }

        func textViewDidEndEditing(_ textView: UITextView) {
            MarkdownPresentation.refresh(textView)
        }
    }
}
#endif
