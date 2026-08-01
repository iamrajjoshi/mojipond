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

    func testShortcodeTokenRangeRequiresWordBoundaries() {
        XCTAssertNil(
            AccessibilityTextAdapter.shortcodeTokenRange(
                in: "hello:f",
                selection: NSRange(location: 7, length: 0)
            )
        )
        XCTAssertNil(
            AccessibilityTextAdapter.shortcodeTokenRange(
                in: "hello :fworld",
                selection: NSRange(location: 8, length: 0)
            )
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

    func testContextRejectsTokenWhenCaretIsInsideFollowingWord() throws {
        let system = FakeAccessibilityTextSystem()
        system.text = "hello :fworld"
        system.selection = NSRange(location: 8, length: 0)
        let adapter = AccessibilityTextAdapter(system: system)

        let context = try adapter.context(for: adapter.focusedTarget())

        XCTAssertNil(context.tokenRange)
        XCTAssertEqual(context.textFragment, "hello :f")
        XCTAssertEqual(
            context.textFragmentRange,
            NSRange(location: 0, length: 8)
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
                code: AXError.noValue.rawValue
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
                code: error.rawValue
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
            code: AXError.noValue.rawValue
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
            code: AXError.noValue.rawValue
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
            code: AXError.cannotComplete.rawValue
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
