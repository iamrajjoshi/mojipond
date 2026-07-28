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
        XCTAssertEqual(result.acceptedFileCount, 1)
        XCTAssertEqual(
            result.preparedPack.manifest.packID.rawValue,
            "knobiknows.all-the-bufo"
        )
        XCTAssertEqual(result.preparedPack.manifest.version, "2026.7.1")
        XCTAssertEqual(result.preparedPack.items[0].aliases.map(\.rawValue), ["frog_wave"])
        XCTAssertEqual(result.preparedPack.items[0].tags, ["frog", "hello"])
        XCTAssertEqual(result.preparedPack.items[0].category, "Bufo")
        XCTAssertEqual(result.preparedPack.items[0].order, 7)
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

    func testPackIdentifierIsPortableAndStrict() throws {
        XCTAssertNotNil(PackIdentifier(rawValue: "com.example.frogs-v2"))
        XCTAssertNil(PackIdentifier(rawValue: "Com.Example"))
        XCTAssertNil(PackIdentifier(rawValue: ".hidden"))
        XCTAssertNil(PackIdentifier(rawValue: "example..frogs"))
        XCTAssertNil(PackIdentifier(rawValue: "../frogs"))
    }
}
