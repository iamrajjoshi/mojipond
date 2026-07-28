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

    func testCustomGIFExactTokenPastesOriginalInMessages() async throws {
        let gif = validGIFData
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
        XCTAssertFalse(
            harness.diagnostics.values.contains {
                switch $0 {
                case .unsupportedTarget,
                     .clipboardRestoreFailed,
                     .sessionDenied,
                     .mediaCopyFallbackAvailable:
                    true
                case .sessionAllowed:
                    false
                }
            }
        )
    }

    func testCustomPNGAutocompleteSelectionPastesInMessages() async throws {
        let png = Data([
            0x89, 0x50, 0x4E, 0x47,
            0x0D, 0x0A, 0x1A, 0x0A,
            0x01
        ])
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
        harness.worker.enqueue(
            keySnapshot(keyCode: RuntimeKeyboardKeyCode.tab)
        )

        let didPaste = await eventually {
            harness.poster.pasteCount == 1
        }
        XCTAssertTrue(didPaste)
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

    func testAnimatedWebPUsesExplicitExperimentalCopyFallback() async throws {
        let webP = try XCTUnwrap(
            Data(
                base64Encoded:
                    "UklGRiIAAABXRUJQVlA4IBYAAAAwAQCdASoBAAEADMDOJaQAA3AA/v89WAAAAA=="
            )
        )
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

    func testStickerCommandShowsOfflineGridAndInsertsSelectedOriginal() async throws {
        let original = validGIFData
        let results = commandResults(
            command: .sticker,
            provider: .notoAnimatedEmoji,
            ids: ["frog", "fox"],
            offline: true
        )
        let coordinator = RuntimeMediaCoordinatorStub(
            response: .offline(results),
            download: MediaCommandDownload(
                data: original,
                contentType: "image/gif",
                suggestedFilename: "original.gif"
            )
        )
        let harness = try makeHarness(
            targetText: "/sticker frog",
            bundleIdentifier: messages,
            mediaCoordinator: coordinator
        )

        harness.worker.setCaptureEnabled(true)
        type("/sticker frog", into: harness.worker)

        let didShowOfflineResults = await eventually {
            harness.presenter.latestMedia?.state == .offline
        }
        XCTAssertTrue(didShowOfflineResults)
        XCTAssertEqual(
            harness.presenter.latestMedia?.attributions,
            [.notoAnimatedEmoji]
        )
        XCTAssertEqual(harness.gate.mode, .media)

        harness.worker.enqueue(
            keySnapshot(keyCode: RuntimeKeyboardKeyCode.rightArrow)
        )
        harness.worker.enqueue(
            keySnapshot(keyCode: RuntimeKeyboardKeyCode.returnKey)
        )

        let didInsert = await eventually {
            harness.poster.pasteCount == 1
        }
        XCTAssertTrue(didInsert)
        let resolvedID = await coordinator.lastResolvedID()
        XCTAssertEqual(resolvedID, "fox")
        XCTAssertEqual(harness.gate.mode, .hidden)
    }

    func testGIFCommandIsMessagesOnlyAndPassesExplicitNetworkOptions() async throws {
        let coordinator = RuntimeMediaCoordinatorStub(
            response: .empty(
                MediaCommandRequest(id: 1, command: .gif)
            ),
            download: MediaCommandDownload(
                data: Data("GIF89a-unused".utf8),
                contentType: "image/gif",
                suggestedFilename: "unused.gif"
            )
        )
        let outsideMessages = try makeHarness(
            targetText: "/gif frog",
            bundleIdentifier: "com.apple.TextEdit",
            mediaCoordinator: coordinator
        )
        outsideMessages.worker.setCaptureEnabled(true)
        type("/gif frog", into: outsideMessages.worker)
        try? await Task.sleep(for: .milliseconds(80))
        let outsideSearchCount = await coordinator.searchCount()
        XCTAssertEqual(outsideSearchCount, 0)
        XCTAssertNil(outsideMessages.presenter.latestMedia)

        let options = MediaCommandNetworkOptions(
            allowsNotoNetwork: false,
            allowsGIPHYNetwork: true
        )
        let inMessages = try makeHarness(
            targetText: "/gif frog",
            bundleIdentifier: messages,
            mediaCoordinator: coordinator,
            networkOptions: options
        )
        inMessages.worker.setCaptureEnabled(true)
        type("/gif frog", into: inMessages.worker)

        let didShowEmpty = await eventually {
            inMessages.presenter.latestMedia?.state == .empty
        }
        XCTAssertTrue(didShowEmpty)
        let searchCount = await coordinator.searchCount()
        let recordedOptions = await coordinator.lastNetworkOptions()
        XCTAssertEqual(searchCount, 1)
        XCTAssertEqual(recordedOptions, options)
    }

    func testMediaPositioningFailureNeverArmsInterception() async throws {
        let coordinator = RuntimeMediaCoordinatorStub(
            response: .empty(
                MediaCommandRequest(id: 1, command: .sticker)
            ),
            download: MediaCommandDownload(
                data: validGIFData,
                contentType: "image/gif",
                suggestedFilename: "unused.gif"
            )
        )
        let harness = try makeHarness(
            targetText: "/sticker frog",
            bundleIdentifier: messages,
            mediaCoordinator: coordinator
        )
        harness.presenter.allowsMediaPresentation = false
        harness.worker.setCaptureEnabled(true)
        type("/sticker frog", into: harness.worker)

        let failedClosed = await eventually {
            let attemptedShow = harness.presenter.mediaUpdates.contains {
                if case .show = $0 {
                    return true
                }
                return false
            }
            guard case .hide? = harness.presenter.mediaUpdates.last else {
                return false
            }
            return attemptedShow && harness.gate.mode == .hidden
        }

        XCTAssertTrue(failedClosed)
        XCTAssertEqual(harness.system.text, "/sticker frog")
        XCTAssertEqual(
            harness.gate.decision(
                for: keySnapshot(
                    keyCode: RuntimeKeyboardKeyCode.returnKey
                )
            ),
            .passThrough
        )
    }

    func testPassThroughReturnBeforeMediaIsVisibleNeverActivatesResult()
        async throws {
        let coordinator = RuntimeMediaCoordinatorStub(
            response: .results(
                commandResults(
                    command: .sticker,
                    provider: .notoAnimatedEmoji,
                    ids: ["frog"],
                    offline: true
                )
            ),
            download: MediaCommandDownload(
                data: validGIFData,
                contentType: "image/gif",
                suggestedFilename: "frog.gif"
            )
        )
        let harness = try makeHarness(
            targetText: "/sticker frog",
            bundleIdentifier: messages,
            mediaCoordinator: coordinator,
            presentationDelayMilliseconds: 120
        )
        harness.worker.setCaptureEnabled(true)
        type("/sticker frog", into: harness.worker)
        let searchStarted = await eventually {
            await coordinator.searchCount() == 1
        }
        XCTAssertTrue(searchStarted)

        harness.worker.enqueue(
            keySnapshot(
                keyCode: RuntimeKeyboardKeyCode.returnKey,
                interceptionOutcome: .passThrough
            )
        )
        try? await Task.sleep(for: .milliseconds(220))

        let resolveCount = await coordinator.resolveCount()
        XCTAssertEqual(resolveCount, 0)
        XCTAssertEqual(harness.poster.pasteCount, 0)
        XCTAssertEqual(harness.gate.mode, .hidden)
    }

    func testStaleMediaSearchIsCancelledAndCannotOverwriteFreshResults() async throws {
        let coordinator = RuntimeMediaCoordinatorStub(
            response: .results(
                commandResults(
                    command: .gif,
                    provider: .giphy,
                    ids: ["fresh"],
                    offline: false
                )
            ),
            download: MediaCommandDownload(
                data: Data("GIF89a-unused".utf8),
                contentType: "image/gif",
                suggestedFilename: "unused.gif"
            ),
            firstSearchDelay: .milliseconds(300)
        )
        let harness = try makeHarness(
            targetText: "/gif first",
            bundleIdentifier: messages,
            mediaCoordinator: coordinator,
            networkOptions: MediaCommandNetworkOptions(
                allowsNotoNetwork: false,
                allowsGIPHYNetwork: true
            )
        )
        harness.worker.setCaptureEnabled(true)
        type("/gif first", into: harness.worker)
        let didStartFirstSearch = await eventually {
            await coordinator.searchCount() == 1
        }
        XCTAssertTrue(didStartFirstSearch)

        harness.system.text = "/gif firstx"
        harness.system.selection = NSRange(
            location: harness.system.text.utf16.count,
            length: 0
        )
        harness.worker.enqueue(
            keySnapshot(keyCode: 0, characters: "x")
        )

        let didShowFreshResults = await eventually(timeout: .seconds(2)) {
            harness.presenter.latestMedia?.items.map(\.id) == ["fresh"]
        }
        XCTAssertTrue(didShowFreshResults)
        let cancelCount = await coordinator.cancelCount()
        XCTAssertGreaterThanOrEqual(cancelCount, 1)
    }

    func testEscapeDuringResolveCannotPasteCancelledMedia() async throws {
        let results = commandResults(
            command: .gif,
            provider: .giphy,
            ids: ["delayed"],
            offline: false
        )
        let coordinator = RuntimeMediaCoordinatorStub(
            response: .results(results),
            download: MediaCommandDownload(
                data: validGIFData,
                contentType: "image/gif",
                suggestedFilename: "delayed.gif"
            ),
            resolveDelay: .milliseconds(150),
            ignoresResolveCancellation: true
        )
        let harness = try makeHarness(
            targetText: "/gif delayed",
            bundleIdentifier: messages,
            mediaCoordinator: coordinator,
            networkOptions: MediaCommandNetworkOptions(
                allowsNotoNetwork: false,
                allowsGIPHYNetwork: true
            )
        )
        harness.worker.setCaptureEnabled(true)
        type("/gif delayed", into: harness.worker)
        let didShowResults = await eventually {
            harness.presenter.latestMedia?.state == .results
        }
        XCTAssertTrue(didShowResults)

        harness.worker.enqueue(
            keySnapshot(keyCode: RuntimeKeyboardKeyCode.returnKey)
        )
        let resolveStarted = await eventually {
            await coordinator.resolveCount() == 1
        }
        XCTAssertTrue(resolveStarted)
        harness.worker.enqueue(
            keySnapshot(keyCode: RuntimeKeyboardKeyCode.escape)
        )

        try? await Task.sleep(for: .milliseconds(250))
        XCTAssertEqual(harness.poster.pasteCount, 0)
        XCTAssertEqual(harness.system.text, "/gif delayed")
        XCTAssertEqual(harness.gate.mode, .hidden)
    }

    func testVisibleMediaGridExpiresBeforeLateActivation() async throws {
        let coordinator = RuntimeMediaCoordinatorStub(
            response: .results(
                commandResults(
                    command: .gif,
                    provider: .giphy,
                    ids: ["stale"],
                    offline: false
                )
            ),
            download: MediaCommandDownload(
                data: validGIFData,
                contentType: "image/gif",
                suggestedFilename: "stale.gif"
            )
        )
        let harness = try makeHarness(
            targetText: "/gif stale",
            bundleIdentifier: messages,
            mediaCoordinator: coordinator,
            networkOptions: MediaCommandNetworkOptions(
                allowsNotoNetwork: false,
                allowsGIPHYNetwork: true
            ),
            mediaInactivityTimeoutMilliseconds: 100
        )
        harness.worker.setCaptureEnabled(true)
        type("/gif stale", into: harness.worker)
        let shown = await eventually {
            harness.presenter.latestMedia?.state == .results
        }
        XCTAssertTrue(shown)

        try? await Task.sleep(for: .milliseconds(180))
        harness.worker.enqueue(
            keySnapshot(keyCode: RuntimeKeyboardKeyCode.returnKey)
        )
        try? await Task.sleep(for: .milliseconds(80))

        let resolveCount = await coordinator.resolveCount()
        XCTAssertEqual(resolveCount, 0)
        XCTAssertEqual(harness.poster.pasteCount, 0)
        XCTAssertEqual(harness.gate.mode, .hidden)
    }

    func testMediaPanelStateMappingCoversEverySearchState() {
        let request = MediaCommandRequest(id: 1, command: .gif)
        let results = MediaCommandResults(
            request: request,
            items: [],
            attributions: []
        )
        XCTAssertEqual(MediaCommandSearchState.idle.runtimePanelState, .idle)
        XCTAssertEqual(
            MediaCommandSearchState.loading(request).runtimePanelState,
            .loading
        )
        XCTAssertEqual(
            MediaCommandSearchState.results(results).runtimePanelState,
            .results
        )
        XCTAssertEqual(
            MediaCommandSearchState.offline(results).runtimePanelState,
            .offline
        )
        XCTAssertEqual(
            MediaCommandSearchState.empty(request).runtimePanelState,
            .empty
        )
        XCTAssertEqual(
            MediaCommandSearchState.cancelled(request).runtimePanelState,
            .cancelled
        )
        XCTAssertEqual(
            MediaCommandSearchState.networkDisabled(request).runtimePanelState,
            .networkDisabled
        )
        XCTAssertEqual(
            MediaCommandSearchState.rateLimited(request).runtimePanelState,
            .rateLimited
        )
        XCTAssertEqual(
            MediaCommandSearchState.failed(
                request,
                .missingGIPHYAPIKey
            ).runtimePanelState,
            .failed(.missingGIPHYAPIKey)
        )
    }

    private var messages: String {
        MediaCommandParser.messagesBundleIdentifier
    }

    private func makeHarness(
        items: [EmojiItem] = [],
        targetText: String,
        bundleIdentifier: String,
        managedMediaRoot: URL? = nil,
        mediaCoordinator:
            (any RuntimeMediaCommandCoordinating)? = nil,
        networkOptions: MediaCommandNetworkOptions = .offlineOnly,
        failClipboardRestore: Bool = false,
        mediaInactivityTimeoutMilliseconds: Int = 8_000,
        presentationDelayMilliseconds: Int = 0
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
            bundleIdentifier: bundleIdentifier
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
        var preferences = MojiPondPreferences.defaults
        preferences.network = NetworkPreferences(
            allowsGitHubImports: false,
            allowsStickerSearch: networkOptions.allowsNotoNetwork,
            allowsGIFSearch: networkOptions.allowsGIPHYNetwork,
            allowsUpdateChecks: false
        )
        let diagnostics = RuntimeMediaDiagnosticRecorder()
        let worker = UnicodeAutocompleteRuntimeWorker(
            searchIndex: EmojiSearchIndex(items: items),
            configuration: UnicodeAutocompleteRuntimeConfiguration(
                preferences: preferences,
                accessibilitySettleDelayMilliseconds: 0,
                accessibilityRetryLimit: 0,
                mediaSearchDebounceMilliseconds: 0,
                mediaResultLimit: 12,
                mediaInactivityTimeoutMilliseconds:
                    mediaInactivityTimeoutMilliseconds
            ),
            interceptionGate: gate,
            contextProvider: captureProvider,
            mainActorBridge: bridge,
            frontmostApplication: FixedFrontmostApplicationProvider(
                value: bundleIdentifier
            ),
            managedMediaRoot: managedMediaRoot,
            mediaCommandCoordinator: mediaCoordinator,
            diagnosticHandler: { diagnostic in
                diagnostics.append(diagnostic)
            }
        )
        return RuntimeMediaHarness(
            worker: worker,
            gate: gate,
            presenter: presenter,
            system: system,
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

    private func mediaEmoji(
        shortcode: String,
        mediaType: EmojiMediaType,
        relativePath: String,
        data: Data
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
                    isAnimated: mediaType.supportsAnimation
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

    private var validGIFData: Data {
        Data(
            base64Encoded:
                "R0lGODlhAQABAIAAAAAAAP///ywAAAAAAQABAAACAUwAOw=="
        )!
    }

    private func commandResults(
        command: MediaCommandKind,
        provider: RemoteMediaProvider,
        ids: [String],
        offline: Bool
    ) -> MediaCommandResults {
        let items = ids.map { id in
            let url = URL(string: "https://media.example/\(id).gif")!
            return MediaCommandResult(
                media: RemoteMediaItem(
                    id: id,
                    provider: provider,
                    title: id.capitalized,
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
        return MediaCommandResults(
            request: MediaCommandRequest(id: 1, command: command),
            items: items,
            attributions: provider == .giphy
                ? [.giphy]
                : [.notoAnimatedEmoji]
        )
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
    let pasteboard: FakePasteboard
    let poster: FakeEventPoster
    let diagnostics: RuntimeMediaDiagnosticRecorder
}

@MainActor
private final class RuntimeMediaRecordingPresenter:
    RuntimeSuggestionPresenting
{
    private(set) var suggestionUpdates: [RuntimeSuggestionPanelUpdate] = []
    private(set) var mediaUpdates: [RuntimeMediaPanelUpdate] = []
    var allowsMediaPresentation = true

    var latestSuggestion: RuntimeSuggestionPanelSnapshot? {
        suggestionUpdates.reversed().compactMap {
            update -> RuntimeSuggestionPanelSnapshot? in
            guard case let .show(snapshot, _) = update else {
                return nil
            }
            return snapshot
        }.first
    }

    var latestMedia: RuntimeMediaPanelSnapshot? {
        mediaUpdates.reversed().compactMap {
            update -> RuntimeMediaPanelSnapshot? in
            guard case let .show(snapshot, _) = update else {
                return nil
            }
            return snapshot
        }.first
    }

    func apply(_ update: RuntimeSuggestionPanelUpdate) {
        suggestionUpdates.append(update)
    }

    func applyMedia(_ update: RuntimeMediaPanelUpdate) {
        mediaUpdates.append(update)
    }

    func applyMediaReportingVisibility(
        _ update: RuntimeMediaPanelUpdate
    ) -> Bool {
        applyMedia(update)
        return allowsMediaPresentation
    }
}

private final class RuntimeMediaCaptureProvider:
    RuntimeTextContextCapturing,
    @unchecked Sendable
{
    private let target: AccessibilityTextTarget
    private let bundleIdentifier: String

    init(
        target: AccessibilityTextTarget,
        bundleIdentifier: String
    ) {
        self.target = target
        self.bundleIdentifier = bundleIdentifier
    }

    func capture(
        expectedToken: String,
        trigger: Character
    ) throws -> RuntimeTextCapture {
        _ = trigger
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

private struct FixedFrontmostApplicationProvider:
    RuntimeFrontmostApplicationProviding
{
    let value: String?

    func bundleIdentifier() -> String? {
        value
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

private actor RuntimeMediaCoordinatorStub:
    RuntimeMediaCommandCoordinating
{
    private let response: MediaCommandSearchState
    private let download: MediaCommandDownload
    private let firstSearchDelay: Duration?
    private let resolveDelay: Duration?
    private let ignoresResolveCancellation: Bool
    private var searches = 0
    private var cancellations = 0
    private var resolutions = 0
    private var resolvedID: String?
    private var networkOptions: MediaCommandNetworkOptions?

    init(
        response: MediaCommandSearchState,
        download: MediaCommandDownload,
        firstSearchDelay: Duration? = nil,
        resolveDelay: Duration? = nil,
        ignoresResolveCancellation: Bool = false
    ) {
        self.response = response
        self.download = download
        self.firstSearchDelay = firstSearchDelay
        self.resolveDelay = resolveDelay
        self.ignoresResolveCancellation = ignoresResolveCancellation
    }

    func search(
        command: MediaCommandKind,
        query: String,
        bundleIdentifier: String?,
        networkOptions: MediaCommandNetworkOptions,
        limit: Int
    ) async -> MediaCommandSearchState {
        _ = command
        _ = query
        _ = bundleIdentifier
        _ = limit
        searches += 1
        self.networkOptions = networkOptions
        if searches == 1, let firstSearchDelay {
            do {
                try await Task.sleep(for: firstSearchDelay)
            } catch {
                return .cancelled(
                    MediaCommandRequest(id: 1, command: command)
                )
            }
        }
        return response
    }

    func cancel() -> MediaCommandSearchState {
        cancellations += 1
        return .idle
    }

    func resolve(
        _ result: MediaCommandResult
    ) async throws -> MediaCommandDownload {
        resolutions += 1
        resolvedID = result.id
        if let resolveDelay {
            if ignoresResolveCancellation {
                try? await Task.sleep(for: resolveDelay)
            } else {
                try await Task.sleep(for: resolveDelay)
            }
        }
        return download
    }

    func searchCount() -> Int {
        searches
    }

    func cancelCount() -> Int {
        cancellations
    }

    func resolveCount() -> Int {
        resolutions
    }

    func lastResolvedID() -> String? {
        resolvedID
    }

    func lastNetworkOptions() -> MediaCommandNetworkOptions? {
        networkOptions
    }

}
