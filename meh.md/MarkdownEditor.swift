import SwiftUI

enum MarkdownEditorScrollPadding {
    static func bottom(for viewportHeight: CGFloat) -> CGFloat {
        max(0, viewportHeight / 2)
    }
}

/// Synchronously commits the native buffer and freezes input before an
/// asynchronous navigation/save operation can replace the editor.
@MainActor
final class MarkdownEditorNavigation {
    var prepareToLeave: (() -> Bool)?
    var resumeEditing: (() -> Void)?
    var focusEditor: (() -> Void)?
    var captureHasEditingFocus: (() -> Bool)?
    var performCommand: ((MarkdownEditingCommand) -> Void)?
    var showFind: (() -> Void)?
    var revealSearchMatch: ((NSRange) -> Void)?
    var searchLandingPosition: MarkdownEditorPosition?
    var capturePosition: (() -> MarkdownEditorPosition?)?
    var restorePosition: ((MarkdownEditorPosition) -> Void)?

    private var isAttached = false
    private var isValid = true
    private var pendingAttachmentAction: (@MainActor @Sendable () -> Void)?

    func whenAttached(_ action: @escaping @MainActor @Sendable () -> Void) {
        guard isValid else { return }
        pendingAttachmentAction = action
        if isAttached { dispatchAttachmentAction() }
    }

    func didAttach() {
        guard isValid else { return }
        isAttached = true
        dispatchAttachmentAction()
    }

    func invalidate() {
        isValid = false
        pendingAttachmentAction = nil
    }

    private func dispatchAttachmentAction() {
        guard let action = pendingAttachmentAction else { return }
        pendingAttachmentAction = nil
        // Run after representable construction has completed.
        DispatchQueue.main.async { [weak self] in
            guard self?.isValid == true else { return }
            action()
        }
    }
}

/// A device-local editing selection and reading position in UTF-16 offsets.
struct MarkdownEditorPosition: Codable, Equatable, Sendable {
    let selection: NSRange
    let scrollAnchor: Int
    let scrollAnchorOffset: Double

    init(
        selection: NSRange,
        scrollAnchor: Int,
        scrollAnchorOffset: Double
    ) {
        self.selection = selection
        self.scrollAnchor = scrollAnchor
        self.scrollAnchorOffset = scrollAnchorOffset
    }
}

/// Acknowledges text already committed to the backing model by `commitEdit`.
/// The revision identifies that exact model state; it must change when the
/// model text changes. The editor does not write this text through its binding.
struct MarkdownEditorCommit {
    let text: String
    let revision: Data

    init(text: String, revision: Data) {
        self.text = text
        self.revision = revision
    }
}

private enum MarkdownEditorDestinationHighlight {
    static func textRange(
        for range: NSRange,
        in layoutManager: NSTextLayoutManager
    ) -> NSTextRange? {
        guard let contentManager = layoutManager.textContentManager,
              let start = contentManager.location(
                contentManager.documentRange.location,
                offsetBy: range.location
              ), let end = contentManager.location(
                start, offsetBy: range.length
              ) else { return nil }
        return NSTextRange(location: start, end: end)
    }

    static func nsRange(
        for range: NSTextRange,
        in layoutManager: NSTextLayoutManager
    ) -> NSRange? {
        guard let contentManager = layoutManager.textContentManager else {
            return nil
        }
        let documentStart = contentManager.documentRange.location
        let location = contentManager.offset(
            from: documentStart, to: range.location
        )
        let end = contentManager.offset(
            from: documentStart, to: range.endLocation
        )
        return NSRange(location: location, length: max(0, end - location))
    }

    static func invalidate(
        _ range: NSRange,
        in layoutManager: NSTextLayoutManager?
    ) {
        guard range.length > 0, let layoutManager,
              let textRange = textRange(for: range, in: layoutManager)
        else { return }
        layoutManager.invalidateRenderingAttributes(for: textRange)
        layoutManager.textViewportLayoutController.layoutViewport()
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

final class MarkdownEditorScrollView: NSScrollView {
    override func layout() {
        super.layout()
        guard let textView = documentView as? MarkdownTextView else { return }
        textView.updateScrollPastEndPadding(
            viewportHeight: contentView.bounds.height
        )
        textView.layoutMarkdownTitle()
        textView.markdownDidLayout?()
    }
}

final class MarkdownTextView: NSTextView {
    let markdownSyntaxCache = MarkdownSyntaxCache()
    var markdownDidBeginEditing: (() -> Void)?
    var markdownDidLayout: (() -> Void)?
    private let markdownTopInset: CGFloat = 20
    private var markdownTitleHeight: CGFloat = 0
    private var markdownTitleHost: NSHostingView<AnyView>?
    private var markdownTitle: AnyView?
    private var markdownTitleWidth: CGFloat = 0

    private var markdownTitleExtent: CGFloat {
        markdownTitleHost == nil ? 0 : markdownTitleHeight + 12
    }

    func updateMarkdownTitle(_ title: AnyView?, height: CGFloat) {
        markdownTitle = title
        if let title {
            if let markdownTitleHost {
                markdownTitleHost.rootView = AnyView(
                    title.frame(width: max(0, bounds.width - 52))
                )
            } else {
                let host = NSHostingView(rootView: AnyView(
                    title.frame(width: max(0, bounds.width - 52))
                ))
                addSubview(host)
                markdownTitleHost = host
            }
        } else {
            markdownTitleHost?.removeFromSuperview()
            markdownTitleHost = nil
        }
        markdownTitleWidth = max(0, bounds.width - 52)
        markdownTitleHeight = max(0, height)
        layoutMarkdownTitle()
        updateScrollPastEndPadding(
            viewportHeight: enclosingScrollView?.contentView.bounds.height ?? 0
        )
    }

    func layoutMarkdownTitle() {
        guard let markdownTitleHost, let markdownTitle else { return }
        let width = max(0, bounds.width - 52)
        if abs(markdownTitleWidth - width) > 0.5 {
            markdownTitleWidth = width
            markdownTitleHost.rootView = AnyView(
                markdownTitle.frame(width: width)
            )
        }
        markdownTitleHost.frame = NSRect(
            x: 26, y: markdownTopInset,
            width: width, height: markdownTitleHeight
        )
        guard width > 0 else { return }
        let measured = markdownTitleHost.fittingSize.height
        if measured.isFinite, measured > 0,
           abs(markdownTitleHeight - measured) > 0.5 {
            markdownTitleHeight = measured
            markdownTitleHost.frame.size.height = measured
            updateScrollPastEndPadding(
                viewportHeight: enclosingScrollView?.contentView.bounds.height ?? 0
            )
        }
    }

    override var textContainerOrigin: NSPoint {
        // NSTextView sizes with symmetric insets. Keep the text at its normal
        // top position so the additional sizing space stays below the note.
        var origin = super.textContainerOrigin
        origin.y = markdownTopInset + markdownTitleExtent
        return origin
    }

    func updateScrollPastEndPadding(viewportHeight: CGFloat) {
        let bottom = MarkdownEditorScrollPadding.bottom(
            for: viewportHeight
        )
        let verticalInset = max(markdownTopInset, bottom / 2)
            + markdownTitleExtent / 2
        guard textContainerInset.height != verticalInset else { return }
        let heightChange = 2 * (verticalInset - textContainerInset.height)
        textContainerInset.height = verticalInset
        // An inset change alone does not immediately resize a TextKit 2 view.
        setFrameSize(NSSize(
            width: frame.width,
            height: max(0, frame.height + heightChange)
        ))
    }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        if let container = textContainer {
            markdownSyntaxCache.refreshTablesAfterResize(
                width: container.size.width - 2 * container.lineFragmentPadding
            )
        }
    }

    override func becomeFirstResponder() -> Bool {
        let accepted = super.becomeFirstResponder()
        if accepted { markdownDidBeginEditing?() }
        return accepted
    }

    private var reportedWindowAttachment = false

    var markdownDidAttachToWindow: (() -> Void)? {
        didSet { reportWindowAttachmentIfNeeded() }
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        reportWindowAttachmentIfNeeded()
    }

    private func reportWindowAttachmentIfNeeded() {
        guard window != nil, !reportedWindowAttachment,
              let markdownDidAttachToWindow else { return }
        reportedWindowAttachment = true
        markdownDidAttachToWindow()
    }

    @discardableResult
    func performMarkdownCommand(_ command: MarkdownEditingCommand) -> Bool {
        guard isEditable, !hasMarkedText(),
              let change = MarkdownEditingRules.change(
                for: command, text: string, selection: selectedRange()
              ) else { return false }
        let expected = (string as NSString).replacingCharacters(
            in: change.range, with: change.replacement
        )
        window?.makeFirstResponder(self)
        if string.utf8.elementsEqual(expected.utf8) {
            setSelectedRange(expected.clampedSelection(change.selection))
            return true
        }
        breakUndoCoalescing()
        insertText(change.replacement, replacementRange: change.range)
        breakUndoCoalescing()
        // A synchronous commit may merge remote text and remap the selection.
        if string.utf8.elementsEqual(expected.utf8) {
            setSelectedRange(expected.clampedSelection(change.selection))
            scrollRangeToVisible(selectedRange())
        }
        return true
    }

    override func insertNewline(_ sender: Any?) {
        if !performMarkdownCommand(.continueLine) { super.insertNewline(sender) }
    }

    override func insertTab(_ sender: Any?) {
        if !performMarkdownCommand(.indent) { super.insertTab(sender) }
    }

    override func insertBacktab(_ sender: Any?) {
        if !performMarkdownCommand(.outdent) { super.insertBacktab(sender) }
    }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        guard window?.firstResponder === self else {
            return super.performKeyEquivalent(with: event)
        }
        let flags = event.modifierFlags.intersection([.command, .shift, .option, .control])
        let command: MarkdownEditingCommand?
        switch (event.charactersIgnoringModifiers?.lowercased(), flags) {
        case ("b", .command): command = .bold
        case ("i", .command): command = .italic
        case ("k", .command): command = .link
        case ("h", [.command, .shift]): command = .heading
        case ("c", [.command, .shift]): command = .inlineCode
        default: command = nil
        }
        if let command, performMarkdownCommand(command) { return true }
        return super.performKeyEquivalent(with: event)
    }

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
    var onBeginEditing: () -> Void
    var title: AnyView?
    var titleHeight: CGFloat
    var focusRequest: Int
    var fontSize: Double
    var fontFamily: EditorFontFamily
    var mode: MarkdownEditorMode

    init(
        text: Binding<String>,
        editRevision: Data? = nil,
        commitEdit: ((String, Data) throws -> MarkdownEditorCommit)? = nil,
        onEditError: ((Error) -> Void)? = nil,
        navigation: MarkdownEditorNavigation? = nil,
        onBeginEditing: @escaping () -> Void = {},
        title: AnyView? = nil,
        titleHeight: CGFloat = 0,
        focusRequest: Int = 0,
        fontSize: Double = 17,
        fontFamily: EditorFontFamily = .system,
        mode: MarkdownEditorMode = .source
    ) {
        _text = text
        self.editRevision = editRevision
        self.commitEdit = commitEdit
        self.onEditError = onEditError
        self.navigation = navigation
        self.onBeginEditing = onBeginEditing
        self.title = title
        self.titleHeight = titleHeight
        self.focusRequest = focusRequest
        self.fontSize = fontSize
        self.fontFamily = fontFamily
        self.mode = mode
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(parent: self)
    }

    func makeNSView(context: Context) -> NSScrollView {
        let scrollView = MarkdownEditorScrollView()
        let textView = MarkdownTextView(usingTextLayoutManager: true)

        scrollView.hasVerticalScroller = true
        scrollView.drawsBackground = false
        scrollView.documentView = textView

        textView.delegate = context.coordinator
        textView.string = text
        textView.isRichText = false
        textView.allowsUndo = true
        textView.drawsBackground = false
        textView.font = MarkdownPresentation.bodyFont(
            for: fontFamily,
            pointSize: MarkdownPresentation.normalizedFontSize(fontSize)
        )
        textView.textColor = .textColor
        textView.textContainerInset = NSSize(width: 22, height: 20)
        textView.textContainer?.lineFragmentPadding = 4
        textView.isHorizontallyResizable = false
        textView.isVerticallyResizable = true
        textView.autoresizingMask = [.width]
        textView.textContainer?.widthTracksTextView = true
        textView.usesFindBar = true
        textView.setAccessibilityIdentifier("markdown-editor")
        MarkdownPresentation.configure(
            textView,
            fontSize: fontSize,
            fontFamily: fontFamily,
            mode: mode
        )
        context.coordinator.observeUndoAndRedo(for: textView)

        context.coordinator.attachNavigation(to: textView)
        textView.updateMarkdownTitle(title, height: titleHeight)
        return scrollView
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        guard let textView = scrollView.documentView as? NSTextView else {
            return
        }
        context.coordinator.update(parent: self, textView: textView)
        (textView as? MarkdownTextView)?.updateMarkdownTitle(
            title, height: titleHeight
        )
        context.coordinator.consumeFocusRequest(
            focusRequest, in: textView
        )
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
        private var displayedFontFamily: EditorFontFamily
        private var displayedMode: MarkdownEditorMode
        private var presentationRefreshScheduled = false
        private var pendingPosition: MarkdownEditorPosition?
        private var positionRestoreScheduled = false
        private var positionRestoreGeneration = 0
        private var pendingSearchMatch: NSRange?
        private var destinationHighlightRange: NSRange?
        private var destinationCenterGeometry: CGSize?
        private var handledFocusRequest: Int

        init(parent: MarkdownEditor) {
            self.parent = parent
            handledFocusRequest = parent.focusRequest
            displayedText = parent.text
            displayedMode = parent.mode
            displayedFontFamily = parent.fontFamily
            displayedRevision = parent.editRevision
            displayedFontSize = MarkdownPresentation.normalizedFontSize(
                parent.fontSize
            )
        }

        func consumeFocusRequest(_ request: Int, in textView: NSTextView) {
            guard request != handledFocusRequest else { return }
            handledFocusRequest = request
            // The host has received the nonediting title in this update.
            DispatchQueue.main.async { [weak textView] in
                guard let textView, textView.isEditable else { return }
                textView.window?.makeFirstResponder(textView)
            }
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

        func attachNavigation(to textView: MarkdownTextView) {
            installDestinationHighlightRendering(in: textView)
            textView.markdownDidBeginEditing = { [weak self] in
                self?.positionRestoreGeneration &+= 1
                self?.pendingPosition = nil
                self?.parent.onBeginEditing()
            }
            textView.markdownDidLayout = { [weak self, weak textView] in
                guard let self, let textView else { return }
                self.centerDestinationIfGeometryChanged(in: textView)
            }
            let navigation = parent.navigation
            parent.navigation?.prepareToLeave = { [weak self, weak textView] in
                guard let self, let textView else { return true }
                guard !textView.hasMarkedText() else { return false }
                self.synchronizeBinding(from: textView)
                guard !self.hasUncommittedText else { return false }
                textView.isEditable = false
                return true
            }
            parent.navigation?.performCommand = { [weak textView] command in
                _ = (textView as? MarkdownTextView)?
                    .performMarkdownCommand(command)
            }
            parent.navigation?.resumeEditing = { [weak textView] in
                textView?.isEditable = true
            }
            parent.navigation?.focusEditor = { [weak textView] in
                guard let textView, textView.isEditable else { return }
                if let window = textView.window,
                   window.makeFirstResponder(textView) { return }
                DispatchQueue.main.async { [weak textView] in
                    guard let textView, textView.isEditable else { return }
                    textView.window?.makeFirstResponder(textView)
                }
            }
            parent.navigation?.captureHasEditingFocus = { [weak textView] in
                guard let textView else { return false }
                return textView.window?.firstResponder === textView
            }
            parent.navigation?.showFind = { [weak self, weak textView] in
                guard let self, let textView else { return }
                self.clearDestinationHighlight(in: textView)
                let sender = NSMenuItem()
                sender.tag = NSTextFinder.Action.showFindInterface.rawValue
                textView.performFindPanelAction(sender)
            }
            parent.navigation?.revealSearchMatch = {
                [weak self, weak textView] range in
                guard let self, let textView else { return }
                self.scheduleSearchMatchReveal(range, in: textView)
            }
            parent.navigation?.capturePosition = { [weak self, weak textView] in
                guard let self, let textView else { return nil }
                return self.capturePosition(in: textView)
            }
            parent.navigation?.restorePosition = {
                [weak self, weak textView] position in
                guard let self, let textView else { return }
                self.schedulePositionRestore(position, in: textView)
            }
            textView.markdownDidAttachToWindow = { [weak navigation] in
                navigation?.didAttach()
            }
        }

        func update(parent: MarkdownEditor, textView: NSTextView) {
            self.parent = parent
            guard !textView.hasMarkedText() else { return }

            let fontSize = MarkdownPresentation.normalizedFontSize(
                parent.fontSize
            )
            if displayedFontSize != fontSize
                || displayedFontFamily != parent.fontFamily
                || displayedMode != parent.mode {
                displayedMode = parent.mode
                displayedFontSize = fontSize
                displayedFontFamily = parent.fontFamily
                schedulePresentationRefresh(for: textView)
            }
            guard !hasUncommittedText else { return }

            if parent.commitEdit != nil, let revision = parent.editRevision,
               revision == displayedRevision {
                // A local commit or an earlier replacement already installed
                // this state. Avoid scanning the entire native/model buffer.
                acceptParentRevision(revision)
                schedulePendingSearchMatchReveal(in: textView)
                schedulePendingPositionRestore(in: textView)
                return
            }

            if textView.string.utf8.elementsEqual(parent.text.utf8) {
                displayedText = textView.string
                acceptParentRevision(parent.editRevision)
                schedulePendingSearchMatchReveal(in: textView)
                schedulePendingPositionRestore(in: textView)
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
            schedulePendingSearchMatchReveal(in: textView)
            schedulePendingPositionRestore(in: textView)
        }

        @objc private func undoManagerDidChange(_ notification: Notification) {
            guard let textView = observedTextView,
                  let undoManager = notification.object as? UndoManager,
                  undoManager === textView.undoManager else {
                return
            }
            synchronizeBinding(from: textView)
        }

        func textViewDidChangeSelection(_ notification: Notification) {
            guard !isUpdating,
                  let textView = notification.object as? NSTextView else {
                return
            }
            if parent.mode == .livePreview {
                schedulePresentationRefresh(for: textView)
            }
            schedulePendingSearchMatchReveal(in: textView)
            schedulePendingPositionRestore(in: textView)
        }

        func textDidChange(_ notification: Notification) {
            guard let textView = notification.object as? NSTextView else {
                return
            }
            clearDestinationHighlight(in: textView)
            synchronizeBinding(from: textView)
            schedulePendingSearchMatchReveal(in: textView)
            schedulePendingPositionRestore(in: textView)
        }

        private func scheduleSearchMatchReveal(
            _ range: NSRange,
            in textView: NSTextView
        ) {
            positionRestoreGeneration &+= 1
            pendingPosition = nil
            parent.navigation?.searchLandingPosition = nil
            pendingSearchMatch = range
            schedulePendingSearchMatchReveal(in: textView)
        }

        private func schedulePendingSearchMatchReveal(
            in textView: NSTextView
        ) {
            guard !textView.hasMarkedText(),
                  let range = pendingSearchMatch else { return }
            pendingSearchMatch = nil
            let selection = textView.string.clampedSelection(range)
            if textView.window?.firstResponder === textView {
                textView.window?.makeFirstResponder(nil)
            }
            textView.setSelectedRange(selection)
            textView.scrollRangeToVisible(selection)
            setDestinationHighlight(selection, in: textView)
            centerDestination(selection, in: textView)
        }

        private func installDestinationHighlightRendering(
            in textView: NSTextView
        ) {
            guard let layoutManager = textView.textLayoutManager else { return }
            let baseValidator = layoutManager.renderingAttributesValidator
            layoutManager.renderingAttributesValidator = {
                [weak self] manager, fragment in
                baseValidator?(manager, fragment)
                self?.applyDestinationHighlight(
                    to: manager, fragment: fragment
                )
            }
        }

        private func applyDestinationHighlight(
            to layoutManager: NSTextLayoutManager,
            fragment: NSTextLayoutFragment
        ) {
            guard let highlight = destinationHighlightRange,
                  highlight.length > 0,
                  let fragmentRange = MarkdownEditorDestinationHighlight
                    .nsRange(for: fragment.rangeInElement, in: layoutManager)
            else { return }
            let intersection = NSIntersectionRange(highlight, fragmentRange)
            guard intersection.length > 0,
                  let textRange = MarkdownEditorDestinationHighlight.textRange(
                    for: intersection, in: layoutManager
                  ) else { return }
            layoutManager.addRenderingAttribute(
                .backgroundColor,
                value: NSColor.systemYellow.withAlphaComponent(0.45),
                for: textRange
            )
        }

        private func setDestinationHighlight(
            _ range: NSRange,
            in textView: NSTextView
        ) {
            clearDestinationHighlight(in: textView)
            guard range.length > 0 else { return }
            destinationHighlightRange = range
            destinationCenterGeometry = nil
            if let layoutManager = textView.textLayoutManager,
               let textRange = MarkdownEditorDestinationHighlight.textRange(
                for: range, in: layoutManager
               ) {
                layoutManager.addRenderingAttribute(
                    .backgroundColor,
                    value: NSColor.systemYellow.withAlphaComponent(0.45),
                    for: textRange
                )
            }
            textView.needsDisplay = true
        }

        private func clearDestinationHighlight(in textView: NSTextView) {
            guard let range = destinationHighlightRange else {
                destinationCenterGeometry = nil
                parent.navigation?.searchLandingPosition = nil
                return
            }
            destinationHighlightRange = nil
            destinationCenterGeometry = nil
            parent.navigation?.searchLandingPosition = nil
            MarkdownEditorDestinationHighlight.invalidate(
                range, in: textView.textLayoutManager
            )
            textView.needsDisplay = true
        }

        private func centerDestinationIfGeometryChanged(
            in textView: NSTextView
        ) {
            guard let range = destinationHighlightRange,
                  let scrollView = textView.enclosingScrollView,
                  destinationCenterGeometry != scrollView.contentView.bounds.size
            else { return }
            centerDestination(range, in: textView)
        }

        private func centerDestination(
            _ range: NSRange,
            in textView: NSTextView
        ) {
            guard let scrollView = textView.enclosingScrollView else { return }
            layoutViewport(in: textView)
            guard let targetRect = localCaretRect(
                at: range.location, in: textView
            ) else { return }
            let clipView = scrollView.contentView
            destinationCenterGeometry = clipView.bounds.size
            let minimumY = textView.bounds.minY
            let maximumY = max(
                minimumY, textView.bounds.maxY - clipView.bounds.height
            )
            let targetY = min(
                maximumY,
                max(minimumY, targetRect.midY - clipView.bounds.height / 2)
            )
            if abs(clipView.bounds.minY - targetY) > 0.5 {
                clipView.scroll(to: NSPoint(x: clipView.bounds.minX, y: targetY))
                scrollView.reflectScrolledClipView(clipView)
            }
            parent.navigation?.searchLandingPosition = capturePosition(
                in: textView
            )
        }

        private func capturePosition(
            in textView: NSTextView
        ) -> MarkdownEditorPosition? {
            guard !textView.hasMarkedText() else { return nil }
            layoutViewport(in: textView)
            let source = textView.string
            let selection = source.clampedSelection(textView.selectedRange())
            let visibleRect = textView.visibleRect
            let point = NSPoint(
                x: visibleRect.minX + textView.textContainerInset.width + 1,
                y: visibleRect.minY + 1
            )
            let rawAnchor = textView.characterIndexForInsertion(at: point)
            let anchor = source.clampedSelection(
                NSRange(location: rawAnchor, length: 0)
            ).location
            let offset = localCaretRect(at: anchor, in: textView)
                .map { Double($0.minY - visibleRect.minY) } ?? 0
            return MarkdownEditorPosition(
                selection: selection,
                scrollAnchor: anchor,
                scrollAnchorOffset: offset.isFinite ? offset : 0
            )
        }

        private func schedulePositionRestore(
            _ position: MarkdownEditorPosition,
            in textView: NSTextView
        ) {
            positionRestoreGeneration &+= 1
            pendingPosition = position
            schedulePendingPositionRestore(in: textView)
        }

        private func schedulePendingPositionRestore(in textView: NSTextView) {
            guard pendingPosition != nil, !positionRestoreScheduled else {
                return
            }
            positionRestoreScheduled = true
            DispatchQueue.main.async { [weak self, weak textView] in
                guard let self else { return }
                self.positionRestoreScheduled = false
                guard let textView, !textView.hasMarkedText(),
                      let position = self.pendingPosition else { return }
                self.pendingPosition = nil
                self.restore(position, in: textView)
            }
        }

        private func restore(
            _ position: MarkdownEditorPosition,
            in textView: NSTextView
        ) {
            let source = textView.string
            let selection = source.clampedSelection(position.selection)
            let anchor = source.clampedSelection(
                NSRange(location: position.scrollAnchor, length: 0)
            ).location

            textView.layoutSubtreeIfNeeded()
            textView.setSelectedRange(selection)
            textView.scrollRangeToVisible(
                NSRange(location: anchor, length: 0)
            )
            layoutViewport(in: textView)

            let generation = positionRestoreGeneration
            DispatchQueue.main.async { [weak self, weak textView] in
                guard let self, let textView else { return }
                self.finishRestore(
                    position, generation: generation, attemptsRemaining: 2,
                    in: textView
                )
            }
        }

        private func finishRestore(
            _ position: MarkdownEditorPosition,
            generation: Int,
            attemptsRemaining: Int,
            in textView: NSTextView
        ) {
            guard generation == positionRestoreGeneration else { return }
            guard !textView.hasMarkedText() else {
                pendingPosition = position
                return
            }
            layoutViewport(in: textView)
            let anchor = textView.string.clampedSelection(
                NSRange(location: position.scrollAnchor, length: 0)
            ).location
            guard let scrollView = textView.enclosingScrollView,
                  let anchorRect = localCaretRect(at: anchor, in: textView)
            else { return }
            let clipView = scrollView.contentView
            let offset = position.scrollAnchorOffset.isFinite
                ? CGFloat(position.scrollAnchorOffset) : 0
            let minimumY = textView.bounds.minY
            let maximumY = max(
                minimumY, textView.bounds.maxY - clipView.bounds.height
            )
            let targetY = min(maximumY, max(minimumY, anchorRect.minY - offset))
            if abs(clipView.bounds.minY - targetY) <= 0.5 { return }
            clipView.scroll(to: NSPoint(x: clipView.bounds.minX, y: targetY))
            scrollView.reflectScrolledClipView(clipView)
            // Layout after scrolling can replace estimated fragment positions.
            // Check again on the next layout turn, with a strict attempt limit.
            guard attemptsRemaining > 0 else { return }
            DispatchQueue.main.async { [weak self, weak textView] in
                guard let self, let textView else { return }
                self.finishRestore(
                    position, generation: generation,
                    attemptsRemaining: attemptsRemaining - 1, in: textView
                )
            }
        }

        private func layoutViewport(in textView: NSTextView) {
            textView.layoutSubtreeIfNeeded()
            textView.textLayoutManager?.textViewportLayoutController
                .layoutViewport()
            textView.layoutSubtreeIfNeeded()
        }

        private func localCaretRect(
            at location: Int,
            in textView: NSTextView
        ) -> NSRect? {
            guard let layoutManager = textView.textLayoutManager,
                  let contentManager = layoutManager.textContentManager,
                  let start = contentManager.location(
                      contentManager.documentRange.location, offsetBy: location
                  ), let range = NSTextRange(location: start, end: start)
            else { return nil }
            // Query the anchor itself. NSTextView's input-method rectangle
            // can describe the active selection instead of an offscreen range.
            layoutManager.ensureLayout(for: range)
            var caretRect: NSRect?
            layoutManager.enumerateTextSegments(
                in: range, type: .selection, options: [.rangeNotRequired]
            ) { _, frame, _, _ in
                if frame.minY.isFinite, !frame.isNull {
                    caretRect = frame.offsetBy(
                        dx: textView.textContainerOrigin.x,
                        dy: textView.textContainerOrigin.y
                    )
                }
                return false
            }
            return caretRect
        }

        private func synchronizeBinding(from textView: NSTextView) {
            guard !isUpdating, !textView.hasMarkedText() else { return }
            guard let storage = textView.textStorage else { return }
            let nativeText = MarkdownPresentation.syntaxCache(for: textView)
                .textSnapshot(in: storage)
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
                    schedulePresentationRefresh(for: textView)
                } else {
                    replaceDisplayedText(
                        with: commit.text,
                        revision: commit.revision,
                        in: textView
                    )
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
                    fontSize: self.parent.fontSize,
                    fontFamily: self.parent.fontFamily,
                    mode: self.parent.mode
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
            clearDestinationHighlight(in: textView)
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
                fontSize: parent.fontSize,
                fontFamily: parent.fontFamily,
                mode: parent.mode
            )
        }

        func textDidBeginEditing(_ notification: Notification) {
            guard let textView = notification.object as? NSTextView else { return }
            schedulePresentationRefresh(for: textView)
        }

        func textDidEndEditing(_ notification: Notification) {
            guard let textView = notification.object as? NSTextView else {
                return
            }
            MarkdownPresentation.refresh(
                textView,
                fontSize: parent.fontSize,
                fontFamily: parent.fontFamily,
                mode: parent.mode
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
    override func layoutSubviews() {
        super.layoutSubviews()
        // Scroll-past-end space belongs to the document. A content inset
        // also reduces UIKit's caret-reveal viewport, which can become
        // smaller than that inset as the keyboard appears.
        let bottom = 18 + MarkdownEditorScrollPadding.bottom(
            for: bounds.height
        )
        var insets = textContainerInset
        let titleExtent = markdownState.titleHost == nil
            ? 0 : markdownState.titleHeight + 12
        if insets.top != 18 + titleExtent || insets.bottom != bottom {
            insets.top = 18 + titleExtent
            insets.bottom = bottom
            textContainerInset = insets
        }
        layoutMarkdownTitle()
        markdownSyntaxCache.refreshTablesAfterResize(
            width: textContainer.size.width - 2 * textContainer.lineFragmentPadding
        )
        markdownState.didLayout?()
    }

    func updateMarkdownTitle(_ title: AnyView?, height: CGFloat) {
        if let title {
            if let host = markdownState.titleHost {
                host.rootView = title
            } else {
                let host = UIHostingController(rootView: title)
                host.view.backgroundColor = .clear
                addSubview(host.view)
                markdownState.titleHost = host
            }
        } else {
            markdownState.titleHost?.view.removeFromSuperview()
            markdownState.titleHost = nil
        }
        markdownState.titleHeight = max(0, height)
        measureMarkdownTitle()
        setNeedsLayout()
    }

    private func layoutMarkdownTitle() {
        guard let host = markdownState.titleHost else { return }
        measureMarkdownTitle()
        host.view.frame = CGRect(
            x: 20, y: 18,
            width: max(0, bounds.width - 40),
            height: markdownState.titleHeight
        )
    }

    private func measureMarkdownTitle() {
        guard let host = markdownState.titleHost else { return }
        let width = max(0, bounds.width - 40)
        guard width > 0 else { return }
        let measured = host.sizeThatFits(
            in: CGSize(width: width, height: .greatestFiniteMagnitude)
        ).height
        if measured.isFinite, measured > 0,
           abs(markdownState.titleHeight - measured) > 0.5 {
            markdownState.titleHeight = measured
        }
    }

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

    var markdownDidAttachToWindow: (() -> Void)? {
        get { markdownState.didAttachToWindow }
        set {
            markdownState.didAttachToWindow = newValue
            reportWindowAttachmentIfNeeded()
        }
    }

    var markdownDidLayout: (() -> Void)? {
        get { markdownState.didLayout }
        set { markdownState.didLayout = newValue }
    }

    override func didMoveToWindow() {
        super.didMoveToWindow()
        reportWindowAttachmentIfNeeded()
    }

    private func reportWindowAttachmentIfNeeded() {
        guard window != nil, !markdownState.reportedWindowAttachment,
              let didAttachToWindow = markdownState.didAttachToWindow else {
            return
        }
        markdownState.reportedWindowAttachment = true
        didAttachToWindow()
    }

    @discardableResult
    func performMarkdownCommand(_ command: MarkdownEditingCommand) -> Bool {
        guard isEditable, markedTextRange == nil,
              !markdownState.isApplyingCommand,
              let change = MarkdownEditingRules.change(
                for: command, text: text ?? "", selection: selectedRange
              ) else { return false }
        let expected = ((text ?? "") as NSString).replacingCharacters(
            in: change.range, with: change.replacement
        )
        becomeFirstResponder()
        if (text ?? "").utf8.elementsEqual(expected.utf8) {
            selectedRange = expected.clampedSelection(change.selection)
            return true
        }
        markdownState.isApplyingCommand = true
        defer { markdownState.isApplyingCommand = false }
        selectedRange = change.range
        super.insertText(change.replacement)
        if (text ?? "").utf8.elementsEqual(expected.utf8) {
            selectedRange = expected.clampedSelection(change.selection)
            scrollRangeToVisible(selectedRange)
        }
        // UIKit programmatic insertion does not consistently notify delegates.
        delegate?.textViewDidChange?(self)
        return true
    }

    override func insertText(_ text: String) {
        if !markdownState.isApplyingCommand, !markdownState.isPasting {
            let command: MarkdownEditingCommand? = text == "\n"
                ? .continueLine : (text == "\t" ? .indent : nil)
            if let command, performMarkdownCommand(command) { return }
        }
        super.insertText(text)
    }

    override func paste(_ sender: Any?) {
        markdownState.isPasting = true
        defer { markdownState.isPasting = false }
        super.paste(sender)
    }

    override var keyCommands: [UIKeyCommand]? {
        let commands: [(String, UIKeyModifierFlags, Selector)] = [
            ("\t", [], #selector(indentMarkdown)),
            ("\t", .shift, #selector(outdentMarkdown)),
            ("b", .command, #selector(boldMarkdown)),
            ("i", .command, #selector(italicMarkdown)),
            ("k", .command, #selector(linkMarkdown)),
            ("h", [.command, .shift], #selector(headingMarkdown)),
            ("c", [.command, .shift], #selector(codeMarkdown)),
        ]
        return (super.keyCommands ?? []) + commands.map { input, flags, action in
            let key = UIKeyCommand(input: input, modifierFlags: flags, action: action)
            key.wantsPriorityOverSystemBehavior = true
            return key
        }
    }

    @objc private func indentMarkdown() {
        if !performMarkdownCommand(.indent) { insertText("\t") }
    }
    @objc private func outdentMarkdown() { _ = performMarkdownCommand(.outdent) }
    @objc private func boldMarkdown() { _ = performMarkdownCommand(.bold) }
    @objc private func italicMarkdown() { _ = performMarkdownCommand(.italic) }
    @objc private func linkMarkdown() { _ = performMarkdownCommand(.link) }
    @objc private func headingMarkdown() { _ = performMarkdownCommand(.heading) }
    @objc private func codeMarkdown() { _ = performMarkdownCommand(.inlineCode) }

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
    var isApplyingCommand = false
    var isPasting = false
    var reportedWindowAttachment = false
    var didAttachToWindow: (() -> Void)?
    var didLayout: (() -> Void)?
    let syntaxCache = MarkdownSyntaxCache()
    var layoutDelegate: MarkdownLayoutManagerDelegate?
    var titleHost: UIHostingController<AnyView>?
    var titleHeight: CGFloat = 0
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
    var onBeginEditing: () -> Void
    var title: AnyView?
    var titleHeight: CGFloat
    var focusRequest: Int
    var fontSize: Double
    var fontFamily: EditorFontFamily
    var mode: MarkdownEditorMode

    init(
        text: Binding<String>,
        editRevision: Data? = nil,
        commitEdit: ((String, Data) throws -> MarkdownEditorCommit)? = nil,
        onEditError: ((Error) -> Void)? = nil,
        navigation: MarkdownEditorNavigation? = nil,
        onBeginEditing: @escaping () -> Void = {},
        title: AnyView? = nil,
        titleHeight: CGFloat = 0,
        focusRequest: Int = 0,
        fontSize: Double = 17,
        fontFamily: EditorFontFamily = .system,
        mode: MarkdownEditorMode = .source
    ) {
        _text = text
        self.editRevision = editRevision
        self.commitEdit = commitEdit
        self.onEditError = onEditError
        self.navigation = navigation
        self.onBeginEditing = onBeginEditing
        self.title = title
        self.titleHeight = titleHeight
        self.focusRequest = focusRequest
        self.fontSize = fontSize
        self.fontFamily = fontFamily
        self.mode = mode
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
        textView.installMarkdownKeyboardToolbar()
        textView.isFindInteractionEnabled = true
        textView.keyboardDismissMode = UIDevice.current.userInterfaceIdiom == .pad
            ? .none : .interactive
        textView.alwaysBounceVertical = true
        textView.topEdgeEffect.isHidden =
            UIDevice.current.userInterfaceIdiom == .pad
        textView.text = text
        textView.allowsEditingTextAttributes = false
        textView.font = MarkdownPresentation.bodyFont(
            for: fontFamily,
            pointSize: MarkdownPresentation.normalizedFontSize(fontSize)
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
        MarkdownPresentation.configure(
            textView,
            fontSize: fontSize,
            fontFamily: fontFamily,
            mode: mode
        )

        context.coordinator.attachNavigation(to: textView)
        textView.updateMarkdownTitle(title, height: titleHeight)
        return textView
    }

    func updateUIView(_ textView: UITextView, context: Context) {
        context.coordinator.update(parent: self, textView: textView)
        (textView as? MarkdownTextView)?.updateMarkdownTitle(
            title, height: titleHeight
        )
        context.coordinator.consumeFocusRequest(
            focusRequest, in: textView
        )
    }

    final class Coordinator: NSObject, UITextViewDelegate {
        var parent: MarkdownEditor
        private var displayedText: String
        private var displayedRevision: Data?
        private var staleParentRevision: Data?
        private var hasUncommittedText = false
        private var isUpdating = false
        private var displayedFontSize: CGFloat
        private var handledFocusRequest: Int
        private var displayedFontFamily: EditorFontFamily
        private var displayedMode: MarkdownEditorMode
        private var presentationRefreshScheduled = false
        private var pendingPosition: MarkdownEditorPosition?
        private var positionRestoreScheduled = false
        private var positionRestoreGeneration = 0
        private var pendingSearchMatch: NSRange?
        private var destinationHighlightRange: NSRange?
        private var destinationCenterGeometry: DestinationCenterGeometry?

        private struct DestinationCenterGeometry: Equatable {
            let size: CGSize
            let adjustedInset: UIEdgeInsets
            let textContainerInset: UIEdgeInsets
        }

        func scrollViewWillBeginDragging(_ scrollView: UIScrollView) {
            positionRestoreGeneration &+= 1
            pendingPosition = nil
        }

        init(parent: MarkdownEditor) {
            self.parent = parent
            handledFocusRequest = parent.focusRequest
            displayedText = parent.text
            displayedMode = parent.mode
            displayedFontFamily = parent.fontFamily
            displayedRevision = parent.editRevision
            displayedFontSize = MarkdownPresentation.normalizedFontSize(
                parent.fontSize
            )
        }

        func consumeFocusRequest(_ request: Int, in textView: UITextView) {
            guard request != handledFocusRequest else { return }
            handledFocusRequest = request
            // Wait for the hosting controller to remove the title text field.
            DispatchQueue.main.async { [weak textView] in
                guard let textView, textView.isEditable else { return }
                _ = textView.becomeFirstResponder()
            }
        }

        func attachNavigation(to textView: MarkdownTextView) {
            installDestinationHighlightRendering(in: textView)
            textView.markdownDidLayout = { [weak self, weak textView] in
                guard let self, let textView else { return }
                self.centerDestinationIfGeometryChanged(in: textView)
            }
            let navigation = parent.navigation
            parent.navigation?.prepareToLeave = { [weak self, weak textView] in
                guard let self, let textView else { return true }
                guard textView.markedTextRange == nil else { return false }
                self.textViewDidChange(textView)
                guard !self.hasUncommittedText else { return false }
                textView.isEditable = false
                return true
            }
            parent.navigation?.performCommand = { [weak textView] command in
                _ = (textView as? MarkdownTextView)?
                    .performMarkdownCommand(command)
            }
            parent.navigation?.resumeEditing = { [weak textView] in
                textView?.isEditable = true
            }
            parent.navigation?.focusEditor = { [weak textView] in
                guard let textView, textView.isEditable else { return }
                if !textView.becomeFirstResponder() {
                    DispatchQueue.main.async { [weak textView] in
                        guard let textView, textView.isEditable else { return }
                        _ = textView.becomeFirstResponder()
                    }
                }
            }
            parent.navigation?.captureHasEditingFocus = { [weak textView] in
                textView?.isFirstResponder == true
            }
            parent.navigation?.showFind = { [weak self, weak textView] in
                guard let self, let textView else { return }
                self.clearDestinationHighlight(in: textView)
                // The find navigator owns keyboard input while it is visible.
                // Resigning first removes the Markdown writing accessory.
                _ = textView.resignFirstResponder()
                textView.findInteraction?.presentFindNavigator(
                    showingReplace: false
                )
            }
            parent.navigation?.revealSearchMatch = {
                [weak self, weak textView] range in
                guard let self, let textView else { return }
                self.scheduleSearchMatchReveal(range, in: textView)
            }
            parent.navigation?.capturePosition = { [weak self, weak textView] in
                guard let self, let textView else { return nil }
                return self.capturePosition(in: textView)
            }
            parent.navigation?.restorePosition = {
                [weak self, weak textView] position in
                guard let self, let textView else { return }
                self.schedulePositionRestore(position, in: textView)
            }
            textView.markdownDidAttachToWindow = { [weak navigation] in
                navigation?.didAttach()
            }
        }

        func update(parent: MarkdownEditor, textView: UITextView) {
            self.parent = parent
            guard textView.markedTextRange == nil else { return }

            let fontSize = MarkdownPresentation.normalizedFontSize(
                parent.fontSize
            )
            if displayedFontSize != fontSize
                || displayedFontFamily != parent.fontFamily
                || displayedMode != parent.mode {
                displayedMode = parent.mode
                displayedFontSize = fontSize
                displayedFontFamily = parent.fontFamily
                schedulePresentationRefresh(for: textView)
            }
            guard !hasUncommittedText else { return }

            if parent.commitEdit != nil, let revision = parent.editRevision,
               revision == displayedRevision {
                // A local commit or an earlier replacement already installed
                // this state. Avoid scanning the entire native/model buffer.
                acceptParentRevision(revision)
                schedulePendingSearchMatchReveal(in: textView)
                schedulePendingPositionRestore(in: textView)
                return
            }

            if textView.text.utf8.elementsEqual(parent.text.utf8) {
                displayedText = textView.text
                acceptParentRevision(parent.editRevision)
                schedulePendingSearchMatchReveal(in: textView)
                schedulePendingPositionRestore(in: textView)
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
            schedulePendingSearchMatchReveal(in: textView)
            schedulePendingPositionRestore(in: textView)
        }

        func textViewDidChangeSelection(_ textView: UITextView) {
            guard !isUpdating else { return }
            if parent.mode == .livePreview {
                schedulePresentationRefresh(for: textView)
            }
            schedulePendingSearchMatchReveal(in: textView)
            schedulePendingPositionRestore(in: textView)
        }

        func textViewDidChange(_ textView: UITextView) {
            guard !isUpdating, textView.markedTextRange == nil else { return }
            clearDestinationHighlight(in: textView)
            defer {
                schedulePendingSearchMatchReveal(in: textView)
                schedulePendingPositionRestore(in: textView)
            }
            let nativeText = MarkdownPresentation.syntaxCache(for: textView)
                .textSnapshot(in: textView.textStorage)
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
                    schedulePresentationRefresh(for: textView)
                } else {
                    replaceDisplayedText(
                        with: commit.text,
                        revision: commit.revision,
                        in: textView
                    )
                }
            } catch {
                hasUncommittedText = true
                parent.onEditError?(error)
            }
        }

        private func scheduleSearchMatchReveal(
            _ range: NSRange,
            in textView: UITextView
        ) {
            positionRestoreGeneration &+= 1
            pendingPosition = nil
            parent.navigation?.searchLandingPosition = nil
            pendingSearchMatch = range
            schedulePendingSearchMatchReveal(in: textView)
        }

        private func schedulePendingSearchMatchReveal(
            in textView: UITextView
        ) {
            guard textView.markedTextRange == nil,
                  let range = pendingSearchMatch else { return }
            pendingSearchMatch = nil
            let selection = textView.text.clampedSelection(range)
            if textView.window?.endEditing(false) != true {
                _ = textView.resignFirstResponder()
            }
            textView.selectedRange = selection
            textView.scrollRangeToVisible(selection)
            setDestinationHighlight(selection, in: textView)
            centerDestination(selection, in: textView)
        }

        private func installDestinationHighlightRendering(
            in textView: UITextView
        ) {
            guard let layoutManager = textView.textLayoutManager else { return }
            let baseValidator = layoutManager.renderingAttributesValidator
            layoutManager.renderingAttributesValidator = {
                [weak self] manager, fragment in
                baseValidator?(manager, fragment)
                self?.applyDestinationHighlight(
                    to: manager, fragment: fragment
                )
            }
        }

        private func applyDestinationHighlight(
            to layoutManager: NSTextLayoutManager,
            fragment: NSTextLayoutFragment
        ) {
            guard let highlight = destinationHighlightRange,
                  highlight.length > 0,
                  let fragmentRange = MarkdownEditorDestinationHighlight
                    .nsRange(for: fragment.rangeInElement, in: layoutManager)
            else { return }
            let intersection = NSIntersectionRange(highlight, fragmentRange)
            guard intersection.length > 0,
                  let textRange = MarkdownEditorDestinationHighlight.textRange(
                    for: intersection, in: layoutManager
                  ) else { return }
            layoutManager.addRenderingAttribute(
                .backgroundColor,
                value: UIColor.systemYellow.withAlphaComponent(0.45),
                for: textRange
            )
        }

        private func setDestinationHighlight(
            _ range: NSRange,
            in textView: UITextView
        ) {
            clearDestinationHighlight(in: textView)
            guard range.length > 0 else { return }
            destinationHighlightRange = range
            destinationCenterGeometry = nil
            if let layoutManager = textView.textLayoutManager,
               let textRange = MarkdownEditorDestinationHighlight.textRange(
                for: range, in: layoutManager
               ) {
                layoutManager.addRenderingAttribute(
                    .backgroundColor,
                    value: UIColor.systemYellow.withAlphaComponent(0.45),
                    for: textRange
                )
            }
            textView.setNeedsDisplay()
        }

        private func clearDestinationHighlight(in textView: UITextView) {
            guard let range = destinationHighlightRange else {
                destinationCenterGeometry = nil
                parent.navigation?.searchLandingPosition = nil
                return
            }
            destinationHighlightRange = nil
            destinationCenterGeometry = nil
            parent.navigation?.searchLandingPosition = nil
            MarkdownEditorDestinationHighlight.invalidate(
                range, in: textView.textLayoutManager
            )
            textView.setNeedsDisplay()
        }

        private func centerDestinationIfGeometryChanged(
            in textView: UITextView
        ) {
            guard let range = destinationHighlightRange else { return }
            let geometry = centerGeometry(for: textView)
            guard destinationCenterGeometry != geometry else { return }
            centerDestination(range, in: textView)
        }

        private func centerDestination(
            _ range: NSRange,
            in textView: UITextView
        ) {
            textView.layoutIfNeeded()
            guard let start = textView.position(
                from: textView.beginningOfDocument,
                offset: range.location
            ) else { return }
            let targetRect = textView.caretRect(for: start)
            let inset = textView.adjustedContentInset
            let visibleHeight = max(
                0, textView.bounds.height - inset.top - inset.bottom
            )
            guard visibleHeight > 0 else { return }
            destinationCenterGeometry = centerGeometry(for: textView)
            let minimumY = -inset.top
            let maximumY = max(
                minimumY,
                textView.contentSize.height - textView.bounds.height
                    + inset.bottom
            )
            let targetY = min(
                maximumY,
                max(
                    minimumY,
                    targetRect.midY - inset.top - visibleHeight / 2
                )
            )
            if abs(textView.contentOffset.y - targetY) > 0.5 {
                textView.setContentOffset(
                    CGPoint(x: textView.contentOffset.x, y: targetY),
                    animated: false
                )
            }
            parent.navigation?.searchLandingPosition = capturePosition(
                in: textView
            )
        }

        private func centerGeometry(
            for textView: UITextView
        ) -> DestinationCenterGeometry {
            DestinationCenterGeometry(
                size: textView.bounds.size,
                adjustedInset: textView.adjustedContentInset,
                textContainerInset: textView.textContainerInset
            )
        }

        private func capturePosition(
            in textView: UITextView
        ) -> MarkdownEditorPosition? {
            guard textView.markedTextRange == nil else { return nil }
            let source = textView.text ?? ""
            let selection = source.clampedSelection(textView.selectedRange)
            let visibleBounds = textView.bounds
            let point = CGPoint(
                x: visibleBounds.minX + textView.textContainerInset.left
                    + textView.textContainer.lineFragmentPadding + 1,
                y: visibleBounds.minY + 1
            )
            let rawAnchor: Int
            if let textPosition = textView.closestPosition(to: point) {
                rawAnchor = textView.offset(
                    from: textView.beginningOfDocument,
                    to: textPosition
                )
            } else {
                rawAnchor = selection.location
            }
            let anchor = source.clampedSelection(
                NSRange(location: rawAnchor, length: 0)
            ).location
            let offset = localCaretRect(at: anchor, in: textView)
                .map { Double($0.minY - visibleBounds.minY) } ?? 0
            return MarkdownEditorPosition(
                selection: selection,
                scrollAnchor: anchor,
                scrollAnchorOffset: offset.isFinite ? offset : 0
            )
        }

        private func schedulePositionRestore(
            _ position: MarkdownEditorPosition,
            in textView: UITextView
        ) {
            positionRestoreGeneration &+= 1
            pendingPosition = position
            schedulePendingPositionRestore(in: textView)
        }

        private func schedulePendingPositionRestore(in textView: UITextView) {
            guard pendingPosition != nil, !positionRestoreScheduled else {
                return
            }
            positionRestoreScheduled = true
            DispatchQueue.main.async { [weak self, weak textView] in
                guard let self else { return }
                self.positionRestoreScheduled = false
                guard let textView, textView.markedTextRange == nil,
                      let position = self.pendingPosition else { return }
                self.pendingPosition = nil
                self.restore(
                    position,
                    generation: self.positionRestoreGeneration,
                    in: textView
                )
            }
        }

        private func restore(
            _ position: MarkdownEditorPosition,
            generation: Int,
            in textView: UITextView
        ) {
            let source = textView.text ?? ""
            let selection = source.clampedSelection(position.selection)
            let anchor = source.clampedSelection(
                NSRange(location: position.scrollAnchor, length: 0)
            ).location

            textView.layoutIfNeeded()
            if let layoutManager = textView.textLayoutManager,
               let contentManager = layoutManager.textContentManager {
                // A newly launched editor initially exposes a provisional
                // TextKit extent. Materialize the document before positioning
                // the saved anchor so clamping uses the real scroll range.
                layoutManager.ensureLayout(for: contentManager.documentRange)
            }
            textView.selectedRange = selection
            textView.scrollRangeToVisible(
                NSRange(location: anchor, length: 0)
            )
            textView.setNeedsLayout()
            textView.layoutIfNeeded()
            // TextKit 2 can expose an estimated contentSize until a scroll
            // reaches that provisional extent. Apply the offset after this
            // layout turn, then converge again if the anchor misses its saved
            // viewport coordinate as more content is materialized.
            DispatchQueue.main.async { [weak self, weak textView] in
                guard let self, let textView else { return }
                guard textView.markedTextRange == nil else {
                    guard generation == self.positionRestoreGeneration else {
                        return
                    }
                    self.pendingPosition = position
                    return
                }
                self.finishRestore(
                    position,
                    generation: generation,
                    attemptsRemaining: 2,
                    in: textView
                )
            }
        }

        private func finishRestore(
            _ position: MarkdownEditorPosition,
            generation: Int,
            attemptsRemaining: Int,
            in textView: UITextView
        ) {
            guard generation == positionRestoreGeneration else { return }
            let source = textView.text ?? ""
            let anchor = source.clampedSelection(
                NSRange(location: position.scrollAnchor, length: 0)
            ).location
            textView.layoutIfNeeded()

            guard let anchorRect = localCaretRect(at: anchor, in: textView)
            else { return }
            let offset = position.scrollAnchorOffset.isFinite
                ? CGFloat(position.scrollAnchorOffset) : 0
            let insets = textView.adjustedContentInset
            let minimumY = -insets.top
            let maximumY = max(
                minimumY,
                textView.contentSize.height - textView.bounds.height
                    + insets.bottom
            )
            let desiredY = anchorRect.minY - offset
            textView.setContentOffset(
                CGPoint(
                    x: textView.contentOffset.x,
                    y: min(maximumY, max(minimumY, desiredY))
                ),
                animated: false
            )
            let restoredOffset = anchorRect.minY - textView.bounds.minY
            guard attemptsRemaining > 0,
                  abs(restoredOffset - offset) > 1 else { return }
            textView.setNeedsLayout()
            DispatchQueue.main.async { [weak self, weak textView] in
                guard let self, let textView,
                      generation == self.positionRestoreGeneration else {
                    return
                }
                guard textView.markedTextRange == nil else {
                    self.pendingPosition = position
                    return
                }
                textView.layoutIfNeeded()
                self.finishRestore(
                    position,
                    generation: generation,
                    attemptsRemaining: attemptsRemaining - 1,
                    in: textView
                )
            }
        }

        private func localCaretRect(
            at location: Int,
            in textView: UITextView
        ) -> CGRect? {
            guard let position = textView.position(
                from: textView.beginningOfDocument,
                offset: location
            ) else { return nil }
            let rect = textView.caretRect(for: position)
            guard rect.minX.isFinite, rect.minY.isFinite else { return nil }
            return rect
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
                    fontSize: self.parent.fontSize,
                    fontFamily: self.parent.fontFamily,
                    mode: self.parent.mode
                )
            }
        }

        private func replaceDisplayedText(
            with newText: String,
            revision: Data?,
            in textView: UITextView
        ) {
            clearDestinationHighlight(in: textView)
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
                fontSize: parent.fontSize,
                fontFamily: parent.fontFamily,
                mode: parent.mode
            )
        }

        func textViewDidBeginEditing(_ textView: UITextView) {
            parent.onBeginEditing()
            positionRestoreGeneration &+= 1
            pendingPosition = nil
            schedulePresentationRefresh(for: textView)
        }

        func textViewDidEndEditing(_ textView: UITextView) {
            MarkdownPresentation.refresh(
                textView,
                fontSize: parent.fontSize,
                fontFamily: parent.fontFamily,
                mode: parent.mode
            )
        }
    }
}
#endif
