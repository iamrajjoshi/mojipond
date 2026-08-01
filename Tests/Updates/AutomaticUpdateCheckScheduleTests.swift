import Foundation
import XCTest
@testable import MojiPond

final class AutomaticUpdateCheckScheduleTests: XCTestCase {
    @MainActor
    func testTaskSchedulerRunsScheduledAction() async {
        let didRun = expectation(description: "scheduled action ran")
        let scheduler = TaskAutomaticUpdateCheckScheduler()

        scheduler.schedule(after: 0) {
            didRun.fulfill()
        }

        await fulfillment(of: [didRun], timeout: 1)
    }

    @MainActor
    func testTaskSchedulerCancelSuppressesSleepingAction() async {
        let didRun = expectation(description: "canceled action did not run")
        didRun.isInverted = true
        let scheduler = TaskAutomaticUpdateCheckScheduler()

        scheduler.schedule(after: 0.25) {
            didRun.fulfill()
        }
        scheduler.cancel()

        await fulfillment(of: [didRun], timeout: 0.1)
    }

    @MainActor
    func testTaskSchedulerReplacementSuppressesStaleAction() async {
        let staleAction = expectation(
            description: "replaced action did not run"
        )
        staleAction.isInverted = true
        let replacementAction = expectation(
            description: "replacement action ran"
        )
        let scheduler = TaskAutomaticUpdateCheckScheduler()

        scheduler.schedule(after: 0.25) {
            staleAction.fulfill()
        }
        scheduler.schedule(after: 0) {
            replacementAction.fulfill()
        }

        await fulfillment(
            of: [replacementAction, staleAction],
            timeout: 0.1
        )
    }

    func testHistoryStorePersistsAndClearsCheckHistory() throws {
        let suiteName = "AutomaticUpdateCheckScheduleTests.\(UUID())"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer {
            defaults.removePersistentDomain(forName: suiteName)
        }
        let store = UserDefaultsUpdateCheckHistoryStore(
            defaults: defaults
        )
        let date = Date(timeIntervalSince1970: 1_900_000_000)

        store.lastAutomaticCheckDate = date
        store.lastSuccessfulAutomaticCheckOutcome = .updateAvailable

        XCTAssertEqual(
            UserDefaultsUpdateCheckHistoryStore(defaults: defaults)
                .lastAutomaticCheckDate,
            date
        )
        XCTAssertEqual(
            UserDefaultsUpdateCheckHistoryStore(defaults: defaults)
                .lastSuccessfulAutomaticCheckOutcome,
            .updateAvailable
        )

        store.lastAutomaticCheckDate = nil
        store.lastSuccessfulAutomaticCheckOutcome = nil

        XCTAssertNil(store.lastAutomaticCheckDate)
        XCTAssertNil(store.lastSuccessfulAutomaticCheckOutcome)
        XCTAssertNil(
            defaults.object(
                forKey: UserDefaultsUpdateCheckHistoryStore
                    .lastAutomaticCheckDateKey
            )
        )
        XCTAssertNil(
            defaults.object(
                forKey: UserDefaultsUpdateCheckHistoryStore
                    .lastSuccessfulAutomaticCheckOutcomeKey
            )
        )
    }
}
