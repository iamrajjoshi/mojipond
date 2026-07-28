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
            $0.network.allowsGitHubImports = true
        }

        XCTAssertFalse(state.isEnabled)
        XCTAssertEqual(state.preferences.shortcode.trigger, .pipe)
        XCTAssertTrue(state.preferences.network.allowsGitHubImports)
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

        state.setEnabled(false)
        XCTAssertEqual(state.statusSummary, "Paused")
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
