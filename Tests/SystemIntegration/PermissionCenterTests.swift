import XCTest
@testable import MojiPond

@MainActor
final class PermissionCenterTests: XCTestCase {
    func testInitializationOnlyPreflightsAndNeverRequests() {
        let provider = FakePermissionProvider()
        let center = SystemPermissionCenter(
            provider: provider,
            history: FakePermissionHistory()
        )

        XCTAssertEqual(center.snapshot.inputMonitoring, .notRequested)
        XCTAssertEqual(center.snapshot.accessibility, .notRequested)
        XCTAssertEqual(center.snapshot.eventPosting, .notRequested)
        XCTAssertTrue(provider.requests.isEmpty)
    }

    func testExplicitRequestRecordsDeniedAndGrantedStates() {
        let provider = FakePermissionProvider()
        let history = FakePermissionHistory()
        let center = SystemPermissionCenter(provider: provider, history: history)

        XCTAssertEqual(center.requestInputMonitoring(), .denied)
        provider.requestResults[.accessibility] = true
        XCTAssertEqual(center.requestAccessibility(), .granted)
        provider.requestResults[.eventPosting] = true
        XCTAssertEqual(center.requestEventPosting(), .granted)

        XCTAssertEqual(
            provider.requests,
            [.inputMonitoring, .accessibility, .eventPosting]
        )
        XCTAssertTrue(history.requested.contains(.inputMonitoring))
        XCTAssertTrue(history.everGranted.contains(.accessibility))
    }

    func testRefreshSurfacesRevocation() {
        let provider = FakePermissionProvider()
        let history = FakePermissionHistory()
        provider.granted[.accessibility] = true
        let center = SystemPermissionCenter(provider: provider, history: history)
        XCTAssertEqual(center.snapshot.accessibility, .granted)

        provider.granted[.accessibility] = false
        center.refresh()

        XCTAssertEqual(center.snapshot.accessibility, .revoked)
    }
}
