import XCTest
@testable import MojiPond

final class EmojiSearchIndexTests: XCTestCase {
    func testRankingUsesFrozenTextMatchPrecedence() {
        let items = [
            CoreTestFixtures.item(id: "fuzzy", shortcode: "wobble_alpha_velvet_echo"),
            CoreTestFixtures.item(id: "substring", shortcode: "microwave"),
            CoreTestFixtures.item(id: "keyword", shortcode: "farewell", keywords: ["wave"]),
            CoreTestFixtures.item(id: "name", shortcode: "salute", name: "Wave hello"),
            CoreTestFixtures.item(id: "alias-prefix", shortcode: "greeting", aliases: ["wave_back"]),
            CoreTestFixtures.item(id: "shortcode-prefix", shortcode: "wave_hello"),
            CoreTestFixtures.item(id: "exact-alias", shortcode: "hello", aliases: ["wave"]),
            CoreTestFixtures.item(id: "exact-shortcode", shortcode: "wave")
        ]
        let results = EmojiSearchIndex(items: items).search("wave", limit: 20)

        XCTAssertEqual(
            results.map(\.item.id),
            [
                "exact-shortcode",
                "exact-alias",
                "shortcode-prefix",
                "alias-prefix",
                "name",
                "keyword",
                "substring",
                "fuzzy"
            ]
        )
        XCTAssertEqual(
            results.map(\.matchKind),
            [
                .exactShortcode,
                .exactAlias,
                .shortcodePrefix,
                .aliasPrefix,
                .namePrefix,
                .keyword,
                .substring,
                .fuzzy
            ]
        )
    }

    func testRecencyPrecedesPackPriorityWithinSameTextMatch() {
        let highPriority = CoreTestFixtures.item(
            id: "high",
            shortcode: "cat_a",
            packPriority: 10
        )
        let recentlyUsed = CoreTestFixtures.item(
            id: "recent",
            shortcode: "cat_b",
            packPriority: 0
        )
        let usage = EmojiUsageSnapshot(
            statisticsByItemID: [
                "recent": EmojiUsageStatistics(
                    useCount: 100,
                    lastUsedAt: Date(timeIntervalSince1970: 10_000)
                )
            ]
        )

        let results = EmojiSearchIndex(items: [recentlyUsed, highPriority])
            .search("cat", usage: usage)

        XCTAssertEqual(results.map(\.item.id), ["recent", "high"])
    }

    func testUsedSubstringCanOutrankUnusedPrefixButNotExactMatch() {
        let exact = CoreTestFixtures.item(
            id: "exact",
            shortcode: "wave"
        )
        let prefix = CoreTestFixtures.item(
            id: "prefix",
            shortcode: "wave_hello"
        )
        let usedSubstring = CoreTestFixtures.item(
            id: "used-substring",
            shortcode: "bufo-wave"
        )
        let usage = EmojiUsageSnapshot(
            statisticsByItemID: [
                "used-substring": EmojiUsageStatistics(
                    useCount: 4,
                    lastUsedAt: Date(timeIntervalSince1970: 10_000)
                )
            ]
        )

        let results = EmojiSearchIndex(
            items: [prefix, usedSubstring, exact]
        ).search("wave", usage: usage)

        XCTAssertEqual(
            results.map(\.item.id),
            ["exact", "used-substring", "prefix"]
        )
    }

    func testRecencyThenUseCountBreakTiesWithinPack() {
        let old = CoreTestFixtures.item(id: "old", shortcode: "dog_a")
        let recent = CoreTestFixtures.item(id: "recent", shortcode: "dog_b")
        let unused = CoreTestFixtures.item(id: "unused", shortcode: "dog_c")
        let usage = EmojiUsageSnapshot(
            statisticsByItemID: [
                "old": EmojiUsageStatistics(
                    useCount: 500,
                    lastUsedAt: Date(timeIntervalSince1970: 10)
                ),
                "recent": EmojiUsageStatistics(
                    useCount: 1,
                    lastUsedAt: Date(timeIntervalSince1970: 20)
                )
            ]
        )

        let results = EmojiSearchIndex(items: [old, unused, recent])
            .search("dog", usage: usage)

        XCTAssertEqual(results.map(\.item.id), ["recent", "old", "unused"])
    }

    func testFavoriteBreaksTieBeforeRecencyWithinPack() {
        let favorite = CoreTestFixtures.item(
            id: "favorite",
            shortcode: "frog_a"
        )
        let recent = CoreTestFixtures.item(
            id: "recent",
            shortcode: "frog_b"
        )
        let usage = EmojiUsageSnapshot(
            statisticsByItemID: [
                "recent": EmojiUsageStatistics(
                    useCount: 100,
                    lastUsedAt: Date(timeIntervalSince1970: 10_000)
                )
            ],
            favoriteItemIDs: ["favorite"]
        )

        let results = EmojiSearchIndex(items: [recent, favorite])
            .search("frog", usage: usage)

        XCTAssertEqual(results.map(\.item.id), ["favorite", "recent"])
    }

    func testOrderingIsDeterministicAcrossInputOrder() {
        let items = [
            CoreTestFixtures.item(id: "z", shortcode: "pond_z"),
            CoreTestFixtures.item(id: "a", shortcode: "pond_a"),
            CoreTestFixtures.item(id: "m", shortcode: "pond_m")
        ]

        let forward = EmojiSearchIndex(items: items).search("pond").map(\.item.id)
        let reversed = EmojiSearchIndex(items: Array(items.reversed())).search("pond").map(\.item.id)

        XCTAssertEqual(forward, ["a", "m", "z"])
        XCTAssertEqual(reversed, forward)
    }

    func testExactMatchNeverReturnsPrefixOrFuzzyCandidate() {
        let index = EmojiSearchIndex(items: [
            CoreTestFixtures.item(
                id: "lizard",
                shortcode: "lizard",
                aliases: ["reptile"]
            )
        ])

        XCTAssertNil(index.exactMatch(for: "liz"))
        XCTAssertNil(index.exactMatch(for: "lzzrd"))
        XCTAssertEqual(index.exactMatch(for: "lizard")?.item.id, "lizard")
        XCTAssertEqual(index.exactMatch(for: "REPTILE")?.matchKind, .exactAlias)
    }

    func testCustomAliasesParticipateAsExactAliases() {
        let item = CoreTestFixtures.item(
            id: "party",
            shortcode: "tada",
            aliases: ["party_parrot"]
        )
        let usage = EmojiUsageSnapshot(
            customAliasesByItemID: ["party": ["celebrate"]]
        )
        let index = EmojiSearchIndex(items: [item])

        let result = index.exactMatch(for: "celebrate", usage: usage)

        XCTAssertEqual(result?.item.id, "party")
        XCTAssertEqual(result?.matchKind, .exactAlias)
        XCTAssertEqual(
            index.exactTokens(usage: usage),
            ["tada", "party_parrot", "celebrate"]
        )
    }

    func testBrowseFiltersDisabledPacksAndHonorsLimit() {
        let enabled = EmojiCatalogPack(
            id: "enabled",
            name: "Enabled",
            source: .local,
            priority: 2,
            items: [
                CoreTestFixtures.item(id: "one", shortcode: "one"),
                CoreTestFixtures.item(id: "two", shortcode: "two")
            ]
        )
        let disabled = EmojiCatalogPack(
            id: "disabled",
            name: "Disabled",
            source: .local,
            isEnabled: false,
            priority: 100,
            items: [
                CoreTestFixtures.item(id: "hidden", shortcode: "hidden")
            ]
        )

        let results = EmojiSearchIndex(packs: [disabled, enabled]).search("", limit: 1)

        XCTAssertEqual(results.count, 1)
        XCTAssertEqual(results.first?.matchKind, .browse)
        XCTAssertNotEqual(results.first?.item.id, "hidden")
    }

    func testSearchNormalizesCaseWidthAndDiacritics() {
        let index = EmojiSearchIndex(items: [
            CoreTestFixtures.item(id: "cafe", shortcode: "coffee", name: "Café")
        ])

        XCTAssertEqual(index.search("ＣＡＦＥ").first?.item.id, "cafe")
    }
}
