import AppKit
import ImageIO
import UniformTypeIdentifiers
import XCTest
@testable import MojiPond

@MainActor
final class AdaptiveGlyphPayloadBuilderTests: XCTestCase {
    func testEncoderPrewarmSourceMatchesTransparentCustomEmojiPath()
        throws
    {
        let data = try XCTUnwrap(
            AdaptiveGlyphPayloadBuilder.makeEncoderPrewarmPNG()
        )
        let source = try XCTUnwrap(
            CGImageSourceCreateWithData(data as CFData, nil)
        )
        XCTAssertEqual(
            CGImageSourceGetType(source) as String?,
            UTType.png.identifier
        )
        XCTAssertEqual(CGImageSourceGetCount(source), 1)
        let properties = try XCTUnwrap(
            CGImageSourceCopyPropertiesAtIndex(
                source,
                0,
                nil
            ) as? [CFString: Any]
        )
        XCTAssertEqual(properties[kCGImagePropertyPixelWidth] as? Int, 128)
        XCTAssertEqual(properties[kCGImagePropertyPixelHeight] as? Int, 128)
        XCTAssertEqual(properties[kCGImagePropertyHasAlpha] as? Bool, true)
    }

    func testPayloadCacheBuildsOnceForRepeatedKey() {
        var cache = AdaptiveGlyphPayloadCache()
        let key = cacheKey(contentIdentifier: "mojipond:hash:bufo")
        let expected = PasteboardItemPayload.text("cached")
        var buildCount = 0

        let first = cache.payload(for: key) {
            buildCount += 1
            return expected
        }
        let second = cache.payload(for: key) {
            buildCount += 1
            return PasteboardItemPayload.text("rebuilt")
        }

        XCTAssertEqual(first, expected)
        XCTAssertEqual(second, expected)
        XCTAssertEqual(buildCount, 1)
    }

    func testPayloadCacheSeparatesMetadataAndSourceTypes() {
        var cache = AdaptiveGlyphPayloadCache()
        let keys = [
            cacheKey(contentIdentifier: "mojipond:first:bufo"),
            cacheKey(contentIdentifier: "mojipond:second:bufo"),
            cacheKey(
                contentIdentifier: "mojipond:first:bufo",
                sourceType: .jpeg
            ),
            cacheKey(
                contentIdentifier: "mojipond:first:bufo",
                accessibilityDescription: ":different:"
            )
        ]
        var buildCount = 0

        for key in keys {
            _ = cache.payload(for: key) {
                buildCount += 1
                return PasteboardItemPayload.text("\(buildCount)")
            }
        }

        XCTAssertEqual(buildCount, keys.count)
    }

    func testPayloadCacheRetriesFailuresAndEvictsLeastRecentlyUsedEntry() {
        var cache = AdaptiveGlyphPayloadCache(
            countLimit: 2,
            byteLimit: 1_024
        )
        let firstKey = cacheKey(contentIdentifier: "mojipond:first:bufo")
        let secondKey = cacheKey(contentIdentifier: "mojipond:second:bufo")
        let thirdKey = cacheKey(contentIdentifier: "mojipond:third:bufo")
        var failedBuildCount = 0

        XCTAssertNil(
            cache.payload(for: firstKey) {
                failedBuildCount += 1
                return nil
            }
        )
        XCTAssertNil(
            cache.payload(for: firstKey) {
                failedBuildCount += 1
                return nil
            }
        )
        XCTAssertEqual(failedBuildCount, 2)

        _ = cache.payload(for: firstKey) {
            PasteboardItemPayload.text("first")
        }
        _ = cache.payload(for: secondKey) {
            PasteboardItemPayload.text("second")
        }
        _ = cache.payload(for: firstKey) {
            XCTFail("A cache hit should not rebuild the first payload.")
            return nil
        }
        _ = cache.payload(for: thirdKey) {
            PasteboardItemPayload.text("third")
        }

        var secondBuildCount = 0
        _ = cache.payload(for: secondKey) {
            secondBuildCount += 1
            return PasteboardItemPayload.text("second rebuilt")
        }
        XCTAssertEqual(secondBuildCount, 1)
    }

    func testPayloadCacheHonorsByteLimit() {
        var cache = AdaptiveGlyphPayloadCache(
            countLimit: 10,
            byteLimit: 6
        )
        let firstKey = cacheKey(contentIdentifier: "mojipond:first:bufo")
        let secondKey = cacheKey(contentIdentifier: "mojipond:second:bufo")

        _ = cache.payload(for: firstKey) {
            PasteboardItemPayload.text("1234")
        }
        _ = cache.payload(for: secondKey) {
            PasteboardItemPayload.text("5678")
        }

        var firstBuildCount = 0
        _ = cache.payload(for: firstKey) {
            firstBuildCount += 1
            return PasteboardItemPayload.text("1234")
        }
        XCTAssertEqual(firstBuildCount, 1)
    }

    func testPayloadServiceBuildsOffMainThreadAndReusesPreparedPayload()
        async
    {
        let recorder = AdaptiveGlyphBuilderRecorder()
        let expected = PasteboardItemPayload.text("prepared")
        let service = AdaptiveGlyphPayloadService(
            queueLabel: "MojiPondTests.AdaptiveGlyphPayloadService",
            builder: { request in
                recorder.recordBuild()
                XCTAssertEqual(request.sourceType, .png)
                return expected
            }
        )
        let request = AdaptiveGlyphPayloadRequest(
            sourceData: Data("png".utf8),
            sourceType: .png,
            contentIdentifier: "mojipond:hash:prepared",
            accessibilityDescription: ":prepared:",
            plainTextFallback: ":prepared:"
        )

        await withCheckedContinuation { continuation in
            service.prepare(request) {
                continuation.resume()
            }
        }
        let payload = await withCheckedContinuation { continuation in
            service.payload(for: request) {
                continuation.resume(returning: $0)
            }
        }

        XCTAssertEqual(payload, expected)
        XCTAssertEqual(recorder.buildCount, 1)
        XCTAssertFalse(recorder.builtOnMainThread)
    }

    func testExplicitPayloadDoesNotWaitBehindRunningPreparation() {
        let recorder = AdaptiveGlyphBuilderRecorder()
        let preparationStarted = DispatchSemaphore(value: 0)
        let releasePreparation = DispatchSemaphore(value: 0)
        let preparationCompleted = DispatchSemaphore(value: 0)
        let explicitCompleted = DispatchSemaphore(value: 0)
        let speculative = payloadRequest("speculative")
        let explicit = payloadRequest("explicit")
        let service = AdaptiveGlyphPayloadService(
            queueLabel: "MojiPondTests.AdaptiveGlyphPayloadService.Priority",
            builder: { request in
                recorder.recordBuild(request.contentIdentifier)
                if request.cacheKey == speculative.cacheKey {
                    preparationStarted.signal()
                    _ = releasePreparation.wait(
                        timeout: .now() + 5
                    )
                }
                return .text(request.contentIdentifier)
            }
        )

        service.prepare(
            for: speculative.cacheKey,
            loader: {
                recorder.recordLoad(speculative.contentIdentifier)
                return speculative
            },
            completion: {
                preparationCompleted.signal()
            }
        )
        XCTAssertEqual(
            preparationStarted.wait(timeout: .now() + 2),
            .success
        )

        service.payload(for: explicit) { _ in
            explicitCompleted.signal()
        }
        let explicitResult = explicitCompleted.wait(
            timeout: .now() + 2
        )
        releasePreparation.signal()
        let preparationResult = preparationCompleted.wait(
            timeout: .now() + 2
        )

        XCTAssertEqual(explicitResult, .success)
        XCTAssertEqual(preparationResult, .success)
        XCTAssertEqual(
            recorder.buildCount(for: explicit.contentIdentifier),
            1
        )
    }

    func testSameKeyInFlightPayloadRequestsCoalesceAheadOfQueuedWork() {
        let recorder = AdaptiveGlyphBuilderRecorder()
        let firstStarted = DispatchSemaphore(value: 0)
        let releaseFirst = DispatchSemaphore(value: 0)
        let releaseUnrelated = DispatchSemaphore(value: 0)
        let firstCompleted = DispatchSemaphore(value: 0)
        let coalescedCompleted = DispatchSemaphore(value: 0)
        let unrelatedCompleted = DispatchSemaphore(value: 0)
        let first = payloadRequest("same-key")
        let unrelated = payloadRequest("unrelated")
        let service = AdaptiveGlyphPayloadService(
            queueLabel:
                "MojiPondTests.AdaptiveGlyphPayloadService.Coalescing",
            builder: { request in
                recorder.recordBuild(request.contentIdentifier)
                if request.cacheKey == first.cacheKey {
                    firstStarted.signal()
                    _ = releaseFirst.wait(timeout: .now() + 5)
                } else if request.cacheKey == unrelated.cacheKey {
                    _ = releaseUnrelated.wait(timeout: .now() + 5)
                }
                return .text(request.contentIdentifier)
            }
        )

        service.payload(for: first) { _ in
            firstCompleted.signal()
        }
        XCTAssertEqual(
            firstStarted.wait(timeout: .now() + 2),
            .success
        )
        service.payload(for: unrelated) { _ in
            unrelatedCompleted.signal()
        }
        service.payload(for: first) { _ in
            coalescedCompleted.signal()
        }

        releaseFirst.signal()
        let firstResult = firstCompleted.wait(timeout: .now() + 2)
        let coalescedResult = coalescedCompleted.wait(
            timeout: .now() + 2
        )
        releaseUnrelated.signal()
        let unrelatedResult = unrelatedCompleted.wait(
            timeout: .now() + 2
        )

        XCTAssertEqual(firstResult, .success)
        XCTAssertEqual(coalescedResult, .success)
        XCTAssertEqual(unrelatedResult, .success)
        XCTAssertEqual(
            recorder.buildCount(for: first.contentIdentifier),
            1
        )
    }

    func testExplicitPayloadKeepsOnlyNewestDifferentKeyPendingRequest() {
        let recorder = AdaptiveGlyphBuilderRecorder()
        let runningStarted = DispatchSemaphore(value: 0)
        let releaseRunning = DispatchSemaphore(value: 0)
        let runningCompleted = DispatchSemaphore(value: 0)
        let replacedPayloadCompleted = DispatchSemaphore(value: 0)
        let replacedPreparationCompleted = DispatchSemaphore(value: 0)
        let newestCompleted = DispatchSemaphore(value: 0)
        let running = payloadRequest("running-explicit")
        let replaced = payloadRequest("replaced-explicit")
        let newest = payloadRequest("newest-explicit")
        let service = AdaptiveGlyphPayloadService(
            queueLabel:
                "MojiPondTests.AdaptiveGlyphPayloadService.ExplicitReplacement",
            builder: { request in
                recorder.recordBuild(request.contentIdentifier)
                if request.cacheKey == running.cacheKey {
                    runningStarted.signal()
                    _ = releaseRunning.wait(timeout: .now() + 5)
                }
                return .text(request.contentIdentifier)
            }
        )

        service.payload(for: running) { _ in
            runningCompleted.signal()
        }
        XCTAssertEqual(
            runningStarted.wait(timeout: .now() + 2),
            .success
        )
        service.payload(for: replaced) { payload in
            XCTAssertNil(payload)
            replacedPayloadCompleted.signal()
        }
        service.prepare(replaced) {
            replacedPreparationCompleted.signal()
        }
        service.payload(for: newest) { _ in
            newestCompleted.signal()
        }

        let replacedPayloadResult = replacedPayloadCompleted.wait(
            timeout: .now() + 0.5
        )
        let replacedPreparationResult =
            replacedPreparationCompleted.wait(timeout: .now() + 0.5)
        let replacedBuildCount = recorder.buildCount(
            for: replaced.contentIdentifier
        )
        releaseRunning.signal()
        let runningResult = runningCompleted.wait(timeout: .now() + 2)
        let newestResult = newestCompleted.wait(timeout: .now() + 2)

        XCTAssertEqual(replacedPayloadResult, .success)
        XCTAssertEqual(replacedPreparationResult, .success)
        XCTAssertEqual(runningResult, .success)
        XCTAssertEqual(newestResult, .success)
        XCTAssertEqual(replacedBuildCount, 0)
        XCTAssertEqual(
            recorder.buildCount(for: replaced.contentIdentifier),
            0
        )
        XCTAssertEqual(
            recorder.buildCount(for: newest.contentIdentifier),
            1
        )
    }

    func testNewRunningSameKeyRequestDiscardsOlderPendingPayload() {
        let recorder = AdaptiveGlyphBuilderRecorder()
        let runningStarted = DispatchSemaphore(value: 0)
        let releaseRunning = DispatchSemaphore(value: 0)
        let firstRunningCompleted = DispatchSemaphore(value: 0)
        let pendingCompleted = DispatchSemaphore(value: 0)
        let coalescedRunningCompleted = DispatchSemaphore(value: 0)
        let running = payloadRequest("new-running-same-key")
        let pending = payloadRequest("older-pending-different-key")
        let expected = PasteboardItemPayload.text("running payload")
        let service = AdaptiveGlyphPayloadService(
            queueLabel:
                "MojiPondTests.AdaptiveGlyphPayloadService.RunningCoalescing",
            builder: { request in
                recorder.recordBuild(request.contentIdentifier)
                if request.cacheKey == running.cacheKey {
                    runningStarted.signal()
                    _ = releaseRunning.wait(timeout: .now() + 5)
                    return expected
                }
                return .text("stale pending payload")
            }
        )

        service.payload(for: running) { payload in
            XCTAssertEqual(payload, expected)
            firstRunningCompleted.signal()
        }
        XCTAssertEqual(
            runningStarted.wait(timeout: .now() + 2),
            .success
        )
        service.payload(for: pending) { payload in
            XCTAssertNil(payload)
            pendingCompleted.signal()
        }
        service.payload(for: running) { payload in
            XCTAssertEqual(payload, expected)
            coalescedRunningCompleted.signal()
        }

        let pendingBeforeRunningFinishes = pendingCompleted.wait(
            timeout: .now() + 0.5
        )
        releaseRunning.signal()
        let firstRunningResult = firstRunningCompleted.wait(
            timeout: .now() + 2
        )
        let coalescedRunningResult = coalescedRunningCompleted.wait(
            timeout: .now() + 2
        )

        XCTAssertEqual(pendingBeforeRunningFinishes, .success)
        XCTAssertEqual(firstRunningResult, .success)
        XCTAssertEqual(coalescedRunningResult, .success)
        XCTAssertEqual(
            recorder.buildCount(for: running.contentIdentifier),
            1
        )
        XCTAssertEqual(
            recorder.buildCount(for: pending.contentIdentifier),
            0
        )
    }

    func testCachedPayloadDiscardsOlderDifferentKeyPendingPayload() {
        let recorder = AdaptiveGlyphBuilderRecorder()
        let cachedPrepared = DispatchSemaphore(value: 0)
        let runningStarted = DispatchSemaphore(value: 0)
        let releaseRunning = DispatchSemaphore(value: 0)
        let runningCompleted = DispatchSemaphore(value: 0)
        let pendingCompleted = DispatchSemaphore(value: 0)
        let cachedCompleted = DispatchSemaphore(value: 0)
        let cached = payloadRequest("cached-newest")
        let running = payloadRequest("cached-running")
        let pending = payloadRequest("cached-stale-pending")
        let expected = PasteboardItemPayload.text("cached payload")
        let service = AdaptiveGlyphPayloadService(
            queueLabel:
                "MojiPondTests.AdaptiveGlyphPayloadService.CachedSupersession",
            builder: { request in
                recorder.recordBuild(request.contentIdentifier)
                if request.cacheKey == running.cacheKey {
                    runningStarted.signal()
                    _ = releaseRunning.wait(timeout: .now() + 5)
                }
                if request.cacheKey == cached.cacheKey {
                    return expected
                }
                return .text(request.contentIdentifier)
            }
        )

        service.prepare(cached) {
            cachedPrepared.signal()
        }
        XCTAssertEqual(
            cachedPrepared.wait(timeout: .now() + 2),
            .success
        )
        service.payload(for: running) { _ in
            runningCompleted.signal()
        }
        XCTAssertEqual(
            runningStarted.wait(timeout: .now() + 2),
            .success
        )
        service.payload(for: pending) { payload in
            XCTAssertNil(payload)
            pendingCompleted.signal()
        }
        service.payload(for: cached) { payload in
            XCTAssertEqual(payload, expected)
            cachedCompleted.signal()
        }

        let pendingBeforeRunningFinishes = pendingCompleted.wait(
            timeout: .now() + 0.5
        )
        let cachedResult = cachedCompleted.wait(timeout: .now() + 2)
        releaseRunning.signal()
        let runningResult = runningCompleted.wait(timeout: .now() + 2)

        XCTAssertEqual(pendingBeforeRunningFinishes, .success)
        XCTAssertEqual(cachedResult, .success)
        XCTAssertEqual(runningResult, .success)
        XCTAssertEqual(
            recorder.buildCount(for: cached.contentIdentifier),
            1
        )
        XCTAssertEqual(
            recorder.buildCount(for: pending.contentIdentifier),
            0
        )
    }

    func testPreparationJoinDiscardsOlderDifferentKeyPendingPayload() {
        let recorder = AdaptiveGlyphBuilderRecorder()
        let preparationStarted = DispatchSemaphore(value: 0)
        let releasePreparation = DispatchSemaphore(value: 0)
        let preparationCompleted = DispatchSemaphore(value: 0)
        let runningStarted = DispatchSemaphore(value: 0)
        let releaseRunning = DispatchSemaphore(value: 0)
        let runningCompleted = DispatchSemaphore(value: 0)
        let pendingCompleted = DispatchSemaphore(value: 0)
        let joinedCompleted = DispatchSemaphore(value: 0)
        let prepared = payloadRequest("prepared-newest")
        let running = payloadRequest("prepared-running")
        let pending = payloadRequest("prepared-stale-pending")
        let expected = PasteboardItemPayload.text("prepared payload")
        let service = AdaptiveGlyphPayloadService(
            queueLabel:
                "MojiPondTests.AdaptiveGlyphPayloadService.PreparedSupersession",
            builder: { request in
                recorder.recordBuild(request.contentIdentifier)
                if request.cacheKey == prepared.cacheKey {
                    preparationStarted.signal()
                    _ = releasePreparation.wait(timeout: .now() + 5)
                    return expected
                }
                if request.cacheKey == running.cacheKey {
                    runningStarted.signal()
                    _ = releaseRunning.wait(timeout: .now() + 5)
                }
                return .text(request.contentIdentifier)
            }
        )

        service.prepare(prepared) {
            preparationCompleted.signal()
        }
        XCTAssertEqual(
            preparationStarted.wait(timeout: .now() + 2),
            .success
        )
        service.payload(for: running) { _ in
            runningCompleted.signal()
        }
        XCTAssertEqual(
            runningStarted.wait(timeout: .now() + 2),
            .success
        )
        service.payload(for: pending) { payload in
            XCTAssertNil(payload)
            pendingCompleted.signal()
        }
        service.payload(for: prepared) { payload in
            XCTAssertEqual(payload, expected)
            joinedCompleted.signal()
        }

        let pendingBeforeWorkFinishes = pendingCompleted.wait(
            timeout: .now() + 0.5
        )
        releasePreparation.signal()
        let preparationResult = preparationCompleted.wait(
            timeout: .now() + 2
        )
        let joinedResult = joinedCompleted.wait(timeout: .now() + 2)
        releaseRunning.signal()
        let runningResult = runningCompleted.wait(timeout: .now() + 2)

        XCTAssertEqual(pendingBeforeWorkFinishes, .success)
        XCTAssertEqual(preparationResult, .success)
        XCTAssertEqual(joinedResult, .success)
        XCTAssertEqual(runningResult, .success)
        XCTAssertEqual(
            recorder.buildCount(for: prepared.contentIdentifier),
            1
        )
        XCTAssertEqual(
            recorder.buildCount(for: pending.contentIdentifier),
            0
        )
    }

    func testExplicitPayloadRetriesFailedSameKeyPreparation() {
        let recorder = AdaptiveGlyphBuilderRecorder()
        let preparationStarted = DispatchSemaphore(value: 0)
        let releasePreparation = DispatchSemaphore(value: 0)
        let preparationCompleted = DispatchSemaphore(value: 0)
        let explicitCompleted = DispatchSemaphore(value: 0)
        let speculative = payloadRequest("retry-after-preparation")
        let explicit = AdaptiveGlyphPayloadRequest(
            sourceData: Data("explicit source".utf8),
            sourceType: speculative.sourceType,
            contentIdentifier: speculative.contentIdentifier,
            accessibilityDescription:
                speculative.accessibilityDescription,
            plainTextFallback: speculative.plainTextFallback
        )
        let expected = PasteboardItemPayload.text("explicit retry")
        let service = AdaptiveGlyphPayloadService(
            queueLabel:
                "MojiPondTests.AdaptiveGlyphPayloadService.PreparationRetry",
            builder: { request in
                recorder.recordBuild(request.contentIdentifier)
                if request.sourceData == speculative.sourceData {
                    preparationStarted.signal()
                    _ = releasePreparation.wait(timeout: .now() + 5)
                    return nil
                }
                return expected
            }
        )

        service.prepare(speculative) {
            preparationCompleted.signal()
        }
        XCTAssertEqual(
            preparationStarted.wait(timeout: .now() + 2),
            .success
        )
        service.payload(for: explicit) { payload in
            XCTAssertEqual(payload, expected)
            explicitCompleted.signal()
        }

        releasePreparation.signal()
        let explicitResult = explicitCompleted.wait(timeout: .now() + 2)
        let preparationResult = preparationCompleted.wait(
            timeout: .now() + 2
        )

        XCTAssertEqual(explicitResult, .success)
        XCTAssertEqual(preparationResult, .success)
        XCTAssertEqual(
            recorder.buildCount(for: explicit.contentIdentifier),
            2
        )
    }

    func testOlderFailedPreparationRetryKeepsNewerPendingPayload() {
        let recorder = AdaptiveGlyphBuilderRecorder()
        let runningStarted = DispatchSemaphore(value: 0)
        let releaseRunning = DispatchSemaphore(value: 0)
        let runningCompleted = DispatchSemaphore(value: 0)
        let preparationStarted = DispatchSemaphore(value: 0)
        let releasePreparation = DispatchSemaphore(value: 0)
        let preparationCompleted = DispatchSemaphore(value: 0)
        let olderCompleted = DispatchSemaphore(value: 0)
        let newerCompleted = DispatchSemaphore(value: 0)
        let running = payloadRequest("ordering-running")
        let speculative = payloadRequest("ordering-older")
        let older = AdaptiveGlyphPayloadRequest(
            sourceData: Data("older explicit source".utf8),
            sourceType: speculative.sourceType,
            contentIdentifier: speculative.contentIdentifier,
            accessibilityDescription:
                speculative.accessibilityDescription,
            plainTextFallback: speculative.plainTextFallback
        )
        let newer = payloadRequest("ordering-newer")
        let expectedNewer = PasteboardItemPayload.text("newer payload")
        let service = AdaptiveGlyphPayloadService(
            queueLabel:
                "MojiPondTests.AdaptiveGlyphPayloadService.OlderRetry",
            builder: { request in
                recorder.recordBuild(request.contentIdentifier)
                if request.cacheKey == running.cacheKey {
                    runningStarted.signal()
                    _ = releaseRunning.wait(timeout: .now() + 5)
                } else if request.sourceData == speculative.sourceData {
                    preparationStarted.signal()
                    _ = releasePreparation.wait(timeout: .now() + 5)
                    return nil
                }
                if request.cacheKey == newer.cacheKey {
                    return expectedNewer
                }
                return .text("older retry")
            }
        )

        service.payload(for: running) { _ in
            runningCompleted.signal()
        }
        service.prepare(speculative) {
            preparationCompleted.signal()
        }
        XCTAssertEqual(
            runningStarted.wait(timeout: .now() + 2),
            .success
        )
        XCTAssertEqual(
            preparationStarted.wait(timeout: .now() + 2),
            .success
        )

        service.payload(for: older) { payload in
            XCTAssertNil(payload)
            olderCompleted.signal()
        }
        service.payload(for: newer) { payload in
            XCTAssertEqual(payload, expectedNewer)
            newerCompleted.signal()
        }
        releasePreparation.signal()

        let olderBeforeRunningFinishes = olderCompleted.wait(
            timeout: .now() + 0.5
        )
        let preparationBeforeRunningFinishes =
            preparationCompleted.wait(timeout: .now() + 0.5)
        releaseRunning.signal()
        let runningResult = runningCompleted.wait(timeout: .now() + 2)
        let newerResult = newerCompleted.wait(timeout: .now() + 2)
        if olderBeforeRunningFinishes == .timedOut {
            _ = olderCompleted.wait(timeout: .now() + 2)
        }
        if preparationBeforeRunningFinishes == .timedOut {
            _ = preparationCompleted.wait(timeout: .now() + 2)
        }

        XCTAssertEqual(olderBeforeRunningFinishes, .success)
        XCTAssertEqual(preparationBeforeRunningFinishes, .success)
        XCTAssertEqual(runningResult, .success)
        XCTAssertEqual(newerResult, .success)
        XCTAssertEqual(
            recorder.buildCount(for: speculative.contentIdentifier),
            1
        )
        XCTAssertEqual(
            recorder.buildCount(for: newer.contentIdentifier),
            1
        )
    }

    func testNewerFailedPreparationRetryReplacesOlderPendingPayload() {
        let recorder = AdaptiveGlyphBuilderRecorder()
        let runningStarted = DispatchSemaphore(value: 0)
        let releaseRunning = DispatchSemaphore(value: 0)
        let runningCompleted = DispatchSemaphore(value: 0)
        let preparationStarted = DispatchSemaphore(value: 0)
        let releasePreparation = DispatchSemaphore(value: 0)
        let preparationCompleted = DispatchSemaphore(value: 0)
        let olderCompleted = DispatchSemaphore(value: 0)
        let newerCompleted = DispatchSemaphore(value: 0)
        let running = payloadRequest("reverse-ordering-running")
        let speculative = payloadRequest("reverse-ordering-newer")
        let newer = AdaptiveGlyphPayloadRequest(
            sourceData: Data("newer explicit source".utf8),
            sourceType: speculative.sourceType,
            contentIdentifier: speculative.contentIdentifier,
            accessibilityDescription:
                speculative.accessibilityDescription,
            plainTextFallback: speculative.plainTextFallback
        )
        let older = payloadRequest("reverse-ordering-older")
        let expectedNewer = PasteboardItemPayload.text("newer retry")
        let service = AdaptiveGlyphPayloadService(
            queueLabel:
                "MojiPondTests.AdaptiveGlyphPayloadService.NewerRetry",
            builder: { request in
                recorder.recordBuild(request.contentIdentifier)
                if request.cacheKey == running.cacheKey {
                    runningStarted.signal()
                    _ = releaseRunning.wait(timeout: .now() + 5)
                } else if request.sourceData == speculative.sourceData {
                    preparationStarted.signal()
                    _ = releasePreparation.wait(timeout: .now() + 5)
                    return nil
                }
                if request.cacheKey == newer.cacheKey {
                    return expectedNewer
                }
                return .text(request.contentIdentifier)
            }
        )

        service.payload(for: running) { _ in
            runningCompleted.signal()
        }
        service.prepare(speculative) {
            preparationCompleted.signal()
        }
        XCTAssertEqual(
            runningStarted.wait(timeout: .now() + 2),
            .success
        )
        XCTAssertEqual(
            preparationStarted.wait(timeout: .now() + 2),
            .success
        )

        service.payload(for: older) { payload in
            XCTAssertNil(payload)
            olderCompleted.signal()
        }
        service.payload(for: newer) { payload in
            XCTAssertEqual(payload, expectedNewer)
            newerCompleted.signal()
        }
        releasePreparation.signal()

        let olderBeforeRunningFinishes = olderCompleted.wait(
            timeout: .now() + 0.5
        )
        releaseRunning.signal()
        let runningResult = runningCompleted.wait(timeout: .now() + 2)
        let newerResult = newerCompleted.wait(timeout: .now() + 2)
        let preparationResult = preparationCompleted.wait(
            timeout: .now() + 2
        )

        XCTAssertEqual(olderBeforeRunningFinishes, .success)
        XCTAssertEqual(runningResult, .success)
        XCTAssertEqual(newerResult, .success)
        XCTAssertEqual(preparationResult, .success)
        XCTAssertEqual(
            recorder.buildCount(for: speculative.contentIdentifier),
            2
        )
        XCTAssertEqual(
            recorder.buildCount(for: older.contentIdentifier),
            0
        )
    }

    func testReturningToSupersededKeyKeepsNewestPendingPayload() {
        let recorder = AdaptiveGlyphBuilderRecorder()
        let runningStarted = DispatchSemaphore(value: 0)
        let releaseRunning = DispatchSemaphore(value: 0)
        let runningCompleted = DispatchSemaphore(value: 0)
        let preparationStarted = DispatchSemaphore(value: 0)
        let releasePreparation = DispatchSemaphore(value: 0)
        let preparationCompleted = DispatchSemaphore(value: 0)
        let retryCompleted = DispatchSemaphore(value: 0)
        let supersededPendingCompleted = DispatchSemaphore(value: 0)
        let newestPendingCompleted = DispatchSemaphore(value: 0)
        let running = payloadRequest("coalescing-order-running")
        let speculative = payloadRequest("coalescing-order-retry")
        let retry = AdaptiveGlyphPayloadRequest(
            sourceData: Data("coalescing retry source".utf8),
            sourceType: speculative.sourceType,
            contentIdentifier: speculative.contentIdentifier,
            accessibilityDescription:
                speculative.accessibilityDescription,
            plainTextFallback: speculative.plainTextFallback
        )
        let pending = payloadRequest("coalescing-order-pending")
        let expectedPending = PasteboardItemPayload.text(
            "coalesced pending"
        )
        let service = AdaptiveGlyphPayloadService(
            queueLabel:
                "MojiPondTests.AdaptiveGlyphPayloadService.CoalescedOrder",
            builder: { request in
                recorder.recordBuild(request.contentIdentifier)
                if request.cacheKey == running.cacheKey {
                    runningStarted.signal()
                    _ = releaseRunning.wait(timeout: .now() + 5)
                } else if request.sourceData == speculative.sourceData {
                    preparationStarted.signal()
                    _ = releasePreparation.wait(timeout: .now() + 5)
                    return nil
                }
                if request.cacheKey == pending.cacheKey {
                    return expectedPending
                }
                return .text("retry payload")
            }
        )

        service.payload(for: running) { _ in
            runningCompleted.signal()
        }
        service.prepare(speculative) {
            preparationCompleted.signal()
        }
        XCTAssertEqual(
            runningStarted.wait(timeout: .now() + 2),
            .success
        )
        XCTAssertEqual(
            preparationStarted.wait(timeout: .now() + 2),
            .success
        )

        service.payload(for: pending) { payload in
            XCTAssertNil(payload)
            supersededPendingCompleted.signal()
        }
        service.payload(for: retry) { payload in
            XCTAssertNil(payload)
            retryCompleted.signal()
        }
        service.payload(for: pending) { payload in
            XCTAssertEqual(payload, expectedPending)
            newestPendingCompleted.signal()
        }
        releasePreparation.signal()

        let retryBeforeRunningFinishes = retryCompleted.wait(
            timeout: .now() + 0.5
        )
        let preparationBeforeRunningFinishes =
            preparationCompleted.wait(timeout: .now() + 0.5)
        releaseRunning.signal()
        let runningResult = runningCompleted.wait(timeout: .now() + 2)
        let supersededPendingResult = supersededPendingCompleted.wait(
            timeout: .now() + 2
        )
        let newestPendingResult = newestPendingCompleted.wait(
            timeout: .now() + 2
        )

        XCTAssertEqual(retryBeforeRunningFinishes, .success)
        XCTAssertEqual(preparationBeforeRunningFinishes, .success)
        XCTAssertEqual(runningResult, .success)
        XCTAssertEqual(supersededPendingResult, .success)
        XCTAssertEqual(newestPendingResult, .success)
        XCTAssertEqual(
            recorder.buildCount(for: speculative.contentIdentifier),
            1
        )
        XCTAssertEqual(
            recorder.buildCount(for: pending.contentIdentifier),
            1
        )
    }

    func testDeferredPreparationKeepsOnlyNewestPendingLoader() {
        let recorder = AdaptiveGlyphBuilderRecorder()
        let runningStarted = DispatchSemaphore(value: 0)
        let releaseRunning = DispatchSemaphore(value: 0)
        let runningCompleted = DispatchSemaphore(value: 0)
        let replacedCompleted = DispatchSemaphore(value: 0)
        let newestCompleted = DispatchSemaphore(value: 0)
        let running = payloadRequest("running")
        let replaced = payloadRequest("replaced")
        let newest = payloadRequest("newest")
        let service = AdaptiveGlyphPayloadService(
            queueLabel:
                "MojiPondTests.AdaptiveGlyphPayloadService.Replacement",
            builder: { request in
                recorder.recordBuild(request.contentIdentifier)
                if request.cacheKey == running.cacheKey {
                    runningStarted.signal()
                    _ = releaseRunning.wait(timeout: .now() + 5)
                }
                return .text(request.contentIdentifier)
            }
        )

        service.prepare(
            for: running.cacheKey,
            loader: {
                recorder.recordLoad(running.contentIdentifier)
                return running
            },
            completion: {
                runningCompleted.signal()
            }
        )
        XCTAssertEqual(
            runningStarted.wait(timeout: .now() + 2),
            .success
        )
        service.prepare(
            for: replaced.cacheKey,
            loader: {
                recorder.recordLoad(replaced.contentIdentifier)
                return replaced
            },
            completion: {
                replacedCompleted.signal()
            }
        )
        service.prepare(
            for: newest.cacheKey,
            loader: {
                recorder.recordLoad(newest.contentIdentifier)
                return newest
            },
            completion: {
                newestCompleted.signal()
            }
        )

        let replacedResult = replacedCompleted.wait(
            timeout: .now() + 2
        )
        let replacedLoadCount = recorder.loadCount(
            for: replaced.contentIdentifier
        )
        releaseRunning.signal()
        let runningResult = runningCompleted.wait(
            timeout: .now() + 2
        )
        let newestResult = newestCompleted.wait(
            timeout: .now() + 2
        )

        XCTAssertEqual(replacedResult, .success)
        XCTAssertEqual(runningResult, .success)
        XCTAssertEqual(newestResult, .success)
        XCTAssertEqual(replacedLoadCount, 0)
        XCTAssertEqual(
            recorder.loadCount(for: newest.contentIdentifier),
            1
        )
        XCTAssertFalse(recorder.loadedOnMainThread)
    }

    func testStaticPNGBuildsRTFDFirstAndRoundTripsAsInlineGlyph()
        throws
    {
        guard #available(macOS 15.0, *) else {
            throw XCTSkip("Adaptive image glyphs require macOS 15.")
        }
        let root = try TestSupport.makeTemporaryDirectory()
        defer {
            try? FileManager.default.removeItem(at: root)
        }
        let imageURL = try TestSupport.writeImage(
            to: root.appendingPathComponent("wide.png"),
            width: 6,
            height: 2
        )
        let imageData = try Data(contentsOf: imageURL)
        let identifier = "mojipond:\(String(repeating: "a", count: 64))"
        let fallback = ":wide_bufo:"

        let payload = try AdaptiveGlyphPayloadBuilder.buildPayload(
            sourceData: imageData,
            sourceType: .png,
            contentIdentifier: identifier,
            accessibilityDescription: fallback,
            plainTextFallback: fallback
        )

        XCTAssertEqual(
            payload.representations.map(\.typeIdentifier),
            [
                NSPasteboard.PasteboardType.rtfd.rawValue,
                NSPasteboard.PasteboardType.string.rawValue
            ]
        )
        XCTAssertEqual(
            payload.representations[1].data,
            Data(fallback.utf8)
        )

        let pasteboard = NSPasteboard(
            name: NSPasteboard.Name(
                "MojiPondAdaptiveGlyphTests-\(UUID().uuidString)"
            )
        )
        defer {
            pasteboard.clearContents()
            pasteboard.releaseGlobally()
        }
        let access = MacPasteboardAccess(pasteboard: pasteboard)
        XCTAssertTrue(access.replaceContents(with: [payload]))

        let attributed = try XCTUnwrap(
            pasteboard.readObjects(
                forClasses: [NSAttributedString.self]
            )?.first as? NSAttributedString
        )
        XCTAssertEqual(attributed.length, 1)
        XCTAssertEqual(
            attributed.string.unicodeScalars.map(\.value),
            [0xFFFC]
        )
        let glyph = try XCTUnwrap(
            attributed.attribute(
                .adaptiveImageGlyph,
                at: 0,
                effectiveRange: nil
            ) as? NSAdaptiveImageGlyph
        )
        XCTAssertEqual(glyph.contentIdentifier, identifier)
        XCTAssertEqual(glyph.contentDescription, fallback)
        XCTAssertLessThanOrEqual(
            glyph.imageContent.count,
            AdaptiveGlyphPayloadBuilder.maximumEncodedBytes
        )

        let glyphSource = try XCTUnwrap(
            CGImageSourceCreateWithData(
                glyph.imageContent as CFData,
                nil
            )
        )
        XCTAssertEqual(
            CGImageSourceGetType(glyphSource) as String?,
            UTType.heic.identifier
        )
        XCTAssertEqual(CGImageSourceGetCount(glyphSource), 1)
        let properties = try XCTUnwrap(
            CGImageSourceCopyPropertiesAtIndex(
                glyphSource,
                0,
                nil
            ) as? [CFString: Any]
        )
        XCTAssertEqual(
            properties[kCGImagePropertyPixelWidth] as? Int,
            6
        )
        XCTAssertEqual(
            properties[kCGImagePropertyPixelHeight] as? Int,
            2
        )
    }

    func testAnimatedSourceIsRejectedInsteadOfFlattened() throws {
        guard #available(macOS 15.0, *) else {
            throw XCTSkip("Adaptive image glyphs require macOS 15.")
        }
        let root = try TestSupport.makeTemporaryDirectory()
        defer {
            try? FileManager.default.removeItem(at: root)
        }
        let imageURL = try TestSupport.writeImage(
            to: root.appendingPathComponent("animated.gif"),
            format: .gif,
            width: 8,
            height: 8,
            frameCount: 2
        )
        let imageData = try Data(contentsOf: imageURL)

        XCTAssertThrowsError(
            try AdaptiveGlyphPayloadBuilder.buildPayload(
                sourceData: imageData,
                sourceType: .gif,
                contentIdentifier:
                    "mojipond:\(String(repeating: "b", count: 64))",
                accessibilityDescription: ":animated_bufo:",
                plainTextFallback: ":animated_bufo:"
            )
        ) {
            XCTAssertEqual(
                $0 as? AdaptiveGlyphPayloadError,
                .animatedSource
            )
        }
    }

    func testAnimatedPNGIsRejectedEvenWhenCallerTreatsItAsStatic()
        throws
    {
        guard #available(macOS 15.0, *) else {
            throw XCTSkip("Adaptive image glyphs require macOS 15.")
        }
        let root = try TestSupport.makeTemporaryDirectory()
        defer {
            try? FileManager.default.removeItem(at: root)
        }
        let imageURL = try TestSupport.writeImage(
            to: root.appendingPathComponent("animated.png"),
            format: .png,
            width: 8,
            height: 8,
            frameCount: 2
        )
        let imageData = try Data(contentsOf: imageURL)
        let source = try XCTUnwrap(
            CGImageSourceCreateWithData(imageData as CFData, nil)
        )
        XCTAssertEqual(CGImageSourceGetCount(source), 2)

        XCTAssertThrowsError(
            try AdaptiveGlyphPayloadBuilder.buildPayload(
                sourceData: imageData,
                sourceType: .png,
                contentIdentifier:
                    "mojipond:\(String(repeating: "d", count: 64))",
                accessibilityDescription: ":animated_png:",
                plainTextFallback: ":animated_png:"
            )
        ) {
            XCTAssertEqual(
                $0 as? AdaptiveGlyphPayloadError,
                .animatedSource
            )
        }
    }

    func testInvalidImageReturnsNoInlinePayload() {
        let payload = AdaptiveGlyphPayloadBuilder.payloadIfSupported(
            sourceData: Data("not an image".utf8),
            sourceType: .png,
            contentIdentifier:
                "mojipond:\(String(repeating: "c", count: 64))",
            accessibilityDescription: ":invalid:",
            plainTextFallback: ":invalid:"
        )

        XCTAssertNil(payload)
    }

    func testSystemRejectionIsHandledWithoutUsingNonfailableSwiftInit()
        throws
    {
        guard #available(macOS 15.0, *) else {
            throw XCTSkip("Adaptive image glyphs require macOS 15.")
        }
        let root = try TestSupport.makeTemporaryDirectory()
        defer {
            try? FileManager.default.removeItem(at: root)
        }
        let imageURL = try TestSupport.writeImage(
            to: root.appendingPathComponent("plain.png"),
            width: 128,
            height: 128
        )
        let imageData = try Data(contentsOf: imageURL)
        let source = try XCTUnwrap(
            CGImageSourceCreateWithData(imageData as CFData, nil)
        )
        let image = try XCTUnwrap(
            CGImageSourceCreateImageAtIndex(source, 0, nil)
        )
        let plainHEIC = NSMutableData()
        let destination = try XCTUnwrap(
            CGImageDestinationCreateWithData(
                plainHEIC,
                UTType.heic.identifier as CFString,
                1,
                nil
            )
        )
        CGImageDestinationAddImage(destination, image, nil)
        XCTAssertTrue(CGImageDestinationFinalize(destination))

        XCTAssertThrowsError(
            try AdaptiveGlyphPayloadBuilder.makeGlyph(
                plainHEIC as Data,
                expectedIdentifier: "missing",
                expectedDescription: "missing"
            )
        ) {
            XCTAssertEqual(
                $0 as? AdaptiveGlyphPayloadError,
                .systemRejectedImage
            )
        }
    }

    private func cacheKey(
        contentIdentifier: String,
        sourceType: UTType = .png,
        accessibilityDescription: String = ":bufo:",
        plainTextFallback: String = ":bufo:"
    ) -> AdaptiveGlyphPayloadCacheKey {
        AdaptiveGlyphPayloadCacheKey(
            sourceType: sourceType,
            contentIdentifier: contentIdentifier,
            accessibilityDescription: accessibilityDescription,
            plainTextFallback: plainTextFallback
        )
    }

    private func payloadRequest(
        _ identifier: String
    ) -> AdaptiveGlyphPayloadRequest {
        AdaptiveGlyphPayloadRequest(
            sourceData: Data(identifier.utf8),
            sourceType: .png,
            contentIdentifier: "mojipond:test:\(identifier)",
            accessibilityDescription: ":\(identifier):",
            plainTextFallback: ":\(identifier):"
        )
    }
}

private final class AdaptiveGlyphBuilderRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var recordedBuildCount = 0
    private var recordedMainThreadBuild = false
    private var buildCountsByIdentifier: [String: Int] = [:]
    private var loadCountsByIdentifier: [String: Int] = [:]
    private var recordedMainThreadLoad = false

    var buildCount: Int {
        lock.withLock {
            recordedBuildCount
        }
    }

    var builtOnMainThread: Bool {
        lock.withLock {
            recordedMainThreadBuild
        }
    }

    var loadedOnMainThread: Bool {
        lock.withLock {
            recordedMainThreadLoad
        }
    }

    func buildCount(for identifier: String) -> Int {
        lock.withLock {
            buildCountsByIdentifier[identifier, default: 0]
        }
    }

    func loadCount(for identifier: String) -> Int {
        lock.withLock {
            loadCountsByIdentifier[identifier, default: 0]
        }
    }

    func recordBuild(_ identifier: String = "default") {
        lock.withLock {
            recordedBuildCount += 1
            recordedMainThreadBuild =
                recordedMainThreadBuild || Thread.isMainThread
            buildCountsByIdentifier[identifier, default: 0] += 1
        }
    }

    func recordLoad(_ identifier: String) {
        lock.withLock {
            loadCountsByIdentifier[identifier, default: 0] += 1
            recordedMainThreadLoad =
                recordedMainThreadLoad || Thread.isMainThread
        }
    }
}
