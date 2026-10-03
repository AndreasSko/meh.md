#if NOTEBOOK_PERFORMANCE_HOST
import Foundation
import NoteCore
import QuartzCore
import SwiftUI
import UIKit

@MainActor
enum NotebookPerformanceHost {
    @MainActor
    final class Context {
        let directory: URL
        let noteID: UUID
        let replica: NotebookReplica
        let session: NoteSession
        let editor: MarkdownTextView
        let openToIdleMS: Double

        private let window: UIWindow
        private let priorMode: Any?
        private let hadPriorMode: Bool

        fileprivate init(
            directory: URL,
            noteID: UUID,
            replica: NotebookReplica,
            session: NoteSession,
            editor: MarkdownTextView,
            openToIdleMS: Double,
            window: UIWindow,
            priorMode: Any?,
            hadPriorMode: Bool
        ) {
            self.directory = directory
            self.noteID = noteID
            self.replica = replica
            self.session = session
            self.editor = editor
            self.openToIdleMS = openToIdleMS
            self.window = window
            self.priorMode = priorMode
            self.hadPriorMode = hadPriorMode
        }

        func reloadForVerification() async throws -> NoteSession {
            let verifier = NotebookReplica(directory: directory)
            try await verifier.load()
            return try await verifier.openNote(noteID)
        }

        func finish() async {
            try? await session.flush()
            // Wait for any local Recent Activity catalog write queued by the
            // real NotebookView edit callback before deleting the fixture.
            try? await replica.recordRecentActivity(for: noteID)
            window.rootViewController = UIViewController()
            if hadPriorMode {
                UserDefaults.standard.set(priorMode, forKey: "editor.mode")
            } else {
                UserDefaults.standard.removeObject(forKey: "editor.mode")
            }
        }
    }

    static func attach(
        initialText: String,
        mode: MarkdownEditorMode,
        in window: UIWindow
    ) async throws -> Context {
        let directory = FileManager.default.temporaryDirectory
            .appending(path: "meh-notebook-performance-\(UUID().uuidString)")
        try FileManager.default.createDirectory(
            at: directory, withIntermediateDirectories: true
        )
        let defaults = UserDefaults.standard
        let hadPriorMode = defaults.object(forKey: "editor.mode") != nil
        let priorMode = defaults.object(forKey: "editor.mode")
        var lastAttachState = "hosting controller not created"
        do {
            let replica = NotebookReplica(directory: directory)
            try await replica.createLocalNotebook()
            let noteID = try await replica.createNote(
                name: "Typing performance", text: initialText
            )
            let session = try await replica.openNote(noteID)
            // NotebookView's preferred-note restoration opens through this
            // same replica, so it receives the already registered session.
            guard try await replica.openNote(noteID) === session else {
                throw HostError.sessionWasNotReused
            }
            guard session.text.utf8.elementsEqual(initialText.utf8) else {
                throw HostError.noteTextMismatch
            }

            defaults.set(mode.rawValue, forKey: "editor.mode")
            let root = NotebookView(
                replica: replica,
                workspace: nil,
                sceneID: UUID(),
                preferredNoteID: noteID
            )
            let hostController = UIHostingController(rootView: root)
            let openStart = CACurrentMediaTime()
            window.rootViewController = hostController
            hostController.view.layoutIfNeeded()

            for _ in 0..<300 {
                let editor = findEditor(in: hostController.view)
                let editorTextMatches = editor?.text.utf8.elementsEqual(
                    initialText.utf8
                ) == true
                let sessionTextMatches = session.text.utf8.elementsEqual(
                    initialText.utf8
                )
                let selectionCallbackConfigured =
                    editor?.markdownLinkNavigation?.selectionChanged != nil
                lastAttachState = "editor=\(editor != nil), "
                    + "editorTextMatches=\(editorTextMatches), "
                    + "sessionTextMatches=\(sessionTextMatches), "
                    + "selectionCallbackConfigured=\(selectionCallbackConfigured)"
                if let editor, editorTextMatches, sessionTextMatches,
                   selectionCallbackConfigured {
                    return Context(
                        directory: directory,
                        noteID: noteID,
                        replica: replica,
                        session: session,
                        editor: editor,
                        openToIdleMS: (CACurrentMediaTime() - openStart) * 1_000,
                        window: window,
                        priorMode: priorMode,
                        hadPriorMode: hadPriorMode
                    )
                }
                try await Task.sleep(for: .milliseconds(20))
            }
            logFailure(
                state: lastAttachState,
                controller: hostController
            )
            throw HostError.editorDidNotAttach(lastAttachState)
        } catch {
            let preserveFailedHost = ProcessInfo.processInfo.environment[
                "EDITOR_PERFORMANCE_PRESERVE_FAILED_HOST"
            ] == "1"
            if !preserveFailedHost {
                window.rootViewController = UIViewController()
            }
            if hadPriorMode {
                defaults.set(priorMode, forKey: "editor.mode")
            } else {
                defaults.removeObject(forKey: "editor.mode")
            }
            if !preserveFailedHost {
                try? FileManager.default.removeItem(at: directory)
            }
            throw error
        }
    }

    private static func findEditor(in view: UIView) -> MarkdownTextView? {
        if let editor = view as? MarkdownTextView { return editor }
        for subview in view.subviews {
            if let editor = findEditor(in: subview) { return editor }
        }
        return nil
    }

    private static func logFailure(
        state: String,
        controller: UIViewController
    ) {
        var lines = ["Notebook performance host attach failed: \(state)"]
        func describe(_ view: UIView, depth: Int) {
            let indent = String(repeating: "  ", count: depth)
            var details: [String] = []
            if let label = view as? UILabel, let text = label.text {
                details.append("text=\(String(reflecting: text))")
            }
            if let button = view as? UIButton,
               let title = button.currentTitle {
                details.append("title=\(String(reflecting: title))")
            }
            let suffix = details.isEmpty ? "" : " " + details.joined(separator: " ")
            lines.append("\(indent)\(type(of: view))\(suffix)")
            for child in view.subviews { describe(child, depth: depth + 1) }
        }
        describe(controller.view, depth: 0)
        FileHandle.standardError.write(Data((lines.joined(separator: "\n") + "\n").utf8))
    }

    private enum HostError: Error {
        case editorDidNotAttach(String)
        case noteTextMismatch
        case sessionWasNotReused
    }
}
#else
import Foundation
import NoteCore
import SwiftUI
import UIKit

@MainActor
enum NotebookPerformanceHost {
    final class Context {
        var directory: URL { fatalError("Notebook host unavailable") }
        var noteID: UUID { fatalError("Notebook host unavailable") }
        var replica: NotebookReplica { fatalError("Notebook host unavailable") }
        var session: NoteSession { fatalError("Notebook host unavailable") }
        var editor: MarkdownTextView { fatalError("Notebook host unavailable") }
        var openToIdleMS: Double { fatalError("Notebook host unavailable") }

        func reloadForVerification() async throws -> NoteSession {
            fatalError("The notebook host is not compiled in this mode")
        }

        func finish() async {}
    }

    static func attach(
        initialText: String,
        mode: MarkdownEditorMode,
        in window: UIWindow
    ) async throws -> Context {
        fatalError("Set NOTEBOOK_PERFORMANCE_HOST to enable the notebook host")
    }
}
#endif
