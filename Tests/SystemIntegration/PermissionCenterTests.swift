import AppKit
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
        XCTAssertEqual(provider.preflights, SystemPermission.allCases)
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

    func testPermissionActionsMatchCurrentStatus() {
        XCTAssertEqual(
            SystemPermissionStatus.notRequested.primaryAction,
            .request
        )
        XCTAssertEqual(
            SystemPermissionStatus.denied.primaryAction,
            .openSettings
        )
        XCTAssertEqual(
            SystemPermissionStatus.revoked.primaryAction,
            .openSettings
        )
        XCTAssertNil(SystemPermissionStatus.granted.primaryAction)
    }

    func testSettingsOpenerUsesPermissionSpecificAnchorsAndFallback() {
        var opened: [URL] = []
        let opener = MacSystemPermissionSettingsOpener { url in
            opened.append(url)
            return opened.count == 3
        }

        XCTAssertTrue(opener.openSettings(for: .inputMonitoring))
        XCTAssertEqual(opened.count, 3)
        XCTAssertTrue(
            opened[0].absoluteString.contains("Privacy_ListenEvent")
        )
        XCTAssertFalse(
            opened[0].absoluteString.contains("Privacy_Accessibility")
        )
        XCTAssertFalse(
            opened[2].absoluteString.contains("Privacy_ListenEvent")
        )

        let accessibilityURLs =
            MacSystemPermissionSettingsOpener.candidateURLs(
                for: .accessibility
            )
        XCTAssertTrue(
            accessibilityURLs[0].absoluteString.contains(
                "Privacy_Accessibility"
            )
        )
    }

    func testSettingsOpenerReportsWhenEveryRouteFails() {
        let opener = MacSystemPermissionSettingsOpener { _ in false }

        XCTAssertFalse(opener.openSettings(for: .accessibility))
    }

    func testRefreshPreflightsEachPermissionOnce() {
        let provider = FakePermissionProvider()
        let center = SystemPermissionCenter(
            provider: provider,
            history: FakePermissionHistory()
        )
        provider.resetPreflights()

        center.refresh()

        XCTAssertEqual(provider.preflights, SystemPermission.allCases)
    }

    func testLiveUpdatesRefreshWhenApplicationBecomesActive() async {
        let notifications = NotificationCenter()
        let provider = FakePermissionProvider()
        let center = SystemPermissionCenter(
            provider: provider,
            history: FakePermissionHistory(),
            notificationCenter: notifications
        )
        center.startLiveUpdates()
        provider.resetPreflights()
        provider.granted[.accessibility] = true

        notifications.post(
            name: NSApplication.didBecomeActiveNotification,
            object: nil
        )

        let refreshed = await eventually {
            center.snapshot.accessibility == .granted
        }
        XCTAssertTrue(refreshed)
        XCTAssertEqual(provider.preflights, SystemPermission.allCases)
        center.stopLiveUpdates()
    }

    func testLiveUpdatesDoNotPollWhileApplicationRemainsActive() async {
        let provider = FakePermissionProvider()
        let center = SystemPermissionCenter(
            provider: provider,
            history: FakePermissionHistory(),
            notificationCenter: NotificationCenter()
        )
        center.startLiveUpdates()
        provider.resetPreflights()

        try? await Task.sleep(for: .seconds(1.1))

        XCTAssertTrue(provider.preflights.isEmpty)
        center.stopLiveUpdates()
    }

    private func eventually(
        timeout: Duration = .seconds(1),
        condition: @escaping @MainActor () -> Bool
    ) async -> Bool {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: timeout)
        while clock.now < deadline {
            if condition() {
                return true
            }
            try? await Task.sleep(for: .milliseconds(5))
        }
        return condition()
    }
}
