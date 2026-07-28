import Foundation
import XCTest
@testable import MojiPond

@MainActor
final class ImportOrchestratorTests: XCTestCase {
    func testReportsDuplicateSHAWithinImportAndExistingLibrary() async throws {
        let workspace = try ImportingTestSupport.makeWorkspace()
        defer { try? FileManager.default.removeItem(at: workspace.root) }
        let original = try TestSupport.writeImage(
            to: workspace.root.appendingPathComponent("copy_one.png")
        )
        let copy = workspace.root.appendingPathComponent("copy_two.png")
        try FileManager.default.copyItem(at: original, to: copy)
        let validated = try AssetValidator().validate(fileAt: original)
        let existingItemID = UUID()
        let existingPackID = UUID()
        let existingLibrary = MojiPondLibrary(
            packs: [
                EmojiPack(
                    id: existingPackID,
                    name: "Existing",
                    source: PackSource(kind: .builtIn),
                    items: [
                        LibraryEmoji(
                            id: existingItemID,
                            shortcode: try Shortcode(
                                validating: "existing_bufo"
                            ),
                            payload: .asset(
                                StoredAsset(
                                    relativePath: "assets/existing/bufo.png",
                                    format: validated.format,
                                    sha256: validated.digest.sha256,
                                    byteCount: validated.digest.byteCount,
                                    pixelWidth: validated.pixelWidth,
                                    pixelHeight: validated.pixelHeight,
                                    frameCount: validated.frameCount
                                )
                            )
                        )
                    ]
                )
            ]
        )
        let preparation = try await ImportOrchestrator(
            temporaryRootURL: workspace.temporaryRoot
        ).prepare(
            .files([original, copy], packName: "Copies"),
            against: existingLibrary
        )

        XCTAssertEqual(preparation.preview.items.count, 2)
        XCTAssertEqual(preparation.duplicateContent.count, 1)
        let duplicate = preparation.duplicateContent[0]
        XCTAssertEqual(duplicate.sha256, validated.digest.sha256)
        XCTAssertEqual(Set(duplicate.incomingItemIDs).count, 2)
        XCTAssertEqual(duplicate.existingItems.count, 1)
        XCTAssertEqual(duplicate.existingItems[0].packID, existingPackID)
        XCTAssertEqual(duplicate.existingItems[0].itemID, existingItemID)
    }

    func testDuplicateAssetAnalysisDeliberatelySkipsUnicodeEntries() async throws {
        let workspace = try ImportingTestSupport.makeWorkspace()
        defer { try? FileManager.default.removeItem(at: workspace.root) }
        let packURL = workspace.root.appendingPathComponent(
            "UnicodePack",
            isDirectory: true
        )
        try FileManager.default.createDirectory(
            at: packURL,
            withIntermediateDirectories: false
        )
        let manifest = PortablePackManifest(
            id: try PackIdentifier(validating: "example.unicode"),
            name: "Unicode",
            version: "1.0.0",
            emoji: [
                PortablePackEmoji(
                    shortcode: try Shortcode(validating: "frog_one"),
                    unicode: "🐸"
                ),
                PortablePackEmoji(
                    shortcode: try Shortcode(validating: "frog_two"),
                    unicode: "🐸"
                )
            ]
        )
        try JSONEncoder().encode(manifest).write(
            to: packURL.appendingPathComponent(
                MojiPondLibrary.manifestFilename
            )
        )
        let existingLibrary = MojiPondLibrary(
            packs: [
                EmojiPack(
                    name: "Existing",
                    source: PackSource(kind: .individualFiles),
                    items: [
                        LibraryEmoji(
                            shortcode: try Shortcode(
                                validating: "existing_frog"
                            ),
                            payload: .unicode("🐸")
                        )
                    ]
                )
            ]
        )

        let preparation = try await ImportOrchestrator(
            temporaryRootURL: workspace.temporaryRoot
        ).prepare(
            .folder(packURL),
            against: existingLibrary
        )

        XCTAssertEqual(preparation.preview.items.count, 2)
        XCTAssertTrue(
            preparation.preview.items.allSatisfy {
                $0.unicode == "🐸" && $0.format == nil
            }
        )
        XCTAssertTrue(preparation.duplicateContent.isEmpty)
        try await preparation.discard()
    }

    func testZIPPreparationOwnsExtractedFilesUntilDiscarded() async throws {
        let workspace = try ImportingTestSupport.makeWorkspace()
        defer { try? FileManager.default.removeItem(at: workspace.root) }
        let imageURL = try TestSupport.writeImage(
            to: workspace.root.appendingPathComponent("bufo.png")
        )
        let archiveData = TestZipBuilder.archive(
            entries: [
                .init(
                    path: "bufo-pack/bufo.png",
                    data: try Data(contentsOf: imageURL)
                )
            ]
        )
        let archiveURL = workspace.root.appendingPathComponent("bufos.zip")
        try archiveData.write(to: archiveURL)
        let preparation = try await ImportOrchestrator(
            temporaryRootURL: workspace.temporaryRoot
        ).prepare(
            .zipArchive(archiveURL),
            against: MojiPondLibrary()
        )

        XCTAssertEqual(
            preparation.preview.preparedPack.source.kind,
            .zipArchive
        )
        let extractedAsset =
            preparation.preview.preparedPack.items[0].sourceURL
        XCTAssertTrue(
            extractedAsset.path.hasPrefix(
                preparation.workingDirectoryURL.path + "/"
            )
        )
        XCTAssertTrue(
            FileManager.default.fileExists(atPath: extractedAsset.path)
        )

        try await preparation.discard()
        XCTAssertFalse(
            FileManager.default.fileExists(atPath: extractedAsset.path)
        )
    }

    func testSyntheticBufoGitHubArchivePreparesAndInstalls() async throws {
        let workspace = try ImportingTestSupport.makeWorkspace()
        defer { try? FileManager.default.removeItem(at: workspace.root) }
        let imageURL = try TestSupport.writeImage(
            to: workspace.root.appendingPathComponent("bufo-wave.png"),
            width: 3,
            height: 2
        )
        let sha = String(repeating: "b", count: 40)
        let archiveData = TestZipBuilder.archive(
            entries: [
                .init(
                    path: "all-the-bufo-\(sha)/all-the-bufo/bufo-wave.png",
                    data: try Data(contentsOf: imageURL)
                )
            ]
        )
        let transport = MockImportHTTPTransport()
        await transport.enqueue(
            host: "api.github.com",
            outcome: .response(
                try ImportingTestSupport.response(
                    url: "https://api.github.com/repos/knobiknows/all-the-bufo/commits/HEAD",
                    data: Data(#"{"sha":"\#(sha)"}"#.utf8),
                    headers: ["ETag": "\"bufo-commit\""]
                )
            )
        )
        await transport.enqueue(
            host: "codeload.github.com",
            outcome: .response(
                try ImportingTestSupport.response(
                    url: "https://codeload.github.com/knobiknows/all-the-bufo/zip/\(sha)",
                    data: archiveData,
                    headers: ["Content-Type": "application/zip"]
                )
            )
        )
        let orchestrator = ImportOrchestrator(
            transport: transport,
            temporaryRootURL: workspace.temporaryRoot
        )
        let preparation = try await orchestrator.prepare(
            .github(
                try ImportingTestSupport.unwrappedURL(
                    "https://github.com/knobiknows/all-the-bufo"
                )
            ),
            against: MojiPondLibrary()
        )

        XCTAssertEqual(preparation.preview.items.count, 1)
        XCTAssertEqual(
            preparation.preview.preparedPack.name,
            "all-the-bufo"
        )
        XCTAssertEqual(
            preparation.preview.preparedPack.source.kind,
            .github
        )
        XCTAssertEqual(
            preparation.preview.preparedPack.source.github?.ref,
            "HEAD"
        )
        XCTAssertEqual(
            preparation.preview.preparedPack.updateMetadata.sourceRevision,
            sha
        )
        XCTAssertEqual(
            preparation.preview.preparedPack.updateMetadata.sourceETag,
            "\"bufo-commit\""
        )
        XCTAssertEqual(
            preparation.preview.preparedPack.items[0].shortcode.rawValue,
            "bufo-wave"
        )
        let temporaryAsset =
            preparation.preview.preparedPack.items[0].sourceURL
        XCTAssertTrue(
            FileManager.default.fileExists(atPath: temporaryAsset.path)
        )

        let store = LibraryStore(
            rootURL: workspace.root.appendingPathComponent(
                "Library",
                isDirectory: true
            )
        )
        let installed = try await preparation.install(into: store)
        XCTAssertFalse(
            FileManager.default.fileExists(
                atPath: preparation.workingDirectoryURL.path
            )
        )
        XCTAssertEqual(installed.items.count, 1)
        let installedAsset = try XCTUnwrap(installed.items[0].payload.asset)
        let installedAssetURL = try await store.assetURL(for: installedAsset)
        XCTAssertTrue(
            FileManager.default.fileExists(atPath: installedAssetURL.path)
        )
    }

    func testCancellationStopsGitHubPreparationAndCleansWorkspace() async throws {
        let workspace = try ImportingTestSupport.makeWorkspace()
        defer { try? FileManager.default.removeItem(at: workspace.root) }
        let transport = MockImportHTTPTransport()
        await transport.enqueue(
            host: "api.github.com",
            outcome: .waitForCancellation
        )
        let orchestrator = ImportOrchestrator(
            transport: transport,
            temporaryRootURL: workspace.temporaryRoot
        )
        let repositoryURL = try ImportingTestSupport.unwrappedURL(
            "https://github.com/knobiknows/all-the-bufo"
        )
        let task = Task {
            try await orchestrator.prepare(
                .github(repositoryURL),
                against: MojiPondLibrary()
            )
        }

        for _ in 0..<1_000 {
            if !(await transport.recordedCalls()).isEmpty {
                break
            }
            await Task.yield()
        }
        let callsBeforeCancellation = await transport.recordedCalls()
        XCTAssertEqual(callsBeforeCancellation.count, 1)
        task.cancel()
        do {
            _ = try await task.value
            XCTFail("Expected cancellation")
        } catch {
            XCTAssertTrue(error is CancellationError)
        }

        let remaining = try FileManager.default.contentsOfDirectory(
            at: workspace.temporaryRoot,
            includingPropertiesForKeys: nil
        )
        XCTAssertTrue(remaining.isEmpty)
    }
}
