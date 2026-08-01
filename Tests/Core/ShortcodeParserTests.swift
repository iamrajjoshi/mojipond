import XCTest
@testable import MojiPond

final class ShortcodeParserTests: XCTestCase {
    private let start = Date(timeIntervalSince1970: 1_000)

    func testOpeningTriggerStartsBoundedSessionAndCharactersUpdateSuggestions() {
        var parser = ShortcodeParser(startingTransactionID: 41)

        let opening = parser.handle(.character(":"), at: start)
        XCTAssertFalse(opening.shouldConsumeEvent)
        XCTAssertEqual(opening.currentState.session?.transactionID.rawValue, 41)
        XCTAssertEqual(opening.currentState.session?.query, "")
        XCTAssertEqual(opening.actions.count, 1)

        let query = parser.handle(
            .character("L", modifiers: [.shift]),
            at: start.addingTimeInterval(0.1)
        )
        XCTAssertEqual(query.currentState.session?.query, "l")
        XCTAssertEqual(
            query.actions,
            [
                .updateSuggestions(
                    transactionID: ParserTransactionID(rawValue: 41),
                    query: "l",
                    token: ParsedShortcodeToken(trigger: .colon, query: "l", isClosed: false)
                )
            ]
        )
    }

    func testClosingTriggerRequestsExactLookupWithoutAutofiringPrefix() {
        var parser = ShortcodeParser()
        parser.handle(.character(":"), at: start)
        let prefix = parser.handle(.character("l"), at: start.addingTimeInterval(0.1))

        XCTAssertNotNil(prefix.currentState.session)
        XCTAssertFalse(prefix.actions.contains(where: {
            if case .requestExactReplacement = $0 {
                return true
            }
            return false
        }))

        let closing = parser.handle(.character(":"), at: start.addingTimeInterval(0.2))
        XCTAssertEqual(closing.currentState, .idle)
        XCTAssertEqual(
            closing.actions,
            [
                .requestExactReplacement(
                    transactionID: ParserTransactionID(rawValue: 1),
                    shortcode: "l",
                    token: ParsedShortcodeToken(trigger: .colon, query: "l", isClosed: true)
                )
            ]
        )
        XCTAssertEqual(
            ParsedShortcodeToken(trigger: .colon, query: "l", isClosed: true).utf16Length,
            3
        )
    }

    func testDoubleTriggerOpensBrowser() {
        var parser = ShortcodeParser()
        parser.handle(.character(":"), at: start)

        let result = parser.handle(.character(":"), at: start.addingTimeInterval(0.1))

        XCTAssertEqual(result.currentState, .idle)
        XCTAssertEqual(
            result.actions,
            [
                .openBrowser(
                    transactionID: ParserTransactionID(rawValue: 1),
                    token: ParsedShortcodeToken(trigger: .colon, query: "", isClosed: true)
                )
            ]
        )
    }

    func testEverySupportedTriggerCanOpenAndCloseToken() {
        for trigger in ShortcodeTrigger.allCases {
            let preferences = ShortcodePreferences(trigger: trigger)
            var parser = ShortcodeParser(
                configuration: ShortcodeParserConfiguration(preferences: preferences)
            )

            parser.handle(.character(trigger.character), at: start)
            parser.handle(.character("a"), at: start.addingTimeInterval(0.1))
            let result = parser.handle(
                .character(trigger.character),
                at: start.addingTimeInterval(0.2)
            )

            guard case let .requestExactReplacement(_, shortcode, token) = result.actions.first else {
                return XCTFail("Expected exact replacement for \(trigger)")
            }
            XCTAssertEqual(shortcode, "a")
            XCTAssertEqual(token.rendered, "\(trigger.rawValue)a\(trigger.rawValue)")
        }
    }

    func testBackspaceShrinksQueryThenDeletingOpeningTriggerResets() {
        var parser = ShortcodeParser()
        parser.handle(.character(":"), at: start)
        parser.handle(.character("a"), at: start)

        let firstBackspace = parser.handle(.backspace(), at: start)
        XCTAssertEqual(firstBackspace.currentState.session?.query, "")
        XCTAssertEqual(
            firstBackspace.actions,
            [.hideSuggestions(transactionID: ParserTransactionID(rawValue: 1))]
        )

        let secondBackspace = parser.handle(.backspace(), at: start)
        XCTAssertEqual(secondBackspace.currentState, .idle)
        XCTAssertEqual(
            secondBackspace.actions,
            [
                .reset(
                    transactionID: ParserTransactionID(rawValue: 1),
                    reason: .openingTriggerDeleted
                )
            ]
        )
    }

    func testBackspaceRestoresSuggestionsAfterInvalidSuffix() {
        var parser = ShortcodeParser()
        parser.handle(.character(":"), at: start)
        parser.handle(.character("f"), at: start)

        let invalid = parser.handle(.character(" "), at: start)
        XCTAssertEqual(invalid.currentState.session?.query, "f")
        XCTAssertEqual(
            invalid.actions,
            [
                .hideSuggestions(
                    transactionID: ParserTransactionID(rawValue: 1)
                )
            ]
        )

        let trailingCharacter = parser.handle(
            .character("x"),
            at: start
        )
        XCTAssertEqual(trailingCharacter.currentState.session?.query, "f")
        XCTAssertEqual(
            trailingCharacter.actions,
            [
                .hideSuggestions(
                    transactionID: ParserTransactionID(rawValue: 1)
                )
            ]
        )

        let firstBackspace = parser.handle(.backspace(), at: start)
        XCTAssertEqual(firstBackspace.currentState.session?.query, "f")
        XCTAssertEqual(
            firstBackspace.actions,
            [
                .hideSuggestions(
                    transactionID: ParserTransactionID(rawValue: 1)
                )
            ]
        )

        let restoringBackspace = parser.handle(.backspace(), at: start)
        XCTAssertEqual(restoringBackspace.currentState.session?.query, "f")
        XCTAssertEqual(
            restoringBackspace.actions,
            [
                .updateSuggestions(
                    transactionID: ParserTransactionID(rawValue: 1),
                    query: "f",
                    token: ParsedShortcodeToken(
                        trigger: .colon,
                        query: "f",
                        isClosed: false
                    )
                )
            ]
        )
    }

    func testTriggerStartsFreshSessionDuringInvalidSuffix() {
        var parser = ShortcodeParser()
        parser.handle(.character(":"), at: start)
        parser.handle(.character("f"), at: start)
        parser.handle(.character(" "), at: start)

        let restarted = parser.handle(.character(":"), at: start)

        XCTAssertEqual(restarted.currentState.session?.query, "")
        XCTAssertEqual(
            restarted.currentState.session?.transactionID,
            ParserTransactionID(rawValue: 2)
        )
        XCTAssertEqual(
            restarted.actions,
            [
                .reset(
                    transactionID: ParserTransactionID(rawValue: 1),
                    reason: .externallyCancelled
                ),
                .began(
                    ShortcodeParserSession(
                        transactionID:
                            ParserTransactionID(rawValue: 2),
                        openedAt: start,
                        lastInputAt: start,
                        query: "",
                        recoverableSuffixLength: 0
                    )
                )
            ]
        )
    }

    func testMaximumLengthIsCappedAndOverflowResetsAggressively() {
        var parser = ShortcodeParser(
            configuration: ShortcodeParserConfiguration(maximumTokenLength: 3)
        )
        parser.handle(.character(":"), at: start)
        parser.handle(.character("a"), at: start)
        parser.handle(.character("b"), at: start)
        parser.handle(.character("c"), at: start)

        let overflow = parser.handle(.character("d"), at: start)

        XCTAssertEqual(overflow.currentState, .idle)
        XCTAssertEqual(
            overflow.actions,
            [
                .reset(
                    transactionID: ParserTransactionID(rawValue: 1),
                    reason: .maximumLengthExceeded
                )
            ]
        )
    }

    func testDefaultMaximumAllowsExactly64CharactersAndRejectsThe65th() {
        var parser = ShortcodeParser()
        parser.handle(.character(":"), at: start)
        for _ in 0..<Shortcode.maximumLength {
            parser.handle(.character("a"), at: start)
        }

        XCTAssertEqual(parser.state.session?.query.count, 64)
        let overflow = parser.handle(.character("a"), at: start)
        XCTAssertEqual(overflow.currentState, .idle)
        XCTAssertEqual(
            overflow.actions,
            [
                .reset(
                    transactionID: ParserTransactionID(rawValue: 1),
                    reason: .maximumLengthExceeded
                )
            ]
        )
    }

    func testUnsupportedModifierResetsWithoutConsumption() {
        var parser = ShortcodeParser()
        parser.handle(.character(":"), at: start)
        let modified = parser.handle(
            .character("v", modifiers: [.command]),
            at: start
        )

        XCTAssertFalse(modified.shouldConsumeEvent)
        XCTAssertEqual(modified.currentState, .idle)
        XCTAssertEqual(
            modified.actions,
            [
                .reset(
                    transactionID: ParserTransactionID(rawValue: 1),
                    reason: .unsupportedModifiers
                )
            ]
        )
    }

    func testTimeoutResetsAndNextSessionHasMonotonicallyIncreasingID() {
        let preferences = ShortcodePreferences(parserTimeout: 1)
        var parser = ShortcodeParser(
            configuration: ShortcodeParserConfiguration(preferences: preferences),
            startingTransactionID: 7
        )
        parser.handle(.character(":"), at: start)

        let timeout = parser.handle(.timeout, at: start.addingTimeInterval(1))
        XCTAssertEqual(
            timeout.actions,
            [
                .reset(
                    transactionID: ParserTransactionID(rawValue: 7),
                    reason: .timeout
                )
            ]
        )

        parser.handle(.character(":"), at: start.addingTimeInterval(2))
        XCTAssertEqual(parser.state.session?.transactionID.rawValue, 8)
    }

    func testZeroTimeoutKeepsSessionAliveUntilExplicitlyCancelled() {
        var parser = ShortcodeParser()
        parser.handle(.character(":"), at: start)
        parser.handle(.character("f"), at: start)

        let timeout = parser.handle(
            .timeout,
            at: start.addingTimeInterval(60)
        )

        XCTAssertTrue(timeout.actions.isEmpty)
        XCTAssertEqual(timeout.currentState.session?.query, "f")
    }

    func testNavigationRefreshesPositiveTimeoutActivity() {
        let preferences = ShortcodePreferences(parserTimeout: 1)
        var parser = ShortcodeParser(
            configuration: ShortcodeParserConfiguration(
                preferences: preferences
            )
        )
        parser.handle(.character(":"), at: start)
        parser.handle(.character("f"), at: start)

        let navigation = parser.handle(
            .navigation(.arrowDown),
            at: start.addingTimeInterval(0.75)
        )
        XCTAssertTrue(navigation.shouldConsumeEvent)

        let beforeRefreshedDeadline = parser.handle(
            .timeout,
            at: start.addingTimeInterval(1.5)
        )
        XCTAssertTrue(beforeRefreshedDeadline.actions.isEmpty)
        XCTAssertEqual(beforeRefreshedDeadline.currentState.session?.query, "f")

        let afterRefreshedDeadline = parser.handle(
            .timeout,
            at: start.addingTimeInterval(1.75)
        )
        XCTAssertEqual(
            afterRefreshedDeadline.actions,
            [
                .reset(
                    transactionID: ParserTransactionID(rawValue: 1),
                    reason: .timeout
                )
            ]
        )
    }

    func testTriggerTypedAfterTimeoutStartsFreshTransactionInSameTransition() {
        let preferences = ShortcodePreferences(parserTimeout: 1)
        var parser = ShortcodeParser(
            configuration: ShortcodeParserConfiguration(preferences: preferences)
        )
        parser.handle(.character(":"), at: start)

        let transition = parser.handle(
            .character(":"),
            at: start.addingTimeInterval(2)
        )

        XCTAssertEqual(transition.currentState.session?.transactionID.rawValue, 2)
        XCTAssertEqual(transition.actions.count, 2)
        XCTAssertEqual(
            transition.actions.first,
            .reset(transactionID: ParserTransactionID(rawValue: 1), reason: .timeout)
        )
    }

    func testAllExternalSafetySignalsResetActiveSession() {
        let reasons: [ParserResetReason] = [
            .focusChanged,
            .applicationChanged,
            .mouseClick,
            .cursorMoved,
            .screenLocked,
            .permissionLost,
            .secureInput,
            .deadKeyOrIME,
            .externallyCancelled
        ]

        for (offset, reason) in reasons.enumerated() {
            var parser = ShortcodeParser(startingTransactionID: UInt64(offset + 1))
            parser.handle(.character(":"), at: start)
            parser.handle(.character("a"), at: start)

            let result = parser.handle(.reset(reason), at: start)

            XCTAssertEqual(result.currentState, .idle)
            XCTAssertEqual(
                result.actions,
                [
                    .reset(
                        transactionID: ParserTransactionID(rawValue: UInt64(offset + 1)),
                        reason: reason
                    )
                ]
            )
        }
    }

    func testVisiblePanelOwnsNavigationAcceptanceAndEscape() {
        var parser = ShortcodeParser()
        parser.handle(.character(":"), at: start)
        parser.handle(.character("a"), at: start)

        let down = parser.handle(.navigation(.arrowDown), at: start)
        XCTAssertTrue(down.shouldConsumeEvent)
        XCTAssertEqual(
            down.actions,
            [
                .moveSelection(
                    transactionID: ParserTransactionID(rawValue: 1),
                    direction: .arrowDown
                )
            ]
        )

        let accepted = parser.handle(.navigation(.tab), at: start)
        XCTAssertTrue(accepted.shouldConsumeEvent)
        XCTAssertEqual(accepted.currentState, .idle)

        parser.handle(.character(":"), at: start)
        parser.handle(.character("b"), at: start)
        let escaped = parser.handle(.escape, at: start)
        XCTAssertTrue(escaped.shouldConsumeEvent)
        XCTAssertEqual(escaped.currentState, .idle)
    }

    func testDisabledAcceptanceAndBareTriggerDoNotStealKeys() {
        let preferences = ShortcodePreferences(
            acceptsTab: false,
            acceptsReturn: false,
            showsSuggestionsOnBareTrigger: false
        )
        var parser = ShortcodeParser(
            configuration: ShortcodeParserConfiguration(preferences: preferences)
        )
        parser.handle(.character(":"), at: start)

        let arrow = parser.handle(.navigation(.arrowDown), at: start)
        XCTAssertFalse(arrow.shouldConsumeEvent)
        XCTAssertEqual(
            arrow.actions,
            [
                .reset(
                    transactionID: ParserTransactionID(rawValue: 1),
                    reason: .cursorMoved
                )
            ]
        )

        parser.handle(.character(":"), at: start)
        parser.handle(.character("a"), at: start)
        let tab = parser.handle(.navigation(.tab), at: start)
        XCTAssertFalse(tab.shouldConsumeEvent)
        XCTAssertEqual(
            tab.actions,
            [
                .reset(
                    transactionID: ParserTransactionID(rawValue: 2),
                    reason: .acceptanceDisabled
                )
            ]
        )
    }

    func testDisabledClosingAndDoubleTriggerFeaturesLeaveTextUntouchedAndReset() {
        let preferences = ShortcodePreferences(
            replacesOnExactClosingTrigger: false,
            opensBrowserOnDoubleTrigger: false
        )
        var parser = ShortcodeParser(
            configuration: ShortcodeParserConfiguration(preferences: preferences)
        )

        parser.handle(.character(":"), at: start)
        let double = parser.handle(.character(":"), at: start)
        XCTAssertEqual(
            double.actions,
            [
                .reset(
                    transactionID: ParserTransactionID(rawValue: 1),
                    reason: .doubleTriggerDisabled
                )
            ]
        )

        parser.handle(.character(":"), at: start)
        parser.handle(.character("a"), at: start)
        let exact = parser.handle(.character(":"), at: start)
        XCTAssertEqual(
            exact.actions,
            [
                .reset(
                    transactionID: ParserTransactionID(rawValue: 2),
                    reason: .exactReplacementDisabled
                )
            ]
        )
    }
}
