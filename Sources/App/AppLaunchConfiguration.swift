import Foundation

struct AppLaunchConfiguration: Equatable {
    enum InitialScreen: String {
        case onboarding
        case library
        case settings
        case importPreview = "import-preview"
        case suggestions
        case browser
    }

    enum UITestPermissionScenario: String {
        case notRequested = "not-requested"
        case denied
        case granted
        case revoked
    }

    static let uiTestingFlag = "--mojipond-ui-testing"
    static let uiTestScreenArgument = "--mojipond-ui-test-screen"
    static let uiTestPermissionArgument =
        "--mojipond-ui-test-permissions"
    static let openLibraryArgument = "--mojipond-open-library"

    enum InitialPresentation: Equatable {
        case onboarding
        case library
        case statusItemOnly
    }

    let isUITesting: Bool
    let initialScreen: InitialScreen?
    let uiTestPermissionScenario: UITestPermissionScenario
    let ephemeralRootURL: URL?
    let opensLibraryAtLaunch: Bool

    static var current: AppLaunchConfiguration {
        parse(
            arguments: ProcessInfo.processInfo.arguments,
            processIdentifier: ProcessInfo.processInfo.processIdentifier,
            temporaryDirectory: FileManager.default.temporaryDirectory
        )
    }

    static func parse(
        arguments: [String],
        processIdentifier: Int32,
        temporaryDirectory: URL
    ) -> AppLaunchConfiguration {
        guard arguments.contains(uiTestingFlag) else {
            return AppLaunchConfiguration(
                isUITesting: false,
                initialScreen: nil,
                uiTestPermissionScenario: .notRequested,
                ephemeralRootURL: nil,
                opensLibraryAtLaunch:
                    arguments.contains(openLibraryArgument)
            )
        }

        let requestedScreen = value(
            following: uiTestScreenArgument,
            in: arguments
        )
        let initialScreen = requestedScreen.flatMap(InitialScreen.init)
            ?? .onboarding
        let permissionScenario = value(
            following: uiTestPermissionArgument,
            in: arguments
        ).flatMap(UITestPermissionScenario.init)
            ?? .notRequested
        let ephemeralRootURL = temporaryDirectory
            .appendingPathComponent(
                "MojiPond-UI-Tests-\(processIdentifier)",
                isDirectory: true
            )

        return AppLaunchConfiguration(
            isUITesting: true,
            initialScreen: initialScreen,
            uiTestPermissionScenario: permissionScenario,
            ephemeralRootURL: ephemeralRootURL,
            opensLibraryAtLaunch: initialScreen == .library
        )
    }

    func initialPresentation(
        hasCompletedOnboarding: Bool
    ) -> InitialPresentation {
        if isUITesting {
            return initialScreen == .library
                ? .library
                : .onboarding
        }
        guard hasCompletedOnboarding else {
            return .onboarding
        }
        return opensLibraryAtLaunch ? .library : .statusItemOnly
    }

    @MainActor
    func makeAppState() -> AppState {
        guard isUITesting else {
            return AppState()
        }

        let permissions = SystemPermissionCenter(
            provider: UITestPermissionProvider(
                scenario: uiTestPermissionScenario
            ),
            history: UITestPermissionHistoryStore(
                scenario: uiTestPermissionScenario
            )
        )
        return AppState(
            permissions: permissions,
            preferencesStore: UITestPreferencesStore(),
            initialOnboardingCompletion:
                initialScreen != .onboarding,
            launchAtLoginController:
                UITestLaunchAtLoginController()
        )
    }

    private static func value(
        following argument: String,
        in arguments: [String]
    ) -> String? {
        guard let index = arguments.firstIndex(of: argument) else {
            return nil
        }
        let valueIndex = arguments.index(after: index)
        guard arguments.indices.contains(valueIndex) else {
            return nil
        }
        return arguments[valueIndex]
    }
}

private struct UITestLaunchAtLoginController:
    LaunchAtLoginControlling
{
    var isEnabled: Bool {
        false
    }

    func setEnabled(_ enabled: Bool) throws {
        _ = enabled
    }
}

private struct UITestPermissionProvider: SystemPermissionProviding {
    let scenario: AppLaunchConfiguration.UITestPermissionScenario

    func isGranted(_ permission: SystemPermission) -> Bool {
        _ = permission
        return scenario == .granted
    }

    func request(_ permission: SystemPermission) -> Bool {
        isGranted(permission)
    }
}

private final class UITestPermissionHistoryStore: PermissionHistoryStoring {
    private let scenario:
        AppLaunchConfiguration.UITestPermissionScenario

    init(
        scenario: AppLaunchConfiguration.UITestPermissionScenario
    ) {
        self.scenario = scenario
    }

    func hasRequested(_ permission: SystemPermission) -> Bool {
        _ = permission
        return scenario != .notRequested
    }

    func wasEverGranted(_ permission: SystemPermission) -> Bool {
        _ = permission
        return scenario == .granted || scenario == .revoked
    }

    func setRequested(
        _ requested: Bool,
        for permission: SystemPermission
    ) {}

    func setEverGranted(
        _ granted: Bool,
        for permission: SystemPermission
    ) {}
}

private struct UITestPreferencesStore: PreferencesPersisting {
    func load() -> MojiPondPreferences {
        .defaults
    }

    func save(_ preferences: MojiPondPreferences) {}
}
