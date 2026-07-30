import ApplicationServices
import XCTest
@testable import MojiPond

@MainActor
final class InsertionEngineTests: XCTestCase {
    func testUnicodeUsesDirectAccessibilityWithoutTouchingClipboard() async throws {
        let system = FakeAccessibilityTextSystem()
        system.text = ":frog:"
        system.selection = NSRange(location: 6, length: 0)
        let adapter = AccessibilityTextAdapter(system: system)
        let request = AccessibilityReplacementRequest(
            target: try adapter.focusedTarget(),
            tokenRange: NSRange(location: 0, length: 6),
            expectedToken: ":frog:",
            expectedSelection: system.selection
        )
        let originalClipboard = [PasteboardItemPayload.text("keep me")]
        let pasteboard = FakePasteboard(items: originalClipboard)
        let poster = FakeEventPoster()
        let engine = InsertionEngine(
            accessibility: adapter,
            pasteboard: PasteboardTransactionCoordinator(
                pasteboard: pasteboard
            ),
            eventPoster: poster,
            restorationDelay: .zero
        )

        let result = await engine.insert(.unicode("🐸"), replacing: request)

        XCTAssertEqual(result, .inserted(.directAccessibility))
        XCTAssertEqual(system.text, "🐸")
        XCTAssertEqual(pasteboard.items, originalClipboard)
        XCTAssertEqual(poster.pasteCount, 0)
    }

    func testMessagesShapedUnicodeUsesValidatedPasteAndRestoresClipboard()
        async throws
    {
        let system = FakeAccessibilityTextSystem()
        system.text = ":wave:"
        system.selection = NSRange(location: 6, length: 0)
        system.caretBounds = nil
        system.boundsErrorsByRange[system.selection] = .axFailure(
            operation: "read bounds for text range",
            code: AXError.noValue.rawValue
        )
        system.rangedStringError = .axFailure(
            operation: "read string for text range",
            code: AXError.noValue.rawValue
        )
        system.settableAttributes = [kAXSelectedTextRangeAttribute]
        let adapter = AccessibilityTextAdapter(system: system)
        let target = try adapter.focusedTarget()
        let context = try adapter.context(for: target)
        let tokenRange = try XCTUnwrap(context.tokenRange)
        let request = AccessibilityReplacementRequest(
            target: target,
            tokenRange: tokenRange,
            expectedToken: ":wave:",
            expectedSelection: system.selection
        )
        let originalClipboard = [PasteboardItemPayload.text("keep me")]
        let pasteboard = FakePasteboard(items: originalClipboard)
        let poster = FakeEventPoster()
        let engine = InsertionEngine(
            accessibility: adapter,
            pasteboard: PasteboardTransactionCoordinator(
                pasteboard: pasteboard
            ),
            eventPoster: poster,
            restorationDelay: .zero
        )

        let result = await engine.insert(.unicode("👋"), replacing: request)

        XCTAssertNil(context.caretBounds)
        XCTAssertEqual(tokenRange, NSRange(location: 0, length: 6))
        XCTAssertEqual(
            result,
            .inserted(.temporaryPasteboard(.restored))
        )
        XCTAssertEqual(
            system.selectedRangesSet,
            [NSRange(location: 0, length: 6)]
        )
        XCTAssertEqual(poster.pasteCount, 1)
        XCTAssertEqual(pasteboard.items, originalClipboard)
    }

    func testMediaRevalidatesSelectsPastesAndRestoresClipboard() async throws {
        let system = FakeAccessibilityTextSystem()
        system.text = "Look :bufo:"
        system.selection = NSRange(location: 11, length: 0)
        let adapter = AccessibilityTextAdapter(system: system)
        let request = AccessibilityReplacementRequest(
            target: try adapter.focusedTarget(),
            tokenRange: NSRange(location: 5, length: 6),
            expectedToken: ":bufo:",
            expectedSelection: system.selection
        )
        let originalClipboard = [PasteboardItemPayload.text("original")]
        let pasteboard = FakePasteboard(items: originalClipboard)
        let poster = FakeEventPoster()
        let engine = InsertionEngine(
            accessibility: adapter,
            pasteboard: PasteboardTransactionCoordinator(
                pasteboard: pasteboard
            ),
            eventPoster: poster,
            restorationDelay: .zero
        )
        let media = PasteboardItemPayload(
            representations: [
                PasteboardRepresentation(
                    typeIdentifier: "public.png",
                    data: Data([1, 2, 3])
                )
            ]
        )

        let result = await engine.insert(.media(media), replacing: request)

        XCTAssertEqual(
            result,
            .inserted(.temporaryPasteboard(.restored))
        )
        XCTAssertEqual(
            system.selectedRangesSet,
            [NSRange(location: 5, length: 6)]
        )
        XCTAssertEqual(poster.pasteCount, 1)
        XCTAssertEqual(
            poster.targetProcessIdentifiers,
            [request.target.processIdentifier]
        )
        XCTAssertEqual(pasteboard.items, originalClipboard)
    }

    func testMediaRestoresClipboardOnlyAfterPasteIsAcknowledged() async throws {
        let system = FakeAccessibilityTextSystem()
        system.text = "Look :bufo:"
        system.selection = NSRange(location: 11, length: 0)
        let adapter = AccessibilityTextAdapter(system: system)
        let request = AccessibilityReplacementRequest(
            target: try adapter.focusedTarget(),
            tokenRange: NSRange(location: 5, length: 6),
            expectedToken: ":bufo:",
            expectedSelection: system.selection
        )
        let originalClipboard = [PasteboardItemPayload.text("original")]
        let pasteboard = FakePasteboard(items: originalClipboard)
        let poster = FakeEventPoster()
        let acknowledgement = expectation(
            description: "Messages acknowledges the paste"
        )
        poster.onPaste = {
            Task { @MainActor in
                try? await Task.sleep(for: .milliseconds(30))
                XCTAssertNotEqual(pasteboard.items, originalClipboard)
                system.text = "Look "
                system.selection = NSRange(location: 5, length: 0)
                acknowledgement.fulfill()
            }
        }
        let engine = InsertionEngine(
            accessibility: adapter,
            pasteboard: PasteboardTransactionCoordinator(
                pasteboard: pasteboard
            ),
            eventPoster: poster,
            restorationDelay: .milliseconds(240)
        )

        let clock = ContinuousClock()
        let startedAt = clock.now
        let result = await engine.insert(
            .media(.text("asset")),
            replacing: request
        )
        let elapsed = startedAt.duration(to: clock.now)

        await fulfillment(of: [acknowledgement], timeout: 1)
        XCTAssertEqual(
            result,
            .inserted(.temporaryPasteboard(.restored))
        )
        XCTAssertLessThan(elapsed, .milliseconds(160))
        XCTAssertEqual(pasteboard.items, originalClipboard)
    }

    func testMediaWithoutPasteAcknowledgementReturnsFallback() async throws {
        let system = FakeAccessibilityTextSystem()
        system.text = "Look :bufo:"
        system.selection = NSRange(location: 11, length: 0)
        let adapter = AccessibilityTextAdapter(system: system)
        let request = AccessibilityReplacementRequest(
            target: try adapter.focusedTarget(),
            tokenRange: NSRange(location: 5, length: 6),
            expectedToken: ":bufo:",
            expectedSelection: system.selection
        )
        let originalClipboard = [PasteboardItemPayload.text("original")]
        let pasteboard = FakePasteboard(items: originalClipboard)
        let engine = InsertionEngine(
            accessibility: adapter,
            pasteboard: PasteboardTransactionCoordinator(
                pasteboard: pasteboard
            ),
            eventPoster: FakeEventPoster(),
            restorationDelay: .milliseconds(60)
        )

        let result = await engine.insert(
            .media(.text("asset")),
            replacing: request
        )

        XCTAssertEqual(result, .copyFallbackAvailable(.unknown))
        XCTAssertEqual(pasteboard.items, originalClipboard)
        XCTAssertEqual(
            system.selectedRangesSet,
            [NSRange(location: 5, length: 6)]
        )
    }

    func testUnsafeClipboardSnapshotLeavesTokenAndClipboardUnchanged() async throws {
        let system = FakeAccessibilityTextSystem()
        system.text = ":bufo:"
        system.selection = NSRange(location: 6, length: 0)
        let adapter = AccessibilityTextAdapter(system: system)
        let request = AccessibilityReplacementRequest(
            target: try adapter.focusedTarget(),
            tokenRange: NSRange(location: 0, length: 6),
            expectedToken: ":bufo:",
            expectedSelection: system.selection
        )
        let originalClipboard = [PasteboardItemPayload.text("large clipboard")]
        let pasteboard = FakePasteboard(items: originalClipboard)
        let engine = InsertionEngine(
            accessibility: adapter,
            pasteboard: PasteboardTransactionCoordinator(
                pasteboard: pasteboard,
                memoryLimit: 1
            ),
            eventPoster: FakeEventPoster(),
            restorationDelay: .zero
        )

        let result = await engine.insert(
            .media(.text("not really media")),
            replacing: request
        )

        XCTAssertEqual(
            result,
            .copyFallbackAvailable(.unsafeClipboardSnapshot)
        )
        XCTAssertEqual(system.text, ":bufo:")
        XCTAssertTrue(system.selectedRangesSet.isEmpty)
        XCTAssertEqual(pasteboard.items, originalClipboard)
    }

    func testMissingPostPermissionDoesNotMutateAnything() async throws {
        let system = FakeAccessibilityTextSystem()
        system.text = ":bufo:"
        system.selection = NSRange(location: 6, length: 0)
        let adapter = AccessibilityTextAdapter(system: system)
        let request = AccessibilityReplacementRequest(
            target: try adapter.focusedTarget(),
            tokenRange: NSRange(location: 0, length: 6),
            expectedToken: ":bufo:",
            expectedSelection: system.selection
        )
        let originalClipboard = [PasteboardItemPayload.text("original")]
        let pasteboard = FakePasteboard(items: originalClipboard)
        let engine = InsertionEngine(
            accessibility: adapter,
            pasteboard: PasteboardTransactionCoordinator(
                pasteboard: pasteboard
            ),
            eventPoster: FakeEventPoster(canPostEvents: false),
            restorationDelay: .zero
        )

        let result = await engine.insert(
            .media(.text("asset")),
            replacing: request
        )

        XCTAssertEqual(
            result,
            .copyFallbackAvailable(.eventPostingUnavailable)
        )
        XCTAssertEqual(system.text, ":bufo:")
        XCTAssertEqual(pasteboard.items, originalClipboard)
    }

    func testRevokedReturnAuthorizationPreventsSyntheticPost() async throws {
        let system = FakeAccessibilityTextSystem()
        system.text = "🐸"
        system.selection = NSRange(location: 2, length: 0)
        let adapter = AccessibilityTextAdapter(system: system)
        let request = AccessibilityReplacementRequest(
            target: try adapter.focusedTarget(),
            tokenRange: NSRange(location: 0, length: 6),
            expectedToken: ":frog:",
            expectedSelection: NSRange(location: 6, length: 0)
        )
        let poster = FakeEventPoster()
        let engine = InsertionEngine(
            accessibility: adapter,
            pasteboard: PasteboardTransactionCoordinator(
                pasteboard: FakePasteboard()
            ),
            eventPoster: poster,
            restorationDelay: .zero,
            returnSettleDelay: .zero
        )

        let sent = await engine.sendReturnAfterConfirmedInsertion(
            replacing: request,
            claimSend: { false }
        )

        XCTAssertFalse(sent)
        XCTAssertEqual(poster.returnCount, 0)
    }

    func testBrowserInsertionAcknowledgesCollapsedCaretMovementBeforeSend()
        async throws
    {
        let system = FakeAccessibilityTextSystem()
        system.text = "Hello "
        system.selection = NSRange(location: 6, length: 0)
        let adapter = AccessibilityTextAdapter(system: system)
        let request = AccessibilityReplacementRequest(
            target: try adapter.focusedTarget(),
            tokenRange: system.selection,
            expectedToken: "",
            expectedSelection: system.selection
        )
        let family = "👨‍👩‍👧‍👦"
        try adapter.replaceUnicode(family, request: request)
        let poster = FakeEventPoster()
        let engine = InsertionEngine(
            accessibility: adapter,
            pasteboard: PasteboardTransactionCoordinator(
                pasteboard: FakePasteboard()
            ),
            eventPoster: poster,
            restorationDelay: .zero,
            returnSettleDelay: .zero
        )

        let sent = await engine.sendReturnAfterConfirmedInsertion(
            replacing: request
        )

        XCTAssertTrue(sent)
        XCTAssertEqual(system.text, "Hello \(family)")
        XCTAssertEqual(
            system.selection,
            NSRange(
                location: 6 + family.utf16.count,
                length: 0
            )
        )
        XCTAssertEqual(poster.returnCount, 1)
    }
}
