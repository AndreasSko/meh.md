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
