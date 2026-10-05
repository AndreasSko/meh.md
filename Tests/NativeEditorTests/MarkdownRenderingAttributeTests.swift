import XCTest

@testable import NativeEditor

#if os(iOS)
import UIKit

@MainActor
private final class AttributeEditObserver: NSObject {
    var count = 0

    @objc func didEdit(_ notification: Notification) {
        guard let storage = notification.object as? NSTextStorage,
              storage.editedMask.contains(.editedAttributes) else { return }
        count += 1
    }
}

@MainActor
final class MarkdownRenderingAttributeTests: XCTestCase {
    func testListFocusChangesOnlyRenderingAttributes() throws {
        let textView = MarkdownTextView(usingTextLayoutManager: true)
        let host = UIViewController()
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 402, height: 874))
        window.rootViewController = host
        host.view.addSubview(textView)
        textView.frame = CGRect(x: 0, y: 0, width: 402, height: 488)
        let source = "- First fictional item  \n- Second fictional item  \n"
            + "Unrelated highlighted prose"
        textView.text = source
        textView.selectedRange = NSRange(location: 3, length: 0)
        window.makeKeyAndVisible()
        defer { window.isHidden = true }
        XCTAssertTrue(textView.becomeFirstResponder())
        MarkdownPresentation.configure(textView, mode: .livePreview)
        textView.layoutIfNeeded()

        let manager = try XCTUnwrap(textView.textLayoutManager)
        let content = try XCTUnwrap(manager.textContentManager)
        manager.ensureLayout(for: content.documentRange)
        let second = (source as NSString).range(of: "- Second").location
        let markerFont = try XCTUnwrap(textView.textStorage.attribute(
            .font, at: second, effectiveRange: nil
        ) as? UIFont)
        XCTAssertGreaterThan(markerFont.pointSize, 1)
        XCTAssertNotEqual(try color(at: 0, in: manager), UIColor.clear)
        XCTAssertEqual(try color(at: second, in: manager), UIColor.clear)

        let highlighted = (source as NSString).range(of: "highlighted")
        let highlightStart = try XCTUnwrap(content.location(
            content.documentRange.location, offsetBy: highlighted.location
        ))
        let highlightEnd = try XCTUnwrap(content.location(
            highlightStart, offsetBy: highlighted.length
        ))
        let highlightRange = try XCTUnwrap(NSTextRange(
            location: highlightStart, end: highlightEnd
        ))
        manager.addRenderingAttribute(
            .backgroundColor, value: UIColor.systemYellow, for: highlightRange
        )

        let observer = AttributeEditObserver()
        NotificationCenter.default.addObserver(
            observer, selector: #selector(AttributeEditObserver.didEdit(_:)),
            name: NSTextStorage.didProcessEditingNotification,
            object: textView.textStorage
        )
        defer { NotificationCenter.default.removeObserver(observer) }

        textView.selectedRange = NSRange(location: second + 3, length: 0)
        MarkdownPresentation.refresh(textView, mode: .livePreview)
        XCTAssertEqual(observer.count, 0)
        XCTAssertEqual(try color(at: 0, in: manager), UIColor.clear)
        XCTAssertNotEqual(try color(at: second, in: manager), UIColor.clear)
        XCTAssertEqual(textView.textStorage.attribute(
            .font, at: second, effectiveRange: nil
        ) as? UIFont, markerFont)
        XCTAssertEqual(try attribute(
            .backgroundColor, at: highlighted.location, in: manager
        ) as? UIColor, UIColor.systemYellow)

        MarkdownPresentation.refresh(textView, mode: .source)
        XCTAssertEqual(observer.count, 0)
        XCTAssertNotEqual(try color(at: 0, in: manager), UIColor.clear)
        XCTAssertNotEqual(try color(at: second, in: manager), UIColor.clear)
        XCTAssertEqual(textView.text, source)
        XCTAssertEqual(textView.selectedRange,
                       NSRange(location: second + 3, length: 0))
    }

    private func color(at offset: Int, in manager: NSTextLayoutManager) throws
        -> UIColor {
        try XCTUnwrap(attribute(.foregroundColor, at: offset, in: manager)
            as? UIColor)
    }

    private func attribute(_ key: NSAttributedString.Key, at offset: Int,
                           in manager: NSTextLayoutManager) throws -> Any? {
        let content = try XCTUnwrap(manager.textContentManager)
        let location = try XCTUnwrap(content.location(
            content.documentRange.location, offsetBy: offset
        ))
        var value: Any?
        manager.enumerateRenderingAttributes(from: location, reverse: false) {
            _, attributes, _ in
            value = attributes[key]
            return false
        }
        return value
    }
}
#endif
