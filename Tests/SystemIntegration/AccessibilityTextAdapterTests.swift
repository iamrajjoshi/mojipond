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
