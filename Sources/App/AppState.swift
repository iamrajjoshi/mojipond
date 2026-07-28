import AppKit
import Combine
import ServiceManagement

@MainActor
final class AppState: ObservableObject {
    private enum Key {
        static let isEnabled = "app.isEnabled"
        static let completedOnboarding = "onboarding.completed"
    }

    let permissions: SystemPermissionCenter

    @Published var isEnabled: Bool {
        didSet {
            UserDefaults.standard.set(isEnabled, forKey: Key.isEnabled)
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

    init(permissions: SystemPermissionCenter = SystemPermissionCenter()) {
        self.permissions = permissions
        isEnabled = UserDefaults.standard.object(forKey: Key.isEnabled) as? Bool ?? true
        hasCompletedOnboarding = UserDefaults.standard.bool(
            forKey: Key.completedOnboarding
        )
        launchAtLoginEnabled = SMAppService.mainApp.status == .enabled
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
        guard canMonitorTyping else {
            return "Permissions needed"
        }
        return "Ready"
    }

    func start() {
        permissions.startLiveUpdates()
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
        } catch {
            launchAtLoginEnabled = SMAppService.mainApp.status == .enabled
            launchAtLoginError = error.localizedDescription
        }
    }
}

