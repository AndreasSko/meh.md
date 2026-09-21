import NoteCore
import SwiftUI
import UIKit
import os

/// A disposable real editor/session, with no notebook catalog or CloudKit.
@MainActor
enum LargeNotePerformanceProbe {
    private static let log = OSLog(
        subsystem: "de.andreas-sk.meh-md.large-note-probe",
        category: .pointsOfInterest
    )

    static func run(in window: UIWindow) async {
        let directory = URL.documentsDirectory
        var report: [String: Any] = [:]
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let environment = ProcessInfo.processInfo.environment
            let kilobytes = Int(environment["EDITOR_PERFORMANCE_BLOCKS"] ?? "500") ?? 500
            let mode = MarkdownEditorMode(
                rawValue: environment["EDITOR_PERFORMANCE_MODE"] ?? "livePreview"
            ) ?? .livePreview
            try verifyMultilineBold()
            let initial = fixture(minimumBytes: kilobytes * 1_000)
            try initial.write(
                to: directory.appending(path: "large-note-fixture.md"),
                atomically: true, encoding: .utf8
            )
            // A unique location on every run; never open the user's notebook.
            let storageDirectory = directory.appending(path: UUID().uuidString)
            defer { try? FileManager.default.removeItem(at: storageDirectory) }
            let session = NoteSession(storage: NoteFileStorage(directory: storageDirectory))
            await session.load()
            try session.replaceAll(with: initial)
            try await session.flush()

            let navigation = MarkdownEditorNavigation()
            let controller = UIHostingController(rootView: NotebookNoteEditor(
                session: session, navigation: navigation, isInTrash: false,
                hasUnrecordedEdit: .constant(false), mode: mode
            ))
            let openStart = CACurrentMediaTime()
            window.rootViewController = controller
            controller.view.layoutIfNeeded()
            await nextIdle()
            guard let editor = findEditor(in: controller.view) else {
                throw ProbeError.failed("Native editor did not attach")
            }
            let openMS = milliseconds(since: openStart)
            guard editor.becomeFirstResponder() else {
                throw ProbeError.failed("Native editor could not become first responder")
            }
            editor.selectedRange = NSRange(location: initial.utf16.count, length: 0)
            editor.scrollRangeToVisible(editor.selectedRange)
            // Keep opening, scrolling, and the initial keyboard transition out
            // of the edit measurements. No artificial refresh/layout per edit.
            try await Task.sleep(for: .seconds(1))
            guard editor.isFirstResponder else {
                throw ProbeError.failed("Native editor lost focus before measurement")
            }

            let cache = editor.markdownSyntaxCache
            let initialFullParses = cache.parseCount
            let initialIncrementalParses = cache.incrementalParseCount
            var expected = initial
            var expectedCaret = initial.utf16.count
            var measurements: [String: [Double]] = ["open_to_idle_ms": [openMS]]
            var steps: [[String: Any]] = []
            var mainActorDelays: [Double] = []
            let monitor = Task { @MainActor in
                while !Task.isCancelled {
                    let start = CACurrentMediaTime()
                    do { try await Task.sleep(for: .milliseconds(10)) }
                    catch { break }
                    guard !Task.isCancelled else { break }
                    mainActorDelays.append(max(0, milliseconds(since: start) - 10))
                }
            }
            defer { monitor.cancel() }
            await Task.yield()
            func edit(_ kind: String, replacement: String, deleting: Bool = false) async throws {
                let oldSelection = editor.selectedRange
                let replacedRange = deleting
                    ? NSRange(location: oldSelection.location - 1, length: 1)
                    : oldSelection
                let fullParses = cache.parseCount
                let incrementalParses = cache.incrementalParseCount
                let signpost = OSSignpostID(log: log)
                os_signpost(.begin, log: log, name: "Large note edit", signpostID: signpost)
                let start = CACurrentMediaTime()
                if deleting { editor.deleteBackward() } else { editor.insertText(replacement) }
                let synchronousMS = milliseconds(since: start)
                await nextIdle()
                let idleMS = milliseconds(since: start)
                os_signpost(.end, log: log, name: "Large note edit", signpostID: signpost)
                measurements["\(kind)_synchronous_ms", default: []].append(synchronousMS)
                measurements["\(kind)_to_idle_ms", default: []].append(idleMS)
                steps.append(["action": kind, "synchronous_ms": synchronousMS,
                              "to_idle_ms": idleMS,
                              "presentation_current_at_idle": cache.currentPresentation != nil,
                              "full_parses": cache.parseCount - fullParses,
                              "incremental_parses": cache.incrementalParseCount - incrementalParses,
                              "formatted_utf16_length": cache.lastLayoutRange.length])
                expected = (expected as NSString).replacingCharacters(
                    in: replacedRange, with: replacement
                )
                expectedCaret = replacedRange.location + replacement.utf16.count
                // Outside the timed region; compare literal UTF-8, not Unicode
                // canonical equivalence, and check the native caret as well.
                guard editor.text.utf8.elementsEqual(expected.utf8),
                      session.text.utf8.elementsEqual(expected.utf8),
                      editor.selectedRange == NSRange(location: expectedCaret, length: 0)
                else { throw ProbeError.failed("Text or caret mismatch after \(kind)") }
                try await Task.sleep(for: .milliseconds(50))
            }
            for character in " A small bright star." {
                try await edit("typing", replacement: String(character))
            }
            for _ in 0..<6 { try await edit("deletion", replacement: "", deleting: true) }
            // Equivalent inserted text, without reading or replacing the user's
            // clipboard. This does not measure clipboard decoding or paste UI.
            try await edit("bulk_insert", replacement: "\n\nA **new observation** of the moon 🪐.\n")

            // Exercise unmatched delimiters away from EOF, one key at a time.
            // The ordinary line belongs to a short paragraph in the fixture.
            let source = expected as NSString
            let middle = source.length / 2
            let target = source.range(of: "An ordinary paragraph", options: [],
                                      range: NSRange(location: middle, length: source.length - middle))
            guard target.location != NSNotFound else {
                throw ProbeError.failed("Middle paragraph was not found")
            }
            editor.selectedRange = NSRange(location: target.location, length: 0)
            editor.scrollRangeToVisible(editor.selectedRange)
            try await Task.sleep(for: .seconds(1))
            for (kind, text) in [("middle_bold_open", "**"),
                                 ("middle_bold_typing", "bright"),
                                 ("middle_bold_close", "**")] {
                for character in text {
                    try await edit(kind, replacement: String(character))
                    guard cache.currentPresentation?.result == MarkdownSyntax.parse(expected) else {
                        throw ProbeError.failed("Incorrect presentation after \(kind)")
                    }
                }
            }

            // Synchronous preparation must finish before the final idle point.
            monitor.cancel()
            measurements["main_actor_scheduling_delay_ms"] = mainActorDelays
            guard cache.currentPresentation?.result == MarkdownSyntax.parse(expected),
                  editor.text.utf8.elementsEqual(expected.utf8),
                  editor.selectedRange == NSRange(location: expectedCaret, length: 0)
            else { throw ProbeError.failed("Final presentation is stale or changed text/caret") }

            let saveStart = CACurrentMediaTime()
            // Observe the real idle autosave rather than forcing a flush.
            while session.status != .saved, milliseconds(since: saveStart) < 15_000 {
                if case .saveFailed(let message) = session.status {
                    throw ProbeError.failed(message)
                }
                try await Task.sleep(for: .milliseconds(50))
            }
            guard session.status == .saved else { throw ProbeError.failed("Autosave timed out") }
            measurements["autosave_wait_including_debounce_ms"] = [milliseconds(since: saveStart)]
            let reloaded = NoteSession(storage: NoteFileStorage(directory: storageDirectory))
            await reloaded.load()
            guard reloaded.text.utf8.elementsEqual(expected.utf8), reloaded.status == .saved else {
                throw ProbeError.failed("Saved text did not round-trip")
            }
            report = [
                "scenario": "large-note", "mode": mode.rawValue,
                "requested_kb": kilobytes, "utf8_bytes": initial.utf8.count,
                "utf16_length": initial.utf16.count, "prior_edit_history": 0,
                "system": UIDevice.current.systemVersion,
                "device": environment["SIMULATOR_MODEL_IDENTIFIER"] ?? UIDevice.current.model,
                "source_and_selection_preserved": true, "saved_text_preserved": true,
                "final_presentation_verified": true,
                "multiline_bold_fonts_verified": true,
                "full_parses_during_edits": cache.parseCount - initialFullParses,
                "incremental_parses_during_edits": cache.incrementalParseCount - initialIncrementalParses,
                "measurements": measurements, "steps": steps,
                "measurement_note": "Native edit call and next main-run-loop idle; Synchronous formatting is checked after the final edit. Main-actor delay includes correctness checks and styling. Not display latency. Autosave wait includes debounce. No CloudKit or notebook catalog."
            ]
        } catch {
            report = ["scenario": "large-note", "source_and_selection_preserved": false,
                      "error": String(describing: error)]
        }
        do {
            let data = try JSONSerialization.data(
                withJSONObject: report, options: [.prettyPrinted, .sortedKeys]
            )
            try data.write(to: directory.appending(path: "performance.json"), options: .atomic)
        } catch { NSLog("Large-note report failed: %@", String(describing: error)) }
    }

    private static func fixture(minimumBytes: Int) -> String {
        let block = """
        ## Fictional observatory
        A **bright** star and a [map](https://example.test/map).
        An ordinary paragraph records the night's observations: Größe, café, and moon 🪐.
        * Outer orbit
          * Inner orbit with ==light== and ~~dust~~.
        > A quiet observation from the hill.
        ```swift
        let orbit = 42
        ```


        """
        return String(repeating: block, count: (minimumBytes + block.utf8.count - 1) / block.utf8.count)
            + "End of sample."
    }

    private static func verifyMultilineBold() throws {
        for mode in [MarkdownEditorMode.source, .livePreview] {
            let view = MarkdownTextView(usingTextLayoutManager: true)
            view.text = "**First line\nsecond line**\n\nPlain paragraph"
            MarkdownPresentation.configure(view, mode: mode)
            for (word, expectedBold) in [("First", true), ("second", true), ("Plain", false)] {
                let position = (view.text as NSString).range(of: word).location
                let font = view.textStorage.attribute(.font, at: position,
                                                       effectiveRange: nil) as? UIFont
                guard font?.fontDescriptor.symbolicTraits.contains(.traitBold) == expectedBold else {
                    throw ProbeError.failed("Incorrect multiline bold font for \(word) in \(mode)")
                }
            }
        }
    }

    private static func findEditor(in view: UIView) -> MarkdownTextView? {
        if let editor = view as? MarkdownTextView { return editor }
        return view.subviews.lazy.compactMap { findEditor(in: $0) }.first
    }

    private static func milliseconds(since start: CFTimeInterval) -> Double {
        (CACurrentMediaTime() - start) * 1_000
    }

    private static func nextIdle() async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            let observer = CFRunLoopObserverCreateWithHandler(
                nil, CFRunLoopActivity.beforeWaiting.rawValue, false, CFIndex.max
            ) { _, _ in continuation.resume() }
            CFRunLoopAddObserver(CFRunLoopGetMain(), observer, .commonModes)
        }
    }

    private enum ProbeError: Error {
        case failed(String)
    }
}
