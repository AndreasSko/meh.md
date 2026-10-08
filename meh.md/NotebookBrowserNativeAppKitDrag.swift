#if os(macOS)
import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// Installs source tracking on the native list without intercepting hit tests.
/// Clicks fail recognition so AppKit delivers their real events to the list.
@MainActor
struct NotebookBrowserAppKitDragReader: NSViewRepresentable {
    let state: NotebookBrowserDragState
    let canBegin: () -> Bool
    let sourceAt: (CGPoint) -> UUID?
    let selectSource: (UUID) -> Void
    let begin: (UUID) -> NSItemProvider

    func makeNSView(context: Context) -> ReaderView {
        let view = ReaderView()
        view.setAccessibilityElement(false)
        view.setAccessibilityHidden(true)
        view.configure(self)
        return view
    }

    func updateNSView(_ view: ReaderView, context: Context) {
        view.configure(self)
    }

    static func dismantleNSView(_ view: ReaderView, coordinator: ()) {
        view.disconnect()
        view.configuration = nil
    }

    final class ReaderView: NSView, NSGestureRecognizerDelegate, NSDraggingSource {
        fileprivate var configuration: NotebookBrowserAppKitDragReader?
        private var recognizer: SourceRecognizer?
        private weak var installedView: NSView?
        private weak var sessionState: NotebookBrowserDragState?
        private weak var activeSession: NSDraggingSession?
        private var sessionToken: UUID?

        func configure(_ configuration: NotebookBrowserAppKitDragReader) {
            if let previous = self.configuration,
               previous.state !== configuration.state {
                disconnect()
            }
            self.configuration = configuration
            connect()
        }

        override func viewDidMoveToSuperview() {
            super.viewDidMoveToSuperview()
            connect()
        }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            connect()
        }

        override func layout() {
            super.layout()
            connect()
        }

        override func hitTest(_ point: NSPoint) -> NSView? { nil }

        private func connect() {
            guard let window,
                  let scroll = configuration?.state.scrollView ?? enclosingScrollView,
                  scroll.window === window else {
                disconnect()
                return
            }
            let target = scroll.documentView.flatMap(Self.table(in:)) ?? scroll
            guard installedView !== target else { return }
            disconnect()
            let recognizer = SourceRecognizer(target: self, action: #selector(startDrag(_:)))
            recognizer.owner = self
            recognizer.delegate = self
            recognizer.delaysPrimaryMouseButtonEvents = true
            recognizer.isCancellableByScrollGesture = true
            recognizer.name = "Notebook native drag source"
            self.recognizer = recognizer
            installedView = target
            target.addGestureRecognizer(recognizer)
        }

        private static func table(in view: NSView) -> NSTableView? {
            if let table = view as? NSTableView { return table }
            for child in view.subviews {
                if let table = table(in: child) { return table }
            }
            return nil
        }

        func disconnect() {
            if let recognizer {
                recognizer.isEnabled = false
                installedView?.removeGestureRecognizer(recognizer)
                recognizer.owner = nil
                recognizer.delegate = nil
                recognizer.target = nil
            }
            recognizer = nil
            installedView = nil
            finishOwnedSession()
        }

        func gestureRecognizer(
            _ gestureRecognizer: NSGestureRecognizer,
            shouldAttemptToRecognizeWith event: NSEvent
        ) -> Bool {
            source(for: event) != nil
        }

        fileprivate func source(for event: NSEvent) -> UUID? {
            guard event.type == .leftMouseDown,
                  !event.modifierFlags.contains(.control),
                  let configuration, configuration.canBegin(),
                  !configuration.state.isSessionActive,
                  let installedView, let window,
                  let content = window.contentView else { return nil }
            // AppKit hit testing takes coordinates in the view's parent.
            let parentPoint = installedView.superview?.convert(
                event.locationInWindow, from: nil
            ) ?? event.locationInWindow
            var hit = installedView.hitTest(parentPoint)
            while let view = hit, view !== installedView {
                // NSTableView is itself an NSControl; its child controls are
                // disclosures, inline fields, and buttons that keep tracking.
                if let field = view as? NSTextField,
                   !field.isEditable, !field.isSelectable {
                    hit = view.superview
                    continue
                }
                if view is NSControl { return nil }
                hit = view.superview
            }
            let point = content.convert(event.locationInWindow, from: nil)
            return configuration.sourceAt(CGPoint(
                x: point.x,
                y: content.isFlipped ? point.y : content.bounds.height - point.y
            ))
        }

        @objc private func startDrag(_ recognizer: SourceRecognizer) {
            guard recognizer.consumeDragStart() else { return }
            guard sessionToken == nil, let id = recognizer.sourceID,
                  let configuration, configuration.canBegin(),
                  let sourceView = installedView, let window,
                  sourceView.window === window else {
                recognizer.cancelRecognition()
                return
            }
            configuration.selectSource(id)
            // The existing provider callback captures the synchronous payload.
            // The native pasteboard uses that token without asynchronously
            // loading the provider or exposing note contents to other apps.
            _ = configuration.begin(id)
            guard let drag = configuration.state.drag else {
                recognizer.cancelRecognition()
                return
            }
            let pasteboard = NSPasteboardItem()
            pasteboard.setData(Data(drag.token.uuidString.utf8), forType:
                NSPasteboard.PasteboardType(UTType.mehNotebookItem.identifier))
            let item = NSDraggingItem(pasteboardWriter: pasteboard)
            let preview = draggingPreview(in: sourceView, at: recognizer.startPoint)
            item.setDraggingFrame(preview.frame, contents: preview.image)
            sessionState = configuration.state
            sessionToken = drag.token
            activeSession = sourceView.beginDraggingSession(
                items: [item], gesture: recognizer, source: self
            )
            if activeSession == nil {
                finishOwnedSession()
                recognizer.cancelRecognition()
            }
        }

        private func draggingPreview(
            in source: NSView, at windowPoint: NSPoint
        ) -> (frame: NSRect, image: NSImage) {
            if let table = source as? NSTableView {
                let point = table.convert(windowPoint, from: nil)
                let row = table.row(at: point)
                if row >= 0, let view = table.rowView(atRow: row, makeIfNecessary: false),
                   !view.bounds.isEmpty,
                   let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds) {
                    view.cacheDisplay(in: view.bounds, to: bitmap)
                    let image = NSImage(size: view.bounds.size)
                    image.addRepresentation(bitmap)
                    return (view.convert(view.bounds, to: source), image)
                }
            }
            let image = NSImage(size: NSSize(width: 150, height: 32), flipped: false) { rect in
                NSColor.controlBackgroundColor.setFill()
                NSBezierPath(roundedRect: rect, xRadius: 6, yRadius: 6).fill()
                ("Move selected items" as NSString).draw(
                    at: NSPoint(x: 10, y: 8), withAttributes: [
                        .font: NSFont.systemFont(ofSize: NSFont.systemFontSize),
                        .foregroundColor: NSColor.labelColor
                    ])
                return true
            }
            let point = source.convert(windowPoint, from: nil)
            return (NSRect(x: point.x - 12, y: point.y - 16,
                           width: image.size.width, height: image.size.height), image)
        }

        func draggingSession(
            _ session: NSDraggingSession,
            sourceOperationMaskFor context: NSDraggingContext
        ) -> NSDragOperation {
            context == .withinApplication ? .move : []
        }

        func draggingSession(_ session: NSDraggingSession, willBeginAt screenPoint: NSPoint) {
            guard let state = sessionState, state.drag?.token == sessionToken else { return }
            state.isSessionActive = true
        }

        func draggingSession(
            _ session: NSDraggingSession, endedAt screenPoint: NSPoint,
            operation: NSDragOperation
        ) {
            guard activeSession == nil || activeSession === session else { return }
            finishOwnedSession()
        }

        func ignoreModifierKeys(for session: NSDraggingSession) -> Bool { true }

        private func finishOwnedSession() {
            if let state = sessionState, let token = sessionToken,
               state.drag?.token == token {
                state.reset()
            }
            activeSession = nil
            sessionState = nil
            sessionToken = nil
        }
    }

    final class SourceRecognizer: NSGestureRecognizer {
        fileprivate weak var owner: ReaderView?
        fileprivate private(set) var sourceID: UUID?
        fileprivate private(set) var startPoint: NSPoint = .zero
        private var currentPoint: NSPoint = .zero
        private var attemptedSession = false

        override func shouldBeRequiredToFail(by other: NSGestureRecognizer) -> Bool {
            // The list's selection pan starts before our drag threshold.
            // Let source recognition decide first; ordinary clicks fail at
            // mouse-up and release the list's delayed native event stream.
            if let pan = other as? NSPanGestureRecognizer,
               let view, pan.view === view, pan.buttonMask & 1 != 0 {
                return true
            }
            return super.shouldBeRequiredToFail(by: other)
        }

        override func mouseDown(with event: NSEvent) {
            super.mouseDown(with: event)
            sourceID = owner?.source(for: event)
            startPoint = event.locationInWindow
            currentPoint = startPoint
            if sourceID == nil { state = .failed }
        }

        override func mouseDragged(with event: NSEvent) {
            super.mouseDragged(with: event)
            currentPoint = event.locationInWindow
            if state == .possible, sourceID != nil,
               hypot(currentPoint.x - startPoint.x, currentPoint.y - startPoint.y) >= 5 {
                state = .began
            } else if state == .began || state == .changed {
                state = .changed
            }
        }

        override func mouseUp(with event: NSEvent) {
            super.mouseUp(with: event)
            currentPoint = event.locationInWindow
            if state == .possible { state = .failed }
            else if state == .began || state == .changed { state = .ended }
        }

        override func mouseCancelled(with event: NSEvent) {
            super.mouseCancelled(with: event)
            if state == .possible { state = .failed }
            else if state == .began || state == .changed { state = .cancelled }
        }

        override func location(in view: NSView?) -> NSPoint {
            view?.convert(currentPoint, from: nil) ?? currentPoint
        }

        fileprivate func cancelRecognition() {
            if state == .began || state == .changed { state = .cancelled }
        }

        fileprivate func consumeDragStart() -> Bool {
            guard !attemptedSession, state == .began || state == .changed else { return false }
            attemptedSession = true
            return true
        }

        override func reset() {
            super.reset()
            sourceID = nil
            startPoint = .zero
            currentPoint = .zero
            attemptedSession = false
        }
    }
}
#endif
