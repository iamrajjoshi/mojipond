import Foundation

enum MediaCommandGridKey: Equatable, Sendable {
    case left
    case right
    case up
    case down
    case tab(backward: Bool)
    case returnKey
    case escape
}

enum MediaCommandGridAction: Equatable, Sendable {
    case ignored
    case moved(to: Int)
    case activate(index: Int)
    case dismiss
}

struct MediaCommandGrid: Equatable, Sendable {
    private(set) var items: [MediaCommandResult]
    private(set) var selectedIndex: Int?
    let columnCount: Int

    init(items: [MediaCommandResult] = [], columnCount: Int = 4) {
        self.items = items
        self.columnCount = max(columnCount, 1)
        selectedIndex = items.isEmpty ? nil : 0
    }

    mutating func updateItems(_ updatedItems: [MediaCommandResult]) {
        let selectedID = selectedIndex.flatMap { index in
            items.indices.contains(index) ? items[index].id : nil
        }
        items = updatedItems

        if let selectedID,
           let matchingIndex = items.firstIndex(where: { $0.id == selectedID }) {
            selectedIndex = matchingIndex
        } else {
            selectedIndex = items.isEmpty ? nil : 0
        }
    }

    mutating func handle(_ key: MediaCommandGridKey) -> MediaCommandGridAction {
        if key == .escape {
            return .dismiss
        }
        guard !items.isEmpty else {
            return .ignored
        }

        let currentIndex = selectedIndex ?? 0
        let destination: Int
        switch key {
        case .left:
            destination = max(currentIndex - 1, 0)
        case .right:
            destination = min(currentIndex + 1, items.count - 1)
        case .up:
            destination = max(currentIndex - columnCount, 0)
        case .down:
            destination = min(currentIndex + columnCount, items.count - 1)
        case let .tab(backward):
            if backward {
                destination = (currentIndex - 1 + items.count) % items.count
            } else {
                destination = (currentIndex + 1) % items.count
            }
        case .returnKey:
            selectedIndex = currentIndex
            return .activate(index: currentIndex)
        case .escape:
            return .dismiss
        }

        selectedIndex = destination
        return .moved(to: destination)
    }
}
