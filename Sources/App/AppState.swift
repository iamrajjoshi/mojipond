import AppKit
import Combine
import ServiceManagement

@MainActor
final class AppState: ObservableObject {
    private enum Key {
        static let completedOnboarding = "onboarding.completed"
    }

    let permissions: SystemPermissionCenter
    private let preferencesStore: any PreferencesPersisting

    @Published var preferences: MojiPondPreferences {
        didSet {
            preferencesStore.save(preferences)
        }
    }

    @Published var hasCompletedOnboarding: Bool {
        didSet {
            UserDefaults.standard.set(
                hasCompletedOnboarding,
                forKey: Key.completedOnboarding
            )
        }
    }

    @Published private(set) var launchAtLoginEnabled: Bool
    @Published private(set) var launchAtLoginError: String?
    @Published private(set) var runtimeState: MojiPondRuntimeState = .stopped
    @Published private(set) var runtimeNotice: String?

    init(
        permissions: SystemPermissionCenter = SystemPermissionCenter(),
        preferencesStore: any PreferencesPersisting =
            UserDefaultsPreferencesStore()
    ) {
        self.permissions = permissions
        self.preferencesStore = preferencesStore
        preferences = preferencesStore.load()
        hasCompletedOnboarding = UserDefaults.standard.bool(
            forKey: Key.completedOnboarding
        )
        launchAtLoginEnabled = SMAppService.mainApp.status == .enabled
    }

    var isEnabled: Bool {
        preferences.activationMode == .enabled
    }

    var isInstalledInApplications: Bool {
        Bundle.main.bundleURL.path.hasPrefix("/Applications/")
    }

    var canMonitorTyping: Bool {
        permissions.snapshot.inputMonitoring == .granted
            && permissions.snapshot.accessibility == .granted
    }

    var statusSummary: String {
        guard isEnabled else {
            return "Paused"
        }
        if case .failed = runtimeState {
            return "Needs attention"
        }
        guard canMonitorTyping else {
            return "Permissions needed"
        }
        switch runtimeState {
        case .running:
            return "Ready"
        case .waitingForPermissions:
            return "Permissions needed"
        case .failed:
            return "Needs attention"
        case .paused:
            return "Paused"
        case .stopped:
            return "Starting…"
        }
    }

    func start() {
        permissions.startLiveUpdates()
    }

    func setEnabled(_ enabled: Bool) {
        preferences.activationMode = enabled ? .enabled : .paused
    }

    func updatePreferences(
        _ update: (inout MojiPondPreferences) -> Void
    ) {
        var candidate = preferences
        update(&candidate)
        preferences = candidate
    }

    func setRuntimeState(_ state: MojiPondRuntimeState) {
        runtimeState = state
    }

    func setRuntimeNotice(_ notice: String?) {
        runtimeNotice = notice
    }

    func finishOnboarding() {
        hasCompletedOnboarding = true
    }

    func setLaunchAtLogin(_ enabled: Bool) {
        do {
            if enabled {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
            launchAtLoginEnabled = SMAppService.mainApp.status == .enabled
            launchAtLoginError = nil
            updatePreferences {
                $0.launchAtLogin = launchAtLoginEnabled
            }
        } catch {
            launchAtLoginEnabled = SMAppService.mainApp.status == .enabled
            launchAtLoginError = error.localizedDescription
        }
    }
}
