import Foundation
import XCTest
@testable import MojiPond

final class MediaCommandGridTests: XCTestCase {
    func testArrowsMoveWithinGridBounds() {
        var grid = MediaCommandGrid(items: items(count: 7), columnCount: 3)

        XCTAssertEqual(grid.handle(.right), .moved(to: 1))
        XCTAssertEqual(grid.handle(.down), .moved(to: 4))
        XCTAssertEqual(grid.handle(.down), .moved(to: 6))
        XCTAssertEqual(grid.handle(.right), .moved(to: 6))
        XCTAssertEqual(grid.handle(.up), .moved(to: 3))
        XCTAssertEqual(grid.handle(.left), .moved(to: 2))
    }

    func testTabWrapsAndReturnActivatesSelection() {
        var grid = MediaCommandGrid(items: items(count: 2))

        XCTAssertEqual(grid.handle(.tab(backward: true)), .moved(to: 1))
        XCTAssertEqual(grid.handle(.tab(backward: false)), .moved(to: 0))
        XCTAssertEqual(grid.handle(.returnKey), .activate(index: 0))
        XCTAssertEqual(grid.handle(.escape), .dismiss)
    }

    func testUpdatesPreserveSelectionByStableIdentifier() {
        let original = items(count: 3)
        var grid = MediaCommandGrid(items: original)
        _ = grid.handle(.right)

        grid.updateItems([original[2], original[1]])

        XCTAssertEqual(grid.selectedIndex, 1)
        XCTAssertEqual(grid.handle(.returnKey), .activate(index: 1))
    }

    private func items(count: Int) -> [MediaCommandResult] {
        (0..<count).map { index in
            let url = URL(string: "https://fonts.gstatic.com/\(index).gif")!
            return MediaCommandResult(
                media: RemoteMediaItem(
                    id: "item-\(index)",
                    provider: .notoAnimatedEmoji,
                    title: "Item \(index)",
                    previewURL: url,
                    originalURL: url,
                    dimensions: nil,
                    attribution: "Noto Animated Emoji by Google"
                ),
                origin: .remote
            )
        }
    }
}
