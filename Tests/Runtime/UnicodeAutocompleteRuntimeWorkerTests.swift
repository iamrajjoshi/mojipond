import CoreGraphics
import XCTest
@testable import MojiPond

@MainActor
final class UnicodeAutocompleteRuntimeWorkerTests: XCTestCase {
    func testClosingTokenReplacesExactMatchButNeverPrefix() async throws {
        let exact = try makeHarness(
            items: [emoji(shortcode: "frog", value: "🐸")],
            targetText: ":frog:"
        )
        exact.worker.setCaptureEnabled(true)
        type(":frog:", into: exact.worker)

        let exactInserted = await eventually {
            exact.system.text == "🐸"
        }
        XCTAssertTrue(exactInserted)

        let prefix = try makeHarness(
            items: [emoji(shortcode: "frog", value: "🐸")],
            targetText: ":fro:"
        )
        prefix.worker.setCaptureEnabled(true)
        type(":fro:", into: prefix.worker)
        try? await Task.sleep(for: .milliseconds(80))

        XCTAssertEqual(prefix.system.text, ":fro:")
    }

    func testResetCancelsStaleDelayedInsertion() async throws {
        let harness = try makeHarness(
            items: [emoji(shortcode: "frog", value: "🐸")],
            targetText: ":frog:",
            settleDelayMilliseconds: 40
        )
        harness.worker.setCaptureEnabled(true)
        type(":frog:", into: harness.worker)
        harness.worker.reset(.cursorMoved)
        try? await Task.sleep(for: .milliseconds(160))

        XCTAssertEqual(harness.system.text, ":frog:")
        XCTAssertEqual(harness.gate.mode, .hidden)
    }

    func testSelectionMovementThenTabAcceptsSelectedResult() async throws {
        let harness = try makeHarness(
            items: [
                emoji(shortcode: "frog", value: "🐸"),
                emoji(shortcode: "fox", value: "🦊")
            ],
            targetText: ":f"
        )
        harness.worker.setCaptureEnabled(true)
        type(":f", into: harness.worker)
        let suggestionsShown = await eventually {
            harness.presenter.latestShown?.mode == .suggestions
        }
        XCTAssertTrue(suggestionsShown)
        let shownSnapshot = try XCTUnwrap(
            harness.presenter.latestShown
        )
        XCTAssertGreaterThan(shownSnapshot.rows.count, 1)
        let expectedSelection = shownSnapshot.rows[1].glyph

        harness.worker.enqueue(
            keySnapshot(keyCode: RuntimeKeyboardKeyCode.downArrow)
        )
        harness.worker.enqueue(
            keySnapshot(keyCode: RuntimeKeyboardKeyCode.tab)
        )

        let selectedInserted = await eventually {
            harness.system.text == expectedSelection
        }
        XCTAssertTrue(selectedInserted)
    }

    func testDoubleTriggerOpensLargerLocalBrowser() async throws {
        let harness = try makeHarness(
            items: [
                emoji(shortcode: "frog", value: "🐸"),
                emoji(shortcode: "fox", value: "🦊")
            ],
            targetText: "::"
        )
        harness.worker.setCaptureEnabled(true)
        type("::", into: harness.worker)

        let browserShown = await eventually {
            harness.presenter.latestShown?.mode == .browser
        }
        XCTAssertTrue(browserShown)
        XCTAssertEqual(harness.gate.mode, .browser)
    }

    func testMissingCaretBoundsFailsClosedAndNeverShowsPanel() async throws {
        let harness = try makeHarness(
            items: [emoji(shortcode: "frog", value: "🐸")],
            targetText: ":f",
            caretBounds: nil
        )
        harness.worker.setCaptureEnabled(true)
        type(":f", into: harness.worker)

        let captureAttempted = await eventually {
            harness.captureProvider.captureCount > 0
        }
        XCTAssertTrue(captureAttempted)
        try? await Task.sleep(for: .milliseconds(40))
        XCTAssertNil(harness.presenter.latestShown)
        XCTAssertEqual(harness.gate.mode, .hidden)
    }

    func testPermissionExclusionAndSecureDenialsResetSession() async throws {
        let denials: [RuntimeSessionDenial] = [
            .permissionUnavailable,
            .excludedApplication("com.apple.Terminal"),
            .secureField
        ]

        for denial in denials {
            let diagnostics = RuntimeDiagnosticRecorder()
            let harness = try makeHarness(
                items: [emoji(shortcode: "frog", value: "🐸")],
                targetText: ":f",
                captureError: .denied(denial),
                diagnosticHandler: { diagnostic in
                    diagnostics.append(diagnostic)
                }
            )
            harness.worker.setCaptureEnabled(true)
            type(":f", into: harness.worker)

            let denialReported = await eventually {
                diagnostics.values.contains(.sessionDenied(denial))
            }
            XCTAssertTrue(
                denialReported,
                "Missing diagnostic for \(denial)"
            )
            XCTAssertEqual(harness.gate.mode, .hidden)
            XCTAssertNil(harness.presenter.latestShown)
        }
    }

    private func makeHarness(
        items: [EmojiItem],
        targetText: String,
        caretBounds: CGRect? = CGRect(
            x: 120,
            y: 180,
            width: 1,
            height: 18
        ),
        settleDelayMilliseconds: Int = 0,
        captureError: RuntimeTextCaptureError? = nil,
        diagnosticHandler:
            (@Sendable (UnicodeAutocompleteRuntimeDiagnostic) -> Void)? = nil
    ) throws -> RuntimeWorkerHarness {
        let system = FakeAccessibilityTextSystem()
        system.text = targetText
        system.selection = NSRange(
            location: targetText.utf16.count,
            length: 0
        )
        let accessibility = AccessibilityTextAdapter(system: system)
        let target = try accessibility.focusedTarget()
        let captureProvider = FixedRuntimeTextCaptureProvider(
            target: target,
            caretBounds: caretBounds,
            error: captureError
        )
        let presenter = RuntimeRecordingPresenter()
        let gate = RuntimeInterceptionGate()
        let bridge = RuntimeMainActorBridge(
            presenter: presenter,
            insertionEngine: InsertionEngine(
                accessibility: accessibility,
                pasteboard: PasteboardTransactionCoordinator(
                    pasteboard: FakePasteboard()
                ),
                eventPoster: FakeEventPoster(),
                restorationDelay: .zero
            )
        )
        let worker = UnicodeAutocompleteRuntimeWorker(
            searchIndex: EmojiSearchIndex(items: items),
            configuration: UnicodeAutocompleteRuntimeConfiguration(
                accessibilitySettleDelayMilliseconds:
                    settleDelayMilliseconds,
                accessibilityRetryLimit: 0
            ),
            interceptionGate: gate,
            contextProvider: captureProvider,
            mainActorBridge: bridge,
            diagnosticHandler: diagnosticHandler
        )
        return RuntimeWorkerHarness(
            worker: worker,
            gate: gate,
            presenter: presenter,
            system: system,
            captureProvider: captureProvider
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
        characters: String? = nil
    ) -> KeyboardEventSnapshot {
        KeyboardEventSnapshot(
            typeRawValue: CGEventType.keyDown.rawValue,
            keyCode: keyCode,
            flagsRawValue: 0,
            timestamp: 1,
            characters: characters
        )
    }

    private func emoji(
        shortcode: String,
        value: String
    ) -> EmojiItem {
        EmojiItem(
            id: "test.\(shortcode)",
            shortcode: Shortcode(rawValue: shortcode)!,
            name: shortcode,
            category: "test",
            content: .unicode(UnicodeEmojiContent(value: value)),
            packID: "test"
        )
    }

    private func eventually(
        timeout: Duration = .seconds(1),
        condition: @MainActor () -> Bool
    ) async -> Bool {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: timeout)
        while clock.now < deadline {
            if condition() {
                return true
            }
            try? await Task.sleep(for: .milliseconds(5))
        }
        return condition()
    }
}

private struct RuntimeWorkerHarness {
    let worker: UnicodeAutocompleteRuntimeWorker
    let gate: RuntimeInterceptionGate
    let presenter: RuntimeRecordingPresenter
    let system: FakeAccessibilityTextSystem
    let captureProvider: FixedRuntimeTextCaptureProvider
}

@MainActor
private final class RuntimeRecordingPresenter: RuntimeSuggestionPresenting {
    private(set) var updates: [RuntimeSuggestionPanelUpdate] = []

    var latestShown: RuntimeSuggestionPanelSnapshot? {
        updates.reversed().lazy.compactMap { update in
            guard case let .show(snapshot, _) = update else {
                return nil
            }
            return snapshot
        }.first
    }

    func apply(_ update: RuntimeSuggestionPanelUpdate) {
        updates.append(update)
    }
}

private final class FixedRuntimeTextCaptureProvider:
    RuntimeTextContextCapturing,
    @unchecked Sendable
{
    private let target: AccessibilityTextTarget
    private let caretBounds: CGRect?
    private let error: RuntimeTextCaptureError?
    private let lock = NSLock()
    private var storedCaptureCount = 0

    init(
        target: AccessibilityTextTarget,
        caretBounds: CGRect?,
        error: RuntimeTextCaptureError?
    ) {
        self.target = target
        self.caretBounds = caretBounds
        self.error = error
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
        if let error {
            throw error
        }
        let length = expectedToken.utf16.count
        return RuntimeTextCapture(
            target: target,
            context: AccessibilityTextContext(
                selection: NSRange(location: length, length: 0),
                caretBounds: caretBounds,
                textFragment: expectedToken,
                textFragmentRange: NSRange(location: 0, length: length),
                tokenRange: NSRange(location: 0, length: length)
            )
        )
    }
}

private final class RuntimeDiagnosticRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var storedValues: [UnicodeAutocompleteRuntimeDiagnostic] = []

    var values: [UnicodeAutocompleteRuntimeDiagnostic] {
        lock.withLock {
            storedValues
        }
    }

    func append(_ value: UnicodeAutocompleteRuntimeDiagnostic) {
        lock.withLock {
            storedValues.append(value)
        }
    }
}
