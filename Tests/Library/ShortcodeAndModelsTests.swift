import Foundation
import XCTest
@testable import MojiPond

final class ShortcodeAndModelsTests: XCTestCase {
    func testStrictShortcodeValidation() throws {
        XCTAssertNotNil(Shortcode(rawValue: "frog"))
        XCTAssertNotNil(Shortcode(rawValue: "frog_party+1"))
        XCTAssertNotNil(Shortcode(rawValue: String(repeating: "a", count: 64)))

        XCTAssertNil(Shortcode(rawValue: ""))
        XCTAssertNil(Shortcode(rawValue: "_frog"))
        XCTAssertNil(Shortcode(rawValue: "Frog"))
        XCTAssertNil(Shortcode(rawValue: "frog party"))
        XCTAssertNil(Shortcode(rawValue: String(repeating: "a", count: 65)))
    }

    func testShortcodeNormalizationIsDeterministic() throws {
        XCTAssertEqual(
            try Shortcode(normalizing: ":Party Parrot:").rawValue,
            "party_parrot"
        )
        XCTAssertEqual(
            try Shortcode(normalizing: "  Crème brûlée!! ").rawValue,
            "creme_brulee"
        )
        XCTAssertEqual(try Shortcode(normalizing: "+1").rawValue, "1")
        XCTAssertThrowsError(try Shortcode(normalizing: "🐸"))
    }

    func testShortcodeCodableUsesSingleValidatedString() throws {
        let shortcode = try Shortcode(validating: "bufo_wave")
        let data = try JSONEncoder().encode(shortcode)
        XCTAssertEqual(String(decoding: data, as: UTF8.self), "\"bufo_wave\"")
        XCTAssertEqual(try JSONDecoder().decode(Shortcode.self, from: data), shortcode)
        XCTAssertThrowsError(
            try JSONDecoder().decode(Shortcode.self, from: Data("\"BAD VALUE\"".utf8))
        )
    }

    func testContentHasherProducesKnownSHA256() throws {
        let digest = ContentHasher.sha256(of: Data("abc".utf8))
        XCTAssertEqual(
            digest.sha256,
            "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad"
        )
        XCTAssertEqual(digest.byteCount, 3)
    }

    func testFileHasherRejectsSymlinkAndByteLimit() throws {
        let root = try TestSupport.makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("data")
        try Data("hello".utf8).write(to: file)
        let link = root.appendingPathComponent("link")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: file)

        XCTAssertEqual(try ContentHasher.sha256(ofFileAt: file).byteCount, 5)
        XCTAssertThrowsError(try ContentHasher.sha256(ofFileAt: file, maximumBytes: 4)) {
            XCTAssertEqual(
                $0 as? ContentHashError,
                .tooLarge(actual: 5, limit: 4)
            )
        }
        XCTAssertThrowsError(try ContentHasher.sha256(ofFileAt: link)) {
            XCTAssertEqual($0 as? ContentHashError, .notARegularFile(link))
        }
    }

    func testLibrarySchemaAndPathValidation() throws {
        let shortcode = try Shortcode(validating: "frog")
        let asset = StoredAsset(
            relativePath: "assets/123/frog.png",
            format: .png,
            sha256: String(repeating: "a", count: 64),
            byteCount: 123,
            pixelWidth: 2,
            pixelHeight: 2,
            frameCount: 1
        )
        let pack = EmojiPack(
            name: "Frogs",
            source: PackSource(kind: .folder),
            items: [
                LibraryEmoji(shortcode: shortcode, payload: .asset(asset))
            ]
        )
        let library = MojiPondLibrary(packs: [pack])
        XCTAssertNoThrow(try library.validated())

        var unsupported = library
        unsupported.schemaVersion = 99
        XCTAssertThrowsError(try unsupported.validated()) {
            XCTAssertEqual($0 as? LibraryModelError, .unsupportedSchemaVersion(99))
        }

        XCTAssertFalse(StoredAsset.isSafeRelativePath("../outside.png"))
        XCTAssertFalse(StoredAsset.isSafeRelativePath("/absolute.png"))
        XCTAssertFalse(StoredAsset.isSafeRelativePath("assets\\frog.png"))
        XCTAssertTrue(StoredAsset.isSafeRelativePath("assets/pack/frog.png"))
    }
}
