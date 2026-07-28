import Foundation
import UniformTypeIdentifiers
import XCTest
@testable import MojiPond

final class ImportScannerAndCollisionTests: XCTestCase {
    func testScansIndividualFilesAndReportsInvalidInputs() throws {
        let root = try TestSupport.makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }

        let frog = try TestSupport.writeImage(
            to: root.appendingPathComponent("Party Frog.png")
        )
        let unsupported = root.appendingPathComponent("notes.txt")
        try Data("hello".utf8).write(to: unsupported)
        let invalid = root.appendingPathComponent("broken.gif")
        try Data("GIF89a".utf8).write(to: invalid)

        let result = try ImportScanner().scanFiles(
            [frog, unsupported, invalid],
            packName: "My Pond"
        )
        XCTAssertEqual(result.acceptedFileCount, 1)
        XCTAssertEqual(result.preparedPack.items[0].shortcode.rawValue, "party_frog")
        XCTAssertEqual(result.rejections.count, 2)
        XCTAssertEqual(result.preparedPack.source.kind, .individualFiles)
    }

    func testScansFolderRecursivelyWithoutFollowingSymlinks() throws {
        let root = try TestSupport.makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let nested = root.appendingPathComponent("nested", isDirectory: true)
        try FileManager.default.createDirectory(at: nested, withIntermediateDirectories: false)
        _ = try TestSupport.writeImage(to: nested.appendingPathComponent("bufo-wave.png"))
        try Data("license".utf8).write(to: root.appendingPathComponent("LICENSE"))
        let link = root.appendingPathComponent("linked.png")
        try FileManager.default.createSymbolicLink(
            at: link,
            withDestinationURL: nested.appendingPathComponent("bufo-wave.png")
        )

        let result = try ImportScanner().scanFolder(at: root, packName: "Bufo")
        XCTAssertEqual(result.acceptedFileCount, 1)
        XCTAssertEqual(result.preparedPack.items[0].shortcode.rawValue, "bufo-wave")
        XCTAssertEqual(result.ignoredFileCount, 1)
        XCTAssertEqual(result.rejections.count, 1)
        XCTAssertEqual(result.preparedPack.source.kind, .folder)
    }

    func testScannerEnforcesTotalByteAndEntryLimits() throws {
        let root = try TestSupport.makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let first = try TestSupport.writeImage(to: root.appendingPathComponent("one.png"))
        let second = try TestSupport.writeImage(to: root.appendingPathComponent("two.png"))

        var entryLimits = ImportScanLimits.default
        entryLimits.maximumFileCount = 1
        XCTAssertThrowsError(
            try ImportScanner(limits: entryLimits).scanFiles(
                [first, second],
                packName: "Too many"
            )
        )

        var byteLimits = ImportScanLimits.default
        byteLimits.maximumTotalInputBytes = 1
        XCTAssertThrowsError(
            try ImportScanner(limits: byteLimits).scanFiles(
                [first],
                packName: "Too large"
            )
        ) {
            XCTAssertEqual(
                $0 as? ImportScanError,
                .totalBytesExceeded(limit: 1)
            )
        }
    }

    func testZIPImportUsesPreflightExtractionThenFolderValidation() throws {
        let root = try TestSupport.makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let source = try TestSupport.writeImage(
            to: root.appendingPathComponent("source.png")
        )
        let archiveURL = root.appendingPathComponent("frogs.zip")
        try TestZipBuilder.archive(
            entries: [
                .init(path: "bundle/", data: Data(), unixMode: 0o040700),
                .init(path: "bundle/frog.png", data: try Data(contentsOf: source))
            ]
        ).write(to: archiveURL)
        let destination = root.appendingPathComponent("expanded", isDirectory: true)

        let result = try ImportScanner().scanZIPArchive(
            at: archiveURL,
            extractingTo: destination,
            packName: "ZIP Frogs"
        )
        XCTAssertEqual(result.acceptedFileCount, 1)
        XCTAssertEqual(result.preparedPack.items[0].shortcode.rawValue, "frog")
        XCTAssertEqual(result.preparedPack.source.kind, .zipArchive)
        XCTAssertEqual(result.preparedPack.source.displayLocation, "frogs.zip")
    }

    func testCollisionPreviewAndRenameResolution() throws {
        let root = try TestSupport.makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let source = try TestSupport.writeImage(to: root.appendingPathComponent("frog.png"))
        let scan = try ImportScanner().scanFiles([source], packName: "Incoming")
        let existingItem = LibraryEmoji(
            shortcode: try Shortcode(validating: "frog"),
            payload: .unicode("🐸")
        )
        let existingPack = EmojiPack(
            name: "Existing",
            source: PackSource(kind: .builtIn),
            items: [existingItem]
        )
        let library = MojiPondLibrary(packs: [existingPack])

        let preview = ImportCollisionAnalyzer.makePreview(
            scanResult: scan,
            library: library
        )
        XCTAssertEqual(preview.collisions.count, 1)
        XCTAssertTrue(preview.requiresDecisions)

        let renamed = try Shortcode(validating: "frog_custom")
        let resolved = try ImportCollisionAnalyzer.resolve(
            preview: preview,
            decisions: [
                preview.collisions[0].id: .renameIncomingClaim(renamed)
            ],
            library: library
        )
        XCTAssertEqual(resolved.pack.items[0].shortcode, renamed)
        XCTAssertTrue(resolved.existingItemIDsToReplace.isEmpty)
    }

    func testCollisionReplacementAndWithinImportSkip() throws {
        let root = try TestSupport.makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let png = try TestSupport.writeImage(to: root.appendingPathComponent("Party Frog.png"))
        let gif = try TestSupport.writeImage(
            to: root.appendingPathComponent("party_frog.gif"),
            format: .gif
        )
        let scan = try ImportScanner().scanFiles([png, gif], packName: "Incoming")
        let existingItem = LibraryEmoji(
            shortcode: try Shortcode(validating: "party_frog"),
            payload: .unicode("🐸")
        )
        let existingPack = EmojiPack(
            name: "Existing",
            source: PackSource(kind: .builtIn),
            items: [existingItem]
        )
        let library = MojiPondLibrary(packs: [existingPack])
        let preview = ImportCollisionAnalyzer.makePreview(
            scanResult: scan,
            library: library
        )
        XCTAssertEqual(preview.collisions.count, 3)

        var decisions: [UUID: CollisionDecision] = [:]
        for collision in preview.collisions {
            switch collision.existing {
            case .library:
                decisions[collision.id] = .replaceExistingItem
            case .incoming:
                decisions[collision.id] = .skipIncomingItem
            }
        }
        let resolved = try ImportCollisionAnalyzer.resolve(
            preview: preview,
            decisions: decisions,
            library: library
        )
        XCTAssertEqual(resolved.pack.items.count, 1)
        XCTAssertEqual(resolved.existingItemIDsToReplace, [existingItem.id])
    }

    func testResolutionRequiresEveryDecisionAndRejectsRemainingCollision() throws {
        let root = try TestSupport.makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let source = try TestSupport.writeImage(to: root.appendingPathComponent("frog.png"))
        let scan = try ImportScanner().scanFiles([source], packName: "Incoming")
        let existing = MojiPondLibrary(
            packs: [
                EmojiPack(
                    name: "Existing",
                    source: PackSource(kind: .builtIn),
                    items: [
                        LibraryEmoji(
                            shortcode: try Shortcode(validating: "frog"),
                            payload: .unicode("🐸")
                        )
                    ]
                )
            ]
        )
        let preview = ImportCollisionAnalyzer.makePreview(scanResult: scan, library: existing)

        XCTAssertThrowsError(
            try ImportCollisionAnalyzer.resolve(
                preview: preview,
                decisions: [:],
                library: existing
            )
        )
        XCTAssertThrowsError(
            try ImportCollisionAnalyzer.resolve(
                preview: preview,
                decisions: [
                    preview.collisions[0].id:
                        .renameIncomingClaim(try Shortcode(validating: "frog"))
                ],
                library: existing
            )
        ) {
            XCTAssertEqual(
                $0 as? CollisionResolutionError,
                .unresolved(try! Shortcode(validating: "frog"))
            )
        }
    }
}
