import SwiftUI

#if os(iOS)
import UIKit
#endif

struct EditorModeControl: View {
    @Binding var mode: MarkdownEditorMode
    let isEnabled: Bool

    var body: some View {
        Picker("Editor Mode", selection: $mode) {
            Label("Source", systemImage: "doc.plaintext")
                .tag(MarkdownEditorMode.source)
                .accessibilityIdentifier("editor-mode-source")
            Label("Live Preview", systemImage: "text.document")
                .tag(MarkdownEditorMode.livePreview)
                .accessibilityIdentifier("editor-mode-live-preview")
        }
        .disabled(!isEnabled)
        .accessibilityIdentifier("editor-mode")
    }
}

struct EditorWritingControls: View {
    let navigation: MarkdownEditorNavigation
    let isEnabled: Bool

    var body: some View {
        Menu {
            commandButton("Bold", systemImage: "bold", command: .bold)
            commandButton("Italic", systemImage: "italic", command: .italic)
            commandButton("Link", systemImage: "link", command: .link)
            commandButton(
                "Heading", systemImage: "textformat.size.larger",
                command: .heading
            )
            commandButton(
                "Inline Code", systemImage: "chevron.left.forwardslash.chevron.right",
                command: .inlineCode
            )

            Divider()

            commandButton(
                "Strikethrough", systemImage: "strikethrough",
                command: .strikethrough
            )
            commandButton(
                "Highlight", systemImage: "highlighter", command: .highlight
            )
            commandButton(
                "Code Block", systemImage: "curlybraces.square", command: .codeBlock
            )
            Divider()

            commandButton(
                "Indent", systemImage: "increase.indent", command: .indent
            )
            commandButton(
                "Outdent", systemImage: "decrease.indent", command: .outdent
            )
        } label: {
            Label("Formatting", systemImage: "textformat")
                .labelStyle(.iconOnly)
        }
        .disabled(!isEnabled)
        .accessibilityIdentifier("editor-formatting")
    }

    private func commandButton(
        _ title: String,
        systemImage: String,
        command: MarkdownEditingCommand
    ) -> some View {
        Button {
            navigation.performCommand?(command)
        } label: {
            Label(title, systemImage: systemImage)
        }
        .accessibilityIdentifier(command.accessibilityIdentifier)
    }
}

private extension MarkdownEditingCommand {
    var accessibilityIdentifier: String {
        switch self {
        case .continueLine: "editor-command-continue-line"
        case .indent: "editor-command-indent"
        case .outdent: "editor-command-outdent"
        case .bold: "editor-command-bold"
        case .italic: "editor-command-italic"
        case .strikethrough: "editor-command-strikethrough"
        case .highlight: "editor-command-highlight"
        case .heading: "editor-command-heading"
        case .link: "editor-command-link"
        case .inlineCode: "editor-command-inline-code"
        case .codeBlock: "editor-command-code-block"
        }
    }
}

#if os(iOS)
extension MarkdownTextView {
    func installMarkdownKeyboardToolbar() {
        inputAccessoryView = MarkdownKeyboardAccessoryView(textView: self)
    }
}

private final class MarkdownKeyboardAccessoryView: UIView,
    UICollectionViewDataSource, UICollectionViewDelegateFlowLayout {
    private struct CommandDefinition {
        let id: String
        let title: String
        let systemImage: String
        let command: MarkdownEditingCommand
    }

    private static let orderDefaultsKey = "editor.keyboardToolbar.commands"
    private static let definitions = [
        CommandDefinition(
            id: "indent", title: "Indent",
            systemImage: "increase.indent", command: .indent
        ),
        CommandDefinition(
            id: "outdent", title: "Outdent",
            systemImage: "decrease.indent", command: .outdent
        ),
        CommandDefinition(
            id: "bold", title: "Bold", systemImage: "bold", command: .bold
        ),
        CommandDefinition(
            id: "italic", title: "Italic", systemImage: "italic",
            command: .italic
        ),
    ]
    private static let defaultOrder = definitions.map(\.id)

    private weak var textView: MarkdownTextView?
    private var order: [String]
    private var isMovingCommand = false
    private let layout = UICollectionViewFlowLayout()
    private lazy var collectionView = MarkdownKeyboardCollectionView(
        frame: .zero,
        collectionViewLayout: layout
    )

    init(textView: MarkdownTextView) {
        self.textView = textView
        order = Self.savedOrder()
        super.init(
            frame: CGRect(x: 0, y: 0, width: textView.bounds.width, height: 50)
        )
        configureView()
    }

    required init?(coder: NSCoder) {
        return nil
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        let spacing = max(4, (collectionView.bounds.width - 5 * 44) / 4)
        if layout.minimumLineSpacing != spacing {
            layout.minimumLineSpacing = spacing
            layout.invalidateLayout()
        }
    }

    private func configureView() {
        autoresizingMask = [.flexibleWidth]
        backgroundColor = .secondarySystemBackground
        tintColor = .label
        accessibilityIdentifier = "editor-keyboard-toolbar"

        let separator = UIView()
        separator.translatesAutoresizingMaskIntoConstraints = false
        separator.backgroundColor = .separator
        addSubview(separator)

        layout.scrollDirection = .horizontal
        layout.itemSize = CGSize(width: 44, height: 44)
        layout.minimumInteritemSpacing = 0
        layout.sectionInset = .zero
        collectionView.translatesAutoresizingMaskIntoConstraints = false
        collectionView.backgroundColor = .clear
        collectionView.showsHorizontalScrollIndicator = false
        collectionView.isScrollEnabled = false
        collectionView.dataSource = self
        collectionView.delegate = self
        collectionView.register(
            MarkdownKeyboardButtonCell.self,
            forCellWithReuseIdentifier: MarkdownKeyboardButtonCell.reuseIdentifier
        )
        let longPress = UILongPressGestureRecognizer(
            target: self,
            action: #selector(handleLongPress(_:))
        )
        collectionView.addGestureRecognizer(longPress)
        addSubview(collectionView)

        let adaptiveWidth = collectionView.widthAnchor.constraint(
            equalTo: widthAnchor,
            constant: -24
        )
        adaptiveWidth.priority = UILayoutPriority(
            rawValue: UILayoutPriority.defaultHigh.rawValue + 1
        )
        let preferredTabletWidth = collectionView.widthAnchor.constraint(
            equalToConstant: 480
        )
        preferredTabletWidth.priority = .defaultHigh
        NSLayoutConstraint.activate([
            separator.leadingAnchor.constraint(equalTo: leadingAnchor),
            separator.trailingAnchor.constraint(equalTo: trailingAnchor),
            separator.topAnchor.constraint(equalTo: topAnchor),
            separator.heightAnchor.constraint(equalToConstant: 0.5),
            collectionView.centerXAnchor.constraint(equalTo: centerXAnchor),
            collectionView.centerYAnchor.constraint(equalTo: centerYAnchor),
            collectionView.heightAnchor.constraint(equalToConstant: 44),
            collectionView.leadingAnchor.constraint(
                greaterThanOrEqualTo: leadingAnchor,
                constant: 12
            ),
            collectionView.trailingAnchor.constraint(
                lessThanOrEqualTo: trailingAnchor,
                constant: -12
            ),
            collectionView.widthAnchor.constraint(lessThanOrEqualToConstant: 480),
            adaptiveWidth,
            preferredTabletWidth,
        ])
    }

    func collectionView(
        _ collectionView: UICollectionView,
        numberOfItemsInSection section: Int
    ) -> Int {
        order.count + 1
    }

    func collectionView(
        _ collectionView: UICollectionView,
        cellForItemAt indexPath: IndexPath
    ) -> UICollectionViewCell {
        let cell = collectionView.dequeueReusableCell(
            withReuseIdentifier: MarkdownKeyboardButtonCell.reuseIdentifier,
            for: indexPath
        ) as! MarkdownKeyboardButtonCell
        if indexPath.item == order.count {
            let action = UIAction { [weak self, weak cell] _ in
                guard let source = cell?.presentationSource else { return }
                self?.presentOverflow(from: source)
            }
            cell.configure(
                title: "More Formatting",
                systemImage: "ellipsis.circle",
                accessibilityIdentifier: "editor-formatting",
                action: action,
                menu: nil,
                accessibilityActions: []
            )
            return cell
        }

        let definition = definition(at: indexPath.item)
        let action = UIAction { [weak textView] _ in
            _ = textView?.performMarkdownCommand(definition.command)
        }
        cell.configure(
            title: definition.title,
            systemImage: definition.systemImage,
            accessibilityIdentifier: definition.command.accessibilityIdentifier,
            action: action,
            menu: nil,
            accessibilityActions: accessibilityMoveActions(for: definition.id)
        )
        return cell
    }

    func collectionView(
        _ collectionView: UICollectionView,
        canMoveItemAt indexPath: IndexPath
    ) -> Bool {
        indexPath.item < order.count
    }

    func collectionView(
        _ collectionView: UICollectionView,
        moveItemAt sourceIndexPath: IndexPath,
        to destinationIndexPath: IndexPath
    ) {
        let command = order.remove(at: sourceIndexPath.item)
        order.insert(command, at: min(destinationIndexPath.item, order.count))
        saveOrder()
    }

    func collectionView(
        _ collectionView: UICollectionView,
        targetIndexPathForMoveFromItemAt originalIndexPath: IndexPath,
        toProposedIndexPath proposedIndexPath: IndexPath
    ) -> IndexPath {
        IndexPath(
            item: min(proposedIndexPath.item, order.count - 1),
            section: proposedIndexPath.section
        )
    }

    @objc private func handleLongPress(_ gesture: UILongPressGestureRecognizer) {
        let location = gesture.location(in: collectionView)
        switch gesture.state {
        case .began:
            guard let indexPath = collectionView.indexPathForItem(at: location),
                  indexPath.item < order.count else { return }
            isMovingCommand = collectionView.beginInteractiveMovementForItem(
                at: indexPath
            )
        case .changed:
            if isMovingCommand {
                collectionView.updateInteractiveMovementTargetPosition(location)
            }
        case .ended:
            if isMovingCommand {
                collectionView.endInteractiveMovement()
                DispatchQueue.main.async { [weak self] in
                    self?.refreshVisibleAccessibilityActions()
                }
            }
            isMovingCommand = false
        default:
            if isMovingCommand { collectionView.cancelInteractiveMovement() }
            isMovingCommand = false
        }
    }

    private func definition(at index: Int) -> CommandDefinition {
        let id = order[index]
        return Self.definitions.first { $0.id == id }!
    }

    private func accessibilityMoveActions(
        for id: String
    ) -> [UIAccessibilityCustomAction] {
        guard let index = order.firstIndex(of: id) else { return [] }
        var actions: [UIAccessibilityCustomAction] = []
        if index > 0 {
            actions.append(
                UIAccessibilityCustomAction(name: "Move Left") {
                    [weak self] _ in self?.moveCommand(id: id, by: -1) == true
                }
            )
        }
        if index < order.count - 1 {
            actions.append(
                UIAccessibilityCustomAction(name: "Move Right") {
                    [weak self] _ in self?.moveCommand(id: id, by: 1) == true
                }
            )
        }
        return actions
    }

    private func moveCommand(id: String, by offset: Int) -> Bool {
        guard let index = order.firstIndex(of: id) else { return false }
        let destination = index + offset
        guard order.indices.contains(index), order.indices.contains(destination) else {
            return false
        }
        order.swapAt(index, destination)
        saveOrder()
        collectionView.reloadData()
        return true
    }

    private func refreshVisibleAccessibilityActions() {
        for visibleCell in collectionView.visibleCells {
            guard let cell = visibleCell as? MarkdownKeyboardButtonCell,
                  let indexPath = collectionView.indexPath(for: cell),
                  indexPath.item < order.count else {
                (visibleCell as? MarkdownKeyboardButtonCell)?
                    .updateAccessibilityActions([])
                continue
            }
            cell.updateAccessibilityActions(
                accessibilityMoveActions(for: order[indexPath.item])
            )
        }
    }

    private func presentOverflow(from source: UIView) {
        let commands: [(String, String, MarkdownEditingCommand)] = [
            ("Heading", "textformat.size.larger", .heading),
            ("Link", "link", .link),
            ("Strikethrough", "strikethrough", .strikethrough),
            ("Highlight", "highlighter", .highlight),
            (
                "Inline Code",
                "chevron.left.forwardslash.chevron.right",
                .inlineCode
            ),
            ("Code Block", "curlybraces.square", .codeBlock),
        ]
        guard let textView,
              let presenter = Self.owningViewController(for: textView) else {
            return
        }
        let sourceRect = source.convert(source.bounds, to: presenter.view)
        let availableHeight = sourceRect.minY
            - presenter.view.safeAreaInsets.top - 16
        let menu = MarkdownFormattingMenuViewController(
            commands: commands,
            textView: textView
        )
        menu.preferredContentSize = CGSize(
            width: 300,
            height: min(CGFloat(commands.count) * 44, max(176, availableHeight))
        )
        menu.modalPresentationStyle = .popover
        guard let popover = menu.popoverPresentationController else { return }
        popover.sourceView = presenter.view
        popover.sourceRect = sourceRect
        popover.permittedArrowDirections = .down
        popover.delegate = menu
        presenter.present(menu, animated: true)
    }

    private func saveOrder() {
        UserDefaults.standard.set(order, forKey: Self.orderDefaultsKey)
    }

    private static func savedOrder() -> [String] {
        let saved = UserDefaults.standard.stringArray(forKey: orderDefaultsKey) ?? []
        guard saved.count == defaultOrder.count,
              Set(saved) == Set(defaultOrder) else { return defaultOrder }
        return saved
    }

    private static func owningViewController(for view: UIView) -> UIViewController? {
        var responder: UIResponder? = view
        while let next = responder?.next {
            if let controller = next as? UIViewController { return controller }
            responder = next
        }
        return nil
    }
}

private final class MarkdownFormattingMenuViewController: UITableViewController,
    UIPopoverPresentationControllerDelegate {
    private let commands: [(String, String, MarkdownEditingCommand)]
    private weak var textView: MarkdownTextView?

    init(
        commands: [(String, String, MarkdownEditingCommand)],
        textView: MarkdownTextView
    ) {
        self.commands = commands
        self.textView = textView
        super.init(style: .plain)
    }

    required init?(coder: NSCoder) {
        return nil
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        tableView.rowHeight = 44
        tableView.separatorInset = UIEdgeInsets(top: 0, left: 48, bottom: 0, right: 0)
        tableView.register(UITableViewCell.self, forCellReuseIdentifier: "Action")
    }

    override func tableView(
        _ tableView: UITableView,
        numberOfRowsInSection section: Int
    ) -> Int {
        commands.count
    }

    override func tableView(
        _ tableView: UITableView,
        cellForRowAt indexPath: IndexPath
    ) -> UITableViewCell {
        let cell = tableView.dequeueReusableCell(
            withIdentifier: "Action",
            for: indexPath
        )
        var content = cell.defaultContentConfiguration()
        if indexPath.row < commands.count {
            let command = commands[indexPath.row]
            content.text = command.0
            content.image = UIImage(systemName: command.1)
            cell.accessibilityIdentifier = command.2.accessibilityIdentifier
        }
        cell.contentConfiguration = content
        cell.isAccessibilityElement = true
        cell.accessibilityLabel = content.text
        cell.accessibilityTraits.insert(.button)
        return cell
    }

    override func tableView(
        _ tableView: UITableView,
        didSelectRowAt indexPath: IndexPath
    ) {
        tableView.deselectRow(at: indexPath, animated: true)
        if indexPath.row < commands.count {
            let command = commands[indexPath.row].2
            dismiss(animated: true) { [weak textView] in
                _ = textView?.performMarkdownCommand(command)
            }
        }
    }

    func adaptivePresentationStyle(
        for controller: UIPresentationController
    ) -> UIModalPresentationStyle {
        .none
    }
}

private final class MarkdownKeyboardCollectionView: UICollectionView {
    override var canBecomeFirstResponder: Bool { false }
}

private final class MarkdownKeyboardButtonCell: UICollectionViewCell {
    static let reuseIdentifier = "MarkdownKeyboardButtonCell"

    private let button = UIButton(type: .system)
    private var primaryAction: UIAction?

    var presentationSource: UIView { button }

    override init(frame: CGRect) {
        super.init(frame: frame)
        button.translatesAutoresizingMaskIntoConstraints = false
        contentView.addSubview(button)
        NSLayoutConstraint.activate([
            button.leadingAnchor.constraint(equalTo: contentView.leadingAnchor),
            button.trailingAnchor.constraint(equalTo: contentView.trailingAnchor),
            button.topAnchor.constraint(equalTo: contentView.topAnchor),
            button.bottomAnchor.constraint(equalTo: contentView.bottomAnchor),
        ])
    }

    required init?(coder: NSCoder) {
        return nil
    }

    func configure(
        title: String,
        systemImage: String,
        accessibilityIdentifier: String,
        action: UIAction?,
        menu: UIMenu?,
        accessibilityActions: [UIAccessibilityCustomAction]
    ) {
        if let primaryAction {
            button.removeAction(primaryAction, for: .primaryActionTriggered)
        }
        primaryAction = action
        if let action {
            button.addAction(action, for: .primaryActionTriggered)
        }
        var configuration = UIButton.Configuration.plain()
        configuration.image = UIImage(systemName: systemImage)
        configuration.baseForegroundColor = .label
        configuration.preferredSymbolConfigurationForImage =
            UIImage.SymbolConfiguration(pointSize: 18, weight: .regular)
        button.configuration = configuration
        button.menu = menu
        button.showsMenuAsPrimaryAction = menu != nil
        button.accessibilityLabel = title
        button.accessibilityIdentifier = accessibilityIdentifier
        button.accessibilityCustomActions = accessibilityActions
    }

    func updateAccessibilityActions(
        _ actions: [UIAccessibilityCustomAction]
    ) {
        button.accessibilityCustomActions = actions
    }
}
#endif
