import XCTest
@testable import MojiPond

final class LibrarySearchAdapterTests: XCTestCase {
    func testAdapterFiltersDisabledPacksAndPreservesUnicodeMetadataAndOrder() throws {
        let firstID = UUID(uuidString: "AAAAAAAA-AAAA-AAAA-AAAA-AAAAAAAAAAAA")!
        let secondID = UUID(uuidString: "BBBBBBBB-BBBB-BBBB-BBBB-BBBBBBBBBBBB")!
        let packID = UUID(uuidString: "CCCCCCCC-CCCC-CCCC-CCCC-CCCCCCCCCCCC")!
        let enabled = EmojiPack(
            id: packID,
            name: "Favorites",
            source: PackSource(kind: .folder, displayLocation: "/fixture"),
            items: [
                LibraryEmoji(
                    id: firstID,
                    shortcode: try Shortcode(validating: "wave"),
                    aliases: [try Shortcode(validating: "hello")],
                    displayName: "Waving hand",
                    payload: .unicode("👋")
                ),
                LibraryEmoji(
                    id: secondID,
                    shortcode: try Shortcode(validating: "lizard"),
                    payload: .unicode("🦎")
                )
            ]
        )
        let disabled = EmojiPack(
            name: "Disabled",
            isEnabled: false,
            source: PackSource(kind: .folder),
            items: []
        )

        let catalog = try EmojiLibrarySearchAdapter.catalog(
            from: [disabled, enabled],
            priorityByPackID: [packID: 9]
        )

        XCTAssertEqual(catalog.count, 1)
        XCTAssertEqual(catalog[0].id, packID.uuidString)
        XCTAssertEqual(catalog[0].priority, 9)
        XCTAssertEqual(catalog[0].items.map(\.id), [firstID.uuidString, secondID.uuidString])
        XCTAssertEqual(catalog[0].items.map(\.order), [0, 1])
        XCTAssertEqual(catalog[0].items[0].aliases, ["hello"])
        XCTAssertEqual(catalog[0].items[0].name, "Waving hand")
        XCTAssertEqual(catalog[0].items[0].packPriority, 9)
        guard case let .unicode(content) = catalog[0].items[0].content else {
            return XCTFail("Expected Unicode content")
        }
        XCTAssertEqual(content.value, "👋")
    }

    func testAdapterPreservesManagedMediaPathDigestDimensionsAndAnimation() throws {
        let digest = String(repeating: "a", count: 64)
        let libraryItem = LibraryEmoji(
            shortcode: try Shortcode(validating: "bufo_dance"),
            displayName: "Bufo dance",
            sourceFilename: "dance.gif",
            payload: .asset(
                StoredAsset(
                    relativePath: "packs/bufo/dance.gif",
                    format: .gif,
                    sha256: digest,
                    byteCount: 456,
                    pixelWidth: 128,
                    pixelHeight: 96,
                    frameCount: 12
                )
            )
        )
        let pack = EmojiPack(
            name: "Bufo",
            source: PackSource(
                kind: .github,
                github: GitHubPackSource(
                    owner: "knobiknows",
                    repository: "all-the-bufo",
                    ref: "main",
                    subdirectory: "emojis"
                )
            ),
            items: [libraryItem]
        )

        let catalog = try EmojiLibrarySearchAdapter.catalogPack(from: pack, priority: 4)
        guard case let .media(media) = try XCTUnwrap(catalog.items.first).content else {
            return XCTFail("Expected media content")
        }

        XCTAssertEqual(media.relativePath, "packs/bufo/dance.gif")
        XCTAssertEqual(media.originalFilename, "dance.gif")
        XCTAssertEqual(media.contentHash, digest)
        XCTAssertEqual(media.dimensions, MediaDimensions(width: 128, height: 96))
        XCTAssertEqual(media.mediaType, .gif)
        XCTAssertTrue(media.isAnimated)
        XCTAssertEqual(
            catalog.source,
            .github(
                owner: "knobiknows",
                repository: "all-the-bufo",
                revision: "main",
                subdirectory: "emojis"
            )
        )
    }

    func testAdapterRejectsMalformedPayloadInsteadOfOpeningAnAsset() {
        let itemID = UUID()
        let item = LibraryEmoji(
            id: itemID,
            shortcode: try! Shortcode(validating: "broken"),
            payload: EmojiPayload(kind: .asset, unicode: nil, asset: nil)
        )
        let pack = EmojiPack(
            name: "Broken",
            source: PackSource(kind: .folder),
            items: [item]
        )

        XCTAssertThrowsError(
            try EmojiLibrarySearchAdapter.catalogPack(from: pack, priority: 0)
        ) { error in
            XCTAssertEqual(error as? LibrarySearchAdapterError, .missingAsset(itemID: itemID))
        }
    }
}
