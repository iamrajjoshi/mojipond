import Foundation
import XCTest
@testable import MojiPond

final class MediaCommandCoordinatorTests: XCTestCase {
    func testOfflineStickerSearchNeverCallsNetwork() async throws {
        let searcher = MediaSearchStub(behaviors: [.results([])])
        let coordinator = try makeCoordinator(searcher: searcher)

        let state = await coordinator.search(
            command: .sticker,
            query: "pond",
            bundleIdentifier: messages,
            networkOptions: .offlineOnly
        )

        guard case let .results(results) = state else {
            return XCTFail("Expected bundled results, got \(state)")
        }
        XCTAssertEqual(results.items.map(\.id), ["noto-1f438"])
        XCTAssertEqual(results.attributions, [.notoAnimatedEmoji])
        let callCount = await searcher.numberOfCalls()
        XCTAssertEqual(callCount, 0)
    }

    func testGIFSearchRequiresExplicitNetworkOptIn() async throws {
        let searcher = MediaSearchStub(
            behaviors: [.results([remoteItem(provider: .giphy, id: "gif")])]
        )
        let coordinator = try makeCoordinator(searcher: searcher)

        let state = await coordinator.search(
            command: .gif,
            query: "frog",
            bundleIdentifier: messages,
            networkOptions: .offlineOnly
        )

        XCTAssertEqual(
            state,
            .networkDisabled(MediaCommandRequest(id: 1, command: .gif))
        )
        let callCount = await searcher.numberOfCalls()
        XCTAssertEqual(callCount, 0)
    }

    func testGIPHYResultsExposeRequiredAttribution() async throws {
        let searcher = MediaSearchStub(
            behaviors: [
                .results([remoteItem(provider: .giphy, id: "giphy-frog")])
            ]
        )
        let coordinator = try makeCoordinator(searcher: searcher)

        let state = await coordinator.search(
            command: .gif,
            query: "frog",
            bundleIdentifier: messages,
            networkOptions: network(giphy: true)
        )

        guard case let .results(results) = state else {
            return XCTFail("Expected GIPHY results, got \(state)")
        }
        XCTAssertEqual(results.items.map(\.id), ["giphy-frog"])
        XCTAssertEqual(results.attributions, [.giphy])
        XCTAssertEqual(results.items.first?.attribution, .giphy)
    }

    func testNetworkFailureSurfacesOfflineStickerFallback() async throws {
        let searcher = MediaSearchStub(
            behaviors: [.urlError(.notConnectedToInternet)]
        )
        let coordinator = try makeCoordinator(searcher: searcher)

        let state = await coordinator.search(
            command: .sticker,
            query: "frog",
            bundleIdentifier: messages,
            networkOptions: network(noto: true)
        )

        guard case let .offline(results) = state else {
            return XCTFail("Expected offline fallback, got \(state)")
        }
        XCTAssertEqual(results.items.map(\.id), ["noto-1f438"])
    }

    func testEmptyAndProviderErrorStatesAreExplicit() async throws {
        let invalidResponse = MediaSearchStub(
            behaviors: [.remoteError(.invalidResponse)]
        )
        let offlineCoordinator = try makeCoordinator(searcher: invalidResponse)

        let empty = await offlineCoordinator.search(
            command: .sticker,
            query: "no-such-sticker",
            bundleIdentifier: messages,
            networkOptions: .offlineOnly
        )
        XCTAssertEqual(
            empty,
            .empty(MediaCommandRequest(id: 1, command: .sticker))
        )

        let failed = await offlineCoordinator.search(
            command: .gif,
            query: "frog",
            bundleIdentifier: messages,
            networkOptions: network(giphy: true)
        )
        XCTAssertEqual(
            failed,
            .failed(
                MediaCommandRequest(id: 2, command: .gif),
                .invalidProviderResponse
            )
        )
    }

    func testRateLimitHasDedicatedState() async throws {
        let searcher = MediaSearchStub(
            behaviors: [.remoteError(.statusCode(429))]
        )
        let coordinator = try makeCoordinator(searcher: searcher)

        let state = await coordinator.search(
            command: .gif,
            query: "frog",
            bundleIdentifier: messages,
            networkOptions: network(giphy: true)
        )

        XCTAssertEqual(
            state,
            .rateLimited(MediaCommandRequest(id: 1, command: .gif))
        )
    }

    func testNonMessagesRequestIsCancelledBeforeProviderCall() async throws {
        let searcher = MediaSearchStub(
            behaviors: [
                .results([remoteItem(provider: .giphy, id: "unexpected")])
            ]
        )
        let coordinator = try makeCoordinator(searcher: searcher)

        let state = await coordinator.search(
            command: .gif,
            query: "private phrase",
            bundleIdentifier: "com.apple.TextEdit",
            networkOptions: network(giphy: true)
        )

        XCTAssertEqual(
            state,
            .cancelled(MediaCommandRequest(id: 1, command: .gif))
        )
        let callCount = await searcher.numberOfCalls()
        XCTAssertEqual(callCount, 0)
        XCTAssertFalse(String(reflecting: state).contains("private phrase"))
    }

    func testNewRequestCancelsAndCannotBeOverwrittenByStaleResult() async throws {
        let searcher = MediaSearchStub(
            behaviors: [
                .delayedResults(
                    .milliseconds(500),
                    [remoteItem(provider: .giphy, id: "stale")]
                ),
                .results([remoteItem(provider: .giphy, id: "fresh")])
            ]
        )
        let coordinator = try makeCoordinator(searcher: searcher)
        let bundleIdentifier = messages
        let options = network(giphy: true)

        let staleTask = Task {
            await coordinator.search(
                command: .gif,
                query: "first",
                bundleIdentifier: bundleIdentifier,
                networkOptions: options
            )
        }
        while await searcher.numberOfCalls() == 0 {
            await Task.yield()
        }
        let loadingState = await coordinator.currentState()
        XCTAssertEqual(
            loadingState,
            .loading(MediaCommandRequest(id: 1, command: .gif))
        )

        let fresh = await coordinator.search(
            command: .gif,
            query: "second",
            bundleIdentifier: bundleIdentifier,
            networkOptions: options
        )
        let stale = await staleTask.value

        XCTAssertEqual(
            stale,
            .cancelled(MediaCommandRequest(id: 1, command: .gif))
        )
        guard case let .results(freshResults) = fresh else {
            return XCTFail("Expected fresh results, got \(fresh)")
        }
        XCTAssertEqual(freshResults.request.id, 2)
        XCTAssertEqual(freshResults.items.map(\.id), ["fresh"])
        let currentState = await coordinator.currentState()
        XCTAssertEqual(currentState, fresh)
    }

    func testExplicitCancellationPublishesCancelledState() async throws {
        let searcher = MediaSearchStub(
            behaviors: [
                .delayedResults(
                    .seconds(1),
                    [remoteItem(provider: .giphy, id: "late")]
                )
            ]
        )
        let coordinator = try makeCoordinator(searcher: searcher)
        let bundleIdentifier = messages
        let options = network(giphy: true)
        let searchTask = Task {
            await coordinator.search(
                command: .gif,
                query: "frog",
                bundleIdentifier: bundleIdentifier,
                networkOptions: options
            )
        }
        while await searcher.numberOfCalls() == 0 {
            await Task.yield()
        }

        let cancelled = await coordinator.cancel()
        let completed = await searchTask.value

        XCTAssertEqual(
            cancelled,
            .cancelled(MediaCommandRequest(id: 1, command: .gif))
        )
        XCTAssertEqual(completed, cancelled)
        let currentState = await coordinator.currentState()
        XCTAssertEqual(currentState, cancelled)
    }

    func testOriginalRemoteGIFBytesAreNotReencoded() async throws {
        let originalBytes = Data([
            0x47, 0x49, 0x46, 0x38, 0x39, 0x61,
            0x01, 0x00, 0x01, 0x00, 0x3b
        ])
        let downloader = FixedRemoteDownloader(
            download: MediaCommandDownload(
                data: originalBytes,
                contentType: "image/gif",
                suggestedFilename: "original.gif"
            )
        )
        let coordinator = try makeCoordinator(
            searcher: nil,
            downloader: downloader
        )
        let result = MediaCommandResult(
            media: remoteItem(provider: .giphy, id: "original"),
            origin: .remote
        )

        let download = try await coordinator.resolve(result)

        XCTAssertEqual(download.data, originalBytes)
        XCTAssertEqual(download.contentType, "image/gif")
    }

    private var messages: String {
        MediaCommandParser.messagesBundleIdentifier
    }

    private func makeCoordinator(
        searcher: MediaSearchStub?,
        downloader: any MediaCommandRemoteDownloading =
            FixedRemoteDownloader(
                download: MediaCommandDownload(
                    data: Data(),
                    contentType: "image/gif",
                    suggestedFilename: "unused.gif"
                )
            )
    ) throws -> MediaCommandCoordinator {
        try MediaCommandCoordinator(
            offlineCatalog: NotoOfflineCatalog(
                resourceProvider: BundleNotoOfflineResourceProvider(
                    bundle: .main
                )
            ),
            stickerSearcher: searcher,
            gifSearcher: searcher,
            assetResolver: MediaCommandAssetResolver(
                remoteDownloader: downloader
            )
        )
    }

    private func network(
        noto: Bool = false,
        giphy: Bool = false
    ) -> MediaCommandNetworkOptions {
        MediaCommandNetworkOptions(
            allowsNotoNetwork: noto,
            allowsGIPHYNetwork: giphy
        )
    }

    private func remoteItem(
        provider: RemoteMediaProvider,
        id: String
    ) -> RemoteMediaItem {
        let preview = URL(string: "https://media.example/\(id)-preview.gif")!
        let original = URL(string: "https://media.example/\(id)-original.gif")!
        return RemoteMediaItem(
            id: id,
            provider: provider,
            title: id,
            previewURL: preview,
            originalURL: original,
            dimensions: RemoteMediaDimensions(width: 512, height: 512),
            attribution: provider == .giphy
                ? "Powered by GIPHY"
                : "Noto Animated Emoji by Google",
            analytics: nil
        )
    }
}

private actor MediaSearchStub:
    MediaCommandStickerSearching,
    MediaCommandGIFSearching
{
    enum Behavior: Sendable {
        case results([RemoteMediaItem])
        case delayedResults(Duration, [RemoteMediaItem])
        case remoteError(RemoteMediaError)
        case urlError(URLError.Code)
    }

    private let behaviors: [Behavior]
    private var callCount = 0

    init(behaviors: [Behavior]) {
        self.behaviors = behaviors
    }

    func search(_: String, limit: Int) async throws -> [RemoteMediaItem] {
        let behavior = behaviors.isEmpty
            ? Behavior.results([])
            : behaviors[min(callCount, behaviors.count - 1)]
        callCount += 1

        switch behavior {
        case let .results(items):
            return Array(items.prefix(limit))
        case let .delayedResults(delay, items):
            try await Task.sleep(for: delay)
            return Array(items.prefix(limit))
        case let .remoteError(error):
            throw error
        case let .urlError(code):
            throw URLError(code)
        }
    }

    func numberOfCalls() -> Int {
        callCount
    }
}

private struct FixedRemoteDownloader: MediaCommandRemoteDownloading {
    let download: MediaCommandDownload

    func downloadOriginal(
        _: RemoteMediaItem
    ) async throws -> MediaCommandDownload {
        download
    }
}
