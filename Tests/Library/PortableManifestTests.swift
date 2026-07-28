import Foundation
import XCTest
@testable import MojiPond

final class PortableManifestTests: XCTestCase {
    func testPortableManifestRoundTripsAndDrivesFolderImport() throws {
        let root = try TestSupport.makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let assets = root.appendingPathComponent("emoji", isDirectory: true)
        try FileManager.default.createDirectory(at: assets, withIntermediateDirectories: false)
        _ = try TestSupport.writeImage(
            to: assets.appendingPathComponent("wave.png")
        )

        let manifest = PortablePackManifest(
            id: try PackIdentifier(validating: "knobiknows.all-the-bufo"),
            name: "All the Bufo",
            version: "2026.7.1",
            author: "knobiknows",
            description: "A carefully curated frog pond.",
            sourceURL: URL(string: "https://github.com/knobiknows/all-the-bufo"),
            license: "CC-BY-4.0",
            emoji: [
                PortablePackEmoji(
                    shortcode: try Shortcode(validating: "bufo_wave"),
                    aliases: [try Shortcode(validating: "frog_wave")],
                    displayName: "Bufo wave",
                    tags: ["frog", "hello"],
                    category: "Bufo",
                    order: 7,
                    file: "emoji/wave.png"
                ),
                PortablePackEmoji(
                    shortcode: try Shortcode(validating: "pond_coder"),
                    displayName: "Pond coder",
                    tags: ["unicode", "work"],
                    category: "People",
                    order: 8,
                    unicode: "👨🏽‍💻"
                )
            ]
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let encoded = try encoder.encode(manifest)
        try encoded.write(
            to: root.appendingPathComponent(MojiPondLibrary.manifestFilename)
        )

        XCTAssertEqual(try PortablePackManifest.decode(encoded), manifest)
        let result = try ImportScanner().scanFolder(at: root)
        XCTAssertEqual(result.acceptedFileCount, 2)
        XCTAssertEqual(
            result.preparedPack.manifest.packID.rawValue,
            "knobiknows.all-the-bufo"
        )
        XCTAssertEqual(result.preparedPack.manifest.version, "2026.7.1")
        XCTAssertEqual(result.preparedPack.items[0].aliases.map(\.rawValue), ["frog_wave"])
        XCTAssertEqual(result.preparedPack.items[0].tags, ["frog", "hello"])
        XCTAssertEqual(result.preparedPack.items[0].category, "Bufo")
        XCTAssertEqual(result.preparedPack.items[0].order, 7)
        XCTAssertEqual(result.preparedPack.items[1].unicode, "👨🏽‍💻")
        XCTAssertNil(result.preparedPack.items[1].asset)
        XCTAssertEqual(result.preparedPack.items[1].order, 8)
    }

    func testPortableManifestRejectsTraversalDuplicatesAndUnsupportedSchema() throws {
        let base = """
        {
          "schemaVersion": 1,
          "id": "example.frogs",
          "name": "Frogs",
          "version": "1.0.0",
          "emoji": [
            {"shortcode": "frog", "file": "../outside.png"}
          ]
        }
        """
        XCTAssertThrowsError(
            try PortablePackManifest.decode(Data(base.utf8))
        ) {
            XCTAssertEqual(
                $0 as? PortablePackManifestError,
                .unsafeAssetPath("../outside.png")
            )
        }

        let duplicate = """
        {
          "schemaVersion": 1,
          "id": "example.frogs",
          "name": "Frogs",
          "version": "1.0.0",
          "emoji": [
            {"shortcode": "frog", "file": "one.png"},
            {"shortcode": "frog", "file": "two.png"}
          ]
        }
        """
        XCTAssertThrowsError(
            try PortablePackManifest.decode(Data(duplicate.utf8))
        ) {
            XCTAssertEqual(
                $0 as? PortablePackManifestError,
                .duplicateShortcode(try! Shortcode(validating: "frog"))
            )
        }

        let unsupported = base.replacingOccurrences(
            of: "\"schemaVersion\": 1",
            with: "\"schemaVersion\": 999"
        )
        XCTAssertThrowsError(
            try PortablePackManifest.decode(Data(unsupported.utf8))
        ) {
            XCTAssertEqual(
                $0 as? PortablePackManifestError,
                .unsupportedSchemaVersion(999)
            )
        }
    }

    func testVersion1FileManifestRemainsCompatible() throws {
        let manifest = """
        {
          "schemaVersion": 1,
          "id": "example.legacy",
          "name": "Legacy",
          "version": "1.0.0",
          "emoji": [
            {"shortcode": "frog", "file": "frog.png"}
          ]
        }
        """

        let decoded = try PortablePackManifest.decode(Data(manifest.utf8))

        XCTAssertEqual(decoded.schemaVersion, 1)
        XCTAssertEqual(decoded.emoji[0].file, "frog.png")
        XCTAssertNil(decoded.emoji[0].unicode)
    }

    func testPortableManifestRequiresExactlyOneValidContentField() throws {
        let neither = """
        {
          "schemaVersion": 2,
          "id": "example.invalid",
          "name": "Invalid",
          "version": "1.0.0",
          "emoji": [{"shortcode": "frog"}]
        }
        """
        XCTAssertThrowsError(
            try PortablePackManifest.decode(Data(neither.utf8))
        ) {
            XCTAssertEqual(
                $0 as? PortablePackManifestError,
                .missingEmojiContent(
                    try! Shortcode(validating: "frog")
                )
            )
        }

        let both = """
        {
          "schemaVersion": 2,
          "id": "example.invalid",
          "name": "Invalid",
          "version": "1.0.0",
          "emoji": [
            {
              "shortcode": "frog",
              "file": "frog.png",
              "unicode": "🐸"
            }
          ]
        }
        """
        XCTAssertThrowsError(
            try PortablePackManifest.decode(Data(both.utf8))
        ) {
            XCTAssertEqual(
                $0 as? PortablePackManifestError,
                .conflictingEmojiContent(
                    try! Shortcode(validating: "frog")
                )
            )
        }

        let plainText = """
        {
          "schemaVersion": 2,
          "id": "example.invalid",
          "name": "Invalid",
          "version": "1.0.0",
          "emoji": [
            {"shortcode": "frog", "unicode": "frog"}
          ]
        }
        """
        XCTAssertThrowsError(
            try PortablePackManifest.decode(Data(plainText.utf8))
        ) {
            guard case let .invalidUnicode(shortcode, reason) =
                $0 as? PortablePackManifestError else {
                return XCTFail("Expected Unicode rejection, got \($0)")
            }
            XCTAssertEqual(shortcode.rawValue, "frog")
            XCTAssertTrue(reason.contains("exactly one emoji"))
        }

        let v1Unicode = """
        {
          "schemaVersion": 1,
          "id": "example.invalid",
          "name": "Invalid",
          "version": "1.0.0",
          "emoji": [
            {"shortcode": "frog", "unicode": "🐸"}
          ]
        }
        """
        XCTAssertThrowsError(
            try PortablePackManifest.decode(Data(v1Unicode.utf8))
        ) {
            XCTAssertEqual(
                $0 as? PortablePackManifestError,
                .unicodeRequiresSchemaVersion2(
                    try! Shortcode(validating: "frog")
                )
            )
        }
    }

    func testUnicodeEmojiValidationAllowsSequencesAndRejectsUnsafeText() {
        XCTAssertNoThrow(
            try UnicodeEmojiValueValidator.validate("👨🏽‍💻")
        )
        XCTAssertNoThrow(
            try UnicodeEmojiValueValidator.validate("🇨🇦")
        )
        XCTAssertNoThrow(
            try UnicodeEmojiValueValidator.validate("1️⃣")
        )
        XCTAssertThrowsError(
            try UnicodeEmojiValueValidator.validate("\u{0000}")
        ) {
            XCTAssertEqual(
                $0 as? UnicodeEmojiValidationError,
                .unsafeScalar
            )
        }
        XCTAssertThrowsError(
            try UnicodeEmojiValueValidator.validate(":frog:")
        ) {
            XCTAssertEqual(
                $0 as? UnicodeEmojiValidationError,
                .mustBeSingleEmoji
            )
        }
    }

    func testPortableManifestRejectsIntermediateDirectorySymlink() throws {
        let root = try TestSupport.makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let pack = root.appendingPathComponent("pack", isDirectory: true)
        let outside = root.appendingPathComponent("outside", isDirectory: true)
        try FileManager.default.createDirectory(
            at: pack,
            withIntermediateDirectories: false
        )
        try FileManager.default.createDirectory(
            at: outside,
            withIntermediateDirectories: false
        )
        _ = try TestSupport.writeImage(
            to: outside.appendingPathComponent("wave.png")
        )
        try FileManager.default.createSymbolicLink(
            at: pack.appendingPathComponent("emoji", isDirectory: true),
            withDestinationURL: outside
        )

        let manifest = PortablePackManifest(
            id: try PackIdentifier(validating: "example.symlink"),
            name: "Escaped Pond",
            version: "1.0.0",
            emoji: [
                PortablePackEmoji(
                    shortcode: try Shortcode(validating: "wave"),
                    file: "emoji/wave.png"
                )
            ]
        )
        try JSONEncoder().encode(manifest).write(
            to: pack.appendingPathComponent(
                MojiPondLibrary.manifestFilename
            )
        )

        XCTAssertThrowsError(try ImportScanner().scanFolder(at: pack)) {
            guard case let .assetRejected(path, reason) =
                $0 as? PortablePackManifestError else {
                return XCTFail("Expected symlink rejection, got \($0)")
            }
            XCTAssertEqual(path, "emoji/wave.png")
            XCTAssertTrue(reason.contains("Symbolic links"))
        }
    }

    func testPackIdentifierIsPortableAndStrict() throws {
        XCTAssertNotNil(PackIdentifier(rawValue: "com.example.frogs-v2"))
        XCTAssertNil(PackIdentifier(rawValue: "Com.Example"))
        XCTAssertNil(PackIdentifier(rawValue: ".hidden"))
        XCTAssertNil(PackIdentifier(rawValue: "example..frogs"))
        XCTAssertNil(PackIdentifier(rawValue: "../frogs"))
    }
}
