import Foundation

struct AppLaunchConfiguration: Equatable {
    enum InitialScreen: String {
        case onboarding
        case library
        case libraryEmptyPack = "library-empty-pack"
        case settings
        case importPreview = "import-preview"
        case suggestions
        case browser
    }

    enum UITestPermissionScenario: String {
        case notRequested = "not-requested"
        case denied
        case granted
        case grantOnRequest = "grant-on-request"
        case revoked
    }

    enum UITestAppearance: String {
        case light
        case dark
    }

    enum UITestUpdateScenario: String {
        case unconfigured
        case configured
    }

    static let uiTestingFlag = "--mojipond-ui-testing"
    static let uiTestScreenArgument = "--mojipond-ui-test-screen"
    static let uiTestPermissionArgument =
        "--mojipond-ui-test-permissions"
    static let uiTestAppearanceArgument =
        "--mojipond-ui-test-appearance"
    static let uiTestUpdatesArgument =
        "--mojipond-ui-test-updates"
    static let openLibraryArgument = "--mojipond-open-library"

    enum InitialPresentation: Equatable {
        case onboarding
        case library
        case statusItemOnly
    }

    let isUITesting: Bool
    let initialScreen: InitialScreen?
    let uiTestPermissionScenario: UITestPermissionScenario
    let uiTestAppearance: UITestAppearance?
    let uiTestUpdateScenario: UITestUpdateScenario
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
                uiTestAppearance: nil,
                uiTestUpdateScenario: .unconfigured,
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
        let appearance = value(
            following: uiTestAppearanceArgument,
            in: arguments
        ).flatMap(UITestAppearance.init)
            ?? .light
        let updateScenario = value(
            following: uiTestUpdatesArgument,
            in: arguments
        ).flatMap(UITestUpdateScenario.init)
            ?? .unconfigured
        let ephemeralRootURL = temporaryDirectory
            .appendingPathComponent(
                "MojiPond-UI-Tests-\(processIdentifier)",
                isDirectory: true
            )

        return AppLaunchConfiguration(
            isUITesting: true,
            initialScreen: initialScreen,
            uiTestPermissionScenario: permissionScenario,
            uiTestAppearance: appearance,
            uiTestUpdateScenario: updateScenario,
            ephemeralRootURL: ephemeralRootURL,
            opensLibraryAtLaunch:
                initialScreen == .library
                    || initialScreen == .libraryEmptyPack
        )
    }

    func initialPresentation(
        hasCompletedOnboarding: Bool
    ) -> InitialPresentation {
        if isUITesting {
            return initialScreen == .library
                || initialScreen == .libraryEmptyPack
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
        let updates: AppUpdateController
        switch uiTestUpdateScenario {
        case .unconfigured:
            updates = AppUpdateController()
        case .configured:
            updates = AppUpdateController(
                configuration: SignedUpdateConfiguration(
                    feedURL: URL(
                        string: "https://updates.example.invalid/feed.json"
                    ),
                    publicKey: .ed25519(
                        rawRepresentation: Data(repeating: 0, count: 32)
                    )
                ),
                checkerFactory: { _ in UITestUpdateChecker() },
                checkHistoryStore: UITestUpdateCheckHistoryStore(),
                automaticCheckScheduler:
                    UITestAutomaticUpdateCheckScheduler()
            )
        }
        return AppState(
            permissions: permissions,
            preferencesStore: UITestPreferencesStore(),
            updates: updates,
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

private final class UITestPermissionProvider: SystemPermissionProviding {
    let scenario: AppLaunchConfiguration.UITestPermissionScenario
    private var grantedPermissions: Set<SystemPermission> = []

    init(scenario: AppLaunchConfiguration.UITestPermissionScenario) {
        self.scenario = scenario
    }

    func isGranted(_ permission: SystemPermission) -> Bool {
        scenario == .granted || grantedPermissions.contains(permission)
    }

    func request(_ permission: SystemPermission) -> Bool {
        if scenario == .grantOnRequest {
            grantedPermissions.insert(permission)
        }
        return isGranted(permission)
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
        return scenario != .notRequested && scenario != .grantOnRequest
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

private struct UITestUpdateChecker: SignedUpdateChecking {
    func check(
        for kind: UpdateCheckKind
    ) async throws -> SignedUpdateCheckResult {
        _ = kind
        throw SignedUpdateCheckError.transportFailure
    }
}

private final class UITestUpdateCheckHistoryStore:
    UpdateCheckHistoryStoring
{
    var lastAutomaticCheckDate: Date?
    var lastSuccessfulAutomaticCheckOutcome:
        SuccessfulUpdateCheckOutcome?
}

@MainActor
private final class UITestAutomaticUpdateCheckScheduler:
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
