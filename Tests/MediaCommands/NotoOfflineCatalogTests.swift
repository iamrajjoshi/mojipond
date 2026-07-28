import Foundation
import XCTest
@testable import MojiPond

final class NotoOfflineCatalogTests: XCTestCase {
    func testBundledManifestValidatesAllPinnedAssets() throws {
        let catalog = try bundledCatalog()

        XCTAssertEqual(catalog.count, 16)
        let frogs = try catalog.search("pond")
        XCTAssertEqual(frogs.map(\.id), ["noto-1f438"])
        XCTAssertTrue(frogs.allSatisfy { result in
            if case .bundled = result.origin {
                return result.media.originalURL.isFileURL
            }
            return false
        })
    }

    func testSearchOrderingIsDeterministic() throws {
        let catalog = try bundledCatalog()

        let first = try catalog.search("heart").map(\.id)
        let second = try catalog.search("heart").map(\.id)

        XCTAssertEqual(first, second)
        XCTAssertEqual(first.first, "noto-2764_fe0f")
    }

    func testChangedDigestIsRejectedBeforeCatalogUse() throws {
        let base = BundleNotoOfflineResourceProvider(bundle: .main)
        let object = try XCTUnwrap(
            JSONSerialization.jsonObject(with: try base.manifestData())
                as? [String: Any]
        )
        var changed = object
        var assets = try XCTUnwrap(object["assets"] as? [[String: Any]])
        assets[0]["sha256"] = String(repeating: "0", count: 64)
        changed["assets"] = assets
        let changedData = try JSONSerialization.data(withJSONObject: changed)

        XCTAssertThrowsError(
            try NotoOfflineCatalog(
                resourceProvider: ManifestOverrideProvider(
                    manifest: changedData,
                    base: base
                )
            )
        ) { error in
            XCTAssertEqual(
                error as? NotoOfflineCatalogError,
                .assetCorrupt("gifs/1f602.gif")
            )
        }
    }

    func testBundledResolverReturnsThePinnedGIFBytes() async throws {
        let result = try XCTUnwrap(
            try bundledCatalog().search("frog").first
        )
        guard case let .bundled(asset) = result.origin else {
            return XCTFail("Expected a bundled result.")
        }
        let expected = try Data(contentsOf: asset.fileURL)
        let resolver = MediaCommandAssetResolver(
            remoteDownloader: UnexpectedRemoteDownloader()
        )

        let download = try await resolver.resolve(result)

        XCTAssertEqual(download.data, expected)
        XCTAssertEqual(download.contentType, "image/gif")
        XCTAssertEqual(download.suggestedFilename, "1f438.gif")
    }

    private func bundledCatalog() throws -> NotoOfflineCatalog {
        try NotoOfflineCatalog(
            resourceProvider: BundleNotoOfflineResourceProvider(bundle: .main)
        )
    }
}

private struct ManifestOverrideProvider: NotoOfflineResourceProviding {
    let manifest: Data
    let base: BundleNotoOfflineResourceProvider

    func manifestData() throws -> Data {
        manifest
    }

    func assetURL(for relativePath: String) throws -> URL {
        try base.assetURL(for: relativePath)
    }
}

private struct UnexpectedRemoteDownloader: MediaCommandRemoteDownloading {
    func downloadOriginal(
        _: RemoteMediaItem
    ) async throws -> MediaCommandDownload {
        throw UnexpectedRemoteDownloadError()
    }
}

private struct UnexpectedRemoteDownloadError: Error {}
