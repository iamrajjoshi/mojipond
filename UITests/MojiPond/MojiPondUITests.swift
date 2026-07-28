import XCTest

@MainActor
final class MojiPondUITests: XCTestCase {
    func testOnboardingAdvancesWithoutRequestingPermissions() {
        continueAfterFailure = false
        let application = launch(
            initialScreen: "onboarding",
            appearance: .light
        )
        defer {
            application.terminate()
        }

        let welcomeExists = application.staticTexts[
            "Every emote, right where you type"
        ].waitForExistence(timeout: 5)
        XCTAssertTrue(welcomeExists)
        attachScreen(named: "onboarding-welcome")

        application.buttons["Continue"].click()

        let permissionsExists = application.staticTexts[
            "Permissions, used narrowly"
        ].waitForExistence(timeout: 2)
        XCTAssertTrue(permissionsExists)
        let libraryModeExists = application.buttons[
            "Continue in Library Mode"
        ].exists
        XCTAssertTrue(libraryModeExists)
        attachScreen(named: "onboarding-permission-explanation")

        application.buttons["Continue in Library Mode"].click()

        let practiceFieldExists = application.textFields[
            "onboarding.practiceField"
        ].waitForExistence(timeout: 2)
        XCTAssertTrue(practiceFieldExists)
        let privacyWindowExists = application.windows.matching(
            NSPredicate(
                format: "title CONTAINS[c] %@",
                "Privacy & Security"
            )
        ).firstMatch.exists
        XCTAssertFalse(privacyWindowExists)
        attachScreen(named: "onboarding-practice")
    }

    func testLibraryLaunchesFromDeterministicState() {
        continueAfterFailure = false
        let application = launch(
            initialScreen: "library",
            appearance: .light
        )
        defer {
            application.terminate()
        }

        assertLibraryIsReady(application)
        attachScreen(named: "library-initial")
    }

    func testLibraryLightAndDarkAppearanceScreenshots() {
        continueAfterFailure = false
        captureLibraryImportSurface(
            appearance: .light,
            screenshotName: "library-light"
        )
        captureLibraryImportSurface(
            appearance: .dark,
            screenshotName: "library-dark"
        )
    }

    func testOnboardingPermissionStatesRenderDeterministically() {
        continueAfterFailure = false
        let scenarios: [
            (
                AppUITestPermissionScenario,
                expectedStatus: String,
                screenshotName: String
            )
        ] = [
            (
                .denied,
                expectedStatus: "Not allowed",
                screenshotName: "onboarding-permissions-denied"
            ),
            (
                .granted,
                expectedStatus: "Allowed",
                screenshotName: "onboarding-permissions-granted"
            ),
            (
                .revoked,
                expectedStatus: "Access removed",
                screenshotName: "onboarding-permissions-revoked"
            )
        ]

        for scenario in scenarios {
            captureOnboardingPermissionState(
                scenario: scenario.0,
                expectedStatus: scenario.expectedStatus,
                screenshotName: scenario.screenshotName
            )
        }
    }

    func testRequiredDocumentationSurfaces() {
        continueAfterFailure = false
        captureDocumentationSurface(
            initialScreen: "settings",
            appearance: .light,
            windowTitle: "MojiPond Settings",
            expectedText: "Enable MojiPond",
            screenshotName: "settings"
        )
        captureDocumentationSurface(
            initialScreen: "import-preview",
            appearance: .light,
            windowTitle: "MojiPond Import Preview",
            expectedText: "Pond Favorites",
            screenshotName: "import-preview"
        )
        captureDocumentationSurface(
            initialScreen: "suggestions",
            appearance: .light,
            windowTitle: "MojiPond Caret Suggestions",
            windowIdentifier: "runtime.suggestionPanel",
            expectedText: "Waving hand, colon wave colon",
            screenshotName: "caret-suggestions"
        )
        captureDocumentationSurface(
            initialScreen: "browser",
            appearance: .dark,
            windowTitle: "MojiPond Emoji Browser",
            windowIdentifier: "runtime.suggestionPanel",
            expectedText: "pond",
            screenshotName: "emoji-browser-dark"
        )
    }

    private func captureLibraryImportSurface(
        appearance: AppUITestAppearance,
        screenshotName: String
    ) {
        let application = launch(
            initialScreen: "library",
            appearance: appearance
        )
        defer {
            application.terminate()
        }

        assertLibraryIsReady(application)
        application.buttons["Import Pack"].click()
        XCTAssertTrue(
            application.staticTexts[
                "Import an emoji pack"
            ].waitForExistence(timeout: 2)
        )
        attachScreen(named: screenshotName)
    }

    private func captureDocumentationSurface(
        initialScreen: String,
        appearance: AppUITestAppearance,
        windowTitle: String,
        windowIdentifier: String? = nil,
        expectedText: String,
        screenshotName: String
    ) {
        let application = launch(
            initialScreen: initialScreen,
            appearance: appearance
        )
        defer {
            application.terminate()
        }

        let window = application.windows[
            windowIdentifier ?? windowTitle
        ]
        XCTAssertTrue(window.waitForExistence(timeout: 5))
        let matchingText = window.descendants(
            matching: .any
        ).matching(
            NSPredicate(
                format: "label CONTAINS[c] %@",
                expectedText
            )
        ).firstMatch
        XCTAssertTrue(
            matchingText.waitForExistence(timeout: 5),
            "Expected \(windowTitle) to contain \(expectedText)"
        )
        attachScreen(named: screenshotName, element: window)
    }

    private func captureOnboardingPermissionState(
        scenario: AppUITestPermissionScenario,
        expectedStatus: String,
        screenshotName: String
    ) {
        let application = launch(
            initialScreen: "onboarding",
            appearance: .light,
            permissionScenario: scenario
        )
        defer {
            application.terminate()
        }

        XCTAssertTrue(
            application.staticTexts[
                "Every emote, right where you type"
            ].waitForExistence(timeout: 5)
        )
        application.buttons["Continue"].click()
        let permissionStatus = application.descendants(
            matching: .any
        ).matching(
            NSPredicate(
                format: "label == %@ AND value == %@",
                "Permission status",
                expectedStatus
            )
        ).firstMatch
        XCTAssertTrue(
            permissionStatus.waitForExistence(timeout: 2),
            "Expected permission status \(expectedStatus)"
        )
        let window = application.windows["Set Up MojiPond"]
        XCTAssertTrue(window.waitForExistence(timeout: 2))
        attachScreen(named: screenshotName, element: window)
    }

    private func assertLibraryIsReady(
        _ application: XCUIApplication
    ) {
        XCTAssertTrue(
            application.windows[
                "MojiPond Library"
            ].waitForExistence(timeout: 5)
        )
        XCTAssertTrue(
            application.buttons[
                "Import Pack"
            ].waitForExistence(timeout: 5)
        )
        XCTAssertTrue(
            application.staticTexts[
                "All Emoji"
            ].waitForExistence(timeout: 5)
        )
        XCTAssertTrue(
            application.buttons[
                "grinning face, colon grinning colon, "
                    + "Unicode emoji, Built-in Emoji"
            ].waitForExistence(timeout: 5)
        )
    }

    private func launch(
        initialScreen: String,
        appearance: AppUITestAppearance,
        permissionScenario:
            AppUITestPermissionScenario = .notRequested
    ) -> XCUIApplication {
        let application = XCUIApplication()
        application.launchArguments = [
            AppUITestArgument.enabled,
            AppUITestArgument.screen,
            initialScreen,
            AppUITestArgument.permissionScenario,
            permissionScenario.rawValue,
            "-AppleInterfaceStyle",
            appearance.rawValue,
            "-AppleInterfaceStyleSwitchesAutomatically",
            "false"
        ]
        application.launch()
        return application
    }

    private func attachScreen(named name: String) {
        let attachment = XCTAttachment(
            screenshot: XCUIScreen.main.screenshot()
        )
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    private func attachScreen(
        named name: String,
        element: XCUIElement
    ) {
        let attachment = XCTAttachment(
            screenshot: element.screenshot()
        )
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}

private enum AppUITestArgument {
    static let enabled = "--mojipond-ui-testing"
    static let screen = "--mojipond-ui-test-screen"
    static let permissionScenario =
        "--mojipond-ui-test-permissions"
}

private enum AppUITestAppearance: String {
    case light = "Light"
    case dark = "Dark"
}

private enum AppUITestPermissionScenario: String {
    case notRequested = "not-requested"
    case denied
    case granted
    case revoked
}
