import CoreGraphics
import XCTest
@testable import MojiPond

final class RuntimeKeyboardTests: XCTestCase {
    func testMapperProducesParserInputsWithoutTouchingTheOS() {
        XCTAssertEqual(
            RuntimeKeyboardEventMapper.action(
                for: snapshot(
                    keyCode: 0,
                    flags: [.maskShift],
                    characters: "F"
                )
            ),
            .character("F", modifiers: [.shift])
        )
        XCTAssertEqual(
            RuntimeKeyboardEventMapper.action(
                for: snapshot(
                    keyCode: RuntimeKeyboardKeyCode.delete,
                    flags: [.maskAlternate]
                )
            ),
            .backspace(modifiers: [.option])
        )
        XCTAssertEqual(
            RuntimeKeyboardEventMapper.action(
                for: snapshot(
                    keyCode: RuntimeKeyboardKeyCode.leftArrow
                )
            ),
            .reset(.cursorMoved)
        )
        XCTAssertEqual(
            RuntimeKeyboardEventMapper.action(
                for: snapshot(keyCode: 0)
            ),
            .reset(.deadKeyOrIME)
        )
    }

    func testMouseClickMapsToAnAggressiveReset() {
        let event = KeyboardEventSnapshot(
            typeRawValue: CGEventType.leftMouseDown.rawValue,
            keyCode: 0,
            flagsRawValue: 0,
            timestamp: 1,
            characters: nil
        )

        XCTAssertEqual(
            RuntimeKeyboardEventMapper.action(for: event),
            .reset(.mouseClick)
        )
    }

    func testScreenshotShortcutPassesThroughWithoutChangingParserInput() {
        for keyCode in [
            RuntimeKeyboardKeyCode.digit3,
            RuntimeKeyboardKeyCode.digit4,
            RuntimeKeyboardKeyCode.digit5,
            RuntimeKeyboardKeyCode.digit6
        ] {
            XCTAssertEqual(
                RuntimeKeyboardEventMapper.action(
                    for: snapshot(
                        keyCode: keyCode,
                        flags: [.maskCommand, .maskShift]
                    )
                ),
                .ignore
            )
        }
    }

    func testImmediateScreenshotDoesNotLeaveTheGateInScreenshotMode() {
        let gate = RuntimeInterceptionGate()
        gate.setCaptureEnabled(true)
        gate.setMode(
            .suggestions,
            acceptsTab: true,
            acceptsReturn: true
        )

        let screenshot = gate.outcome(
            for: snapshot(
                keyCode: RuntimeKeyboardKeyCode.digit3,
                flags: [.maskCommand, .maskShift]
            )
        )
        let followingCharacter = gate.outcome(
            for: snapshot(keyCode: 3, characters: "f")
        )

        XCTAssertTrue(screenshot.preservesAutocompleteContext)
        XCTAssertFalse(
            followingCharacter.preservesAutocompleteContext
        )
    }

    func testScreenshotFlowPreservesVisibleSuggestionsAndPrediction()
        throws
    {
        let gate = RuntimeInterceptionGate()
        gate.configureExactCommitPrediction(
            trigger: ":",
            isEnabled: true,
            exactTokens: ["frog"]
        )
        gate.setCaptureEnabled(true)
        let opening = gate.outcome(
            for: snapshot(keyCode: 41, characters: ":")
        )
        _ = gate.outcome(
            for: snapshot(keyCode: 3, characters: "f")
        )
        XCTAssertTrue(
            gate.verifyExactCommitPrediction(
                generation: opening.predictionGeneration,
                expectedToken: ":f"
            )
        )
        gate.setMode(
            .suggestions,
            acceptsTab: true,
            acceptsReturn: true
        )

        let shortcut = gate.outcome(
            for: snapshot(
                keyCode: RuntimeKeyboardKeyCode.digit4,
                flags: [.maskCommand, .maskShift]
            )
        )

        XCTAssertEqual(shortcut.decision, .passThrough)
        XCTAssertTrue(shortcut.preservesAutocompleteContext)
        XCTAssertEqual(gate.mode, .suggestions)
        XCTAssertTrue(gate.isExactCommitArmed)

        let cancelScreenshot = gate.outcome(
            for: snapshot(keyCode: RuntimeKeyboardKeyCode.escape)
        )
        XCTAssertEqual(cancelScreenshot.decision, .passThrough)
        XCTAssertTrue(cancelScreenshot.preservesAutocompleteContext)
        XCTAssertEqual(gate.mode, .suggestions)
        XCTAssertTrue(gate.isExactCommitArmed)
    }

    func testScreenshotMouseSelectionDoesNotLookLikeACaretClick() {
        let gate = RuntimeInterceptionGate()
        gate.setCaptureEnabled(true)
        gate.setMode(
            .suggestions,
            acceptsTab: true,
            acceptsReturn: true
        )
        _ = gate.outcome(
            for: snapshot(
                keyCode: RuntimeKeyboardKeyCode.digit4,
                flags: [.maskCommand, .maskShift]
            )
        )
        let screenshotClick = KeyboardEventSnapshot(
            typeRawValue: CGEventType.leftMouseDown.rawValue,
            keyCode: 0,
            flagsRawValue: 0,
            timestamp: 1,
            characters: nil
        )

        let capture = gate.outcome(for: screenshotClick)

        XCTAssertTrue(capture.preservesAutocompleteContext)
        XCTAssertEqual(gate.mode, .suggestions)

        _ = gate.outcome(for: screenshotClick)
        XCTAssertEqual(gate.mode, .hidden)
    }

    func testValidatedRecoveredTokenRearmsExactClosePrediction()
        throws
    {
        let gate = RuntimeInterceptionGate()
        gate.configureExactCommitPrediction(
            trigger: ":",
            isEnabled: true,
            exactTokens: ["frog"]
        )
        gate.setCaptureEnabled(true)

        let generation = try XCTUnwrap(
            gate.restoreExactCommitPrediction(
                expectedToken: ":frog"
            )
        )
        gate.setMode(
            .suggestions,
            acceptsTab: true,
            acceptsReturn: true
        )

        let close = gate.outcome(
            for: snapshot(keyCode: 41, characters: ":")
        )

        XCTAssertEqual(close.predictionGeneration, generation)
        XCTAssertEqual(gate.mode, .committing)
        XCTAssertEqual(
            gate.outcome(
                for: snapshot(
                    keyCode: RuntimeKeyboardKeyCode.returnKey
                )
            ),
            .intercepting(.committing)
        )
    }

    func testGateOnlyOwnsVisibleUnmodifiedNavigation() {
        let gate = RuntimeInterceptionGate()
        let down = snapshot(
            keyCode: RuntimeKeyboardKeyCode.downArrow
        )

        XCTAssertEqual(gate.decision(for: down), .passThrough)
        gate.setCaptureEnabled(true)
        gate.setMode(
            .suggestions,
            acceptsTab: true,
            acceptsReturn: false
        )

        XCTAssertEqual(gate.decision(for: down), .intercept)
        XCTAssertEqual(
            gate.decision(
                for: snapshot(keyCode: RuntimeKeyboardKeyCode.tab)
            ),
            .intercept
        )
        XCTAssertEqual(
            gate.decision(
                for: snapshot(keyCode: RuntimeKeyboardKeyCode.returnKey)
            ),
            .passThrough
        )
        XCTAssertEqual(
            gate.decision(
                for: snapshot(
                    keyCode: RuntimeKeyboardKeyCode.downArrow,
                    flags: [.maskCommand]
                )
            ),
            .passThrough
        )
        XCTAssertEqual(gate.mode, .suggestions)
        XCTAssertEqual(
            gate.decision(
                for: snapshot(keyCode: RuntimeKeyboardKeyCode.returnKey)
            ),
            .passThrough
        )
        XCTAssertEqual(
            gate.decision(
                for: snapshot(keyCode: 0, characters: "a")
            ),
            .passThrough
        )
    }

    func testPhysicalArrowFlagsRemainUnmodifiedAcrossKeyboardSurfaces() {
        let physicalArrowFlags: CGEventFlags = [
            .maskSecondaryFn,
            .maskNumericPad
        ]
        let down = snapshot(
            keyCode: RuntimeKeyboardKeyCode.downArrow,
            flags: physicalArrowFlags
        )

        XCTAssertEqual(
            RuntimeKeyboardEventMapper.action(for: down),
            .navigation(.arrowDown, modifiers: [])
        )

        let gate = RuntimeInterceptionGate()
        gate.setCaptureEnabled(true)
        for mode in [
            RuntimeInterceptionMode.suggestions,
            .browser
        ] {
            gate.setMode(mode, acceptsTab: true, acceptsReturn: true)
            XCTAssertEqual(
                gate.decision(for: down),
                .intercept,
                "Expected physical arrows to navigate \(mode)"
            )
        }

        XCTAssertEqual(
            gate.decision(
                for: snapshot(
                    keyCode: RuntimeKeyboardKeyCode.downArrow,
                    flags: physicalArrowFlags.union(.maskCommand)
                )
            ),
            .passThrough
        )
    }

    func testBrowserOwnsAcceptanceEvenWhenAutocompleteAcceptanceIsDisabled() {
        let gate = RuntimeInterceptionGate()
        gate.setCaptureEnabled(true)
        gate.setMode(
            .browser,
            acceptsTab: false,
            acceptsReturn: false
        )

        XCTAssertEqual(
            gate.decision(
                for: snapshot(keyCode: RuntimeKeyboardKeyCode.tab)
            ),
            .intercept
        )
        XCTAssertEqual(
            gate.decision(
                for: snapshot(keyCode: RuntimeKeyboardKeyCode.keypadEnter)
            ),
            .intercept
        )
        XCTAssertEqual(
            gate.decision(
                for: snapshot(keyCode: 3, characters: "f")
            ),
            .intercept
        )
        XCTAssertEqual(
            gate.decision(
                for: snapshot(keyCode: RuntimeKeyboardKeyCode.delete)
            ),
            .intercept
        )
        XCTAssertEqual(
            gate.decision(
                for: snapshot(keyCode: 49, characters: " ")
            ),
            .intercept
        )
        XCTAssertEqual(
            gate.decision(
                for: snapshot(
                    keyCode: 3,
                    flags: [.maskCommand],
                    characters: "f"
                )
            ),
            .passThrough
        )
    }

    func testBrowserAcceptsShiftedQueryCharactersButNotShiftedNavigation() {
        let gate = RuntimeInterceptionGate()
        gate.setCaptureEnabled(true)
        gate.setMode(
            .browser,
            acceptsTab: true,
            acceptsReturn: true
        )

        XCTAssertEqual(
            gate.decision(
                for: snapshot(
                    keyCode: 27,
                    flags: [.maskShift],
                    characters: "_"
                )
            ),
            .intercept
        )
        for keyCode in [
            RuntimeKeyboardKeyCode.downArrow,
            RuntimeKeyboardKeyCode.tab,
            RuntimeKeyboardKeyCode.returnKey
        ] {
            XCTAssertEqual(
                gate.decision(
                    for: snapshot(
                        keyCode: keyCode,
                        flags: [.maskShift]
                    )
                ),
                .passThrough
            )
        }
    }

    func testVerifiedExactTokenArmsCommitBeforeWorkerHandlesClosingTrigger()
        throws
    {
        let gate = RuntimeInterceptionGate()
        gate.configureExactCommitPrediction(
            trigger: ":",
            isEnabled: true,
            exactTokens: ["frog"]
        )
        gate.setCaptureEnabled(true)
        let opening = gate.outcome(
            for: snapshot(
                keyCode: 41,
                flags: [.maskShift],
                characters: ":"
            )
        )
        let generation = try XCTUnwrap(opening.predictionGeneration)
        for character in "frog" {
            _ = gate.outcome(
                for: snapshot(
                    keyCode: 0,
                    characters: String(character)
                )
            )
        }
        XCTAssertTrue(
            gate.verifyExactCommitPrediction(
                generation: generation,
                expectedToken: ":fro"
            )
        )

        XCTAssertEqual(
            gate.outcome(
                for: snapshot(
                    keyCode: 41,
                    flags: [.maskShift],
                    characters: ":"
                )
            ).decision,
            .passThrough
        )
        XCTAssertEqual(gate.mode, .committing)
        XCTAssertEqual(
            gate.outcome(
                for: snapshot(keyCode: RuntimeKeyboardKeyCode.returnKey)
            ),
            .intercepting(.committing)
        )
    }

    func testReturnIntentCarriesIntoCommitAndCanOnlyBeClaimedOnce()
        throws
    {
        let gate = RuntimeInterceptionGate()
        gate.configureExactCommitPrediction(
            trigger: ":",
            isEnabled: true,
            exactTokens: ["frog"]
        )
        gate.setCaptureEnabled(true)
        let opening = gate.outcome(
            for: snapshot(
                keyCode: 41,
                flags: [.maskShift],
                characters: ":"
            )
        )
        let predictionGeneration = try XCTUnwrap(
            opening.predictionGeneration
        )
        for character in "frog" {
            _ = gate.outcome(
                for: snapshot(
                    keyCode: 0,
                    characters: String(character)
                )
            )
        }
        XCTAssertTrue(
            gate.verifyExactCommitPrediction(
                generation: predictionGeneration,
                expectedToken: ":fro"
            )
        )
        let close = gate.outcome(
            for: snapshot(
                keyCode: 41,
                flags: [.maskShift],
                characters: ":"
            )
        )
        XCTAssertEqual(
            gate.outcome(
                for: snapshot(
                    keyCode: RuntimeKeyboardKeyCode.returnKey
                )
            ),
            .intercepting(.committing)
        )

        let commitGeneration = try XCTUnwrap(
            gate.activateCommit(
                interactionRevision: close.interactionRevision,
                acceptsTab: true,
                acceptsReturn: true
            )
        )
        XCTAssertTrue(
            gate.hasPendingCommitSend(
                generation: commitGeneration
            )
        )
        XCTAssertTrue(
            gate.finishCommit(
                generation: commitGeneration,
                retainingPendingSend: true
            )
        )
        XCTAssertTrue(
            gate.claimPendingCommitSend(
                generation: commitGeneration
            )
        )
        XCTAssertFalse(
            gate.claimPendingCommitSend(
                generation: commitGeneration
            )
        )
    }

    func testCommitCompletionBeforeReturnReleasesItToTheTarget() throws {
        let gate = RuntimeInterceptionGate()
        gate.configureExactCommitPrediction(
            trigger: ":",
            isEnabled: true,
            exactTokens: ["frog"]
        )
        gate.setCaptureEnabled(true)
        gate.setMode(
            .committing,
            acceptsTab: true,
            acceptsReturn: true
        )
        let commitGeneration = try XCTUnwrap(
            gate.activateCommit(
                interactionRevision: gate.interactionRevision,
                acceptsTab: true,
                acceptsReturn: true
            )
        )

        XCTAssertFalse(
            gate.finishCommit(
                generation: commitGeneration,
                retainingPendingSend: true
            )
        )
        XCTAssertEqual(gate.mode, .hidden)
        XCTAssertEqual(
            gate.outcome(
                for: snapshot(
                    keyCode: RuntimeKeyboardKeyCode.returnKey
                )
            ).decision,
            .passThrough
        )
    }

    func testFailedCommitFinalizationAtomicallyReleasesLaterReturn()
        throws
    {
        let gate = RuntimeInterceptionGate()
        gate.configureExactCommitPrediction(
            trigger: ":",
            isEnabled: true,
            exactTokens: ["frog"]
        )
        gate.setCaptureEnabled(true)
        gate.setMode(
            .committing,
            acceptsTab: true,
            acceptsReturn: true
        )
        let generation = try XCTUnwrap(
            gate.activateCommit(
                interactionRevision: gate.interactionRevision,
                acceptsTab: true,
                acceptsReturn: true
            )
        )
        XCTAssertEqual(
            gate.outcome(
                for: snapshot(
                    keyCode: RuntimeKeyboardKeyCode.returnKey
                )
            ).decision,
            .intercept
        )

        XCTAssertFalse(
            gate.finishCommit(
                generation: generation,
                retainingPendingSend: false
            )
        )
        XCTAssertFalse(
            gate.claimPendingCommitSend(generation: generation)
        )
        XCTAssertEqual(gate.mode, .hidden)
        XCTAssertEqual(
            gate.outcome(
                for: snapshot(
                    keyCode: RuntimeKeyboardKeyCode.returnKey
                )
            ).decision,
            .passThrough
        )
    }

    func testEscapeRevokesPendingCommitSendBeforeClaim() throws {
        let gate = RuntimeInterceptionGate()
        gate.configureExactCommitPrediction(
            trigger: ":",
            isEnabled: true,
            exactTokens: ["frog"]
        )
        gate.setCaptureEnabled(true)
        gate.setMode(
            .committing,
            acceptsTab: true,
            acceptsReturn: true
        )
        let interactionRevision = gate.interactionRevision
        let commitGeneration = try XCTUnwrap(
            gate.activateCommit(
                interactionRevision: interactionRevision,
                acceptsTab: true,
                acceptsReturn: true
            )
        )
        XCTAssertEqual(
            gate.outcome(
                for: snapshot(
                    keyCode: RuntimeKeyboardKeyCode.returnKey
                )
            ),
            .intercepting(.committing)
        )
        XCTAssertEqual(
            gate.outcome(
                for: snapshot(
                    keyCode: RuntimeKeyboardKeyCode.escape
                )
            ),
            .intercepting(.committing)
        )

        XCTAssertFalse(
            gate.claimPendingCommitSend(
                generation: commitGeneration
            )
        )
        XCTAssertEqual(gate.mode, .hidden)
    }

    func testCharacterAfterVerifiedExactCloseDisarmsCommitBeforeReturn()
        throws
    {
        let gate = RuntimeInterceptionGate()
        gate.configureExactCommitPrediction(
            trigger: ":",
            isEnabled: true,
            exactTokens: ["frog"]
        )
        gate.setCaptureEnabled(true)
        let opening = gate.outcome(
            for: snapshot(
                keyCode: 41,
                flags: [.maskShift],
                characters: ":"
            )
        )
        let generation = try XCTUnwrap(opening.predictionGeneration)
        for character in "frog" {
            _ = gate.outcome(
                for: snapshot(
                    keyCode: 0,
                    characters: String(character)
                )
            )
        }
        XCTAssertTrue(
            gate.verifyExactCommitPrediction(
                generation: generation,
                expectedToken: ":fro"
            )
        )
        _ = gate.outcome(
            for: snapshot(
                keyCode: 41,
                flags: [.maskShift],
                characters: ":"
            )
        )
        XCTAssertEqual(gate.mode, .committing)

        XCTAssertEqual(
            gate.outcome(
                for: snapshot(keyCode: 7, characters: "x")
            ),
            .passThrough
        )
        XCTAssertEqual(gate.mode, .hidden)
        XCTAssertEqual(
            gate.outcome(
                for: snapshot(keyCode: RuntimeKeyboardKeyCode.returnKey)
            ),
            .passThrough
        )
    }

    func testShiftReturnAfterVerifiedExactCloseDisarmsCommitBeforeReturn()
        throws
    {
        let gate = RuntimeInterceptionGate()
        gate.configureExactCommitPrediction(
            trigger: ":",
            isEnabled: true,
            exactTokens: ["frog"]
        )
        gate.setCaptureEnabled(true)
        let opening = gate.outcome(
            for: snapshot(
                keyCode: 41,
                flags: [.maskShift],
                characters: ":"
            )
        )
        let generation = try XCTUnwrap(opening.predictionGeneration)
        for character in "frog" {
            _ = gate.outcome(
                for: snapshot(
                    keyCode: 0,
                    characters: String(character)
                )
            )
        }
        XCTAssertTrue(
            gate.verifyExactCommitPrediction(
                generation: generation,
                expectedToken: ":fro"
            )
        )
        _ = gate.outcome(
            for: snapshot(
                keyCode: 41,
                flags: [.maskShift],
                characters: ":"
            )
        )
        XCTAssertEqual(gate.mode, .committing)

        XCTAssertEqual(
            gate.outcome(
                for: snapshot(
                    keyCode: RuntimeKeyboardKeyCode.returnKey,
                    flags: [.maskShift]
                )
            ),
            .passThrough
        )
        XCTAssertEqual(gate.mode, .hidden)
        XCTAssertEqual(
            gate.outcome(
                for: snapshot(keyCode: RuntimeKeyboardKeyCode.returnKey)
            ),
            .passThrough
        )
    }

    func testPendingPresentationCannotReplaceVerifiedExactCommit()
        throws
    {
        let gate = RuntimeInterceptionGate()
        gate.configureExactCommitPrediction(
            trigger: ":",
            isEnabled: true,
            exactTokens: ["frog"]
        )
        gate.setCaptureEnabled(true)
        let opening = gate.outcome(
            for: snapshot(
                keyCode: 41,
                flags: [.maskShift],
                characters: ":"
            )
        )
        let generation = try XCTUnwrap(opening.predictionGeneration)
        for character in "frog" {
            _ = gate.outcome(
                for: snapshot(
                    keyCode: 0,
                    characters: String(character)
                )
            )
        }
        XCTAssertTrue(
            gate.verifyExactCommitPrediction(
                generation: generation,
                expectedToken: ":fro"
            )
        )
        XCTAssertTrue(
            gate.expectPresentation(
                revision: 1,
                interactionRevision: gate.interactionRevision
            )
        )
        _ = gate.outcome(
            for: snapshot(
                keyCode: 41,
                flags: [.maskShift],
                characters: ":"
            )
        )
        XCTAssertEqual(gate.mode, .committing)

        XCTAssertFalse(
            gate.activatePresentation(
                revision: 1,
                mode: .suggestions,
                acceptsTab: true,
                acceptsReturn: true
            )
        )
        XCTAssertEqual(gate.mode, .committing)
        XCTAssertEqual(
            gate.outcome(
                for: snapshot(
                    keyCode: RuntimeKeyboardKeyCode.returnKey,
                    flags: [.maskShift]
                )
            ),
            .passingThrough(
                predictionGeneration: generation,
                interactionRevision: 2
            )
        )
        XCTAssertEqual(
            gate.outcome(
                for: snapshot(keyCode: RuntimeKeyboardKeyCode.returnKey)
            ).decision,
            .passThrough
        )
    }

    func testInteractionInvalidationRejectsPendingPresentation() {
        let gate = RuntimeInterceptionGate()
        gate.configureExactCommitPrediction(
            trigger: ":",
            isEnabled: true,
            exactTokens: ["frog"]
        )
        gate.setCaptureEnabled(true)
        _ = gate.outcome(
            for: snapshot(
                keyCode: 41,
                flags: [.maskShift],
                characters: ":"
            )
        )
        XCTAssertTrue(
            gate.expectPresentation(
                revision: 1,
                interactionRevision: gate.interactionRevision
            )
        )

        XCTAssertEqual(
            gate.outcome(
                for: snapshot(keyCode: 49, characters: " ")
            ).decision,
            .passThrough
        )
        XCTAssertFalse(
            gate.activatePresentation(
                revision: 1,
                mode: .suggestions,
                acceptsTab: true,
                acceptsReturn: true
            )
        )
        XCTAssertEqual(gate.mode, .hidden)
        XCTAssertEqual(
            gate.outcome(
                for: snapshot(keyCode: RuntimeKeyboardKeyCode.returnKey)
            ).decision,
            .passThrough
        )
    }

    func testCaretNavigationPassesThroughAndKeepsSuggestionsOpen() {
        let cases: [(CGKeyCode, CGEventFlags)] = [
            (RuntimeKeyboardKeyCode.leftArrow, []),
            (RuntimeKeyboardKeyCode.rightArrow, [.maskShift]),
            (RuntimeKeyboardKeyCode.leftArrow, [.maskAlternate]),
            (RuntimeKeyboardKeyCode.rightArrow, [.maskCommand]),
            (RuntimeKeyboardKeyCode.upArrow, [.maskShift]),
            (RuntimeKeyboardKeyCode.downArrow, [.maskAlternate])
        ]

        for (keyCode, flags) in cases {
            let gate = RuntimeInterceptionGate()
            gate.configureExactCommitPrediction(
                trigger: ":",
                isEnabled: true,
                exactTokens: ["frog"]
            )
            gate.setCaptureEnabled(true)
            _ = gate.outcome(
                for: snapshot(keyCode: 41, characters: ":")
            )
            gate.setMode(
                .suggestions,
                acceptsTab: true,
                acceptsReturn: true
            )

            let outcome = gate.outcome(
                for: snapshot(keyCode: keyCode, flags: flags)
            )

            XCTAssertEqual(outcome.decision, .passThrough)
            XCTAssertFalse(outcome.requiresContextRecovery)
            XCTAssertTrue(outcome.preservesSuggestionSurface)
            XCTAssertEqual(gate.mode, .suggestions)
            XCTAssertEqual(
                gate.outcome(
                    for: snapshot(keyCode: RuntimeKeyboardKeyCode.tab)
                ).decision,
                .passThrough
            )
        }
    }

    func testEditingRecoveredInteriorTokenRequestsAnotherRevalidation() {
        let gate = RuntimeInterceptionGate()
        gate.setCaptureEnabled(true)
        let interactionRevision = gate.interactionRevision
        XCTAssertTrue(
            gate.expectPresentation(
                revision: 1,
                interactionRevision: interactionRevision
            )
        )
        XCTAssertTrue(
            gate.activatePresentation(
                revision: 1,
                mode: .suggestions,
                acceptsTab: false,
                acceptsReturn: false,
                revalidatesTextEdits: true
            )
        )

        let outcome = gate.outcome(
            for: snapshot(keyCode: 0, characters: "x")
        )

        XCTAssertEqual(outcome.decision, .passThrough)
        XCTAssertTrue(outcome.requiresContextRecovery)
        XCTAssertEqual(gate.mode, .hidden)
    }

    func testBackspaceRestoresPredictionAfterInvalidCharacter() throws {
        let gate = RuntimeInterceptionGate()
        gate.configureExactCommitPrediction(
            trigger: ":",
            isEnabled: true,
            exactTokens: ["frog"]
        )
        gate.setCaptureEnabled(true)
        let opening = gate.outcome(
            for: snapshot(keyCode: 41, characters: ":")
        )
        let generation = try XCTUnwrap(opening.predictionGeneration)
        for character in "fro" {
            _ = gate.outcome(
                for: snapshot(
                    keyCode: 0,
                    characters: String(character)
                )
            )
        }
        XCTAssertTrue(
            gate.verifyExactCommitPrediction(
                generation: generation,
                expectedToken: ":fro"
            )
        )
        gate.setMode(
            .suggestions,
            acceptsTab: true,
            acceptsReturn: true
        )

        let invalid = gate.outcome(
            for: snapshot(keyCode: 49, characters: " ")
        )
        XCTAssertEqual(invalid.decision, .passThrough)
        XCTAssertEqual(gate.mode, .hidden)

        let recovery = gate.outcome(
            for: snapshot(keyCode: RuntimeKeyboardKeyCode.delete)
        )
        XCTAssertEqual(recovery.predictionGeneration, generation)
        XCTAssertTrue(
            gate.verifyExactCommitPrediction(
                generation: generation,
                expectedToken: ":fro"
            )
        )
        let interactionRevision = try XCTUnwrap(
            recovery.interactionRevision
        )
        XCTAssertTrue(
            gate.expectPresentation(
                revision: 1,
                interactionRevision: interactionRevision
            )
        )
        XCTAssertTrue(
            gate.activatePresentation(
                revision: 1,
                mode: .suggestions,
                acceptsTab: true,
                acceptsReturn: true
            )
        )
        XCTAssertEqual(gate.mode, .suggestions)

        _ = gate.outcome(
            for: snapshot(keyCode: 5, characters: "g")
        )
        XCTAssertTrue(
            gate.verifyExactCommitPrediction(
                generation: generation,
                expectedToken: ":frog"
            )
        )
        _ = gate.outcome(
            for: snapshot(keyCode: 41, characters: ":")
        )
        XCTAssertEqual(gate.mode, .committing)
        XCTAssertEqual(
            gate.outcome(
                for: snapshot(
                    keyCode: RuntimeKeyboardKeyCode.returnKey
                )
            ),
            .intercepting(.committing)
        )
    }

    func testPreservingHiddenPredictionKeepsRecoveryRevisionCurrent() throws {
        let gate = RuntimeInterceptionGate()
        gate.configureExactCommitPrediction(
            trigger: ":",
            isEnabled: true,
            exactTokens: ["frog"]
        )
        gate.setCaptureEnabled(true)
        let opening = gate.outcome(
            for: snapshot(keyCode: 41, characters: ":")
        )
        for character in "fro" {
            _ = gate.outcome(
                for: snapshot(
                    keyCode: 0,
                    characters: String(character)
                )
            )
        }
        XCTAssertTrue(
            gate.verifyExactCommitPrediction(
                generation: opening.predictionGeneration,
                expectedToken: ":fro"
            )
        )
        gate.setMode(
            .suggestions,
            acceptsTab: true,
            acceptsReturn: true
        )

        let invalid = gate.outcome(
            for: snapshot(keyCode: 49, characters: " ")
        )
        let hiddenRevision = try XCTUnwrap(
            invalid.interactionRevision
        )
        XCTAssertEqual(gate.mode, .hidden)

        gate.setMode(
            .hidden,
            acceptsTab: true,
            acceptsReturn: true,
            preservingExactCommitPrediction: true
        )
        XCTAssertEqual(gate.interactionRevision, hiddenRevision)

        let recovery = gate.outcome(
            for: snapshot(keyCode: RuntimeKeyboardKeyCode.delete)
        )
        XCTAssertEqual(recovery.interactionRevision, hiddenRevision)
        XCTAssertTrue(
            gate.expectPresentation(
                revision: 1,
                interactionRevision: hiddenRevision
            )
        )
    }

    func testEscapePreservesPredictionForTheNextTokenEdit() throws {
        let gate = RuntimeInterceptionGate()
        gate.configureExactCommitPrediction(
            trigger: ":",
            isEnabled: true,
            exactTokens: ["frog"]
        )
        gate.setCaptureEnabled(true)
        let opening = gate.outcome(
            for: snapshot(keyCode: 41, characters: ":")
        )
        let generation = try XCTUnwrap(opening.predictionGeneration)
        _ = gate.outcome(
            for: snapshot(keyCode: 3, characters: "f")
        )
        XCTAssertTrue(
            gate.verifyExactCommitPrediction(
                generation: generation,
                expectedToken: ":f"
            )
        )
        gate.setMode(
            .suggestions,
            acceptsTab: true,
            acceptsReturn: true
        )

        let escape = gate.outcome(
            for: snapshot(keyCode: RuntimeKeyboardKeyCode.escape)
        )
        let hiddenRevision = try XCTUnwrap(escape.interactionRevision)
        XCTAssertEqual(escape.predictionGeneration, generation)
        XCTAssertEqual(gate.mode, .hidden)

        gate.setMode(
            .hidden,
            acceptsTab: true,
            acceptsReturn: true,
            preservingExactCommitPrediction: true
        )
        XCTAssertEqual(gate.interactionRevision, hiddenRevision)

        let resumed = gate.outcome(
            for: snapshot(keyCode: 15, characters: "r")
        )
        XCTAssertEqual(resumed.predictionGeneration, generation)
        XCTAssertEqual(resumed.interactionRevision, hiddenRevision)
        XCTAssertTrue(
            gate.verifyExactCommitPrediction(
                generation: generation,
                expectedToken: ":fr"
            )
        )
    }

    func testTriggerStartsFreshPredictionDuringInvalidSuffix() throws {
        let gate = RuntimeInterceptionGate()
        gate.configureExactCommitPrediction(
            trigger: ":",
            isEnabled: true,
            exactTokens: ["frog", "smile"]
        )
        gate.setCaptureEnabled(true)
        let opening = gate.outcome(
            for: snapshot(keyCode: 41, characters: ":")
        )
        let firstGeneration = try XCTUnwrap(
            opening.predictionGeneration
        )
        _ = gate.outcome(
            for: snapshot(keyCode: 3, characters: "f")
        )
        _ = gate.outcome(
            for: snapshot(keyCode: 49, characters: " ")
        )

        let restarted = gate.outcome(
            for: snapshot(keyCode: 41, characters: ":")
        )
        XCTAssertNotEqual(
            restarted.predictionGeneration,
            firstGeneration
        )
        XCTAssertTrue(
            gate.verifyExactCommitPrediction(
                generation: restarted.predictionGeneration,
                expectedToken: ":"
            )
        )
    }

    func testStaleInteractionCannotRegisterANewPresentation() throws {
        let gate = RuntimeInterceptionGate()
        gate.configureExactCommitPrediction(
            trigger: ":",
            isEnabled: true,
            exactTokens: ["frog"]
        )
        gate.setCaptureEnabled(true)
        let opening = gate.outcome(
            for: snapshot(
                keyCode: 41,
                flags: [.maskShift],
                characters: ":"
            )
        )
        let originatingRevision = try XCTUnwrap(
            opening.interactionRevision
        )

        XCTAssertEqual(
            gate.outcome(
                for: snapshot(keyCode: 49, characters: " ")
            ).decision,
            .passThrough
        )
        XCTAssertFalse(
            gate.expectPresentation(
                revision: 1,
                interactionRevision: originatingRevision
            )
        )
        XCTAssertFalse(
            gate.activatePresentation(
                revision: 1,
                mode: .suggestions,
                acceptsTab: true,
                acceptsReturn: true
            )
        )
        XCTAssertEqual(gate.mode, .hidden)
        XCTAssertEqual(
            gate.outcome(
                for: snapshot(keyCode: RuntimeKeyboardKeyCode.returnKey)
            ).decision,
            .passThrough
        )
    }

    func testInvalidatedInteractionCannotReactivateCommit() {
        let gate = RuntimeInterceptionGate()
        gate.configureExactCommitPrediction(
            trigger: ":",
            isEnabled: true,
            exactTokens: ["frog"]
        )
        gate.setCaptureEnabled(true)
        gate.setMode(
            .suggestions,
            acceptsTab: true,
            acceptsReturn: true
        )
        let acceptance = gate.outcome(
            for: snapshot(keyCode: RuntimeKeyboardKeyCode.returnKey)
        )
        _ = gate.outcome(
            for: snapshot(keyCode: 7, characters: "x")
        )

        XCTAssertNil(
            gate.activateCommit(
                interactionRevision: acceptance.interactionRevision,
                acceptsTab: true,
                acceptsReturn: true
            )
        )
        XCTAssertEqual(gate.mode, .hidden)
    }

    func testEscapeInvalidatesQueuedSuggestionAcceptance() {
        let gate = RuntimeInterceptionGate()
        gate.configureExactCommitPrediction(
            trigger: ":",
            isEnabled: false,
            exactTokens: []
        )
        gate.setCaptureEnabled(true)
        gate.setMode(
            .suggestions,
            acceptsTab: true,
            acceptsReturn: true
        )
        let acceptance = gate.outcome(
            for: snapshot(keyCode: RuntimeKeyboardKeyCode.returnKey)
        )

        let escape = gate.outcome(
            for: snapshot(keyCode: RuntimeKeyboardKeyCode.escape)
        )
        XCTAssertEqual(escape, .intercepting(.suggestions))
        XCTAssertNotEqual(
            escape.interactionRevision,
            acceptance.interactionRevision
        )
        XCTAssertNil(
            gate.activateCommit(
                interactionRevision: acceptance.interactionRevision,
                acceptsTab: true,
                acceptsReturn: true
            )
        )
        XCTAssertEqual(gate.mode, .hidden)
        XCTAssertEqual(
            gate.outcome(
                for: snapshot(keyCode: RuntimeKeyboardKeyCode.returnKey)
            ).decision,
            .passThrough
        )
    }

    func testCommitReturnPassesThroughWhenReplayIsUnavailable() throws {
        let gate = RuntimeInterceptionGate()
        gate.configureExactCommitPrediction(
            trigger: ":",
            isEnabled: true,
            exactTokens: ["frog"]
        )
        gate.setCanReplayCommitSend(false)
        gate.setCaptureEnabled(true)
        gate.setMode(
            .committing,
            acceptsTab: true,
            acceptsReturn: true
        )
        let commitGeneration = try XCTUnwrap(
            gate.activateCommit(
                interactionRevision: gate.interactionRevision,
                acceptsTab: true,
                acceptsReturn: true
            )
        )

        XCTAssertEqual(
            gate.outcome(
                for: snapshot(
                    keyCode: RuntimeKeyboardKeyCode.returnKey
                )
            ).decision,
            .passThrough
        )
        XCTAssertFalse(
            gate.hasPendingCommitSend(
                generation: commitGeneration
            )
        )
    }

    func testSecondPickerReturnPassesThroughWithoutReplayCapability()
        throws
    {
        let gate = RuntimeInterceptionGate()
        gate.configureExactCommitPrediction(
            trigger: ":",
            isEnabled: false,
            exactTokens: []
        )
        gate.setCanReplayCommitSend(false)
        gate.setCaptureEnabled(true)
        gate.setMode(
            .suggestions,
            acceptsTab: true,
            acceptsReturn: true
        )
        let acceptance = gate.outcome(
            for: snapshot(keyCode: RuntimeKeyboardKeyCode.returnKey)
        )
        let send = gate.outcome(
            for: snapshot(keyCode: RuntimeKeyboardKeyCode.returnKey)
        )

        XCTAssertEqual(acceptance, .intercepting(.suggestions))
        XCTAssertEqual(send.decision, .passThrough)
        let generation = try XCTUnwrap(
            gate.activateCommit(
                interactionRevision: acceptance.interactionRevision,
                acceptsTab: true,
                acceptsReturn: true
            )
        )
        XCTAssertFalse(
            gate.hasPendingCommitSend(generation: generation)
        )
    }

    func testRapidSecondReturnQueuesSendBeforeSuggestionAcceptanceRuns()
        throws
    {
        let gate = RuntimeInterceptionGate()
        gate.configureExactCommitPrediction(
            trigger: ":",
            isEnabled: true,
            exactTokens: ["frog"]
        )
        gate.setCaptureEnabled(true)
        gate.setMode(
            .suggestions,
            acceptsTab: true,
            acceptsReturn: true
        )
        let firstAcceptance = gate.outcome(
            for: snapshot(keyCode: RuntimeKeyboardKeyCode.returnKey)
        )
        let queuedSend = gate.outcome(
            for: snapshot(keyCode: RuntimeKeyboardKeyCode.returnKey)
        )

        XCTAssertEqual(firstAcceptance, .intercepting(.suggestions))
        XCTAssertEqual(queuedSend, .intercepting(.suggestions))
        let commitGeneration = try XCTUnwrap(
            gate.activateCommit(
                interactionRevision:
                    firstAcceptance.interactionRevision,
                acceptsTab: true,
                acceptsReturn: true
            )
        )
        XCTAssertTrue(
            gate.hasPendingCommitSend(generation: commitGeneration)
        )
    }

    func testDifferentKeyDisarmsPendingExactCommit() {
        let gate = RuntimeInterceptionGate()
        gate.configureExactCommitPrediction(
            trigger: ":",
            isEnabled: true,
            exactTokens: ["frog"]
        )
        gate.setCaptureEnabled(true)
        _ = gate.outcome(
            for: snapshot(
                keyCode: 41,
                flags: [.maskShift],
                characters: ":"
            )
        )

        XCTAssertEqual(
            gate.decision(
                for: snapshot(keyCode: 7, characters: "x")
            ),
            .passThrough
        )
        XCTAssertFalse(gate.isExactCommitArmed)
        XCTAssertEqual(
            gate.decision(
                for: snapshot(
                    keyCode: 41,
                    flags: [.maskShift],
                    characters: ":"
                )
            ),
            .passThrough
        )
        XCTAssertEqual(gate.mode, .hidden)
    }

    func testMouseDownInvalidatesExactCommitBeforeAnotherFieldCanSend()
        throws
    {
        let gate = RuntimeInterceptionGate()
        gate.configureExactCommitPrediction(
            trigger: ":",
            isEnabled: true,
            exactTokens: ["frog"]
        )
        gate.setCaptureEnabled(true)

        let opening = gate.outcome(
            for: snapshot(
                keyCode: 41,
                flags: [.maskShift],
                characters: ":"
            )
        )
        let oldGeneration = try XCTUnwrap(
            opening.predictionGeneration
        )
        for character in "frog" {
            _ = gate.outcome(
                for: snapshot(
                    keyCode: 0,
                    characters: String(character)
                )
            )
        }
        XCTAssertTrue(
            gate.verifyExactCommitPrediction(
                generation: oldGeneration,
                expectedToken: ":fro"
            )
        )

        XCTAssertEqual(
            gate.decision(
                for: eventSnapshot(type: .leftMouseDown)
            ),
            .passThrough
        )
        XCTAssertEqual(gate.mode, .hidden)
        XCTAssertFalse(gate.isExactCommitArmed)

        let newOpening = gate.outcome(
            for: snapshot(
                keyCode: 41,
                flags: [.maskShift],
                characters: ":"
            )
        )
        XCTAssertNotEqual(
            newOpening.predictionGeneration,
            oldGeneration
        )
        XCTAssertFalse(
            gate.verifyExactCommitPrediction(
                generation: oldGeneration,
                expectedToken: ":frog"
            )
        )
        XCTAssertEqual(
            gate.decision(
                for: snapshot(
                    keyCode: RuntimeKeyboardKeyCode.returnKey
                )
            ),
            .passThrough
        )
    }

    private func snapshot(
        keyCode: CGKeyCode,
        flags: CGEventFlags = [],
        characters: String? = nil
    ) -> KeyboardEventSnapshot {
        KeyboardEventSnapshot(
            typeRawValue: CGEventType.keyDown.rawValue,
            keyCode: keyCode,
            flagsRawValue: flags.rawValue,
            timestamp: 1,
            characters: characters
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
}
