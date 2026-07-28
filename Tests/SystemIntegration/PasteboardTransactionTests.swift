import AppKit
import UniformTypeIdentifiers
import XCTest
@testable import MojiPond

@MainActor
final class PasteboardTransactionTests: XCTestCase {
    func testSnapshotPreservesMultipleItemsAndRepresentations() throws {
        let items = [
            PasteboardItemPayload(
                representations: [
                    PasteboardRepresentation(
                        typeIdentifier: "public.utf8-plain-text",
                        data: Data("hello".utf8)
                    ),
                    PasteboardRepresentation(
                        typeIdentifier: "public.html",
                        data: Data("<b>hello</b>".utf8)
                    )
                ]
            ),
            PasteboardItemPayload(
                representations: [
                    PasteboardRepresentation(
                        typeIdentifier: "public.png",
                        data: Data([1, 2, 3])
                    )
                ]
            )
        ]
        let pasteboard = FakePasteboard(items: items)
        let coordinator = PasteboardTransactionCoordinator(
            pasteboard: pasteboard,
            memoryLimit: 1_024
        )

        let snapshot = try coordinator.captureSnapshot()

        XCTAssertEqual(snapshot.items, items)
        XCTAssertEqual(snapshot.byteCount, 20)
    }

    func testUnchangedPasteboardRestoresOriginalEmptyClipboard() async throws {
        let pasteboard = FakePasteboard()
        let coordinator = PasteboardTransactionCoordinator(
            pasteboard: pasteboard
        )

        let outcome = try await coordinator.performTemporaryWrite(
            [.text("temporary")],
            restorationDelay: .zero
        ) {}

        XCTAssertEqual(outcome, .restored)
        XCTAssertTrue(pasteboard.items.isEmpty)
    }

    func testMemoryLimitAbortsBeforeChangingPasteboard() async {
        let original = [PasteboardItemPayload.text("too large")]
        let pasteboard = FakePasteboard(items: original)
        let coordinator = PasteboardTransactionCoordinator(
            pasteboard: pasteboard,
            memoryLimit: 2
        )

        do {
            _ = try await coordinator.performTemporaryWrite(
                [.text("temporary")],
                restorationDelay: .zero
            ) {}
            XCTFail("Expected a memory-limit error")
        } catch {
            XCTAssertEqual(
                error as? PasteboardTransactionError,
                .memoryLimitExceeded(limit: 2)
            )
        }
        XCTAssertEqual(pasteboard.items, original)
        XCTAssertEqual(pasteboard.changeCount, 0)
    }

    func testUserCopyRaceNeverGetsOverwrittenByRestore() async throws {
        let original = [PasteboardItemPayload.text("original")]
        let userCopy = [PasteboardItemPayload.text("user copy")]
        let pasteboard = FakePasteboard(items: original)
        let coordinator = PasteboardTransactionCoordinator(
            pasteboard: pasteboard
        )

        let outcome = try await coordinator.performTemporaryWrite(
            [.text("temporary")],
            restorationDelay: .zero
        ) {
            pasteboard.simulateExternalCopy(userCopy)
        }

        XCTAssertEqual(outcome, .skippedBecausePasteboardChanged)
        XCTAssertEqual(pasteboard.items, userCopy)
    }

    func testRestoreFailureReportsInsertionAsCompleted() async throws {
        let pasteboard = FakePasteboard(items: [.text("original")])
        pasteboard.failingWriteAttempts = [2]
        let coordinator = PasteboardTransactionCoordinator(
            pasteboard: pasteboard
        )

        let outcome = try await coordinator.performTemporaryWrite(
            [.text("temporary")],
            restorationDelay: .zero
        ) {}

        XCTAssertEqual(outcome, .restoreFailed)
        XCTAssertEqual(pasteboard.items, [.text("temporary")])
    }

    func testFailedTemporaryWriteAttemptsToRestoreOriginalSnapshot() async {
        let original = [PasteboardItemPayload.text("original")]
        let pasteboard = FakePasteboard(items: original)
        pasteboard.failingWriteAttempts = [1]
        pasteboard.failedWriteClearsContents = true
        let coordinator = PasteboardTransactionCoordinator(
            pasteboard: pasteboard
        )

        do {
            _ = try await coordinator.performTemporaryWrite(
                [.text("temporary")],
                restorationDelay: .zero
            ) {}
            XCTFail("Expected temporary write failure")
        } catch {
            XCTAssertEqual(
                error as? PasteboardTransactionError,
                .unableToWriteTemporaryItems
            )
        }
        XCTAssertEqual(pasteboard.items, original)
    }

    func testImagePayloadIncludesOriginalAndCompatibilityRepresentations() throws {
        let image = NSImage(size: NSSize(width: 2, height: 2))
        image.lockFocus()
        NSColor.green.setFill()
        NSRect(x: 0, y: 0, width: 2, height: 2).fill()
        image.unlockFocus()
        let tiff = try XCTUnwrap(image.tiffRepresentation)

        let payload = PasteboardItemPayload.image(
            originalData: tiff,
            type: .tiff
        )
        let types = Set(payload.representations.map(\.typeIdentifier))

        XCTAssertTrue(types.contains(UTType.tiff.identifier))
        XCTAssertTrue(types.contains(UTType.png.identifier))
        XCTAssertEqual(
            payload.representations.first {
                $0.typeIdentifier == UTType.tiff.identifier
            }?.data,
            tiff
        )
    }

    func testOriginalGIFBytesAreNeverFlattened() {
        let gifBytes = Data("GIF89a-original-animation".utf8)

        let payload = PasteboardItemPayload.image(
            originalData: gifBytes,
            type: .gif,
            includeCompatibilityFallbacks: false
        )

        XCTAssertEqual(
            payload.representations.first {
                $0.typeIdentifier == UTType.gif.identifier
            }?.data,
            gifBytes
        )
    }

    func testConcurrentTransactionsAreSerialized() async throws {
        let pasteboard = FakePasteboard(
            items: [.text("original")]
        )
        let coordinator = PasteboardTransactionCoordinator(
            pasteboard: pasteboard
        )
        var order: [String] = []

        let first = Task { @MainActor in
            try await coordinator.performTemporaryWrite(
                [.text("first")],
                restorationDelay: .zero
            ) {
                order.append("first-start")
                try await Task.sleep(for: .milliseconds(30))
                order.append("first-end")
            }
        }
        try await Task.sleep(for: .milliseconds(2))
        let second = Task { @MainActor in
            try await coordinator.performTemporaryWrite(
                [.text("second")],
                restorationDelay: .zero
            ) {
                order.append("second-start")
                order.append("second-end")
            }
        }

        _ = try await first.value
        _ = try await second.value

        XCTAssertEqual(
            order,
            ["first-start", "first-end", "second-start", "second-end"]
        )
        XCTAssertEqual(pasteboard.items, [.text("original")])
    }
}
