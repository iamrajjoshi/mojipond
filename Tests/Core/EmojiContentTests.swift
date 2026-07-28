import XCTest
@testable import MojiPond

final class EmojiContentTests: XCTestCase {
    func testMediaContentRoundTripsWithoutLosingOriginalAssetMetadata() throws {
        let media = MediaEmojiContent(
            mediaType: .gif,
            relativePath: "packs/bufo/bufo_wave.gif",
            thumbnailRelativePath: "thumbnails/bufo_wave.png",
            originalFilename: "bufo_wave.gif",
            contentHash: String(repeating: "a", count: 64),
            dimensions: MediaDimensions(width: 128, height: 128),
            isAnimated: true,
            fallbackRelativePath: nil
        )
        let item = EmojiItem(
            id: "bufo.wave",
            shortcode: try Shortcode(validating: "bufo_wave"),
            name: "Bufo wave",
            aliases: ["BUFO_WAVE", "wave_bufo", "wave_bufo"],
            keywords: ["frog", " Frog ", ""],
            category: "Bufo",
            content: .media(media),
            packID: "bufo",
            packPriority: 7
        )

        let encoded = try JSONEncoder().encode(item)
        let decoded = try JSONDecoder().decode(EmojiItem.self, from: encoded)

        XCTAssertEqual(decoded, item)
        XCTAssertEqual(decoded.aliases, ["wave_bufo"])
        XCTAssertEqual(decoded.keywords, ["frog"])
        XCTAssertTrue(decoded.content.isAnimated)
    }

    func testUnicodeContentReturnsRequestedVariantAndFallsBackToBase() {
        let content = UnicodeEmojiContent(
            value: "👋",
            unicodeVersion: "6.0",
            skinToneVariants: [
                UnicodeEmojiVariant(skinTone: .medium, value: "👋🏽")
            ]
        )

        XCTAssertEqual(content.value(for: .medium), "👋🏽")
        XCTAssertEqual(content.value(for: .dark), "👋")
        XCTAssertEqual(content.value(for: nil), "👋")
    }

    func testAliasSyntaxKeepsBuiltInPlusAliasButRejectsUnboundedOrUnicodeAliases() {
        let item = CoreTestFixtures.item(
            id: "thumbsup",
            shortcode: "thumbsup",
            aliases: ["+1", "é", String(repeating: "a", count: 65)]
        )

        XCTAssertEqual(item.aliases, ["+1"])
    }
}
