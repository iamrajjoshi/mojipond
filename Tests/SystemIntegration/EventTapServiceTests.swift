import CoreGraphics
import XCTest
@testable import MojiPond

final class EventTapServiceTests: XCTestCase {
    func testSyntheticEventsCarryRecursionPreventionTag() throws {
        let event = try XCTUnwrap(
            CGEvent(
                keyboardEventSource: nil,
                virtualKey: 0,
                keyDown: true
            )
        )

        XCTAssertFalse(SessionEventTapService.isSyntheticEvent(event))
        SessionEventTapService.tagAsSynthetic(event)
        XCTAssertTrue(SessionEventTapService.isSyntheticEvent(event))
    }

    func testHandlerAloneControlsActiveInterception() {
        let passThrough = SessionEventTapService(
            interceptionPolicy: { _ in .passThrough },
            eventHandler: { _ in }
        )
        let intercept = SessionEventTapService(
            interceptionPolicy: { _ in .intercept },
            eventHandler: { _ in }
        )
        let event = KeyboardEventSnapshot(
            typeRawValue: CGEventType.keyDown.rawValue,
            keyCode: 0,
            flagsRawValue: 0,
            timestamp: 1,
            characters: "a"
        )

        XCTAssertEqual(
            passThrough.interceptionDecision(for: event),
            .passThrough
        )
        XCTAssertEqual(
            intercept.interceptionDecision(for: event),
            .intercept
        )
    }

    func testDisablementDiagnosticsCountReenableAttempts() {
        let service = SessionEventTapService(eventHandler: { _ in })

        service.simulateDisablementForTesting(timedOut: true)
        service.simulateDisablementForTesting(timedOut: true)
        service.simulateDisablementForTesting(timedOut: false)

        XCTAssertEqual(
            service.diagnostics,
            EventTapDiagnosticSnapshot(
                timeoutDisablements: 2,
                userInputDisablements: 1,
                reenablements: 3
            )
        )
    }
}
