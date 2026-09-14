import Foundation

/// A persisted, parent-scoped position in a notebook's manual order.
///
/// The encoded components are intentionally opaque outside NoteCore. They are
/// variable length so repeated insertion between the same two items does not
/// require rewriting unrelated siblings.
public struct NotebookOrderKey: Equatable, Hashable, Sendable, Comparable {
    static let maximumComponentCount = 4_096

    let rawValue: String
    fileprivate let components: [UInt16]

    init?(rawValue: String) {
        let parts = rawValue.split(separator: ".", omittingEmptySubsequences: false)
        guard !parts.isEmpty, parts.count <= Self.maximumComponentCount else {
            return nil
        }
        var components: [UInt16] = []
        components.reserveCapacity(parts.count)
        for part in parts {
            guard part.count == 4,
                  let component = UInt16(part, radix: 16),
                  String(format: "%04x", component) == part else {
                return nil
            }
            components.append(component)
        }
        self.rawValue = rawValue
        self.components = components
    }

    fileprivate init(components: [UInt16]) {
        precondition(!components.isEmpty)
        precondition(components.count <= Self.maximumComponentCount)
        self.components = components
        rawValue = components.map { String(format: "%04x", $0) }
            .joined(separator: ".")
    }

    public static func < (left: Self, right: Self) -> Bool {
        left.components.lexicographicallyPrecedes(right.components)
    }
}

/// Applies the catalog's ordering rules without rereading Automerge state.
public enum NotebookOrdering {
    public static func orderedChildren(
        _ placements: [NotebookPlacement],
        parentID: UUID?,
        inTrash: Bool
    ) -> [NotebookPlacement] {
        let children = placements.filter {
            $0.parentID == parentID && $0.isInTrash == inTrash
        }
        // Manual order is defined for the active tree. Explicit Trash roots
        // can retain ranks from different stored parents, so comparing those
        // unrelated scopes would not represent user intent.
        guard !inTrash, children.contains(where: { effectiveKey($0) != nil }) else {
            return children.sorted(by: legacyPrecedes)
        }
        return children.sorted { left, right in
            switch (effectiveKey(left), effectiveKey(right)) {
            case let (leftKey?, rightKey?):
                if leftKey != rightKey { return leftKey < rightKey }
                return left.item.id.uuidString < right.item.id.uuidString
            case (_?, nil):
                return true
            case (nil, _?):
                return false
            case (nil, nil):
                return legacyPrecedes(left, right)
            }
        }
    }

    private static func effectiveKey(
        _ placement: NotebookPlacement
    ) -> NotebookOrderKey? {
        // Missing-parent and cycle recovery can derive a different display
        // parent. A rank from the stored parent is unrelated to that scope.
        placement.parentID == placement.item.parentID
            ? placement.item.orderKey
            : nil
    }

    private static func legacyPrecedes(
        _ left: NotebookPlacement,
        _ right: NotebookPlacement
    ) -> Bool {
        if left.item.kind != right.item.kind {
            return left.item.kind == .folder
        }
        let order = left.displayName.localizedStandardCompare(right.displayName)
        return order == .orderedSame
            ? left.item.id.uuidString < right.item.id.uuidString
            : order == .orderedAscending
    }
}

enum NotebookOrderKeyFactory {
    static func between(
        _ lower: NotebookOrderKey?,
        _ upper: NotebookOrderKey?,
        itemID: UUID
    ) throws -> NotebookOrderKey {
        if let lower, let upper, !(lower < upper) {
            throw NotebookCatalogError.invalidOrder
        }

        let low = lower?.components ?? []
        let high = upper?.components
        var result: [UInt16] = []
        var index = 0
        var upperIsConstrained = high != nil

        while true {
            guard result.count + 10 <= NotebookOrderKey.maximumComponentCount else {
                throw NotebookCatalogError.orderSpaceExhausted
            }
            let lowPart = index < low.count ? low[index] : 0
            let highPart: UInt16
            if upperIsConstrained {
                guard let high, index < high.count else {
                    throw NotebookCatalogError.invalidOrder
                }
                highPart = high[index]
            } else {
                highPart = .max
            }

            if lowPart == highPart {
                result.append(lowPart)
                index += 1
                continue
            }
            guard lowPart < highPart else {
                throw NotebookCatalogError.invalidOrder
            }
            if UInt32(highPart) - UInt32(lowPart) > 1 {
                let distance = UInt32(highPart) - UInt32(lowPart)
                result.append(UInt16(UInt32(lowPart) + distance / 2))
                break
            }

            result.append(lowPart)
            index += 1
            upperIsConstrained = false
        }

        // A stable item suffix makes concurrent insertions of different items
        // into the same gap distinct while keeping the generated base strictly
        // between its two boundaries.
        result.append(0x8000)
        let bytes = withUnsafeBytes(of: itemID.uuid) { Array($0) }
        for offset in stride(from: 0, to: bytes.count, by: 2) {
            result.append(UInt16(bytes[offset]) << 8 | UInt16(bytes[offset + 1]))
        }
        return NotebookOrderKey(components: result)
    }

    static func distribute(
        itemIDs: [UUID],
        lower: NotebookOrderKey?,
        upper: NotebookOrderKey?
    ) throws -> [UUID: NotebookOrderKey] {
        var result: [UUID: NotebookOrderKey] = [:]
        try distribute(
            itemIDs[...], lower: lower, upper: upper, result: &result
        )
        return result
    }

    private static func distribute(
        _ itemIDs: ArraySlice<UUID>,
        lower: NotebookOrderKey?,
        upper: NotebookOrderKey?,
        result: inout [UUID: NotebookOrderKey]
    ) throws {
        guard !itemIDs.isEmpty else { return }
        let middleIndex = itemIDs.index(
            itemIDs.startIndex,
            offsetBy: itemIDs.count / 2
        )
        let itemID = itemIDs[middleIndex]
        let middle = try between(lower, upper, itemID: itemID)
        try distribute(
            itemIDs[..<middleIndex],
            lower: lower,
            upper: middle,
            result: &result
        )
        result[itemID] = middle
        let afterMiddle = itemIDs.index(after: middleIndex)
        try distribute(
            itemIDs[afterMiddle...],
            lower: middle,
            upper: upper,
            result: &result
        )
    }
}
