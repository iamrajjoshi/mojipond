import XCTest
@testable import MojiPond

@MainActor
final class AppStateTests: XCTestCase {
    func testEnableAndPreferenceChangesPersistOneDocument() {
        let store = PreferencesStoreSpy(initial: .defaults)
        let state = AppState(preferencesStore: store)

        state.setEnabled(false)
        state.updatePreferences {
            $0.shortcode.trigger = .pipe
            $0.network.allowsStickerSearch = true
        }

        XCTAssertFalse(state.isEnabled)
        XCTAssertEqual(state.preferences.shortcode.trigger, .pipe)
        XCTAssertTrue(state.preferences.network.allowsStickerSearch)
        XCTAssertEqual(store.saved.last, state.preferences)
    }

    func testStatusFollowsPermissionsAndRuntimeLifecycle() {
        let provider = AppStatePermissionProvider()
        let history = AppStatePermissionHistory()
        let permissions = SystemPermissionCenter(
            provider: provider,
            history: history
        )
        let state = AppState(
            permissions: permissions,
            preferencesStore: PreferencesStoreSpy(initial: .defaults)
        )

        state.setRuntimeState(.waitingForPermissions)
        XCTAssertEqual(state.statusSummary, "Permissions needed")

        provider.granted = [.inputMonitoring, .accessibility]
        permissions.refresh()
        state.setRuntimeState(.running)
        XCTAssertEqual(state.statusSummary, "Ready")

        state.setRuntimeState(
            .contextSuspended(
                .excludedApplication("com.example.private")
            )
        )
        XCTAssertEqual(state.statusSummary, "Excluded here")

        state.setRuntimeState(.contextSuspended(.secureField))
        XCTAssertEqual(state.statusSummary, "Secure field")

        state.setRuntimeState(.contextSuspended(.applicationUnknown))
        XCTAssertEqual(state.statusSummary, "Unverified app")

        state.setRuntimeState(.sessionLocked)
        XCTAssertEqual(state.statusSummary, "Locked")

        state.setEnabled(false)
        XCTAssertEqual(state.statusSummary, "Paused")
    }

    func testUpdatePreferenceStartsAndCancelsAutomaticCheck() {
        let configuration = SignedUpdateConfiguration(
            feedURL: URL(
                string: "https://updates.example.com/feed.json"
            ),
            publicKey: .ed25519(rawRepresentation: Data([1]))
        )
        let updates = AppUpdateController(
            configuration: configuration,
            checkerFactory: { _ in
                SuspendingAppStateUpdateChecker()
            },
            checkHistoryStore: AppStateUpdateCheckHistoryStore(),
            automaticCheckScheduler:
                AppStateAutomaticUpdateCheckScheduler()
        )
        let state = AppState(
            preferencesStore: PreferencesStoreSpy(initial: .defaults),
            updates: updates
        )

        state.updatePreferences {
            $0.network.allowsUpdateChecks = true
        }
        XCTAssertEqual(updates.state, .checking)

        state.updatePreferences {
            $0.network.allowsUpdateChecks = false
        }
        XCTAssertEqual(updates.state, .idle)
    }

    func testLaunchAtLoginUsesInjectedController() {
        let controller = LaunchAtLoginControllerStub()
        let state = AppState(
            preferencesStore: PreferencesStoreSpy(initial: .defaults),
            launchAtLoginController: controller
        )

        XCTAssertFalse(state.launchAtLoginEnabled)

        state.setLaunchAtLogin(true)

        XCTAssertTrue(controller.isEnabled)
        XCTAssertTrue(state.launchAtLoginEnabled)
        XCTAssertTrue(state.preferences.launchAtLogin)
        XCTAssertNil(state.launchAtLoginError)
    }

    func testUsageResetWithoutConfiguredStoreReportsFailure() {
        let delegate = AppDelegate()

        delegate.resetUsageRanking()

        XCTAssertEqual(
            delegate.appState.runtimeNotice,
            UsageRankingResetNotice.failure
        )
    }
}

private final class AppStateUpdateCheckHistoryStore:
    UpdateCheckHistoryStoring
{
    var lastAutomaticCheckDate: Date?
    var lastSuccessfulAutomaticCheckOutcome:
        SuccessfulUpdateCheckOutcome?
}

@MainActor
private final class AppStateAutomaticUpdateCheckScheduler:
    AutomaticUpdateCheckScheduling
{
    func schedule(
        after delay: TimeInterval,
        action: @escaping @MainActor @Sendable () -> Void
    ) {
        _ = delay
        _ = action
    }

    func cancel() {}
}

private struct SuspendingAppStateUpdateChecker: SignedUpdateChecking {
    func check(
        for kind: UpdateCheckKind
    ) async throws -> SignedUpdateCheckResult {
        _ = kind
        try await Task.sleep(for: .seconds(30))
        throw CancellationError()
    }
}

private final class PreferencesStoreSpy: PreferencesPersisting {
    let initial: MojiPondPreferences
    private(set) var saved: [MojiPondPreferences] = []

    init(initial: MojiPondPreferences) {
        self.initial = initial
    }

    func load() -> MojiPondPreferences {
        initial
    }

    func save(_ preferences: MojiPondPreferences) {
        saved.append(preferences)
    }
}

private final class AppStatePermissionProvider: SystemPermissionProviding {
    var granted = Set<SystemPermission>()

    func isGranted(_ permission: SystemPermission) -> Bool {
        granted.contains(permission)
    }

    func request(_ permission: SystemPermission) -> Bool {
        granted.contains(permission)
    }
}

private final class AppStatePermissionHistory: PermissionHistoryStoring {
    private var requested = Set<SystemPermission>()
    private var granted = Set<SystemPermission>()

    func hasRequested(_ permission: SystemPermission) -> Bool {
        requested.contains(permission)
    }

    func wasEverGranted(_ permission: SystemPermission) -> Bool {
        granted.contains(permission)
    }

    func setRequested(_ requested: Bool, for permission: SystemPermission) {
        if requested {
            self.requested.insert(permission)
        } else {
            self.requested.remove(permission)
        }
    }

    func setEverGranted(_ granted: Bool, for permission: SystemPermission) {
        if granted {
            self.granted.insert(permission)
        } else {
            self.granted.remove(permission)
        }
    }
}

private final class LaunchAtLoginControllerStub:
    LaunchAtLoginControlling
{
    var isEnabled = false

    func setEnabled(_ enabled: Bool) throws {
        isEnabled = enabled
    }
}
