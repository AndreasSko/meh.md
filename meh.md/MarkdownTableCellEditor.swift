import Foundation
import ObjectiveC
#if os(macOS)
import AppKit
#else
import UIKit
#endif

nonisolated(unsafe) private var cellEditorControllerKey: UInt8 = 0

extension MarkdownTextView {
    var markdownCellController: MarkdownTableCellEditorController {
        if let controller = objc_getAssociatedObject(self, &cellEditorControllerKey)
            as? MarkdownTableCellEditorController { return controller }
        let controller = MarkdownTableCellEditorController(owner: self)
        objc_setAssociatedObject(self, &cellEditorControllerKey, controller,
                                 .OBJC_ASSOCIATION_RETAIN_NONATOMIC)
        return controller
    }

    var markdownCellSource: String {
#if os(macOS)
        string
#else
        text ?? ""
#endif
    }

    var markdownCellSourceHasMarkedText: Bool {
#if os(macOS)
        hasMarkedText()
#else
        markedTextRange != nil
#endif
    }

    var markdownCellSourceSelection: NSRange {
        get {
#if os(macOS)
            selectedRange()
#else
            selectedRange
#endif
        }
        set {
#if os(macOS)
            setSelectedRange(newValue)
#else
            selectedRange = newValue
#endif
        }
    }

    func applyMarkdownCellSourceChange(_ change: MarkdownEditingChange) {
        let expected = (markdownCellSource as NSString).replacingCharacters(
            in: change.range, with: change.replacement
        )
        if markdownCellSource.utf8.elementsEqual(expected.utf8) {
            markdownCellSourceSelection = expected.clampedSelection(change.selection)
            return
        }
#if os(macOS)
        breakUndoCoalescing()
        insertText(change.replacement, replacementRange: change.range)
        breakUndoCoalescing()
#else
        selectedRange = change.range
        insertText(change.replacement)
#endif
        if markdownCellSource.utf8.elementsEqual(expected.utf8) {
            markdownCellSourceSelection = expected.clampedSelection(change.selection)
        }
#if !os(macOS)
        delegate?.textViewDidChange?(self)
#endif
    }
}

/// A single cell editor belongs to the note, not to a range-keyed scroll view.
/// The source text view owns all durable changes and undo registrations.
@MainActor
final class MarkdownTableCellEditorController: NSObject {
    private weak var owner: MarkdownTextView?
    private(set) var target: MarkdownTableCellEditing.Target?
    private var sourceSnapshot = ""
    private(set) var forwarding = false
    private var updating = false
    private var activationPending = false
    var onCompositionEnded: (() -> Void)?
    private var horizontalOffset: CGFloat = 0
    private var widths: [CGFloat]?
#if os(macOS)
    let editor = MarkdownTableNativeCellEditor(usingTextLayoutManager: true)
#else
    let editor = MarkdownTableNativeCellEditor()
#endif
#if os(macOS)
    private let clip = NSView(frame: .zero)
#else
    private let clip = UIView(frame: .zero)
#endif

    init(owner: MarkdownTextView) {
        self.owner = owner
        super.init()
        editor.controller = self
        editor.delegate = self
#if os(macOS)
        clip.wantsLayer = true
        clip.layer?.masksToBounds = true
        editor.drawsBackground = false
        editor.isRichText = false
        editor.isVerticallyResizable = false
        editor.textContainerInset = .zero
        editor.textContainer?.lineFragmentPadding = 0
        editor.setAccessibilityIdentifier("markdown.table.cell.editor")
#else
        clip.clipsToBounds = true
        editor.backgroundColor = .clear
        editor.isScrollEnabled = false
        editor.textContainerInset = .zero
        editor.textContainer.lineFragmentPadding = 0
        editor.accessibilityIdentifier = "markdown.table.cell.editor"
        editor.autocapitalizationType = .sentences
        editor.returnKeyType = .next
#endif
        clip.addSubview(editor)
        clip.isHidden = true
    }

    var isActive: Bool { target != nil }
    var canEdit: Bool { isActive && owner?.isEditable == true && !hasMarkedText }
    var hasMarkedText: Bool {
#if os(macOS)
        editor.composing || editor.hasMarkedText()
#else
        editor.composing || editor.markedTextRange != nil
#endif
    }
    var hasFocus: Bool {
#if os(macOS)
        owner?.window?.firstResponder === editor
#else
        editor.isFirstResponder
#endif
    }
    var sourceUndoManager: UndoManager? { owner?.undoManager }

    private var localText: String {
#if os(macOS)
        editor.string
#else
        editor.text ?? ""
#endif
    }
    private var localSelection: NSRange {
        get {
#if os(macOS)
            editor.selectedRange()
#else
            editor.selectedRange
#endif
        }
        set {
#if os(macOS)
            editor.setSelectedRange(newValue)
#else
            editor.selectedRange = newValue
#endif
        }
    }

    @discardableResult
    func begin(tableRange: NSRange, row: Int, column: Int, point: CGPoint? = nil) -> Bool {
        guard let owner, owner.isEditable, !hasMarkedText,
              !owner.markdownCellSourceHasMarkedText,
              MarkdownLivePreview.snapshot(for: owner).mode == .livePreview,
              let table = owner.markdownSyntaxCache.result(for: owner.markdownCellSource)
                .tables.first(where: { $0.range == tableRange }),
              let next = MarkdownTableCellEditing.target(
                text: owner.markdownCellSource, table: table, row: row, column: column
              ) else { return false }
        horizontalOffset = owner.markdownTableDrawingOffsets[tableRange, default: 0]
        widths = owner.markdownSyntaxCache.tableLayout?.rows.first(where: {
            $0.tableRange == tableRange
        })?.columnWidths
        target = next
        sourceSnapshot = owner.markdownCellSource
        if clip.superview == nil { owner.addSubview(clip) }
        clip.isHidden = false
        installText(selection: NSRange(location: next.contentRange.length, length: 0))
        synchronizeSelection()
        owner.markdownSyntaxCache.tableRefresh?()
#if os(macOS)
        if let overlay = owner.markdownTableScrollOverlays.first(where: { $0.tableRange == next.tableRange }),
           overlay.rowFrames.indices.contains(row) {
            let x = overlay.tableRows[row].columnWidths.prefix(column).reduce(0, +)
            overlay.revealMarkdownTableCellFrame(CGRect(
                x: x, y: overlay.rowFrames[row].minY,
                width: overlay.tableRows[row].columnWidths[column],
                height: overlay.rowFrames[row].height
            ))
            horizontalOffset = overlay.elasticHorizontalOffset
        }
#endif
        updateGeometry()
#if os(macOS)
        owner.window?.makeFirstResponder(editor)
        owner.markdownDidBeginEditing?()
#else
        editor.inputAccessoryView = owner.inputAccessoryView
        editor.becomeFirstResponder()
        owner.delegate?.textViewDidBeginEditing?(owner)
#endif
        if let point {
#if os(macOS)
            let p = editor.convert(point, from: owner)
            let index = editor.characterIndexForInsertion(at: p)
            localSelection = NSRange(location: min(index, (localText as NSString).length), length: 0)
#else
            let p = editor.convert(point, from: owner)
            if let position = editor.closestPosition(to: p) {
                localSelection = NSRange(location: editor.offset(
                    from: editor.beginningOfDocument, to: position), length: 0)
            }
#endif
            synchronizeSelection()
        }
        revealEditingSelection()
        return true
    }

    func activateSourceSelection() {
        guard !activationPending, !isActive else { return }
        activationPending = true
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.activationPending = false
            guard let owner = self.owner, owner.isEditable,
                  MarkdownLivePreview.snapshot(for: owner).mode == .livePreview,
                  !self.hasMarkedText, !owner.markdownCellSourceHasMarkedText else { return }
#if os(macOS)
            guard owner.window?.firstResponder === owner else { return }
#else
            guard owner.isFirstResponder else { return }
#endif
            let selection = owner.markdownCellSourceSelection
            guard let target = MarkdownTableCellEditing.target(
                text: owner.markdownCellSource, selection: selection
            ), self.begin(tableRange: target.tableRange, row: target.row, column: target.column)
            else { return }
            self.localSelection = MarkdownTableCellEditing.localSelection(selection, in: target)
            self.synchronizeSelection()
            self.revealEditingSelection()
        }
    }

    func end(focusSource: Bool = false) {
        guard isActive else { return }
        target = nil
        widths = nil
        clip.isHidden = true
        DispatchQueue.main.async { [weak owner] in
            owner?.markdownSyntaxCache.tableRefresh?()
        }
#if os(macOS)
        if hasFocus { owner?.window?.makeFirstResponder(focusSource ? owner : nil) }
#else
        if editor.isFirstResponder {
            if focusSource { owner?.becomeFirstResponder() }
            else { editor.resignFirstResponder() }
        }
#endif
    }

    /// Called before creating a presentation snapshot, including remote updates.
    func synchronize(mode: MarkdownEditorMode) {
        guard !updating, let owner, let current = target else { return }
        if mode != .livePreview || !owner.isEditable { end(); return }
        guard !hasMarkedText else { return }
        let source = owner.markdownCellSource
        if !source.utf8.elementsEqual(sourceSnapshot.utf8) {
            guard let next = MarkdownTableCellEditing.rebased(
                current, from: sourceSnapshot, to: source
            ) else { end(); return }
            let selection = MarkdownTableCellEditing.localSelection(
                owner.markdownCellSourceSelection, in: next
            )
            target = next
            sourceSnapshot = source
            installText(selection: selection)
        }
        updateGeometry()
    }

    var renderedTableRange: NSRange? { target?.tableRange }
    var fixedColumnWidths: [CGFloat]? { isActive ? widths : nil }

    func synchronizeSelection() {
        guard !updating, let owner, let target, !hasMarkedText else { return }
        updating = true
        let selection = MarkdownTableCellEditing.sourceSelection(localSelection, in: target)
        if owner.markdownCellSourceSelection != selection {
            owner.markdownCellSourceSelection = selection
        }
        updating = false
    }

    private func installText(selection: NSRange) {
        guard let owner, let target else { return }
        updating = true
        defer { updating = false }
        let value = MarkdownTableCellEditing.text(in: owner.markdownCellSource, target: target)
        let undo = sourceUndoManager
        let enabled = undo?.isUndoRegistrationEnabled == true
        if enabled { undo?.disableUndoRegistration() }
#if os(macOS)
        editor.string = value
#else
        editor.text = value
#endif
        if enabled { undo?.enableUndoRegistration() }
        localSelection = value.clampedSelection(selection)
    }

    func replaceLocal(range: NSRange, replacement: String) {
        guard !updating, !hasMarkedText, let owner, owner.isEditable, let target else { return }
        let cell = localText as NSString
        guard range.location >= 0, NSMaxRange(range) <= cell.length else { return }
        let value = cell.replacingCharacters(in: range, with: replacement)
        let selection = NSRange(location: range.location + (replacement as NSString).length, length: 0)
        guard let change = MarkdownTableCellEditing.change(
            text: owner.markdownCellSource, target: target,
            replacement: value, selection: selection
        ) else { return }
        apply(change)
    }

    func commitComposition() {
        guard !updating, let owner, !hasMarkedText else { return }
        // Updates received while a candidate was marked still need applying
        // when composition is cancelled or accepts the unchanged cell text.
        guard owner.isEditable, let target,
              let change = MarkdownTableCellEditing.change(
                text: owner.markdownCellSource, target: target,
                replacement: localText, selection: localSelection
              ) else {
            onCompositionEnded?()
            synchronize(mode: MarkdownLivePreview.snapshot(for: owner).mode)
            return
        }
        let expected = (owner.markdownCellSource as NSString).replacingCharacters(
            in: change.range, with: change.replacement
        )
        let unchanged = expected.utf8.elementsEqual(owner.markdownCellSource.utf8)
        apply(change)
        if unchanged { onCompositionEnded?() }
    }

    func undoCellChange(redo: Bool = false) {
        guard let owner, owner.isEditable, !hasMarkedText,
              let undo = sourceUndoManager,
              redo ? undo.canRedo : undo.canUndo else { return }
        if redo { undo.redo() } else { undo.undo() }
#if !os(macOS)
        owner.delegate?.textViewDidChange?(owner)
#endif
        owner.markdownSyntaxCache.tableRefresh?()
        synchronize(mode: MarkdownLivePreview.snapshot(for: owner).mode)
#if !os(macOS)
        UIMenuSystem.main.setNeedsRevalidate()
#endif
    }

    private func apply(_ change: MarkdownEditingChange) {
        guard let owner else { return }
        let previousTarget = target
        let expected = (owner.markdownCellSource as NSString).replacingCharacters(
            in: change.range, with: change.replacement
        )
        forwarding = true
        owner.applyMarkdownCellSourceChange(change)
        // Resolve the accepted selection, which can differ after a merged commit.
        let acceptedTarget: MarkdownTableCellEditing.Target?
        if owner.markdownCellSource.utf8.elementsEqual(expected.utf8), let previousTarget {
            acceptedTarget = MarkdownTableCellEditing.targetAfter(
                change: change, priorTarget: previousTarget, source: expected
            )
        } else {
            acceptedTarget = MarkdownTableCellEditing.target(
                text: owner.markdownCellSource, selection: owner.markdownCellSourceSelection
            )
        }
        if let next = acceptedTarget {
            target = next
            sourceSnapshot = owner.markdownCellSource
            installText(selection: MarkdownTableCellEditing.localSelection(
                owner.markdownCellSourceSelection, in: next
            ))
        } else { end() }
        forwarding = false
        owner.markdownSyntaxCache.tableRefresh?()
        updateGeometry()
        revealEditingSelection()
#if !os(macOS)
        // The source owns undo actions, so refresh the focused cell's command
        // availability after a source-backed edit.
        UIMenuSystem.main.setNeedsRevalidate()
#endif
    }

    @discardableResult
    func perform(_ command: MarkdownEditingCommand) -> Bool {
        guard let owner, isActive, !hasMarkedText else { return false }
        synchronizeSelection()
        forwarding = true
        let performed = owner.performMarkdownCommand(command)
        forwarding = false
        guard performed else { return false }
        if let next = MarkdownTableCellEditing.target(
            text: owner.markdownCellSource, selection: owner.markdownCellSourceSelection
        ) {
            target = next
            sourceSnapshot = owner.markdownCellSource
            widths = nil // A structural command may change the column count.
            installText(selection: MarkdownTableCellEditing.localSelection(
                owner.markdownCellSourceSelection, in: next
            ))
            owner.markdownSyntaxCache.tableRefresh?()
#if os(macOS)
            owner.window?.makeFirstResponder(editor)
#else
            editor.becomeFirstResponder()
#endif
            revealEditingSelection()
        } else { end(focusSource: true) }
        return true
    }

    func showFind() {
        guard let owner, !hasMarkedText else { return }
        end(focusSource: true)
#if os(macOS)
        let sender = NSMenuItem()
        sender.tag = NSTextFinder.Action.showFindInterface.rawValue
        owner.performFindPanelAction(sender)
#else
        owner.resignFirstResponder()
        owner.findInteraction?.presentFindNavigator(showingReplace: false)
#endif
    }

    func nextRow() {
        guard let owner, let current = target, !hasMarkedText else { return }
        let tables = owner.markdownSyntaxCache.result(for: owner.markdownCellSource).tables
        guard let table = tables.first(where: { $0.range == current.tableRange }) else { return }
        if current.row == table.rows.count {
            guard perform(.tableRowBelow), let updated = target else { return }
            let latest = owner.markdownSyntaxCache.result(for: owner.markdownCellSource).tables
                .first(where: { $0.range == updated.tableRange })
            if let latest {
                _ = begin(tableRange: latest.range, row: min(current.row + 1, latest.rows.count),
                          column: current.column)
            }
        } else {
            _ = begin(tableRange: table.range, row: current.row + 1, column: current.column)
        }
        localSelection = NSRange(location: 0, length: (localText as NSString).length)
        synchronizeSelection()
        revealEditingSelection()
    }

    private func revealEditingSelection() {
#if os(macOS)
        updateGeometry(reveal: true)
#else
        guard let owner, let target,
              let overlay = owner.markdownTableScrollOverlays.first(where: {
                  $0.tableRange == target.tableRange
              }), overlay.rowFrames.indices.contains(target.row),
              overlay.tableRows.indices.contains(target.row),
              overlay.tableRows[target.row].columnWidths.indices.contains(target.column),
              let selection = editor.selectedTextRange else { return }
        editor.layoutIfNeeded()
        let caret = editor.caretRect(for: selection.end)
        guard !caret.isNull, caret.minX.isFinite, caret.minY.isFinite,
              caret.height > 0 else { return }
        let padding = owner.markdownSyntaxCache.tableLayout?.padding ?? 7
        let columnX = overlay.tableRows[target.row].columnWidths
            .prefix(target.column).reduce(0, +)
        // A table row can exceed the keyboard viewport at large text sizes.
        // Reveal the native insertion point instead of the complete row/cell.
        // Use logical content coordinates even when the cell clip is offscreen.
        let frame = caret.offsetBy(
            dx: columnX + padding,
            dy: overlay.rowFrames[target.row].minY + padding
        ).insetBy(dx: -8, dy: -8)
        overlay.revealMarkdownTableCellFrame(frame)
        horizontalOffset = overlay.elasticHorizontalOffset
        updateGeometry()
#endif
    }

    func updateGeometry(reveal: Bool = false) {
        guard let owner, let target,
              let overlay = owner.markdownTableScrollOverlays.first(where: {
                $0.tableRange == target.tableRange
              }), overlay.tableRows.indices.contains(target.row),
              overlay.rowFrames.indices.contains(target.row),
              overlay.tableRows[target.row].columnWidths.indices.contains(target.column)
              else { return }
        let row = overlay.tableRows[target.row]
        let padding = owner.markdownSyntaxCache.tableLayout?.padding ?? 7
        let x = row.columnWidths.prefix(target.column).reduce(0, +)
        let contentRect = CGRect(
            x: x, y: overlay.rowFrames[target.row].minY,
            width: row.columnWidths[target.column], height: row.height
        )
        horizontalOffset = min(max(0, horizontalOffset),
                               max(0, overlay.contentWidth - overlay.frame.width))
        _ = owner.markdownSyntaxCache.setTableHorizontalOffset(horizontalOffset, for: target.tableRange)
        overlay.setNativeHorizontalOffset(horizontalOffset)
        // Match the editor clip to the table's current horizontal viewport.
        let offset = overlay.elasticHorizontalOffset
        let full = CGRect(x: overlay.frame.minX + x - offset + padding,
                          y: overlay.frame.minY + contentRect.minY + padding,
                          width: max(1, contentRect.width - 2 * padding),
                          height: max(1, contentRect.height - 2 * padding))
        let viewport = CGRect(x: overlay.frame.minX, y: full.minY,
                              width: overlay.frame.width, height: full.height)
        let visible = full.intersection(viewport)
        let clippedFrame = visible.isNull ? .zero : visible
        if clip.frame != clippedFrame { clip.frame = clippedFrame }
#if os(macOS)
        owner.addSubview(clip, positioned: .above, relativeTo: nil)
#else
        owner.bringSubviewToFront(clip)
#endif
        let editorFrame = CGRect(x: full.minX - clip.frame.minX, y: 0,
                                 width: full.width, height: full.height)
        if editor.frame != editorFrame { editor.frame = editorFrame }
#if os(macOS)
        editor.textContainer?.containerSize = CGSize(width: full.width, height: .greatestFiniteMagnitude)
        let fallbackFont = owner.typingAttributes[.font] as? NSFont
            ?? MarkdownPresentation.editorBodyFont
        let cellFont = row.cells[target.column].length > 0
            ? row.cells[target.column].attribute(.font, at: 0, effectiveRange: nil) as? NSFont
                ?? fallbackFont : fallbackFont
        if editor.font != cellFont { editor.font = cellFont }
        editor.textColor = .textColor
#else
        let fallbackFont = owner.typingAttributes[.font] as? UIFont
            ?? MarkdownPresentation.editorBodyFont
        let cellFont = row.cells[target.column].length > 0
            ? row.cells[target.column].attribute(.font, at: 0, effectiveRange: nil) as? UIFont
                ?? fallbackFont : fallbackFont
        if editor.font != cellFont { editor.font = cellFont }
        editor.textColor = .label
#endif
        editor.alignmentForCell(row.cells[target.column])
#if os(macOS)
        editor.setAccessibilityLabel(String(localized: "Row \(target.row + 1), column \(target.column + 1)"))
        if reveal {
            owner.scrollToVisible(CGRect(x: overlay.frame.minX, y: full.minY,
                                        width: overlay.frame.width, height: full.height))
        }
#else
        let header = overlay.tableRows.first?.cells[target.column].string ?? ""
        editor.accessibilityLabel = String(localized: "\(header), row \(target.row + 1), column \(target.column + 1)")
#endif
    }

    func didScroll(offset: CGFloat, tableRange: NSRange) {
        guard target?.tableRange == tableRange else { return }
        horizontalOffset = offset
        updateGeometry()
    }
}

#if os(macOS)
extension MarkdownTableCellEditorController: NSTextViewDelegate {
    func textView(_ textView: NSTextView, shouldChangeTextIn affectedCharRange: NSRange,
                  replacementString: String?) -> Bool {
        if editor.composing || updating { return true }
        guard let replacementString else { return false }
        replaceLocal(range: affectedCharRange, replacement: replacementString)
        return false
    }
    func textViewDidChangeSelection(_ notification: Notification) { synchronizeSelection() }
}
final class MarkdownTableNativeCellEditor: NSTextView {
    weak var controller: MarkdownTableCellEditorController?
    var composing = false
    var pasting = false
    fileprivate var compositionDepth = 0
    fileprivate var compositionEnding = false
    override var undoManager: UndoManager? { controller?.sourceUndoManager }
    override func insertText(_ insertString: Any, replacementRange: NSRange) {
        guard composing else {
            super.insertText(insertString, replacementRange: replacementRange)
            return
        }
        mutateComposition(finishing: true) {
            super.insertText(insertString, replacementRange: replacementRange)
            super.unmarkText()
        }
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
        case ("c", [.command, .shift]): command = .inlineCode
        case ("f", .command):
            controller?.showFind()
            return true
        default: command = nil
        }
        if let command, controller?.perform(command) == true { return true }
        return super.performKeyEquivalent(with: event)
    }
    override func insertTab(_ sender: Any?) { _ = controller?.perform(.tableNextCell) }
    override func insertBacktab(_ sender: Any?) { _ = controller?.perform(.tablePreviousCell) }
    override func insertNewline(_ sender: Any?) { controller?.nextRow() }
    override func cancelOperation(_ sender: Any?) {
        controller?.end(focusSource: true)
    }
    override func setMarkedText(_ string: Any, selectedRange: NSRange, replacementRange: NSRange) {
        composing = true
        mutateComposition {
            super.setMarkedText(string, selectedRange: selectedRange, replacementRange: replacementRange)
        }
    }
    override func unmarkText() {
        mutateComposition(finishing: true) { super.unmarkText() }
    }
    func alignmentForCell(_ cell: NSAttributedString) {
        let desired = (cell.length > 0 ? cell.attribute(.paragraphStyle, at: 0, effectiveRange: nil)
            as? NSParagraphStyle : nil)?.alignment ?? .left
        if alignment != desired { alignment = desired }
    }
}
#else
extension MarkdownTableCellEditorController: UITextViewDelegate {
    func textView(_ textView: UITextView, shouldChangeTextIn range: NSRange,
                  replacementText text: String) -> Bool {
        if editor.composing || updating { return true }
        if (text == "\n" || text == "\r"), !editor.pasting { nextRow(); return false }
        if text == "\t", !editor.pasting { _ = perform(.tableNextCell); return false }
        replaceLocal(range: range, replacement: text)
        return false
    }
    func textViewDidChangeSelection(_ textView: UITextView) { synchronizeSelection() }
}
final class MarkdownTableNativeCellEditor: UITextView, UIAccessibilityContainerDataTableCell {
    weak var controller: MarkdownTableCellEditorController?
    var composing = false
    var pasting = false
    fileprivate var compositionDepth = 0
    fileprivate var compositionEnding = false
    override var undoManager: UndoManager? { controller?.sourceUndoManager }
    init() { super.init(frame: .zero, textContainer: nil) }
    required init?(coder: NSCoder) { fatalError("init(coder:) is unavailable") }
    override func setMarkedText(_ markedText: String?, selectedRange: NSRange) {
        composing = true
        mutateComposition {
            super.setMarkedText(markedText, selectedRange: selectedRange)
        }
    }
    override func unmarkText() {
        mutateComposition(finishing: true) { super.unmarkText() }
    }
    override func insertText(_ text: String) {
        guard composing else { super.insertText(text); return }
        mutateComposition(finishing: true) {
            super.insertText(text)
            super.unmarkText()
        }
    }
    override func paste(_ sender: Any?) {
        pasting = true
        defer { pasting = false }
        super.paste(sender)
    }

    override func canPerformAction(_ action: Selector, withSender sender: Any?) -> Bool {
        let commands: [Selector] = [#selector(nextCell(_:)), #selector(previousCell(_:)),
            #selector(nextRow(_:)), #selector(bold(_:)), #selector(italic(_:)), #selector(link(_:)),
            #selector(code(_:)), #selector(findNote(_:)), #selector(done(_:))]
        if commands.contains(action) { return controller?.canEdit == true }
        if action == #selector(undoCell(_:)) {
            return controller?.canEdit == true && undoManager?.canUndo == true
        }
        if action == #selector(redoCell(_:)) {
            return controller?.canEdit == true && undoManager?.canRedo == true
        }
        return super.canPerformAction(action, withSender: sender)
    }

    override var keyCommands: [UIKeyCommand]? {
        guard controller?.hasMarkedText != true else { return super.keyCommands }
        let commands: [(String, UIKeyModifierFlags, Selector)] = [
            ("\t", [], #selector(nextCell(_:))), ("\t", .shift, #selector(previousCell(_:))),
            ("\r", [], #selector(nextRow(_:))),
            ("\n", [], #selector(nextRow(_:))),
            ("z", .command, #selector(undoCell(_:))),
            ("z", [.command, .shift], #selector(redoCell(_:))),
            ("b", .command, #selector(bold(_:))), ("i", .command, #selector(italic(_:))),
            ("k", .command, #selector(link(_:))), ("c", [.command, .shift], #selector(code(_:))),
            ("f", .command, #selector(findNote(_:))),
            (UIKeyCommand.inputEscape, [], #selector(done(_:))),
        ]
        let inherited = (super.keyCommands ?? []).filter { key in
            let duplicate = commands.contains { input, flags, _ in
                key.input?.lowercased() == input && key.modifierFlags == flags
            }
            return !duplicate
        }
        return commands.map { input, flags, action in
            let key = UIKeyCommand(input: input, modifierFlags: flags, action: action)
            key.wantsPriorityOverSystemBehavior = true
            return key
        } + inherited
    }
    func accessibilityRowRange() -> NSRange {
        NSRange(location: controller?.target?.row ?? 0, length: 1)
    }
    func accessibilityColumnRange() -> NSRange {
        NSRange(location: controller?.target?.column ?? 0, length: 1)
    }

    @objc private func nextRow(_ sender: UIKeyCommand) { controller?.nextRow() }
    @objc private func undoCell(_ sender: UIKeyCommand) { controller?.undoCellChange() }
    @objc private func redoCell(_ sender: UIKeyCommand) { controller?.undoCellChange(redo: true) }
    @objc private func nextCell(_ sender: UIKeyCommand) { _ = controller?.perform(.tableNextCell) }
    @objc private func previousCell(_ sender: UIKeyCommand) { _ = controller?.perform(.tablePreviousCell) }
    @objc private func bold(_ sender: UIKeyCommand) { _ = controller?.perform(.bold) }
    @objc private func italic(_ sender: UIKeyCommand) { _ = controller?.perform(.italic) }
    @objc private func link(_ sender: UIKeyCommand) { _ = controller?.perform(.link) }
    @objc private func code(_ sender: UIKeyCommand) { _ = controller?.perform(.inlineCode) }
    @objc private func findNote(_ sender: UIKeyCommand) { controller?.showFind() }
    @objc private func done(_ sender: UIKeyCommand) { controller?.end(focusSource: true) }
    func alignmentForCell(_ cell: NSAttributedString) {
        let desired = (cell.length > 0 ? cell.attribute(.paragraphStyle, at: 0, effectiveRange: nil)
            as? NSParagraphStyle : nil)?.alignment ?? .left
        if textAlignment != desired { textAlignment = desired }
    }
}
#endif

private extension MarkdownTableNativeCellEditor {
    func mutateComposition(finishing: Bool = false, _ operation: () -> Void) {
        // Native input methods can reenter insert/unmark while accepting a
        // candidate. Replay model updates only after the outermost mutation
        // restores undo registration, since replacement clears undo actions.
        let outermost = compositionDepth == 0
        let undo = undoManager
        let enabled = outermost && undo?.isUndoRegistrationEnabled == true
        if enabled { undo?.disableUndoRegistration() }
        compositionDepth += 1
        compositionEnding = compositionEnding || finishing
        operation()
        compositionDepth -= 1
        if enabled { undo?.enableUndoRegistration() }
        if outermost, compositionEnding {
            compositionEnding = false
            composing = false
            controller?.commitComposition()
        }
    }
}
