import XCTest
@testable import MojiPond

final class SkinToneResolverTests: XCTestCase {
    private let variants = [
        UnicodeEmojiVariant(skinTone: .light, value: "👋🏻"),
        UnicodeEmojiVariant(skinTone: .medium, value: "👋🏽"),
        UnicodeEmojiVariant(skinTone: .dark, value: "👋🏿")
    ]

    func testExplicitTonePrecedesItemPreferenceAndGlobalDefault() {
        let item = CoreTestFixtures.item(
            id: "wave",
            shortcode: "wave",
            value: "👋",
            variants: variants
        )
        let usage = EmojiUsageSnapshot(
            preferredSkinToneByItemID: ["wave": .medium]
        )

        let result = SkinToneResolver.resolve(
            item: item,
            explicitTone: .dark,
            defaultTone: .light,
            usage: usage
        )

        XCTAssertEqual(
            result,
            ResolvedUnicodeEmoji(
                value: "👋🏿",
                skinTone: .dark,
                source: .explicit
            )
        )
    }

    func testItemPreferencePrecedesGlobalDefault() {
        let item = CoreTestFixtures.item(
            id: "wave",
            shortcode: "wave",
            value: "👋",
            variants: variants
        )
        let usage = EmojiUsageSnapshot(
            preferredSkinToneByItemID: ["wave": .medium]
        )

        XCTAssertEqual(
            SkinToneResolver.resolve(
                item: item,
                defaultTone: .light,
                usage: usage
            )?.source,
            .itemPreference
        )
    }

    func testUnavailablePreferencesFallBackToMostUsedAvailableTone() {
        let item = CoreTestFixtures.item(
            id: "wave",
            shortcode: "wave",
            value: "👋",
            variants: variants
        )
        let usage = EmojiUsageSnapshot(
            statisticsByItemID: [
                "wave": EmojiUsageStatistics(
                    useCount: 5,
                    skinToneUseCounts: [.medium: 4, .dark: 1],
                    lastUsedSkinTone: .medium
                )
            ],
            preferredSkinToneByItemID: ["wave": .mediumLight]
        )

        let result = SkinToneResolver.resolve(
            item: item,
            explicitTone: .mediumDark,
            defaultTone: .mediumLight,
            usage: usage
        )

        XCTAssertEqual(result?.value, "👋🏽")
        XCTAssertEqual(result?.source, .itemUsage)
    }

    func testBaseEmojiIsUsedWhenNoVariantCanBeSelected() {
        let item = CoreTestFixtures.item(
            id: "lizard",
            shortcode: "lizard",
            value: "🦎"
        )

        XCTAssertEqual(
            SkinToneResolver.resolve(item: item, defaultTone: .dark),
            ResolvedUnicodeEmoji(
                value: "🦎",
                skinTone: nil,
                source: .baseEmoji
            )
        )
    }

    func testMediaDoesNotResolveAsUnicode() throws {
        let media = MediaEmojiContent(
            mediaType: .png,
            relativePath: "packs/bufo.png",
            contentHash: String(repeating: "b", count: 64)
        )
        let item = EmojiItem(
            id: "bufo",
            shortcode: try Shortcode(validating: "bufo"),
            name: "Bufo",
            category: "Custom",
            content: .media(media),
            packID: "bufo"
        )

        XCTAssertNil(SkinToneResolver.resolve(item: item, defaultTone: .medium))
    }
}
