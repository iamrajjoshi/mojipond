import XCTest
@testable import MojiPond

final class GemojiDatasetTests: XCTestCase {
    func testPinnedBundledDatasetMapsAllRecordsToUniqueSearchItems() throws {
        let url = try XCTUnwrap(
            Bundle.main.url(forResource: "gemoji", withExtension: "json")
        )
        let pack = try GemojiDatasetDecoder().decode(Data(contentsOf: url))

        XCTAssertEqual(pack.items.count, 1_870)
        XCTAssertEqual(Set(pack.items.map(\.id)).count, pack.items.count)
        XCTAssertEqual(pack.version, GemojiDatasetDecoder.defaultRevision)
        XCTAssertNotNil(pack.items.first(where: { $0.shortcode.rawValue == "wave" }))
        XCTAssertTrue(
            pack.items.contains {
                $0.shortcode.rawValue == "thumbsup" && $0.aliases.contains("+1")
            }
        )
    }

    func testDecoderMapsAliasesMetadataAndSkinToneVariants() throws {
        let json = """
        [
          {
            "emoji": "👋",
            "description": "waving hand",
            "category": "People & Body",
            "aliases": ["wave"],
            "tags": ["goodbye"],
            "unicode_version": "6.0",
            "ios_version": "6.0",
            "skin_tones": true
          },
          {
            "emoji": "👍",
            "description": "thumbs up",
            "category": "People & Body",
            "aliases": ["+1", "thumbsup"],
            "tags": ["approve"],
            "unicode_version": "6.0",
            "skin_tones": true
          }
        ]
        """

        let pack = try GemojiDatasetDecoder(
            packPriority: 12,
            revision: "fixture-revision"
        ).decode(Data(json.utf8))

        XCTAssertEqual(pack.id, "builtin.gemoji")
        XCTAssertEqual(pack.priority, 12)
        XCTAssertEqual(pack.version, "fixture-revision")
        XCTAssertEqual(pack.items.count, 2)

        let wave = try XCTUnwrap(pack.items.first)
        XCTAssertEqual(wave.shortcode.rawValue, "wave")
        XCTAssertEqual(wave.keywords, ["goodbye"])
        XCTAssertEqual(wave.category, "People & Body")
        XCTAssertEqual(wave.packPriority, 12)
        guard case let .unicode(content) = wave.content else {
            return XCTFail("Expected Unicode content")
        }
        XCTAssertEqual(content.unicodeVersion, "6.0")
        XCTAssertEqual(content.skinToneVariants.count, EmojiSkinTone.allCases.count)
        XCTAssertEqual(content.value(for: .medium), "👋🏽")

        let thumbsup = pack.items[1]
        XCTAssertEqual(thumbsup.shortcode.rawValue, "thumbsup")
        XCTAssertEqual(thumbsup.aliases, ["+1"])
    }

    func testSkinToneInsertionPreservesZWJSequence() throws {
        let json = """
        [{
          "emoji": "🧑‍🦽",
          "description": "person in manual wheelchair",
          "category": "People & Body",
          "aliases": ["person_in_manual_wheelchair"],
          "tags": [],
          "unicode_version": "12.0",
          "skin_tones": true
        }]
        """

        let pack = try GemojiDatasetDecoder().decode(Data(json.utf8))
        guard case let .unicode(content) = try XCTUnwrap(pack.items.first).content else {
            return XCTFail("Expected Unicode content")
        }

        XCTAssertEqual(content.value(for: .medium), "🧑🏽‍🦽")
    }

    func testDecoderRejectsRecordWithoutCanonicalAlias() {
        let json = """
        [{
          "emoji": "👍",
          "description": "thumbs up",
          "category": "People & Body",
          "aliases": ["+1"],
          "tags": []
        }]
        """

        XCTAssertThrowsError(try GemojiDatasetDecoder().decode(Data(json.utf8))) { error in
            XCTAssertEqual(error as? GemojiDatasetError, .missingUsableAlias(record: 0))
        }
    }

    func testDecoderRejectsDuplicateStableIdentifiers() {
        let json = """
        [
          {
            "emoji": "😀",
            "description": "one",
            "category": "Smileys",
            "aliases": ["same"],
            "tags": []
          },
          {
            "emoji": "😃",
            "description": "two",
            "category": "Smileys",
            "aliases": ["same"],
            "tags": []
          }
        ]
        """

        XCTAssertThrowsError(try GemojiDatasetDecoder().decode(Data(json.utf8))) { error in
            XCTAssertEqual(
                error as? GemojiDatasetError,
                .duplicateIdentifier("builtin.gemoji.same")
            )
        }
    }
}
