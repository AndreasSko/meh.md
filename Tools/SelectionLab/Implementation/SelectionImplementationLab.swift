#if DEBUG && os(iOS)
import SwiftUI
import UIKit

enum SelectionImplementationLaunch {
    static var enabled: Bool {
        ProcessInfo.processInfo.environment["MEH_SELECTION_IMPLEMENTATION"] == "1"
    }
    static let fixture = (1...80).map {
        "Trail \($0). A fictional moonlit walk beside the river, with **bright stars** and quiet trees."
            + ($0 == 70 ? " ORBITAL LANTERN rests beside the fictional bridge." : "")
    }.joined(separator: "\n\n")
}

private struct SelectionImplementationEditor: View {
    @State private var text = SelectionImplementationLaunch.fixture
    let navigation: MarkdownEditorNavigation
    var body: some View {
        MarkdownEditor(text: $text, navigation: navigation,
            mode: ProcessInfo.processInfo.environment["MEH_SELECTION_EDITOR"] == "source"
                ? .source : .livePreview)
            .ignoresSafeArea(
                navigation.findPresentation.isVisible ? .all : .container,
                edges: .bottom
            )
    }
}

struct SelectionImplementationView: UIViewControllerRepresentable {
    func makeUIViewController(context: Context) -> SelectionImplementationController {
        SelectionImplementationController()
    }
    func updateUIViewController(_ controller: SelectionImplementationController,
                               context: Context) {}
}

final class SelectionImplementationController: UIViewController {
    private let metrics = UILabel()
    private let navigation = MarkdownEditorNavigation()
    private var host: UIHostingController<SelectionImplementationEditor>?
    private weak var editor: UITextView?
    private var timer: Timer?
    private var minY: CGFloat = .greatestFiniteMagnitude
    private var maxY: CGFloat = -.greatestFiniteMagnitude
    private var trace: [[String: Any]] = []

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .systemBackground
        let reset = UIButton(type: .system)
        reset.setTitle("Reset trace", for: .normal)
        reset.accessibilityIdentifier = "implementation-reset"
        reset.addTarget(self, action: #selector(resetTrace), for: .touchUpInside)
        let find = UIButton(type: .system)
        find.setTitle("Find", for: .normal)
        find.accessibilityIdentifier = "implementation-find"
        find.addTarget(self, action: #selector(showFind), for: .touchUpInside)
        let header = UIStackView(arrangedSubviews: [reset, find])
        header.distribution = .fillEqually
        metrics.accessibilityIdentifier = "implementation-metrics"
        metrics.font = .monospacedSystemFont(ofSize: 9, weight: .regular)
        let controller = UIHostingController(rootView:
            SelectionImplementationEditor(navigation: navigation))
        host = controller
        addChild(controller)
        controller.didMove(toParent: self)
        let stack = UIStackView(arrangedSubviews: [header, metrics, controller.view])
        stack.axis = .vertical
        stack.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor),
            stack.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            stack.bottomAnchor.constraint(equalTo: view.safeAreaLayoutGuide.bottomAnchor),
            header.heightAnchor.constraint(equalToConstant: 36),
            metrics.heightAnchor.constraint(equalToConstant: 16)
        ])
        timer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.sample() }
        }
    }

    @objc private func showFind() { navigation.showFind?() }
    @objc private func resetTrace() {
        minY = .greatestFiniteMagnitude
        maxY = -.greatestFiniteMagnitude
        trace = []
        sample()
    }

    private func sample() {
        if editor == nil {
            func find(_ root: UIView) -> UITextView? {
                if let text = root as? UITextView { return text }
                return root.subviews.lazy.compactMap { find($0) }.first
            }
            editor = find(view)
        }
        guard let editor else { return }
        editor.accessibilityIdentifier = "implementation-editor"
        minY = min(minY, editor.contentOffset.y)
        maxY = max(maxY, editor.contentOffset.y)
        let range = editor.selectedRange
        let text = editor.text ?? ""
        let validRange = NSMaxRange(range) <= (text as NSString).length
        let frame = editor.convert(editor.bounds, to: nil)
        func caret(_ offset: Int) -> [String: CGFloat] {
            guard let pos = editor.position(from: editor.beginningOfDocument,
                                           offset: offset) else { return [:] }
            let r = editor.convert(editor.caretRect(for: pos), to: nil)
            return ["x": r.midX, "y": r.maxY, "top": r.minY]
        }
        var word: [String: Any] = [:]
        for fraction in [0.4, 0.35, 0.45, 0.3, 0.5] where word.isEmpty {
            let target = CGPoint(x: fraction == 0.4 ? 55 : 100,
                y: editor.bounds.minY + editor.bounds.height * fraction)
            if let pos = editor.closestPosition(to: target),
           let r = editor.tokenizer.rangeEnclosingPosition(pos, with: .word,
                    inDirection: UITextDirection(rawValue: UITextStorageDirection.forward.rawValue)) {
            let rect = editor.convert(editor.firstRect(for: r), to: nil)
            word = ["x": rect.midX, "y": rect.midY,
                    "text": editor.text(in: r) ?? "",
                    "location": editor.offset(from: editor.beginningOfDocument, to: r.start)]
            }
        }
        let row: [String: Any] = ["time": CACurrentMediaTime(),
            "y": editor.contentOffset.y, "location": range.location,
            "length": range.length, "firstResponder": editor.isFirstResponder,
            "height": editor.bounds.height, "pan": editor.panGestureRecognizer.state.rawValue]
        if trace.count < 3000 { trace.append(row) }
        var nativeEnd: [String: CGFloat] = [:]
        var selectionRects: [[String: Any]] = []
        if let selected = editor.selectedTextRange {
            for selection in editor.selectionRects(for: selected) {
                let rect = editor.convert(selection.rect, to: nil)
                selectionRects.append(["x": rect.minX, "y": rect.minY,
                    "width": rect.width, "height": rect.height,
                    "start": selection.containsStart, "end": selection.containsEnd])
                if selection.containsEnd {
                    nativeEnd = ["x": rect.maxX, "y": rect.maxY, "top": rect.minY]
                }
            }
        }
        let value: [String: Any] = ["text": text,
            "selectedText": validRange ? (text as NSString).substring(with: range) : "INVALID",
            "location": range.location, "length": range.length,
            "y": editor.contentOffset.y, "minY": minY, "maxY": maxY,
            "height": editor.bounds.height, "contentHeight": editor.contentSize.height,
            "start": caret(range.location), "end": caret(NSMaxRange(range)),
            "nativeEnd": nativeEnd, "selectionRects": selectionRects,
            "word": word, "firstResponder": editor.isFirstResponder,
            "frame": ["x": frame.minX, "y": frame.minY,
                      "width": frame.width, "height": frame.height],
            "trace": trace]
        if let data = try? JSONSerialization.data(withJSONObject: value,
                                                  options: [.sortedKeys]),
           let json = String(data: data, encoding: .utf8) {
            metrics.text = "offset \(Int(editor.contentOffset.y)) selection \(range.location)+\(range.length)"
            metrics.accessibilityValue = json
        }
    }
}
#endif
