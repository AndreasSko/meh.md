import SwiftUI
import NoteCore

enum MarkdownEditorScrollPadding {
    static func bottom(for viewportHeight: CGFloat) -> CGFloat {
        max(0, viewportHeight / 2)
    }
}

@Observable
@MainActor
final class MarkdownEditorFindPresentation {
    var isVisible = false
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
    var prepareCommand: ((MarkdownEditingCommand) -> (() -> Void)?)?
    var prepareSnippetInsertion: (() -> ((String) -> Bool)?)?
    let snippetMenu = EditorSnippetMenuState()
    var insertSnippet: ((UUID) -> Void)?
    let tableCommands = MarkdownTableCommandState()
    let findPresentation = MarkdownEditorFindPresentation()
    var showFind: (() -> Void)?
    var openLink: ((NotebookLinkOccurrence) -> Void)? {
        didSet { linkActivationChanged?() }
    }
    var linkActivationChanged: (() -> Void)?
    var requestLink: ((String, NSRange) -> Void)?
    var selectionChanged: ((String, NSRange, Bool) -> Void)?
    var insertLink: ((MarkdownEditingChange, String) -> Bool)?
    var hasLinkCompletion = false
    var completionCommand: ((String) -> Bool)?
    var revealSearchMatch: ((NSRange) -> Void)?
    var searchLandingPosition: MarkdownEditorPosition?
    var capturePosition: (() -> MarkdownEditorPosition?)?
    var restorePosition: ((MarkdownEditorPosition) -> Void)?
    #if os(iOS)
    var restorePositionAndNotify: ((MarkdownEditorPosition, @escaping () -> Void) -> Void)?
    var captureViewportInsets: (() -> UIEdgeInsets?)?
    var captureViewportOriginY: (() -> CGFloat?)?
    #endif
    // A link/history visit overrides the ordinary saved position for this
    // attachment, even if SwiftUI's restoration task runs after navigation.
    var hasExplicitVisitDestination = false

    private var isAttached = false
    fileprivate(set) var isValid = true
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

extension MarkdownTextView {
    /// Capture before loading a snippet so an async result cannot edit a new
    /// note or a selection the user has moved in the meantime.
    func preparedSnippetInsertion() -> ((String) -> Bool)? {
        #if os(macOS)
        guard isEditable, !hasMarkedText(),
              !markdownCellController.isActive else { return nil }
        let source = string
        let selection = selectedRange()
        #else
        guard isEditable, markedTextRange == nil,
              !markdownState.isApplyingCommand,
              !markdownCellController.isActive else { return nil }
        let source = text ?? ""
        let selection = selectedRange
        #endif
        let navigation = markdownLinkNavigation
        let hadNavigation = navigation != nil
        return { [weak self, weak navigation] snippet in
            guard let self, (!hadNavigation || navigation != nil),
                  self.markdownLinkNavigation === navigation,
                  navigation?.isValid != false,
                  !self.markdownCellController.isActive else { return false }
            #if os(macOS)
            guard self.string.utf8.elementsEqual(source.utf8),
                  self.selectedRange() == selection else { return false }
            #else
            guard (self.text ?? "").utf8.elementsEqual(source.utf8),
                  self.selectedRange == selection,
                  !self.markdownState.isApplyingCommand else { return false }
            #endif
            let change = MarkdownEditingChange(
                range: selection, replacement: snippet,
                selection: NSRange(
                    location: selection.location + snippet.utf16.count,
                    length: 0
                )
            )
            return self.insertNoteLink(change, expected: source)
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
        textView.updateMarkdownTableScrollOverlays()
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
        if !markdownCellController.forwarding,
           undoManager?.isUndoing != true, undoManager?.isRedoing != true {
            markdownCellController.end()
        }
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

    var markdownLinkNavigation: MarkdownEditorNavigation? {
        didSet {
            oldValue?.linkActivationChanged = nil
            markdownLinkNavigation?.linkActivationChanged = { [weak self] in
                self?.refreshNoteLinkCursorRegions()
                if let self { self.window?.invalidateCursorRects(for: self) }
            }
            refreshNoteLinkCursorRegions()
            window?.invalidateCursorRects(for: self)
        }
    }

    private var noteLinkTrackingArea: NSTrackingArea?
    private var renderedLinkCursorRects: [NSRect] = []
    private var sourceLinkCursorRects: [NSRect] = []

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let noteLinkTrackingArea { removeTrackingArea(noteLinkTrackingArea) }
        let area = NSTrackingArea(rect: .zero,
            options: [.cursorUpdate, .mouseMoved, .activeInKeyWindow, .inVisibleRect],
            owner: self, userInfo: nil)
        addTrackingArea(area)
        noteLinkTrackingArea = area
        refreshNoteLinkCursorRegions()
    }

    override func resetCursorRects() {
        super.resetCursorRects()
        refreshNoteLinkCursorRegions()
    }

    private func refreshNoteLinkCursorRegions() {
        renderedLinkCursorRects = noteLinkCursorRects(modifiers: [])
        sourceLinkCursorRects = noteLinkCursorRects(modifiers: .command)
    }

    override func cursorUpdate(with event: NSEvent) {
        if !updateNoteLinkCursor(at: convert(event.locationInWindow, from: nil),
            modifiers: event.modifierFlags) {
            super.cursorUpdate(with: event)
        }
    }

    override func mouseMoved(with event: NSEvent) {
        super.mouseMoved(with: event)
        updateNoteLinkCursor(at: convert(event.locationInWindow, from: nil),
            modifiers: event.modifierFlags)
    }

    @discardableResult
    private func updateNoteLinkCursor(at point: NSPoint, modifiers: NSEvent.ModifierFlags) -> Bool {
        // Title buttons and table overlays own their own native pointer.
        guard visibleRect.contains(point),
              hitTest(convert(point, to: superview)) === self else { return false }
        let flags = modifiers.intersection([.command, .shift, .option, .control])
        let rects = flags.isEmpty ? renderedLinkCursorRects
            : (flags == .command ? sourceLinkCursorRects : [])
        if markdownLinkNavigation?.openLink != nil, !hasMarkedText(),
           rects.contains(where: { $0.contains(point) }) {
            NSCursor.pointingHand.set()
        } else { NSCursor.iBeam.set() }
        return true
    }

    override func flagsChanged(with event: NSEvent) {
        super.flagsChanged(with: event)
        window?.invalidateCursorRects(for: self)
        if let window {
            let point = convert(window.mouseLocationOutsideOfEventStream, from: nil)
            updateNoteLinkCursor(at: point, modifiers: event.modifierFlags)
        }
    }

    func noteLinkCursorRects(modifiers: NSEvent.ModifierFlags) -> [NSRect] {
        guard markdownLinkNavigation?.openLink != nil, !hasMarkedText(),
              let manager = textLayoutManager,
              let content = manager.textContentManager else { return [] }
        let flags = modifiers.intersection([.command, .shift, .option, .control])
        guard flags.isEmpty || flags == .command else { return [] }
        let source = string as NSString
        let snapshot = MarkdownLivePreview.snapshot(for: self)
        var rects: [NSRect] = []
        for link in NotebookLinkParser.parse(string) where !link.isEmbed {
            guard flags == .command || MarkdownLivePreview.conceals(
                link.range, in: source, snapshot: snapshot
            ) else { continue }
            // The pointer belongs to the visible label, including each wrapped
            // line. Hidden destinations and trailing blank space stay editable.
            let range: NSRange
            if flags == .command { range = link.range }
            else if link.kind == .markdown {
                range = NSRange(location: link.range.location + 1,
                    length: (link.label ?? "").utf16.count)
            } else if link.label != nil {
                let start = NSMaxRange(link.destinationRange) + 1
                range = NSRange(location: start, length: NSMaxRange(link.range) - 2 - start)
            } else { range = link.destinationRange }
            for frame in MarkdownPresentation.textSegmentFrames(
                for: range, layoutManager: manager, contentManager: content
            ) {
                let rect = frame.offsetBy(dx: textContainerOrigin.x,
                    dy: textContainerOrigin.y).intersection(visibleRect)
                if !rect.isNull, rect.width > 1, rect.height > 0 { rects.append(rect) }
            }
        }
        return rects
    }

    func insertNoteLink(_ change: MarkdownEditingChange, expected: String) -> Bool {
        guard isEditable, !hasMarkedText(), string == expected,
              NSMaxRange(change.range) <= (string as NSString).length else { return false }
        window?.makeFirstResponder(self)
        breakUndoCoalescing()
        insertText(change.replacement, replacementRange: change.range)
        breakUndoCoalescing()
        let updated = (expected as NSString).replacingCharacters(
            in: change.range, with: change.replacement)
        if string == updated { setSelectedRange(updated.clampedSelection(change.selection)) }
        return true
    }

    override func menu(for event: NSEvent) -> NSMenu? {
        let menu = super.menu(for: event)
        let offset = characterIndexForInsertion(at: convert(event.locationInWindow, from: nil))
        if let link = NotebookLinkParser.parse(string).first(where: {
            !$0.isEmbed && NSLocationInRange(offset, $0.range)
        }) {
            let item = NSMenuItem(title: String(localized: "Open Linked Note"),
                action: #selector(openMarkdownLink(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = link
            menu?.insertItem(item, at: 0)
        }
        return menu
    }

    @objc private func openMarkdownLink(_ sender: NSMenuItem) {
        if let link = sender.representedObject as? NotebookLinkOccurrence {
            markdownLinkNavigation?.openLink?(link)
        }
    }

    @discardableResult
    func performMarkdownCommand(_ command: MarkdownEditingCommand) -> Bool {
        if markdownCellController.isActive, !markdownCellController.forwarding {
            return markdownCellController.perform(command)
        }
        guard isEditable, !hasMarkedText() else { return false }
        if command == .link, let request = markdownLinkNavigation?.requestLink {
            request(string, selectedRange())
            return true
        }
        let syntaxResult = command == .toggleTask
            ? markdownSyntaxCache.result(for: string) : nil
        guard let change = MarkdownEditingRules.change(
            for: command, text: string, selection: selectedRange(),
            syntaxResult: syntaxResult
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

    func toggleMarkdownTask(at location: Int) {
        guard isEditable, !hasMarkedText() else { return }
        let syntaxResult = markdownSyntaxCache.result(for: string)
        guard let change = MarkdownEditingRules.toggleTask(
            text: string, at: location, syntaxResult: syntaxResult
        ) else { return }
        let selection = selectedRange()
        breakUndoCoalescing()
        insertText(change.replacement, replacementRange: change.range)
        breakUndoCoalescing()
        setSelectedRange(string.clampedSelection(selection))
    }

    override func mouseDown(with event: NSEvent) {
        markdownCellController.end()
        let point = convert(event.locationInWindow, from: nil)
        if let checkbox = MarkdownPresentation.taskCheckbox(at: point, in: self) {
            toggleMarkdownTask(at: checkbox.range.location)
            return
        }
        if event.clickCount == 1,
           let open = markdownLinkNavigation?.openLink,
           let link = noteLink(at: point, modifiers: event.modifierFlags) {
            open(link)
            return
        }
        super.mouseDown(with: event)
    }

    // Test the displayed glyph, not merely the nearest insertion position:
    // clicking blank space after a link should still place the caret.
    func noteLink(at point: NSPoint, modifiers: NSEvent.ModifierFlags) -> NotebookLinkOccurrence? {
        guard !hasMarkedText(), let window else { return nil }
        let flags = modifiers.intersection([.command, .shift, .option, .control])
        guard flags.isEmpty || flags == .command else { return nil }
        let snapshot = MarkdownLivePreview.snapshot(for: self)
        let source = string as NSString
        let offset = characterIndexForInsertion(at: point)
        let links = NotebookLinkParser.parse(string)
        for candidate in [offset, offset - 1] where candidate >= 0 && candidate < source.length {
            let character = source.rangeOfComposedCharacterSequence(at: candidate)
            let screenRect = firstRect(forCharacterRange: character, actualRange: nil)
            let rect = convert(window.convertFromScreen(screenRect), from: nil)
            guard rect.width > 1, rect.contains(point),
                  let link = links.first(where: {
                      !$0.isEmbed && NSLocationInRange(candidate, $0.range)
                  }) else { continue }
            if flags == .command || MarkdownLivePreview.conceals(
                link.range, in: source, snapshot: snapshot
            ) { return link }
        }
        return nil
    }

    override func keyDown(with event: NSEvent) {
        let flags = event.modifierFlags.intersection([.command, .shift, .option, .control])
        if markdownLinkNavigation?.hasLinkCompletion == true,
           flags.isEmpty, !hasMarkedText() {
            let command: String?
            switch event.keyCode {
            case 124, 125: command = "next"
            case 123, 126: command = "previous"
            case 36: command = "accept"
            case 53: command = "dismiss"
            default: command = nil
            }
            if let command, markdownLinkNavigation?.completionCommand?(command) == true { return }
        }
        super.keyDown(with: event)
    }

    override func insertNewline(_ sender: Any?) {
        if markdownLinkNavigation?.hasLinkCompletion == true,
           !hasMarkedText(),
           markdownLinkNavigation?.completionCommand?("accept") == true { return }
        if !performMarkdownCommand(.continueLine) { super.insertNewline(sender) }
    }

    override func insertTab(_ sender: Any?) {
        if performMarkdownCommand(.tableNextCell) { return }
        if !performMarkdownCommand(.indent) { super.insertTab(sender) }
    }

    override func insertBacktab(_ sender: Any?) {
        if performMarkdownCommand(.tablePreviousCell) { return }
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
        case ("t", [.command, .shift]): command = .toggleTask
        default: command = nil
        }
        if let command, performMarkdownCommand(command) { return true }
        return super.performKeyEquivalent(with: event)
    }

    override func accessibilityChildren() -> [Any]? {
        var children = super.accessibilityChildren() ?? []
        for overlay in markdownTableScrollOverlays where !children.contains(where: {
            ($0 as AnyObject) === overlay
        }) {
            children.append(overlay)
        }
        return children
    }

    override func drawBackground(in rect: NSRect) {
        super.drawBackground(in: rect)
        MarkdownPresentation.drawBlockBackgrounds(in: self, dirtyRect: rect)
    }
}

struct MarkdownEditor: NSViewRepresentable {
    @Binding var text: String
    var isReadOnly = false
    var editRevision: Data?
    var commitEdit: ((String, Data) throws -> MarkdownEditorCommit)?
    var commitNativeEdit: ((String, Data, NoteEditorTextChange?) throws -> MarkdownEditorCommit)?

    private var revisionedCommit: ((String, Data, NoteEditorTextChange?) throws -> MarkdownEditorCommit)? {
        if let commitNativeEdit { return commitNativeEdit }
        guard let commitEdit else { return nil }
        return { text, revision, _ in try commitEdit(text, revision) }
    }
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
        isReadOnly: Bool = false,
        editRevision: Data? = nil,
        commitEdit: ((String, Data) throws -> MarkdownEditorCommit)? = nil,
        commitNativeEdit: ((String, Data, NoteEditorTextChange?) throws -> MarkdownEditorCommit)? = nil,
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
        self.isReadOnly = isReadOnly
        self.editRevision = editRevision
        self.commitEdit = commitEdit
        self.commitNativeEdit = commitNativeEdit
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
        textView.isEditable = !isReadOnly
        textView.isSelectable = true
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
        textView.setAccessibilityIdentifier(
            isReadOnly ? "note-history-preview" : "markdown-editor"
        )
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

        private func refreshTableCommands(in textView: NSTextView) {
            guard let textView = textView as? MarkdownTextView else { return }
            parent.navigation?.tableCommands.scheduleRefresh(from: textView)
        }

        func attachNavigation(to textView: MarkdownTextView) {
            textView.markdownCellController.onCompositionEnded = { [weak self, weak textView] in
                guard let self, let textView else { return }
                self.update(parent: self.parent, textView: textView)
            }
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
            refreshTableCommands(in: textView)
            parent.navigation?.prepareCommand = { [weak textView] command in
                textView?.preparedMarkdownCommand(command)
            }
            parent.navigation?.prepareSnippetInsertion = { [weak textView] in
                textView?.preparedSnippetInsertion()
            }
            let navigation = parent.navigation
            parent.navigation?.prepareToLeave = { [weak self, weak textView] in
                guard let self, let textView else { return true }
                guard !textView.hasMarkedText(),
                      !textView.markdownCellController.hasMarkedText else { return false }
                textView.markdownCellController.end()
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
                    || textView.markdownCellController.hasFocus
            }
            parent.navigation?.showFind = { [weak self, weak textView] in
                guard let self, let textView else { return }
                self.clearDestinationHighlight(in: textView)
                textView.markdownCellController.end(focusSource: true)
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
            textView.markdownLinkNavigation = navigation
            navigation?.insertLink = { [weak textView] change, expected in
                textView?.insertNoteLink(change, expected: expected) == true
            }
            textView.markdownDidAttachToWindow = { [weak navigation] in
                navigation?.didAttach()
            }
        }

        func update(parent: MarkdownEditor, textView: NSTextView) {
            self.parent = parent
            if let nativeView = textView as? MarkdownTextView,
               nativeView.markdownLinkNavigation !== parent.navigation {
                attachNavigation(to: nativeView)
                if nativeView.window != nil { parent.navigation?.didAttach() }
            }
            textView.isEditable = !parent.isReadOnly
            guard !textView.hasMarkedText(),
                  !((textView as? MarkdownTextView)?.markdownCellController.hasMarkedText ?? false)
            else { return }
            (textView as? MarkdownTextView)?.markdownCellController.synchronize(mode: parent.mode)

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

            if parent.revisionedCommit != nil, let revision = parent.editRevision,
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
            refreshTableCommands(in: textView)
            reportLinkSelection(in: textView)
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
            reportLinkSelection(in: textView)
            schedulePendingSearchMatchReveal(in: textView)
            schedulePendingPositionRestore(in: textView)
        }

        private func reportLinkSelection(in textView: NSTextView) {
            guard !textView.hasMarkedText() else { return }
            let text = textView.string
            let selection = textView.selectedRange()
            let editing = textView.window?.firstResponder === textView
            let navigation = parent.navigation
            DispatchQueue.main.async { [weak navigation] in
                navigation?.selectionChanged?(text, selection, editing)
            }
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
            (textView as? MarkdownTextView)?.markdownCellController.end()
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
            refreshTableCommands(in: textView)
            guard !isUpdating, !textView.hasMarkedText() else { return }
            guard let storage = textView.textStorage else { return }
            let nativeText = MarkdownPresentation.syntaxCache(for: textView)
                .textSnapshot(in: storage)
            guard !displayedText.utf8.elementsEqual(nativeText.utf8) else {
                MarkdownPresentation.syntaxCache(for: textView).acknowledgeNativeText()
                return
            }

            guard let commitEdit = parent.revisionedCommit,
                  let baseRevision = displayedRevision else {
                displayedText = nativeText
                MarkdownPresentation.syntaxCache(for: textView).acknowledgeNativeText()
                parent.text = nativeText
                schedulePresentationRefresh(for: textView)
                return
            }

            do {
                let cache = MarkdownPresentation.syntaxCache(for: textView)
                let commit = try commitEdit(
                    nativeText, baseRevision,
                    textView.textStorage.flatMap { cache.nativeTextChange(in: $0) }
                )
                cache.acknowledgeNativeText()
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
            refreshTableCommands(in: textView)
            MarkdownPresentation.syntaxCache(for: textView).acknowledgeNativeText()
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
final class MarkdownTextView: UITextView, UIGestureRecognizerDelegate,
    UIPointerInteractionDelegate {
    override var contentSize: CGSize {
        get { super.contentSize }
        set {
            // UIKit supplies the natural text extent. Extend the scrollable
            // document without turning whitespace into a caret-reveal margin.
            markdownState.naturalContentSize = newValue
            super.contentSize = contentSizeWithEndPadding(newValue)
        }
    }

    private func contentSizeWithEndPadding(_ size: CGSize) -> CGSize {
        CGSize(width: size.width,
               height: size.height + markdownScrollPastEndPadding)
    }

    var markdownFindPresentation: MarkdownEditorFindPresentation? {
        get { markdownState.findPresentation }
        set { markdownState.findPresentation = newValue }
    }

    override func findInteraction(
        _ interaction: UIFindInteraction, didBegin session: UIFindSession
    ) {
        super.findInteraction(interaction, didBegin: session)
        markdownState.isFinding = true
        markdownFindPresentation?.isVisible = true
        setNeedsLayout()
    }

    override func findInteraction(
        _ interaction: UIFindInteraction, didEnd session: UIFindSession
    ) {
        super.findInteraction(interaction, didEnd: session)
        markdownState.isFinding = false
        markdownFindPresentation?.isVisible = false
        updateFindKeyboardInsets()
    }

    private func updateFindKeyboardInsets() {
        // Read-only navigation previews pin the captured source viewport.
        // Their bottom inset must survive subsequent layout passes as well.
        if !isEditable, contentInsetAdjustmentBehavior == .never,
           !markdownState.isFinding { return }
        // Find's glass accessory needs the dimmed document behind it.
        // Keep matches above the keyboard while the view extends beneath it.
        let overlap = bounds.intersection(keyboardLayoutGuide.layoutFrame)
        let bottom = markdownState.isFinding && !overlap.isNull
            ? overlap.height : 0
        if contentInset.bottom != bottom {
            contentInset.bottom = bottom
            verticalScrollIndicatorInsets.bottom = bottom
        }
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        updateFindKeyboardInsets()
        let padding = MarkdownEditorScrollPadding.bottom(
            for: max(0, bounds.height - (markdownState.isFinding
                ? adjustedContentInset.bottom : 0))
        )
        var insets = textContainerInset
        let titleExtent = markdownState.titleHost == nil
            ? 0 : markdownState.titleHeight + 12
        insets.top = 18 + titleExtent
        // Small system gestures can briefly resize the editor. Keep optional
        // end space stable so those changes do not move the scrollable extent.
        // Optional space below the document may differ from half the viewport
        // by less than half a body-font line. Compare against applied padding
        // so accumulated resizes still update it, independently of the title.
        let previousPadding = markdownState.appliedEndPadding
        if previousPadding == nil
            || abs(markdownScrollPastEndPadding - padding) >= markdownBodyLineHeight / 2 {
            markdownState.appliedEndPadding = padding
        }
        // Text margins also affect native caret reveal. Keep optional space
        // below the note in its scrollable extent instead.
        insets.bottom = 18
        if insets != textContainerInset {
            textContainerInset = insets
        }
        if previousPadding != markdownState.appliedEndPadding,
           let naturalSize = markdownState.naturalContentSize {
            // A viewport resize can change padding without a new text extent.
            // Start from the last native size so layout never adds it twice.
            super.contentSize = contentSizeWithEndPadding(naturalSize)
        }
        layoutMarkdownTitle()
        markdownSyntaxCache.refreshTablesAfterResize(
            width: textContainer.size.width - 2 * textContainer.lineFragmentPadding
        )
        updateMarkdownTableScrollOverlays()
        markdownState.linkPointer?.invalidate()
        markdownState.didLayout?()
    }

    override func becomeFirstResponder() -> Bool {
        if markdownCellController.hasFocus, !markdownCellController.forwarding,
           undoManager?.isUndoing != true, undoManager?.isRedoing != true {
            markdownCellController.end()
        }
        let wasFirstResponder = isFirstResponder
        let accepted = super.becomeFirstResponder()
        if accepted, !wasFirstResponder {
            markdownState.pendingKeyboardSelectionReveal = true
        }
        markdownState.linkPointer?.invalidate()
        return accepted
    }

    override func resignFirstResponder() -> Bool {
        let accepted = super.resignFirstResponder()
        if accepted { markdownState.pendingKeyboardSelectionReveal = false }
        markdownState.linkPointer?.invalidate()
        return accepted
    }

    func updateMarkdownTitle(_ title: AnyView?, height: CGFloat) {
        if let title {
            if let host = markdownState.titleHost {
                host.rootView = title
            } else {
                let host = UIHostingController(rootView: title)
                host.view.backgroundColor = .clear
                markdownState.titleHost = host
            }
            attachMarkdownTitleHostIfNeeded()
        } else {
            removeMarkdownTitleHost()
        }
        markdownState.titleHeight = max(0, height)
        measureMarkdownTitle()
        setNeedsLayout()
    }

    private func attachMarkdownTitleHostIfNeeded() {
        guard let host = markdownState.titleHost else { return }
        var responder = next
        var owner: UIViewController?
        while let current = responder {
            if let controller = current as? UIViewController {
                owner = controller
                break
            }
            responder = current.next
        }
        if let owner, host.parent !== owner {
            detachMarkdownTitleHost(host)
            owner.addChild(host)
            addSubview(host.view)
            host.didMove(toParent: owner)
        } else if host.view.superview !== self {
            // Representable construction can precede its owning controller.
            // Adopt the host once the native editor joins that hierarchy.
            addSubview(host.view)
        }
    }

    private func detachMarkdownTitleHost(_ host: UIHostingController<AnyView>) {
        if host.parent != nil { host.willMove(toParent: nil) }
        host.view.removeFromSuperview()
        if host.parent != nil { host.removeFromParent() }
    }

    func removeMarkdownTitleHost() {
        if let host = markdownState.titleHost { detachMarkdownTitleHost(host) }
        markdownState.titleHost = nil
    }

    override func didMoveToSuperview() {
        super.didMoveToSuperview()
        if superview == nil {
            if let host = markdownState.titleHost { detachMarkdownTitleHost(host) }
        } else {
            attachMarkdownTitleHostIfNeeded()
        }
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

    var markdownBodyLineHeight: CGFloat {
        get { markdownState.bodyLineHeight }
        set {
            guard newValue.isFinite, newValue > 0,
                  newValue != markdownState.bodyLineHeight else { return }
            markdownState.bodyLineHeight = newValue
            setNeedsLayout()
        }
    }

    var markdownScrollPastEndPadding: CGFloat {
        markdownState.appliedEndPadding ?? 0
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
        if window != nil { attachMarkdownTitleHostIfNeeded() }
        let center = NotificationCenter.default
        if let observer = markdownState.keyboardRevealObserver {
            center.removeObserver(observer)
            markdownState.keyboardRevealObserver = nil
        }
        if window != nil {
            markdownState.keyboardRevealObserver = center.addObserver(
                forName: UIResponder.keyboardDidShowNotification,
                object: nil, queue: .main
            ) { [weak self] _ in
                MainActor.assumeIsolated {
                    self?.revealSelectionAfterKeyboardDidShow()
                }
            }
        } else {
            markdownState.pendingKeyboardSelectionReveal = false
        }
        reportWindowAttachmentIfNeeded()
    }

    private func revealSelectionAfterKeyboardDidShow() {
        guard markdownState.pendingKeyboardSelectionReveal else { return }
        markdownState.pendingKeyboardSelectionReveal = false
        guard window != nil, isFirstResponder, isEditable,
              !markdownState.isFinding else { return }
        let selection = selectedRange
        let length = textStorage.length
        guard selection.location != NSNotFound,
              selection.location <= length,
              selection.length <= length - selection.location else { return }
        // Estimated TextKit extents can leave the caret covered on focus.
        // Reveal the current selection once native keyboard bounds settle.
        scrollRangeToVisible(selection)
    }

    private func reportWindowAttachmentIfNeeded() {
        guard window != nil, !markdownState.reportedWindowAttachment,
              let didAttachToWindow = markdownState.didAttachToWindow else {
            return
        }
        markdownState.reportedWindowAttachment = true
        didAttachToWindow()
    }

    var markdownLinkNavigation: MarkdownEditorNavigation? {
        get { markdownState.linkNavigation }
        set {
            markdownState.linkNavigation?.linkActivationChanged = nil
            markdownState.linkNavigation = newValue
            newValue?.linkActivationChanged = { [weak self] in
                self?.markdownState.linkPointer?.invalidate()
            }
            installMarkdownLinkPointer()
            markdownState.linkPointer?.invalidate()
        }
    }

    private func installMarkdownLinkPointer() {
        guard markdownState.linkPointer == nil else { return }
        let interaction = UIPointerInteraction(delegate: self)
        addInteraction(interaction)
        markdownState.linkPointer = interaction
    }

    private func passiveNoteLink(at point: CGPoint,
                                 modifiers: UIKeyModifierFlags = []) -> NotebookLinkOccurrence? {
        guard !isFirstResponder, markedTextRange == nil,
              markdownLinkNavigation?.openLink != nil,
              modifiers.intersection([.command, .shift, .alternate, .control]).isEmpty,
              MarkdownLivePreview.snapshot(for: self).mode == .livePreview else { return nil }
        return noteLink(at: point)
    }

    /// Match the pointer to the visible label segment under it, including
    /// wrapped labels. Hidden destinations and trailing space remain text.
    func noteLinkPointerRegion(at point: CGPoint,
                               modifiers: UIKeyModifierFlags = []) -> UIPointerRegion? {
        guard window != nil, let link = passiveNoteLink(at: point, modifiers: modifiers) else {
            return nil
        }
        let labelRange: NSRange
        if link.kind == .markdown {
            labelRange = NSRange(location: link.range.location + 1,
                                 length: (link.label ?? "").utf16.count)
        } else if link.label != nil {
            let start = NSMaxRange(link.destinationRange) + 1
            labelRange = NSRange(location: start, length: NSMaxRange(link.range) - 2 - start)
        } else { labelRange = link.destinationRange }
        guard let start = position(from: beginningOfDocument, offset: labelRange.location),
              let end = position(from: start, offset: labelRange.length),
              let range = textRange(from: start, to: end) else { return nil }
        for selection in selectionRects(for: range) {
            let rect = selection.rect.intersection(bounds)
            if !rect.isNull, rect.width > 1, rect.height > 0, rect.contains(point) {
                return UIPointerRegion(rect: rect, identifier: link.range.location)
            }
        }
        return nil
    }

    func pointerInteraction(_ interaction: UIPointerInteraction,
                            regionFor request: UIPointerRegionRequest,
                            defaultRegion: UIPointerRegion) -> UIPointerRegion? {
        noteLinkPointerRegion(at: request.location, modifiers: request.modifiers)
    }

    func pointerInteraction(_ interaction: UIPointerInteraction,
                            styleFor region: UIPointerRegion) -> UIPointerStyle? {
        guard interaction === markdownState.linkPointer,
              let current = noteLinkPointerRegion(at: CGPoint(x: region.rect.midX,
                                                              y: region.rect.midY)),
              current.identifier == region.identifier else { return nil }
        let parameters = UIPreviewParameters(textLineRects: [NSValue(cgRect: region.rect)])
        parameters.backgroundColor = .clear
        let preview = UITargetedPreview(view: self, parameters: parameters)
        return UIPointerStyle(effect: .highlight(preview), shape: .roundedRect(
            convert(region.rect, to: preview.target.container), radius: 4))
    }

    func insertNoteLink(_ change: MarkdownEditingChange, expected: String) -> Bool {
        guard isEditable, markedTextRange == nil, text == expected,
              NSMaxRange(change.range) <= (text as NSString).length else { return false }
        markdownState.isApplyingCommand = true
        defer { markdownState.isApplyingCommand = false }
        becomeFirstResponder()
        undoManager?.beginUndoGrouping()
        selectedRange = change.range
        super.insertText(change.replacement)
        undoManager?.endUndoGrouping()
        let updated = (expected as NSString).replacingCharacters(
            in: change.range, with: change.replacement)
        if text == updated { selectedRange = updated.clampedSelection(change.selection) }
        delegate?.textViewDidChange?(self)
        return true
    }

    private func noteLink(at point: CGPoint) -> NotebookLinkOccurrence? {
        guard let position = closestPosition(to: point) else { return nil }
        let offset = self.offset(from: beginningOfDocument, to: position)
        guard let link = NotebookLinkParser.parse(text ?? "").first(where: {
            !$0.isEmbed && NSLocationInRange(offset, $0.range)
        }), let start = self.position(from: beginningOfDocument, offset: link.range.location),
            let end = self.position(from: start, offset: link.range.length),
            let range = textRange(from: start, to: end),
            selectionRects(for: range).contains(where: {
                $0.rect.insetBy(dx: -4, dy: -4).contains(point)
            }) else { return nil }
        return link
    }

    @discardableResult
    func performMarkdownCommand(_ command: MarkdownEditingCommand) -> Bool {
        if markdownCellController.isActive, !markdownCellController.forwarding {
            return markdownCellController.perform(command)
        }
        guard isEditable, markedTextRange == nil,
              !markdownState.isApplyingCommand else { return false }
        if command == .link, let request = markdownLinkNavigation?.requestLink {
            request(text ?? "", selectedRange)
            return true
        }
        let source = text ?? ""
        let syntaxResult = command == .toggleTask
            ? markdownSyntaxCache.result(for: source) : nil
        guard let change = MarkdownEditingRules.change(
            for: command, text: source, selection: selectedRange,
            syntaxResult: syntaxResult
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
        if command == .insertTable {
            markdownCellController.activateSourceSelection()
        }
        return true
    }

    func toggleMarkdownTask(at location: Int) {
        guard isEditable, markedTextRange == nil else { return }
        let source = text ?? ""
        let syntaxResult = markdownSyntaxCache.result(for: source)
        guard let change = MarkdownEditingRules.toggleTask(
            text: source, at: location, syntaxResult: syntaxResult
        ) else { return }
        let selection = selectedRange
        markdownState.isApplyingCommand = true
        defer { markdownState.isApplyingCommand = false }
        selectedRange = change.range
        super.insertText(change.replacement)
        selectedRange = (text ?? "").clampedSelection(selection)
        delegate?.textViewDidChange?(self)
    }

    func installMarkdownTaskTap() {
        installMarkdownLinkPointer()
        defer { markdownState.linkPointer?.invalidate() }
        guard markdownState.taskTap == nil else { return }
        let tap = UITapGestureRecognizer(
            target: self, action: #selector(tappedMarkdownTask(_:))
        )
        tap.delegate = self
        addGestureRecognizer(tap)
        markdownState.taskTap = tap
        accessibilityCustomActions = [UIAccessibilityCustomAction(
            name: String(localized: "Toggle Task"),
            target: self,
            selector: #selector(accessibilityToggleMarkdownTask(_:))
        )]
    }

    @objc private func accessibilityToggleMarkdownTask(
        _ action: UIAccessibilityCustomAction
    ) -> Bool {
        performMarkdownCommand(.toggleTask)
    }

    @objc private func tappedMarkdownTask(_ tap: UITapGestureRecognizer) {
        let point = tap.location(in: self)
        if let link = markdownState.tappedLink {
            markdownState.tappedLink = nil
            markdownLinkNavigation?.openLink?(link)
            return
        }
        guard let checkbox = MarkdownPresentation.taskCheckbox(
            at: point, in: self
        ) else { return }
        toggleMarkdownTask(at: checkbox.range.location)
    }

    private var linkCompletionKeyCommands: [UIKeyCommand] {
        guard markdownLinkNavigation?.hasLinkCompletion == true,
              markedTextRange == nil else { return [] }
        let keys = [UIKeyCommand.inputDownArrow, UIKeyCommand.inputUpArrow,
                    UIKeyCommand.inputRightArrow, UIKeyCommand.inputLeftArrow,
                    "\r", UIKeyCommand.inputEscape]
        let commands = keys.map {
            let command = UIKeyCommand(input: $0, modifierFlags: [],
                action: #selector(handleLinkCompletionKey(_:)))
            command.wantsPriorityOverSystemBehavior = true
            return command
        }
        return commands
    }

    @objc private func handleLinkCompletionKey(_ sender: UIKeyCommand) {
        let command: String
        switch sender.input {
        case UIKeyCommand.inputDownArrow, UIKeyCommand.inputRightArrow: command = "next"
        case UIKeyCommand.inputUpArrow, UIKeyCommand.inputLeftArrow: command = "previous"
        case UIKeyCommand.inputEscape: command = "dismiss"
        default: command = "accept"
        }
        if markdownLinkNavigation?.completionCommand?(command) != true, command == "accept" {
            super.insertText("\n")
        }
    }

    override func insertText(_ text: String) {
        if text == "\n", markdownLinkNavigation?.hasLinkCompletion == true,
           markedTextRange == nil,
           markdownLinkNavigation?.completionCommand?("accept") == true { return }
        if !markdownState.isApplyingCommand, !markdownState.isPasting,
           !markdownCellController.forwarding {
            if text == "\t", performMarkdownCommand(.tableNextCell) { return }
            let command: MarkdownEditingCommand? = text == "\n"
                ? .continueLine : (text == "\t" ? .indent : nil)
            if let command, performMarkdownCommand(command) { return }
        }
        super.insertText(text)
    }

    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent?) {
        if !markdownCellController.forwarding { markdownCellController.end() }
        super.touchesBegan(touches, with: event)
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
            ("t", [.command, .shift], #selector(toggleTaskMarkdown)),
        ]
        return linkCompletionKeyCommands + (super.keyCommands ?? []) + commands.map { input, flags, action in
            let key = UIKeyCommand(input: input, modifierFlags: flags, action: action)
            key.wantsPriorityOverSystemBehavior = true
            return key
        }
    }

    @objc private func indentMarkdown() {
        if performMarkdownCommand(.tableNextCell) { return }
        if !performMarkdownCommand(.indent) { insertText("\t") }
    }
    @objc private func outdentMarkdown() {
        if !performMarkdownCommand(.tablePreviousCell) {
            _ = performMarkdownCommand(.outdent)
        }
    }
    @objc private func boldMarkdown() { _ = performMarkdownCommand(.bold) }
    @objc private func italicMarkdown() { _ = performMarkdownCommand(.italic) }
    @objc private func linkMarkdown() { _ = performMarkdownCommand(.link) }
    @objc private func headingMarkdown() { _ = performMarkdownCommand(.heading) }
    @objc private func codeMarkdown() { _ = performMarkdownCommand(.inlineCode) }
    @objc private func toggleTaskMarkdown() {
        _ = performMarkdownCommand(.toggleTask)
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
    override func gestureRecognizerShouldBegin(
        _ gestureRecognizer: UIGestureRecognizer
    ) -> Bool {
        guard gestureRecognizer === markdownState.taskTap,
              let tap = gestureRecognizer as? UITapGestureRecognizer else {
            return super.gestureRecognizerShouldBegin(gestureRecognizer)
        }
        let point = tap.location(in: self)
        markdownState.tappedLink = passiveNoteLink(at: point, modifiers: tap.modifierFlags)
        return MarkdownPresentation.taskCheckbox(at: point, in: self) != nil
            || markdownState.tappedLink != nil
    }
}

private final class MarkdownTextViewState: NSObject {
    var keyboardRevealObserver: NSObjectProtocol?
    var pendingKeyboardSelectionReveal = false

    isolated deinit {
        if let keyboardRevealObserver {
            NotificationCenter.default.removeObserver(keyboardRevealObserver)
        }
    }

    var appliedEndPadding: CGFloat?
    var naturalContentSize: CGSize?
    var bodyLineHeight = UIFont.systemFont(
        ofSize: MarkdownPresentation.defaultFontSize
    ).lineHeight
    weak var findPresentation: MarkdownEditorFindPresentation?
    var isFinding = false
    var isApplyingCommand = false
    var isPasting = false
    var reportedWindowAttachment = false
    var didAttachToWindow: (() -> Void)?
    var didLayout: (() -> Void)?
    let syntaxCache = MarkdownSyntaxCache()
    var taskTap: UITapGestureRecognizer?
    var tappedLink: NotebookLinkOccurrence?
    var linkPointer: UIPointerInteraction?
    weak var linkNavigation: MarkdownEditorNavigation?
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
    var isReadOnly = false
    var editRevision: Data?
    var commitEdit: ((String, Data) throws -> MarkdownEditorCommit)?
    var commitNativeEdit: ((String, Data, NoteEditorTextChange?) throws -> MarkdownEditorCommit)?

    private var revisionedCommit: ((String, Data, NoteEditorTextChange?) throws -> MarkdownEditorCommit)? {
        if let commitNativeEdit { return commitNativeEdit }
        guard let commitEdit else { return nil }
        return { text, revision, _ in try commitEdit(text, revision) }
    }
    var onEditError: ((Error) -> Void)?
    var navigation: MarkdownEditorNavigation?
    var onBeginEditing: () -> Void
    var title: AnyView?
    var titleHeight: CGFloat
    var focusRequest: Int
    var fontSize: Double
    var fontFamily: EditorFontFamily
    var mode: MarkdownEditorMode
    var initialPreviewPosition: MarkdownEditorPosition?
    var initialPreviewInsets: UIEdgeInsets?
    var initialPreviewOriginY: CGFloat?

    init(
        text: Binding<String>,
        isReadOnly: Bool = false,
        editRevision: Data? = nil,
        commitEdit: ((String, Data) throws -> MarkdownEditorCommit)? = nil,
        commitNativeEdit: ((String, Data, NoteEditorTextChange?) throws -> MarkdownEditorCommit)? = nil,
        onEditError: ((Error) -> Void)? = nil,
        navigation: MarkdownEditorNavigation? = nil,
        onBeginEditing: @escaping () -> Void = {},
        title: AnyView? = nil,
        titleHeight: CGFloat = 0,
        focusRequest: Int = 0,
        fontSize: Double = 17,
        fontFamily: EditorFontFamily = .system,
        mode: MarkdownEditorMode = .source,
        initialPreviewPosition: MarkdownEditorPosition? = nil,
        initialPreviewInsets: UIEdgeInsets? = nil,
        initialPreviewOriginY: CGFloat? = nil
    ) {
        _text = text
        self.isReadOnly = isReadOnly
        self.editRevision = editRevision
        self.commitEdit = commitEdit
        self.commitNativeEdit = commitNativeEdit
        self.onEditError = onEditError
        self.navigation = navigation
        self.onBeginEditing = onBeginEditing
        self.title = title
        self.titleHeight = titleHeight
        self.focusRequest = focusRequest
        self.fontSize = fontSize
        self.fontFamily = fontFamily
        self.mode = mode
        self.initialPreviewPosition = initialPreviewPosition
        self.initialPreviewInsets = initialPreviewInsets
        self.initialPreviewOriginY = initialPreviewOriginY
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
        textView.isFindInteractionEnabled = true
        textView.keyboardLayoutGuide.usesBottomSafeArea = false
        textView.keyboardDismissMode = UIDevice.current.userInterfaceIdiom == .pad
            ? .none : .interactive
        textView.alwaysBounceVertical = true
        textView.topEdgeEffect.isHidden =
            UIDevice.current.userInterfaceIdiom == .pad
        textView.text = text
        textView.allowsEditingTextAttributes = false
        textView.isEditable = !isReadOnly
        textView.isSelectable = true
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
        textView.accessibilityIdentifier = isReadOnly
            ? "note-history-preview" : "markdown-editor"
        MarkdownPresentation.configure(
            textView,
            fontSize: fontSize,
            fontFamily: fontFamily,
            mode: mode
        )

        context.coordinator.attachNavigation(to: textView)
        textView.updateMarkdownTitle(title, height: titleHeight)
        context.coordinator.applyInitialPreviewInsets(in: textView)
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

    static func dismantleUIView(_ textView: UITextView, coordinator: Coordinator) {
        (textView as? MarkdownTextView)?.removeMarkdownTitleHost()
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
        private var pendingPositionCompletion: (() -> Void)?
        private var pendingInitialPreviewPosition: MarkdownEditorPosition?
        private var initialPreviewGeometry: DestinationCenterGeometry?
        private var initialPreviewOriginY: CGFloat?

        private struct DestinationCenterGeometry: Equatable {
            let size: CGSize
            let adjustedInset: UIEdgeInsets
            let textContainerInset: UIEdgeInsets
        }

        func scrollViewWillBeginDragging(_ scrollView: UIScrollView) {
            cancelPositionRestore()
        }

        init(parent: MarkdownEditor) {
            self.parent = parent
            pendingInitialPreviewPosition = parent.initialPreviewPosition
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

        private func refreshTableCommands(in textView: UITextView) {
            guard let textView = textView as? MarkdownTextView else { return }
            parent.navigation?.tableCommands.scheduleRefresh(from: textView)
        }

        func attachNavigation(to textView: MarkdownTextView) {
            textView.installMarkdownKeyboardToolbar(navigation: parent.navigation)
            textView.markdownFindPresentation = parent.navigation?.findPresentation
            textView.markdownCellController.onCompositionEnded = { [weak self, weak textView] in
                guard let self, let textView else { return }
                self.update(parent: self.parent, textView: textView)
            }
            installDestinationHighlightRendering(in: textView)
            textView.markdownDidLayout = { [weak self, weak textView] in
                guard let self, let textView else { return }
                self.restoreInitialPreviewIfNeeded(in: textView)
                self.centerDestinationIfGeometryChanged(in: textView)
            }
            refreshTableCommands(in: textView)
            parent.navigation?.prepareCommand = { [weak textView] command in
                textView?.preparedMarkdownCommand(command)
            }
            parent.navigation?.prepareSnippetInsertion = { [weak textView] in
                textView?.preparedSnippetInsertion()
            }
            let navigation = parent.navigation
            parent.navigation?.prepareToLeave = { [weak self, weak textView] in
                guard let self, let textView else { return true }
                guard textView.markedTextRange == nil,
                      !textView.markdownCellController.hasMarkedText else { return false }
                textView.markdownCellController.end()
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
                    || textView?.markdownCellController.hasFocus == true
            }
            parent.navigation?.showFind = { [weak self, weak textView] in
                guard let self, let textView else { return }
                self.clearDestinationHighlight(in: textView)
                // The find navigator owns keyboard input while it is visible.
                // Resigning first removes the Markdown writing accessory.
                textView.markdownCellController.end()
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
            parent.navigation?.restorePositionAndNotify = {
                [weak self, weak textView] position, completion in
                guard let self, let textView else { return }
                self.schedulePositionRestore(position, in: textView, completion: completion)
            }
            parent.navigation?.captureViewportInsets = { [weak textView] in
                guard let textView else { return nil }
                textView.layoutIfNeeded()
                return textView.adjustedContentInset
            }
            parent.navigation?.captureViewportOriginY = { [weak textView] in
                guard let textView, let window = textView.window else { return nil }
                return textView.convert(textView.bounds, to: window).minY
            }
            textView.markdownLinkNavigation = navigation
            navigation?.insertLink = { [weak textView] change, expected in
                textView?.insertNoteLink(change, expected: expected) == true
            }
            textView.markdownDidAttachToWindow = { [weak navigation] in
                navigation?.didAttach()
            }
        }

        func update(parent: MarkdownEditor, textView: UITextView) {
            if parent.isReadOnly,
               parent.initialPreviewPosition != self.parent.initialPreviewPosition
                || parent.initialPreviewInsets != self.parent.initialPreviewInsets
                || parent.initialPreviewOriginY != self.parent.initialPreviewOriginY {
                pendingInitialPreviewPosition = parent.initialPreviewPosition
                textView.setNeedsLayout()
            }
            self.parent = parent
            applyInitialPreviewInsets(in: textView)
            // SwiftUI can retain the native view while a navigation visit or
            // History changes its owner. Selection reporting uses the updated
            // parent, so insertion and toolbar callbacks must follow it too.
            if let nativeView = textView as? MarkdownTextView,
               nativeView.markdownLinkNavigation !== parent.navigation {
                attachNavigation(to: nativeView)
                if nativeView.window != nil { parent.navigation?.didAttach() }
            }
            textView.isEditable = !parent.isReadOnly
            guard textView.markedTextRange == nil,
                  !((textView as? MarkdownTextView)?.markdownCellController.hasMarkedText ?? false)
            else { return }
            (textView as? MarkdownTextView)?.markdownCellController.synchronize(mode: parent.mode)

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

            if parent.revisionedCommit != nil, let revision = parent.editRevision,
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
            refreshTableCommands(in: textView)
            reportLinkSelection(in: textView)
            if parent.mode == .livePreview {
                schedulePresentationRefresh(for: textView)
            }
            schedulePendingSearchMatchReveal(in: textView)
            schedulePendingPositionRestore(in: textView)
        }

        func textViewDidChange(_ textView: UITextView) {
            guard !isUpdating, textView.markedTextRange == nil else { return }
            defer { reportLinkSelection(in: textView) }
            refreshTableCommands(in: textView)
            clearDestinationHighlight(in: textView)
            defer {
                schedulePendingSearchMatchReveal(in: textView)
                schedulePendingPositionRestore(in: textView)
            }
            let nativeText = MarkdownPresentation.syntaxCache(for: textView)
                .textSnapshot(in: textView.textStorage)
            guard !displayedText.utf8.elementsEqual(nativeText.utf8) else {
                MarkdownPresentation.syntaxCache(for: textView).acknowledgeNativeText()
                return
            }

            guard let commitEdit = parent.revisionedCommit,
                  let baseRevision = displayedRevision else {
                displayedText = nativeText
                MarkdownPresentation.syntaxCache(for: textView).acknowledgeNativeText()
                parent.text = nativeText
                schedulePresentationRefresh(for: textView)
                return
            }

            do {
                let cache = MarkdownPresentation.syntaxCache(for: textView)
                let commit = try commitEdit(
                    nativeText, baseRevision,
                    cache.nativeTextChange(in: textView.textStorage)
                )
                cache.acknowledgeNativeText()
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

        private func reportLinkSelection(in textView: UITextView) {
            guard textView.markedTextRange == nil else { return }
            let text = textView.text ?? ""
            let selection = textView.selectedRange
            let editing = textView.isFirstResponder
            let navigation = parent.navigation
            DispatchQueue.main.async { [weak navigation] in
                navigation?.selectionChanged?(text, selection, editing)
            }
        }

        func textView(_ textView: UITextView, editMenuForTextIn range: NSRange,
                      suggestedActions: [UIMenuElement]) -> UIMenu? {
            let link = NotebookLinkParser.parse(textView.text ?? "").first {
                !$0.isEmbed && (NSIntersectionRange($0.range, range).length > 0
                    || NSLocationInRange(range.location, $0.range))
            }
            guard let link else { return UIMenu(children: suggestedActions) }
            let action = UIAction(title: String(localized: "Open Linked Note"),
                                  image: UIImage(systemName: "link")) {
                [weak navigation = parent.navigation] _ in
                navigation?.openLink?(link)
            }
            return UIMenu(children: [action] + suggestedActions)
        }

        private func scheduleSearchMatchReveal(
            _ range: NSRange,
            in textView: UITextView
        ) {
            cancelPositionRestore()
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
            (textView as? MarkdownTextView)?.markdownCellController.end()
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

        func applyInitialPreviewInsets(in textView: UITextView) {
            guard parent.isReadOnly, let insets = parent.initialPreviewInsets else { return }
            textView.contentInsetAdjustmentBehavior = .never
            if textView.contentInset != insets { textView.contentInset = insets }
            textView.scrollIndicatorInsets = insets
        }

        private func restoreInitialPreviewIfNeeded(in textView: UITextView) {
            guard parent.isReadOnly, let window = textView.window,
                  textView.bounds.width > 0,
                  textView.bounds.height > 0,
                  let position = parent.initialPreviewPosition else { return }
            let origin = textView.convert(textView.bounds, to: window).minY
            let geometry = centerGeometry(for: textView)
            guard pendingInitialPreviewPosition != nil
                    || initialPreviewGeometry != geometry || initialPreviewOriginY != origin
            else { return }
            // A lazy navigation preview must be positioned before its first
            // paint, including the outgoing screen during a link push.
            pendingInitialPreviewPosition = nil
            initialPreviewGeometry = geometry
            initialPreviewOriginY = origin
            applyPreviewPosition(position, origin: origin, in: textView)
        }

        private func applyPreviewPosition(_ position: MarkdownEditorPosition,
                                          origin: CGFloat, in textView: UITextView) {
            cancelPositionRestore()
            let offset = parent.initialPreviewOriginY.map { $0 - origin } ?? 0
            let previewPosition = MarkdownEditorPosition(
                selection: position.selection, scrollAnchor: position.scrollAnchor,
                scrollAnchorOffset: position.scrollAnchorOffset + Double(offset)
            )
            restore(previewPosition, generation: positionRestoreGeneration,
                    in: textView, completion: nil, immediately: true)
        }

        private func cancelPositionRestore() {
            positionRestoreGeneration &+= 1
            pendingPosition = nil
            let completion = pendingPositionCompletion
            pendingPositionCompletion = nil
            // An explicit scroll, focus, or reveal owns the new viewport.
            // A canceled restoration must still release its retained preview.
            completion?()
        }

        private func schedulePositionRestore(
            _ position: MarkdownEditorPosition,
            in textView: UITextView,
            completion: (() -> Void)? = nil
        ) {
            cancelPositionRestore()
            pendingPosition = position
            if let completion {
                let generation = positionRestoreGeneration
                var completed = false
                pendingPositionCompletion = { [weak self] in
                    guard !completed else { return }
                    completed = true
                    if self?.positionRestoreGeneration == generation {
                        self?.pendingPositionCompletion = nil
                    }
                    completion()
                }
            }
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
                let completion = self.pendingPositionCompletion
                self.pendingPosition = nil
                self.restore(
                    position,
                    generation: self.positionRestoreGeneration,
                    in: textView,
                    completion: completion
                )
            }
        }

        private func restore(
            _ position: MarkdownEditorPosition,
            generation: Int,
            in textView: UITextView,
            completion: (() -> Void)?,
            immediately: Bool = false
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
            if immediately {
                finishRestore(position, generation: generation, attemptsRemaining: 0,
                              in: textView, completion: completion)
                return
            }
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
                    self.pendingPositionCompletion = completion
                    return
                }
                self.finishRestore(
                    position,
                    generation: generation,
                    attemptsRemaining: 2,
                    in: textView,
                    completion: completion
                )
            }
        }

        private func finishRestore(
            _ position: MarkdownEditorPosition,
            generation: Int,
            attemptsRemaining: Int,
            in textView: UITextView,
            completion: (() -> Void)?
        ) {
            guard generation == positionRestoreGeneration else { return }
            let source = textView.text ?? ""
            let anchor = source.clampedSelection(
                NSRange(location: position.scrollAnchor, length: 0)
            ).location
            textView.layoutIfNeeded()

            guard let anchorRect = localCaretRect(at: anchor, in: textView)
            else { completion?(); return }
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
                  abs(restoredOffset - offset) > 1 else {
                // The incoming live editor may now replace the retained
                // navigation preview without exposing its initial offset.
                completion?()
                return
            }
            textView.setNeedsLayout()
            DispatchQueue.main.async { [weak self, weak textView] in
                guard let self, let textView,
                      generation == self.positionRestoreGeneration else {
                    return
                }
                guard textView.markedTextRange == nil else {
                    self.pendingPosition = position
                    self.pendingPositionCompletion = completion
                    return
                }
                textView.layoutIfNeeded()
                self.finishRestore(
                    position,
                    generation: generation,
                    attemptsRemaining: attemptsRemaining - 1,
                    in: textView,
                    completion: completion
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
            refreshTableCommands(in: textView)
            MarkdownPresentation.syntaxCache(for: textView).acknowledgeNativeText()
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
            cancelPositionRestore()
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
