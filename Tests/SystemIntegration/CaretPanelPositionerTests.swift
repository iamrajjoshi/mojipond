import XCTest
@testable import MojiPond

final class CaretPanelPositionerTests: XCTestCase {
    func testQuartzToAppKitConversionSupportsNegativeDisplayOrigins() {
        let display = DisplayGeometry(
            appKitFrame: CGRect(x: -1_920, y: 0, width: 1_920, height: 1_080),
            quartzFrame: CGRect(x: -1_920, y: 0, width: 1_920, height: 1_080),
            visibleFrame: CGRect(x: -1_920, y: 0, width: 1_920, height: 1_040)
        )

        let result = CaretPanelPositioner.appKitCaretRect(
            fromQuartz: CGRect(x: -1_000, y: 100, width: 2, height: 20),
            displays: [display]
        )

        XCTAssertEqual(
            result,
            CGRect(x: -1_000, y: 960, width: 2, height: 20)
        )
    }

    func testPlacementPrefersBelowAndClampsToVisibleFrame() {
        let result = CaretPanelPositioner.placement(
            panelSize: CGSize(width: 300, height: 180),
            nearAppKitCaret: CGRect(x: 950, y: 500, width: 0, height: 0),
            visibleFrame: CGRect(x: 0, y: 0, width: 1_000, height: 800)
        )

        XCTAssertEqual(result.edge, .below)
        XCTAssertEqual(result.frame.maxX, 1_000)
        XCTAssertGreaterThanOrEqual(result.frame.minY, 0)
    }

    func testPlacementFlipsAboveNearBottomEdge() {
        let result = CaretPanelPositioner.placement(
            panelSize: CGSize(width: 200, height: 120),
            nearAppKitCaret: CGRect(x: 40, y: 20, width: 1, height: 18),
            visibleFrame: CGRect(x: 0, y: 0, width: 1_000, height: 800)
        )

        XCTAssertEqual(result.edge, .above)
        XCTAssertGreaterThan(result.frame.minY, 20)
    }

    @MainActor
    func testCaretPanelCannotStealKeyOrMainWindowStatus() {
        let panel = NonactivatingCaretPanel(
            contentRect: CGRect(x: 0, y: 0, width: 300, height: 200)
        )

        XCTAssertFalse(panel.canBecomeKey)
        XCTAssertFalse(panel.canBecomeMain)
        XCTAssertTrue(panel.styleMask.contains(.nonactivatingPanel))
        XCTAssertTrue(panel.collectionBehavior.contains(.canJoinAllSpaces))
        XCTAssertTrue(panel.collectionBehavior.contains(.fullScreenAuxiliary))
    }
}
