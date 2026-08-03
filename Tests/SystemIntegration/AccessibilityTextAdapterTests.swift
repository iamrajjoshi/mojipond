import ApplicationServices
import XCTest
@testable import MojiPond

final class AccessibilityTextAdapterTests: XCTestCase {
    func testUTF16ValidationAcceptsWholeEmojiAndRejectsSplitSurrogate() {
        let text = "a🐸b"

        XCTAssertNoThrow(
            try AccessibilityTextAdapter.validate(
                NSRange(location: 1, length: 2),
                in: text
            )
        )
        XCTAssertThrowsError(
            try AccessibilityTextAdapter.validate(
                NSRange(location: 1, length: 1),
                in: text
            )
        ) { error in
            XCTAssertEqual(error as? AccessibilityTextError, .invalidUTF16Range)
        }
    }

    func testShortcodeTokenRangeUsesUTF16OffsetsAndIncludesClosingColon() {
        let text = "🐸 hello :party_parrot: later"
        let string = text as NSString
        let token = ":party_parrot:"
        let tokenRange = string.range(of: token)
        let caretBeforeClosingColon = NSRange(
            location: tokenRange.location + tokenRange.length - 1,
            length: 0
        )

        XCTAssertEqual(
            AccessibilityTextAdapter.shortcodeTokenRange(
                in: text,
                selection: caretBeforeClosingColon
            ),
            tokenRange
        )
        XCTAssertEqual(
            AccessibilityTextAdapter.shortcodeTokenRange(
                in: text,
                selection: NSRange(
                    location: tokenRange.location + tokenRange.length,
                    length: 0
                )
            ),
            tokenRange
        )
    }

    func testShortcodeTokenRangeFindsWholeOpenTokenAroundCaretOrSelection() {
        let text = "🐸 Say :party_parrot later"
        let tokenRange = (text as NSString).range(of: ":party_parrot")
        let cases = [
            NSRange(location: tokenRange.location + 1, length: 0),
            NSRange(location: tokenRange.location + 6, length: 0),
            NSRange(location: tokenRange.location + 1, length: 5),
            NSRange(location: tokenRange.location, length: 6),
            tokenRange
        ]

        for selection in cases {
            XCTAssertEqual(
                AccessibilityTextAdapter.shortcodeTokenRange(
                    in: text,
                    selection: selection
                ),
                tokenRange,
                "Expected the token around selection \(selection)"
            )
        }
    }

    func testShortcodeTokenRangeRejectsSelectionCrossingTokenBoundary() {
        let text = "Say :frog later"

        for selection in [
            NSRange(location: 3, length: 3),
            NSRange(location: 5, length: 6),
            NSRange(location: 4, length: 7)
        ] {
            XCTAssertNil(
                AccessibilityTextAdapter.shortcodeTokenRange(
                    in: text,
                    selection: selection
                ),
                "Expected selection \(selection) to leave the token"
            )
        }
    }

    func testShortcodeTokenRangeSupportsConfiguredTrigger() {
        XCTAssertEqual(
            AccessibilityTextAdapter.shortcodeTokenRange(
                in: "try ;wave",
                selection: NSRange(location: 9, length: 0),
                trigger: ";"
            ),
            NSRange(location: 4, length: 5)
        )
    }

    func testShortcodeTokenRangeRequiresOpeningWordBoundary() {
        XCTAssertNil(
            AccessibilityTextAdapter.shortcodeTokenRange(
                in: "hello:f",
                selection: NSRange(location: 7, length: 0)
            )
        )
        XCTAssertEqual(
            AccessibilityTextAdapter.shortcodeTokenRange(
                in: "hello :fworld",
                selection: NSRange(location: 8, length: 0)
            ),
            NSRange(location: 6, length: 7)
        )

        for text in [":f", "hello :f", "hello (:f"] {
            let selection = NSRange(
                location: text.utf16.count,
                length: 0
            )
            XCTAssertNotNil(
                AccessibilityTextAdapter.shortcodeTokenRange(
                    in: text,
                    selection: selection
                ),
                "Expected a token at a valid boundary in \(text)"
            )
        }
    }

    func testShortcodeTokenRangeTreatsDoubleTriggerAsOneToken() {
        XCTAssertEqual(
            AccessibilityTextAdapter.shortcodeTokenRange(
                in: "::",
                selection: NSRange(location: 2, length: 0)
            ),
            NSRange(location: 0, length: 2)
        )
    }

    func testContextFindsWholeTokenWhenCaretIsInsideQuery() throws {
        let system = FakeAccessibilityTextSystem()
        system.text = "hello :fworld"
        system.selection = NSRange(location: 8, length: 0)
        let adapter = AccessibilityTextAdapter(system: system)

        let context = try adapter.context(for: adapter.focusedTarget())

        XCTAssertEqual(
            context.tokenRange,
            NSRange(location: 6, length: 7)
        )
        XCTAssertEqual(context.textFragment, "hello :fworld")
        XCTAssertEqual(
            context.textFragmentRange,
            NSRange(location: 0, length: 13)
        )
    }

    func testDirectReplacementRevalidatesAndDoesNotUseClipboard() throws {
        let system = FakeAccessibilityTextSystem()
        system.text = "Hello :frog:"
        system.selection = NSRange(location: 12, length: 0)
        let adapter = AccessibilityTextAdapter(system: system)
        let target = try adapter.focusedTarget()
        let request = AccessibilityReplacementRequest(
            target: target,
            tokenRange: NSRange(location: 6, length: 6),
            expectedToken: ":frog:",
            expectedSelection: system.selection
        )

        try adapter.replaceUnicode("🐸", request: request)

        XCTAssertEqual(system.text, "Hello 🐸")
        XCTAssertEqual(system.replacements, ["🐸"])
        XCTAssertEqual(system.rangedStringReads, [request.tokenRange])
        XCTAssertEqual(system.fullValueReadCount, 0)
        XCTAssertEqual(
            system.selectedRangesSet,
            [NSRange(location: 6, length: 6)]
        )
    }

    func testReplacementCancelsWhenSelectionIsStale() throws {
        let system = FakeAccessibilityTextSystem()
        system.text = ":frog:"
        system.selection = NSRange(location: 6, length: 0)
        let adapter = AccessibilityTextAdapter(system: system)
        let target = try adapter.focusedTarget()
        let request = AccessibilityReplacementRequest(
            target: target,
            tokenRange: NSRange(location: 0, length: 6),
            expectedToken: ":frog:",
            expectedSelection: system.selection
        )
        system.selection = NSRange(location: 5, length: 0)

        XCTAssertThrowsError(try adapter.replaceUnicode("🐸", request: request)) {
            XCTAssertEqual($0 as? AccessibilityTextError, .staleSelection)
        }
        XCTAssertEqual(system.text, ":frog:")
    }

    func testReplacementCancelsForSecureFocusedElement() throws {
        let system = FakeAccessibilityTextSystem()
        system.text = ":secret:"
        system.selection = NSRange(location: 8, length: 0)
        system.subrole = kAXSecureTextFieldSubrole
        let adapter = AccessibilityTextAdapter(system: system)
        let target = try adapter.focusedTarget()
        let request = AccessibilityReplacementRequest(
            target: target,
            tokenRange: NSRange(location: 0, length: 8),
            expectedToken: ":secret:",
            expectedSelection: system.selection
        )

        XCTAssertThrowsError(try adapter.replaceUnicode("🔒", request: request)) {
            XCTAssertEqual($0 as? AccessibilityTextError, .secureTextField)
        }
    }

    func testMissingSubroleIsTreatedAsOrdinaryEditableText() throws {
        let missingSubroleErrors: [AccessibilityTextError] = [
            .unsupportedAttribute(kAXSubroleAttribute),
            .axFailure(
                operation: "read text target subrole",
                code: .noValue
            )
        ]

        for error in missingSubroleErrors {
            let system = FakeAccessibilityTextSystem()
            system.text = ":frog:"
            system.selection = NSRange(location: 6, length: 0)
            system.subroleError = error
            let adapter = AccessibilityTextAdapter(system: system)
            let target = try adapter.focusedTarget()

            XCTAssertFalse(try adapter.secureStatus(of: target))
            XCTAssertEqual(
                try adapter.context(for: target).tokenRange,
                NSRange(location: 0, length: 6)
            )
        }
    }

    func testReplacementCancelsWhenFocusedElementChanges() throws {
        let system = FakeAccessibilityTextSystem()
        system.text = ":frog:"
        system.selection = NSRange(location: 6, length: 0)
        let adapter = AccessibilityTextAdapter(system: system)
        let target = try adapter.focusedTarget()
        let request = AccessibilityReplacementRequest(
            target: target,
            tokenRange: NSRange(location: 0, length: 6),
            expectedToken: ":frog:",
            expectedSelection: system.selection
        )
        system.focusedElementReference = system.alternateElement

        XCTAssertThrowsError(try adapter.replaceUnicode("🐸", request: request)) {
            XCTAssertEqual($0 as? AccessibilityTextError, .staleTarget)
        }
    }

    func testContextIncludesCaretBoundsAndTokenRange() throws {
        let system = FakeAccessibilityTextSystem()
        system.text = "Say :frog"
        system.selection = NSRange(location: 9, length: 0)
        system.caretBounds = CGRect(x: 100, y: 200, width: 0, height: 18)
        let adapter = AccessibilityTextAdapter(system: system)

        let context = try adapter.context(for: adapter.focusedTarget())

        XCTAssertEqual(context.caretBounds, system.caretBounds)
        XCTAssertEqual(context.tokenRange, NSRange(location: 4, length: 5))
        XCTAssertEqual(context.textFragment, "Say :frog")
        XCTAssertEqual(system.fullValueReadCount, 0)
    }

    func testContextReadsOnlyABoundedWindowAroundInteriorSelection() throws {
        let system = FakeAccessibilityTextSystem()
        let prefix = String(repeating: "a", count: 200) + " "
        let suffix = " " + String(repeating: "z", count: 200)
        system.text = prefix + ":party_parrot" + suffix
        let tokenRange = (system.text as NSString).range(of: ":party_parrot")
        system.selection = NSRange(
            location: tokenRange.location + 3,
            length: 4
        )
        let adapter = AccessibilityTextAdapter(system: system)

        let context = try adapter.context(for: adapter.focusedTarget())

        XCTAssertEqual(context.tokenRange, tokenRange)
        XCTAssertEqual(context.selection, system.selection)
        XCTAssertEqual(
            context.textFragmentRange.location,
            system.selection.location
                - AccessibilityTextAdapter.maximumShortcodeContextLength
        )
        XCTAssertLessThanOrEqual(
            context.textFragmentRange.length,
            AccessibilityTextAdapter.maximumShortcodeContextLength * 2
                + system.selection.length
        )
        XCTAssertEqual(system.rangedStringReads, [context.textFragmentRange])
        XCTAssertEqual(system.fullValueReadCount, 0)
    }

    func testContextAlignsBoundedSuffixAroundSurrogatePair() throws {
        let system = FakeAccessibilityTextSystem()
        let trailingASCII = String(repeating: "z", count: 62)
        system.text = ":frog " + trailingASCII + "🐸"
        system.selection = NSRange(location: 3, length: 0)
        let adapter = AccessibilityTextAdapter(system: system)

        let context = try adapter.context(for: adapter.focusedTarget())

        XCTAssertEqual(
            context.tokenRange,
            NSRange(location: 0, length: 5)
        )
        XCTAssertEqual(
            context.textFragmentRange.location
                + context.textFragmentRange.length,
            68,
            "The bounded range should stop before a split surrogate pair"
        )
        XCTAssertEqual(system.fullValueReadCount, 0)
    }

    func testContextAlignsBoundedPrefixAroundSurrogatePair() throws {
        let system = FakeAccessibilityTextSystem()
        system.text = "🐸" + String(repeating: "a", count: 63) + " :"
        system.selection = NSRange(location: 67, length: 0)
        let adapter = AccessibilityTextAdapter(system: system)

        let context = try adapter.context(for: adapter.focusedTarget())

        XCTAssertEqual(
            context.tokenRange,
            NSRange(location: 66, length: 1)
        )
        XCTAssertEqual(
            context.textFragmentRange.location,
            2,
            "The bounded range should start after a split surrogate pair"
        )
        XCTAssertEqual(system.fullValueReadCount, 0)
    }

    func testContextFindsInteriorTokenWhenCharacterCountIsUnavailable()
        throws
    {
        let system = FakeAccessibilityTextSystem()
        system.text = "Say :party_parrot later"
        let tokenRange = (system.text as NSString).range(of: ":party_parrot")
        system.selection = NSRange(
            location: tokenRange.location + 4,
            length: 0
        )
        system.characterCountError = .axFailure(
            operation: "read text character count",
            code: .noValue
        )
        let adapter = AccessibilityTextAdapter(system: system)

        let context = try adapter.context(for: adapter.focusedTarget())

        XCTAssertEqual(context.tokenRange, tokenRange)
        XCTAssertEqual(system.fullValueReadCount, 0)
        XCTAssertLessThanOrEqual(
            system.rangedStringReads.count,
            AccessibilityTextAdapter.maximumShortcodeContextLength + 1
        )
    }

    func testContextFallsBackToPreviousCharacterWhenCollapsedCaretHasNoGeometry()
        throws
    {
        let unavailableErrors = [
            AXError.noValue,
            AXError.notEnoughPrecision
        ]

        for error in unavailableErrors {
            let system = FakeAccessibilityTextSystem()
            system.text = "Say :w"
            system.selection = NSRange(location: 6, length: 0)
            let collapsedRange = NSRange(location: 6, length: 0)
            let previousCharacterRange = NSRange(location: 5, length: 1)
            system.boundsErrorsByRange[collapsedRange] = .axFailure(
                operation: "read bounds for text range",
                code: error
            )
            system.boundsByRange[previousCharacterRange] = CGRect(
                x: 14,
                y: 20,
                width: 8,
                height: 18
            )
            let adapter = AccessibilityTextAdapter(system: system)

            let context = try adapter.context(for: adapter.focusedTarget())

            XCTAssertEqual(
                context.caretBounds,
                CGRect(x: 22, y: 20, width: 0, height: 18)
            )
            XCTAssertEqual(context.tokenRange, NSRange(location: 4, length: 2))
            XCTAssertEqual(
                system.boundsReads,
                [collapsedRange, previousCharacterRange]
            )
        }
    }

    func testContextFallsBackWhenCollapsedCaretGeometryIsDegenerate()
        throws
    {
        let system = FakeAccessibilityTextSystem()
        system.text = "Say :w"
        system.selection = NSRange(location: 6, length: 0)
        let collapsedRange = NSRange(location: 6, length: 0)
        let previousCharacterRange = NSRange(location: 5, length: 1)
        system.boundsByRange[collapsedRange] = CGRect(
            x: 0,
            y: 1_080,
            width: 0,
            height: 0
        )
        system.boundsByRange[previousCharacterRange] = CGRect(
            x: 314,
            y: 220,
            width: 8,
            height: 18
        )
        let adapter = AccessibilityTextAdapter(system: system)

        let context = try adapter.context(for: adapter.focusedTarget())

        XCTAssertEqual(
            context.caretBounds,
            CGRect(x: 322, y: 220, width: 0, height: 18)
        )
        XCTAssertEqual(
            system.boundsReads,
            [collapsedRange, previousCharacterRange]
        )
    }

    func testContextUsesTextMarkerBoundsWhenRangeGeometryIsDegenerate()
        throws
    {
        let system = FakeAccessibilityTextSystem()
        system.text = "Try :w"
        system.selection = NSRange(location: 6, length: 0)
        let collapsedRange = NSRange(location: 6, length: 0)
        let previousCharacterRange = NSRange(location: 5, length: 1)
        let degenerateBounds = CGRect(
            x: 0,
            y: 1_329,
            width: 0,
            height: 0
        )
        system.boundsByRange[collapsedRange] = degenerateBounds
        system.boundsByRange[previousCharacterRange] = degenerateBounds
        system.textMarkerBounds = CGRect(
            x: 1_086,
            y: 1_229,
            width: 8,
            height: 20
        )
        let adapter = AccessibilityTextAdapter(system: system)

        let context = try adapter.context(for: adapter.focusedTarget())

        XCTAssertEqual(
            context.caretBounds,
            CGRect(x: 1_094, y: 1_229, width: 0, height: 20)
        )
        XCTAssertEqual(
            system.boundsReads,
            [collapsedRange, previousCharacterRange]
        )
    }

    func testContextUsesLeadingEdgeForEditorWideTextMarkerBounds() throws {
        let system = FakeAccessibilityTextSystem()
        system.text = "Try :w"
        system.selection = NSRange(location: 6, length: 0)
        let degenerateBounds = CGRect(
            x: 0,
            y: 1_329,
            width: 0,
            height: 0
        )
        system.boundsByRange[
            NSRange(location: 6, length: 0)
        ] = degenerateBounds
        system.boundsByRange[
            NSRange(location: 5, length: 1)
        ] = degenerateBounds
        system.textMarkerBounds = CGRect(
            x: 393,
            y: 1_229,
            width: 709,
            height: 20
        )
        let adapter = AccessibilityTextAdapter(system: system)

        let context = try adapter.context(for: adapter.focusedTarget())

        XCTAssertEqual(
            context.caretBounds,
            CGRect(x: 393, y: 1_229, width: 0, height: 20)
        )
    }

    func testContextRejectsImplausiblyTallTextMarkerBounds() throws {
        let system = FakeAccessibilityTextSystem()
        system.text = "Try :w"
        system.selection = NSRange(location: 6, length: 0)
        let degenerateBounds = CGRect(
            x: 0,
            y: 1_329,
            width: 0,
            height: 0
        )
        system.boundsByRange[
            NSRange(location: 6, length: 0)
        ] = degenerateBounds
        system.boundsByRange[
            NSRange(location: 5, length: 1)
        ] = degenerateBounds
        system.textMarkerBounds = CGRect(
            x: 0,
            y: 39,
            width: 2_056,
            height: 1_290
        )
        let adapter = AccessibilityTextAdapter(system: system)

        let context = try adapter.context(for: adapter.focusedTarget())

        XCTAssertNil(context.caretBounds)
    }

    func testContextFallsBackToBoundedValueWhenRangedStringHasNoValue() throws {
        let system = FakeAccessibilityTextSystem()
        system.text = "Say :w"
        system.selection = NSRange(location: 6, length: 0)
        system.rangedStringError = .axFailure(
            operation: "read string for text range",
            code: .noValue
        )
        let adapter = AccessibilityTextAdapter(
            system: system,
            maximumFallbackDocumentLength: 64
        )

        let context = try adapter.context(for: adapter.focusedTarget())

        XCTAssertEqual(context.tokenRange, NSRange(location: 4, length: 2))
        XCTAssertEqual(context.textFragment, "Say :w")
        XCTAssertEqual(system.fullValueReadCount, 1)
    }

    func testNoValueCharacterCountFailsClosedWithoutReadingFullValue() throws {
        let system = FakeAccessibilityTextSystem()
        system.text = "Say :w"
        system.selection = NSRange(location: 6, length: 0)
        system.supportsRangedStrings = false
        system.characterCountError = .axFailure(
            operation: "read text character count",
            code: .noValue
        )
        let adapter = AccessibilityTextAdapter(system: system)

        XCTAssertThrowsError(
            try adapter.context(for: adapter.focusedTarget())
        ) {
            XCTAssertEqual(
                $0 as? AccessibilityTextError,
                .unsupportedAttribute(kAXStringForRangeParameterizedAttribute)
            )
        }
        XCTAssertEqual(system.fullValueReadCount, 0)
    }

    func testActionableCaretGeometryFailureStillFailsClosed() throws {
        let system = FakeAccessibilityTextSystem()
        system.text = "Say :w"
        system.selection = NSRange(location: 6, length: 0)
        let collapsedRange = NSRange(location: 6, length: 0)
        let expectedError = AccessibilityTextError.axFailure(
            operation: "read bounds for text range",
            code: .cannotComplete
        )
        system.boundsErrorsByRange[collapsedRange] = expectedError
        let adapter = AccessibilityTextAdapter(system: system)

        XCTAssertThrowsError(
            try adapter.context(for: adapter.focusedTarget())
        ) {
            XCTAssertEqual($0 as? AccessibilityTextError, expectedError)
        }
        XCTAssertEqual(system.boundsReads, [collapsedRange])
        XCTAssertEqual(system.fullValueReadCount, 0)
    }

    func testSmallControlUsesBoundedFullValueFallback() throws {
        let system = FakeAccessibilityTextSystem()
        system.text = ":frog:"
        system.selection = NSRange(location: 6, length: 0)
        system.supportsRangedStrings = false
        let adapter = AccessibilityTextAdapter(
            system: system,
            maximumFallbackDocumentLength: 64
        )
        let target = try adapter.focusedTarget()
        let request = AccessibilityReplacementRequest(
            target: target,
            tokenRange: NSRange(location: 0, length: 6),
            expectedToken: ":frog:",
            expectedSelection: system.selection
        )

        try adapter.replaceUnicode("🐸", request: request)

        XCTAssertEqual(system.fullValueReadCount, 1)
        XCTAssertEqual(system.text, "🐸")
    }

    func testLargeControlNeverFallsBackToReadingEntireValue() throws {
        let system = FakeAccessibilityTextSystem()
        system.text = String(repeating: "a", count: 10_000) + ":frog:"
        system.selection = NSRange(location: system.text.utf16.count, length: 0)
        system.supportsRangedStrings = false
        let adapter = AccessibilityTextAdapter(
            system: system,
            maximumFallbackDocumentLength: 4_096
        )
        let target = try adapter.focusedTarget()
        let tokenRange = (system.text as NSString).range(of: ":frog:")
        let request = AccessibilityReplacementRequest(
            target: target,
            tokenRange: tokenRange,
            expectedToken: ":frog:",
            expectedSelection: system.selection
        )

        XCTAssertThrowsError(try adapter.replaceUnicode("🐸", request: request)) {
            XCTAssertEqual(
                $0 as? AccessibilityTextError,
                .unsupportedAttribute(kAXStringForRangeParameterizedAttribute)
            )
        }
        XCTAssertEqual(system.fullValueReadCount, 0)
    }
}
