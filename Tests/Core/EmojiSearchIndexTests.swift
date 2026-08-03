import XCTest
@testable import MojiPond

final class EmojiSearchIndexTests: XCTestCase {
    func testRankingUsesFrozenTextMatchPrecedence() {
        let items = [
            CoreTestFixtures.item(id: "substring", shortcode: "microwave"),
            CoreTestFixtures.item(id: "token-exact", shortcode: "hello-wave"),
            CoreTestFixtures.item(id: "exact-alias", shortcode: "hello", aliases: ["wave"]),
            CoreTestFixtures.item(id: "exact-shortcode", shortcode: "wave")
        ]
        let index = EmojiSearchIndex(items: items)

        XCTAssertEqual(
            index.search("wave", limit: 20).map(\.item.id),
            [
                "exact-shortcode",
                "exact-alias",
                "token-exact",
                "substring"
            ]
        )
        XCTAssertEqual(
            index.search("wave", limit: 20).map(\.matchKind),
            [
                .exactShortcode,
                .exactAlias,
                .tokenExact,
                .substring
            ]
        )
    }

    func testTokenPrefixPrecedesUnorderedAllTokenMatch() {
        let index = EmojiSearchIndex(items: [
            CoreTestFixtures.item(id: "unordered", shortcode: "hug-bufo"),
            CoreTestFixtures.item(id: "prefix", shortcode: "bufo-hug")
        ])

        let results = index.search("bu h", limit: 20)

        XCTAssertEqual(results.map(\.item.id), ["prefix", "unordered"])
        XCTAssertEqual(results.map(\.matchKind), [.tokenPrefix, .allTokens])
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

    func testTextRelevanceAlwaysPrecedesPersonalization() {
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
            shortcode: "microwave"
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
            ["exact", "prefix", "used-substring"]
        )
    }

    func testTighterDistancePrecedesUsageWithinTheSameMatchTier() {
        let shortPrefix = CoreTestFixtures.item(
            id: "hat",
            shortcode: "bufo-hat"
        )
        let loosePrefix = CoreTestFixtures.item(
            id: "hyperventilating",
            shortcode: "bufo-hyperventilating"
        )
        let usage = EmojiUsageSnapshot(
            statisticsByItemID: [
                "hyperventilating": EmojiUsageStatistics(
                    useCount: 10_000,
                    lastUsedAt: Date(timeIntervalSince1970: 100_000)
                )
            ]
        )

        let results = EmojiSearchIndex(items: [loosePrefix, shortPrefix])
            .search("bufo-h", usage: usage, limit: 20)

        XCTAssertEqual(results.map(\.item.id), ["hat", "hyperventilating"])
        XCTAssertTrue(results.allSatisfy { $0.matchKind == .tokenPrefix })
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
        XCTAssertNil(index.exactMatch(for: " lizard "))
        XCTAssertNil(index.exactMatch(for: "ｌｉｚａｒｄ"))
        XCTAssertEqual(index.exactMatch(for: "lizard")?.item.id, "lizard")
        XCTAssertEqual(index.exactMatch(for: "REPTILE")?.matchKind, .exactAlias)
    }

    func testSeparatorOnlyQueryNeverFallsBackToBrowse() {
        let index = EmojiSearchIndex(items: [
            CoreTestFixtures.item(
                id: "underscore",
                shortcode: "underscore",
                aliases: ["_"]
            ),
            CoreTestFixtures.item(id: "wave", shortcode: "wave")
        ])

        let aliasResult = index.search("_", limit: 20)

        XCTAssertEqual(aliasResult.map(\.item.id), ["underscore"])
        XCTAssertEqual(aliasResult.first?.matchKind, .exactAlias)
        XCTAssertTrue(index.search("---", limit: 20).isEmpty)
        XCTAssertEqual(index.exactMatch(for: "_")?.item.id, "underscore")
    }

    func testSeparatorsAreEquivalentForSearchButNotClosingTokenReplacement() {
        let index = EmojiSearchIndex(items: [
            CoreTestFixtures.item(id: "hug", shortcode: "bufo-hug")
        ])

        XCTAssertEqual(index.search("bufo_hug").first?.item.id, "hug")
        XCTAssertEqual(
            index.search("bufo hug").first?.matchKind,
            .separatorEquivalent
        )
        XCTAssertNil(index.exactMatch(for: "bufo_hug"))
        XCTAssertEqual(index.exactMatch(for: "bufo-hug")?.item.id, "hug")
    }

    func testStandaloneWordFindsMatchingTokenInsidePackShortcode() {
        let index = EmojiSearchIndex(items: [
            CoreTestFixtures.item(id: "hug", shortcode: "bufo-hug"),
            CoreTestFixtures.item(id: "laugh", shortcode: "bufo-laughing-popcorn")
        ])

        XCTAssertEqual(index.search("hug").first?.item.id, "hug")
        XCTAssertEqual(index.search("hug").first?.matchKind, .tokenExact)
    }

    func testSourceFilenameKeywordTailParticipatesInTokenSearch() {
        let index = EmojiSearchIndex(items: [
            CoreTestFixtures.item(
                id: "hug",
                shortcode: "truncated-import-name",
                keywords: ["all-the-bufo/bufo_hug_waving_original.png"]
            )
        ])

        XCTAssertEqual(index.search("original").first?.item.id, "hug")
        XCTAssertEqual(index.search("original").first?.matchKind, .tokenExact)
    }

    func testTokenMatchForYesBeatsSubstringInEyes() {
        let index = EmojiSearchIndex(items: [
            CoreTestFixtures.item(id: "eyes", shortcode: "eyes"),
            CoreTestFixtures.item(id: "yes", shortcode: "bufo-yes")
        ])

        let results = index.search("yes", limit: 20)

        XCTAssertEqual(results.map(\.item.id), ["yes", "eyes"])
        XCTAssertEqual(results.map(\.matchKind), [.tokenExact, .substring])
    }

    func testCanonicalShortcodeTokenBeatsExactKeywordToken() {
        let index = EmojiSearchIndex(items: [
            CoreTestFixtures.item(
                id: "keyword",
                shortcode: "bufo-embrace",
                keywords: ["hug"]
            ),
            CoreTestFixtures.item(id: "shortcode", shortcode: "bufo-hug")
        ])

        let results = index.search("hug", limit: 20)

        XCTAssertEqual(results.map(\.item.id), ["shortcode", "keyword"])
        XCTAssertEqual(results.map(\.matchKind), [.tokenExact, .tokenExact])
        XCTAssertEqual(results.first?.matchedTerm, "bufo-hug")
    }

    func testBufoPrefixStaysAheadOfRecentlyUsedTypoCandidate() {
        let prefix = CoreTestFixtures.item(id: "hug", shortcode: "bufo-hugging")
        let typo = CoreTestFixtures.item(id: "used", shortcode: "bufo-hgu")
        let usage = EmojiUsageSnapshot(
            statisticsByItemID: [
                "used": EmojiUsageStatistics(
                    useCount: 500,
                    lastUsedAt: Date(timeIntervalSince1970: 10_000)
                )
            ]
        )
        let index = EmojiSearchIndex(items: [typo, prefix])

        let results = index.search("bufo-hug", usage: usage, limit: 20)

        XCTAssertEqual(results.first?.item.id, "hug")
        XCTAssertEqual(results.first?.matchKind, .tokenPrefix)
        XCTAssertEqual(results.last?.item.id, "used")
        XCTAssertEqual(results.last?.matchKind, .fuzzy)
    }

    func testBoundedTypoMatchingHandlesTranspositionWithoutNoisySubsequence() {
        let index = EmojiSearchIndex(items: [
            CoreTestFixtures.item(id: "hug", shortcode: "bufo-hug"),
            CoreTestFixtures.item(id: "noise", shortcode: "huge_green_unicycle")
        ])

        XCTAssertEqual(index.search("hgu").first?.item.id, "hug")
        XCTAssertEqual(index.search("hgu").first?.matchKind, .fuzzy)
        XCTAssertTrue(index.search("wve", limit: 20).isEmpty)
    }

    func testTypoCorrectionFillsSpareResultsAfterAValidPrefix() {
        let index = EmojiSearchIndex(items: [
            CoreTestFixtures.item(id: "intended", shortcode: "wave"),
            CoreTestFixtures.item(id: "prefix", shortcode: "waveemoji")
        ])

        let results = index.search("wavee", limit: 20)

        XCTAssertEqual(results.map(\.item.id), ["prefix", "intended"])
        XCTAssertEqual(results.map(\.matchKind), [.tokenPrefix, .fuzzy])
    }

    func testShortQueriesOnlyReturnExactOrPrefixQualityMatches() {
        let index = EmojiSearchIndex(items: [
            CoreTestFixtures.item(id: "prefix", shortcode: "notice"),
            CoreTestFixtures.item(id: "substring", shortcode: "snow"),
            CoreTestFixtures.item(id: "typo", shortcode: "nu")
        ])

        let results = index.search("no", limit: 20)

        XCTAssertEqual(results.map(\.item.id), ["prefix"])
        XCTAssertEqual(results.map(\.matchKind), [.tokenPrefix])
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
