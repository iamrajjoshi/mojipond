import Foundation
import UniformTypeIdentifiers
import XCTest
@testable import MojiPond

@MainActor
final class LibraryThumbnailPipelineTests: XCTestCase {
    func testArtworkLoadStateDistinguishesFailureFromLoading() {
        XCTAssertEqual(
            LibraryArtworkLoadState.loading.accessibilityLabel,
            "Loading emoji preview"
        )
        XCTAssertNil(
            LibraryArtworkLoadState.loading.placeholderSymbolName
        )
        XCTAssertNil(
            LibraryArtworkLoadState.loaded.accessibilityLabel
        )
        XCTAssertEqual(
            LibraryArtworkLoadState.failed.accessibilityLabel,
            "Emoji preview unavailable"
        )
        XCTAssertEqual(
            LibraryArtworkLoadState.failed.placeholderSymbolName,
            "exclamationmark.triangle"
        )

        let disabledItem = LibraryDisplayItem(
            id: "custom.frog",
            origin: .builtIn,
            packName: "Pond Friends",
            packEnabled: false,
            shortcode: "frog",
            aliases: [],
            displayName: "Pond frog",
            tags: [],
            sourceFilename: nil,
            category: "Pond",
            unicode: nil,
            assetURL: URL(fileURLWithPath: "/private/tmp/frog.png"),
            format: .png,
            isAnimated: false,
            order: 0
        )
        XCTAssertEqual(
            LibraryItemAccessibility.label(
                for: disabledItem,
                artworkState: .failed
            ),
            "Pond frog, colon frog colon, image emoji, Pond Friends, "
                + "pack disabled, Emoji preview unavailable"
        )
        XCTAssertEqual(
            LibraryItemAccessibility.label(
                for: disabledItem,
                artworkState: .loaded,
                personalAliases: ["salute", "hi-wave"]
            ),
            "Pond frog, colon frog colon, image emoji, Pond Friends, "
                + "pack disabled, personal aliases, colon salute colon, "
                + "colon hi-wave colon"
        )
    }

    func testCandidateLoaderFallsBackFromInvalidThumbnailToOriginal()
        async throws
    {
        let workspace = try TestSupport.makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: workspace) }
        let invalidThumbnailURL = workspace.appendingPathComponent(
            "invalid-thumbnail.png"
        )
        try Data("not an image".utf8).write(to: invalidThumbnailURL)
        let originalURL = try TestSupport.writeImage(
            to: workspace.appendingPathComponent("original.png"),
            width: 80,
            height: 40
        )
        let pipeline = LibraryThumbnailPipeline(
            rootURL: workspace.appendingPathComponent(
                "Thumbnails",
                isDirectory: true
            )
        )

        let thumbnail = try await LibraryThumbnailCandidateLoader.thumbnail(
            primaryURL: invalidThumbnailURL,
            fallbackURL: originalURL,
            managedRootURL: workspace,
            using: pipeline
        )

        XCTAssertEqual(thumbnail.pixelWidth, 80)
        XCTAssertEqual(thumbnail.pixelHeight, 40)
    }

    func testCandidateLoaderRevalidatesAfterParentSymlinkSwap()
        async throws
    {
        let workspace = try TestSupport.makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: workspace) }
        let managedRoot = workspace.appendingPathComponent(
            "Library",
            isDirectory: true
        )
        let thumbnailDirectory = managedRoot.appendingPathComponent(
            "thumbnails",
            isDirectory: true
        )
        let originalDirectory = managedRoot.appendingPathComponent(
            "assets",
            isDirectory: true
        )
        try FileManager.default.createDirectory(
            at: thumbnailDirectory,
            withIntermediateDirectories: true
        )
        try FileManager.default.createDirectory(
            at: originalDirectory,
            withIntermediateDirectories: true
        )
        let primaryURL = try TestSupport.writeImage(
            to: thumbnailDirectory.appendingPathComponent("bufo.png"),
            width: 32,
            height: 24
        )
        let originalURL = try TestSupport.writeImage(
            to: originalDirectory.appendingPathComponent("bufo.png"),
            width: 80,
            height: 40
        )
        let externalRoot = workspace.appendingPathComponent(
            "External",
            isDirectory: true
        )
        try FileManager.default.createDirectory(
            at: externalRoot,
            withIntermediateDirectories: true
        )
        _ = try TestSupport.writeImage(
            to: externalRoot.appendingPathComponent("bufo.png"),
            width: 16,
            height: 16
        )
        let pipeline = LibraryThumbnailPipeline(
            rootURL: workspace.appendingPathComponent(
                "Cache",
                isDirectory: true
            )
        )

        let first = try await LibraryThumbnailCandidateLoader.thumbnail(
            primaryURL: primaryURL,
            fallbackURL: originalURL,
            managedRootURL: managedRoot,
            using: pipeline
        )
        XCTAssertEqual(first.pixelWidth, 32)
        XCTAssertEqual(first.pixelHeight, 24)

        try FileManager.default.removeItem(at: thumbnailDirectory)
        try FileManager.default.createSymbolicLink(
            at: thumbnailDirectory,
            withDestinationURL: externalRoot
        )

        let second = try await LibraryThumbnailCandidateLoader.thumbnail(
            primaryURL: primaryURL,
            fallbackURL: originalURL,
            managedRootURL: managedRoot,
            using: pipeline
        )
        XCTAssertEqual(second.pixelWidth, 80)
        XCTAssertEqual(second.pixelHeight, 40)
    }

    func testRendersOffMainActorAndReusesMemoryAndDiskCache()
        async throws
    {
        let workspace = try TestSupport.makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: workspace) }
        let sourceURL = try TestSupport.writeImage(
            to: workspace.appendingPathComponent("frog.png"),
            width: 800,
            height: 400
        )
        let cacheURL = workspace.appendingPathComponent(
            "Thumbnails",
            isDirectory: true
        )
        let renderer = RecordingThumbnailRenderer()
        let pipeline = LibraryThumbnailPipeline(
            rootURL: cacheURL,
            renderer: renderer
        )

        let first = try await pipeline.thumbnail(for: sourceURL)
        let second = try await pipeline.thumbnail(for: sourceURL)

        XCTAssertEqual(first.pixelWidth, 256)
        XCTAssertEqual(first.pixelHeight, 128)
        XCTAssertEqual(second.pixelWidth, first.pixelWidth)
        XCTAssertEqual(renderer.snapshot.invocationCount, 1)
        XCTAssertFalse(renderer.snapshot.renderedOnMainThread)
        let firstMetrics = await pipeline.metrics()
        XCTAssertEqual(
            firstMetrics,
            LibraryThumbnailCacheMetrics(
                memoryHits: 1,
                diskHits: 0,
                renders: 1
            )
        )

        let diskRenderer = RecordingThumbnailRenderer()
        let secondPipeline = LibraryThumbnailPipeline(
            rootURL: cacheURL,
            renderer: diskRenderer
        )
        let diskResult = try await secondPipeline.thumbnail(
            for: sourceURL
        )

        XCTAssertEqual(diskResult.pixelWidth, 256)
        XCTAssertEqual(diskRenderer.snapshot.invocationCount, 0)
        let diskMetrics = await secondPipeline.metrics()
        XCTAssertEqual(
            diskMetrics,
            LibraryThumbnailCacheMetrics(
                memoryHits: 0,
                diskHits: 1,
                renders: 0
            )
        )
        let cacheFiles = try FileManager.default.contentsOfDirectory(
            at: cacheURL,
            includingPropertiesForKeys: [.fileSizeKey]
        )
        XCTAssertEqual(cacheFiles.count, 1)
        XCTAssertEqual(cacheFiles.first?.pathExtension, "png")
        let cachedFileSize = try XCTUnwrap(
                cacheFiles.first?.resourceValues(
                    forKeys: [.fileSizeKey]
                ).fileSize
            )
        XCTAssertLessThanOrEqual(
            Int64(cachedFileSize),
            LibraryThumbnailLimits.default.maximumThumbnailBytes
        )
    }

    func testRendererEnforcesSourcePixelFrameAndAnimationBounds()
        throws
    {
        let workspace = try TestSupport.makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: workspace) }
        let stillURL = try TestSupport.writeImage(
            to: workspace.appendingPathComponent("wide.png"),
            width: 8,
            height: 4
        )
        let animationURL = try TestSupport.writeImage(
            to: workspace.appendingPathComponent("animated.gif"),
            format: .gif,
            width: 4,
            height: 4,
            frameCount: 3
        )
        let renderer = ImageIOLibraryThumbnailRenderer()

        var byteLimits = LibraryThumbnailLimits.default
        byteLimits.maximumSourceBytes = 1
        XCTAssertThrowsError(
            try renderer.render(
                sourceURL: stillURL,
                limits: byteLimits
            )
        ) {
            guard case .sourceTooLarge =
                $0 as? LibraryThumbnailError else {
                return XCTFail("Expected sourceTooLarge, got \($0)")
            }
        }

        var pixelLimits = LibraryThumbnailLimits.default
        pixelLimits.maximumPixelWidth = 7
        XCTAssertThrowsError(
            try renderer.render(
                sourceURL: stillURL,
                limits: pixelLimits
            )
        ) {
            guard case .dimensionsTooLarge =
                $0 as? LibraryThumbnailError else {
                return XCTFail("Expected dimensionsTooLarge, got \($0)")
            }
        }

        var frameLimits = LibraryThumbnailLimits.default
        frameLimits.maximumFrameCount = 2
        XCTAssertThrowsError(
            try renderer.render(
                sourceURL: animationURL,
                limits: frameLimits
            )
        ) {
            XCTAssertEqual(
                $0 as? LibraryThumbnailError,
                .invalidFrameCount(actual: 3, limit: 2)
            )
        }

        var animationLimits = LibraryThumbnailLimits.default
        animationLimits.maximumTotalAnimationPixels = 32
        XCTAssertThrowsError(
            try renderer.render(
                sourceURL: animationURL,
                limits: animationLimits
            )
        ) {
            XCTAssertEqual(
                $0 as? LibraryThumbnailError,
                .animationPixelBudgetExceeded(limit: 32)
            )
        }
    }

    func testStaticThumbnailUsesOnlyFirstAnimatedFrame() throws {
        let workspace = try TestSupport.makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: workspace) }
        let animationURL = try TestSupport.writeImage(
            to: workspace.appendingPathComponent("animated.gif"),
            format: .gif,
            width: 120,
            height: 80,
            frameCount: 3
        )
        var limits = LibraryThumbnailLimits.default
        limits.thumbnailPixelSize = 48

        let thumbnail = try ImageIOLibraryThumbnailRenderer().render(
            sourceURL: animationURL,
            limits: limits
        )

        XCTAssertLessThanOrEqual(thumbnail.pixelWidth, 48)
        XCTAssertLessThanOrEqual(thumbnail.pixelHeight, 48)
    }

    func testSourceReplacementInvalidatesOldFingerprintAndCacheEntry()
        async throws
    {
        let workspace = try TestSupport.makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: workspace) }
        let sourceURL = try TestSupport.writeImage(
            to: workspace.appendingPathComponent("frog.png"),
            width: 8,
            height: 4
        )
        let cacheURL = workspace.appendingPathComponent(
            "Thumbnails",
            isDirectory: true
        )
        let pipeline = LibraryThumbnailPipeline(rootURL: cacheURL)
        let first = try await pipeline.thumbnail(for: sourceURL)
        XCTAssertEqual(first.pixelWidth, 8)

        try FileManager.default.removeItem(at: sourceURL)
        _ = try TestSupport.writeImage(
            to: sourceURL,
            width: 4,
            height: 8
        )
        try FileManager.default.setAttributes(
            [.modificationDate: Date(timeIntervalSinceNow: 10)],
            ofItemAtPath: sourceURL.path
        )
        let replacement = try await pipeline.thumbnail(for: sourceURL)

        XCTAssertEqual(replacement.pixelWidth, 4)
        XCTAssertEqual(replacement.pixelHeight, 8)
        let metrics = await pipeline.metrics()
        XCTAssertEqual(metrics.renders, 2)
        XCTAssertEqual(
            try FileManager.default.contentsOfDirectory(
                at: cacheURL,
                includingPropertiesForKeys: nil
            ).count,
            1
        )
    }

    func testDeletedSourceCannotBeServedFromCacheAndCanBeInvalidated()
        async throws
    {
        let workspace = try TestSupport.makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: workspace) }
        let sourceURL = try TestSupport.writeImage(
            to: workspace.appendingPathComponent("frog.png")
        )
        let cacheURL = workspace.appendingPathComponent(
            "Thumbnails",
            isDirectory: true
        )
        let pipeline = LibraryThumbnailPipeline(rootURL: cacheURL)
        _ = try await pipeline.thumbnail(for: sourceURL)
        try FileManager.default.removeItem(at: sourceURL)

        do {
            _ = try await pipeline.thumbnail(for: sourceURL)
            XCTFail("Expected a deleted source to be rejected")
        } catch {
            XCTAssertTrue(error is CocoaError)
        }

        try await pipeline.invalidate(sourceURL: sourceURL)
        XCTAssertTrue(
            try FileManager.default.contentsOfDirectory(
                at: cacheURL,
                includingPropertiesForKeys: nil
            ).isEmpty
        )
    }

    func testDiskCachePrunesToConfiguredByteLimit() async throws {
        let workspace = try TestSupport.makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: workspace) }
        let sourceURL = try TestSupport.writeImage(
            to: workspace.appendingPathComponent("frog.png"),
            width: 32,
            height: 32
        )
        let cacheURL = workspace.appendingPathComponent(
            "Thumbnails",
            isDirectory: true
        )
        let pipeline = LibraryThumbnailPipeline(
            rootURL: cacheURL,
            maximumCacheBytes: 1,
            maximumMemoryEntries: 0
        )

        _ = try await pipeline.thumbnail(for: sourceURL)

        XCTAssertTrue(
            try FileManager.default.contentsOfDirectory(
                at: cacheURL,
                includingPropertiesForKeys: nil
            ).isEmpty
        )
    }

    func testViewModelItemAndPackRemovalReconcileManagedThumbnails()
        async throws
    {
        let workspace = try TestSupport.makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: workspace) }
        let paths = ApplicationPaths(
            applicationSupportBase: workspace.appendingPathComponent(
                "Application Support",
                isDirectory: true
            ),
            cachesBase: workspace.appendingPathComponent(
                "Caches",
                isDirectory: true
            )
        )
        let sourceDirectory = workspace.appendingPathComponent(
            "Sources",
            isDirectory: true
        )
        try FileManager.default.createDirectory(
            at: sourceDirectory,
            withIntermediateDirectories: true
        )
        let frogURL = try TestSupport.writeImage(
            to: sourceDirectory.appendingPathComponent("frog.png"),
            width: 8,
            height: 4
        )
        let toadURL = try TestSupport.writeImage(
            to: sourceDirectory.appendingPathComponent("toad.png"),
            width: 4,
            height: 8
        )
        let store = LibraryStore(rootURL: paths.libraryRoot)
        let pack = try await installThumbnailTestPack(
            files: [frogURL, toadURL],
            into: store
        )
        var managedURLs: [URL] = []
        for item in pack.items {
            let asset = try XCTUnwrap(item.payload.asset)
            managedURLs.append(
                try await store.assetURL(for: asset)
            )
        }
        let pipeline = LibraryThumbnailPipeline(
            rootURL: paths.cachesRoot.appendingPathComponent(
                "Library Thumbnails",
                isDirectory: true
            )
        )
        for url in managedURLs {
            _ = try await pipeline.thumbnail(for: url)
        }
        let initialCounts = try await pipeline.entryCounts()
        XCTAssertEqual(
            initialCounts,
            LibraryThumbnailCacheEntryCounts(memory: 2, disk: 2)
        )
        let viewModel = LibraryViewModel(
            store: store,
            paths: paths,
            thumbnailService: pipeline
        )

        viewModel.requestRemoveItem(
            packID: pack.id,
            item: pack.items[0]
        )
        await viewModel.confirmRemoval()

        let itemRemovalCounts = try await pipeline.entryCounts()
        XCTAssertEqual(
            itemRemovalCounts,
            LibraryThumbnailCacheEntryCounts(memory: 1, disk: 1)
        )

        viewModel.requestRemovePack(pack)
        await viewModel.confirmRemoval()

        let packRemovalCounts = try await pipeline.entryCounts()
        XCTAssertEqual(
            packRemovalCounts,
            LibraryThumbnailCacheEntryCounts(memory: 0, disk: 0)
        )
    }

    func testReconcilePreventsLateRenderFromRepopulatingDeletedCache()
        async throws
    {
        let workspace = try TestSupport.makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: workspace) }
        let sourceURL = try TestSupport.writeImage(
            to: workspace.appendingPathComponent("frog.png")
        )
        let renderer = BlockingThumbnailRenderer()
        let pipeline = LibraryThumbnailPipeline(
            rootURL: workspace.appendingPathComponent(
                "Thumbnails",
                isDirectory: true
            ),
            renderer: renderer
        )
        let loadTask = Task {
            try await pipeline.thumbnail(for: sourceURL)
        }
        await fulfillment(
            of: [renderer.started],
            timeout: 2
        )

        try await pipeline.reconcile(retaining: [])
        renderer.release()

        do {
            _ = try await loadTask.value
            XCTFail("Expected invalidated render to be discarded")
        } catch {
            XCTAssertTrue(error is CancellationError)
        }
        let entryCounts = try await pipeline.entryCounts()
        XCTAssertEqual(
            entryCounts,
            LibraryThumbnailCacheEntryCounts(memory: 0, disk: 0)
        )
    }
}

private final class RecordingThumbnailRenderer:
    LibraryThumbnailRendering,
    @unchecked Sendable
{
    struct Snapshot {
        let invocationCount: Int
        let renderedOnMainThread: Bool
    }

    private let lock = NSLock()
    private var invocationCount = 0
    private var renderedOnMainThread = false
    private let renderer = ImageIOLibraryThumbnailRenderer()

    var snapshot: Snapshot {
        lock.lock()
        defer { lock.unlock() }
        return Snapshot(
            invocationCount: invocationCount,
            renderedOnMainThread: renderedOnMainThread
        )
    }

    func render(
        sourceURL: URL,
        limits: LibraryThumbnailLimits
    ) throws -> LibraryThumbnail {
        lock.lock()
        invocationCount += 1
        renderedOnMainThread =
            renderedOnMainThread || Thread.isMainThread
        lock.unlock()
        return try renderer.render(
            sourceURL: sourceURL,
            limits: limits
        )
    }
}

private final class BlockingThumbnailRenderer:
    LibraryThumbnailRendering,
    @unchecked Sendable
{
    let started = XCTestExpectation(
        description: "thumbnail render started"
    )

    private let gate = DispatchSemaphore(value: 0)
    private let renderer = ImageIOLibraryThumbnailRenderer()

    func release() {
        gate.signal()
    }

    func render(
        sourceURL: URL,
        limits: LibraryThumbnailLimits
    ) throws -> LibraryThumbnail {
        started.fulfill()
        gate.wait()
        return try renderer.render(
            sourceURL: sourceURL,
            limits: limits
        )
    }
}

private func installThumbnailTestPack(
    files: [URL],
    into store: LibraryStore
) async throws -> EmojiPack {
    let scan = try ImportScanner().scanFiles(
        files,
        packName: "Thumbnail frogs"
    )
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
