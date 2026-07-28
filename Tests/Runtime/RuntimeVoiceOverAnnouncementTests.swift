import ImageIO
import UniformTypeIdentifiers
import XCTest
@testable import MojiPond

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

    func testSuggestionPanelUsesProductionDocumentationGeometry() {
        let rows = [
            RuntimeSuggestionRow(
                id: "wave",
                glyph: "👋",
                shortcode: "wave",
                name: "Waving hand"
            )
        ]
        let suggestions = RuntimeSuggestionPanelSnapshot(
            revision: 1,
            transactionID: ParserTransactionID(rawValue: 1),
            mode: .suggestions,
            rows: rows,
            selectedIndex: 0,
            query: nil
        )
        let browser = RuntimeSuggestionPanelSnapshot(
            revision: 2,
            transactionID: ParserTransactionID(rawValue: 2),
            mode: .browser,
            rows: rows,
            selectedIndex: 0,
            query: "pond"
        )

        XCTAssertEqual(
            RuntimeSuggestionPanelController.preferredSize(
                for: suggestions
            ),
            CGSize(width: 380, height: 282)
        )
        XCTAssertEqual(
            RuntimeSuggestionPanelController.preferredSize(
                for: browser
            ),
            CGSize(width: 440, height: 92)
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
            "Offline. Showing 1 bundled results. Selected Waving hand."
        )
    }
}
