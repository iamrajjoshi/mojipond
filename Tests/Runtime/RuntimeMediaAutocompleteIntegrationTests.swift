import AppKit
import CoreGraphics
import CryptoKit
import Foundation
import UniformTypeIdentifiers
import XCTest
@testable import MojiPond

@MainActor
final class RuntimeMediaAutocompleteIntegrationTests: XCTestCase {
    nonisolated(unsafe) private var temporaryRoots: [URL] = []

    override func tearDownWithError() throws {
        for root in temporaryRoots {
            try? FileManager.default.removeItem(at: root)
        }
        temporaryRoots = []
    }

    func testAnimatedGIFExactTokenUsesFirstFrameGlyphInMessages()
        async throws
    {
        let sourceRoot = try TestSupport.makeTemporaryDirectory()
        temporaryRoots.append(sourceRoot)
        let gifURL = try TestSupport.writeImage(
            to: sourceRoot.appendingPathComponent("animated.gif"),
            format: .gif,
            width: 8,
            height: 8,
            frameCount: 2
        )
        let gif = try Data(contentsOf: gifURL)
        let fixture = try makeMediaFixture(data: gif, filename: "bufo.gif")
        let harness = try makeHarness(
            items: [
                mediaEmoji(
                    shortcode: "bufo",
                    mediaType: .gif,
                    relativePath: fixture.relativePath,
                    data: gif
                )
            ],
            targetText: ":bufo:",
            bundleIdentifier: messages,
            managedMediaRoot: fixture.root
        )

        harness.worker.setCaptureEnabled(true)
        type(":bufo:", into: harness.worker)

        let didPaste = await eventually {
            harness.poster.pasteCount == 1
        }
        XCTAssertTrue(didPaste)
        let temporaryPayload = try XCTUnwrap(
            harness.pasteboard.successfulWrites.first?.first
        )
        if #available(macOS 15.0, *) {
            XCTAssertEqual(
                temporaryPayload.representations.first?.typeIdentifier,
                NSPasteboard.PasteboardType.rtfd.rawValue
            )
            XCTAssertFalse(
                temporaryPayload.representations.contains {
                    $0.typeIdentifier == UTType.gif.identifier
                }
            )
            let glyph = try adaptiveGlyph(from: temporaryPayload)
            let glyphSource = try XCTUnwrap(
                CGImageSourceCreateWithData(
                    glyph.imageContent as CFData,
                    nil
                )
            )
            XCTAssertEqual(CGImageSourceGetCount(glyphSource), 1)
            XCTAssertTrue(glyph.contentIdentifier.hasSuffix(":bufo:f0"))
        } else {
            XCTAssertEqual(
                temporaryPayload.representations.first {
                    $0.typeIdentifier == UTType.gif.identifier
                }?.data,
                gif
            )
        }
        XCTAssertFalse(
            harness.diagnostics.values.contains {
                switch $0 {
                case .unsupportedTarget,
                     .clipboardRestoreFailed,
                     .sendAfterInsertionUnavailable,
                     .sessionDenied,
                     .mediaCopyFallbackAvailable:
                    true
                case .sessionAllowed:
                    false
                }
            }
        )
    }

    func testAnimatedPNGExactTokenUsesFirstFrameGlyphInMessages()
        async throws
    {
        guard #available(macOS 15.0, *) else {
            throw XCTSkip("Adaptive image glyphs require macOS 15.")
        }
        let sourceRoot = try TestSupport.makeTemporaryDirectory()
        temporaryRoots.append(sourceRoot)
        let pngURL = try TestSupport.writeImage(
            to: sourceRoot.appendingPathComponent("animated.png"),
            format: .png,
            width: 8,
            height: 8,
            frameCount: 2
        )
        let png = try Data(contentsOf: pngURL)
        let source = try XCTUnwrap(
            CGImageSourceCreateWithData(png as CFData, nil)
        )
        XCTAssertEqual(CGImageSourceGetCount(source), 2)
        let fixture = try makeMediaFixture(
            data: png,
            filename: "animated.png"
        )
        let harness = try makeHarness(
            items: [
                mediaEmoji(
                    shortcode: "animated_png",
                    mediaType: .png,
                    relativePath: fixture.relativePath,
                    data: png,
                    isAnimated: true
                )
            ],
            targetText: ":animated_png:",
            bundleIdentifier: messages,
            managedMediaRoot: fixture.root
        )

        harness.worker.setCaptureEnabled(true)
        type(":animated_png:", into: harness.worker)

        let didPaste = await eventually {
            harness.poster.pasteCount == 1
        }
        XCTAssertTrue(didPaste)
        let temporaryPayload = try XCTUnwrap(
            harness.pasteboard.successfulWrites.first?.first
        )
        XCTAssertEqual(
            temporaryPayload.representations.first?.typeIdentifier,
            NSPasteboard.PasteboardType.rtfd.rawValue
        )
        XCTAssertFalse(
            temporaryPayload.representations.contains {
                $0.typeIdentifier == UTType.png.identifier
            }
        )
        let glyph = try adaptiveGlyph(from: temporaryPayload)
        let glyphSource = try XCTUnwrap(
            CGImageSourceCreateWithData(
                glyph.imageContent as CFData,
                nil
            )
        )
        XCTAssertEqual(CGImageSourceGetCount(glyphSource), 1)
        XCTAssertTrue(
            glyph.contentIdentifier.hasSuffix(":animated_png:f0")
        )
    }

    func testCustomPNGAutocompleteSelectionPastesInMessages() async throws {
        let sourceRoot = try TestSupport.makeTemporaryDirectory()
        temporaryRoots.append(sourceRoot)
        let pngURL = try TestSupport.writeImage(
            to: sourceRoot.appendingPathComponent("source.png"),
            width: 16,
            height: 12
        )
        let png = try Data(contentsOf: pngURL)
        let fixture = try makeMediaFixture(data: png, filename: "bufo.png")
        let harness = try makeHarness(
            items: [
                mediaEmoji(
                    shortcode: "bufo",
                    mediaType: .png,
                    relativePath: fixture.relativePath,
                    data: png
                )
            ],
            targetText: ":bu",
            bundleIdentifier: messages,
            managedMediaRoot: fixture.root
        )
        harness.worker.setCaptureEnabled(true)
        type(":bu", into: harness.worker)

        let didShowSuggestion = await eventually {
            harness.presenter.latestSuggestion?.rows
                .contains(where: { $0.shortcode == "bufo" }) == true
        }
        XCTAssertTrue(didShowSuggestion)
        let suggestion = try XCTUnwrap(
            harness.presenter.latestSuggestion?.rows.first(
                where: { $0.shortcode == "bufo" }
            )
        )
        XCTAssertEqual(
            suggestion.artworkURL,
            fixture.root
                .appendingPathComponent(
                    fixture.relativePath,
                    isDirectory: false
                )
                .standardizedFileURL
                .resolvingSymlinksInPath()
        )
        harness.worker.enqueue(
            keySnapshot(keyCode: RuntimeKeyboardKeyCode.tab)
        )

        // Allow a cold ImageIO startup, but fail before a codec can stall for
        // a minute.
        let didPaste = await eventually(timeout: .seconds(15)) {
            harness.poster.pasteCount == 1
        }
        XCTAssertTrue(didPaste)
        let temporaryPayload = try XCTUnwrap(
            harness.pasteboard.successfulWrites.first?.first
        )
        if #available(macOS 15.0, *) {
            XCTAssertEqual(
                temporaryPayload.representations.first?.typeIdentifier,
                NSPasteboard.PasteboardType.rtfd.rawValue
            )
            XCTAssertFalse(
                temporaryPayload.representations.contains {
                    $0.typeIdentifier == UTType.png.identifier
                        || $0.typeIdentifier == UTType.tiff.identifier
                }
            )
        } else {
            XCTAssertEqual(
                temporaryPayload.representations.first?.typeIdentifier,
                UTType.png.identifier
            )
        }
    }

    func testSuggestionFallsBackToOriginalWhenThumbnailEscapesManagedRoot()
        async throws
    {
        let sourceRoot = try TestSupport.makeTemporaryDirectory()
        temporaryRoots.append(sourceRoot)
        let pngURL = try TestSupport.writeImage(
            to: sourceRoot.appendingPathComponent("source.png"),
            width: 16,
            height: 12
        )
        let png = try Data(contentsOf: pngURL)
        let fixture = try makeMediaFixture(
            data: png,
            filename: "bufo.png"
        )
        let externalRoot = try TestSupport.makeTemporaryDirectory()
        temporaryRoots.append(externalRoot)
        try png.write(
            to: externalRoot.appendingPathComponent("thumbnail.png")
        )
        try FileManager.default.createSymbolicLink(
            at: fixture.root.appendingPathComponent(
                "thumbnails",
                isDirectory: true
            ),
            withDestinationURL: externalRoot
        )
        let item = EmojiItem(
            id: "custom.bufo",
            shortcode: Shortcode(rawValue: "bufo")!,
            name: "Bufo",
            category: "Custom",
            content: .media(
                MediaEmojiContent(
                    mediaType: .png,
                    relativePath: fixture.relativePath,
                    thumbnailRelativePath:
                        "thumbnails/thumbnail.png",
                    originalFilename: "bufo.png",
                    contentHash: digest(png),
                    isAnimated: false
                )
            ),
            packID: "custom"
        )
        let harness = try makeHarness(
            items: [item],
            targetText: ":bu",
            bundleIdentifier: messages,
            managedMediaRoot: fixture.root
        )

        harness.worker.setCaptureEnabled(true)
        type(":bu", into: harness.worker)

        let didShowSuggestion = await eventually {
            harness.presenter.latestSuggestion?.rows
                .contains(where: { $0.shortcode == "bufo" }) == true
        }
        XCTAssertTrue(didShowSuggestion)
        let suggestion = try XCTUnwrap(
            harness.presenter.latestSuggestion?.rows.first(
                where: { $0.shortcode == "bufo" }
            )
        )
        XCTAssertEqual(
            suggestion.artworkURL,
            fixture.root
                .standardizedFileURL
                .resolvingSymlinksInPath()
                .appendingPathComponent(
                    "thumbnails/thumbnail.png",
                    isDirectory: false
                )
                .standardizedFileURL
        )
        XCTAssertEqual(
            suggestion.artworkFallbackURL,
            fixture.root
                .standardizedFileURL
                .resolvingSymlinksInPath()
                .appendingPathComponent(
                    fixture.relativePath,
                    isDirectory: false
                )
                .standardizedFileURL
        )
        XCTAssertEqual(
            suggestion.artworkRootURL,
            fixture.root
                .standardizedFileURL
                .resolvingSymlinksInPath()
        )
    }

    func testSuggestionFallsBackToOriginalWhenThumbnailIsMissing()
        async throws
    {
        let sourceRoot = try TestSupport.makeTemporaryDirectory()
        temporaryRoots.append(sourceRoot)
        let pngURL = try TestSupport.writeImage(
            to: sourceRoot.appendingPathComponent("source.png"),
            width: 16,
            height: 12
        )
        let png = try Data(contentsOf: pngURL)
        let fixture = try makeMediaFixture(
            data: png,
            filename: "bufo.png"
        )
        let item = EmojiItem(
            id: "custom.bufo",
            shortcode: Shortcode(rawValue: "bufo")!,
            name: "Bufo",
            category: "Custom",
            content: .media(
                MediaEmojiContent(
                    mediaType: .png,
                    relativePath: fixture.relativePath,
                    thumbnailRelativePath:
                        "thumbnails/missing.png",
                    originalFilename: "bufo.png",
                    contentHash: digest(png),
                    isAnimated: false
                )
            ),
            packID: "custom"
        )
        let harness = try makeHarness(
            items: [item],
            targetText: ":bu",
            bundleIdentifier: messages,
            managedMediaRoot: fixture.root
        )

        harness.worker.setCaptureEnabled(true)
        type(":bu", into: harness.worker)

        let didShowSuggestion = await eventually {
            harness.presenter.latestSuggestion?.rows
                .contains(where: { $0.shortcode == "bufo" }) == true
        }
        XCTAssertTrue(didShowSuggestion)
        let suggestion = try XCTUnwrap(
            harness.presenter.latestSuggestion?.rows.first(
                where: { $0.shortcode == "bufo" }
            )
        )
        XCTAssertEqual(
            suggestion.artworkURL,
            fixture.root
                .standardizedFileURL
                .resolvingSymlinksInPath()
                .appendingPathComponent(
                    "thumbnails/missing.png",
                    isDirectory: false
                )
                .standardizedFileURL
        )
        XCTAssertEqual(
            suggestion.artworkFallbackURL,
            fixture.root
                .standardizedFileURL
                .resolvingSymlinksInPath()
                .appendingPathComponent(
                    fixture.relativePath,
                    isDirectory: false
                )
                .standardizedFileURL
        )
        XCTAssertEqual(
            suggestion.artworkRootURL,
            fixture.root
                .standardizedFileURL
                .resolvingSymlinksInPath()
        )
    }

    func testSuggestionRetainsOriginalAsFallbackForInvalidThumbnail()
        async throws
    {
        let sourceRoot = try TestSupport.makeTemporaryDirectory()
        temporaryRoots.append(sourceRoot)
        let pngURL = try TestSupport.writeImage(
            to: sourceRoot.appendingPathComponent("source.png"),
            width: 16,
            height: 12
        )
        let png = try Data(contentsOf: pngURL)
        let fixture = try makeMediaFixture(
            data: png,
            filename: "bufo.png"
        )
        let thumbnailRelativePath = "thumbnails/invalid.png"
        let thumbnailURL = fixture.root.appendingPathComponent(
            thumbnailRelativePath,
            isDirectory: false
        )
        try FileManager.default.createDirectory(
            at: thumbnailURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try Data("not an image".utf8).write(to: thumbnailURL)
        let item = EmojiItem(
            id: "custom.bufo",
            shortcode: Shortcode(rawValue: "bufo")!,
            name: "Bufo",
            category: "Custom",
            content: .media(
                MediaEmojiContent(
                    mediaType: .png,
                    relativePath: fixture.relativePath,
                    thumbnailRelativePath: thumbnailRelativePath,
                    originalFilename: "bufo.png",
                    contentHash: digest(png),
                    isAnimated: false
                )
            ),
            packID: "custom"
        )
        let harness = try makeHarness(
            items: [item],
            targetText: ":bu",
            bundleIdentifier: messages,
            managedMediaRoot: fixture.root
        )

        harness.worker.setCaptureEnabled(true)
        type(":bu", into: harness.worker)

        let didShowSuggestion = await eventually {
            harness.presenter.latestSuggestion?.rows
                .contains(where: { $0.shortcode == "bufo" }) == true
        }
        XCTAssertTrue(didShowSuggestion)
        let suggestion = try XCTUnwrap(
            harness.presenter.latestSuggestion?.rows.first(
                where: { $0.shortcode == "bufo" }
            )
        )
        XCTAssertEqual(
            suggestion.artworkURL,
            fixture.root
                .standardizedFileURL
                .resolvingSymlinksInPath()
                .appendingPathComponent(
                    thumbnailRelativePath,
                    isDirectory: false
                )
                .standardizedFileURL
        )
        XCTAssertEqual(
            suggestion.artworkFallbackURL,
            fixture.root
                .standardizedFileURL
                .resolvingSymlinksInPath()
                .appendingPathComponent(
                    fixture.relativePath,
                    isDirectory: false
                )
                .standardizedFileURL
        )
        XCTAssertEqual(
            suggestion.artworkRootURL,
            fixture.root
                .standardizedFileURL
                .resolvingSymlinksInPath()
        )
    }

    func testSuccessfulStaticGlyphDoesNotBuildPhotoFallback() async throws {
        let sourceRoot = try TestSupport.makeTemporaryDirectory()
        temporaryRoots.append(sourceRoot)
        let pngURL = try TestSupport.writeImage(
            to: sourceRoot.appendingPathComponent("fast.png"),
            width: 16,
            height: 12
        )
        let png = try Data(contentsOf: pngURL)
        let fixture = try makeMediaFixture(data: png, filename: "fast.png")
        let fallbackRecorder = RuntimeMediaPayloadBuilderRecorder()
        let service = AdaptiveGlyphPayloadService(
            queueLabel:
                "com.rajjoshi.MojiPond.tests.fast-static-glyph.\(UUID())",
            builder: { _ in
                .text("native glyph")
            }
        )
        let harness = try makeHarness(
            items: [
                mediaEmoji(
                    shortcode: "bufo",
                    mediaType: .png,
                    relativePath: fixture.relativePath,
                    data: png
                )
            ],
            targetText: ":bu",
            bundleIdentifier: messages,
            managedMediaRoot: fixture.root,
            adaptiveGlyphPayloadService: service,
            managedMediaPayloadBuilder: { resolved in
                fallbackRecorder.build(resolved)
            }
        )

        harness.worker.setCaptureEnabled(true)
        type(":bu", into: harness.worker)
        let didShowSuggestion = await eventually {
            harness.presenter.latestSuggestion?.rows
                .contains(where: { $0.shortcode == "bufo" }) == true
        }
        XCTAssertTrue(didShowSuggestion)

        harness.worker.enqueue(
            keySnapshot(keyCode: RuntimeKeyboardKeyCode.tab)
        )
        let didPaste = await eventually {
            harness.poster.pasteCount == 1
        }
        XCTAssertTrue(didPaste)
        XCTAssertEqual(fallbackRecorder.buildCount, 0)
        XCTAssertEqual(
            harness.pasteboard.successfulWrites.first?
                .first?
                .representations
                .first?
                .data,
            Data("native glyph".utf8)
        )
    }

    func testAnimatedGlyphPreparationUsesFirstFramePolicy() async throws {
        let sourceRoot = try TestSupport.makeTemporaryDirectory()
        temporaryRoots.append(sourceRoot)
        let gifURL = try TestSupport.writeImage(
            to: sourceRoot.appendingPathComponent("prepared.gif"),
            format: .gif,
            width: 16,
            height: 12,
            frameCount: 2
        )
        let gif = try Data(contentsOf: gifURL)
        let fixture = try makeMediaFixture(
            data: gif,
            filename: "prepared.gif"
        )
        let buildStarted = expectation(
            description: "first-frame glyph preparation started"
        )
        let fallbackRecorder = RuntimeMediaPayloadBuilderRecorder()
        let service = AdaptiveGlyphPayloadService(
            queueLabel:
                "com.rajjoshi.MojiPond.tests.prepared-animated-glyph.\(UUID())",
            builder: { request in
                XCTAssertEqual(request.framePolicy, .firstFrame)
                XCTAssertTrue(
                    request.contentIdentifier.hasSuffix(":bufo:f0")
                )
                buildStarted.fulfill()
                return .text("prepared first-frame glyph")
            }
        )
        let harness = try makeHarness(
            items: [
                mediaEmoji(
                    shortcode: "bufo",
                    mediaType: .gif,
                    relativePath: fixture.relativePath,
                    data: gif
                )
            ],
            targetText: ":buf",
            bundleIdentifier: messages,
            managedMediaRoot: fixture.root,
            adaptiveGlyphPayloadService: service,
            managedMediaPayloadBuilder: { resolved in
                fallbackRecorder.build(resolved)
            }
        )

        harness.worker.setCaptureEnabled(true)
        type(":buf", into: harness.worker)
        await fulfillment(of: [buildStarted], timeout: 2)

        harness.worker.enqueue(
            keySnapshot(keyCode: RuntimeKeyboardKeyCode.tab)
        )
        let didPaste = await eventually {
            harness.poster.pasteCount == 1
        }
        XCTAssertTrue(didPaste)
        XCTAssertEqual(fallbackRecorder.buildCount, 0)
        XCTAssertEqual(
            harness.pasteboard.successfulWrites.first?
                .first?
                .representations
                .first?
                .data,
            Data("prepared first-frame glyph".utf8)
        )
    }

    func testCaptureCancellationDoesNotWaitForStaticGlyphBuildAndDropsResult()
        async throws
    {
        let sourceRoot = try TestSupport.makeTemporaryDirectory()
        temporaryRoots.append(sourceRoot)
        let pngURL = try TestSupport.writeImage(
            to: sourceRoot.appendingPathComponent("blocked.png"),
            width: 16,
            height: 12
        )
        let png = try Data(contentsOf: pngURL)
        let fixture = try makeMediaFixture(
            data: png,
            filename: "blocked.png"
        )
        let buildStarted = expectation(description: "glyph build started")
        let allowBuildToFinish = DispatchSemaphore(value: 0)
        let service = AdaptiveGlyphPayloadService(
            queueLabel:
                "com.rajjoshi.MojiPond.tests.blocked-glyph.\(UUID())",
            builder: { _ in
                buildStarted.fulfill()
                allowBuildToFinish.wait()
                return .text("late glyph payload")
            }
        )
        defer {
            allowBuildToFinish.signal()
        }
        let harness = try makeHarness(
            items: [
                mediaEmoji(
                    shortcode: "bufo",
                    mediaType: .png,
                    relativePath: fixture.relativePath,
                    data: png
                )
            ],
            targetText: ":bu",
            bundleIdentifier: messages,
            managedMediaRoot: fixture.root,
            adaptiveGlyphPayloadService: service
        )

        harness.worker.setCaptureEnabled(true)
        type(":bu", into: harness.worker)
        let didShowSuggestion = await eventually {
            harness.presenter.latestSuggestion?.rows
                .contains(where: { $0.shortcode == "bufo" }) == true
        }
        XCTAssertTrue(didShowSuggestion)

        harness.worker.enqueue(
            keySnapshot(keyCode: RuntimeKeyboardKeyCode.tab)
        )
        await fulfillment(of: [buildStarted], timeout: 2)
        XCTAssertEqual(harness.poster.pasteCount, 0)

        // A synchronous glyph build would hold the runtime queue here. Put
        // the gate in a visible state so only the queued permission shutdown
        // can hide it while the dedicated build queue remains blocked.
        harness.gate.setMode(
            .suggestions,
            acceptsTab: true,
            acceptsReturn: true
        )
        harness.worker.setCaptureEnabled(false)
        let didDisableCapture = await eventually {
            harness.gate.mode == .hidden
        }
        XCTAssertTrue(didDisableCapture)

        allowBuildToFinish.signal()
        let serviceDrained = expectation(description: "glyph service drained")
        service.prepare(
            AdaptiveGlyphPayloadRequest(
                sourceData: png,
                sourceType: .png,
                contentIdentifier:
                    "mojipond:\(digest(png)):bufo",
                accessibilityDescription: ":bufo:",
                plainTextFallback: ":bufo:"
            )
        ) {
            serviceDrained.fulfill()
        }
        await fulfillment(of: [serviceDrained], timeout: 2)

        // Both operations use serial queues: the service barrier runs after
        // its late completion is submitted, and the browser command runs
        // after that completion is handled by the runtime queue.
        harness.worker.setCaptureEnabled(true)
        harness.worker.openBrowser()
        let didDrainRuntime = await eventually {
            harness.gate.mode == .browser
        }
        XCTAssertTrue(didDrainRuntime)
        await Task.yield()
        XCTAssertEqual(harness.poster.pasteCount, 0)
    }

    func testCaptureCancellationDoesNotWaitForManagedMediaResolveAndDropsResult()
        async throws
    {
        let gif = validGIFData
        let fixture = try makeMediaFixture(
            data: gif,
            filename: "blocked-resolve.gif"
        )
        let resolveStarted = expectation(
            description: "managed media resolve started"
        )
        let resolveFinished = expectation(
            description: "managed media resolve finished"
        )
        let allowResolveToFinish = DispatchSemaphore(value: 0)
        let resolver = RuntimeManagedMediaResolverStub { _, _ in
            resolveStarted.fulfill()
            allowResolveToFinish.wait()
            resolveFinished.fulfill()
            return RuntimeResolvedManagedMedia(
                originalData: gif,
                uniformType: .gif,
                suggestedFilename: "blocked-resolve.gif",
                insertionPolicy: .automatic
            )
        }
        defer {
            allowResolveToFinish.signal()
        }
        let harness = try makeHarness(
            items: [
                mediaEmoji(
                    shortcode: "bufo",
                    mediaType: .gif,
                    relativePath: fixture.relativePath,
                    data: gif
                )
            ],
            targetText: ":bu",
            bundleIdentifier: messages,
            managedMediaResolver: resolver,
            managedMediaRoot: fixture.root
        )

        harness.worker.setCaptureEnabled(true)
        type(":bu", into: harness.worker)
        let didShowSuggestion = await eventually {
            harness.presenter.latestSuggestion?.rows
                .contains(where: { $0.shortcode == "bufo" }) == true
        }
        XCTAssertTrue(didShowSuggestion)

        harness.worker.enqueue(
            keySnapshot(keyCode: RuntimeKeyboardKeyCode.tab)
        )
        await fulfillment(of: [resolveStarted], timeout: 2)
        XCTAssertEqual(harness.poster.pasteCount, 0)

        // Only the queued permission shutdown can hide this manually armed
        // gate while custom-asset validation remains blocked off-worker.
        harness.gate.setMode(
            .suggestions,
            acceptsTab: true,
            acceptsReturn: true
        )
        harness.worker.setCaptureEnabled(false)
        let didDisableCapture = await eventually {
            harness.gate.mode == .hidden
        }
        XCTAssertTrue(didDisableCapture)
        XCTAssertEqual(harness.poster.pasteCount, 0)

        allowResolveToFinish.signal()
        await fulfillment(of: [resolveFinished], timeout: 2)
        await Task.yield()

        // The browser command is a runtime-queue barrier after the resolver's
        // late callback. A cancelled transaction must discard that callback.
        harness.worker.setCaptureEnabled(true)
        harness.worker.openBrowser()
        let didDrainRuntime = await eventually {
            harness.gate.mode == .browser
        }
        XCTAssertTrue(didDrainRuntime)
        await Task.yield()
        XCTAssertEqual(harness.poster.pasteCount, 0)
    }

    func testStaticGlyphFailureFallsBackToOriginalImagePayload()
        async throws
    {
        let png = Data([
            0x89, 0x50, 0x4E, 0x47,
            0x0D, 0x0A, 0x1A, 0x0A,
            0x01
        ])
        let fixture = try makeMediaFixture(
            data: png,
            filename: "unreadable.png"
        )
        let harness = try makeHarness(
            items: [
                mediaEmoji(
                    shortcode: "unreadable",
                    mediaType: .png,
                    relativePath: fixture.relativePath,
                    data: png
                )
            ],
            targetText: ":unreadable:",
            bundleIdentifier: messages,
            managedMediaRoot: fixture.root
        )

        harness.worker.setCaptureEnabled(true)
        type(":unreadable:", into: harness.worker)

        let didPaste = await eventually {
            harness.poster.pasteCount == 1
        }
        XCTAssertTrue(didPaste)
        let temporaryPayload = try XCTUnwrap(
            harness.pasteboard.successfulWrites.first?.first
        )
        XCTAssertEqual(
            temporaryPayload.representations.first?.typeIdentifier,
            UTType.png.identifier
        )
        XCTAssertEqual(
            temporaryPayload.representations.first?.data,
            png
        )
        XCTAssertFalse(
            temporaryPayload.representations.contains {
                $0.typeIdentifier
                    == NSPasteboard.PasteboardType.rtfd.rawValue
            }
        )
    }

    func testSuccessfulPasteSurfacesClipboardRestoreFailure() async throws {
        let gif = validGIFData
        let fixture = try makeMediaFixture(
            data: gif,
            filename: "restore-warning.gif"
        )
        let harness = try makeHarness(
            items: [
                mediaEmoji(
                    shortcode: "restore_warning",
                    mediaType: .gif,
                    relativePath: fixture.relativePath,
                    data: gif
                )
            ],
            targetText: ":restore_warning:",
            bundleIdentifier: messages,
            managedMediaRoot: fixture.root,
            failClipboardRestore: true
        )

        harness.worker.setCaptureEnabled(true)
        type(":restore_warning:", into: harness.worker)

        let warningReported = await eventually {
            harness.poster.pasteCount == 1
                && harness.diagnostics.values.contains(
                    .clipboardRestoreFailed
                )
        }
        XCTAssertTrue(warningReported)
    }

    func testAnimatedWebPUsesFirstFrameGlyphInMessages() async throws {
        guard #available(macOS 15.0, *) else {
            throw XCTSkip("Adaptive image glyphs require macOS 15.")
        }
        let webP = TestSupport.tinyAnimatedWebPData
        let source = try XCTUnwrap(
            CGImageSourceCreateWithData(webP as CFData, nil)
        )
        XCTAssertEqual(CGImageSourceGetCount(source), 2)
        let fixture = try makeMediaFixture(
            data: webP,
            filename: "experimental.webp"
        )
        let harness = try makeHarness(
            items: [
                mediaEmoji(
                    shortcode: "experimental",
                    mediaType: .webP,
                    relativePath: fixture.relativePath,
                    data: webP
                )
            ],
            targetText: ":experimental:",
            bundleIdentifier: messages,
            managedMediaRoot: fixture.root
        )

        harness.worker.setCaptureEnabled(true)
        type(":experimental:", into: harness.worker)

        let didPaste = await eventually(timeout: .seconds(15)) {
            harness.poster.pasteCount == 1
        }
        XCTAssertTrue(didPaste)
        let temporaryPayload = try XCTUnwrap(
            harness.pasteboard.successfulWrites.first?.first
        )
        XCTAssertEqual(
            temporaryPayload.representations.first?.typeIdentifier,
            NSPasteboard.PasteboardType.rtfd.rawValue
        )
        XCTAssertFalse(
            temporaryPayload.representations.contains {
                $0.typeIdentifier == UTType.webP.identifier
            }
        )
        XCTAssertFalse(
            harness.diagnostics.values.contains {
                guard case let .mediaCopyFallbackAvailable(value) = $0 else {
                    return false
                }
                return value.reason == .animatedWebPExperimental
            }
        )
    }

    func testAnimatedWebPGlyphFailureKeepsExplicitCopyFallback()
        async throws
    {
        let webP = TestSupport.tinyAnimatedWebPData
        let fixture = try makeMediaFixture(
            data: webP,
            filename: "experimental.webp"
        )
        let service = AdaptiveGlyphPayloadService(
            queueLabel:
                "com.rajjoshi.MojiPond.tests.failed-webp-glyph.\(UUID())",
            builder: { _ in nil }
        )
        let harness = try makeHarness(
            items: [
                mediaEmoji(
                    shortcode: "experimental",
                    mediaType: .webP,
                    relativePath: fixture.relativePath,
                    data: webP
                )
            ],
            targetText: ":experimental:",
            bundleIdentifier: messages,
            managedMediaRoot: fixture.root,
            adaptiveGlyphPayloadService: service
        )

        harness.worker.setCaptureEnabled(true)
        type(":experimental:", into: harness.worker)

        let fallbackReported = await eventually {
            harness.diagnostics.values.contains {
                guard case let .mediaCopyFallbackAvailable(value) = $0 else {
                    return false
                }
                return value.reason == .animatedWebPExperimental
                    && value.payload != nil
            }
        }
        XCTAssertTrue(fallbackReported)
        XCTAssertEqual(harness.poster.pasteCount, 0)
        XCTAssertEqual(harness.system.text, ":experimental:")
    }

    func testCustomMediaOutsideMessagesLeavesTokenAndReportsCopyFallback() async throws {
        let png = Data([
            0x89, 0x50, 0x4E, 0x47,
            0x0D, 0x0A, 0x1A, 0x0A,
            0x01
        ])
        let fixture = try makeMediaFixture(data: png, filename: "pond.png")
        let harness = try makeHarness(
            items: [
                mediaEmoji(
                    shortcode: "pond",
                    mediaType: .png,
                    relativePath: fixture.relativePath,
                    data: png
                )
            ],
            targetText: ":pond:",
            bundleIdentifier: "com.apple.TextEdit",
            managedMediaRoot: fixture.root
        )

        harness.worker.setCaptureEnabled(true)
        type(":pond:", into: harness.worker)

        let didReportFallback = await eventually {
            harness.diagnostics.values.contains {
                guard
                    case let .mediaCopyFallbackAvailable(diagnostic) = $0
                else {
                    return false
                }
                return diagnostic.source
                    == .customEmoji(shortcode: "pond")
                    && diagnostic.reason == .notMessages
                    && diagnostic.payload?.representations.first?.data
                        == png
            }
        }
        XCTAssertTrue(didReportFallback)
        XCTAssertEqual(harness.poster.pasteCount, 0)
        XCTAssertEqual(harness.system.text, ":pond:")
    }

    func testCustomMediaHashMismatchFailsClosed() async throws {
        let gif = Data("GIF89a-tampered".utf8)
        let fixture = try makeMediaFixture(data: gif, filename: "bufo.gif")
        let item = EmojiItem(
            id: "custom.bufo",
            shortcode: Shortcode(rawValue: "bufo")!,
            name: "Bufo",
            category: "Custom",
            content: .media(
                MediaEmojiContent(
                    mediaType: .gif,
                    relativePath: fixture.relativePath,
                    originalFilename: "bufo.gif",
                    contentHash: String(repeating: "0", count: 64),
                    isAnimated: true
                )
            ),
            packID: "custom"
        )
        let harness = try makeHarness(
            items: [item],
            targetText: ":bufo:",
            bundleIdentifier: messages,
            managedMediaRoot: fixture.root
        )

        harness.worker.setCaptureEnabled(true)
        type(":bufo:", into: harness.worker)

        let didRejectAsset = await eventually {
            harness.diagnostics.values.contains(
                .mediaCopyFallbackAvailable(
                    RuntimeMediaCopyFallbackDiagnostic(
                        source: .customEmoji(shortcode: "bufo"),
                        reason: .invalidManagedAsset
                    )
                )
            )
        }
        XCTAssertTrue(didRejectAsset)
        XCTAssertEqual(harness.poster.pasteCount, 0)
        XCTAssertEqual(harness.system.text, ":bufo:")
    }

    private var messages: String {
        "com.apple.MobileSMS"
    }

    private func makeHarness(
        items: [EmojiItem] = [],
        targetText: String,
        bundleIdentifier: String,
        managedMediaResolver:
            any RuntimeManagedMediaResolving =
                RuntimeManagedMediaResolver(),
        managedMediaRoot: URL? = nil,
        adaptiveGlyphPayloadService:
            AdaptiveGlyphPayloadService = AdaptiveGlyphPayloadService(),
        managedMediaPayloadBuilder:
            @escaping @Sendable (RuntimeResolvedManagedMedia) ->
                PasteboardItemPayload = { $0.pasteboardPayload },
        failClipboardRestore: Bool = false,
        presentationDelayMilliseconds: Int = 0,
        captureDelayMilliseconds: Int = 0
    ) throws -> RuntimeMediaHarness {
        let system = FakeAccessibilityTextSystem()
        system.text = targetText
        system.selection = NSRange(
            location: targetText.utf16.count,
            length: 0
        )
        let accessibility = AccessibilityTextAdapter(system: system)
        let target = try accessibility.focusedTarget()
        let captureProvider = RuntimeMediaCaptureProvider(
            target: target,
            bundleIdentifier: bundleIdentifier,
            delayMilliseconds: captureDelayMilliseconds
        )
        let presenter = RuntimeMediaRecordingPresenter()
        let gate = RuntimeInterceptionGate()
        let pasteboard = FakePasteboard(
            items: [.text("preserve clipboard")]
        )
        if failClipboardRestore {
            pasteboard.failingWriteAttempts = [2]
        }
        let poster = FakeEventPoster()
        let bridge = RuntimeMainActorBridge(
            presenter: presenter,
            insertionEngine: InsertionEngine(
                accessibility: accessibility,
                pasteboard: PasteboardTransactionCoordinator(
                    pasteboard: pasteboard
                ),
                eventPoster: poster,
                restorationDelay: .zero
            ),
            presentationDelayMilliseconds:
                presentationDelayMilliseconds
        )
        let diagnostics = RuntimeMediaDiagnosticRecorder()
        let worker = UnicodeAutocompleteRuntimeWorker(
            searchIndex: EmojiSearchIndex(items: items),
            configuration: UnicodeAutocompleteRuntimeConfiguration(
                preferences: .defaults,
                accessibilitySettleDelayMilliseconds: 0,
                accessibilityRetryLimit: 0
            ),
            interceptionGate: gate,
            contextProvider: captureProvider,
            mainActorBridge: bridge,
            managedMediaResolver: managedMediaResolver,
            managedMediaRoot: managedMediaRoot,
            adaptiveGlyphPayloadService: adaptiveGlyphPayloadService,
            managedMediaPayloadBuilder: managedMediaPayloadBuilder,
            diagnosticHandler: { diagnostic in
                diagnostics.append(diagnostic)
            }
        )
        return RuntimeMediaHarness(
            worker: worker,
            gate: gate,
            presenter: presenter,
            system: system,
            captureProvider: captureProvider,
            pasteboard: pasteboard,
            poster: poster,
            diagnostics: diagnostics
        )
    }

    private func type(
        _ text: String,
        into worker: UnicodeAutocompleteRuntimeWorker
    ) {
        for character in text {
            worker.enqueue(
                keySnapshot(
                    keyCode: character == ":" ? 41 : 0,
                    characters: String(character)
                )
            )
        }
    }

    private func keySnapshot(
        keyCode: CGKeyCode,
        characters: String? = nil,
        interceptionOutcome: EventInterceptionOutcome? = nil
    ) -> KeyboardEventSnapshot {
        KeyboardEventSnapshot(
            typeRawValue: CGEventType.keyDown.rawValue,
            keyCode: keyCode,
            flagsRawValue: 0,
            timestamp: DispatchTime.now().uptimeNanoseconds,
            characters: characters,
            interceptionOutcome: interceptionOutcome
        )
    }

    private func eventSnapshot(
        type: CGEventType
    ) -> KeyboardEventSnapshot {
        KeyboardEventSnapshot(
            typeRawValue: type.rawValue,
            keyCode: 0,
            flagsRawValue: 0,
            timestamp: 1,
            characters: nil
        )
    }

    private func mediaEmoji(
        shortcode: String,
        mediaType: AssetFormat,
        relativePath: String,
        data: Data,
        isAnimated: Bool? = nil
    ) -> EmojiItem {
        EmojiItem(
            id: "custom.\(shortcode)",
            shortcode: Shortcode(rawValue: shortcode)!,
            name: shortcode,
            category: "Custom",
            content: .media(
                MediaEmojiContent(
                    mediaType: mediaType,
                    relativePath: relativePath,
                    originalFilename: URL(
                        fileURLWithPath: relativePath
                    ).lastPathComponent,
                    contentHash: digest(data),
                    isAnimated:
                        isAnimated ?? mediaType.supportsAnimation
                )
            ),
            packID: "custom"
        )
    }

    private func makeMediaFixture(
        data: Data,
        filename: String
    ) throws -> (root: URL, relativePath: String) {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "MojiPondRuntimeAutocomplete-\(UUID().uuidString)",
                isDirectory: true
            )
        let directory = root.appendingPathComponent(
            "assets",
            isDirectory: true
        )
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )
        let relativePath = "assets/\(filename)"
        try data.write(to: root.appendingPathComponent(relativePath))
        temporaryRoots.append(root)
        return (root, relativePath)
    }

    private func digest(_ data: Data) -> String {
        SHA256.hash(data: data)
            .map { String(format: "%02x", $0) }
            .joined()
    }

    @available(macOS 15.0, *)
    private func adaptiveGlyph(
        from payload: PasteboardItemPayload
    ) throws -> NSAdaptiveImageGlyph {
        let pasteboard = NSPasteboard(
            name: NSPasteboard.Name(
                "MojiPondRuntimeGlyphTests-\(UUID().uuidString)"
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
        return try XCTUnwrap(
            attributed.attribute(
                .adaptiveImageGlyph,
                at: 0,
                effectiveRange: nil
            ) as? NSAdaptiveImageGlyph
        )
    }

    private var validGIFData: Data {
        Data(
            base64Encoded:
                "R0lGODlhAQABAIAAAAAAAP///ywAAAAAAQABAAACAUwAOw=="
        )!
    }

    private func eventually(
        timeout: Duration = .seconds(1),
        condition: @escaping @MainActor () async -> Bool
    ) async -> Bool {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: timeout)
        while clock.now < deadline {
            if await condition() {
                return true
            }
            try? await Task.sleep(for: .milliseconds(5))
        }
        return await condition()
    }
}

private struct RuntimeMediaHarness {
    let worker: UnicodeAutocompleteRuntimeWorker
    let gate: RuntimeInterceptionGate
    let presenter: RuntimeMediaRecordingPresenter
    let system: FakeAccessibilityTextSystem
    let captureProvider: RuntimeMediaCaptureProvider
    let pasteboard: FakePasteboard
    let poster: FakeEventPoster
    let diagnostics: RuntimeMediaDiagnosticRecorder
}

@MainActor
private final class RuntimeMediaRecordingPresenter:
    RuntimeSuggestionPresenting
{
    private(set) var suggestionUpdates: [RuntimeSuggestionPanelUpdate] = []

    var latestSuggestion: RuntimeSuggestionPanelSnapshot? {
        suggestionUpdates.reversed().compactMap {
            update -> RuntimeSuggestionPanelSnapshot? in
            guard case let .show(snapshot, _) = update else {
                return nil
            }
            return snapshot
        }.first
    }

    func apply(_ update: RuntimeSuggestionPanelUpdate) {
        suggestionUpdates.append(update)
    }
}

private final class RuntimeMediaCaptureProvider:
    RuntimeTextContextCapturing,
    @unchecked Sendable
{
    private let target: AccessibilityTextTarget
    private let bundleIdentifier: String
    private let delayMilliseconds: Int
    private let lock = NSLock()
    private var storedCaptureCount = 0

    init(
        target: AccessibilityTextTarget,
        bundleIdentifier: String,
        delayMilliseconds: Int
    ) {
        self.target = target
        self.bundleIdentifier = bundleIdentifier
        self.delayMilliseconds = max(0, delayMilliseconds)
    }

    var captureCount: Int {
        lock.withLock {
            storedCaptureCount
        }
    }

    func capture(
        expectedToken: String,
        trigger: Character
    ) throws -> RuntimeTextCapture {
        _ = trigger
        lock.withLock {
            storedCaptureCount += 1
        }
        if delayMilliseconds > 0 {
            Thread.sleep(
                forTimeInterval: Double(delayMilliseconds) / 1_000
            )
        }
        let length = expectedToken.utf16.count
        return RuntimeTextCapture(
            target: target,
            context: AccessibilityTextContext(
                selection: NSRange(location: length, length: 0),
                caretBounds: CGRect(
                    x: 120,
                    y: 180,
                    width: 1,
                    height: 18
                ),
                textFragment: expectedToken,
                textFragmentRange: NSRange(location: 0, length: length),
                tokenRange: NSRange(location: 0, length: length)
            ),
            bundleIdentifier: bundleIdentifier
        )
    }
}

private struct RuntimeManagedMediaResolverStub:
    RuntimeManagedMediaResolving,
    Sendable
{
    let handler: @Sendable (
        MediaEmojiContent,
        URL
    ) throws -> RuntimeResolvedManagedMedia

    init(
        handler: @escaping @Sendable (
            MediaEmojiContent,
            URL
        ) throws -> RuntimeResolvedManagedMedia
    ) {
        self.handler = handler
    }

    func resolve(
        _ media: MediaEmojiContent,
        beneath managedRoot: URL
    ) throws -> RuntimeResolvedManagedMedia {
        try handler(media, managedRoot)
    }
}

private final class RuntimeMediaPayloadBuilderRecorder:
    @unchecked Sendable
{
    private let lock = NSLock()
    private var storage = 0

    var buildCount: Int {
        lock.withLock { storage }
    }

    func build(
        _ resolved: RuntimeResolvedManagedMedia
    ) -> PasteboardItemPayload {
        _ = resolved
        lock.withLock {
            storage += 1
        }
        return .text("photo fallback")
    }
}

private final class RuntimeMediaDiagnosticRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [UnicodeAutocompleteRuntimeDiagnostic] = []

    var values: [UnicodeAutocompleteRuntimeDiagnostic] {
        lock.withLock { storage }
    }

    func append(_ value: UnicodeAutocompleteRuntimeDiagnostic) {
        lock.withLock {
            storage.append(value)
        }
    }
}
