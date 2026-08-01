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

    func testExplicitRequestShowsPendingUntilTheSystemReportsItsDecision() {
        let provider = FakePermissionProvider()
        let history = FakePermissionHistory()
        let center = SystemPermissionCenter(
            provider: provider,
            history: history,
            grantObservationInterval: .seconds(60)
        )

        XCTAssertEqual(center.requestInputMonitoring(), .pending)
        XCTAssertEqual(center.snapshot.inputMonitoring, .pending)
        provider.granted[.inputMonitoring] = true
        center.refresh()
        XCTAssertEqual(center.snapshot.inputMonitoring, .granted)

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

    func testEveryUnresolvedPermissionOffersRequestAndSettings() {
        XCTAssertEqual(
            SystemPermissionStatus.notRequested.availableActions,
            [.request, .openSettings]
        )
        XCTAssertEqual(
            SystemPermissionStatus.denied.availableActions,
            [.request, .openSettings]
        )
        XCTAssertEqual(
            SystemPermissionStatus.revoked.availableActions,
            [.request, .openSettings]
        )
        XCTAssertEqual(
            SystemPermissionStatus.pending.availableActions,
            [.openSettings]
        )
        XCTAssertTrue(SystemPermissionStatus.granted.availableActions.isEmpty)
    }

    func testBoundedGrantObservationRefreshesUntilGrantedThenStops() async {
        let provider = FakePermissionProvider()
        let center = SystemPermissionCenter(
            provider: provider,
            history: FakePermissionHistory(),
            grantObservationInterval: .milliseconds(5),
            grantObservationAttemptLimit: 20
        )
        provider.resetPreflights()

        XCTAssertEqual(center.requestAccessibility(), .pending)
        provider.granted[.accessibility] = true

        let granted = await eventually {
            center.snapshot.accessibility == .granted
        }
        XCTAssertTrue(granted)
        let preflightCountAfterGrant = provider.preflights.count
        try? await Task.sleep(for: .milliseconds(30))
        XCTAssertEqual(provider.preflights.count, preflightCountAfterGrant)
    }

    func testGrantObservationStopsAfterItsBoundedWindow() async {
        let provider = FakePermissionProvider()
        let center = SystemPermissionCenter(
            provider: provider,
            history: FakePermissionHistory(),
            grantObservationInterval: .milliseconds(2),
            grantObservationAttemptLimit: 3
        )
        provider.resetPreflights()

        XCTAssertEqual(center.requestAccessibility(), .pending)
        let resolved = await eventually {
            center.snapshot.accessibility == .denied
        }
        XCTAssertTrue(resolved)

        let preflightCountAfterTimeout = provider.preflights.count
        try? await Task.sleep(for: .milliseconds(20))
        XCTAssertEqual(
            provider.preflights.count,
            preflightCountAfterTimeout
        )
    }

    func testInputMonitoringRequestUsesIOHIDAndCoreGraphics() {
        var calls: [String] = []
        let access = MacInputMonitoringPermissionAccess(
            checkCoreGraphics: {
                calls.append("check-core-graphics")
                return false
            },
            requestCoreGraphics: {
                calls.append("request-core-graphics")
                return false
            },
            checkIOHID: {
                calls.append("check-iohid")
                return false
            },
            requestIOHID: {
                calls.append("request-iohid")
                return false
            }
        )

        XCTAssertFalse(access.request())
        XCTAssertEqual(
            calls,
            [
                "request-iohid",
                "request-core-graphics",
                "check-core-graphics",
                "check-iohid"
            ]
        )
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
