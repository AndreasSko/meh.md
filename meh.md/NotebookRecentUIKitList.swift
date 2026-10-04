#if os(iOS)
import SwiftUI
import UIKit

struct NotebookRecentUIKitItem: Equatable, Identifiable {
    let id: UUID
    let title: String
    let preview: String
    let isCurrent: Bool
    let isPinned: Bool
    let canPin: Bool
}

/// A non-scrolling table hosted as one row in the notebook's SwiftUI sidebar.
/// UIKit owns the swipe interaction while SwiftUI continues to own row content.
struct NotebookRecentUIKitList<RowContent: View>: UIViewRepresentable {
    let items: [NotebookRecentUIKitItem]
    let rowContent: (UUID) -> RowContent
    let onTogglePin: (UUID) -> Void
    let onTrash: (UUID, @escaping (Bool) -> Void) -> Void
    let onHide: (UUID, @escaping (Bool) -> Void) -> Void
    let contextMenu: (UUID) -> UIMenu
    var usesViewport = false
    var scrollingEnabled = false
    var accessibilityHidden = false
    var onVisibleIDs: ([UUID]) -> Void = { _ in }

    init(
        items: [NotebookRecentUIKitItem],
        @ViewBuilder rowContent: @escaping (UUID) -> RowContent,
        onTogglePin: @escaping (UUID) -> Void,
        onTrash: @escaping (UUID, @escaping (Bool) -> Void) -> Void,
        onHide: @escaping (UUID, @escaping (Bool) -> Void) -> Void,
        contextMenu: @escaping (UUID) -> UIMenu,
        usesViewport: Bool = false,
        scrollingEnabled: Bool = false,
        accessibilityHidden: Bool = false,
        onVisibleIDs: @escaping ([UUID]) -> Void = { _ in }
    ) {
        self.items = items
        self.rowContent = rowContent
        self.onTogglePin = onTogglePin
        self.onTrash = onTrash
        self.onHide = onHide
        self.contextMenu = contextMenu
        self.usesViewport = usesViewport
        self.scrollingEnabled = scrollingEnabled
        self.accessibilityHidden = accessibilityHidden
        self.onVisibleIDs = onVisibleIDs
    }

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    func makeUIView(context: Context) -> RecentTableView {
        let table = RecentTableView(frame: .zero, style: .plain)
        table.backgroundColor = .clear
        table.isOpaque = false
        table.isScrollEnabled = false
        table.separatorStyle = .none
        table.contentInset = .zero
        table.contentInsetAdjustmentBehavior = .never
        table.sectionHeaderHeight = 0
        table.sectionFooterHeight = 0
        table.estimatedSectionHeaderHeight = 0
        table.estimatedSectionFooterHeight = 0
        table.rowHeight = UITableView.automaticDimension
        table.estimatedRowHeight = 72
        table.showsVerticalScrollIndicator = false
        table.showsHorizontalScrollIndicator = false
        table.register(UITableViewCell.self, forCellReuseIdentifier: "Recent")
        table.delegate = context.coordinator

        let coordinator = context.coordinator
        let source = UITableViewDiffableDataSource<Int, UUID>(tableView: table) {
            [weak coordinator] table, indexPath, id in
            let cell = table.dequeueReusableCell(
                withIdentifier: "Recent", for: indexPath
            )
            coordinator?.configure(cell, for: id)
            return cell
        }
        source.defaultRowAnimation = .automatic
        coordinator.dataSource = source
        return table
    }

    func updateUIView(_ table: RecentTableView, context: Context) {
        table.accessibilityElementsHidden = accessibilityHidden
        if table.usesViewport != usesViewport {
            table.usesViewport = usesViewport
            table.invalidateIntrinsicContentSize()
        }
        table.isScrollEnabled = scrollingEnabled
        table.showsVerticalScrollIndicator = scrollingEnabled
        table.onLayout = { [weak table, weak coordinator = context.coordinator] in
            guard let table else { return }
            coordinator?.reportVisibleIDs(in: table)
        }
        if !usesViewport, table.contentOffset.y != 0 {
            table.setContentOffset(.zero, animated: false)
        }
        context.coordinator.update(
            table: table,
            items: items,
            rowContent: rowContent,
            onTogglePin: onTogglePin,
            onTrash: onTrash,
            onHide: onHide,
            contextMenu: contextMenu,
            onVisibleIDs: onVisibleIDs
        )
    }

    func sizeThatFits(
        _ proposal: ProposedViewSize,
        uiView table: RecentTableView,
        context: Context
    ) -> CGSize? {
        guard let width = proposal.width, width > 0 else { return nil }
        if usesViewport {
            return CGSize(width: width, height: proposal.height ?? 0)
        }
        // Measuring inside SwiftUI must not synchronously lay out hosted
        // SwiftUI cells. UIKit updates contentSize during its layout pass.
        return CGSize(width: width, height: table.reportedHeight)
    }

    final class Coordinator: NSObject, UITableViewDelegate {
        var dataSource: UITableViewDiffableDataSource<Int, UUID>?
        private var items: [NotebookRecentUIKitItem] = []
        private var itemByID: [UUID: NotebookRecentUIKitItem] = [:]
        private var rowContent: ((UUID) -> RowContent)?
        private var onTogglePin: ((UUID) -> Void)?
        private var onTrash: ((UUID, @escaping (Bool) -> Void) -> Void)?
        private var onHide: ((UUID, @escaping (Bool) -> Void) -> Void)?
        private var contextMenu: ((UUID) -> UIMenu)?
        private var onVisibleIDs: (([UUID]) -> Void)?
        private var reportedIDs: [UUID] = []

        func update(
            table: RecentTableView,
            items newItems: [NotebookRecentUIKitItem],
            rowContent: @escaping (UUID) -> RowContent,
            onTogglePin: @escaping (UUID) -> Void,
            onTrash: @escaping (UUID, @escaping (Bool) -> Void) -> Void,
            onHide: @escaping (UUID, @escaping (Bool) -> Void) -> Void,
            contextMenu: @escaping (UUID) -> UIMenu,
            onVisibleIDs: @escaping ([UUID]) -> Void
        ) {
            self.rowContent = rowContent
            self.onTogglePin = onTogglePin
            self.onTrash = onTrash
            self.onHide = onHide
            self.contextMenu = contextMenu
            self.onVisibleIDs = onVisibleIDs
            guard items != newItems else { return }

            let oldItems = itemByID
            let oldIDs = items.map(\.id)
            let newIDs = newItems.map(\.id)
            items = newItems
            itemByID = Dictionary(uniqueKeysWithValues: newItems.map { ($0.id, $0) })

            var snapshot = NSDiffableDataSourceSnapshot<Int, UUID>()
            snapshot.appendSections([0])
            snapshot.appendItems(newIDs)
            let reordered = oldIDs != newIDs
            let changedIDs = newItems.compactMap { item -> UUID? in
                guard let oldItem = oldItems[item.id] else { return nil }
                if reordered || oldItem != item { return item.id }
                return nil
            }
            snapshot.reconfigureItems(changedIDs)
            guard let dataSource else { return }
            table.beginSnapshotUpdate(
                preservingHeight: !oldIDs.isEmpty && Set(oldIDs) == Set(newIDs)
            )
            dataSource.apply(snapshot, animatingDifferences:
                !oldIDs.isEmpty && oldIDs.count == newIDs.count) {
                table.endSnapshotUpdate()
                self.reportVisibleIDs(in: table)
            }
        }

        func scrollViewDidScroll(_ scrollView: UIScrollView) {
            guard let table = scrollView as? RecentTableView else { return }
            reportVisibleIDs(in: table)
        }

        func reportVisibleIDs(in table: RecentTableView) {
            guard table.usesViewport else { return }
            let rows = table.indexPathsForVisibleRows?.map(\.row) ?? []
            guard let first = rows.min(), let last = rows.max() else { return }
            // Visible index paths can briefly belong to the old snapshot.
            let lower = min(items.count, max(0, first - 4))
            let upper = min(items.count, max(lower, last + 9))
            let ids = Array(items[lower..<upper].map(\.id))
            guard ids != reportedIDs else { return }
            reportedIDs = ids
            // Layout callbacks must not mutate SwiftUI state synchronously.
            DispatchQueue.main.async { [weak self] in self?.onVisibleIDs?(ids) }
        }

        func configure(_ cell: UITableViewCell, for id: UUID) {
            guard let rowContent else { return }
            cell.backgroundColor = .clear
            cell.isOpaque = false
            cell.selectionStyle = .none
            cell.contentConfiguration = UIHostingConfiguration {
                rowContent(id)
            }
            .margins(.all, 0)
        }

        func tableView(
            _ tableView: UITableView,
            leadingSwipeActionsConfigurationForRowAt indexPath: IndexPath
        ) -> UISwipeActionsConfiguration? {
            guard let id = dataSource?.itemIdentifier(for: indexPath),
                  let item = itemByID[id], item.isPinned || item.canPin
            else { return nil }

            let title = item.isPinned
                ? String(localized: "Unpin from Recents")
                : String(localized: "Pin in Recents")
            let action = UIContextualAction(style: .normal, title: nil) {
                [weak self] _, _, completion in
                completion(true)
                self?.onTogglePin?(id)
            }
            let image = UIImage(systemName: item.isPinned ? "pin.slash" : "pin.fill")
            image?.accessibilityLabel = title
            action.image = image
            action.backgroundColor = item.isPinned ? .systemGray : .systemOrange
            let configuration = UISwipeActionsConfiguration(actions: [action])
            configuration.performsFirstActionWithFullSwipe = true
            return configuration
        }

        func tableView(
            _ tableView: UITableView,
            trailingSwipeActionsConfigurationForRowAt indexPath: IndexPath
        ) -> UISwipeActionsConfiguration? {
            guard let id = dataSource?.itemIdentifier(for: indexPath),
                  itemByID[id] != nil else { return nil }

            let action = UIContextualAction(
                style: .destructive, title: nil
            ) { [weak self] _, _, completion in
                guard let onTrash = self?.onTrash else {
                    completion(false)
                    return
                }
                // UIKit must receive success only after the note was saved
                // and moved to Trash, including any editor flush.
                onTrash(id, completion)
            }
            let image = UIImage(systemName: "trash")
            image?.accessibilityLabel = String(localized: "Move to Trash")
            action.image = image
            let hide = UIContextualAction(style: .normal, title: nil) {
                [weak self] _, _, completion in
                guard let onHide = self?.onHide else {
                    completion(false)
                    return
                }
                onHide(id, completion)
            }
            let hideImage = UIImage(systemName: "eye.slash")
            hideImage?.accessibilityLabel = String(localized: "Hide from Recents")
            hide.image = hideImage
            hide.backgroundColor = .systemGray
            let configuration = UISwipeActionsConfiguration(actions: [action, hide])
            // Both actions require a tap, so a full swipe cannot hide a
            // note or move it to Trash.
            configuration.performsFirstActionWithFullSwipe = false
            return configuration
        }

        func tableView(
            _ tableView: UITableView,
            contextMenuConfigurationForRowAt indexPath: IndexPath,
            point: CGPoint
        ) -> UIContextMenuConfiguration? {
            guard let id = dataSource?.itemIdentifier(for: indexPath),
                  contextMenu != nil else { return nil }
            return UIContextMenuConfiguration(
                identifier: nil,
                previewProvider: nil
            ) { [weak self] _ in
                self?.contextMenu?(id)
            }
        }
    }
}

final class RecentTableView: UITableView {
    var usesViewport = false
    var onLayout: (() -> Void)?
    private var pendingSnapshots = 0
    private var heldHeight: CGFloat?

    var reportedHeight: CGFloat { heldHeight ?? contentSize.height }

    func beginSnapshotUpdate(preservingHeight: Bool) {
        // Reconfiguring self-sizing cells briefly substitutes estimated heights.
        // Keep that intermediate geometry out of the surrounding SwiftUI list.
        if preservingHeight, heldHeight == nil {
            heldHeight = contentSize.height
        }
        pendingSnapshots += 1
    }

    func endSnapshotUpdate() {
        pendingSnapshots -= 1
        guard pendingSnapshots == 0 else { return }
        heldHeight = nil
        invalidateIntrinsicContentSize()
    }

    override var contentSize: CGSize {
        didSet {
            if heldHeight == nil, oldValue.height != contentSize.height {
                invalidateIntrinsicContentSize()
            }
        }
    }

    override var intrinsicContentSize: CGSize {
        CGSize(width: UIView.noIntrinsicMetric,
               height: usesViewport ? UIView.noIntrinsicMetric : reportedHeight)
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        onLayout?()
    }
}
#endif
