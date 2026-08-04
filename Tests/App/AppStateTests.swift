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
            $0.network.allowsCrashReports = false
        }

        XCTAssertFalse(state.isEnabled)
        XCTAssertEqual(state.preferences.shortcode.trigger, .pipe)
        XCTAssertFalse(state.preferences.network.allowsCrashReports)
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
        XCTAssertEqual(state.statusSummary, "Disabled")
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
            delegate.appState.usageRankingResetNotice,
            UsageRankingResetNotice.failure
        )
    }

    func testStatusMenuRoutesSettingsDirectlyToAppDelegate() throws {
        let delegate = AppDelegate()
        let menu = delegate.makeStatusMenu()
        let activationItem = try XCTUnwrap(menu.items.first)
        let libraryItem = try XCTUnwrap(
            menu.items.first(where: { $0.title == "Emoji Library" })
        )
        let onboardingItem = menu.items.first(
            where: { $0.title == "Finish Setup…" }
        )
        let settingsItem = try XCTUnwrap(
            menu.items.first(where: { $0.title == "Settings…" })
        )
        let quitItem = try XCTUnwrap(
            menu.items.first(where: { $0.title == "Quit MojiPond" })
        )

        XCTAssertEqual(
            activationItem.title,
            delegate.appState.isEnabled
                ? "Disable MojiPond"
                : "Enable MojiPond"
        )
        XCTAssertEqual(activationItem.state, .off)
        XCTAssertTrue(activationItem.target === delegate)
        XCTAssertTrue(libraryItem.target === delegate)
        XCTAssertEqual(libraryItem.keyEquivalent, "")
        if let onboardingItem {
            XCTAssertTrue(onboardingItem.target === delegate)
        }
        XCTAssertTrue(settingsItem.target === delegate)
        XCTAssertEqual(settingsItem.keyEquivalent, ",")
        XCTAssertEqual(
            NSStringFromSelector(try XCTUnwrap(settingsItem.action)),
            "showSettings"
        )
        XCTAssertEqual(quitItem.keyEquivalent, "q")
        XCTAssertNil(
            menu.items.first(where: { $0.title == "Emoji Library…" })
        )
        XCTAssertNil(
            menu.items.first {
                $0.title == "Insert Emoji at Caret…"
            }
        )
        XCTAssertNil(
            menu.items.first {
                $0.title == "Setup & Permissions…"
            }
        )
        XCTAssertEqual(
            menu.items.contains { $0.title == "Finish Setup…" },
            !delegate.appState.hasCompletedOnboarding
        )
        XCTAssertNil(
            menu.items.first {
                $0.title == "Check for Updates…"
            }
        )
        XCTAssertNil(
            menu.items.first(where: { $0.title == "Ready" })
        )
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
