import Foundation
import XCTest
@testable import MojiPond

final class RuntimeRemoteMediaCacheTests: XCTestCase {
    private var temporaryRoots: [URL] = []

    override func tearDownWithError() throws {
        for root in temporaryRoots {
            try? FileManager.default.removeItem(at: root)
        }
        temporaryRoots = []
    }

    func testNotoDiskCacheRoundTripsValidatedOriginalBytes() async throws {
        let root = temporaryRoot()
        let cache = RuntimeNotoMediaDiskCache(rootURL: root)
        let result = mediaResult(provider: .notoAnimatedEmoji)
        let download = gifDownload()

        try await cache.store(download, for: result)
        let cached = try await cache.cachedDownload(for: result)

        XCTAssertEqual(cached?.data, download.data)
        XCTAssertEqual(cached?.contentType, download.contentType)
        XCTAssertEqual(cached?.suggestedFilename.hasSuffix(".gif"), true)
    }

    func testGIPHYNeverTouchesPersistentMediaCache() async throws {
        let root = temporaryRoot()
        let cache = RuntimeNotoMediaDiskCache(rootURL: root)
        let result = mediaResult(provider: .giphy)

        try await cache.store(gifDownload(), for: result)
        let cached = try await cache.cachedDownload(for: result)

        XCTAssertNil(cached)
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.path))
    }

    func testNotoDiskCacheHonorsConfiguredByteBound() async throws {
        let root = temporaryRoot()
        let cache = RuntimeNotoMediaDiskCache(
            rootURL: root,
            maximumBytes: 1
        )
        let result = mediaResult(provider: .notoAnimatedEmoji)

        try await cache.store(gifDownload(), for: result)
        let cached = try await cache.cachedDownload(for: result)

        XCTAssertNil(cached)
    }

    func testResolverUsesNotoCacheButBypassesItForGIPHY() async throws {
        let cachedDownload = gifDownload()
        let cache = RuntimeRemoteMediaCacheSpy(cached: cachedDownload)
        let coordinator = RuntimeRemoteMediaCoordinatorSpy(
            download: gifDownload(suffix: "-network")
        )
        let resolver = RuntimeMediaDownloadResolver(
            coordinator: coordinator,
            cache: cache
        )

        let noto = try await resolver.resolve(
            mediaResult(provider: .notoAnimatedEmoji)
        )
        let resolveCountAfterNoto = await coordinator.resolveCount()
        let readCountAfterNoto = await cache.readCount()
        XCTAssertEqual(noto, cachedDownload)
        XCTAssertEqual(resolveCountAfterNoto, 0)
        XCTAssertEqual(readCountAfterNoto, 1)

        let giphy = try await resolver.resolve(
            mediaResult(provider: .giphy)
        )
        let resolveCountAfterGIPHY = await coordinator.resolveCount()
        let readCountAfterGIPHY = await cache.readCount()
        let writeCountAfterGIPHY = await cache.writeCount()
        XCTAssertEqual(giphy.data, gifDownload(suffix: "-network").data)
        XCTAssertEqual(resolveCountAfterGIPHY, 1)
        XCTAssertEqual(readCountAfterGIPHY, 1)
        XCTAssertEqual(writeCountAfterGIPHY, 0)
    }

    func testNotoCacheMissDownloadsThenStoresForNextSelection() async throws {
        let download = gifDownload()
        let cache = RuntimeRemoteMediaCacheSpy(cached: nil)
        let coordinator = RuntimeRemoteMediaCoordinatorSpy(
            download: download
        )
        let resolver = RuntimeMediaDownloadResolver(
            coordinator: coordinator,
            cache: cache
        )

        let resolved = try await resolver.resolve(
            mediaResult(provider: .notoAnimatedEmoji)
        )
        let resolveCount = await coordinator.resolveCount()
        let readCount = await cache.readCount()
        let writeCount = await cache.writeCount()

        XCTAssertEqual(resolved, download)
        XCTAssertEqual(resolveCount, 1)
        XCTAssertEqual(readCount, 1)
        XCTAssertEqual(writeCount, 1)
    }

    func testRuntimeNetworkPolicyDisablesURLCaching() {
        let session = RuntimeMediaNetworkPolicy.nonCachingSession()
        let request = RuntimeMediaNetworkPolicy.nonCachingRequest(
            for: URL(string: "https://media.giphy.com/example.gif")!
        )

        XCTAssertNil(session.configuration.urlCache)
        XCTAssertEqual(
            session.configuration.requestCachePolicy,
            .reloadIgnoringLocalCacheData
        )
        XCTAssertEqual(
            request.cachePolicy,
            .reloadIgnoringLocalCacheData
        )
    }

    func testAttributionPolicyAlwaysAddsProviderAttribution() {
        XCTAssertEqual(
            RuntimeMediaAttributionPolicy.normalized(
                items: [mediaResult(provider: .giphy)],
                declared: []
            ),
            [.giphy]
        )
        XCTAssertEqual(
            RuntimeMediaAttributionPolicy.normalized(
                items: [mediaResult(provider: .notoAnimatedEmoji)],
                declared: []
            ),
            [.notoAnimatedEmoji]
        )
    }

    private func temporaryRoot() -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "MojiPondRuntimeRemoteCache-\(UUID().uuidString)",
                isDirectory: true
            )
        temporaryRoots.append(root)
        return root
    }

    private func gifDownload(
        suffix: String = ""
    ) -> MediaCommandDownload {
        let base = Data(
            base64Encoded:
                "R0lGODlhAQABAIAAAAAAAP///ywAAAAAAQABAAACAUwAOw=="
        )!
        return MediaCommandDownload(
            data: base + Data(suffix.utf8),
            contentType: "image/gif",
            suggestedFilename: "original.gif"
        )
    }

    private func mediaResult(
        provider: RemoteMediaProvider
    ) -> MediaCommandResult {
        let url = URL(
            string: "https://media.example/\(provider.rawValue).gif"
        )!
        return MediaCommandResult(
            media: RemoteMediaItem(
                id: provider.rawValue,
                provider: provider,
                title: provider.rawValue,
                previewURL: url,
                originalURL: url,
                dimensions: nil,
                attribution: provider == .giphy
                    ? "Powered by GIPHY"
                    : "Noto Animated Emoji by Google",
                analytics: nil
            ),
            origin: .remote
        )
    }
}

private actor RuntimeRemoteMediaCacheSpy: RuntimeRemoteMediaCaching {
    private let cached: MediaCommandDownload?
    private var reads = 0
    private var writes = 0

    init(cached: MediaCommandDownload?) {
        self.cached = cached
    }

    func cachedDownload(
        for result: MediaCommandResult
    ) -> MediaCommandDownload? {
        _ = result
        reads += 1
        return cached
    }

    func store(
        _ download: MediaCommandDownload,
        for result: MediaCommandResult
    ) {
        _ = download
        _ = result
        writes += 1
    }

    func readCount() -> Int {
        reads
    }

    func writeCount() -> Int {
        writes
    }
}

private actor RuntimeRemoteMediaCoordinatorSpy:
    RuntimeMediaCommandCoordinating
{
    private let download: MediaCommandDownload
    private var resolutions = 0

    init(download: MediaCommandDownload) {
        self.download = download
    }

    func search(
        command: MediaCommandKind,
        query: String,
        bundleIdentifier: String?,
        networkOptions: MediaCommandNetworkOptions,
        limit: Int
    ) -> MediaCommandSearchState {
        _ = query
        _ = bundleIdentifier
        _ = networkOptions
        _ = limit
        return .empty(MediaCommandRequest(id: 1, command: command))
    }

    func cancel() -> MediaCommandSearchState {
        .idle
    }

    func resolve(
        _ result: MediaCommandResult
    ) -> MediaCommandDownload {
        _ = result
        resolutions += 1
        return download
    }

    func resolveCount() -> Int {
        resolutions
    }
}
