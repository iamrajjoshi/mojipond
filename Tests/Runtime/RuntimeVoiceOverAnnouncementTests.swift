import AppKit
import ImageIO
import UniformTypeIdentifiers
import XCTest
@testable import MojiPond

@MainActor
final class RuntimeVoiceOverAnnouncementTests: XCTestCase {
    func testMediaPreviewPlaybackHonorsReduceMotion() {
        XCTAssertEqual(
            RuntimeMediaPreviewPolicy.playback(
                isSelected: true,
                reduceMotion: false
            ),
            .animated
        )
        XCTAssertEqual(
            RuntimeMediaPreviewPolicy.playback(
                isSelected: true,
                reduceMotion: true
            ),
            .staticFrame
        )
        XCTAssertEqual(
            RuntimeMediaPreviewPolicy.playback(
                isSelected: false,
                reduceMotion: false
            ),
            .staticFrame
        )
        XCTAssertFalse(RuntimeMediaPreviewPlayback.staticFrame.animates)
    }

    func testStaticMediaPreviewPlaybackProducesUsefulFirstFrame()
        throws
    {
        let workspace = try TestSupport.makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: workspace) }
        let sourceURL = try TestSupport.writeImage(
            to: workspace.appendingPathComponent("animated.gif"),
            format: .gif,
            width: 24,
            height: 16,
            frameCount: 3
        )
        let sourceData = try Data(contentsOf: sourceURL)

        let prepared = try XCTUnwrap(
            RuntimeMediaPreviewPolicy.prepareImageData(
                sourceData,
                playback: .staticFrame,
                limits: .default
            )
        )
        let imageSource = try XCTUnwrap(
            CGImageSourceCreateWithData(prepared as CFData, nil)
        )

        XCTAssertEqual(CGImageSourceGetCount(imageSource), 1)
        XCTAssertEqual(
            CGImageSourceGetType(imageSource) as String?,
            UTType.png.identifier
        )
        XCTAssertNotNil(CGImageSourceCreateImageAtIndex(imageSource, 0, nil))
    }

    func testMediaPreviewFailureHasAccessibleDescription() {
        XCTAssertEqual(
            RuntimeMediaPreviewLoadState.loading.accessibilityDescription,
            "Preview loading"
        )
        XCTAssertNil(
            RuntimeMediaPreviewLoadState.loaded.accessibilityDescription
        )
        XCTAssertEqual(
            RuntimeMediaPreviewLoadState.failed.accessibilityDescription,
            "Preview unavailable"
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
        XCTAssertEqual(
            RuntimeVoiceOverAnnouncement.suggestions(
                overflowingSuggestions
            ),
            "6 emoji suggestions. Selected Waving hand, colon wave colon."
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

    func testMediaAnnouncementTracksStateAndSelection() {
        let snapshot = RuntimeMediaPanelSnapshot(
            revision: 1,
            command: .sticker,
            state: .offline,
            items: [
                RuntimeMediaPanelItem(
                    id: "wave",
                    title: "Waving hand",
                    previewURL: URL(fileURLWithPath: "/tmp/wave.gif"),
                    provider: .notoAnimatedEmoji
                )
            ],
            selectedIndex: 0,
            attributions: []
        )

        XCTAssertEqual(
            RuntimeVoiceOverAnnouncement.media(snapshot),
            "Offline. Showing 1 bundled result. Selected Waving hand, 1 of 1."
        )
    }

    func testMediaPanelUsesOnlyTheRowsItsResultsNeed() {
        func snapshot(itemCount: Int) -> RuntimeMediaPanelSnapshot {
            RuntimeMediaPanelSnapshot(
                revision: UInt64(itemCount),
                command: .sticker,
                state: .results,
                items: (0 ..< itemCount).map { index in
                    RuntimeMediaPanelItem(
                        id: "item-\(index)",
                        title: "Item \(index)",
                        previewURL: URL(
                            fileURLWithPath: "/tmp/item-\(index).gif"
                        ),
                        provider: .notoAnimatedEmoji
                    )
                },
                selectedIndex: itemCount > 0 ? 0 : nil,
                attributions: []
            )
        }

        XCTAssertEqual(
            RuntimeMediaPanelView.preferredSize(for: snapshot(itemCount: 0)),
            CGSize(width: 500, height: 146)
        )
        for count in 1 ... 4 {
            XCTAssertEqual(
                RuntimeMediaPanelView.preferredSize(
                    for: snapshot(itemCount: count)
                ),
                CGSize(width: 500, height: 208)
            )
        }
        XCTAssertEqual(
            RuntimeMediaPanelView.preferredSize(for: snapshot(itemCount: 5)),
            CGSize(width: 500, height: 319)
        )
        XCTAssertEqual(
            RuntimeMediaPanelView.preferredSize(for: snapshot(itemCount: 12)),
            CGSize(width: 500, height: 430)
        )
        XCTAssertEqual(
            RuntimeMediaPanelView.preferredSize(for: snapshot(itemCount: 13)),
            CGSize(width: 500, height: 430)
        )
    }

    func testMediaInteractionHintsMatchTheKeysEachStateOwns() {
        let item = RuntimeMediaPanelItem(
            id: "wave",
            title: "Waving hand",
            previewURL: URL(fileURLWithPath: "/tmp/wave.gif"),
            provider: .notoAnimatedEmoji
        )
        let empty = RuntimeMediaPanelSnapshot(
            revision: 1,
            command: .sticker,
            state: .empty,
            items: [],
            selectedIndex: nil,
            attributions: []
        )
        let results = RuntimeMediaPanelSnapshot(
            revision: 2,
            command: .sticker,
            state: .results,
            items: [item],
            selectedIndex: 0,
            attributions: []
        )
        let resolving = RuntimeMediaPanelSnapshot(
            revision: 3,
            command: .sticker,
            state: .resolving,
            items: [item],
            selectedIndex: 0,
            attributions: []
        )

        XCTAssertFalse(empty.canActivateSelection)
        XCTAssertFalse(empty.capturesSelectionKeys)
        XCTAssertEqual(
            empty.interactionHint,
            "type to refine  ·  esc close"
        )
        XCTAssertTrue(results.canActivateSelection)
        XCTAssertTrue(results.capturesSelectionKeys)
        XCTAssertEqual(
            results.interactionHint,
            "arrows choose  ·  ↩ insert  ·  esc close"
        )
        XCTAssertFalse(resolving.canActivateSelection)
        XCTAssertTrue(resolving.capturesSelectionKeys)
        XCTAssertEqual(
            resolving.interactionHint,
            "preparing  ·  esc cancel"
        )
    }

    func testMediaSelectionAnnouncementDoesNotRepeatTheResultCount() {
        let items = [
            RuntimeMediaPanelItem(
                id: "wave",
                title: "Waving hand",
                previewURL: URL(fileURLWithPath: "/tmp/wave.gif"),
                provider: .notoAnimatedEmoji
            ),
            RuntimeMediaPanelItem(
                id: "frog",
                title: "Frog",
                previewURL: URL(fileURLWithPath: "/tmp/frog.gif"),
                provider: .notoAnimatedEmoji
            )
        ]
        let previous = RuntimeMediaPanelSnapshot(
            revision: 1,
            command: .sticker,
            state: .results,
            items: items,
            selectedIndex: 0,
            attributions: []
        )
        let selectionUpdate = RuntimeMediaPanelSnapshot(
            revision: 2,
            command: .sticker,
            state: .results,
            items: items,
            selectedIndex: 1,
            attributions: []
        )

        XCTAssertEqual(
            RuntimeVoiceOverAnnouncement.media(previous),
            "2 media results. Selected Waving hand, 1 of 2."
        )
        XCTAssertEqual(
            RuntimeVoiceOverAnnouncement.mediaUpdate(
                selectionUpdate,
                after: previous
            ),
            "Selected Frog, 2 of 2."
        )
    }

    func testMediaFailureAnnouncementExplainsTheProblem() {
        let snapshot = RuntimeMediaPanelSnapshot(
            revision: 1,
            command: .sticker,
            state: .failed(.providerUnavailable),
            items: [],
            selectedIndex: nil,
            attributions: []
        )

        XCTAssertEqual(
            RuntimeVoiceOverAnnouncement.media(snapshot),
            "Media search failed. The media provider is unavailable."
        )
    }

    func testMediaPreviewReusesSourceAcrossSelectionChanges() async throws {
        let workspace = try TestSupport.makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: workspace) }
        let sourceURL = try TestSupport.writeImage(
            to: workspace.appendingPathComponent("animated.gif"),
            format: .gif,
            width: 24,
            height: 16,
            frameCount: 3
        )
        let sourceData = try Data(contentsOf: sourceURL)
        var sourceLoads = 0
        let coordinator = RuntimeAnimatedMediaPreview.Coordinator {
            _, _ in
            sourceLoads += 1
            try await Task.sleep(for: .milliseconds(40))
            return sourceData
        }
        let imageView = NSImageView()
        let firstLoad = expectation(description: "animated preview loaded")
        var nextLoadExpectation: XCTestExpectation? = firstLoad
        let stateChanged: @MainActor (RuntimeMediaPreviewLoadState) -> Void = {
            state in
            guard state == .loaded else {
                return
            }
            nextLoadExpectation?.fulfill()
            nextLoadExpectation = nil
        }

        coordinator.load(
            sourceURL,
            provider: .notoAnimatedEmoji,
            animates: false,
            into: imageView,
            stateChanged: stateChanged
        )
        coordinator.load(
            sourceURL,
            provider: .notoAnimatedEmoji,
            animates: true,
            into: imageView,
            stateChanged: stateChanged
        )
        await fulfillment(of: [firstLoad], timeout: 2)

        XCTAssertEqual(sourceLoads, 1)
        XCTAssertNotNil(imageView.image)
        XCTAssertTrue(imageView.animates)

        let staticLoad = expectation(description: "static preview loaded")
        nextLoadExpectation = staticLoad
        coordinator.load(
            sourceURL,
            provider: .notoAnimatedEmoji,
            animates: false,
            into: imageView,
            stateChanged: stateChanged
        )

        XCTAssertEqual(sourceLoads, 1)
        XCTAssertNotNil(
            imageView.image,
            "The existing preview should remain visible while deriving a frame"
        )
        XCTAssertFalse(imageView.animates)
        await fulfillment(of: [staticLoad], timeout: 2)

        XCTAssertEqual(sourceLoads, 1)
        XCTAssertNotNil(imageView.image)
        coordinator.cancel()
    }
}
