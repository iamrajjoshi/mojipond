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

    func testSuggestionRefreshKeepsVisiblePanelAndInterceptionUntilUpdated()
        async throws
    {
        let harness = try makeHarness(
            items: [emoji(shortcode: "frog", value: "🐸")],
            targetText: ":fr",
            settleDelayMilliseconds: 80
        )
        harness.worker.setCaptureEnabled(true)
        type(":f", into: harness.worker)
        let initialShown = await eventually {
            harness.gate.mode == .suggestions
        }
        XCTAssertTrue(initialShown)

        let updateStart = harness.presenter.updates.count
        harness.worker.enqueue(
            keySnapshot(keyCode: 15, characters: "r")
        )
        let presentationRetained = await eventually(
            timeout: .milliseconds(50)
        ) {
            harness.presenter.updates.dropFirst(updateStart).contains {
                guard case .retain = $0 else {
                    return false
                }
                return true
            }
        }
        XCTAssertTrue(presentationRetained)
        XCTAssertEqual(harness.gate.mode, .suggestions)
        XCTAssertFalse(
            harness.presenter.updates.dropFirst(updateStart).contains {
                guard case .hide = $0 else {
                    return false
                }
                return true
            }
        )

        let refreshed = await eventually {
            harness.presenter.updates.dropFirst(updateStart).contains {
                guard case .show = $0 else {
                    return false
                }
                return true
            }
        }
        XCTAssertTrue(refreshed)

        let refreshUpdates = harness.presenter.updates.dropFirst(updateStart)
        XCTAssertFalse(
            refreshUpdates.contains {
                guard case .hide = $0 else {
                    return false
                }
                return true
            }
        )
        XCTAssertEqual(harness.gate.mode, .suggestions)
    }

    func testImmediateTabDuringSuggestionRefreshAcceptsSelection()
        async throws
    {
        try await assertImmediateAcceptanceDuringSuggestionRefresh(
            keyCode: RuntimeKeyboardKeyCode.tab
        )
    }

    func testImmediateReturnDuringSuggestionRefreshAcceptsSelection()
        async throws
    {
        try await assertImmediateAcceptanceDuringSuggestionRefresh(
            keyCode: RuntimeKeyboardKeyCode.returnKey
        )
    }

    func testDelayedStaleRefreshCannotRepaintAfterNewerCharacter()
        async throws
    {
        let harness = try makeHarness(
            items: [emoji(shortcode: "frog", value: "🐸")],
            targetText: ":fro",
            presentationDelayMilliseconds: 120
        )
        harness.worker.setCaptureEnabled(true)
        type(":f", into: harness.worker)
        let initialShown = await eventually {
            harness.gate.mode == .suggestions
        }
        XCTAssertTrue(initialShown)

        let updateStart = harness.presenter.updates.count
        let captureStart = harness.captureProvider.captureCount
        harness.worker.enqueue(
            keySnapshot(keyCode: 15, characters: "r")
        )
        let firstRefreshCaptured = await eventually {
            harness.captureProvider.captureCount > captureStart
        }
        XCTAssertTrue(firstRefreshCaptured)

        harness.worker.enqueue(
            keySnapshot(keyCode: 31, characters: "o")
        )
        let didRetainPresentation = await eventually {
            harness.presenter.updates.dropFirst(updateStart).contains {
                guard case .retain = $0 else {
                    return false
                }
                return true
            }
        }
        XCTAssertTrue(didRetainPresentation)
        let revision = try XCTUnwrap(
            harness.presenter.updates.dropFirst(updateStart)
                .compactMap { update -> UInt64? in
                    guard case let .retain(revision) = update else {
                        return nil
                    }
                    return revision
                }
                .max()
        )
        let latestRefreshShown = await eventually(
            timeout: .milliseconds(400)
        ) {
            harness.presenter.updates.dropFirst(updateStart).contains {
                guard case let .show(snapshot, _) = $0 else {
                    return false
                }
                return snapshot.revision > revision
            }
        }

        XCTAssertTrue(latestRefreshShown)
        XCTAssertFalse(
            harness.presenter.updates.dropFirst(updateStart).contains {
                guard case let .show(snapshot, _) = $0 else {
                    return false
                }
                return snapshot.revision < revision
            }
        )
    }

    func testSuggestionRefreshHidesPanelWhenResultsBecomeEmpty()
        async throws
    {
        let harness = try makeHarness(
            items: [emoji(shortcode: "frog", value: "🐸")],
            targetText: ":fz"
        )
        harness.worker.setCaptureEnabled(true)
        type(":f", into: harness.worker)
        let initialShown = await eventually {
            harness.gate.mode == .suggestions
        }
        XCTAssertTrue(initialShown)

        let updateStart = harness.presenter.updates.count
        harness.worker.enqueue(
            keySnapshot(keyCode: 6, characters: "z")
        )
        let hidden = await eventually {
            harness.presenter.updates.dropFirst(updateStart).contains {
                guard case .hide = $0 else {
                    return false
                }
                return true
            }
        }

        XCTAssertTrue(hidden)
        XCTAssertEqual(harness.gate.mode, .hidden)
    }

    func testSuggestionRefreshCaptureFailureHidesVisiblePanelAndDisablesInterception()
        async throws
    {
        let harness = try makeHarness(
            items: [emoji(shortcode: "frog", value: "🐸")],
            targetText: ":fr"
        )
        harness.worker.setCaptureEnabled(true)
        type(":f", into: harness.worker)
        let initialShown = await eventually {
            harness.gate.mode == .suggestions
        }
        XCTAssertTrue(initialShown)

        let updateStart = harness.presenter.updates.count
        harness.captureProvider.setError(.invalidTokenContext)
        harness.worker.enqueue(
            keySnapshot(keyCode: 15, characters: "r")
        )
        let hidden = await eventually {
            harness.presenter.updates.dropFirst(updateStart).contains {
                guard case .hide = $0 else {
                    return false
                }
                return true
            }
        }

        XCTAssertTrue(hidden)
        try? await Task.sleep(for: .milliseconds(40))
        XCTAssertEqual(harness.gate.mode, .hidden)
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

    func testDoubleTriggerBrowserContainsTheCompleteLibrary() async throws {
        let items = (0..<75).map {
            emoji(shortcode: "pond_\($0)", value: "🐸")
        }
        let harness = try makeHarness(
            items: items,
            targetText: "::"
        )
        harness.worker.setCaptureEnabled(true)
        type("::", into: harness.worker)

        let completeBrowserShown = await eventually {
            harness.presenter.latestShown?.mode == .browser
                && harness.presenter.latestShown?.rows.count == items.count
        }

        XCTAssertTrue(completeBrowserShown)
        XCTAssertEqual(
            Set(harness.presenter.latestShown?.rows.map(\.shortcode) ?? []),
            Set(items.map(\.shortcode.rawValue))
        )
    }

    func testBrowserSelectionKeyRepeatReusesRowsForLargeLibrary()
        async throws
    {
        let items = (0..<1_700).map {
            emoji(
                shortcode: String(format: "pond_%04d", $0),
                value: "🐸"
            )
        }
        let harness = try makeHarness(
            items: items,
            targetText: "hello",
            parserTimeout: 10
        )
        harness.worker.setCaptureEnabled(true)
        harness.worker.openBrowser()

        let browserShown = await eventually(timeout: .seconds(5)) {
            harness.presenter.latestShown?.mode == .browser
                && harness.presenter.latestShown?.rows.count == items.count
                && harness.gate.mode == .browser
        }
        XCTAssertTrue(browserShown)
        let initialSnapshot = try XCTUnwrap(
            harness.presenter.latestShown
        )
        let updateStart = harness.presenter.updates.count

        let keyRepeatCount = 64
        for _ in 0..<keyRepeatCount {
            harness.worker.enqueue(
                keySnapshot(
                    keyCode: RuntimeKeyboardKeyCode.downArrow
                )
            )
        }

        let keyRepeatPresented = await eventually(timeout: .seconds(5)) {
            harness.presenter.latestShown?.selectedIndex == keyRepeatCount
                && harness.presenter.updates.count
                    >= updateStart + keyRepeatCount
        }
        XCTAssertTrue(keyRepeatPresented)

        let selectionSnapshots = harness.presenter.updates
            .dropFirst(updateStart)
            .compactMap { update -> RuntimeSuggestionPanelSnapshot? in
                guard case let .show(snapshot, _) = update else {
                    return nil
                }
                return snapshot
            }
        XCTAssertEqual(selectionSnapshots.count, keyRepeatCount)
        XCTAssertEqual(
            Set(
                ([initialSnapshot] + selectionSnapshots).map {
                    rowStorageAddress($0.rows)
                }
            ).count,
            1,
            "Selection-only updates must reuse immutable presentation rows."
        )
    }

    func testBrowserOwnsAFilteredVirtualQueryAndBackspace() async throws {
        let harness = try makeHarness(
            items: [
                emoji(shortcode: "frog", value: "🐸"),
                emoji(shortcode: "whale", value: "🐋")
            ],
            targetText: "::"
        )
        harness.worker.setCaptureEnabled(true)
        type("::", into: harness.worker)
        let browserShown = await eventually {
            harness.presenter.latestShown?.mode == .browser
        }
        XCTAssertTrue(browserShown)

        harness.worker.enqueue(
            keySnapshot(keyCode: 3, characters: "f")
        )
        let filtered = await eventually {
            harness.presenter.latestShown?.query == "f"
        }
        XCTAssertTrue(filtered)
        XCTAssertEqual(
            harness.presenter.latestShown?.rows.map(\.shortcode),
            ["frog"]
        )
        XCTAssertEqual(harness.system.text, "::")
        XCTAssertEqual(harness.gate.mode, .browser)

        harness.worker.enqueue(
            keySnapshot(keyCode: 6, characters: "z")
        )
        let noMatch = await eventually {
            harness.presenter.latestShown?.query == "fz"
                && harness.presenter.latestShown?.rows.isEmpty == true
        }
        XCTAssertTrue(noMatch)
        XCTAssertEqual(harness.gate.mode, .browser)

        harness.worker.enqueue(
            keySnapshot(keyCode: RuntimeKeyboardKeyCode.delete)
        )
        harness.worker.enqueue(
            keySnapshot(keyCode: RuntimeKeyboardKeyCode.delete)
        )
        let resetToAll = await eventually {
            harness.presenter.latestShown?.query == ""
                && harness.presenter.latestShown?.rows.count == 2
        }
        XCTAssertTrue(resetToAll)
        XCTAssertEqual(harness.gate.mode, .browser)
    }

    func testMenuBrowserAnchorsAtCaretWithoutMutatingText() async throws {
        let harness = try makeHarness(
            items: [emoji(shortcode: "frog", value: "🐸")],
            targetText: "hello"
        )
        harness.worker.setCaptureEnabled(true)
        harness.worker.openBrowser()

        let browserShown = await eventually {
            harness.presenter.latestShown?.mode == .browser
        }
        XCTAssertTrue(browserShown)
        XCTAssertEqual(harness.system.text, "hello")

        harness.worker.enqueue(
            keySnapshot(keyCode: RuntimeKeyboardKeyCode.returnKey)
        )
        let inserted = await eventually {
            harness.system.text == "hello🐸"
        }
        XCTAssertTrue(inserted)
    }

    func testMenuBrowserFailsClosedWhenCaretCannotBeCaptured() async throws {
        let diagnostics = RuntimeDiagnosticRecorder()
        let harness = try makeHarness(
            items: [emoji(shortcode: "frog", value: "🐸")],
            targetText: "hello",
            captureError: .inaccessibleTarget,
            diagnosticHandler: { diagnostic in
                diagnostics.append(diagnostic)
            }
        )
        harness.worker.setCaptureEnabled(true)
        harness.worker.openBrowser()

        let unsupportedReported = await eventually {
            diagnostics.values.contains(.unsupportedTarget)
        }
        XCTAssertTrue(unsupportedReported)
        XCTAssertNil(harness.presenter.latestShown)
        XCTAssertEqual(harness.gate.mode, .hidden)
        XCTAssertEqual(harness.system.text, "hello")
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

    func testSuggestionPositioningFailureNeverArmsInterception() async throws {
        let harness = try makeHarness(
            items: [emoji(shortcode: "frog", value: "🐸")],
            targetText: ":f"
        )
        harness.presenter.allowsPresentation = false
        harness.worker.setCaptureEnabled(true)
        type(":f", into: harness.worker)

        let failedClosed = await eventually {
            let attemptedShow = harness.presenter.updates.contains {
                if case .show = $0 {
                    return true
                }
                return false
            }
            guard case .hide? = harness.presenter.updates.last else {
                return false
            }
            return attemptedShow && harness.gate.mode == .hidden
        }

        XCTAssertTrue(failedClosed)
        XCTAssertEqual(harness.system.text, ":f")
        XCTAssertEqual(
            harness.gate.decision(
                for: keySnapshot(
                    keyCode: RuntimeKeyboardKeyCode.downArrow
                )
            ),
            .passThrough
        )
    }

    func testPassThroughReturnBeforeSuggestionIsVisibleNeverAccepts()
        async throws {
        let harness = try makeHarness(
            items: [emoji(shortcode: "frog", value: "🐸")],
            targetText: ":f",
            presentationDelayMilliseconds: 120
        )
        harness.worker.setCaptureEnabled(true)
        type(":f", into: harness.worker)
        let captureFinished = await eventually {
            harness.captureProvider.captureCount > 0
        }
        XCTAssertTrue(captureFinished)

        harness.worker.enqueue(
            keySnapshot(
                keyCode: RuntimeKeyboardKeyCode.returnKey,
                interceptionOutcome: .passThrough
            )
        )
        try? await Task.sleep(for: .milliseconds(180))

        XCTAssertEqual(harness.system.text, ":f")
        XCTAssertEqual(harness.gate.mode, .hidden)
    }

    func testPassThroughBrowserCharacterBeforeVisibilityNeverChangesQuery()
        async throws {
        let harness = try makeHarness(
            items: [emoji(shortcode: "frog", value: "🐸")],
            targetText: "::",
            presentationDelayMilliseconds: 120
        )
        harness.worker.setCaptureEnabled(true)
        type("::", into: harness.worker)
        let captureFinished = await eventually {
            harness.captureProvider.captureCount > 0
        }
        XCTAssertTrue(captureFinished)

        harness.worker.enqueue(
            keySnapshot(
                keyCode: 7,
                characters: "x",
                interceptionOutcome: .passThrough
            )
        )
        try? await Task.sleep(for: .milliseconds(180))

        XCTAssertFalse(
            harness.presenter.updates.contains {
                guard case let .show(snapshot, _) = $0 else {
                    return false
                }
                return snapshot.query == "x"
            }
        )
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

    func testSuggestionPanelExpiresWithoutAnotherKeyEvent() async throws {
        let harness = try makeHarness(
            items: [emoji(shortcode: "frog", value: "🐸")],
            targetText: ":f",
            parserTimeout: 0.1
        )
        harness.worker.setCaptureEnabled(true)
        type(":f", into: harness.worker)
        let shown = await eventually {
            harness.gate.mode == .suggestions
        }
        XCTAssertTrue(shown)

        let hidden = await eventually(timeout: .milliseconds(500)) {
            harness.gate.mode == .hidden
        }
        XCTAssertTrue(hidden)
    }

    func testNavigationRearmsSuggestionInactivityTimeout() async throws {
        let harness = try makeHarness(
            items: [
                emoji(shortcode: "frog", value: "🐸"),
                emoji(shortcode: "fox", value: "🦊")
            ],
            targetText: ":f",
            parserTimeout: 0.15
        )
        harness.worker.setCaptureEnabled(true)
        type(":f", into: harness.worker)
        let shown = await eventually {
            harness.gate.mode == .suggestions
        }
        XCTAssertTrue(shown)

        try? await Task.sleep(for: .milliseconds(90))
        harness.worker.enqueue(
            keySnapshot(keyCode: RuntimeKeyboardKeyCode.downArrow)
        )
        try? await Task.sleep(for: .milliseconds(90))
        XCTAssertEqual(harness.gate.mode, .suggestions)

        let eventuallyHidden = await eventually(timeout: .milliseconds(400)) {
            harness.gate.mode == .hidden
        }
        XCTAssertTrue(eventuallyHidden)
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
        parserTimeout: TimeInterval = 3,
        presentationDelayMilliseconds: Int = 0,
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
            selectionLocation: targetText.utf16.count,
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
            ),
            presentationDelayMilliseconds:
                presentationDelayMilliseconds
        )
        var preferences = MojiPondPreferences.defaults
        preferences.shortcode.parserTimeout = parserTimeout
        let worker = UnicodeAutocompleteRuntimeWorker(
            searchIndex: EmojiSearchIndex(items: items),
            configuration: UnicodeAutocompleteRuntimeConfiguration(
                preferences: preferences,
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

    private func assertImmediateAcceptanceDuringSuggestionRefresh(
        keyCode: CGKeyCode
    ) async throws {
        let harness = try makeHarness(
            items: [emoji(shortcode: "frog", value: "🐸")],
            targetText: ":fr",
            settleDelayMilliseconds: 80
        )
        harness.worker.setCaptureEnabled(true)
        type(":f", into: harness.worker)
        let initialShown = await eventually {
            harness.gate.mode == .suggestions
        }
        XCTAssertTrue(initialShown)

        let updateStart = harness.presenter.updates.count
        harness.worker.enqueue(
            keySnapshot(keyCode: 15, characters: "r")
        )
        let refreshStarted = await eventually(
            timeout: .milliseconds(50)
        ) {
            harness.presenter.updates.dropFirst(updateStart).contains {
                guard case .retain = $0 else {
                    return false
                }
                return true
            }
        }
        XCTAssertTrue(refreshStarted)

        let acceptance = keySnapshot(keyCode: keyCode)
        let outcome = harness.gate.outcome(for: acceptance)
        XCTAssertEqual(outcome, .intercepting(.suggestions))
        harness.worker.enqueue(acceptance.delivered(with: outcome))

        let inserted = await eventually {
            harness.system.text == "🐸"
        }
        XCTAssertTrue(inserted)
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
            timestamp: 1,
            characters: characters,
            interceptionOutcome: interceptionOutcome
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

    private func rowStorageAddress(
        _ rows: [RuntimeSuggestionRow]
    ) -> Int {
        rows.withUnsafeBufferPointer { buffer in
            guard let baseAddress = buffer.baseAddress else {
                return 0
            }
            return Int(bitPattern: baseAddress)
        }
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
    var allowsPresentation = true
    private var latestRevision: UInt64 = 0

    var latestShown: RuntimeSuggestionPanelSnapshot? {
        updates.reversed().lazy.compactMap { update in
            guard case let .show(snapshot, _) = update else {
                return nil
            }
            return snapshot
        }.first
    }

    func apply(_ update: RuntimeSuggestionPanelUpdate) {
        guard update.revision >= latestRevision else {
            return
        }
        latestRevision = update.revision
        updates.append(update)
    }

    func applyReportingVisibility(
        _ update: RuntimeSuggestionPanelUpdate
    ) -> Bool {
        apply(update)
        return allowsPresentation
    }
}

private final class FixedRuntimeTextCaptureProvider:
    RuntimeTextContextCapturing,
    @unchecked Sendable
{
    private let target: AccessibilityTextTarget
    private let selectionLocation: Int
    private let caretBounds: CGRect?
    private let lock = NSLock()
    private var error: RuntimeTextCaptureError?
    private var storedCaptureCount = 0

    init(
        target: AccessibilityTextTarget,
        selectionLocation: Int,
        caretBounds: CGRect?,
        error: RuntimeTextCaptureError?
    ) {
        self.target = target
        self.selectionLocation = selectionLocation
        self.caretBounds = caretBounds
        self.error = error
    }

    var captureCount: Int {
        lock.withLock {
            storedCaptureCount
        }
    }

    func setError(_ error: RuntimeTextCaptureError?) {
        lock.withLock {
            self.error = error
        }
    }

    func capture(
        expectedToken: String,
        trigger: Character
    ) throws -> RuntimeTextCapture {
        _ = trigger
        let capturedError = lock.withLock {
            storedCaptureCount += 1
            return error
        }
        if let capturedError {
            throw capturedError
        }
        let length = expectedToken.utf16.count
        let tokenLocation = selectionLocation - length
        guard tokenLocation >= 0 else {
            throw RuntimeTextCaptureError.invalidTokenContext
        }
        return RuntimeTextCapture(
            target: target,
            context: AccessibilityTextContext(
                selection: NSRange(
                    location: selectionLocation,
                    length: 0
                ),
                caretBounds: caretBounds,
                textFragment: expectedToken,
                textFragmentRange: NSRange(
                    location: tokenLocation,
                    length: length
                ),
                tokenRange: NSRange(
                    location: tokenLocation,
                    length: length
                )
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
