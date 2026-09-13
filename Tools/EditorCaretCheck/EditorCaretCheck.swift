import AppKit
import SwiftUI

@main
@MainActor
private enum EditorCaretCheck {
    private static var runner: Runner?

    static func main() {
        let application = NSApplication.shared
        application.setActivationPolicy(.regular)
        let runner = Runner(application: application)
        self.runner = runner
        runner.start()
        application.run()
    }
}

@MainActor
private final class Runner {
    private struct Configuration {
        let fontSize: Double
        let atEnd: Bool

        var description: String {
            "\(Int(fontSize))pt \(atEnd ? "end" : "middle")"
        }
    }

    private final class TextState {
        var text: String

        init(text: String) {
            self.text = text
        }
    }

    private struct MountedEditor {
        let window: NSWindow
        let textView: NSTextView
        let state: TextState
        let source: String
        let insertionLocation: Int
    }

    private let application: NSApplication
    private let configurations = [
        Configuration(fontSize: 17, atEnd: false),
        Configuration(fontSize: 17, atEnd: true),
        Configuration(fontSize: 22, atEnd: false),
        Configuration(fontSize: 22, atEnd: true),
    ]
    private var failures: [String] = []
    private var mountedEditor: MountedEditor?

    init(application: NSApplication) {
        self.application = application
    }

    func start() {
        runConfiguration(at: 0)
    }

    private func runConfiguration(at index: Int) {
        guard configurations.indices.contains(index) else {
            finish()
            return
        }

        let configuration = configurations[index]
        guard let mounted = mount(configuration) else {
            failures.append("\(configuration.description): text view missing")
            runConfiguration(at: index + 1)
            return
        }
        mountedEditor = mounted

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
            self.insertReturn(
                1,
                configuration: configuration,
                configurationIndex: index
            )
        }
    }

    private func insertReturn(
        _ returnCount: Int,
        configuration: Configuration,
        configurationIndex: Int
    ) {
        guard let mountedEditor else { return }
        guard returnCount <= 5 else {
            verifySource(mountedEditor, configuration: configuration)
            mountedEditor.window.orderOut(nil)
            self.mountedEditor = nil
            runConfiguration(at: configurationIndex + 1)
            return
        }

        mountedEditor.textView.insertNewline(nil)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.08) {
            self.verifyIndicator(
                mountedEditor.textView,
                configuration: configuration,
                returnCount: returnCount
            )
            self.insertReturn(
                returnCount + 1,
                configuration: configuration,
                configurationIndex: configurationIndex
            )
        }
    }

    private func verifyIndicator(
        _ textView: NSTextView,
        configuration: Configuration,
        returnCount: Int
    ) {
        textView.window?.displayIfNeeded()
        guard let indicator = textView.subviews.compactMap({
            $0 as? NSTextInsertionIndicator
        }).first else {
            failures.append(
                "\(configuration.description) Return \(returnCount): "
                    + "native insertion indicator missing "
                    + focusState(for: textView)
            )
            return
        }

        guard indicator.displayMode == .automatic,
              !indicator.isHidden,
              indicator.alphaValue > 0,
              indicator.frame.height > 0 else {
            failures.append(
                "\(configuration.description) Return \(returnCount): "
                    + "mode=\(indicator.displayMode.rawValue) "
                    + "hidden=\(indicator.isHidden) "
                    + "alpha=\(indicator.alphaValue) "
                    + "frame=\(indicator.frame) "
                    + focusState(for: textView)
            )
            return
        }
    }

    private func verifySource(
        _ mounted: MountedEditor,
        configuration: Configuration
    ) {
        let expected = NSMutableString(string: mounted.source)
        expected.insert(
            String(repeating: "\n", count: 5),
            at: mounted.insertionLocation
        )
        guard mounted.textView.string == expected as String,
              mounted.state.text == expected as String else {
            failures.append("\(configuration.description): source mismatch")
            return
        }
    }

    private func mount(_ configuration: Configuration) -> MountedEditor? {
        let lines = (0..<80).map { "Invented paragraph \($0)." }
        let source = lines.joined(separator: "\n")
        let state = TextState(text: source)
        let editor = MarkdownEditor(
            text: Binding(
                get: { state.text },
                set: { state.text = $0 }
            ),
            fontSize: configuration.fontSize
        )
        let window = NSWindow(
            contentRect: NSRect(x: 100, y: 100, width: 360, height: 240),
            styleMask: [.titled],
            backing: .buffered,
            defer: false
        )
        let host = NSHostingView(rootView: editor)
        window.contentView = host
        host.layoutSubtreeIfNeeded()
        guard let textView = findTextView(in: host) else {
            window.orderOut(nil)
            return nil
        }

        let insertionLocation: Int
        if configuration.atEnd {
            insertionLocation = (source as NSString).length
        } else {
            let range = (source as NSString).range(of: lines[40])
            insertionLocation = NSMaxRange(range)
        }
        textView.setSelectedRange(
            NSRange(location: insertionLocation, length: 0)
        )
        textView.scrollRangeToVisible(textView.selectedRange())
        application.activate()
        window.makeKeyAndOrderFront(nil)
        window.makeMain()
        window.makeFirstResponder(textView)
        application.activate()

        return MountedEditor(
            window: window,
            textView: textView,
            state: state,
            source: source,
            insertionLocation: insertionLocation
        )
    }

    private func findTextView(in view: NSView) -> NSTextView? {
        if let textView = view as? NSTextView {
            return textView
        }
        return view.subviews.lazy.compactMap(findTextView).first
    }

    private func focusState(for textView: NSTextView) -> String {
        let isFirstResponder = textView.window?.firstResponder === textView
        return "key=\(textView.window?.isKeyWindow == true) "
            + "firstResponder=\(isFirstResponder) "
            + "shouldDraw=\(textView.shouldDrawInsertionPoint)"
    }

    private func finish() {
        let result: String
        if failures.isEmpty {
            result = "PASS: native insertion indicator remained visible "
                + "for five Returns at 17pt and 22pt, middle and end.\n"
        } else {
            result = "FAIL:\n" + failures.joined(separator: "\n") + "\n"
        }
        let resultURL = URL(
            fileURLWithPath: "/tmp/meh-editor-caret-check-result.txt"
        )
        try? result.write(to: resultURL, atomically: true, encoding: .utf8)
        FileHandle.standardOutput.write(Data(result.utf8))
        application.terminate(nil)
    }
}
