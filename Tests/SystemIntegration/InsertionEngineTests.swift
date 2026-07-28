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
}
