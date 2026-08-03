import AppKit
import Combine
import ServiceManagement

protocol LaunchAtLoginControlling {
    var isEnabled: Bool { get }

    func setEnabled(_ enabled: Bool) throws
}

struct SystemLaunchAtLoginController: LaunchAtLoginControlling {
    var isEnabled: Bool {
        SMAppService.mainApp.status == .enabled
    }

    func setEnabled(_ enabled: Bool) throws {
        if enabled {
            try SMAppService.mainApp.register()
        } else {
            try SMAppService.mainApp.unregister()
        }
    }
}

@MainActor
final class AppState: ObservableObject {
    private enum Key {
        static let completedOnboarding = "onboarding.completed"
    }

    let permissions: SystemPermissionCenter
    let updates: AppUpdateController
    private let preferencesStore: any PreferencesPersisting
    private let persistsOnboardingCompletion: Bool
    private let launchAtLoginController:
        any LaunchAtLoginControlling

    @Published var preferences: MojiPondPreferences {
        didSet {
            preferencesStore.save(preferences)
        }
    }

    @Published var hasCompletedOnboarding: Bool {
        didSet {
            guard persistsOnboardingCompletion else {
                return
            }
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
    @Published private(set) var runtimeDenialNotice: String?
    @Published private(set) var usageRankingResetNotice: String?

    init(
        permissions: SystemPermissionCenter = SystemPermissionCenter(),
        preferencesStore: any PreferencesPersisting =
            UserDefaultsPreferencesStore(),
        updates: AppUpdateController = AppUpdateController(),
        initialOnboardingCompletion: Bool? = nil,
        launchAtLoginController: any LaunchAtLoginControlling =
            SystemLaunchAtLoginController()
    ) {
        self.permissions = permissions
        self.preferencesStore = preferencesStore
        self.updates = updates
        self.launchAtLoginController = launchAtLoginController
        persistsOnboardingCompletion = initialOnboardingCompletion == nil
        preferences = preferencesStore.load()
        hasCompletedOnboarding = initialOnboardingCompletion
            ?? UserDefaults.standard.bool(forKey: Key.completedOnboarding)
        launchAtLoginEnabled = launchAtLoginController.isEnabled
    }

    var isEnabled: Bool {
        preferences.activationMode == .enabled
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
        case let .contextSuspended(denial):
            switch denial {
            case .excludedApplication, .excludedDomain:
                return "Excluded here"
            case .secureEventInput, .secureField, .secureStatusUnknown:
                return "Secure field"
            case .applicationUnknown:
                return "Unverified app"
            case .domainUnknown:
                return "Unverified site"
            case .permissionUnavailable:
                return "Permissions needed"
            }
        case .sessionLocked:
            return "Locked"
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
        updates.start()
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

    func setRuntimeDenialNotice(_ notice: String?) {
        runtimeDenialNotice = notice
    }

    func setUsageRankingResetNotice(_ notice: String?) {
        usageRankingResetNotice = notice
    }

    func finishOnboarding() {
        hasCompletedOnboarding = true
    }

    func setLaunchAtLogin(_ enabled: Bool) {
        do {
            try launchAtLoginController.setEnabled(enabled)
            launchAtLoginEnabled = launchAtLoginController.isEnabled
            launchAtLoginError = nil
            updatePreferences {
                $0.launchAtLogin = launchAtLoginEnabled
            }
        } catch {
            launchAtLoginEnabled = launchAtLoginController.isEnabled
            launchAtLoginError = error.localizedDescription
        }
    }
}
