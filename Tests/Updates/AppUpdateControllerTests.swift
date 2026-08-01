import CryptoKit
import Dispatch
import Foundation
import XCTest
@testable import MojiPond

@MainActor
final class AppUpdateControllerTests: XCTestCase {
    func testBundleConfigurationRequiresMatchingAlgorithmAndBase64Key() {
        let keyData = Data([1, 2, 3, 4])
        let configuration = BundledUpdateConfigurationLoader.load(
            infoDictionary: [
                BundledUpdateConfigurationLoader.feedURLKey:
                    "https://updates.example.com/feed.json",
                BundledUpdateConfigurationLoader.publicKeyKey:
                    keyData.base64EncodedString(),
                BundledUpdateConfigurationLoader.algorithmKey:
                    UpdateSignatureAlgorithm.ed25519.rawValue
            ],
            automaticChecksEnabled: true
        )

        XCTAssertEqual(
            configuration.feedURL?.absoluteString,
            "https://updates.example.com/feed.json"
        )
        XCTAssertEqual(
            configuration.publicKey,
            .ed25519(rawRepresentation: keyData)
        )
        XCTAssertTrue(configuration.automaticChecksEnabled)

        let malformed = BundledUpdateConfigurationLoader.load(
            infoDictionary: [
                BundledUpdateConfigurationLoader.feedURLKey:
                    "https://updates.example.com/feed.json",
                BundledUpdateConfigurationLoader.publicKeyKey:
                    "not base64",
                BundledUpdateConfigurationLoader.algorithmKey:
                    UpdateSignatureAlgorithm.ed25519.rawValue
            ],
            automaticChecksEnabled: false
        )
        XCTAssertNil(malformed.publicKey)
    }

    func testUpdateChecksRequireBothFeedAndVerificationKey() {
        let feedURL = URL(
            string: "https://updates.example.com/feed.json"
        )
        let publicKey = UpdateVerificationKey.ed25519(
            rawRepresentation: Data([1])
        )

        XCTAssertFalse(
            AppUpdateController(
                configuration: SignedUpdateConfiguration()
            ).canCheckForUpdates
        )
        XCTAssertFalse(
            AppUpdateController(
                configuration: SignedUpdateConfiguration(feedURL: feedURL)
            ).canCheckForUpdates
        )
        XCTAssertFalse(
            AppUpdateController(
                configuration: SignedUpdateConfiguration(
                    publicKey: publicKey
                )
            ).canCheckForUpdates
        )
        XCTAssertTrue(
            AppUpdateController(
                configuration: SignedUpdateConfiguration(
                    feedURL: feedURL,
                    publicKey: publicKey
                )
            ).canCheckForUpdates
        )
    }

    func testManualCheckReportsMissingSignedConfigurationWithoutFetching()
        async
    {
        let controller = AppUpdateController(
            configuration: SignedUpdateConfiguration()
        )

        controller.checkManually(automaticChecksEnabled: false)
        await waitForCheckToFinish(controller)

        XCTAssertEqual(controller.state, .disabled(.missingFeedURL))
        XCTAssertEqual(
            controller.statusSummary,
            "Disabled until a signed feed is configured"
        )
    }

    func testAutomaticOptOutDoesNotStartACheck() {
        let configuration = SignedUpdateConfiguration(
            feedURL: URL(
                string: "https://updates.example.com/feed.json"
            ),
            publicKey: .ed25519(rawRepresentation: Data([1]))
        )
        let controller = AppUpdateController(
            configuration: configuration
        )

        controller.start(automaticChecksEnabled: false)

        XCTAssertEqual(controller.state, .idle)
    }

    func testAutomaticChecksRunImmediatelyAndRepeatDaily()
        async throws
    {
        let fixture = try await makeVerifiedUpdateFixture()
        let firstChecker = ImmediateUpdateChecker(
            result: .verified(fixture.metadata)
        )
        let secondChecker = ImmediateUpdateChecker(
            result: .verified(fixture.metadata)
        )
        let checkerSequence = UpdateCheckerSequence([
            firstChecker,
            secondChecker,
        ])
        let now = MutableUpdateCheckDate(
            Date(timeIntervalSince1970: 1_900_000_000)
        )
        let history = InMemoryUpdateCheckHistoryStore()
        let scheduler = ManualAutomaticUpdateCheckScheduler()
        let controller = AppUpdateController(
            configuration: fixture.configuration,
            currentVersion: "0.2.0",
            currentBuild: 2,
            checkerFactory: { _ in checkerSequence.next() },
            currentDate: { now.value },
            checkHistoryStore: history,
            automaticCheckScheduler: scheduler
        )

        controller.start(automaticChecksEnabled: true)

        XCTAssertEqual(controller.state, .checking)
        XCTAssertEqual(history.lastAutomaticCheckDate, now.value)
        XCTAssertEqual(
            try XCTUnwrap(scheduler.scheduledDelay),
            AppUpdateController.defaultAutomaticCheckInterval,
            accuracy: 0.001
        )
        await waitForCheckToFinish(controller)
        XCTAssertEqual(
            controller.state,
            .current(version: "0.2.0")
        )
        XCTAssertEqual(
            history.lastSuccessfulAutomaticCheckOutcome,
            .noActionableUpdate
        )

        now.value = now.value.addingTimeInterval(
            AppUpdateController.defaultAutomaticCheckInterval
        )
        scheduler.fire()

        XCTAssertEqual(controller.state, .checking)
        XCTAssertEqual(history.lastAutomaticCheckDate, now.value)
        await waitForCheckToFinish(controller)
        XCTAssertEqual(
            controller.state,
            .current(version: "0.2.0")
        )
    }

    func testRecentCurrentCheckWaitsOnlyForRemainingInterval()
        async throws
    {
        let fixture = try await makeVerifiedUpdateFixture()
        let checkerSequence = UpdateCheckerSequence([
            ImmediateUpdateChecker(
                result: .verified(fixture.metadata)
            ),
        ])
        let hour: TimeInterval = 60 * 60
        let now = MutableUpdateCheckDate(
            Date(timeIntervalSince1970: 1_900_000_000)
        )
        let history = InMemoryUpdateCheckHistoryStore()
        history.lastAutomaticCheckDate = now.value
            .addingTimeInterval(-hour)
        history.lastSuccessfulAutomaticCheckOutcome = .noActionableUpdate
        let scheduler = ManualAutomaticUpdateCheckScheduler()
        let controller = AppUpdateController(
            configuration: fixture.configuration,
            currentVersion: "0.2.0",
            currentBuild: 2,
            checkerFactory: { _ in checkerSequence.next() },
            currentDate: { now.value },
            checkHistoryStore: history,
            automaticCheckScheduler: scheduler
        )

        controller.start(automaticChecksEnabled: true)

        XCTAssertEqual(controller.state, .idle)
        XCTAssertEqual(
            try XCTUnwrap(scheduler.scheduledDelay),
            AppUpdateController.defaultAutomaticCheckInterval - hour,
            accuracy: 0.001
        )

        now.value = try XCTUnwrap(history.lastAutomaticCheckDate)
            .addingTimeInterval(
                AppUpdateController.defaultAutomaticCheckInterval
            )
        scheduler.fire()

        XCTAssertEqual(controller.state, .checking)
        XCTAssertEqual(history.lastAutomaticCheckDate, now.value)
        await waitForCheckToFinish(controller)
        XCTAssertEqual(
            controller.state,
            .current(version: "0.2.0")
        )
    }

    func testRecentAvailableOutcomeRechecksOnLaunch()
        async throws
    {
        let fixture = try await makeVerifiedUpdateFixture()
        let now = Date(timeIntervalSince1970: 1_900_000_000)
        let history = InMemoryUpdateCheckHistoryStore()
        history.lastAutomaticCheckDate = now.addingTimeInterval(-60 * 60)
        history.lastSuccessfulAutomaticCheckOutcome = .updateAvailable
        let checker = SuspendedUpdateChecker()
        let scheduler = ManualAutomaticUpdateCheckScheduler()
        let controller = AppUpdateController(
            configuration: fixture.configuration,
            currentVersion: "0.1.0",
            currentBuild: 1,
            checkerFactory: { _ in checker },
            currentDate: { now },
            checkHistoryStore: history,
            automaticCheckScheduler: scheduler
        )

        controller.start(automaticChecksEnabled: true)
        await checker.waitUntilStarted()

        XCTAssertEqual(controller.state, .checking)
        XCTAssertEqual(history.lastAutomaticCheckDate, now)
        await checker.finish(with: .verified(fixture.metadata))
        await waitForCheckToFinish(controller)

        XCTAssertEqual(
            controller.state,
            .available(fixture.metadata)
        )
        XCTAssertEqual(
            history.lastSuccessfulAutomaticCheckOutcome,
            .updateAvailable
        )
    }

    func testRecentIncompatibleOutcomeWaitsForRemainingInterval()
        async throws
    {
        let fixture = try await makeVerifiedUpdateFixture(
            minimumSystemVersion: "15.1"
        )
        let hour: TimeInterval = 60 * 60
        let now = MutableUpdateCheckDate(
            Date(timeIntervalSince1970: 1_900_000_000)
        )
        let history = InMemoryUpdateCheckHistoryStore()
        let firstScheduler = ManualAutomaticUpdateCheckScheduler()
        let firstController = AppUpdateController(
            configuration: fixture.configuration,
            currentVersion: "0.1.0",
            currentBuild: 1,
            currentSystemVersion: try XCTUnwrap(
                UpdateSystemVersion("15.0")
            ),
            checkerFactory: { _ in
                ImmediateUpdateChecker(
                    result: .verified(fixture.metadata)
                )
            },
            currentDate: { now.value },
            checkHistoryStore: history,
            automaticCheckScheduler: firstScheduler
        )

        firstController.start(automaticChecksEnabled: true)
        await waitForCheckToFinish(firstController)

        XCTAssertEqual(
            firstController.state,
            .incompatible(
                metadata: fixture.metadata,
                requiredSystemVersion: "15.1"
            )
        )
        XCTAssertEqual(
            history.lastSuccessfulAutomaticCheckOutcome,
            .noActionableUpdate
        )

        now.value = now.value.addingTimeInterval(hour)
        let relaunchScheduler = ManualAutomaticUpdateCheckScheduler()
        let relaunchedController = AppUpdateController(
            configuration: fixture.configuration,
            currentVersion: "0.1.0",
            currentBuild: 1,
            currentSystemVersion: try XCTUnwrap(
                UpdateSystemVersion("15.0")
            ),
            checkerFactory: { _ in
                XCTFail("A recent incompatible result should not recheck")
                return ImmediateUpdateChecker(
                    result: .verified(fixture.metadata)
                )
            },
            currentDate: { now.value },
            checkHistoryStore: history,
            automaticCheckScheduler: relaunchScheduler
        )

        relaunchedController.start(automaticChecksEnabled: true)

        XCTAssertEqual(relaunchedController.state, .idle)
        XCTAssertEqual(
            try XCTUnwrap(relaunchScheduler.scheduledDelay),
            AppUpdateController.defaultAutomaticCheckInterval - hour,
            accuracy: 0.001
        )
    }

    func testTurningOffAutomaticChecksCancelsTimerAndActiveCheck()
        async throws
    {
        let fixture = try await makeVerifiedUpdateFixture()
        let checker = SuspendedUpdateChecker()
        let scheduler = ManualAutomaticUpdateCheckScheduler()
        let controller = AppUpdateController(
            configuration: fixture.configuration,
            checkerFactory: { _ in checker },
            checkHistoryStore: InMemoryUpdateCheckHistoryStore(),
            automaticCheckScheduler: scheduler
        )

        controller.start(automaticChecksEnabled: true)
        await checker.waitUntilStarted()
        XCTAssertTrue(scheduler.hasScheduledAction)

        controller.automaticChecksPreferenceDidChange(enabled: false)

        XCTAssertEqual(controller.state, .idle)
        XCTAssertFalse(scheduler.hasScheduledAction)
    }

    func testCancelCurrentOperationKeepsAutomaticSchedule()
        async throws
    {
        let fixture = try await makeVerifiedUpdateFixture()
        let checker = SuspendedUpdateChecker()
        let scheduler = ManualAutomaticUpdateCheckScheduler()
        let controller = AppUpdateController(
            configuration: fixture.configuration,
            checkerFactory: { _ in checker },
            checkHistoryStore: InMemoryUpdateCheckHistoryStore(),
            automaticCheckScheduler: scheduler
        )

        controller.start(automaticChecksEnabled: true)
        await checker.waitUntilStarted()

        controller.cancelCurrentOperation()

        XCTAssertEqual(controller.state, .idle)
        XCTAssertTrue(scheduler.hasScheduledAction)
        controller.automaticChecksPreferenceDidChange(enabled: false)
    }

    func testCancelCurrentOperationKeepsKnownUpdateAvailable()
        async throws
    {
        let fixture = try await makeVerifiedUpdateFixture()
        let refreshChecker = SuspendedUpdateChecker()
        let checkerSequence = UpdateCheckerSequence([
            ImmediateUpdateChecker(
                result: .verified(fixture.metadata)
            ),
            refreshChecker,
        ])
        let controller = AppUpdateController(
            configuration: fixture.configuration,
            currentVersion: "0.1.0",
            currentBuild: 1,
            checkerFactory: { _ in checkerSequence.next() }
        )

        controller.checkManually(automaticChecksEnabled: false)
        await waitForCheckToFinish(controller)
        XCTAssertEqual(controller.state, .available(fixture.metadata))

        controller.checkManually(automaticChecksEnabled: false)
        await refreshChecker.waitUntilStarted()
        controller.cancelCurrentOperation()

        XCTAssertEqual(controller.state, .available(fixture.metadata))
    }

    func testScheduledCheckRefreshesAnAvailableUpdate()
        async throws
    {
        let firstFixture = try await makeVerifiedUpdateFixture()
        let newerFixture = try await makeVerifiedUpdateFixture(
            version: "0.3.0",
            build: 3
        )
        let checkerSequence = UpdateCheckerSequence([
            ImmediateUpdateChecker(
                result: .verified(firstFixture.metadata)
            ),
            ImmediateUpdateChecker(
                result: .verified(newerFixture.metadata)
            ),
        ])
        let now = MutableUpdateCheckDate(
            Date(timeIntervalSince1970: 1_900_000_000)
        )
        let scheduler = ManualAutomaticUpdateCheckScheduler()
        let controller = AppUpdateController(
            configuration: firstFixture.configuration,
            currentVersion: "0.1.0",
            currentBuild: 1,
            checkerFactory: { _ in checkerSequence.next() },
            currentDate: { now.value },
            checkHistoryStore: InMemoryUpdateCheckHistoryStore(),
            automaticCheckScheduler: scheduler
        )

        controller.start(automaticChecksEnabled: true)
        await waitForCheckToFinish(controller)
        XCTAssertEqual(
            controller.state,
            .available(firstFixture.metadata)
        )

        now.value = now.value.addingTimeInterval(
            AppUpdateController.defaultAutomaticCheckInterval
        )
        scheduler.fire()

        XCTAssertEqual(controller.state, .checking)
        await waitForCheckToFinish(controller)
        XCTAssertEqual(
            controller.state,
            .available(newerFixture.metadata)
        )
        XCTAssertEqual(
            try XCTUnwrap(scheduler.scheduledDelay),
            AppUpdateController.defaultAutomaticCheckInterval,
            accuracy: 0.001
        )
    }

    func testTurningOffDuringScheduledRefreshKeepsVerifiedUpdate()
        async throws
    {
        let fixture = try await makeVerifiedUpdateFixture()
        let refreshChecker = SuspendedUpdateChecker()
        let checkerSequence = UpdateCheckerSequence([
            ImmediateUpdateChecker(
                result: .verified(fixture.metadata)
            ),
            refreshChecker,
        ])
        let scheduler = ManualAutomaticUpdateCheckScheduler()
        let controller = AppUpdateController(
            configuration: fixture.configuration,
            currentVersion: "0.1.0",
            currentBuild: 1,
            checkerFactory: { _ in checkerSequence.next() },
            checkHistoryStore: InMemoryUpdateCheckHistoryStore(),
            automaticCheckScheduler: scheduler
        )

        controller.start(automaticChecksEnabled: true)
        await waitForCheckToFinish(controller)
        XCTAssertEqual(
            controller.state,
            .available(fixture.metadata)
        )

        scheduler.fire()
        await refreshChecker.waitUntilStarted()
        XCTAssertEqual(controller.state, .checking)

        controller.automaticChecksPreferenceDidChange(enabled: false)

        XCTAssertEqual(
            controller.state,
            .available(fixture.metadata)
        )
        XCTAssertFalse(scheduler.hasScheduledAction)
    }

    func testFailedScheduledRefreshKeepsLastVerifiedUpdate()
        async throws
    {
        let fixture = try await makeVerifiedUpdateFixture()
        let checkerSequence = UpdateCheckerSequence([
            ImmediateUpdateChecker(
                result: .verified(fixture.metadata)
            ),
            FailingUpdateChecker(error: .transportFailure),
        ])
        let now = MutableUpdateCheckDate(
            Date(timeIntervalSince1970: 1_900_000_000)
        )
        let history = InMemoryUpdateCheckHistoryStore()
        let scheduler = ManualAutomaticUpdateCheckScheduler()
        let controller = AppUpdateController(
            configuration: fixture.configuration,
            currentVersion: "0.1.0",
            currentBuild: 1,
            checkerFactory: { _ in checkerSequence.next() },
            currentDate: { now.value },
            checkHistoryStore: history,
            automaticCheckScheduler: scheduler
        )

        controller.start(automaticChecksEnabled: true)
        await waitForCheckToFinish(controller)
        XCTAssertEqual(
            controller.state,
            .available(fixture.metadata)
        )

        now.value = now.value.addingTimeInterval(
            AppUpdateController.defaultAutomaticCheckInterval
        )
        scheduler.fire()
        await waitForCheckToFinish(controller)

        XCTAssertEqual(
            controller.state,
            .available(fixture.metadata)
        )
        XCTAssertEqual(
            history.lastSuccessfulAutomaticCheckOutcome,
            .updateAvailable
        )
    }

    func testVerificationFailureSurfacesWithoutFeedContents() async {
        let configuration = SignedUpdateConfiguration(
            feedURL: URL(
                string: "https://updates.example.com/feed.json"
            ),
            publicKey: .ed25519(rawRepresentation: Data([1]))
        )
        let controller = AppUpdateController(
            configuration: configuration,
            checkerFactory: { _ in
                FailingUpdateChecker(error: .invalidSignature)
            }
        )

        controller.checkManually(automaticChecksEnabled: false)
        await waitForCheckToFinish(controller)

        XCTAssertEqual(
            controller.state,
            .failed(
                SignedUpdateCheckError.invalidSignature.errorDescription!
            )
        )
    }

    func testTerminationDiscardsStagingWithoutInstallerHandoff()
        async throws
    {
        let fixture = try await makeVerifiedUpdateFixture()
        let stager = RecordingUpdateStager()
        let controller = AppUpdateController(
            configuration: fixture.configuration,
            currentVersion: "0.1.0",
            currentBuild: 1,
            checkerFactory: { _ in
                ImmediateUpdateChecker(
                    result: .verified(fixture.metadata)
                )
            },
            stagerFactory: { _ in stager }
        )

        controller.checkManually(automaticChecksEnabled: false)
        await waitForCheckToFinish(controller)
        XCTAssertEqual(controller.state, .available(fixture.metadata))

        controller.stageAvailableUpdate()
        await waitForStagingToFinish(controller)
        guard case .staged = controller.state else {
            return XCTFail("Expected a verified staged update")
        }

        controller.prepareForTermination()

        XCTAssertEqual(stager.discardCount, 1)
        XCTAssertEqual(controller.state, .available(fixture.metadata))
    }

    func testIncompatibleUpdateIsNotOfferedForDownload() async throws {
        let fixture = try await makeVerifiedUpdateFixture(
            minimumSystemVersion: "15.1"
        )
        let controller = AppUpdateController(
            configuration: fixture.configuration,
            currentVersion: "0.1.0",
            currentBuild: 1,
            currentSystemVersion: try XCTUnwrap(
                UpdateSystemVersion("15.0")
            ),
            checkerFactory: { _ in
                ImmediateUpdateChecker(
                    result: .verified(fixture.metadata)
                )
            }
        )

        controller.checkManually(automaticChecksEnabled: false)
        await waitForCheckToFinish(controller)

        XCTAssertEqual(
            controller.state,
            .incompatible(
                metadata: fixture.metadata,
                requiredSystemVersion: "15.1"
            )
        )
        XCTAssertNil(controller.availableMetadata)
        controller.stageAvailableUpdate()
        XCTAssertFalse(controller.isStaging)
    }

    func testCanceledCheckCannotClobberNewerCheckOrClearItsTask()
        async throws
    {
        let fixture = try await makeVerifiedUpdateFixture()
        let firstChecker = SuspendedUpdateChecker()
        let secondChecker = SuspendedUpdateChecker()
        let checkerSequence = UpdateCheckerSequence(
            [firstChecker, secondChecker]
        )
        let controller = AppUpdateController(
            configuration: fixture.configuration,
            currentVersion: "0.1.0",
            currentBuild: 1,
            checkerFactory: { _ in checkerSequence.next() }
        )

        controller.checkManually(automaticChecksEnabled: false)
        await firstChecker.waitUntilStarted()
        controller.checkManually(automaticChecksEnabled: false)
        await secondChecker.waitUntilStarted()

        await firstChecker.finish(with: .verified(fixture.metadata))
        await firstChecker.waitUntilReturned()
        await drainMainActor()

        XCTAssertEqual(controller.state, .checking)

        controller.cancelCurrentOperation()
        XCTAssertEqual(controller.state, .idle)
        await secondChecker.finish(with: .verified(fixture.metadata))
        await secondChecker.waitUntilReturned()
        await drainMainActor()

        XCTAssertEqual(controller.state, .idle)
    }

    func testCanceledStagingCannotOverwriteNewerCheckState()
        async throws
    {
        let fixture = try await makeVerifiedUpdateFixture()
        let pendingChecker = SuspendedUpdateChecker()
        let checkerSequence = UpdateCheckerSequence(
            [
                ImmediateUpdateChecker(
                    result: .verified(fixture.metadata)
                ),
                pendingChecker,
            ]
        )
        let stagedUpdate = makeStagedUpdate(
            metadata: fixture.metadata,
            suffix: "stage-check"
        )
        let stager = SuspendedUpdateStager(stagedUpdate: stagedUpdate)
        let controller = AppUpdateController(
            configuration: fixture.configuration,
            currentVersion: "0.1.0",
            currentBuild: 1,
            checkerFactory: { _ in checkerSequence.next() },
            stagerFactory: { _ in stager }
        )

        controller.checkManually(automaticChecksEnabled: false)
        await waitForCheckToFinish(controller)
        controller.stageAvailableUpdate()
        await stager.waitUntilStageStarted()

        controller.checkManually(automaticChecksEnabled: false)
        await pendingChecker.waitUntilStarted()
        await stager.finishStage()
        await stager.waitUntilStageReturned()
        await drainMainActor()

        XCTAssertEqual(controller.state, .checking)
        XCTAssertEqual(stager.discardCount, 1)

        await pendingChecker.finish(with: .verified(fixture.metadata))
        await pendingChecker.waitUntilReturned()
        await waitForCheckToFinish(controller)
        XCTAssertEqual(controller.state, .available(fixture.metadata))
    }

    func testCanceledStagingCannotClearNewerStagerOrTaskHandles()
        async throws
    {
        let fixture = try await makeVerifiedUpdateFixture()
        let firstStager = SuspendedUpdateStager(
            stagedUpdate: makeStagedUpdate(
                metadata: fixture.metadata,
                suffix: "first-stage"
            )
        )
        let secondStagedUpdate = makeStagedUpdate(
            metadata: fixture.metadata,
            suffix: "second-stage"
        )
        let secondStager = SuspendedUpdateStager(
            stagedUpdate: secondStagedUpdate
        )
        let stagerSequence = UpdateStagerSequence(
            [firstStager, secondStager]
        )
        let controller = AppUpdateController(
            configuration: fixture.configuration,
            currentVersion: "0.1.0",
            currentBuild: 1,
            checkerFactory: { _ in
                ImmediateUpdateChecker(
                    result: .verified(fixture.metadata)
                )
            },
            stagerFactory: { _ in stagerSequence.next() }
        )

        controller.checkManually(automaticChecksEnabled: false)
        await waitForCheckToFinish(controller)
        controller.stageAvailableUpdate()
        await firstStager.waitUntilStageStarted()

        controller.checkManually(automaticChecksEnabled: false)
        await waitForCheckToFinish(controller)
        controller.stageAvailableUpdate()
        await secondStager.waitUntilStageStarted()

        await firstStager.finishStage()
        await firstStager.waitUntilStageReturned()
        await drainMainActor()

        XCTAssertEqual(controller.state, .staging(fixture.metadata))
        XCTAssertEqual(firstStager.discardCount, 1)

        await secondStager.finishStage()
        await secondStager.waitUntilStageReturned()
        await waitForStagingToFinish(controller)
        guard case .staged = controller.state else {
            return XCTFail("Expected the newer staged update to win")
        }

        let plan = await controller.revalidateInstallation()
        XCTAssertEqual(
            plan,
            try secondStagedUpdate.installationPlan
        )
    }

    func testCanceledRevalidationCannotRestoreOrFailDiscardedState()
        async throws
    {
        let fixture = try await makeVerifiedUpdateFixture()
        for failsRevalidation in [false, true] {
            let outcome = failsRevalidation ? "failure" : "success"
            let stagedUpdate = makeStagedUpdate(
                metadata: fixture.metadata,
                suffix: "revalidation-\(outcome)"
            )
            let stager = BlockingRevalidationStager(
                stagedUpdate: stagedUpdate,
                failsRevalidation: failsRevalidation
            )
            let controller = AppUpdateController(
                configuration: fixture.configuration,
                currentVersion: "0.1.0",
                currentBuild: 1,
                checkerFactory: { _ in
                    ImmediateUpdateChecker(
                        result: .verified(fixture.metadata)
                    )
                },
                stagerFactory: { _ in stager }
            )

            controller.checkManually(automaticChecksEnabled: false)
            await waitForCheckToFinish(controller)
            controller.stageAvailableUpdate()
            await waitForStagingToFinish(controller)

            let revalidationTask = Task { @MainActor in
                await controller.revalidateInstallation()
            }
            await stager.waitUntilRevalidationStarted()

            let expectedState: AppUpdateState
            if failsRevalidation {
                controller.checkManually(
                    automaticChecksEnabled: false
                )
                await waitForCheckToFinish(controller)
                expectedState = .available(fixture.metadata)
            } else {
                controller.cancelCurrentOperation()
                expectedState = .available(fixture.metadata)
            }
            XCTAssertEqual(
                controller.state,
                expectedState,
                "Invalidated late \(outcome)"
            )
            stager.finishRevalidation()

            let plan = await revalidationTask.value
            XCTAssertNil(plan, "Invalidated late \(outcome)")
            XCTAssertEqual(
                controller.state,
                expectedState,
                "Invalidated late \(outcome)"
            )
            XCTAssertEqual(
                stager.discardCount,
                1,
                "Invalidated late \(outcome)"
            )
        }
    }

    func testInstallAndRelaunchRevalidatesThenStartsVerifiedCandidate()
        async throws {
        let fixture = try await makeVerifiedUpdateFixture()
        let stager = RecordingUpdateStager()
        let launcher = RecordingNativeInstallerLauncher(
            availability: .available
        )
        let controller = AppUpdateController(
            configuration: fixture.configuration,
            currentVersion: "0.1.0",
            currentBuild: 1,
            checkerFactory: { _ in
                ImmediateUpdateChecker(
                    result: .verified(fixture.metadata)
                )
            },
            stagerFactory: { _ in stager },
            nativeInstallerLauncher: launcher
        )
        controller.checkManually(automaticChecksEnabled: false)
        await waitForCheckToFinish(controller)
        controller.stageAvailableUpdate()
        await waitForStagingToFinish(controller)

        let didLaunch = await controller.installAndRelaunch()
        XCTAssertTrue(didLaunch)
        XCTAssertEqual(launcher.launchCount, 1)
        XCTAssertEqual(
            launcher.lastContext?.assetSHA256,
            fixture.metadata.assetSHA256
        )
        XCTAssertEqual(
            controller.state,
            .launchingInstaller(fixture.metadata)
        )

        controller.prepareForTermination()
        XCTAssertEqual(stager.discardCount, 0)
    }

    func testUnwritableDestinationKeepsHonestManualInstallHandoff()
        async throws {
        let fixture = try await makeVerifiedUpdateFixture()
        let stager = RecordingUpdateStager()
        let reason = "The destination folder is not writable."
        let launcher = RecordingNativeInstallerLauncher(
            availability: .manualInstallRequired(reason)
        )
        let controller = AppUpdateController(
            configuration: fixture.configuration,
            currentVersion: "0.1.0",
            currentBuild: 1,
            checkerFactory: { _ in
                ImmediateUpdateChecker(
                    result: .verified(fixture.metadata)
                )
            },
            stagerFactory: { _ in stager },
            nativeInstallerLauncher: launcher
        )
        controller.checkManually(automaticChecksEnabled: false)
        await waitForCheckToFinish(controller)
        controller.stageAvailableUpdate()
        await waitForStagingToFinish(controller)

        let didLaunch = await controller.installAndRelaunch()
        XCTAssertFalse(didLaunch)
        XCTAssertEqual(launcher.launchCount, 0)
        XCTAssertEqual(controller.installationStatusMessage, reason)
        guard case .staged = controller.state else {
            return XCTFail("Manual handoff must remain available.")
        }
    }

    private func waitForCheckToFinish(
        _ controller: AppUpdateController
    ) async {
        for _ in 0..<100 where controller.isChecking {
            await Task.yield()
        }
    }

    private func waitForStagingToFinish(
        _ controller: AppUpdateController
    ) async {
        for _ in 0..<100 where controller.isStaging {
            await Task.yield()
        }
    }

    private func drainMainActor() async {
        for _ in 0..<100 {
            await Task.yield()
        }
    }

    private func makeStagedUpdate(
        metadata: VerifiedUpdateMetadata,
        suffix: String
    ) -> VerifiedStagedUpdate {
        let stagingDirectoryURL = URL(
            fileURLWithPath: "/private/tmp/.mojipond-\(suffix)"
        )
        let applicationURL = stagingDirectoryURL
            .appendingPathComponent("MojiPond.app")
        let plan = VerifiedUpdateInstallationPlan(
            stagedApplicationURL: applicationURL,
            destinationApplicationURL: URL(
                fileURLWithPath: "/Applications/MojiPond.app"
            ),
            relaunchBundleIdentifier: "com.rajjoshi.MojiPond"
        )
        let identity = UpdateCodeSignatureIdentity(
            bundleIdentifier: "com.rajjoshi.MojiPond",
            teamIdentifier: "ABCDEFGHIJ",
            certificateCommonName:
                "Developer ID Application: MojiPond (ABCDEFGHIJ)",
            hasSecureTimestamp: true,
            usesHardenedRuntime: true,
            isDeveloperIDApplication: true,
            isGatekeeperAccepted: true
        )
        return VerifiedStagedUpdate(
            metadata: metadata,
            applicationURL: applicationURL,
            stagingDirectoryURL: stagingDirectoryURL,
            archiveURL: stagingDirectoryURL
                .appendingPathComponent("update.zip"),
            currentIdentity: identity,
            updateIdentity: identity,
            installationState: .ready(plan)
        )
    }

    private func makeVerifiedUpdateFixture(
        minimumSystemVersion: String? = "14.0",
        version: String = "0.2.0",
        build: Int = 2
    ) async throws -> (
        configuration: SignedUpdateConfiguration,
        metadata: VerifiedUpdateMetadata
    ) {
        let feedURL = try XCTUnwrap(
            URL(string: "https://updates.example.com/feed.json")
        )
        let privateKey = Curve25519.Signing.PrivateKey()
        let payload = UpdateControllerPayloadFixture(
            schemaVersion: 1,
            version: version,
            build: build,
            publishedAt: Date(timeIntervalSince1970: 1_800_000_000),
            minimumSystemVersion: minimumSystemVersion,
            downloadURL: try XCTUnwrap(
                URL(string: "https://updates.example.com/MojiPond.zip")
            ),
            releaseNotesURL: nil,
            assetSHA256: String(repeating: "a", count: 64),
            assetByteCount: 1_024
        )
        let payloadEncoder = JSONEncoder()
        payloadEncoder.outputFormatting = [.sortedKeys]
        payloadEncoder.dateEncodingStrategy = .iso8601
        let payloadData = try payloadEncoder.encode(payload)
        let envelope = UpdateControllerEnvelopeFixture(
            schemaVersion: 1,
            algorithm: .ed25519,
            payload: payloadData.base64EncodedString(),
            signature: try privateKey.signature(
                for: payloadData
            ).base64EncodedString()
        )
        let envelopeEncoder = JSONEncoder()
        envelopeEncoder.outputFormatting = [.sortedKeys]
        let response = UpdateFeedResponse(
            data: try envelopeEncoder.encode(envelope),
            finalURL: feedURL
        )
        let configuration = SignedUpdateConfiguration(
            feedURL: feedURL,
            publicKey: .ed25519(
                rawRepresentation: privateKey.publicKey.rawRepresentation
            )
        )
        let result = try await SignedUpdateChecker(
            configuration: configuration,
            fetcher: ControllerUpdateFeedFetcher(response: response)
        ).check(for: .manual)
        guard case let .verified(metadata) = result else {
            throw XCTSkip("Could not construct verified update metadata")
        }
        return (configuration, metadata)
    }
}

private struct FailingUpdateChecker: SignedUpdateChecking {
    let error: SignedUpdateCheckError

    func check(
        for kind: UpdateCheckKind
    ) async throws -> SignedUpdateCheckResult {
        _ = kind
        throw error
    }
}

private struct ImmediateUpdateChecker: SignedUpdateChecking {
    let result: SignedUpdateCheckResult

    func check(
        for kind: UpdateCheckKind
    ) async throws -> SignedUpdateCheckResult {
        _ = kind
        return result
    }
}

private actor SuspendedUpdateChecker: SignedUpdateChecking {
    private var continuation:
        CheckedContinuation<SignedUpdateCheckResult, Never>?
    private var started = false
    private var returned = false

    func check(
        for kind: UpdateCheckKind
    ) async throws -> SignedUpdateCheckResult {
        _ = kind
        started = true
        let result = await withCheckedContinuation {
            continuation = $0
        }
        returned = true
        return result
    }

    func waitUntilStarted() async {
        while !started {
            await Task.yield()
        }
    }

    func finish(with result: SignedUpdateCheckResult) {
        continuation?.resume(returning: result)
        continuation = nil
    }

    func waitUntilReturned() async {
        while !returned {
            await Task.yield()
        }
    }
}

private final class UpdateCheckerSequence: @unchecked Sendable {
    private let lock = NSLock()
    private let checkers: [any SignedUpdateChecking]
    private var index = 0

    init(_ checkers: [any SignedUpdateChecking]) {
        self.checkers = checkers
    }

    func next() -> any SignedUpdateChecking {
        lock.withLock {
            precondition(index < checkers.count)
            defer {
                index += 1
            }
            return checkers[index]
        }
    }
}

private final class MutableUpdateCheckDate {
    var value: Date

    init(_ value: Date) {
        self.value = value
    }
}

private final class InMemoryUpdateCheckHistoryStore:
    UpdateCheckHistoryStoring
{
    var lastAutomaticCheckDate: Date?
    var lastSuccessfulAutomaticCheckOutcome:
        SuccessfulUpdateCheckOutcome?
}

@MainActor
private final class ManualAutomaticUpdateCheckScheduler:
    AutomaticUpdateCheckScheduling
{
    private var action: (@MainActor @Sendable () -> Void)?
    private(set) var scheduledDelay: TimeInterval?

    var hasScheduledAction: Bool {
        action != nil
    }

    func schedule(
        after delay: TimeInterval,
        action: @escaping @MainActor @Sendable () -> Void
    ) {
        scheduledDelay = delay
        self.action = action
    }

    func cancel() {
        scheduledDelay = nil
        action = nil
    }

    func fire() {
        let scheduledAction = action
        action = nil
        scheduledDelay = nil
        scheduledAction?()
    }
}

private actor SuspendedStage {
    private let stagedUpdate: VerifiedStagedUpdate
    private var continuation:
        CheckedContinuation<VerifiedStagedUpdate, Never>?
    private var started = false
    private var returned = false

    init(stagedUpdate: VerifiedStagedUpdate) {
        self.stagedUpdate = stagedUpdate
    }

    func run() async -> VerifiedStagedUpdate {
        started = true
        let stagedUpdate = await withCheckedContinuation {
            continuation = $0
        }
        returned = true
        return stagedUpdate
    }

    func waitUntilStarted() async {
        while !started {
            await Task.yield()
        }
    }

    func finish() {
        continuation?.resume(returning: stagedUpdate)
        continuation = nil
    }

    func waitUntilReturned() async {
        while !returned {
            await Task.yield()
        }
    }
}

private final class SuspendedUpdateStager:
    VerifiedUpdateStaging,
    @unchecked Sendable
{
    private let stage: SuspendedStage
    private let lock = NSLock()
    private var recordedDiscardCount = 0

    init(stagedUpdate: VerifiedStagedUpdate) {
        stage = SuspendedStage(stagedUpdate: stagedUpdate)
    }

    var discardCount: Int {
        lock.withLock { recordedDiscardCount }
    }

    func stage(
        metadata: VerifiedUpdateMetadata
    ) async throws -> VerifiedStagedUpdate {
        _ = metadata
        return await stage.run()
    }

    func waitUntilStageStarted() async {
        await stage.waitUntilStarted()
    }

    func finishStage() async {
        await stage.finish()
    }

    func waitUntilStageReturned() async {
        await stage.waitUntilReturned()
    }

    func revalidateForInstallation(
        _ stagedUpdate: VerifiedStagedUpdate
    ) throws -> VerifiedUpdateInstallationPlan {
        try stagedUpdate.installationPlan
    }

    func discard(_ stagedUpdate: VerifiedStagedUpdate) throws {
        _ = stagedUpdate
        lock.withLock {
            recordedDiscardCount += 1
        }
    }
}

private final class UpdateStagerSequence: @unchecked Sendable {
    private let lock = NSLock()
    private let stagers: [any VerifiedUpdateStaging]
    private var index = 0

    init(_ stagers: [any VerifiedUpdateStaging]) {
        self.stagers = stagers
    }

    func next() -> any VerifiedUpdateStaging {
        lock.withLock {
            precondition(index < stagers.count)
            defer {
                index += 1
            }
            return stagers[index]
        }
    }
}

private final class BlockingRevalidationStager:
    VerifiedUpdateStaging,
    @unchecked Sendable
{
    private let stagedUpdate: VerifiedStagedUpdate
    private let failsRevalidation: Bool
    private let releaseRevalidation = DispatchSemaphore(value: 0)
    private let lock = NSLock()
    private var revalidationStarted = false
    private var revalidationWaiter: CheckedContinuation<Void, Never>?
    private var recordedDiscardCount = 0

    init(
        stagedUpdate: VerifiedStagedUpdate,
        failsRevalidation: Bool
    ) {
        self.stagedUpdate = stagedUpdate
        self.failsRevalidation = failsRevalidation
    }

    var discardCount: Int {
        lock.withLock { recordedDiscardCount }
    }

    func stage(
        metadata: VerifiedUpdateMetadata
    ) async throws -> VerifiedStagedUpdate {
        _ = metadata
        return stagedUpdate
    }

    func revalidateForInstallation(
        _ stagedUpdate: VerifiedStagedUpdate
    ) throws -> VerifiedUpdateInstallationPlan {
        lock.withLock {
            revalidationStarted = true
            revalidationWaiter?.resume()
            revalidationWaiter = nil
        }
        releaseRevalidation.wait()
        if failsRevalidation {
            throw RevalidationFixtureError.failed
        }
        return try stagedUpdate.installationPlan
    }

    func waitUntilRevalidationStarted() async {
        let alreadyStarted = lock.withLock {
            revalidationStarted
        }
        if alreadyStarted {
            return
        }
        await withCheckedContinuation { continuation in
            lock.withLock {
                if revalidationStarted {
                    continuation.resume()
                } else {
                    revalidationWaiter = continuation
                }
            }
        }
    }

    func finishRevalidation() {
        releaseRevalidation.signal()
    }

    func discard(_ stagedUpdate: VerifiedStagedUpdate) throws {
        _ = stagedUpdate
        lock.withLock {
            recordedDiscardCount += 1
        }
    }
}

private enum RevalidationFixtureError: LocalizedError {
    case failed

    var errorDescription: String? {
        "Fixture revalidation failed."
    }
}

private final class RecordingUpdateStager:
    VerifiedUpdateStaging,
    @unchecked Sendable
{
    private let lock = NSLock()
    private var recordedDiscardCount = 0

    var discardCount: Int {
        lock.withLock { recordedDiscardCount }
    }

    func stage(
        metadata: VerifiedUpdateMetadata
    ) async throws -> VerifiedStagedUpdate {
        let applicationURL = URL(
            fileURLWithPath: "/private/tmp/MojiPond.app"
        )
        let plan = VerifiedUpdateInstallationPlan(
            stagedApplicationURL: applicationURL,
            destinationApplicationURL: URL(
                fileURLWithPath: "/Applications/MojiPond.app"
            ),
            relaunchBundleIdentifier: "com.rajjoshi.MojiPond"
        )
        let identity = UpdateCodeSignatureIdentity(
            bundleIdentifier: "com.rajjoshi.MojiPond",
            teamIdentifier: "ABCDEFGHIJ",
            certificateCommonName:
                "Developer ID Application: MojiPond (ABCDEFGHIJ)",
            hasSecureTimestamp: true,
            usesHardenedRuntime: true,
            isDeveloperIDApplication: true,
            isGatekeeperAccepted: true
        )
        return VerifiedStagedUpdate(
            metadata: metadata,
            applicationURL: applicationURL,
            stagingDirectoryURL: URL(
                fileURLWithPath: "/private/tmp/.mojipond-update-test"
            ),
            archiveURL: URL(
                fileURLWithPath:
                    "/private/tmp/.mojipond-update-test/update.zip"
            ),
            currentIdentity: identity,
            updateIdentity: identity,
            installationState: .ready(plan)
        )
    }

    func revalidateForInstallation(
        _ stagedUpdate: VerifiedStagedUpdate
    ) throws -> VerifiedUpdateInstallationPlan {
        guard case let .ready(plan) =
            stagedUpdate.installationState else {
            throw CancellationError()
        }
        return plan
    }

    func discard(_ stagedUpdate: VerifiedStagedUpdate) throws {
        _ = stagedUpdate
        lock.withLock {
            recordedDiscardCount += 1
        }
    }
}

private final class RecordingNativeInstallerLauncher:
    NativeUpdateInstallerLaunching,
    @unchecked Sendable
{
    let availabilityResult: NativeUpdateInstallAvailability
    private let lock = NSLock()
    private var recordedContexts: [NativeUpdateInstallerLaunchContext] = []

    init(availability: NativeUpdateInstallAvailability) {
        availabilityResult = availability
    }

    var launchCount: Int {
        lock.withLock { recordedContexts.count }
    }

    var lastContext: NativeUpdateInstallerLaunchContext? {
        lock.withLock { recordedContexts.last }
    }

    func availability(
        for context: NativeUpdateInstallerLaunchContext
    ) -> NativeUpdateInstallAvailability {
        _ = context
        return availabilityResult
    }

    func launchInstaller(
        for context: NativeUpdateInstallerLaunchContext
    ) throws {
        lock.withLock {
            recordedContexts.append(context)
        }
    }
}

private struct ControllerUpdateFeedFetcher: UpdateFeedFetching {
    let response: UpdateFeedResponse

    func fetchUpdateFeed(
        from url: URL,
        maximumBytes: Int
    ) async throws -> UpdateFeedResponse {
        _ = url
        _ = maximumBytes
        return response
    }
}

private struct UpdateControllerPayloadFixture: Encodable {
    let schemaVersion: Int
    let version: String
    let build: Int
    let publishedAt: Date
    let minimumSystemVersion: String?
    let downloadURL: URL
    let releaseNotesURL: URL?
    let assetSHA256: String
    let assetByteCount: Int64
}

private struct UpdateControllerEnvelopeFixture: Encodable {
    let schemaVersion: Int
    let algorithm: UpdateSignatureAlgorithm
    let payload: String
    let signature: String
}

private extension VerifiedStagedUpdate {
    var installationPlan: VerifiedUpdateInstallationPlan {
        get throws {
            guard case let .ready(plan) =
                installationState else {
                throw CancellationError()
            }
            return plan
        }
    }
}
