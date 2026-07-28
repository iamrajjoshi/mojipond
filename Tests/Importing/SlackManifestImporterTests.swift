import Foundation
import XCTest
@testable import MojiPond

@MainActor
final class SlackManifestImporterTests: XCTestCase {
    func testFolderAutoDetectsLocalSlackMapAndResolvesAliases() async throws {
        let workspace = try ImportingTestSupport.makeWorkspace()
        defer { try? FileManager.default.removeItem(at: workspace.root) }
        let packURL = workspace.root.appendingPathComponent(
            "Local Slack",
            isDirectory: true
        )
        let imagesURL = packURL.appendingPathComponent(
            "images",
            isDirectory: true
        )
        try FileManager.default.createDirectory(
            at: imagesURL,
            withIntermediateDirectories: true
        )
        _ = try TestSupport.writeImage(
            to: imagesURL.appendingPathComponent("bufo-wave.png")
        )
        let manifest = """
        {
          "bufo_wave": "images/bufo-wave.png",
          "hello_bufo": "alias:bufo_wave",
          "missing_bufo": "images/missing.png"
        }
        """
        try Data(manifest.utf8).write(
            to: packURL.appendingPathComponent("emoji.json")
        )
        let orchestrator = ImportOrchestrator(
            temporaryRootURL: workspace.temporaryRoot
        )

        let preparation = try await orchestrator.prepare(
            .folder(packURL),
            against: MojiPondLibrary()
        )

        XCTAssertEqual(
            preparation.preview.preparedPack.source.kind,
            .slackManifest
        )
        XCTAssertEqual(preparation.preview.items.count, 1)
        XCTAssertEqual(
            preparation.preview.preparedPack.items[0].shortcode.rawValue,
            "bufo_wave"
        )
        XCTAssertEqual(
            preparation.preview.preparedPack.items[0].aliases.map(\.rawValue),
            ["hello_bufo"]
        )
        XCTAssertEqual(preparation.preview.rejections.count, 1)
        XCTAssertEqual(
            preparation.preview.rejections[0].source,
            "missing_bufo"
        )
        XCTAssertTrue(
            FileManager.default.fileExists(
                atPath: preparation.workingDirectoryURL.path
            )
        )

        try await preparation.discard()
        XCTAssertFalse(
            FileManager.default.fileExists(
                atPath: preparation.workingDirectoryURL.path
            )
        )
    }

    func testSlackArrayDownloadsRemoteAssetsWithPartialFailure() async throws {
        let workspace = try ImportingTestSupport.makeWorkspace()
        defer { try? FileManager.default.removeItem(at: workspace.root) }
        let imageURL = try TestSupport.writeImage(
            to: workspace.root.appendingPathComponent("response.png"),
            width: 3,
            height: 3
        )
        let imageData = try Data(contentsOf: imageURL)
        let packURL = workspace.root.appendingPathComponent(
            "Remote Slack",
            isDirectory: true
        )
        try FileManager.default.createDirectory(
            at: packURL,
            withIntermediateDirectories: false
        )
        let manifest = """
        {
          "emoji": [
            {
              "name": "Bufo Wave",
              "image_url": "https://emoji.example/bufo-wave.png"
            },
            {
              "name": "Hello Bufo",
              "alias_for": "Bufo Wave"
            },
            {
              "name": "Broken Bufo",
              "url": "https://emoji.example/broken.png"
            }
          ]
        }
        """
        let manifestURL = packURL.appendingPathComponent("emoji.json")
        try Data(manifest.utf8).write(to: manifestURL)
        let transport = MockImportHTTPTransport()
        // Canonical Slack entries are processed in normalized shortcode order.
        await transport.enqueue(
            host: "emoji.example",
            outcome: .networkError(.transport(.timedOut))
        )
        await transport.enqueue(
            host: "emoji.example",
            outcome: .response(
                try ImportingTestSupport.response(
                    url: "https://cdn.example/bufo-wave.png",
                    data: imageData,
                    headers: ["Content-Type": "image/png"]
                )
            )
        )
        let orchestrator = ImportOrchestrator(
            transport: transport,
            temporaryRootURL: workspace.temporaryRoot
        )

        let preparation = try await orchestrator.prepare(
            .folder(
                packURL,
                packName: "Remote Bufos",
                allowRemoteSlackAssets: true
            ),
            against: MojiPondLibrary()
        )

        XCTAssertEqual(preparation.preview.items.count, 1)
        XCTAssertEqual(preparation.preview.rejections.count, 1)
        XCTAssertEqual(
            preparation.preview.preparedPack.items[0].shortcode.rawValue,
            "bufo_wave"
        )
        XCTAssertEqual(
            preparation.preview.preparedPack.items[0].aliases.map(\.rawValue),
            ["hello_bufo"]
        )
        XCTAssertEqual(
            preparation.preview.rejections[0].source,
            "broken_bufo"
        )
        let downloadedURL =
            preparation.preview.preparedPack.items[0].sourceURL
        XCTAssertTrue(
            downloadedURL.path.hasPrefix(
                preparation.workingDirectoryURL.path + "/"
            )
        )
        XCTAssertTrue(
            FileManager.default.fileExists(atPath: downloadedURL.path)
        )
        let calls = await transport.recordedCalls()
        XCTAssertEqual(calls.count, 2)
        XCTAssertTrue(calls.allSatisfy { $0.policy == .slackAsset })
    }

    func testSlackArrayAcceptsLocalPathAndFileFields() async throws {
        let workspace = try ImportingTestSupport.makeWorkspace()
        defer { try? FileManager.default.removeItem(at: workspace.root) }
        let packURL = workspace.root.appendingPathComponent(
            "Local Array",
            isDirectory: true
        )
        try FileManager.default.createDirectory(
            at: packURL,
            withIntermediateDirectories: false
        )
        _ = try TestSupport.writeImage(
            to: packURL.appendingPathComponent("one.png")
        )
        _ = try TestSupport.writeImage(
            to: packURL.appendingPathComponent("two.png"),
            width: 3,
            height: 3
        )
        let manifest = """
        [
          {"name": "bufo_one", "path": "one.png"},
          {"name": "bufo_two", "file": "two.png"}
        ]
        """
        try Data(manifest.utf8).write(
            to: packURL.appendingPathComponent("emoji.json")
        )

        let preparation = try await ImportOrchestrator(
            temporaryRootURL: workspace.temporaryRoot
        ).prepare(
            .folder(packURL),
            against: MojiPondLibrary()
        )

        XCTAssertEqual(
            preparation.preview.preparedPack.items.map(\.shortcode.rawValue),
            ["bufo_one", "bufo_two"]
        )
        XCTAssertTrue(preparation.preview.rejections.isEmpty)
    }

    func testRemoteSlackDownloadsRequireOptInAndRejectCredentials() async throws {
        let credentialURL =
            "https://user:password@emoji.example/private.png"
        let credentialManifest = Data(
            #"{"private":"\#(credentialURL)"}"#.utf8
        )
        do {
            _ = try SlackImportManifestParser.parse(credentialManifest)
            XCTFail("Expected credential-bearing URL rejection")
        } catch {
            XCTAssertEqual(
                error as? SlackImportManifestError,
                .unsafeAssetLocation(credentialURL)
            )
        }

        let workspace = try ImportingTestSupport.makeWorkspace()
        defer { try? FileManager.default.removeItem(at: workspace.root) }
        let packURL = workspace.root.appendingPathComponent(
            "Disabled Remote",
            isDirectory: true
        )
        try FileManager.default.createDirectory(
            at: packURL,
            withIntermediateDirectories: false
        )
        try Data(
            #"{"bufo":"https://emoji.example/bufo.png"}"#.utf8
        ).write(to: packURL.appendingPathComponent("emoji.json"))
        let transport = MockImportHTTPTransport()
        let preparation = try await ImportOrchestrator(
            transport: transport,
            temporaryRootURL: workspace.temporaryRoot
        ).prepare(
            .folder(packURL, allowRemoteSlackAssets: false),
            against: MojiPondLibrary()
        )

        XCTAssertTrue(preparation.preview.items.isEmpty)
        XCTAssertEqual(preparation.preview.rejections.count, 1)
        let calls = await transport.recordedCalls()
        XCTAssertTrue(calls.isEmpty)
    }

    func testRejectsSlackAliasCyclesAndTraversalPaths() throws {
        let cycle = Data(
            #"{"first":"alias:second","second":"alias:first"}"#.utf8
        )
        do {
            _ = try SlackImportManifestParser.parse(cycle)
            XCTFail("Expected alias cycle")
        } catch let SlackImportManifestError.aliasCycle(shortcodes) {
            XCTAssertEqual(
                shortcodes.map(\.rawValue),
                ["first", "second", "first"]
            )
        } catch {
            XCTFail("Unexpected error: \(error)")
        }

        let traversal = Data(#"{"bufo":"../outside.png"}"#.utf8)
        do {
            _ = try SlackImportManifestParser.parse(traversal)
            XCTFail("Expected traversal rejection")
        } catch {
            XCTAssertEqual(
                error as? SlackImportManifestError,
                .unsafeAssetLocation("../outside.png")
            )
        }
    }
}
