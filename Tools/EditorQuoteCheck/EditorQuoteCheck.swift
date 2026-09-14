import UIKit

@main
@MainActor
private final class AppDelegate: UIResponder, UIApplicationDelegate {
    func application(
        _ application: UIApplication,
        configurationForConnecting session: UISceneSession,
        options: UIScene.ConnectionOptions
    ) -> UISceneConfiguration {
        let configuration = UISceneConfiguration(
            name: "Editor quote check",
            sessionRole: session.role
        )
        configuration.delegateClass = SceneDelegate.self
        return configuration
    }
}

@MainActor
private final class SceneDelegate: UIResponder, UIWindowSceneDelegate {
    var window: UIWindow?

    func scene(
        _ scene: UIScene,
        willConnectTo session: UISceneSession,
        options connectionOptions: UIScene.ConnectionOptions
    ) {
        guard let windowScene = scene as? UIWindowScene else { return }
        let window = UIWindow(windowScene: windowScene)
        let controller = UIViewController()
        controller.view.backgroundColor = .systemBackground

        let editor = MarkdownTextView(usingTextLayoutManager: true)
        if let layoutManager = editor.textLayoutManager {
            editor.installMarkdownLayoutManagerDelegate(on: layoutManager)
        }
        editor.frame = controller.view.bounds
        editor.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        editor.textContainerInset = UIEdgeInsets(
            top: 18,
            left: 16,
            bottom: 18,
            right: 16
        )
        editor.textContainer.lineFragmentPadding = 4
        editor.backgroundColor = .clear
        if ProcessInfo.processInfo.environment["EDITOR_PERFORMANCE_CHECK"] == "1" {
            controller.view.addSubview(editor)
            window.rootViewController = controller
            window.makeKeyAndVisible()
            self.window = window
            Task { await EditorPerformanceProbe.run(editor) }
            return
        }
        editor.text = Self.sample
        MarkdownPresentation.configure(editor)
        controller.view.addSubview(editor)

        window.rootViewController = controller
        window.makeKeyAndVisible()
        self.window = window

        let stage = ProcessInfo.processInfo.environment["QUOTE_CHECK_STAGE"]
            ?? "initial"
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
            self.apply(stage: stage, to: editor)
        }
    }

    private func apply(stage: String, to editor: MarkdownTextView) {
        guard stage != "initial" else { return }
        let range = (editor.text as NSString).range(of: "* > Scrolled quote")
        editor.selectedRange = NSRange(location: range.location, length: 0)
        editor.becomeFirstResponder()
        editor.frame.size.height = 430
        editor.scrollRangeToVisible(editor.selectedRange)
        editor.contentOffset.y += 13.5
        if stage == "resized" {
            editor.frame.size.width = 330
        }
    }

    private static let sample = """
    * > Immediate quote is visible when this fictional note first opens.
      > Its continuation belongs to the same blue panel.

    """ + (0..<18).map {
        "Fictional paragraph \($0) fills space without private note content."
    }.joined(separator: "\n") + """

    * > Scrolled quote stays aligned after keyboard and viewport changes.
      > Its continuation remains inside the same panel.
    ```swift
    let fictionalValue = 42
    ```
    """
}


// Opt-in synthetic profiling in the existing test app, never the notebook.
@MainActor
private enum EditorPerformanceProbe {
    static func run(_ editor: MarkdownTextView) async {
        let environment = ProcessInfo.processInfo.environment
        let count = min(500, max(1,
            Int(environment["EDITOR_PERFORMANCE_BLOCKS"] ?? "150") ?? 150))
        let scrollRounds = min(20, max(1,
            Int(environment["EDITOR_PERFORMANCE_SCROLL_ROUNDS"] ?? "1") ?? 1))
        let mode = MarkdownEditorMode(
            rawValue: environment["EDITOR_PERFORMANCE_MODE"] ?? "livePreview"
        ) ?? .livePreview
        let block = """
        ## Fictional observatory
        A **bright** star and a [map](https://example.test/map).
        * Outer orbit
          * Inner orbit with ==light== and ~~dust~~.
          * > A quote in a list.
            > A second line of the quote.
        > Another sky observation.
        ```swift
        let orbit = 42
        ```

        """
        editor.text = String(repeating: block, count: count) + "End of sample."
        var measurements: [String: [Double]] = [:]
        func measure(_ name: String, _ action: () -> Void) {
            let start = CACurrentMediaTime()
            action()
            measurements[name, default: []].append(
                (CACurrentMediaTime() - start) * 1_000
            )
        }
        let initial = editor.text ?? ""
        for _ in 0..<3 {
            measure("parse_ms") { _ = MarkdownSyntax.parse(initial) }
        }
        measure("configure_ms") {
            MarkdownPresentation.configure(editor, mode: mode)
            editor.layoutIfNeeded()
        }
        editor.becomeFirstResponder()
        // Allow the initial system keyboard transition to settle without
        // disabling animations in the app under test.
        try? await Task.sleep(for: .seconds(1))
        editor.layoutIfNeeded()
        var expected = initial
        var valid = true
        for step in 0..<7 {
            await Task.yield()
            measure("unchanged_refresh_ms") {
                MarkdownPresentation.refresh(editor, mode: mode)
            }
            let location = (editor.text as NSString).length
            editor.selectedRange = NSRange(location: location, length: 0)
            measure("selection_refresh_ms") {
                MarkdownPresentation.refresh(editor, mode: mode)
            }
            let addition = String(step)
            measure("typing_refresh_ms") {
                editor.insertText(addition)
                MarkdownPresentation.refresh(editor, mode: mode)
            }
            expected += addition
            valid = valid && editor.text == expected
                && editor.selectedRange == NSRange(
                    location: (expected as NSString).length, length: 0
                )
            measure("resize_layout_ms") {
                editor.frame.size.width = step.isMultiple(of: 2) ? 390 : 700
                editor.layoutIfNeeded()
                editor.textLayoutManager?.textViewportLayoutController
                    .layoutViewport()
            }
            let maxOffset = max(0, editor.contentSize.height - editor.bounds.height)
            let shallow: [CGFloat] = [0, 120, 240, 120]
            let deep: [CGFloat] = [
                maxOffset * 0.5, min(maxOffset, maxOffset * 0.5 + 120),
                maxOffset * 0.9, min(maxOffset, maxOffset * 0.9 + 120),
            ]
            let offsets: [(String, CGFloat)] = Array(
                repeating: shallow.map { ("scroll_layout_ms", $0) }
                    + deep.map { ("deep_scroll_layout_ms", $0) },
                count: scrollRounds
            ).flatMap { $0 }
            for (phase, offset) in offsets {
                measure(phase) {
                    measure("scroll_set_offset_ms") {
                        editor.setContentOffset(CGPoint(x: 0, y: offset), animated: false)
                    }
                    measure("scroll_view_layout_ms") { editor.layoutIfNeeded() }
                    measure("scroll_viewport_ms") {
                        editor.textLayoutManager?.textViewportLayoutController
                            .layoutViewport()
                    }
                    measure("scroll_flush_ms") { CATransaction.flush() }
                }
                await Task.yield()
            }
        }
        valid = valid && editor.text == expected
            && editor.selectedRange == NSRange(
                location: (expected as NSString).length, length: 0
            )
        let report: [String: Any] = [
            "scroll_rounds": scrollRounds,
            "mode": mode.rawValue,
            "blocks": count,
            "utf16_length": (initial as NSString).length,
            "source_and_selection_preserved": valid,
            "system": UIDevice.current.systemVersion,
            "device": UIDevice.current.model,
            "measurements": measurements,
        ]
        let directory = FileManager.default.urls(
            for: .documentDirectory, in: .userDomainMask
        )[0]
        do {
            try FileManager.default.createDirectory(
                at: directory, withIntermediateDirectories: true
            )
            let data = try JSONSerialization.data(
                withJSONObject: report, options: [.prettyPrinted, .sortedKeys]
            )
            try data.write(
                to: directory.appendingPathComponent("performance.json"),
                options: .atomic
            )
        } catch {
            NSLog("Synthetic performance report failed: %@", String(describing: error))
        }
    }
}
