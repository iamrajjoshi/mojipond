import CoreGraphics
import XCTest
@testable import MojiPond

@MainActor
final class UnicodeAutocompleteRuntimeWorkerTests: XCTestCase {
    func testSuggestionLimitRetainsEnoughRowsToScrollWithoutGrowingPanel() {
        XCTAssertEqual(
            UnicodeAutocompleteRuntimeConfiguration().suggestionLimit,
            60
        )
        XCTAssertEqual(
            UnicodeAutocompleteRuntimeConfiguration(
                suggestionLimit: 99
            ).suggestionLimit,
            99
        )
        XCTAssertEqual(
            UnicodeAutocompleteRuntimeConfiguration(
                suggestionLimit: 101
            ).suggestionLimit,
            100
        )
        XCTAssertEqual(
            UnicodeAutocompleteRuntimeConfiguration(
                suggestionLimit: 0
            ).suggestionLimit,
            1
        )
    }

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

    func testReturnImmediatelyAfterExactCloseSendsOnlyAfterInsertion()
        async throws
    {
        let harness = try makeHarness(
            items: [emoji(shortcode: "frog", value: "🐸")],
            targetText: ":frog:",
            presentationDelayMilliseconds: 160
        )
        harness.worker.setCaptureEnabled(true)
        harness.gate.setCaptureEnabled(true)
        deliver(":fro", into: harness)
        let safePrefixVerified = await eventually {
            harness.gate.isExactCommitArmed
        }
        XCTAssertTrue(safePrefixVerified)
        XCTAssertEqual(harness.gate.mode, .hidden)

        let finalCharacter = keySnapshot(
            keyCode: 5,
            characters: "g"
        )
        let finalCharacterOutcome = harness.gate.outcome(
            for: finalCharacter
        )
        let closingTrigger = keySnapshot(
            keyCode: 41,
            characters: ":"
        )
        let closingOutcome = harness.gate.outcome(for: closingTrigger)
        XCTAssertEqual(closingOutcome.decision, .passThrough)

        let returnKey = keySnapshot(
            keyCode: RuntimeKeyboardKeyCode.returnKey
        )
        let returnOutcome = harness.gate.outcome(for: returnKey)
        XCTAssertEqual(returnOutcome, .intercepting(.committing))

        // Let the older presentation attempt reach the main actor after the
        // gate has synchronously armed the commit. Its gate rejection must
        // not cancel the still-valid parser transaction.
        try? await Task.sleep(for: .milliseconds(180))

        // Deliver only after every event-tap decision has been made. This
        // matches production when worker delivery trails the event tap.
        harness.worker.enqueue(
            finalCharacter.delivered(with: finalCharacterOutcome)
        )
        harness.worker.enqueue(
            closingTrigger.delivered(with: closingOutcome)
        )
        harness.worker.enqueue(
            returnKey.delivered(with: returnOutcome)
        )

        let insertedThenSent = await eventually {
            harness.system.text == "🐸"
                && harness.poster.returnCount == 1
        }
        XCTAssertTrue(insertedThenSent)
        XCTAssertEqual(harness.poster.pasteCount, 0)
    }

    func testRecoveredExactCloseStillInterceptsImmediateReturn()
        async throws
    {
        let harness = try makeHarness(
            items: [emoji(shortcode: "frog", value: "🐸")],
            targetText: ":frog:",
            presentationDelayMilliseconds: 160
        )
        harness.worker.setCaptureEnabled(true)
        harness.gate.setCaptureEnabled(true)
        deliver(":fro", into: harness)
        let initiallyArmed = await eventually {
            harness.gate.isExactCommitArmed
        }
        XCTAssertTrue(initiallyArmed)

        let space = keySnapshot(keyCode: 49, characters: " ")
        let spaceOutcome = harness.gate.outcome(for: space)
        harness.worker.enqueue(space.delivered(with: spaceOutcome))
        let hidden = await eventually {
            harness.gate.mode == .hidden
        }
        XCTAssertTrue(hidden)

        let backspace = keySnapshot(
            keyCode: RuntimeKeyboardKeyCode.delete
        )
        let backspaceOutcome = harness.gate.outcome(for: backspace)
        harness.worker.enqueue(
            backspace.delivered(with: backspaceOutcome)
        )
        let restored = await eventually {
            harness.gate.mode == .suggestions
                && harness.gate.isExactCommitArmed
        }
        XCTAssertTrue(restored)

        let finalCharacter = keySnapshot(
            keyCode: 5,
            characters: "g"
        )
        let finalCharacterOutcome = harness.gate.outcome(
            for: finalCharacter
        )
        let closingTrigger = keySnapshot(
            keyCode: 41,
            characters: ":"
        )
        let closingOutcome = harness.gate.outcome(for: closingTrigger)
        XCTAssertEqual(closingOutcome.decision, .passThrough)

        let returnKey = keySnapshot(
            keyCode: RuntimeKeyboardKeyCode.returnKey
        )
        let returnOutcome = harness.gate.outcome(for: returnKey)
        XCTAssertEqual(returnOutcome, .intercepting(.committing))

        harness.worker.enqueue(
            finalCharacter.delivered(with: finalCharacterOutcome)
        )
        harness.worker.enqueue(
            closingTrigger.delivered(with: closingOutcome)
        )
        harness.worker.enqueue(
            returnKey.delivered(with: returnOutcome)
        )

        let insertedThenSent = await eventually {
            harness.system.text == "🐸"
                && harness.poster.returnCount == 1
        }
        XCTAssertTrue(insertedThenSent)
        XCTAssertEqual(harness.poster.pasteCount, 0)
    }

    func testBlockedReturnReportsMissingSendPermissionAfterInsertion()
        async throws
    {
        let diagnostics = RuntimeDiagnosticRecorder()
        let harness = try makeHarness(
            items: [emoji(shortcode: "frog", value: "🐸")],
            targetText: ":frog:",
            canPostEvents: false,
            diagnosticHandler: { diagnostic in
                diagnostics.append(diagnostic)
            }
        )
        harness.worker.setCaptureEnabled(true)
        harness.gate.setCaptureEnabled(true)
        deliver(":frog", into: harness)
        let exactCommitArmed = await eventually {
            harness.gate.isExactCommitArmed
        }
        XCTAssertTrue(exactCommitArmed)

        let closingTrigger = keySnapshot(
            keyCode: 41,
            characters: ":"
        )
        let closingOutcome = harness.gate.outcome(for: closingTrigger)
        let returnKey = keySnapshot(
            keyCode: RuntimeKeyboardKeyCode.returnKey
        )
        let returnOutcome = harness.gate.outcome(for: returnKey)
        XCTAssertEqual(returnOutcome, .intercepting(.committing))

        harness.worker.enqueue(
            closingTrigger.delivered(with: closingOutcome)
        )
        harness.worker.enqueue(
            returnKey.delivered(with: returnOutcome)
        )

        let failureExplained = await eventually {
            harness.system.text == "🐸"
                && diagnostics.values.contains(
                    .sendAfterInsertionUnavailable
                )
        }
        XCTAssertTrue(failureExplained)
        XCTAssertEqual(harness.poster.returnCount, 0)
    }

    func testInterceptedReturnSurvivesDelayedEventTapDelivery()
        async throws
    {
        let harness = try makeHarness(
            items: [emoji(shortcode: "frog", value: "🐸")],
            targetText: ":frog:",
            presentationDelayMilliseconds: 160
        )
        harness.worker.setCaptureEnabled(true)
        harness.gate.setCaptureEnabled(true)
        deliver(":fro", into: harness)
        let exactCommitArmed = await eventually {
            harness.gate.isExactCommitArmed
        }
        XCTAssertTrue(exactCommitArmed)

        let returnHandlerReached = DispatchSemaphore(value: 0)
        let releaseReturnHandler = DispatchSemaphore(value: 0)
        let worker = harness.worker
        let gate = harness.gate
        let eventTap = SessionEventTapService(
            label: "test.delayed-return-delivery",
            interceptionPolicy: { snapshot in
                gate.outcome(for: snapshot)
            },
            eventHandler: { snapshot in
                if snapshot.keyCode == RuntimeKeyboardKeyCode.returnKey {
                    returnHandlerReached.signal()
                    _ = releaseReturnHandler.wait(
                        timeout: .now() + 2
                    )
                }
                worker.enqueue(snapshot)
            }
        )
        defer {
            releaseReturnHandler.signal()
            withExtendedLifetime(eventTap) {}
        }

        XCTAssertEqual(
            eventTap.process(
                keySnapshot(keyCode: 5, characters: "g")
            ),
            .passThrough
        )
        XCTAssertEqual(
            eventTap.process(
                keySnapshot(keyCode: 41, characters: ":")
            ),
            .passThrough
        )
        XCTAssertEqual(
            eventTap.process(
                keySnapshot(
                    keyCode: RuntimeKeyboardKeyCode.returnKey
                )
            ),
            .intercept
        )
        XCTAssertEqual(
            returnHandlerReached.wait(timeout: .now() + 1),
            .success
        )

        let insertedThenSent = await eventually {
            harness.system.text == "🐸"
                && harness.poster.returnCount == 1
        }
        XCTAssertTrue(insertedThenSent)
        releaseReturnHandler.signal()
    }

    func testEscapeRevokesReturnBeforeDelayedEventTapDelivery()
        async throws
    {
        let harness = try makeHarness(
            items: [emoji(shortcode: "frog", value: "🐸")],
            targetText: ":frog:",
            settleDelayMilliseconds: 80,
            presentationDelayMilliseconds: 160
        )
        harness.worker.setCaptureEnabled(true)
        harness.gate.setCaptureEnabled(true)
        deliver(":fro", into: harness)
        let exactCommitArmed = await eventually {
            harness.gate.isExactCommitArmed
        }
        XCTAssertTrue(exactCommitArmed)

        let returnHandlerReached = DispatchSemaphore(value: 0)
        let releaseReturnHandler = DispatchSemaphore(value: 0)
        let worker = harness.worker
        let gate = harness.gate
        let eventTap = SessionEventTapService(
            label: "test.escape-before-return-delivery",
            interceptionPolicy: { snapshot in
                gate.outcome(for: snapshot)
            },
            eventHandler: { snapshot in
                if snapshot.keyCode == RuntimeKeyboardKeyCode.returnKey {
                    returnHandlerReached.signal()
                    _ = releaseReturnHandler.wait(
                        timeout: .now() + 2
                    )
                }
                worker.enqueue(snapshot)
            }
        )
        defer {
            releaseReturnHandler.signal()
            withExtendedLifetime(eventTap) {}
        }

        _ = eventTap.process(
            keySnapshot(keyCode: 5, characters: "g")
        )
        _ = eventTap.process(
            keySnapshot(keyCode: 41, characters: ":")
        )
        XCTAssertEqual(
            eventTap.process(
                keySnapshot(
                    keyCode: RuntimeKeyboardKeyCode.returnKey
                )
            ),
            .intercept
        )
        XCTAssertEqual(
            eventTap.process(
                keySnapshot(keyCode: RuntimeKeyboardKeyCode.escape)
            ),
            .intercept
        )
        XCTAssertEqual(
            returnHandlerReached.wait(timeout: .now() + 1),
            .success
        )

        try? await Task.sleep(for: .milliseconds(180))
        XCTAssertEqual(harness.system.text, ":frog:")
        XCTAssertEqual(harness.poster.returnCount, 0)
        XCTAssertEqual(harness.gate.mode, .hidden)
        releaseReturnHandler.signal()
    }

    func testCharacterAfterExactCloseNeverSwallowsFollowingReturn()
        async throws
    {
        let harness = try makeHarness(
            items: [emoji(shortcode: "frog", value: "🐸")],
            targetText: ":frog:x",
            settleDelayMilliseconds: 80
        )
        harness.worker.setCaptureEnabled(true)
        harness.gate.setCaptureEnabled(true)
        deliver(":fro", into: harness)
        let safePrefixVerified = await eventually {
            harness.gate.isExactCommitArmed
        }
        XCTAssertTrue(safePrefixVerified)

        let finalCharacter = keySnapshot(
            keyCode: 5,
            characters: "g"
        )
        let finalCharacterOutcome = harness.gate.outcome(
            for: finalCharacter
        )
        let closingTrigger = keySnapshot(
            keyCode: 41,
            characters: ":"
        )
        let closingOutcome = harness.gate.outcome(for: closingTrigger)
        let invalidatingCharacter = keySnapshot(
            keyCode: 7,
            characters: "x"
        )
        let invalidatingOutcome = harness.gate.outcome(
            for: invalidatingCharacter
        )

        XCTAssertEqual(closingOutcome.decision, .passThrough)
        XCTAssertEqual(invalidatingOutcome.decision, .passThrough)
        XCTAssertEqual(harness.gate.mode, .hidden)

        // Delay delivery of the invalidating event after its event-tap
        // decision. Older close processing must not resurrect the commit.
        let updateStart = harness.presenter.updates.count
        harness.worker.enqueue(
            finalCharacter.delivered(with: finalCharacterOutcome)
        )
        harness.worker.enqueue(
            closingTrigger.delivered(with: closingOutcome)
        )
        let staleCloseProcessed = await eventually {
            harness.presenter.updates.count > updateStart
        }
        XCTAssertTrue(staleCloseProcessed)
        XCTAssertEqual(harness.gate.mode, .hidden)

        let returnKey = keySnapshot(
            keyCode: RuntimeKeyboardKeyCode.returnKey
        )
        let returnOutcome = harness.gate.outcome(for: returnKey)
        XCTAssertEqual(returnOutcome.decision, .passThrough)

        harness.worker.enqueue(
            invalidatingCharacter.delivered(with: invalidatingOutcome)
        )
        harness.worker.enqueue(
            returnKey.delivered(with: returnOutcome)
        )

        try? await Task.sleep(for: .milliseconds(220))
        XCTAssertEqual(harness.poster.returnCount, 0)
        XCTAssertEqual(harness.system.text, ":frog:x")
        XCTAssertEqual(harness.gate.mode, .hidden)
    }

    func testShiftReturnAfterExactCloseNeverArmsFollowingReturn()
        async throws
    {
        let harness = try makeHarness(
            items: [emoji(shortcode: "frog", value: "🐸")],
            targetText: ":frog:"
        )
        harness.worker.setCaptureEnabled(true)
        harness.gate.setCaptureEnabled(true)
        deliver(":fro", into: harness)
        let safePrefixVerified = await eventually {
            harness.gate.isExactCommitArmed
        }
        XCTAssertTrue(safePrefixVerified)

        let finalCharacter = keySnapshot(
            keyCode: 5,
            characters: "g"
        )
        let finalCharacterOutcome = harness.gate.outcome(
            for: finalCharacter
        )
        let closingTrigger = keySnapshot(
            keyCode: 41,
            characters: ":"
        )
        let closingOutcome = harness.gate.outcome(for: closingTrigger)
        let shiftedReturn = keySnapshot(
            keyCode: RuntimeKeyboardKeyCode.returnKey,
            flags: [.maskShift]
        )
        let shiftedReturnOutcome = harness.gate.outcome(
            for: shiftedReturn
        )
        let returnKey = keySnapshot(
            keyCode: RuntimeKeyboardKeyCode.returnKey
        )
        let returnOutcome = harness.gate.outcome(for: returnKey)

        XCTAssertEqual(shiftedReturnOutcome.decision, .passThrough)
        XCTAssertEqual(returnOutcome.decision, .passThrough)
        XCTAssertEqual(harness.gate.mode, .hidden)

        harness.worker.enqueue(
            finalCharacter.delivered(with: finalCharacterOutcome)
        )
        harness.worker.enqueue(
            closingTrigger.delivered(with: closingOutcome)
        )
        harness.worker.enqueue(
            shiftedReturn.delivered(with: shiftedReturnOutcome)
        )
        harness.worker.enqueue(
            returnKey.delivered(with: returnOutcome)
        )

        try? await Task.sleep(for: .milliseconds(120))
        XCTAssertEqual(harness.poster.returnCount, 0)
        XCTAssertEqual(harness.system.text, ":frog:")
        XCTAssertEqual(harness.gate.mode, .hidden)
    }

    func testSecondReturnAfterPickerAcceptanceSendsOnlyAfterInsertion()
        async throws
    {
        let harness = try makeHarness(
            items: [emoji(shortcode: "frog", value: "🐸")],
            targetText: ":f",
            settleDelayMilliseconds: 80
        )
        harness.worker.setCaptureEnabled(true)
        type(":f", into: harness.worker)
        let suggestionsShown = await eventually {
            harness.gate.mode == .suggestions
        }
        XCTAssertTrue(suggestionsShown)

        let firstReturn = keySnapshot(
            keyCode: RuntimeKeyboardKeyCode.returnKey
        )
        let firstOutcome = harness.gate.outcome(for: firstReturn)
        harness.worker.enqueue(firstReturn.delivered(with: firstOutcome))
        let secondReturn = keySnapshot(
            keyCode: RuntimeKeyboardKeyCode.returnKey
        )
        let secondOutcome = harness.gate.outcome(for: secondReturn)
        harness.worker.enqueue(secondReturn.delivered(with: secondOutcome))

        let insertedThenSent = await eventually {
            harness.system.text == "🐸"
                && harness.poster.returnCount == 1
        }
        XCTAssertTrue(insertedThenSent)
    }

    func testPendingSendIsDroppedWhenFocusedTargetChanges() async throws {
        let harness = try makeHarness(
            items: [emoji(shortcode: "frog", value: "🐸")],
            targetText: ":frog:",
            settleDelayMilliseconds: 80
        )
        harness.worker.setCaptureEnabled(true)
        type(":frog:", into: harness.worker)
        harness.worker.enqueue(
            keySnapshot(keyCode: RuntimeKeyboardKeyCode.returnKey)
        )
        harness.system.focusedElementReference =
            harness.system.alternateElement

        try? await Task.sleep(for: .milliseconds(180))

        XCTAssertEqual(harness.system.text, ":frog:")
        XCTAssertEqual(harness.poster.returnCount, 0)
    }

    func testEscapeDuringCommitCancelsPendingInsertionAndSend() async throws {
        let harness = try makeHarness(
            items: [emoji(shortcode: "frog", value: "🐸")],
            targetText: ":frog:",
            settleDelayMilliseconds: 80
        )
        harness.worker.setCaptureEnabled(true)
        type(":frog:", into: harness.worker)
        harness.worker.enqueue(
            keySnapshot(keyCode: RuntimeKeyboardKeyCode.returnKey)
        )
        harness.worker.enqueue(
            keySnapshot(keyCode: RuntimeKeyboardKeyCode.escape)
        )

        try? await Task.sleep(for: .milliseconds(180))

        XCTAssertEqual(harness.system.text, ":frog:")
        XCTAssertEqual(harness.poster.returnCount, 0)
        XCTAssertEqual(harness.gate.mode, .hidden)
    }

    func testSynchronousEscapeRevokesAnAlreadyStartedCommitCapture()
        async throws
    {
        let harness = try makeHarness(
            items: [emoji(shortcode: "frog", value: "🐸")],
            targetText: ":frog",
            captureDelayMilliseconds: 80
        )
        harness.worker.setCaptureEnabled(true)
        type(":frog", into: harness.worker)
        let shown = await eventually {
            harness.gate.mode == .suggestions
        }
        XCTAssertTrue(shown)

        let captureStart = harness.captureProvider.captureCount
        let acceptance = keySnapshot(
            keyCode: RuntimeKeyboardKeyCode.returnKey
        )
        let acceptanceOutcome = harness.gate.outcome(
            for: acceptance
        )
        XCTAssertEqual(
            acceptanceOutcome,
            .intercepting(.suggestions)
        )
        harness.worker.enqueue(
            acceptance.delivered(with: acceptanceOutcome)
        )
        let commitStarted = await eventually {
            harness.gate.mode == .committing
        }
        XCTAssertTrue(commitStarted)
        let captureStarted = await eventually {
            harness.captureProvider.captureCount > captureStart
        }
        XCTAssertTrue(captureStarted)

        let escape = harness.gate.outcome(
            for: keySnapshot(
                keyCode: RuntimeKeyboardKeyCode.escape
            )
        )
        XCTAssertEqual(escape, .intercepting(.committing))

        try? await Task.sleep(for: .milliseconds(140))
        XCTAssertEqual(harness.system.text, ":frog")
        XCTAssertEqual(harness.poster.returnCount, 0)
        XCTAssertEqual(harness.gate.mode, .hidden)
    }

    func testEscapeAfterInsertionCancelsScheduledSend() async throws {
        let harness = try makeHarness(
            items: [emoji(shortcode: "frog", value: "🐸")],
            targetText: ":frog:",
            settleDelayMilliseconds: 30
        )
        harness.worker.setCaptureEnabled(true)
        type(":frog:", into: harness.worker)
        harness.worker.enqueue(
            keySnapshot(keyCode: RuntimeKeyboardKeyCode.returnKey)
        )

        let inserted = await eventually {
            harness.system.text == "🐸"
        }
        XCTAssertTrue(inserted)
        let escape = keySnapshot(keyCode: RuntimeKeyboardKeyCode.escape)
        let outcome = harness.gate.outcome(for: escape)
        XCTAssertEqual(outcome, .intercepting(.committing))
        harness.worker.enqueue(escape.delivered(with: outcome))

        try? await Task.sleep(for: .milliseconds(80))

        XCTAssertEqual(harness.poster.returnCount, 0)
        XCTAssertEqual(harness.gate.mode, .hidden)
    }

    func testTransientAccessibilityCaptureUsesBoundedSettlingBackoff()
        async throws
    {
        let harness = try makeHarness(
            items: [emoji(shortcode: "frog", value: "🐸")],
            targetText: ":frog:",
            settleDelayMilliseconds: 12,
            accessibilityRetryLimit: 3,
            captureFailuresBeforeSuccess: 3
        )
        harness.worker.setCaptureEnabled(true)
        let clock = ContinuousClock()
        let startedAt = clock.now
        type(":frog:", into: harness.worker)

        let inserted = await eventually(timeout: .milliseconds(500)) {
            harness.system.text == "🐸"
        }

        XCTAssertTrue(inserted)
        XCTAssertGreaterThanOrEqual(
            startedAt.duration(to: clock.now),
            .milliseconds(70)
        )
        XCTAssertLessThan(
            startedAt.duration(to: clock.now),
            .milliseconds(300)
        )
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

    func testPointerHoverSelectsAndClickInsertsWithoutActivatingPanel()
        async throws
    {
        let harness = try makeHarness(
            items: [
                emoji(shortcode: "frog", value: "🐸"),
                emoji(shortcode: "fox", value: "🦊")
            ],
            targetText: ":f"
        )
        harness.worker.setCaptureEnabled(true)
        type(":f", into: harness.worker)
        let panelReady = await eventually {
            harness.presenter.isInteractionConfigured
                && harness.presenter.latestShown?.rows.count == 2
        }
        XCTAssertTrue(panelReady)
        let snapshot = try XCTUnwrap(harness.presenter.latestShown)
        let target = snapshot.rows[1]

        harness.presenter.send(
            .hover(
                transactionID: snapshot.transactionID,
                itemID: target.id
            )
        )
        let hovered = await eventually {
            harness.presenter.latestShown?.selectedRow?.id == target.id
        }
        XCTAssertTrue(hovered)

        harness.presenter.send(
            .accept(
                transactionID: snapshot.transactionID,
                itemID: target.id
            )
        )
        let inserted = await eventually {
            harness.system.text == target.glyph
        }
        XCTAssertTrue(inserted)
    }

    func testSuggestionRefinementPreservesSelectedItemWhenItStillMatches()
        async throws
    {
        let harness = try makeHarness(
            items: [
                emoji(shortcode: "frog", value: "🐸"),
                emoji(shortcode: "frown", value: "☹️")
            ],
            targetText: ":fr"
        )
        harness.worker.setCaptureEnabled(true)
        type(":f", into: harness.worker)
        let initiallyShown = await eventually {
            harness.presenter.latestShown?.rows.count == 2
        }
        XCTAssertTrue(initiallyShown)
        harness.worker.enqueue(
            keySnapshot(keyCode: RuntimeKeyboardKeyCode.downArrow)
        )
        let selectedID = try XCTUnwrap(
            harness.presenter.latestShown?.rows.last?.id
        )
        let selected = await eventually {
            harness.presenter.latestShown?.selectedRow?.id == selectedID
        }
        XCTAssertTrue(selected)

        harness.worker.enqueue(
            keySnapshot(keyCode: 15, characters: "r")
        )

        let preserved = await eventually {
            harness.presenter.latestShown?.rows.count == 2
                && harness.presenter.latestShown?.selectedRow?.id
                    == selectedID
        }
        XCTAssertTrue(preserved)
    }

    func testSuccessfulUnicodeSelectionRefreshesRankingWithoutRelaunch()
        async throws
    {
        let usageStore = InMemoryEmojiUsageStore()
        let harness = try makeHarness(
            items: [
                emoji(shortcode: "frog", value: "🐸"),
                emoji(shortcode: "fish", value: "🐟")
            ],
            targetText: ":f",
            usageStore: usageStore
        )
        harness.worker.setCaptureEnabled(true)
        type(":f", into: harness.worker)
        let initiallyShown = await eventually {
            harness.presenter.latestShown?.rows.count == 2
        }
        XCTAssertTrue(initiallyShown)
        let initial = try XCTUnwrap(harness.presenter.latestShown)
        let chosen = initial.rows[1]
        harness.worker.enqueue(
            keySnapshot(keyCode: RuntimeKeyboardKeyCode.downArrow)
        )
        harness.worker.enqueue(
            keySnapshot(keyCode: RuntimeKeyboardKeyCode.tab)
        )

        let useWasPersisted = await eventuallyAsync {
            guard
                let snapshot = try? await usageStore.snapshot()
            else {
                return false
            }
            return snapshot.statistics(for: chosen.id).useCount == 1
        }
        XCTAssertTrue(useWasPersisted)
        try? await Task.sleep(for: .milliseconds(30))

        type(":f", into: harness.worker)
        let reranked = await eventually {
            harness.presenter.latestShown?.transactionID
                    != initial.transactionID
                && harness.presenter.latestShown?.rows.first?.id
                    == chosen.id
        }
        XCTAssertTrue(reranked)
    }

    func testFailedUsagePersistenceDoesNotMutateInSessionRanking()
        async throws
    {
        let usageStore = FailingRuntimeEmojiUsageStore()
        let harness = try makeHarness(
            items: [
                emoji(shortcode: "frog", value: "🐸"),
                emoji(shortcode: "fox", value: "🦊")
            ],
            targetText: ":f",
            usageStore: usageStore
        )
        harness.worker.setCaptureEnabled(true)
        type(":f", into: harness.worker)
        let initiallyShown = await eventually {
            harness.presenter.latestShown?.rows.count == 2
        }
        XCTAssertTrue(initiallyShown)
        let initial = try XCTUnwrap(harness.presenter.latestShown)
        let originalFirstID = try XCTUnwrap(initial.rows.first?.id)
        harness.worker.enqueue(
            keySnapshot(keyCode: RuntimeKeyboardKeyCode.downArrow)
        )
        harness.worker.enqueue(
            keySnapshot(keyCode: RuntimeKeyboardKeyCode.tab)
        )

        let persistenceAttempted = await eventuallyAsync {
            await usageStore.recordAttempts == 1
        }
        XCTAssertTrue(persistenceAttempted)
        type(":f", into: harness.worker)

        let rankingStayedStable = await eventually {
            harness.presenter.latestShown?.transactionID
                    != initial.transactionID
                && harness.presenter.latestShown?.rows.first?.id
                    == originalFirstID
        }
        XCTAssertTrue(rankingStayedStable)
    }

    func testSuggestionSelectionScrollsPastVisibleRowsAndClampsAtBoundaries()
        async throws
    {
        let items = (0..<8).map { index in
            emoji(
                shortcode: "pond_\(index)",
                value: "selected-\(index)"
            )
        }
        let harness = try makeHarness(
            items: items,
            targetText: ":pond"
        )
        harness.worker.setCaptureEnabled(true)
        type(":pond", into: harness.worker)

        let suggestionsShown = await eventually {
            harness.presenter.latestShown?.rows.count == items.count
                && harness.presenter.latestShown?.selectedIndex == 0
        }
        XCTAssertTrue(suggestionsShown)
        let initial = try XCTUnwrap(harness.presenter.latestShown)
        XCTAssertEqual(initial.visibleRows.count, 6)

        let updateCountBeforeSelectedUp = harness.presenter.updates.count
        harness.worker.enqueue(
            keySnapshot(keyCode: RuntimeKeyboardKeyCode.upArrow)
        )
        let selectionStayedAtFirstResult = await eventually {
            harness.presenter.updates.count > updateCountBeforeSelectedUp
                && harness.presenter.latestShown?.selectedIndex == 0
        }
        XCTAssertTrue(selectionStayedAtFirstResult)

        for _ in 0..<(items.count + 3) {
            harness.worker.enqueue(
                keySnapshot(keyCode: RuntimeKeyboardKeyCode.downArrow)
            )
        }
        let selectedLastResult = await eventually {
            harness.presenter.latestShown?.selectedIndex
                == items.count - 1
        }
        XCTAssertTrue(selectedLastResult)
        let last = try XCTUnwrap(harness.presenter.latestShown)
        XCTAssertEqual(last.selectedRow?.shortcode, "pond_7")
        XCTAssertEqual(last.visibleRows.count, 6)

        harness.worker.enqueue(
            keySnapshot(keyCode: RuntimeKeyboardKeyCode.upArrow)
        )
        let selectedSeventhResult = await eventually {
            harness.presenter.latestShown?.selectedIndex == 6
        }
        XCTAssertTrue(selectedSeventhResult)
        let seventh = try XCTUnwrap(harness.presenter.latestShown)
        XCTAssertEqual(seventh.selectedRow?.shortcode, "pond_6")

        harness.worker.enqueue(
            keySnapshot(keyCode: RuntimeKeyboardKeyCode.tab)
        )
        let selectedInserted = await eventually {
            harness.system.text == "selected-6"
        }
        XCTAssertTrue(selectedInserted)
    }

    func testEscapeDismissesCurrentSuggestionsButTypingResumesThem()
        async throws
    {
        let harness = try makeHarness(
            items: [emoji(shortcode: "frog", value: "🐸")],
            targetText: ":fr"
        )
        harness.worker.setCaptureEnabled(true)
        deliver(":f", into: harness)
        let initiallyShown = await eventually {
            harness.gate.mode == .suggestions
        }
        XCTAssertTrue(initiallyShown)

        let escape = keySnapshot(keyCode: RuntimeKeyboardKeyCode.escape)
        let escapeOutcome = harness.gate.outcome(for: escape)
        XCTAssertEqual(escapeOutcome.decision, .intercept)
        harness.worker.enqueue(escape.delivered(with: escapeOutcome))
        let dismissed = await eventually {
            guard case .hide? = harness.presenter.updates.last else {
                return false
            }
            return harness.gate.mode == .hidden
        }
        XCTAssertTrue(dismissed)

        deliver("r", into: harness)
        let resumed = await eventually {
            harness.gate.mode == .suggestions
                && harness.presenter.latestShown?.rows.map(\.shortcode)
                    == ["frog"]
        }
        XCTAssertTrue(resumed)
    }

    func testCaretMovementInsideTokenKeepsSuggestionsVisible()
        async throws
    {
        let cases: [(CGKeyCode, CGEventFlags, NSRange, Bool)] = [
            (
                RuntimeKeyboardKeyCode.leftArrow,
                [],
                NSRange(location: 4, length: 0),
                true
            ),
            (
                RuntimeKeyboardKeyCode.leftArrow,
                [.maskShift],
                NSRange(location: 4, length: 1),
                true
            ),
            (
                RuntimeKeyboardKeyCode.leftArrow,
                [.maskAlternate],
                NSRange(location: 1, length: 0),
                false
            ),
            (
                RuntimeKeyboardKeyCode.leftArrow,
                [.maskCommand],
                NSRange(location: 0, length: 0),
                false
            ),
            (
                RuntimeKeyboardKeyCode.upArrow,
                [.maskShift],
                NSRange(location: 0, length: 5),
                true
            ),
            (
                RuntimeKeyboardKeyCode.downArrow,
                [.maskAlternate],
                NSRange(location: 1, length: 0),
                false
            )
        ]
        for (keyCode, flags, selection, _) in cases {
            let harness = try makeHarness(
                items: [emoji(shortcode: "frog", value: "🐸")],
                targetText: ":frog"
            )
            harness.worker.setCaptureEnabled(true)
            deliver(":frog", into: harness)
            let initiallyShown = await eventually {
                harness.gate.mode == .suggestions
            }
            XCTAssertTrue(initiallyShown)
            harness.worker.enqueue(
                keySnapshot(keyCode: RuntimeKeyboardKeyCode.downArrow)
            )
            let firstResultSelected = await eventually {
                harness.presenter.latestShown?.selectedIndex == 0
            }
            XCTAssertTrue(firstResultSelected)
            harness.captureProvider.setCurrentContext(
                token: ":frog",
                selection: selection,
                tokenLocation: 0
            )

            let updateStart = harness.presenter.updates.count
            let movement = keySnapshot(
                keyCode: keyCode,
                flags: flags
            )
            let outcome = harness.gate.outcome(for: movement)
            XCTAssertEqual(outcome.decision, .passThrough)
            XCTAssertFalse(outcome.requiresContextRecovery)
            XCTAssertEqual(harness.gate.mode, .suggestions)
            harness.worker.enqueue(movement.delivered(with: outcome))

            let preserved = await eventually {
                harness.gate.mode == .suggestions
                    && harness.presenter.updates.count > updateStart
                    && harness.presenter.latestShown?.selectedIndex == 0
                    && harness.presenter.latestShown?.acceptsTab == false
                    && harness.presenter.latestShown?.acceptsReturn == false
            }
            XCTAssertTrue(
                preserved,
                "Expected retained picker for key \(keyCode), flags \(flags)"
            )
            XCTAssertFalse(
                harness.presenter.updates.dropFirst(updateStart).contains {
                    guard case .hide = $0 else {
                        return false
                    }
                    return true
                }
            )
            XCTAssertEqual(
                harness.gate.outcome(
                    for: keySnapshot(keyCode: RuntimeKeyboardKeyCode.tab)
                ).decision,
                .passThrough
            )
        }
    }

    func testCaretMovementOutsideTokenHidesAfterSettledValidation()
        async throws
    {
        let harness = try makeHarness(
            items: [emoji(shortcode: "frog", value: "🐸")],
            targetText: ":frog",
            settleDelayMilliseconds: 80
        )
        harness.worker.setCaptureEnabled(true)
        deliver(":frog", into: harness)
        let initiallyShown = await eventually {
            harness.gate.mode == .suggestions
        }
        XCTAssertTrue(initiallyShown)

        harness.captureProvider.setCurrentContext(
            token: ":frog",
            selection: NSRange(location: 6, length: 0),
            tokenLocation: 0
        )
        let updateStart = harness.presenter.updates.count
        let movement = keySnapshot(
            keyCode: RuntimeKeyboardKeyCode.rightArrow
        )
        let outcome = harness.gate.outcome(for: movement)
        harness.worker.enqueue(movement.delivered(with: outcome))

        let preserved = await eventually {
            harness.gate.mode == .suggestions
                && harness.presenter.latestShown?.selectedIndex == 0
        }
        XCTAssertTrue(preserved)
        XCTAssertFalse(
            harness.presenter.updates.dropFirst(updateStart).contains {
                guard case .hide = $0 else {
                    return false
                }
                return true
            }
        )

        let hidden = await eventually(timeout: .milliseconds(400)) {
            harness.gate.mode == .hidden
                && harness.presenter.updates.dropFirst(updateStart).contains {
                    guard case .hide = $0 else {
                        return false
                    }
                    return true
                }
        }
        XCTAssertTrue(hidden)
    }

    func testCaretMovementBackToTokenEndReenablesSafeAcceptance()
        async throws
    {
        let harness = try makeHarness(
            items: [emoji(shortcode: "frog", value: "🐸")],
            targetText: ":frog"
        )
        harness.worker.setCaptureEnabled(true)
        deliver(":frog", into: harness)
        let initiallyShown = await eventually {
            harness.gate.mode == .suggestions
        }
        XCTAssertTrue(initiallyShown)

        harness.captureProvider.setCurrentContext(
            token: ":frog",
            selection: NSRange(location: 4, length: 0),
            tokenLocation: 0
        )
        let left = keySnapshot(keyCode: RuntimeKeyboardKeyCode.leftArrow)
        let leftOutcome = harness.gate.outcome(for: left)
        harness.worker.enqueue(left.delivered(with: leftOutcome))
        let disabledInsideToken = await eventually {
            harness.presenter.latestShown?.acceptsTab == false
                && harness.gate.mode == .suggestions
        }
        XCTAssertTrue(disabledInsideToken)

        harness.captureProvider.setCurrentContext(
            token: ":frog",
            selection: NSRange(location: 5, length: 0),
            tokenLocation: 0
        )
        let right = keySnapshot(keyCode: RuntimeKeyboardKeyCode.rightArrow)
        let rightOutcome = harness.gate.outcome(for: right)
        harness.worker.enqueue(right.delivered(with: rightOutcome))

        let reenabledAtTokenEnd = await eventually {
            harness.presenter.latestShown?.acceptsTab == true
                && harness.gate.isExactCommitArmed
        }
        XCTAssertTrue(reenabledAtTokenEnd)
        XCTAssertEqual(
            harness.gate.outcome(
                for: keySnapshot(keyCode: RuntimeKeyboardKeyCode.tab)
            ).decision,
            .intercept
        )
    }

    func testSettledSelectionValidationDoesNotClearNewPickerNavigation()
        async throws
    {
        let harness = try makeHarness(
            items: [
                emoji(shortcode: "frog", value: "🐸"),
                emoji(shortcode: "frown", value: "☹️")
            ],
            targetText: ":fr",
            settleDelayMilliseconds: 80
        )
        harness.worker.setCaptureEnabled(true)
        deliver(":fr", into: harness)
        let initiallyShown = await eventually {
            harness.gate.mode == .suggestions
        }
        XCTAssertTrue(initiallyShown)

        harness.captureProvider.setCurrentContext(
            token: ":fr",
            selection: NSRange(location: 2, length: 1),
            tokenLocation: 0
        )
        let shiftLeft = keySnapshot(
            keyCode: RuntimeKeyboardKeyCode.leftArrow,
            flags: [.maskShift]
        )
        let shiftLeftOutcome = harness.gate.outcome(for: shiftLeft)
        harness.worker.enqueue(
            shiftLeft.delivered(with: shiftLeftOutcome)
        )

        let down = keySnapshot(keyCode: RuntimeKeyboardKeyCode.downArrow)
        let downOutcome = harness.gate.outcome(for: down)
        XCTAssertEqual(downOutcome.decision, .intercept)
        harness.worker.enqueue(down.delivered(with: downOutcome))
        let selected = await eventually {
            harness.presenter.latestShown?.selectedIndex == 1
        }
        XCTAssertTrue(selected)

        try await Task.sleep(for: .milliseconds(250))
        XCTAssertEqual(harness.presenter.latestShown?.selectedIndex, 1)
        XCTAssertEqual(harness.gate.mode, .suggestions)
    }

    func testImmediateExactCloseAfterCaretRoundTripStillReplaces()
        async throws
    {
        let harness = try makeHarness(
            items: [
                emoji(shortcode: "frog", value: "🐸"),
                emoji(shortcode: "frogwave", value: "👋")
            ],
            targetText: ":frog:",
            settleDelayMilliseconds: 80
        )
        harness.worker.setCaptureEnabled(true)
        deliver(":frog", into: harness)
        let initiallyShown = await eventually {
            harness.gate.mode == .suggestions
        }
        XCTAssertTrue(initiallyShown)

        harness.captureProvider.setCurrentContext(
            token: ":frog",
            selection: NSRange(location: 4, length: 0),
            tokenLocation: 0
        )
        let left = keySnapshot(keyCode: RuntimeKeyboardKeyCode.leftArrow)
        let leftOutcome = harness.gate.outcome(for: left)
        harness.worker.enqueue(left.delivered(with: leftOutcome))

        harness.captureProvider.setCurrentContext(
            token: ":frog",
            selection: NSRange(location: 5, length: 0),
            tokenLocation: 0
        )
        let right = keySnapshot(keyCode: RuntimeKeyboardKeyCode.rightArrow)
        let rightOutcome = harness.gate.outcome(for: right)
        harness.worker.enqueue(right.delivered(with: rightOutcome))

        harness.captureProvider.setCurrentContext(
            token: ":frog:",
            selection: NSRange(location: 6, length: 0),
            tokenLocation: 0
        )
        let close = keySnapshot(keyCode: 41, characters: ":")
        let closeOutcome = harness.gate.outcome(for: close)
        XCTAssertTrue(closeOutcome.requiresContextRecovery)
        harness.worker.enqueue(close.delivered(with: closeOutcome))

        let replaced = await eventually(timeout: .milliseconds(700)) {
            harness.system.text == "🐸"
        }
        XCTAssertTrue(replaced)

        let updateStart = harness.presenter.updates.count
        deliver("w", into: harness)
        try await Task.sleep(for: .milliseconds(150))
        XCTAssertEqual(harness.gate.mode, .hidden)
        XCTAssertFalse(
            harness.presenter.updates.dropFirst(updateStart).contains {
                guard case .show = $0 else {
                    return false
                }
                return true
            }
        )
    }

    func testContextRecoveryCannotCrossFocusedTextTargets() async throws {
        let harness = try makeHarness(
            items: [
                emoji(shortcode: "frog", value: "🐸"),
                emoji(shortcode: "wave", value: "👋")
            ],
            targetText: ":frog",
            settleDelayMilliseconds: 40
        )
        harness.worker.setCaptureEnabled(true)
        deliver(":frog", into: harness)
        let initiallyShown = await eventually {
            harness.gate.mode == .suggestions
        }
        XCTAssertTrue(initiallyShown)

        harness.captureProvider.setCurrentContext(
            token: ":frog",
            selection: NSRange(location: 4, length: 0),
            tokenLocation: 0
        )
        let left = keySnapshot(keyCode: RuntimeKeyboardKeyCode.leftArrow)
        let leftOutcome = harness.gate.outcome(for: left)
        harness.worker.enqueue(left.delivered(with: leftOutcome))
        let movementSettled = await eventually {
            harness.presenter.latestShown?.acceptsTab == false
        }
        XCTAssertTrue(movementSettled)

        harness.captureProvider.setCurrentContext(
            token: ":wave",
            selection: NSRange(location: 2, length: 0),
            tokenLocation: 0
        )
        harness.captureProvider.setRepresentsSameTarget(false)
        let edit = keySnapshot(keyCode: 13, characters: "w")
        let editOutcome = harness.gate.outcome(for: edit)
        XCTAssertTrue(editOutcome.requiresContextRecovery)
        harness.worker.enqueue(edit.delivered(with: editOutcome))

        let hidden = await eventually(timeout: .milliseconds(500)) {
            harness.gate.mode == .hidden
                && harness.presenter.updates.last.map { update in
                    guard case .hide = update else {
                        return false
                    }
                    return true
                } == true
        }
        XCTAssertTrue(hidden)
    }

    func testRecoveredSuggestionsStayBoundToTheOriginalTextTarget()
        async throws
    {
        let harness = try makeHarness(
            items: [
                emoji(shortcode: "frog", value: "🐸"),
                emoji(shortcode: "wave", value: "👋")
            ],
            targetText: ":frog",
            settleDelayMilliseconds: 40
        )
        harness.worker.setCaptureEnabled(true)
        deliver(":frog", into: harness)
        let initiallyShown = await eventually {
            harness.gate.mode == .suggestions
        }
        XCTAssertTrue(initiallyShown)

        harness.captureProvider.setCurrentContext(
            token: ":frog",
            selection: NSRange(location: 4, length: 0),
            tokenLocation: 0
        )
        let left = keySnapshot(keyCode: RuntimeKeyboardKeyCode.leftArrow)
        let leftOutcome = harness.gate.outcome(for: left)
        harness.worker.enqueue(left.delivered(with: leftOutcome))
        let movementSettled = await eventually {
            harness.presenter.latestShown?.acceptsTab == false
        }
        XCTAssertTrue(movementSettled)

        let updateStart = harness.presenter.updates.count
        harness.captureProvider.setCurrentContext(
            token: ":wave",
            selection: NSRange(location: 2, length: 0),
            tokenLocation: 0
        )
        harness.captureProvider.setTargetComparisonResults([true, false])
        let edit = keySnapshot(keyCode: 13, characters: "w")
        let editOutcome = harness.gate.outcome(for: edit)
        XCTAssertTrue(editOutcome.requiresContextRecovery)
        harness.worker.enqueue(edit.delivered(with: editOutcome))

        let hidden = await eventually(timeout: .milliseconds(700)) {
            harness.gate.mode == .hidden
                && harness.presenter.updates.last.map { update in
                    guard case .hide = update else {
                        return false
                    }
                    return true
                } == true
        }
        XCTAssertTrue(hidden)
        XCTAssertFalse(
            harness.presenter.updates.dropFirst(updateStart).contains {
                guard case let .show(snapshot, _) = $0 else {
                    return false
                }
                return snapshot.rows.map(\.shortcode) == ["wave"]
            }
        )
    }

    func testInteriorEditSearchesOnlyThroughTheNewCaret() async throws {
        let harness = try makeHarness(
            items: [
                emoji(shortcode: "frog", value: "🐸"),
                emoji(shortcode: "wave", value: "👋")
            ],
            targetText: ":frog"
        )
        harness.worker.setCaptureEnabled(true)
        deliver(":frog", into: harness)
        let initiallyShown = await eventually {
            harness.gate.mode == .suggestions
        }
        XCTAssertTrue(initiallyShown)

        harness.captureProvider.setCurrentContext(
            token: ":frog",
            selection: NSRange(location: 1, length: 0),
            tokenLocation: 0
        )
        let movement = keySnapshot(
            keyCode: RuntimeKeyboardKeyCode.leftArrow,
            flags: [.maskCommand]
        )
        let movementOutcome = harness.gate.outcome(for: movement)
        harness.worker.enqueue(
            movement.delivered(with: movementOutcome)
        )
        let disabledAtInteriorCaret = await eventually {
            harness.presenter.latestShown?.acceptsTab == false
        }
        XCTAssertTrue(disabledAtInteriorCaret)

        let updateStart = harness.presenter.updates.count
        harness.captureProvider.setCurrentContext(
            token: ":wrog",
            selection: NSRange(location: 2, length: 0),
            tokenLocation: 0
        )
        let edit = keySnapshot(keyCode: 13, characters: "w")
        let editOutcome = harness.gate.outcome(for: edit)
        XCTAssertTrue(editOutcome.requiresContextRecovery)
        harness.worker.enqueue(edit.delivered(with: editOutcome))

        let refreshedFromPrefix = await eventually {
            harness.gate.mode == .suggestions
                && harness.presenter.latestShown?.rows
                    .map(\.shortcode) == ["wave"]
                && harness.presenter.latestShown?.acceptsTab == false
        }
        XCTAssertTrue(refreshedFromPrefix)
        XCTAssertFalse(
            harness.presenter.updates.dropFirst(updateStart).contains {
                guard case .hide = $0 else {
                    return false
                }
                return true
            }
        )
    }

    func testInvalidFollowUpAbandonsRetainedRecoverySurface()
        async throws
    {
        for followUp in [
            keySnapshot(keyCode: 49, characters: " "),
            keySnapshot(keyCode: RuntimeKeyboardKeyCode.escape)
        ] {
            let harness = try makeHarness(
                items: [emoji(shortcode: "frog", value: "🐸")],
                targetText: ":frog",
                settleDelayMilliseconds: 80
            )
            harness.worker.setCaptureEnabled(true)
            deliver(":frog", into: harness)
            let initiallyShown = await eventually {
                harness.gate.mode == .suggestions
            }
            XCTAssertTrue(initiallyShown)

            let movement = keySnapshot(
                keyCode: RuntimeKeyboardKeyCode.leftArrow
            )
            let movementOutcome = harness.gate.outcome(for: movement)
            harness.worker.enqueue(
                movement.delivered(with: movementOutcome)
            )
            let edit = keySnapshot(keyCode: 7, characters: "x")
            let editOutcome = harness.gate.outcome(for: edit)
            harness.worker.enqueue(edit.delivered(with: editOutcome))
            let followUpOutcome = harness.gate.outcome(for: followUp)
            harness.worker.enqueue(
                followUp.delivered(with: followUpOutcome)
            )

            let hidden = await eventually {
                harness.gate.mode == .hidden
                    && harness.presenter.updates.contains {
                        guard case .hide = $0 else {
                            return false
                        }
                        return true
                    }
            }
            XCTAssertTrue(hidden)
        }
    }

    func testTypingAfterModifiedCaretMovementRebuildsSuggestions()
        async throws
    {
        for flags in [
            CGEventFlags.maskAlternate,
            CGEventFlags.maskShift
        ] {
            let harness = try makeHarness(
                items: [emoji(shortcode: "frog", value: "🐸")],
                targetText: ":frog"
            )
            harness.worker.setCaptureEnabled(true)
            deliver(":f", into: harness)
            let initiallyShown = await eventually {
                harness.gate.mode == .suggestions
            }
            XCTAssertTrue(initiallyShown)

            let movement = keySnapshot(
                keyCode: RuntimeKeyboardKeyCode.leftArrow,
                flags: flags
            )
            let movementOutcome = harness.gate.outcome(for: movement)
            XCTAssertEqual(movementOutcome.decision, .passThrough)
            harness.worker.enqueue(
                movement.delivered(with: movementOutcome)
            )
            harness.captureProvider.setCurrentToken(":fr")

            let edit = keySnapshot(keyCode: 15, characters: "r")
            let editOutcome = harness.gate.outcome(for: edit)
            harness.worker.enqueue(edit.delivered(with: editOutcome))

            let restored = await eventually {
                harness.gate.mode == .suggestions
                    && harness.presenter.latestShown?.rows
                        .map(\.shortcode) == ["frog"]
            }
            XCTAssertTrue(
                restored,
                "Expected recovery after flags \(flags)"
            )
        }
    }

    func testTypingAfterOptionDeleteRebuildsTokenAtTheCaret()
        async throws
    {
        let harness = try makeHarness(
            items: [emoji(shortcode: "frog", value: "🐸")],
            targetText: ":frog"
        )
        harness.worker.setCaptureEnabled(true)
        deliver(":frog", into: harness)
        let initiallyShown = await eventually {
            harness.gate.mode == .suggestions
        }
        XCTAssertTrue(initiallyShown)

        let deleteWord = keySnapshot(
            keyCode: RuntimeKeyboardKeyCode.delete,
            flags: [.maskAlternate]
        )
        let deleteOutcome = harness.gate.outcome(for: deleteWord)
        XCTAssertEqual(deleteOutcome.decision, .passThrough)
        harness.worker.enqueue(
            deleteWord.delivered(with: deleteOutcome)
        )
        harness.captureProvider.setCurrentToken(":f")

        let edit = keySnapshot(keyCode: 3, characters: "f")
        let editOutcome = harness.gate.outcome(for: edit)
        harness.worker.enqueue(edit.delivered(with: editOutcome))

        let restored = await eventually {
            harness.gate.mode == .suggestions
                && harness.presenter.latestShown?.rows
                    .map(\.shortcode) == ["frog"]
        }
        XCTAssertTrue(restored)
    }

    func testRecoveryPreservesTypedCaseForAccessibilityValidation()
        async throws
    {
        let harness = try makeHarness(
            items: [emoji(shortcode: "frog", value: "🐸")],
            targetText: ":Frog"
        )
        harness.worker.setCaptureEnabled(true)
        deliver(":f", into: harness)
        let initiallyShown = await eventually {
            harness.gate.mode == .suggestions
        }
        XCTAssertTrue(initiallyShown)

        harness.captureProvider.setCurrentToken(":Frog")
        harness.captureProvider.setExpectedCaptureToken(":Frog")
        let movement = keySnapshot(
            keyCode: RuntimeKeyboardKeyCode.leftArrow,
            flags: [.maskAlternate]
        )
        let outcome = harness.gate.outcome(for: movement)
        harness.worker.enqueue(movement.delivered(with: outcome))

        let restored = await eventually {
            harness.gate.mode == .suggestions
                && harness.presenter.latestShown?.rows
                    .map(\.shortcode) == ["frog"]
        }
        XCTAssertTrue(restored)
    }

    func testScreenshotFlowDoesNotHideOrDismissSuggestions()
        async throws
    {
        let harness = try makeHarness(
            items: [emoji(shortcode: "frog", value: "🐸")],
            targetText: ":f"
        )
        harness.worker.setCaptureEnabled(true)
        deliver(":f", into: harness)
        let initiallyShown = await eventually {
            harness.gate.mode == .suggestions
        }
        XCTAssertTrue(initiallyShown)
        let updateCount = harness.presenter.updates.count

        let screenshot = keySnapshot(
            keyCode: RuntimeKeyboardKeyCode.digit4,
            flags: [.maskCommand, .maskShift]
        )
        let screenshotOutcome = harness.gate.outcome(for: screenshot)
        harness.worker.enqueue(
            screenshot.delivered(with: screenshotOutcome)
        )
        let screenshotEscape = keySnapshot(
            keyCode: RuntimeKeyboardKeyCode.escape
        )
        let escapeOutcome = harness.gate.outcome(
            for: screenshotEscape
        )
        harness.worker.enqueue(
            screenshotEscape.delivered(with: escapeOutcome)
        )
        try? await Task.sleep(for: .milliseconds(40))

        XCTAssertTrue(screenshotOutcome.preservesAutocompleteContext)
        XCTAssertTrue(escapeOutcome.preservesAutocompleteContext)
        XCTAssertEqual(harness.gate.mode, .suggestions)
        XCTAssertFalse(
            harness.presenter.updates.dropFirst(updateCount).contains {
                guard case .hide = $0 else {
                    return false
                }
                return true
            }
        )
    }

    func testHorizontalCaretMovementCannotBeRepaintedByStaleRefresh()
        async throws
    {
        for keyCode in [
            RuntimeKeyboardKeyCode.leftArrow,
            RuntimeKeyboardKeyCode.rightArrow
        ] {
            let harness = try makeHarness(
                items: [emoji(shortcode: "frog", value: "🐸")],
                targetText: ":fr",
                presentationDelayMilliseconds: 80
            )
            harness.worker.setCaptureEnabled(true)
            deliver(":f", into: harness)
            let initiallyShown = await eventually(
                timeout: .milliseconds(300)
            ) {
                harness.gate.mode == .suggestions
            }
            XCTAssertTrue(initiallyShown)

            let updateStart = harness.presenter.updates.count
            let refresh = keySnapshot(keyCode: 15, characters: "r")
            let refreshOutcome = harness.gate.outcome(for: refresh)
            XCTAssertEqual(
                harness.gate.mode,
                .suggestions,
                "refresh=\(refreshOutcome)"
            )
            harness.worker.enqueue(
                refresh.delivered(with: refreshOutcome)
            )
            let refreshRetained = await eventually {
                harness.presenter.updates.dropFirst(updateStart).contains {
                    guard case .retain = $0 else {
                        return false
                    }
                    return true
                }
            }
            XCTAssertTrue(refreshRetained)

            harness.captureProvider.setCurrentContext(
                token: ":fr",
                selection: NSRange(location: 2, length: 0),
                tokenLocation: 0
            )

            let movement = keySnapshot(keyCode: keyCode)
            let outcome = harness.gate.outcome(for: movement)
            XCTAssertEqual(outcome.decision, .passThrough)
            harness.worker.enqueue(movement.delivered(with: outcome))

            let preserved = await eventually(
                timeout: .milliseconds(300)
            ) {
                harness.gate.mode == .suggestions
                    && harness.presenter.latestShown?.selectedIndex == 0
                    && harness.presenter.latestShown?.acceptsTab == false
            }
            XCTAssertTrue(
                preserved,
                "surface=\(outcome.preservesSuggestionSurface) "
                    + "revision=\(String(describing: outcome.interactionRevision)) "
                    + "gate=\(harness.gate.mode) "
                    + "updates=\(harness.presenter.updates.dropFirst(updateStart))"
            )
            try? await Task.sleep(for: .milliseconds(140))
            XCTAssertFalse(
                harness.presenter.updates.dropFirst(updateStart).contains {
                    guard case .hide = $0 else {
                        return false
                    }
                    return true
                }
            )
            XCTAssertEqual(harness.gate.mode, .suggestions)
        }
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

    func testSuggestionRefreshKeepsPanelVisibleWhenResultsBecomeEmpty()
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
        let emptyStateShown = await eventually {
            harness.presenter.updates.dropFirst(updateStart).contains {
                guard case let .show(snapshot, _) = $0 else {
                    return false
                }
                return snapshot.mode == .suggestions
                    && snapshot.rows.isEmpty
            }
                && harness.gate.mode == .suggestions
        }

        XCTAssertTrue(emptyStateShown)
        XCTAssertFalse(
            harness.presenter.updates.dropFirst(updateStart).contains {
                guard case .hide = $0 else {
                    return false
                }
                return true
            }
        )
        XCTAssertEqual(
            harness.gate.outcome(
                for: keySnapshot(keyCode: RuntimeKeyboardKeyCode.tab)
            ).decision,
            .passThrough
        )
        XCTAssertEqual(
            harness.gate.outcome(
                for: keySnapshot(keyCode: RuntimeKeyboardKeyCode.returnKey)
            ).decision,
            .passThrough
        )
    }

    func testFreshTriggerAfterInvalidSuffixKeepsNewPredictionArmed()
        async throws
    {
        let harness = try makeHarness(
            items: [emoji(shortcode: "frog", value: "🐸")],
            targetText: ":f :",
            parserTimeout: 10
        )
        harness.worker.setCaptureEnabled(true)
        harness.gate.setCaptureEnabled(true)

        deliver(":f :", into: harness)

        let freshPredictionVerified = await eventually {
            harness.captureProvider.captureCount >= 1
                && harness.gate.isExactCommitArmed
        }
        XCTAssertTrue(freshPredictionVerified)
    }

    func testBackspaceRestoresSuggestionsAfterAccidentalSpace()
        async throws
    {
        let harness = try makeHarness(
            items: [emoji(shortcode: "frog", value: "🐸")],
            targetText: ":f"
        )
        harness.worker.setCaptureEnabled(true)
        type(":f", into: harness.worker)
        let initiallyShown = await eventually {
            harness.gate.mode == .suggestions
        }
        XCTAssertTrue(initiallyShown)

        let updateStart = harness.presenter.updates.count
        let space = keySnapshot(keyCode: 49, characters: " ")
        let spaceOutcome = harness.gate.outcome(for: space)
        harness.worker.enqueue(space.delivered(with: spaceOutcome))
        let hidden = await eventually {
            harness.gate.mode == .hidden
                && harness.presenter.updates.dropFirst(updateStart).contains {
                    guard case .hide = $0 else {
                        return false
                    }
                    return true
                }
        }
        XCTAssertTrue(hidden)

        let backspace = keySnapshot(
            keyCode: RuntimeKeyboardKeyCode.delete
        )
        let backspaceOutcome = harness.gate.outcome(for: backspace)
        harness.worker.enqueue(
            backspace.delivered(with: backspaceOutcome)
        )
        let restored = await eventually {
            harness.gate.mode == .suggestions
                && harness.presenter.updates.dropFirst(updateStart).contains {
                    guard case .show = $0 else {
                        return false
                    }
                    return true
                }
        }
        XCTAssertTrue(restored)
    }

    func testRapidBackspaceRestoresSuggestionsAfterNoMatch()
        async throws
    {
        let harness = try makeHarness(
            items: [emoji(shortcode: "frog", value: "🐸")],
            targetText: ":f"
        )
        harness.worker.setCaptureEnabled(true)
        type(":f", into: harness.worker)
        let initiallyShown = await eventually {
            harness.gate.mode == .suggestions
        }
        XCTAssertTrue(initiallyShown)

        let updateStart = harness.presenter.updates.count
        let typo = keySnapshot(keyCode: 6, characters: "z")
        let typoOutcome = harness.gate.outcome(for: typo)
        let backspace = keySnapshot(
            keyCode: RuntimeKeyboardKeyCode.delete
        )
        let backspaceOutcome = harness.gate.outcome(for: backspace)

        harness.worker.enqueue(typo.delivered(with: typoOutcome))
        harness.worker.enqueue(
            backspace.delivered(with: backspaceOutcome)
        )

        let restored = await eventually {
            harness.gate.mode == .suggestions
                && harness.presenter.updates.dropFirst(updateStart).contains {
                    guard case .show = $0 else {
                        return false
                    }
                    return true
                }
        }
        XCTAssertTrue(restored)
        XCTAssertFalse(
            harness.presenter.updates.dropFirst(updateStart).contains {
                guard case .hide = $0 else {
                    return false
                }
                return true
            }
        )
    }

    func testBackspacingLongNoMatchToTriggerRestoresNewSuggestions()
        async throws
    {
        let longQuery = String(
            repeating: "z",
            count: Shortcode.maximumLength
        )
        let harness = try makeHarness(
            items: [emoji(shortcode: "frog", value: "🐸")],
            targetText: ":\(longQuery)"
        )
        harness.worker.setCaptureEnabled(true)
        type(":\(longQuery)", into: harness.worker)
        let noMatchShown = await eventually {
            harness.presenter.latestShown?.rows.isEmpty == true
                && harness.gate.mode == .suggestions
        }
        XCTAssertTrue(noMatchShown)

        let overflowCount = Shortcode.maximumLength + 1
        var recoverySnapshots: [KeyboardEventSnapshot] = []
        for _ in 0..<overflowCount {
            recoverySnapshots.append(
                keySnapshot(keyCode: 6, characters: "z")
            )
        }
        for _ in 0..<(Shortcode.maximumLength + overflowCount) {
            recoverySnapshots.append(
                keySnapshot(keyCode: RuntimeKeyboardKeyCode.delete)
            )
        }
        recoverySnapshots.append(
            keySnapshot(keyCode: 3, characters: "f")
        )
        let deliveredSnapshots = recoverySnapshots.map { snapshot in
            snapshot.delivered(
                with: harness.gate.outcome(for: snapshot)
            )
        }
        for snapshot in deliveredSnapshots {
            harness.worker.enqueue(snapshot)
        }

        let restored = await eventually {
            harness.presenter.latestShown?.rows.map(\.shortcode) == ["frog"]
                && harness.gate.mode == .suggestions
        }
        XCTAssertTrue(restored)
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

    func testInvalidationDuringCaptureCannotArmStaleSuggestions()
        async throws
    {
        let harness = try makeHarness(
            items: [emoji(shortcode: "frog", value: "🐸")],
            targetText: ":f",
            captureDelayMilliseconds: 100
        )
        harness.worker.setCaptureEnabled(true)
        harness.gate.setCaptureEnabled(true)
        deliver(":", into: harness)
        let openingCaptureFinished = await eventually(
            timeout: .milliseconds(300)
        ) {
            harness.gate.isExactCommitArmed
        }
        XCTAssertTrue(openingCaptureFinished)

        deliver("f", into: harness)
        let suggestionCaptureStarted = await eventually {
            harness.captureProvider.captureCount >= 2
        }
        XCTAssertTrue(suggestionCaptureStarted)

        let invalidatingKey = keySnapshot(
            keyCode: 49,
            characters: " "
        )
        let invalidatingOutcome = harness.gate.outcome(
            for: invalidatingKey
        )
        XCTAssertEqual(invalidatingOutcome.decision, .passThrough)
        XCTAssertEqual(harness.gate.mode, .hidden)

        try? await Task.sleep(for: .milliseconds(150))
        XCTAssertNil(harness.presenter.latestShown)
        XCTAssertEqual(harness.gate.mode, .hidden)

        harness.worker.enqueue(
            invalidatingKey.delivered(with: invalidatingOutcome)
        )
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

    func testBrowserHintIncludesKeysItAlwaysAccepts() async throws {
        let harness = try makeHarness(
            items: [emoji(shortcode: "frog", value: "🐸")],
            targetText: "::",
            acceptsTab: false,
            acceptsReturn: false
        )
        harness.worker.setCaptureEnabled(true)
        type("::", into: harness.worker)

        let browserShown = await eventually {
            harness.presenter.latestShown?.mode == .browser
        }

        XCTAssertTrue(browserShown)
        XCTAssertEqual(harness.presenter.latestShown?.acceptsTab, true)
        XCTAssertEqual(harness.presenter.latestShown?.acceptsReturn, true)
        XCTAssertEqual(
            harness.presenter.latestShown?.compactInteractionHint,
            "↑↓ choose  ·  tab or ↩ insert  ·  esc close"
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
        XCTAssertFalse(selectionSnapshots.isEmpty)
        XCTAssertLessThanOrEqual(
            selectionSnapshots.count,
            keyRepeatCount
        )
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

    func testBrowserSearchAcceptsNaturalLanguageSpaces() async throws {
        let heart = EmojiItem(
            id: "test.heart",
            shortcode: Shortcode(rawValue: "heart")!,
            name: "red heart",
            category: "symbols",
            content: .unicode(UnicodeEmojiContent(value: "❤️")),
            packID: "test"
        )
        let harness = try makeHarness(
            items: [
                heart,
                emoji(shortcode: "frog", value: "🐸")
            ],
            targetText: "::"
        )
        harness.worker.setCaptureEnabled(true)
        type("::", into: harness.worker)
        let browserShown = await eventually {
            harness.presenter.latestShown?.mode == .browser
        }
        XCTAssertTrue(browserShown)

        deliver("red  heart", into: harness)

        let filtered = await eventually {
            harness.presenter.latestShown?.query == "red heart"
        }
        XCTAssertTrue(filtered)
        XCTAssertEqual(
            harness.presenter.latestShown?.rows.map(\.shortcode),
            ["heart"]
        )
        XCTAssertEqual(harness.system.text, "::")
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

    func testInterceptionIsArmedBeforeVisibleSuggestionIsApplied()
        async throws
    {
        let harness = try makeHarness(
            items: [emoji(shortcode: "frog", value: "🐸")],
            targetText: ":f"
        )
        var modeWhenVisible: RuntimeInterceptionMode?
        harness.presenter.onApplyReportingVisibility = {
            modeWhenVisible = harness.gate.mode
        }
        harness.worker.setCaptureEnabled(true)
        type(":f", into: harness.worker)

        let presented = await eventually {
            harness.presenter.latestShown != nil
        }
        XCTAssertTrue(presented)
        XCTAssertEqual(modeWhenVisible, .suggestions)
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

    func testDisabledSuggestionTimeoutKeepsPanelVisibleWithoutAnotherEvent()
        async throws
    {
        let harness = try makeHarness(
            items: [emoji(shortcode: "frog", value: "🐸")],
            targetText: ":f",
            parserTimeout: 0
        )
        harness.worker.setCaptureEnabled(true)
        type(":f", into: harness.worker)

        let shown = await eventually {
            harness.gate.mode == .suggestions
        }
        XCTAssertTrue(shown)

        try? await Task.sleep(for: .milliseconds(150))
        XCTAssertEqual(harness.gate.mode, .suggestions)
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
        accessibilityRetryLimit: Int = 0,
        captureFailuresBeforeSuccess: Int = 0,
        parserTimeout: TimeInterval = 3,
        presentationDelayMilliseconds: Int = 0,
        captureDelayMilliseconds: Int = 0,
        captureError: RuntimeTextCaptureError? = nil,
        canPostEvents: Bool = true,
        acceptsTab: Bool = true,
        acceptsReturn: Bool = true,
        usageStore: (any EmojiUsageStore)? = nil,
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
            error: captureError,
            delayMilliseconds: captureDelayMilliseconds,
            transientFailuresBeforeSuccess:
                captureFailuresBeforeSuccess
        )
        let presenter = RuntimeRecordingPresenter()
        let gate = RuntimeInterceptionGate()
        let poster = FakeEventPoster(canPostEvents: canPostEvents)
        let bridge = RuntimeMainActorBridge(
            presenter: presenter,
            insertionEngine: InsertionEngine(
                accessibility: accessibility,
                pasteboard: PasteboardTransactionCoordinator(
                    pasteboard: FakePasteboard()
                ),
                eventPoster: poster,
                restorationDelay: .zero
            ),
            presentationDelayMilliseconds:
                presentationDelayMilliseconds
        )
        var preferences = MojiPondPreferences.defaults
        preferences.shortcode.parserTimeout = parserTimeout
        preferences.shortcode.acceptsTab = acceptsTab
        preferences.shortcode.acceptsReturn = acceptsReturn
        let worker = UnicodeAutocompleteRuntimeWorker(
            searchIndex: EmojiSearchIndex(items: items),
            configuration: UnicodeAutocompleteRuntimeConfiguration(
                preferences: preferences,
                accessibilitySettleDelayMilliseconds:
                    settleDelayMilliseconds,
                accessibilityRetryLimit: accessibilityRetryLimit
            ),
            interceptionGate: gate,
            contextProvider: captureProvider,
            mainActorBridge: bridge,
            usageStore: usageStore,
            diagnosticHandler: diagnosticHandler
        )
        worker.connectSuggestionPanelInteractions()
        return RuntimeWorkerHarness(
            worker: worker,
            gate: gate,
            presenter: presenter,
            system: system,
            captureProvider: captureProvider,
            poster: poster
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

    private func deliver(
        _ text: String,
        into harness: RuntimeWorkerHarness
    ) {
        for character in text {
            let snapshot = keySnapshot(
                keyCode: character == ":" ? 41 : 0,
                characters: String(character)
            )
            let outcome = harness.gate.outcome(for: snapshot)
            harness.worker.enqueue(snapshot.delivered(with: outcome))
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
        flags: CGEventFlags = [],
        interceptionOutcome: EventInterceptionOutcome? = nil
    ) -> KeyboardEventSnapshot {
        KeyboardEventSnapshot(
            typeRawValue: CGEventType.keyDown.rawValue,
            keyCode: keyCode,
            flagsRawValue: flags.rawValue,
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

    private func eventuallyAsync(
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

private struct RuntimeWorkerHarness {
    let worker: UnicodeAutocompleteRuntimeWorker
    let gate: RuntimeInterceptionGate
    let presenter: RuntimeRecordingPresenter
    let system: FakeAccessibilityTextSystem
    let captureProvider: FixedRuntimeTextCaptureProvider
    let poster: FakeEventPoster
}

@MainActor
private final class RuntimeRecordingPresenter: RuntimeSuggestionPresenting {
    private(set) var updates: [RuntimeSuggestionPanelUpdate] = []
    var allowsPresentation = true
    var onApplyReportingVisibility: (() -> Void)?
    private var latestRevision: UInt64 = 0
    private var interactionHandler:
        (@Sendable (RuntimeSuggestionPanelInteraction) -> Void)?

    var isInteractionConfigured: Bool {
        interactionHandler != nil
    }

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
        onApplyReportingVisibility?()
        return allowsPresentation
    }

    func configureInteractions(
        handler: @escaping @Sendable (
            RuntimeSuggestionPanelInteraction
        ) -> Void,
        quartzFrameDidChange: @escaping @Sendable (CGRect?) -> Void
    ) {
        interactionHandler = handler
        quartzFrameDidChange(nil)
    }

    func send(_ interaction: RuntimeSuggestionPanelInteraction) {
        interactionHandler?(interaction)
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
    private var transientFailuresRemaining: Int
    private let delayMilliseconds: Int
    private var currentToken: String?
    private var expectedCaptureToken: String?
    private var currentSelection: NSRange?
    private var currentTokenLocation: Int?
    private var storedRepresentsSameTarget = true
    private var targetComparisonResults: [Bool] = []

    init(
        target: AccessibilityTextTarget,
        selectionLocation: Int,
        caretBounds: CGRect?,
        error: RuntimeTextCaptureError?,
        delayMilliseconds: Int,
        transientFailuresBeforeSuccess: Int
    ) {
        self.target = target
        self.selectionLocation = selectionLocation
        self.caretBounds = caretBounds
        self.error = error
        self.delayMilliseconds = max(0, delayMilliseconds)
        transientFailuresRemaining = max(
            0,
            transientFailuresBeforeSuccess
        )
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

    func setCurrentToken(_ token: String?) {
        lock.withLock {
            currentToken = token
            currentSelection = nil
            currentTokenLocation = nil
        }
    }

    func setCurrentContext(
        token: String?,
        selection: NSRange,
        tokenLocation: Int
    ) {
        lock.withLock {
            currentToken = token
            currentSelection = selection
            currentTokenLocation = tokenLocation
        }
    }

    func setExpectedCaptureToken(_ token: String?) {
        lock.withLock {
            expectedCaptureToken = token
        }
    }

    func setRepresentsSameTarget(_ representsSameTarget: Bool) {
        lock.withLock {
            storedRepresentsSameTarget = representsSameTarget
        }
    }

    func setTargetComparisonResults(_ results: [Bool]) {
        lock.withLock {
            targetComparisonResults = results
        }
    }

    func representsSameTarget(
        _ lhs: AccessibilityTextTarget,
        _ rhs: AccessibilityTextTarget
    ) -> Bool {
        lock.withLock {
            let comparisonResult = targetComparisonResults.isEmpty
                ? storedRepresentsSameTarget
                : targetComparisonResults.removeFirst()
            return comparisonResult
                && lhs.processIdentifier == rhs.processIdentifier
                && lhs.element === rhs.element
        }
    }

    func captureCurrentToken(
        trigger: Character
    ) throws -> RuntimeTextCapture {
        let state: (String?, NSRange?, Int?) = lock.withLock {
            storedCaptureCount += 1
            return (
                currentToken,
                currentSelection,
                currentTokenLocation
            )
        }
        guard
            let token = state.0,
            token.first == trigger
        else {
            throw RuntimeTextCaptureError.invalidTokenContext
        }
        let isClosed = token.count > 1 && token.last == trigger
        let query = String(
            token.dropFirst().dropLast(isClosed ? 1 : 0)
        )
        guard
            !isClosed || !query.isEmpty,
            query.isEmpty || EmojiAliasSyntax.isValidToken(query)
        else {
            throw RuntimeTextCaptureError.invalidTokenContext
        }
        let length = token.utf16.count
        let tokenLocation = state.2 ?? selectionLocation - length
        guard tokenLocation >= 0 else {
            throw RuntimeTextCaptureError.invalidTokenContext
        }
        let selection = state.1 ?? NSRange(
            location: selectionLocation,
            length: 0
        )
        return RuntimeTextCapture(
            target: target,
            context: AccessibilityTextContext(
                selection: selection,
                caretBounds: caretBounds,
                textFragment: token,
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

    func capture(
        expectedToken: String,
        trigger: Character
    ) throws -> RuntimeTextCapture {
        _ = trigger
        let captureState: (
            error: RuntimeTextCaptureError?,
            renderedToken: String?,
            currentToken: String?,
            selection: NSRange?,
            tokenLocation: Int?
        ) = lock.withLock {
            storedCaptureCount += 1
            if transientFailuresRemaining > 0 {
                transientFailuresRemaining -= 1
                return (.invalidTokenContext, nil, nil, nil, nil)
            }
            return (
                error,
                expectedCaptureToken,
                currentToken,
                currentSelection,
                currentTokenLocation
            )
        }
        if delayMilliseconds > 0 {
            Thread.sleep(
                forTimeInterval: Double(delayMilliseconds) / 1_000
            )
        }
        if let capturedError = captureState.error {
            throw capturedError
        }
        let renderedToken = captureState.renderedToken
            ?? captureState.currentToken
            ?? expectedToken
        let length = renderedToken.utf16.count
        let tokenLocation = captureState.tokenLocation
            ?? selectionLocation - length
        guard tokenLocation >= 0 else {
            throw RuntimeTextCaptureError.invalidTokenContext
        }
        let selection = captureState.selection ?? NSRange(
            location: selectionLocation,
            length: 0
        )
        guard
            selection.location >= tokenLocation,
            selection.location <= Int.max - selection.length,
            tokenLocation <= Int.max - length,
            selection.location + selection.length
                <= tokenLocation + length
        else {
            throw RuntimeTextCaptureError.invalidTokenContext
        }
        let capturesFullToken = renderedToken == expectedToken
        let capturesInteriorPrefix =
            selection.length == 0
                && renderedToken.hasPrefix(expectedToken)
                && tokenLocation + expectedToken.utf16.count
                    == selection.location
        guard capturesFullToken || capturesInteriorPrefix else {
            throw RuntimeTextCaptureError.invalidTokenContext
        }
        return RuntimeTextCapture(
            target: target,
            context: AccessibilityTextContext(
                selection: selection,
                caretBounds: caretBounds,
                textFragment: renderedToken,
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

private actor FailingRuntimeEmojiUsageStore: EmojiUsageStore {
    private(set) var recordAttempts = 0

    func snapshot() async throws -> EmojiUsageSnapshot {
        EmojiUsageSnapshot()
    }

    func recordUse(
        itemID: EmojiItem.ID,
        skinTone: EmojiSkinTone?,
        at date: Date
    ) async throws {
        _ = itemID
        _ = skinTone
        _ = date
        recordAttempts += 1
        throw CocoaError(.fileWriteUnknown)
    }

    func setFavorite(
        _ isFavorite: Bool,
        itemID: EmojiItem.ID
    ) async throws {
        _ = isFavorite
        _ = itemID
    }

    func setCustomAliases(
        _ aliases: [String],
        itemID: EmojiItem.ID
    ) async throws {
        _ = aliases
        _ = itemID
    }

    func setPreferredSkinTone(
        _ skinTone: EmojiSkinTone?,
        itemID: EmojiItem.ID
    ) async throws {
        _ = skinTone
        _ = itemID
    }
}
