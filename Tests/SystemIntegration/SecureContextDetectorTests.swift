import ApplicationServices
import XCTest
@testable import MojiPond

final class SecureContextDetectorTests: XCTestCase {
    func testSecureEventInputSuspendsCapture() {
        let detector = SecureContextDetector(
            secureInput: FakeSecureInputProvider(
                isSecureEventInputEnabled: true
            ),
            accessibility: AccessibilityTextAdapter(
                system: FakeAccessibilityTextSystem()
            )
        )

        let status = detector.currentStatus()

        XCTAssertTrue(status.secureEventInputEnabled)
        XCTAssertTrue(status.shouldSuspendCapture)
        XCTAssertTrue(status.accessibilityStatusKnown)
    }

    func testSecureAXSubroleSuspendsCapture() {
        let system = FakeAccessibilityTextSystem()
        system.subrole = kAXSecureTextFieldSubrole
        let detector = SecureContextDetector(
            secureInput: FakeSecureInputProvider(
                isSecureEventInputEnabled: false
            ),
            accessibility: AccessibilityTextAdapter(system: system)
        )

        let status = detector.currentStatus()

        XCTAssertTrue(status.focusedElementIsSecure)
        XCTAssertTrue(status.shouldSuspendCapture)
        XCTAssertTrue(status.accessibilityStatusKnown)
    }

    func testUnknownAccessibilityStateFailsClosed() {
        let system = FakeAccessibilityTextSystem()
        system.subroleError = AccessibilityTextError.noFocusedElement
        let detector = SecureContextDetector(
            secureInput: FakeSecureInputProvider(
                isSecureEventInputEnabled: false
            ),
            accessibility: AccessibilityTextAdapter(system: system)
        )

        let status = detector.currentStatus()

        XCTAssertFalse(status.accessibilityStatusKnown)
        XCTAssertTrue(status.shouldSuspendCapture)
    }
}
