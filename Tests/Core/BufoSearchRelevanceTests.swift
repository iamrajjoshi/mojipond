import XCTest
@testable import MojiPond

/// User-visible regression coverage for large, similarly named custom packs.
///
/// These expectations intentionally describe search outcomes rather than the
/// scorer's numeric weights, so the implementation can evolve without
/// reintroducing the ranking failures seen with All the Bufo.
final class BufoSearchRelevanceTests: XCTestCase {
    func testBufoPrefixTreatsCommonSeparatorsEquivalently() {
        let index = EmojiSearchIndex(items: relevanceCorpus)

        let hyphenated = index.search("bufo-h", limit: 20)
        let underscored = index.search("bufo_h", limit: 20)
        let spaced = index.search("bufo h", limit: 20)

        let expectedPrefixIDs = [
            "bufo-ha-ha",
            "bufo-hat",
            "bufo-hmm",
            "bufo-hug"
        ]
        XCTAssertEqual(
            Array(hyphenated.prefix(expectedPrefixIDs.count).map(\.item.id)),
            expectedPrefixIDs
        )
        XCTAssertEqual(underscored.map(\.item.id), hyphenated.map(\.item.id))
        XCTAssertEqual(spaced.map(\.item.id), hyphenated.map(\.item.id))
        XCTAssertTrue(
            hyphenated.prefix(expectedPrefixIDs.count).allSatisfy {
                $0.matchKind == .tokenPrefix
            }
        )

        let firstLooseMatch = hyphenated.firstIndex { result in
            result.matchKind == .substring || result.matchKind == .fuzzy
        }
        XCTAssertTrue(firstLooseMatch == nil || firstLooseMatch! >= expectedPrefixIDs.count)
    }

    func testRelevantYesResultBeatsFrequentlyUsedEyes() {
        let usage = EmojiUsageSnapshot(
            statisticsByItemID: [
                "eyes": EmojiUsageStatistics(
                    useCount: 10_000,
                    lastUsedAt: Date(timeIntervalSince1970: 100_000)
                )
            ]
        )
        let results = EmojiSearchIndex(items: relevanceCorpus)
            .search("yes", usage: usage, limit: 20)

        XCTAssertEqual(results.first?.item.id, "bufo-yes")
        XCTAssertEqual(results.first?.matchKind, .tokenExact)
        XCTAssertGreaterThan(
            try XCTUnwrap(results.firstIndex { $0.item.id == "eyes" }),
            try XCTUnwrap(results.firstIndex { $0.item.id == "bufo-yes" })
        )
    }

    func testQualifiedBufoYesIsAnExactSeparatorEquivalentMatch() {
        let index = EmojiSearchIndex(items: relevanceCorpus)

        XCTAssertEqual(index.search("bufo yes").first?.item.id, "bufo-yes")
        XCTAssertEqual(index.search("bufo_yes").first?.item.id, "bufo-yes")
        XCTAssertEqual(
            index.search("bufo yes").first?.matchKind,
            .separatorEquivalent
        )
    }

    func testRepresentativeBufoPrefixesPreferLiteralCandidates() {
        let usedNoise = EmojiUsageSnapshot(
            statisticsByItemID: [
                "bufo-laughing-popcorn": EmojiUsageStatistics(
                    useCount: 10_000,
                    lastUsedAt: Date(timeIntervalSince1970: 100_000)
                )
            ]
        )
        let index = EmojiSearchIndex(items: relevanceCorpus)

        XCTAssertEqual(
            index.search("bufo-pr", usage: usedNoise).first?.item.id,
            "bufo-pray"
        )
        XCTAssertEqual(
            index.search("bufo-c", usage: usedNoise).first?.item.id,
            "bufo-cake"
        )
        XCTAssertEqual(index.search("no", usage: usedNoise).first?.item.id, "bufo-no")
    }

    func testHugAndAdjacentTranspositionResolveToBufoHug() {
        let index = EmojiSearchIndex(items: relevanceCorpus)

        let exactToken = index.search("hug", limit: 20)
        XCTAssertEqual(exactToken.first?.item.id, "bufo-hug")
        XCTAssertEqual(exactToken.first?.matchKind, .tokenExact)

        let transposed = index.search("hgu", limit: 20)
        XCTAssertEqual(transposed.first?.item.id, "bufo-hug")
        XCTAssertEqual(transposed.first?.matchKind, .fuzzy)
    }

    func testOneAndTwoCharacterQueriesNeverProduceTypoMatches() {
        let index = EmojiSearchIndex(items: relevanceCorpus)

        for query in ["b", "h", "q", "hg", "xz"] {
            XCTAssertFalse(
                index.search(query, limit: 50).contains { $0.matchKind == .fuzzy },
                "Unexpected typo result for short query \(query)"
            )
        }
    }

    func testFullSourceFilenameKeywordKeepsTruncatedTailSearchable() {
        let tailOnly = CoreTestFixtures.item(
            id: "long-source",
            shortcode: "bufo-rub-hands-with-evil-smile-and-ambition-moves",
            name: "Bufo rub hands with evil smile and ambition moves",
            keywords: [
                "All the Bufo/bufo-rub-hands-with-evil-smile-and-ambition-moves-original-tailtoken.png"
            ]
        )
        let index = EmojiSearchIndex(items: relevanceCorpus + [tailOnly])

        let result = index.search("tailtoken", limit: 20).first

        XCTAssertEqual(result?.item.id, "long-source")
        XCTAssertEqual(result?.matchKind, .tokenExact)
        XCTAssertEqual(result?.matchedTerm, tailOnly.keywords.first)
    }

    func testOrderingDoesNotDependOnCatalogInputOrder() {
        let forward = EmojiSearchIndex(items: relevanceCorpus)
            .search("bufo h", limit: 50)
            .map(\.item.id)
        let reversed = EmojiSearchIndex(items: relevanceCorpus.reversed())
            .search("bufo h", limit: 50)
            .map(\.item.id)
        let rotatedItems = Array(relevanceCorpus.dropFirst(4))
            + Array(relevanceCorpus.prefix(4))
        let rotated = EmojiSearchIndex(items: rotatedItems)
            .search("bufo h", limit: 50)
            .map(\.item.id)

        XCTAssertEqual(reversed, forward)
        XCTAssertEqual(rotated, forward)
    }

    func testLargePackSearchStaysWithinAnInteractiveSafetyBound() {
        let largeCatalog = (0 ..< 4_000).map { index in
            CoreTestFixtures.item(
                id: String(format: "bulk-%04d", index),
                shortcode: String(format: "bufo-variant-%04d", index)
            )
        } + relevanceCorpus
        let index = EmojiSearchIndex(items: largeCatalog)

        // Warm caches and one-time runtime work before timing the hot path.
        XCTAssertFalse(index.search("bufo hug", limit: 20).isEmpty)

        let clock = ContinuousClock()
        let elapsed = clock.measure {
            for query in ["b", "bu", "buf", "bufo", "bufo h", "hgu"] {
                _ = index.search(query, limit: 20)
            }
        }

        XCTAssertLessThan(
            elapsed,
            .milliseconds(1_500),
            "Six interactive searches across a 4,000-item pack took \(elapsed)"
        )
    }

    private var relevanceCorpus: [EmojiItem] {
        [
            CoreTestFixtures.item(id: "wave", shortcode: "wave", name: "Waving hand"),
            CoreTestFixtures.item(id: "eyes", shortcode: "eyes", name: "Eyes"),
            CoreTestFixtures.item(id: "hugging-face", shortcode: "hugging-face", name: "Hugging face"),
            CoreTestFixtures.item(id: "bufo-ha-ha", shortcode: "bufo-ha-ha", order: 489),
            CoreTestFixtures.item(id: "bufo-hat", shortcode: "bufo-hat", order: 531),
            CoreTestFixtures.item(id: "bufo-hmm", shortcode: "bufo-hmm", order: 552),
            CoreTestFixtures.item(id: "bufo-hug", shortcode: "bufo-hug", order: 565),
            CoreTestFixtures.item(id: "bufo-high-five", shortcode: "bufo-high-five", order: 557),
            CoreTestFixtures.item(id: "bufo-yes", shortcode: "bufo-yes", order: 20),
            CoreTestFixtures.item(id: "bufo-no", shortcode: "bufo-no", order: 21),
            CoreTestFixtures.item(id: "bufo-pray", shortcode: "bufo-pray", order: 22),
            CoreTestFixtures.item(id: "bufo-cake", shortcode: "bufo-cake", order: 23),
            CoreTestFixtures.item(id: "bufo-bright", shortcode: "bufo-bright", order: 30),
            CoreTestFixtures.item(id: "bufo-laugh-xd", shortcode: "bufo-laugh-xd", order: 31),
            CoreTestFixtures.item(
                id: "bufo-laughing-popcorn",
                shortcode: "bufo-laughing-popcorn",
                order: 32
            )
        ]
    }
}
