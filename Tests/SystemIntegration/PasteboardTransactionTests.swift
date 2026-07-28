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

    func testMacPasteboardRejectsInvalidRepresentationBeforeClearing() {
        let nativePasteboard = NSPasteboard(
            name: NSPasteboard.Name(
                "MojiPondTests-\(UUID().uuidString)"
            )
        )
        nativePasteboard.clearContents()
        nativePasteboard.setString(
            "original",
            forType: .string
        )
        let initialChangeCount = nativePasteboard.changeCount
        let access = MacPasteboardAccess(pasteboard: nativePasteboard)
        let invalid = PasteboardItemPayload(
            representations: [
                PasteboardRepresentation(
                    typeIdentifier: "",
                    data: Data("replacement".utf8)
                )
            ]
        )

        XCTAssertFalse(access.replaceContents(with: [invalid]))
        XCTAssertEqual(nativePasteboard.changeCount, initialChangeCount)
        XCTAssertEqual(
            nativePasteboard.string(forType: .string),
            "original"
        )
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
        XCTAssertEqual(
            pasteboard.items.first?.representations.first?.data,
            Data("temporary".utf8)
        )
        XCTAssertTrue(
            pasteboard.items.first?.representations.contains {
                $0.typeIdentifier
                    == "com.rajjoshi.MojiPond.temporary-pasteboard-owner"
            } == true
        )
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

    func testFailedTemporaryWriteNeverOverwritesConcurrentUserCopy() async {
        let original = [PasteboardItemPayload.text("original")]
        let userCopy = [PasteboardItemPayload.text("user copy")]
        let pasteboard = FakePasteboard(items: original)
        pasteboard.failingWriteAttempts = [1]
        pasteboard.failedWriteReplacement = userCopy
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
        XCTAssertEqual(pasteboard.items, userCopy)
        XCTAssertEqual(pasteboard.writeAttempts, 1)
    }

    func testImagePayloadIncludesOriginalAndCompatibilityRepresentations() throws {
        let image = NSImage(size: NSSize(width: 2, height: 2))
        image.lockFocus()
        NSColor.green.setFill()
        NSRect(x: 0, y: 0, width: 2, height: 2).fill()
        image.unlockFocus()
        let tiff = try XCTUnwrap(image.tiffRepresentation)
        let bitmap = try XCTUnwrap(NSBitmapImageRep(data: tiff))
        let png = try XCTUnwrap(
            bitmap.representation(using: .png, properties: [:])
        )

        let payload = PasteboardItemPayload.image(
            originalData: png,
            type: .png
        )
        let types = Set(payload.representations.map(\.typeIdentifier))

        XCTAssertTrue(types.contains(UTType.tiff.identifier))
        XCTAssertTrue(types.contains(UTType.png.identifier))
        XCTAssertEqual(
            payload.representations.first {
                $0.typeIdentifier == UTType.png.identifier
            }?.data,
            png
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

    func testCancelledQueuedTransactionNeverWrites() async throws {
        let pasteboard = FakePasteboard(items: [.text("original")])
        let coordinator = PasteboardTransactionCoordinator(
            pasteboard: pasteboard
        )

        let first = Task { @MainActor in
            try await coordinator.performTemporaryWrite(
                [.text("first")],
                restorationDelay: .zero
            ) {
                try await Task.sleep(for: .milliseconds(80))
            }
        }
        try await Task.sleep(for: .milliseconds(5))
        let second = Task { @MainActor in
            try await coordinator.performTemporaryWrite(
                [.text("second")],
                restorationDelay: .zero
            ) {}
        }
        try await Task.sleep(for: .milliseconds(5))
        second.cancel()

        _ = try await first.value
        do {
            _ = try await second.value
            XCTFail("Expected cancellation")
        } catch is CancellationError {
            // Expected.
        }

        XCTAssertEqual(pasteboard.writeAttempts, 2)
        XCTAssertEqual(pasteboard.items, [.text("original")])
    }

    func testCancellationAfterPasteActionCannotShortenRestoreDelay()
        async throws
    {
        let original = [PasteboardItemPayload.text("sensitive original")]
        let pasteboard = FakePasteboard(items: original)
        let coordinator = PasteboardTransactionCoordinator(
            pasteboard: pasteboard
        )
        let clock = ContinuousClock()
        let started = clock.now
        let task = Task { @MainActor in
            try await coordinator.performTemporaryWrite(
                [.text("selected media")],
                restorationDelay: .milliseconds(120)
            ) {}
        }

        while pasteboard.writeAttempts == 0 {
            try? await Task.sleep(for: .milliseconds(2))
        }
        task.cancel()
        try? await Task.sleep(for: .milliseconds(30))
        XCTAssertEqual(
            pasteboard.items.first?.representations.first?.data,
            Data("selected media".utf8)
        )

        let outcome = try await task.value
        let elapsed = started.duration(to: clock.now)
        XCTAssertGreaterThanOrEqual(elapsed, .milliseconds(110))
        XCTAssertEqual(outcome, .restored)
        XCTAssertEqual(pasteboard.items, original)
    }
}
