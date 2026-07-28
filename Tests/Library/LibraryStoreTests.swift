import Foundation
import XCTest
@testable import MojiPond

@MainActor
final class LibraryStoreTests: XCTestCase {
    func testPersistsInstallsReordersUpdatesAndRemovesPacks() async throws {
        let workspace = try TestSupport.makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: workspace) }
        let libraryRoot = workspace.appendingPathComponent("Library", isDirectory: true)
        let sources = workspace.appendingPathComponent("Sources", isDirectory: true)
        try FileManager.default.createDirectory(at: sources, withIntermediateDirectories: false)
        let frog = try TestSupport.writeImage(to: sources.appendingPathComponent("frog.png"))
        let toad = try TestSupport.writeImage(to: sources.appendingPathComponent("toad.png"))
        let store = LibraryStore(rootURL: libraryRoot)

        let initial = try await store.snapshot()
        XCTAssertEqual(initial.schemaVersion, MojiPondLibrary.currentSchemaVersion)
        XCTAssertTrue(
            FileManager.default.fileExists(
                atPath: libraryRoot.appendingPathComponent("mojipond.json").path
            )
        )

        let first = try await install(
            files: [frog],
            packName: "Frogs",
            into: store
        )
        let firstAsset = try XCTUnwrap(first.items[0].payload.asset)
        let firstAssetURL = try await store.assetURL(for: firstAsset)
        XCTAssertTrue(FileManager.default.fileExists(atPath: firstAssetURL.path))
        XCTAssertEqual(first.priority, 0)
        XCTAssertEqual(first.items[0].order, 0)

        let second = try await install(
            files: [toad],
            packName: "Toads",
            into: store
        )
        XCTAssertEqual(second.priority, 1)
        try await store.movePack(second.id, to: 0)
        try await store.setPackEnabled(first.id, isEnabled: false)

        var metadata = second.updateMetadata
        metadata.lastCheckedAt = Date(timeIntervalSince1970: 1_000)
        metadata.sourceRevision = "v2"
        metadata.sourceETag = "\"etag\""
        try await store.setPackUpdateMetadata(second.id, metadata: metadata)
        var manifest = second.manifest
        manifest.version = "2.0.0"
        manifest.author = "Raj"
        manifest.description = "Toads from the pond."
        manifest.license = "CC-BY-4.0"
        try await store.setPackManifestMetadata(second.id, metadata: manifest)

        let reordered = try await store.snapshot()
        XCTAssertEqual(reordered.packs.map(\.id), [second.id, first.id])
        XCTAssertEqual(reordered.packs.map(\.priority), [0, 1])
        XCTAssertFalse(try XCTUnwrap(reordered.packs.first(where: { $0.id == first.id })).isEnabled)
        XCTAssertEqual(
            try XCTUnwrap(reordered.packs.first(where: { $0.id == second.id }))
                .updateMetadata.sourceRevision,
            "v2"
        )
        XCTAssertEqual(
            try XCTUnwrap(reordered.packs.first(where: { $0.id == second.id }))
                .manifest.version,
            "2.0.0"
        )

        try await store.removePack(first.id)
        XCTAssertFalse(FileManager.default.fileExists(atPath: firstAssetURL.path))
        let afterRemoval = try await store.snapshot()
        XCTAssertEqual(afterRemoval.packs.map(\.id), [second.id])

        let reloaded = LibraryStore(rootURL: libraryRoot)
        let reloadedSnapshot = try await reloaded.snapshot()
        XCTAssertEqual(reloadedSnapshot.packs.map(\.id), [second.id])
    }

    func testCollisionReplacementCleansOldAsset() async throws {
        let workspace = try TestSupport.makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: workspace) }
        let firstSources = workspace.appendingPathComponent("First", isDirectory: true)
        let secondSources = workspace.appendingPathComponent("Second", isDirectory: true)
        try FileManager.default.createDirectory(at: firstSources, withIntermediateDirectories: false)
        try FileManager.default.createDirectory(at: secondSources, withIntermediateDirectories: false)
        let firstFile = try TestSupport.writeImage(
            to: firstSources.appendingPathComponent("frog.png")
        )
        let secondFile = try TestSupport.writeImage(
            to: secondSources.appendingPathComponent("frog.png"),
            width: 3,
            height: 3
        )
        let store = LibraryStore(
            rootURL: workspace.appendingPathComponent("Library", isDirectory: true)
        )

        let firstPack = try await install(
            files: [firstFile],
            packName: "Original",
            into: store
        )
        let oldAsset = try XCTUnwrap(firstPack.items[0].payload.asset)
        let oldAssetURL = try await store.assetURL(for: oldAsset)
        XCTAssertTrue(FileManager.default.fileExists(atPath: oldAssetURL.path))

        let scan = try ImportScanner().scanFiles([secondFile], packName: "Replacement")
        let library = try await store.snapshot()
        let preview = ImportCollisionAnalyzer.makePreview(
            scanResult: scan,
            library: library
        )
        XCTAssertEqual(preview.collisions.count, 1)
        let resolved = try ImportCollisionAnalyzer.resolve(
            preview: preview,
            decisions: [preview.collisions[0].id: .replaceExistingItem],
            library: library
        )
        let replacement = try await store.install(resolved)
        let current = try await store.snapshot()

        XCTAssertEqual(replacement.items.count, 1)
        XCTAssertEqual(
            try XCTUnwrap(current.packs.first(where: { $0.id == firstPack.id })).items.count,
            0
        )
        XCTAssertFalse(FileManager.default.fileExists(atPath: oldAssetURL.path))
    }

    func testStoreRejectsSourceChangedAfterPreview() async throws {
        let workspace = try TestSupport.makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: workspace) }
        let source = try TestSupport.writeImage(
            to: workspace.appendingPathComponent("frog.png")
        )
        let scan = try ImportScanner().scanFiles([source], packName: "Frogs")
        let store = LibraryStore(
            rootURL: workspace.appendingPathComponent("Library", isDirectory: true)
        )
        let library = try await store.snapshot()
        let preview = ImportCollisionAnalyzer.makePreview(scanResult: scan, library: library)
        let resolved = try ImportCollisionAnalyzer.resolve(
            preview: preview,
            decisions: [:],
            library: library
        )

        _ = try TestSupport.writeImage(
            to: source,
            width: 4,
            height: 4
        )
        do {
            _ = try await store.install(resolved)
            XCTFail("Expected changed source rejection")
        } catch {
            // Revalidation may report the exact validation change or the digest mismatch;
            // either path proves the preview is not trusted after the file changes.
            XCTAssertTrue(
                error is LibraryStoreError || error is AssetValidationError,
                "Unexpected error: \(error)"
            )
        }
    }

    func testCleansOrphanAssetsWithoutTouchingReferencedFiles() async throws {
        let workspace = try TestSupport.makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: workspace) }
        let source = try TestSupport.writeImage(
            to: workspace.appendingPathComponent("frog.png")
        )
        let libraryRoot = workspace.appendingPathComponent("Library", isDirectory: true)
        let store = LibraryStore(rootURL: libraryRoot)
        let pack = try await install(files: [source], packName: "Frogs", into: store)
        let referenced = try await store.assetURL(
            for: XCTUnwrap(pack.items[0].payload.asset)
        )

        let orphan = referenced.deletingLastPathComponent().appendingPathComponent("orphan.png")
        try Data("orphan".utf8).write(to: orphan)
        try await store.cleanUpAssets()
        XCTAssertFalse(FileManager.default.fileExists(atPath: orphan.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: referenced.path))
    }

    func testCreatesEditsReplacesExportsAndRemovesLibraryItems() async throws {
        let workspace = try TestSupport.makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: workspace) }
        let sources = workspace.appendingPathComponent("Sources", isDirectory: true)
        try FileManager.default.createDirectory(at: sources, withIntermediateDirectories: false)
        let frog = try TestSupport.writeImage(
            to: sources.appendingPathComponent("frog.png")
        )
        let toad = try TestSupport.writeImage(
            to: sources.appendingPathComponent("toad.png"),
            width: 3,
            height: 3
        )
        let replacement = try TestSupport.writeImage(
            to: sources.appendingPathComponent("replacement.png"),
            width: 4,
            height: 4
        )
        let libraryRoot = workspace.appendingPathComponent("Library", isDirectory: true)
        let store = LibraryStore(rootURL: libraryRoot)

        let emptyRuntimeID = UUID()
        let emptyStableID = try PackIdentifier(validating: "com.raj.empty")
        let emptyManifest = PackManifestMetadata(
            packID: emptyStableID,
            name: "Empty Pond",
            author: "Raj"
        )
        let emptyPack = try await store.createPack(
            id: emptyRuntimeID,
            manifest: emptyManifest
        )
        XCTAssertEqual(emptyPack.id, emptyRuntimeID)
        XCTAssertEqual(emptyPack.manifest, emptyManifest)
        XCTAssertEqual(emptyPack.priority, 0)
        XCTAssertTrue(emptyPack.items.isEmpty)

        do {
            _ = try await store.createPack(
                manifest: emptyManifest
            )
            XCTFail("Expected duplicate stable pack ID rejection")
        } catch {
            XCTAssertEqual(
                error as? LibraryModelError,
                .duplicateStablePackID(emptyStableID)
            )
        }
        let afterRejectedCreate = try await store.snapshot()
        XCTAssertEqual(afterRejectedCreate.packs.map(\.id), [emptyRuntimeID])

        let installed = try await install(
            files: [frog, toad],
            packName: "Frogs",
            into: store
        )
        let frogItem = try XCTUnwrap(
            installed.items.first(where: { $0.shortcode.rawValue == "frog" })
        )
        let toadItem = try XCTUnwrap(
            installed.items.first(where: { $0.shortcode.rawValue == "toad" })
        )
        let oldFrogAsset = try XCTUnwrap(frogItem.payload.asset)
        let oldFrogAssetURL = try await store.assetURL(for: oldFrogAsset)
        let toadAssetURL = try await store.assetURL(
            for: XCTUnwrap(toadItem.payload.asset)
        )

        let toadShortcode = try Shortcode(validating: "toad")
        do {
            _ = try await store.updateItemMetadata(
                packID: installed.id,
                itemID: frogItem.id,
                shortcode: frogItem.shortcode,
                aliases: [toadShortcode],
                displayName: nil,
                tags: [],
                category: nil
            )
            XCTFail("Expected edit collision rejection")
        } catch {
            XCTAssertEqual(
                error as? LibraryStoreError,
                .shortcodeCollision(toadShortcode, existingItemID: toadItem.id)
            )
        }

        let edited = try await store.updateItemMetadata(
            packID: installed.id,
            itemID: frogItem.id,
            shortcode: Shortcode(validating: "pond_frog"),
            aliases: [
                Shortcode(validating: "green_frog"),
                Shortcode(validating: "ribbit")
            ],
            displayName: "Pond Frog",
            tags: ["frog", "green"],
            category: "Bufos"
        )
        XCTAssertEqual(edited.shortcode.rawValue, "pond_frog")
        XCTAssertEqual(edited.aliases.map(\.rawValue), ["green_frog", "ribbit"])
        XCTAssertEqual(edited.displayName, "Pond Frog")
        XCTAssertEqual(edited.tags, ["frog", "green"])
        XCTAssertEqual(edited.category, "Bufos")

        let replaced = try await store.replaceItemAsset(
            packID: installed.id,
            itemID: frogItem.id,
            with: replacement
        )
        let replacementAsset = try XCTUnwrap(replaced.payload.asset)
        let replacementAssetURL = try await store.assetURL(for: replacementAsset)
        XCTAssertEqual(replacementAsset.pixelWidth, 4)
        XCTAssertEqual(replacementAsset.pixelHeight, 4)
        XCTAssertEqual(replaced.sourceFilename, "replacement.png")
        XCTAssertTrue(FileManager.default.fileExists(atPath: replacementAssetURL.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: oldFrogAssetURL.path))

        let sourceURL = try XCTUnwrap(URL(string: "https://example.com/mojipond/frogs"))
        let exportManifest = PackManifestMetadata(
            packID: try PackIdentifier(validating: "com.raj.frogs"),
            name: "Polished Frogs",
            version: "2.1.0",
            author: "Raj",
            description: "A portable pond.",
            sourceURL: sourceURL,
            license: "CC-BY-4.0"
        )
        try await store.setPackManifestMetadata(installed.id, metadata: exportManifest)

        let destination = workspace.appendingPathComponent(
            "Polished Frogs.mojipond",
            isDirectory: true
        )
        let exportedURL = try await store.exportPortablePack(
            installed.id,
            to: destination
        )
        XCTAssertEqual(exportedURL, destination)
        let decodedExport = try PortablePackManifest.decode(
            Data(
                contentsOf: destination.appendingPathComponent(
                    MojiPondLibrary.manifestFilename
                )
            )
        )
        XCTAssertEqual(decodedExport.metadata, exportManifest)
        XCTAssertEqual(decodedExport.emoji.count, 2)
        let exportedFrog = try XCTUnwrap(
            decodedExport.emoji.first(where: { $0.shortcode.rawValue == "pond_frog" })
        )
        XCTAssertEqual(exportedFrog.aliases.map(\.rawValue), ["green_frog", "ribbit"])
        XCTAssertEqual(exportedFrog.tags, ["frog", "green"])
        XCTAssertEqual(exportedFrog.category, "Bufos")
        let exportedFrogURL = destination.appendingPathComponent(
            try XCTUnwrap(exportedFrog.file)
        )
        let exportedValidation = try AssetValidator().validate(fileAt: exportedFrogURL)
        XCTAssertEqual(exportedValidation.digest.sha256, replacementAsset.sha256)

        do {
            _ = try await store.exportPortablePack(installed.id, to: destination)
            XCTFail("Expected existing export destination rejection")
        } catch {
            XCTAssertEqual(
                error as? LibraryStoreError,
                .exportDestinationAlreadyExists
            )
        }

        let removed = try await store.removeItem(
            packID: installed.id,
            itemID: frogItem.id
        )
        XCTAssertEqual(removed.id, frogItem.id)
        XCTAssertFalse(FileManager.default.fileExists(atPath: replacementAssetURL.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: toadAssetURL.path))

        let reloaded = try await LibraryStore(rootURL: libraryRoot).snapshot()
        let reloadedPack = try XCTUnwrap(
            reloaded.packs.first(where: { $0.id == installed.id })
        )
        XCTAssertEqual(reloadedPack.name, "Polished Frogs")
        XCTAssertEqual(reloadedPack.items.map(\.id), [toadItem.id])
        XCTAssertEqual(reloadedPack.items.map(\.order), [0])
    }

    func testCreatesCollisionSafeUnicodeItemAndExportsUnicodeOnlyPack() async throws {
        let workspace = try TestSupport.makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: workspace) }
        let store = LibraryStore(
            rootURL: workspace.appendingPathComponent(
                "Library",
                isDirectory: true
            )
        )
        let pack = try await store.createPack(name: "My Unicode")
        let emptyDigest = pack.updateMetadata.contentSHA256

        let created = try await store.createUnicodeItem(
            in: pack.id,
            shortcode: Shortcode(validating: "pond_coder"),
            unicode: "👨🏽‍💻",
            aliases: [Shortcode(validating: "frog_dev")],
            displayName: "Pond coder",
            tags: ["frog", "work"],
            category: "People"
        )

        XCTAssertEqual(created.payload.unicode, "👨🏽‍💻")
        XCTAssertNil(created.payload.asset)
        let afterCreate = try await store.snapshot()
        let updatedPack = try XCTUnwrap(
            afterCreate.packs.first(where: { $0.id == pack.id })
        )
        XCTAssertNotEqual(
            updatedPack.updateMetadata.contentSHA256,
            emptyDigest
        )

        do {
            _ = try await store.createUnicodeItem(
                in: pack.id,
                shortcode: Shortcode(validating: "pond_coder"),
                unicode: "🐸"
            )
            XCTFail("Expected shortcode collision")
        } catch {
            XCTAssertEqual(
                error as? LibraryStoreError,
                .shortcodeCollision(
                    try Shortcode(validating: "pond_coder"),
                    existingItemID: created.id
                )
            )
        }
        do {
            _ = try await store.createUnicodeItem(
                in: pack.id,
                shortcode: Shortcode(validating: "plain_text"),
                unicode: "frog"
            )
            XCTFail("Expected plain text rejection")
        } catch {
            XCTAssertEqual(
                error as? UnicodeEmojiValidationError,
                .mustBeSingleEmoji
            )
        }
        let afterRejectedCreates = try await store.snapshot()
        XCTAssertEqual(
            afterRejectedCreates.packs[0].items.map(\.id),
            [created.id]
        )

        let destination = workspace.appendingPathComponent(
            "Unicode Only.mojipond",
            isDirectory: true
        )
        _ = try await store.exportPortablePack(pack.id, to: destination)
        XCTAssertFalse(
            FileManager.default.fileExists(
                atPath: destination.appendingPathComponent("emoji").path
            )
        )
        let scanned = try ImportScanner().scanFolder(at: destination)
        XCTAssertEqual(scanned.preparedPack.items.count, 1)
        XCTAssertEqual(scanned.preparedPack.items[0].unicode, "👨🏽‍💻")
        XCTAssertNil(scanned.preparedPack.items[0].asset)

        let builtInPack = try await store.createPack(
            name: "Read Only",
            source: PackSource(kind: .builtIn)
        )
        do {
            _ = try await store.createUnicodeItem(
                in: builtInPack.id,
                shortcode: Shortcode(validating: "nope"),
                unicode: "🛑"
            )
            XCTFail("Expected built-in pack mutation rejection")
        } catch {
            XCTAssertEqual(
                error as? LibraryStoreError,
                .cannotModifyBuiltInPack(builtInPack.id)
            )
        }
    }

    func testReservedShortcodesRejectDirectCreateUpdateAndImport() async throws {
        let workspace = try TestSupport.makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: workspace) }
        let wave = try Shortcode(validating: "wave")
        let hello = try Shortcode(validating: "hello")
        let pondFrog = try Shortcode(validating: "pond_frog")
        let store = LibraryStore(
            rootURL: workspace.appendingPathComponent(
                "Library",
                isDirectory: true
            ),
            reservedShortcodes: [wave, hello]
        )
        let pack = try await store.createPack(name: "My Pond")

        do {
            _ = try await store.createUnicodeItem(
                in: pack.id,
                shortcode: wave,
                unicode: "👋"
            )
            XCTFail("Expected protected create rejection")
        } catch {
            XCTAssertEqual(
                error as? LibraryStoreError,
                .reservedShortcode(wave)
            )
        }

        let item = try await store.createUnicodeItem(
            in: pack.id,
            shortcode: pondFrog,
            unicode: "🐸"
        )
        do {
            _ = try await store.updateItemMetadata(
                packID: pack.id,
                itemID: item.id,
                shortcode: pondFrog,
                aliases: [hello],
                displayName: nil,
                tags: [],
                category: nil
            )
            XCTFail("Expected protected update rejection")
        } catch {
            XCTAssertEqual(
                error as? LibraryStoreError,
                .reservedShortcode(hello)
            )
        }

        let imported = ResolvedPackImport(
            pack: PreparedPackImport(
                name: "Bypassed Preview",
                source: PackSource(kind: .individualFiles),
                items: [
                    PreparedEmoji(
                        shortcode: try Shortcode(
                            validating: "imported_frog"
                        ),
                        aliases: [wave],
                        unicode: "🥳",
                        sourceURL: workspace.appendingPathComponent(
                            "unicode-import"
                        )
                    )
                ]
            ),
            existingItemIDsToReplace: []
        )
        do {
            _ = try await store.install(imported)
            XCTFail("Expected protected import rejection")
        } catch {
            XCTAssertEqual(
                error as? LibraryStoreError,
                .reservedShortcode(wave)
            )
        }

        let snapshot = try await store.snapshot()
        XCTAssertEqual(snapshot.packs.map(\.id), [pack.id])
        XCTAssertEqual(snapshot.packs[0].items.map(\.id), [item.id])
        XCTAssertEqual(snapshot.packs[0].items[0].shortcode, pondFrog)
        XCTAssertTrue(snapshot.packs[0].items[0].aliases.isEmpty)
    }

    func testMixedPortablePackInstallAppendExportAndReplaceRoundTrips() async throws {
        let workspace = try TestSupport.makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: workspace) }
        let store = LibraryStore(
            rootURL: workspace.appendingPathComponent(
                "Library",
                isDirectory: true
            )
        )
        let initialSource = workspace.appendingPathComponent(
            "Initial",
            isDirectory: true
        )
        try FileManager.default.createDirectory(
            at: initialSource,
            withIntermediateDirectories: false
        )
        _ = try TestSupport.writeImage(
            to: initialSource.appendingPathComponent("frog.png")
        )
        let initialManifest = PortablePackManifest(
            id: try PackIdentifier(validating: "example.mixed"),
            name: "Mixed Pond",
            version: "1.0.0",
            emoji: [
                PortablePackEmoji(
                    shortcode: try Shortcode(validating: "frog_art"),
                    file: "frog.png"
                ),
                PortablePackEmoji(
                    shortcode: try Shortcode(validating: "frog_unicode"),
                    unicode: "🐸"
                )
            ]
        )
        try JSONEncoder().encode(initialManifest).write(
            to: initialSource.appendingPathComponent(
                MojiPondLibrary.manifestFilename
            )
        )

        let initialScan = try ImportScanner().scanFolder(at: initialSource)
        let initialPreview = ImportCollisionAnalyzer.makePreview(
            scanResult: initialScan,
            library: try await store.snapshot()
        )
        let initialResolved = try ImportCollisionAnalyzer.resolve(
            preview: initialPreview,
            decisions: [:],
            library: try await store.snapshot()
        )
        let installed = try await store.install(initialResolved)
        XCTAssertEqual(installed.items.count, 2)
        XCTAssertEqual(
            installed.items.compactMap(\.payload.unicode),
            ["🐸"]
        )
        XCTAssertEqual(
            installed.items.compactMap(\.payload.asset).count,
            1
        )

        let appendSource = workspace.appendingPathComponent(
            "Append",
            isDirectory: true
        )
        try FileManager.default.createDirectory(
            at: appendSource,
            withIntermediateDirectories: false
        )
        _ = try TestSupport.writeImage(
            to: appendSource.appendingPathComponent("newt.png"),
            width: 3,
            height: 3
        )
        let appendManifest = PortablePackManifest(
            id: try PackIdentifier(validating: "example.mixed.append"),
            name: "More Pond",
            version: "1.0.0",
            emoji: [
                PortablePackEmoji(
                    shortcode: try Shortcode(validating: "newt_art"),
                    file: "newt.png"
                ),
                PortablePackEmoji(
                    shortcode: try Shortcode(validating: "pond_party"),
                    unicode: "🥳"
                )
            ]
        )
        try JSONEncoder().encode(appendManifest).write(
            to: appendSource.appendingPathComponent(
                MojiPondLibrary.manifestFilename
            )
        )
        let appendScan = try ImportScanner().scanFolder(at: appendSource)
        let beforeAppend = try await store.snapshot()
        let appendPreview = ImportCollisionAnalyzer.makePreview(
            scanResult: appendScan,
            library: beforeAppend
        )
        let appendResolved = try ImportCollisionAnalyzer.resolve(
            preview: appendPreview,
            decisions: [:],
            library: beforeAppend
        )
        let appended = try await store.append(
            appendResolved,
            to: installed.id
        )
        XCTAssertEqual(appended.items.count, 4)
        XCTAssertEqual(
            Set(appended.items.compactMap(\.payload.unicode)),
            Set(["🐸", "🥳"])
        )
        XCTAssertEqual(
            appended.items.compactMap(\.payload.asset).count,
            2
        )

        let exported = workspace.appendingPathComponent(
            "Mixed Export.mojipond",
            isDirectory: true
        )
        _ = try await store.exportPortablePack(installed.id, to: exported)
        let exportedManifest = try PortablePackManifest.decode(
            Data(
                contentsOf: exported.appendingPathComponent(
                    MojiPondLibrary.manifestFilename
                )
            )
        )
        XCTAssertEqual(
            exportedManifest.schemaVersion,
            PortablePackManifest.currentSchemaVersion
        )
        XCTAssertEqual(exportedManifest.emoji.count, 4)
        XCTAssertEqual(
            exportedManifest.emoji.filter { $0.file != nil }.count,
            2
        )
        XCTAssertEqual(
            Set(exportedManifest.emoji.compactMap(\.unicode)),
            Set(["🐸", "🥳"])
        )
        XCTAssertTrue(
            exportedManifest.emoji.allSatisfy {
                ($0.file == nil) != ($0.unicode == nil)
            }
        )

        let exportedScan = try ImportScanner().scanFolder(at: exported)
        var comparison = try await store.snapshot()
        comparison.packs.removeAll { $0.id == installed.id }
        let replacementPreview = ImportCollisionAnalyzer.makePreview(
            scanResult: exportedScan,
            library: comparison
        )
        let replacementResolved = try ImportCollisionAnalyzer.resolve(
            preview: replacementPreview,
            decisions: [:],
            library: comparison
        )
        let replaced = try await store.replacePackContents(
            replacementResolved,
            in: installed.id
        )
        XCTAssertEqual(replaced.items.count, 4)
        XCTAssertEqual(
            Set(replaced.items.compactMap(\.payload.unicode)),
            Set(["🐸", "🥳"])
        )

        let roundTripStore = LibraryStore(
            rootURL: workspace.appendingPathComponent(
                "RoundTripLibrary",
                isDirectory: true
            )
        )
        let roundTripPreview = ImportCollisionAnalyzer.makePreview(
            scanResult: exportedScan,
            library: try await roundTripStore.snapshot()
        )
        let roundTripResolved = try ImportCollisionAnalyzer.resolve(
            preview: roundTripPreview,
            decisions: [:],
            library: try await roundTripStore.snapshot()
        )
        let roundTripped = try await roundTripStore.install(
            roundTripResolved
        )
        XCTAssertEqual(
            roundTripped.items.map(\.shortcode),
            appended.items.map(\.shortcode)
        )
        XCTAssertEqual(
            roundTripped.items.compactMap(\.payload.unicode),
            replaced.items.compactMap(\.payload.unicode)
        )
        XCTAssertEqual(
            roundTripped.items.compactMap { $0.payload.asset?.sha256 },
            replaced.items.compactMap { $0.payload.asset?.sha256 }
        )
    }

    func testMigratesSchemaOneManifestAtomically() async throws {
        let root = try TestSupport.makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(
            at: root.appendingPathComponent("assets"),
            withIntermediateDirectories: false
        )
        let packID = UUID()
        let itemID = UUID()
        let timestamp = "2026-07-27T12:00:00Z"
        let legacyJSON = """
        {
          "schemaVersion": 1,
          "updatedAt": "\(timestamp)",
          "packs": [{
            "id": "\(packID.uuidString)",
            "name": "Legacy Frogs",
            "isEnabled": true,
            "source": {"kind": "builtIn"},
            "updateMetadata": {
              "installedAt": "\(timestamp)",
              "lastUpdatedAt": "\(timestamp)"
            },
            "items": [{
              "id": "\(itemID.uuidString)",
              "shortcode": "frog",
              "aliases": [],
              "payload": {"kind": "unicode", "unicode": "🐸"}
            }]
          }]
        }
        """
        try Data(legacyJSON.utf8).write(
            to: root.appendingPathComponent(MojiPondLibrary.manifestFilename)
        )

        let store = LibraryStore(rootURL: root)
        let migrated = try await store.snapshot()
        XCTAssertEqual(migrated.schemaVersion, MojiPondLibrary.currentSchemaVersion)
        XCTAssertEqual(migrated.packs[0].name, "Legacy Frogs")
        XCTAssertEqual(
            migrated.packs[0].manifest.packID,
            .local(packID)
        )
        XCTAssertEqual(migrated.packs[0].items[0].tags, [])
        XCTAssertEqual(migrated.packs[0].items[0].order, 0)

        let persisted = try String(
            contentsOf: root.appendingPathComponent(MojiPondLibrary.manifestFilename),
            encoding: .utf8
        )
        XCTAssertTrue(persisted.contains("\"schemaVersion\" : 2"))
        XCTAssertTrue(persisted.contains("\"manifest\""))
    }

    func testRejectsFutureSchemaAndManifestSymlink() async throws {
        let workspace = try TestSupport.makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: workspace) }

        let futureRoot = workspace.appendingPathComponent("Future", isDirectory: true)
        try FileManager.default.createDirectory(at: futureRoot, withIntermediateDirectories: false)
        try FileManager.default.createDirectory(
            at: futureRoot.appendingPathComponent("assets"),
            withIntermediateDirectories: false
        )
        try Data(
            #"{"schemaVersion":999,"updatedAt":"2026-07-27T12:00:00Z","packs":[]}"#.utf8
        ).write(to: futureRoot.appendingPathComponent(MojiPondLibrary.manifestFilename))
        do {
            _ = try await LibraryStore(rootURL: futureRoot).snapshot()
            XCTFail("Expected future schema rejection")
        } catch {
            XCTAssertEqual(
                error as? LibraryModelError,
                .unsupportedSchemaVersion(999)
            )
        }

        let linkRoot = workspace.appendingPathComponent("Link", isDirectory: true)
        try FileManager.default.createDirectory(at: linkRoot, withIntermediateDirectories: false)
        let target = workspace.appendingPathComponent("target.json")
        try Data("{}".utf8).write(to: target)
        try FileManager.default.createSymbolicLink(
            at: linkRoot.appendingPathComponent(MojiPondLibrary.manifestFilename),
            withDestinationURL: target
        )
        do {
            _ = try await LibraryStore(rootURL: linkRoot).snapshot()
            XCTFail("Expected manifest symlink rejection")
        } catch {
            XCTAssertEqual(error as? LibraryStoreError, .unsafeManifest)
        }
    }

    private func install(
        files: [URL],
        packName: String,
        into store: LibraryStore
    ) async throws -> EmojiPack {
        let scan = try ImportScanner().scanFiles(files, packName: packName)
        let library = try await store.snapshot()
        let preview = ImportCollisionAnalyzer.makePreview(
            scanResult: scan,
            library: library
        )
        let resolved = try ImportCollisionAnalyzer.resolve(
            preview: preview,
            decisions: [:],
            library: library
        )
        return try await store.install(resolved)
    }
}
