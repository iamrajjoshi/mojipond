import AppKit
import XCTest
@testable import MojiPond

@MainActor
final class RuntimeVoiceOverAnnouncementTests: XCTestCase {
    func testSuggestionPanelConvertsHitTargetToQuartzCoordinates() {
        let display = DisplayGeometry(
            appKitFrame: CGRect(x: 0, y: 0, width: 1_920, height: 1_080),
            quartzFrame: CGRect(x: 0, y: 0, width: 1_920, height: 1_080),
            visibleFrame: CGRect(x: 0, y: 0, width: 1_920, height: 1_080)
        )

        XCTAssertEqual(
            RuntimeSuggestionPanelController.quartzFrame(
                forAppKitFrame: CGRect(
                    x: 100,
                    y: 200,
                    width: 380,
                    height: 279
                ),
                displays: [display]
            ),
            CGRect(x: 100, y: 601, width: 380, height: 279)
        )
    }

    func testSuggestionPanelSizesToVisibleSuggestionRows() {
        let row =
            RuntimeSuggestionRow(
                id: "wave",
                glyph: "👋",
                shortcode: "wave",
                name: "Waving hand"
            )
        let oneSuggestion = RuntimeSuggestionPanelSnapshot(
            revision: 1,
            transactionID: ParserTransactionID(rawValue: 1),
            mode: .suggestions,
            rows: [row],
            selectedIndex: 0,
            query: nil
        )
        let fiveSuggestions = RuntimeSuggestionPanelSnapshot(
            revision: 2,
            transactionID: ParserTransactionID(rawValue: 1),
            mode: .suggestions,
            rows: Array(repeating: row, count: 5),
            selectedIndex: 0,
            query: "wa"
        )
        let sixSuggestions = RuntimeSuggestionPanelSnapshot(
            revision: 3,
            transactionID: ParserTransactionID(rawValue: 1),
            mode: .suggestions,
            rows: Array(repeating: row, count: 6),
            selectedIndex: 0,
            query: "wa"
        )
        let overflowingSuggestions = RuntimeSuggestionPanelSnapshot(
            revision: 4,
            transactionID: ParserTransactionID(rawValue: 1),
            mode: .suggestions,
            rows: Array(repeating: row, count: 7),
            selectedIndex: 0,
            query: "wa"
        )
        let noSuggestions = RuntimeSuggestionPanelSnapshot(
            revision: 5,
            transactionID: ParserTransactionID(rawValue: 1),
            mode: .suggestions,
            rows: [],
            selectedIndex: 0,
            query: "zzzz"
        )
        let browser = RuntimeSuggestionPanelSnapshot(
            revision: 6,
            transactionID: ParserTransactionID(rawValue: 2),
            mode: .browser,
            rows: [row],
            selectedIndex: 0,
            query: "pond"
        )
        let committing = RuntimeSuggestionPanelSnapshot(
            revision: 9,
            transactionID: ParserTransactionID(rawValue: 3),
            mode: .committing,
            rows: [row],
            selectedIndex: 0,
            query: nil
        )
        let fullBrowser = RuntimeSuggestionPanelSnapshot(
            revision: 7,
            transactionID: ParserTransactionID(rawValue: 2),
            mode: .browser,
            rows: Array(repeating: row, count: 7),
            selectedIndex: 0,
            query: "pond"
        )
        let overflowingBrowser = RuntimeSuggestionPanelSnapshot(
            revision: 8,
            transactionID: ParserTransactionID(rawValue: 2),
            mode: .browser,
            rows: Array(repeating: row, count: 8),
            selectedIndex: 0,
            query: "pond"
        )

        XCTAssertEqual(
            RuntimeSuggestionPanelController.preferredSize(
                for: oneSuggestion
            ),
            CGSize(width: 380, height: 69)
        )
        XCTAssertEqual(
            RuntimeSuggestionPanelController.preferredSize(
                for: fiveSuggestions
            ),
            CGSize(width: 380, height: 237)
        )
        XCTAssertEqual(
            RuntimeSuggestionPanelController.preferredSize(
                for: sixSuggestions
            ),
            CGSize(width: 380, height: 279)
        )
        XCTAssertEqual(
            RuntimeSuggestionPanelController.preferredSize(
                for: overflowingSuggestions
            ),
            CGSize(width: 380, height: 279)
        )
        XCTAssertEqual(overflowingSuggestions.visibleRows.count, 6)
        let selectedOverflowingSuggestion = RuntimeSuggestionPanelSnapshot(
            revision: 9,
            transactionID: ParserTransactionID(rawValue: 3),
            mode: .suggestions,
            rows: (0..<8).map { index in
                RuntimeSuggestionRow(
                    id: "row.\(index)",
                    glyph: "🐸",
                    shortcode: "pond_\(index)",
                    name: "Pond \(index)"
                )
            },
            selectedIndex: 6,
            query: nil
        )
        XCTAssertEqual(
            selectedOverflowingSuggestion.selectedRow?.shortcode,
            "pond_6"
        )
        XCTAssertEqual(
            RuntimeSuggestionPanelController.preferredSize(
                for: selectedOverflowingSuggestion
            ),
            CGSize(width: 380, height: 279)
        )
        XCTAssertEqual(
            RuntimeVoiceOverAnnouncement.suggestions(
                selectedOverflowingSuggestion
            ),
            "8 emoji suggestions. Selected Pond 6, colon pond_6 colon."
        )
        XCTAssertEqual(
            RuntimeVoiceOverAnnouncement.suggestions(
                overflowingSuggestions
            ),
            "7 emoji suggestions. Selected Waving hand, colon wave colon."
        )
        XCTAssertEqual(
            RuntimeSuggestionPanelController.preferredSize(
                for: noSuggestions
            ),
            CGSize(width: 380, height: 69)
        )
        XCTAssertEqual(
            RuntimeSuggestionPanelController.preferredSize(
                for: browser
            ),
            CGSize(width: 440, height: 111)
        )
        XCTAssertEqual(
            RuntimeSuggestionPanelController.preferredSize(
                for: fullBrowser
            ),
            CGSize(width: 440, height: 363)
        )
        XCTAssertEqual(
            RuntimeSuggestionPanelController.preferredSize(
                for: overflowingBrowser
            ),
            CGSize(width: 440, height: 363)
        )
        XCTAssertEqual(
            RuntimeSuggestionPanelController.preferredSize(
                for: committing
            ),
            CGSize(width: 380, height: 44)
        )
        XCTAssertEqual(
            RuntimeVoiceOverAnnouncement.suggestions(committing),
            "Adding Waving hand. Escape cancels."
        )
    }

    func testSuggestionInteractionHintMatchesAcceptedKeys() {
        let row = RuntimeSuggestionRow(
            id: "wave",
            glyph: "👋",
            shortcode: "wave",
            name: "Waving hand"
        )
        let base = RuntimeSuggestionPanelSnapshot(
            revision: 1,
            transactionID: ParserTransactionID(rawValue: 1),
            mode: .suggestions,
            rows: [row],
            selectedIndex: 0,
            query: nil,
            acceptsTab: true,
            acceptsReturn: false
        )

        XCTAssertEqual(
            base.compactInteractionHint,
            "↑↓ choose  ·  tab insert  ·  esc close"
        )
        XCTAssertEqual(
            base.compactInteractionAccessibilityLabel,
            "Up and Down Arrow choose, Tab inserts, Escape closes"
        )

        let noAcceptanceKeys = RuntimeSuggestionPanelSnapshot(
            revision: 2,
            transactionID: ParserTransactionID(rawValue: 1),
            mode: .suggestions,
            rows: [row],
            selectedIndex: 0,
            query: nil,
            acceptsTab: false,
            acceptsReturn: false
        )
        XCTAssertEqual(
            noAcceptanceKeys.compactInteractionHint,
            "↑↓ choose  ·  esc close"
        )

        let noSuggestions = RuntimeSuggestionPanelSnapshot(
            revision: 3,
            transactionID: ParserTransactionID(rawValue: 1),
            mode: .suggestions,
            rows: [],
            selectedIndex: 0,
            query: "zz"
        )
        XCTAssertEqual(
            noSuggestions.compactInteractionHint,
            "⌫ edit  ·  esc close"
        )
        XCTAssertEqual(
            noSuggestions.compactInteractionAccessibilityLabel,
            "Backspace edits, Escape closes"
        )

        let emptyBrowser = RuntimeSuggestionPanelSnapshot(
            revision: 4,
            transactionID: ParserTransactionID(rawValue: 2),
            mode: .browser,
            rows: [],
            selectedIndex: 0,
            query: ""
        )
        XCTAssertEqual(
            emptyBrowser.compactInteractionHint,
            "type to search  ·  esc close"
        )
        XCTAssertEqual(
            emptyBrowser.compactInteractionAccessibilityLabel,
            "Type to search, Escape closes"
        )
    }

    func testSuggestionPresentationUsesConfiguredTrigger() {
        let row = RuntimeSuggestionRow(
            id: "wave",
            glyph: "👋",
            shortcode: "wave",
            name: "Waving hand"
        )
        let snapshot = RuntimeSuggestionPanelSnapshot(
            revision: 1,
            transactionID: ParserTransactionID(rawValue: 1),
            mode: .suggestions,
            rows: [row],
            selectedIndex: 0,
            query: "wa",
            trigger: .semicolon
        )

        XCTAssertEqual(snapshot.trigger.rawValue, ";")
        XCTAssertEqual(
            RuntimeVoiceOverAnnouncement.suggestions(snapshot),
            "1 emoji suggestion. Selected Waving hand, semicolon wave semicolon."
        )
    }

    func testBrowserAnnouncementIncludesQueryCountAndSelection() {
        let snapshot = RuntimeSuggestionPanelSnapshot(
            revision: 1,
            transactionID: ParserTransactionID(rawValue: 1),
            mode: .browser,
            rows: [
                RuntimeSuggestionRow(
                    id: "frog",
                    glyph: "🐸",
                    shortcode: "frog",
                    name: "frog"
                )
            ],
            selectedIndex: 0,
            query: "fro"
        )

        XCTAssertEqual(
            RuntimeVoiceOverAnnouncement.suggestions(snapshot),
            "1 result for fro. Selected frog, colon frog colon."
        )
    }

    func testSelectionOnlyVoiceOverUpdateDoesNotRepeatResultCount() {
        let rows = [
            RuntimeSuggestionRow(
                id: "frog",
                glyph: "🐸",
                shortcode: "frog",
                name: "Frog"
            ),
            RuntimeSuggestionRow(
                id: "fox",
                glyph: "🦊",
                shortcode: "fox",
                name: "Fox"
            )
        ]
        let previous = RuntimeSuggestionPanelSnapshot(
            revision: 1,
            transactionID: ParserTransactionID(rawValue: 1),
            mode: .browser,
            rows: rows,
            selectedIndex: 0,
            query: "f"
        )
        let selectionUpdate = RuntimeSuggestionPanelSnapshot(
            revision: 2,
            transactionID: ParserTransactionID(rawValue: 1),
            mode: .browser,
            rows: rows,
            selectedIndex: 1,
            query: "f"
        )
        let queryUpdate = RuntimeSuggestionPanelSnapshot(
            revision: 3,
            transactionID: ParserTransactionID(rawValue: 1),
            mode: .browser,
            rows: rows,
            selectedIndex: 1,
            query: "fo"
        )

        XCTAssertEqual(
            RuntimeVoiceOverAnnouncement.suggestionUpdate(
                selectionUpdate,
                after: previous
            ),
            "Selected Fox, colon fox colon."
        )
        XCTAssertEqual(
            RuntimeVoiceOverAnnouncement.suggestionUpdate(
                queryUpdate,
                after: selectionUpdate
            ),
            "2 results for fo. Selected Fox, colon fox colon."
        )
    }

}
