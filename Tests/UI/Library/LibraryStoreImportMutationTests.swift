import Foundation
import XCTest
@testable import MojiPond

@MainActor
final class LibraryStoreImportMutationTests: XCTestCase {
    func testAppendStagesFilesAndPreservesPackIdentityAndAttribution() async throws {
        let workspace = try TestSupport.makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: workspace) }
        let store = LibraryStore(
            rootURL: workspace.appendingPathComponent("Library", isDirectory: true)
        )
        let frog = try TestSupport.writeImage(
            to: workspace.appendingPathComponent("frog.png")
        )
        let toad = try TestSupport.writeImage(
            to: workspace.appendingPathComponent("toad.png"),
            width: 3,
            height: 3
        )

        let scannedInitial = try ImportScanner().scanFiles(
            [frog],
            packName: "Pond Friends"
        )
        var preparedInitial = scannedInitial.preparedPack
        preparedInitial.manifest.author = "Raj"
        preparedInitial.manifest.license = "Personal use"
        let initialScan = ImportScanResult(
            preparedPack: preparedInitial,
            rejections: scannedInitial.rejections,
            ignoredFileCount: scannedInitial.ignoredFileCount
        )
        let initial = try await install(initialScan, into: store)

        let appendScan = try ImportScanner().scanFiles(
            [toad],
            packName: "Ignored incoming name"
        )
        let beforeAppend = try await store.snapshot()
        let appendPreview = ImportCollisionAnalyzer.makePreview(
            scanResult: appendScan,
            library: beforeAppend
        )
        let resolved = try ImportCollisionAnalyzer.resolve(
            preview: appendPreview,
            decisions: [:],
            library: beforeAppend
        )
        let appended = try await store.append(resolved, to: initial.id)

        XCTAssertEqual(appended.id, initial.id)
        XCTAssertEqual(appended.name, "Pond Friends")
        XCTAssertEqual(appended.manifest.author, "Raj")
        XCTAssertEqual(appended.manifest.license, "Personal use")
        XCTAssertEqual(
            appended.items.map(\.shortcode.rawValue).sorted(),
            ["frog", "toad"]
        )
        for item in appended.items {
            let asset = try XCTUnwrap(item.payload.asset)
            let assetURL = try await store.assetURL(for: asset)
            XCTAssertTrue(FileManager.default.fileExists(atPath: assetURL.path))
        }
    }

    func testReplacePackContentsSwapsAssetsAndKeepsStableMetadata() async throws {
        let workspace = try TestSupport.makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: workspace) }
        let store = LibraryStore(
            rootURL: workspace.appendingPathComponent("Library", isDirectory: true)
        )
        let frog = try TestSupport.writeImage(
            to: workspace.appendingPathComponent("frog.png")
        )
        let newt = try TestSupport.writeImage(
            to: workspace.appendingPathComponent("newt.png"),
            width: 4,
            height: 4
        )

        let scannedInitial = try ImportScanner().scanFiles(
            [frog],
            packName: "Pond Friends"
        )
        var preparedInitial = scannedInitial.preparedPack
        preparedInitial.manifest.author = "Original Author"
        preparedInitial.manifest.license = "CC-BY-4.0"
        let initialScan = ImportScanResult(
            preparedPack: preparedInitial,
            rejections: scannedInitial.rejections,
            ignoredFileCount: scannedInitial.ignoredFileCount
        )
        let initial = try await install(initialScan, into: store)
        let oldAsset = try XCTUnwrap(initial.items.first?.payload.asset)
        let oldAssetURL = try await store.assetURL(for: oldAsset)

        let scannedReplacement = try ImportScanner().scanFiles(
            [newt],
            packName: "A different incoming name"
        )
        var preparedReplacement = scannedReplacement.preparedPack
        preparedReplacement.manifest.version = "2.0.0"
        preparedReplacement.manifest.author = "Replacement Author"
        let replacementScan = ImportScanResult(
            preparedPack: preparedReplacement,
            rejections: scannedReplacement.rejections,
            ignoredFileCount: scannedReplacement.ignoredFileCount
        )
        let current = try await store.snapshot()
        var comparisonLibrary = current
        comparisonLibrary.packs.removeAll { $0.id == initial.id }
        let preview = ImportCollisionAnalyzer.makePreview(
            scanResult: replacementScan,
            library: comparisonLibrary
        )
        let resolved = try ImportCollisionAnalyzer.resolve(
            preview: preview,
            decisions: [:],
            library: comparisonLibrary
        )
        let replaced = try await store.replacePackContents(
            resolved,
            in: initial.id
        )

        XCTAssertEqual(replaced.id, initial.id)
        XCTAssertEqual(replaced.name, "Pond Friends")
        XCTAssertEqual(replaced.source, initial.source)
        XCTAssertEqual(replaced.manifest.packID, initial.manifest.packID)
        XCTAssertEqual(replaced.manifest.author, "Original Author")
        XCTAssertEqual(replaced.manifest.license, "CC-BY-4.0")
        XCTAssertEqual(replaced.manifest.version, "2.0.0")
        XCTAssertEqual(replaced.items.map(\.shortcode.rawValue), ["newt"])
        XCTAssertFalse(FileManager.default.fileExists(atPath: oldAssetURL.path))

        let newAsset = try XCTUnwrap(replaced.items.first?.payload.asset)
        let newAssetURL = try await store.assetURL(for: newAsset)
        XCTAssertTrue(FileManager.default.fileExists(atPath: newAssetURL.path))
    }

    func testAppendRejectsChangedSourceWithoutChangingExistingPack() async throws {
        let workspace = try TestSupport.makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: workspace) }
        let store = LibraryStore(
            rootURL: workspace.appendingPathComponent("Library", isDirectory: true)
        )
        let frog = try TestSupport.writeImage(
            to: workspace.appendingPathComponent("frog.png")
        )
        let toad = try TestSupport.writeImage(
            to: workspace.appendingPathComponent("toad.png")
        )
        let initial = try await install(
            try ImportScanner().scanFiles([frog], packName: "Pond"),
            into: store
        )
        let scan = try ImportScanner().scanFiles([toad], packName: "Pond")
        let snapshot = try await store.snapshot()
        let preview = ImportCollisionAnalyzer.makePreview(
            scanResult: scan,
            library: snapshot
        )
        let resolved = try ImportCollisionAnalyzer.resolve(
            preview: preview,
            decisions: [:],
            library: snapshot
        )
        _ = try TestSupport.writeImage(to: toad, width: 5, height: 5)

        do {
            _ = try await store.append(resolved, to: initial.id)
            XCTFail("Expected changed source rejection")
        } catch {
            XCTAssertTrue(error is LibraryStoreError || error is AssetValidationError)
        }
        let unchanged = try await store.snapshot()
        XCTAssertEqual(
            unchanged.packs.first(where: { $0.id == initial.id })?.items
                .map(\.shortcode.rawValue),
            ["frog"]
        )
    }

    private func install(
        _ scan: ImportScanResult,
        into store: LibraryStore
    ) async throws -> EmojiPack {
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
