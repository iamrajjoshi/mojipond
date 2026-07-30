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
        XCTAssertTrue(
            application.staticTexts[
                "Import one reviewed ZIP at a time."
            ].exists
        )
        let onboardingWindow = application.windows["Set Up MojiPond"]
        XCTAssertTrue(onboardingWindow.waitForExistence(timeout: 2))
        attachScreen(
            named: "onboarding-welcome",
            element: onboardingWindow
        )

        application.buttons["Continue"].click()

        let permissionsExists = application.staticTexts[
            "Permissions, used narrowly"
        ].waitForExistence(timeout: 2)
        XCTAssertTrue(permissionsExists)
        let libraryModeExists = application.buttons[
            "Continue in Library Mode"
        ].exists
        XCTAssertTrue(libraryModeExists)
        attachScreen(
            named: "onboarding-permission-explanation",
            element: onboardingWindow
        )

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
        attachScreen(
            named: "onboarding-practice",
            element: onboardingWindow
        )
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
        attachScreen(
            named: "library-initial",
            element: application.windows["MojiPond Library"]
        )
    }

    func testLibraryLightAndDarkAppearanceScreenshots() {
        continueAfterFailure = false
        let lightScreenshot = captureLibraryImportSurface(
            appearance: .light,
            screenshotName: "library-light"
        )
        let darkScreenshot = captureLibraryImportSurface(
            appearance: .dark,
            screenshotName: "library-dark"
        )
        XCTAssertNotEqual(
            lightScreenshot,
            darkScreenshot,
            "Light and dark screenshots must render distinct appearances"
        )
    }

    func testPackDetailsKeepsImageImportZIPOnly() {
        continueAfterFailure = false
        let application = launch(
            initialScreen: "library",
            appearance: .light
        )
        defer {
            application.terminate()
        }

        assertLibraryIsReady(application)
        let newPackButton = application.buttons["New Empty Pack…"]
        XCTAssertTrue(newPackButton.waitForExistence(timeout: 2))
        newPackButton.click()

        XCTAssertTrue(
            application.staticTexts[
                "Create an empty pack"
            ].waitForExistence(timeout: 2)
        )
        let nameField = application.textFields["Name"]
        XCTAssertTrue(nameField.waitForExistence(timeout: 2))
        nameField.click()
        nameField.typeText("ZIP Only Pack")
        application.buttons["Create Pack"].click()

        let packLabel = application.staticTexts["ZIP Only Pack"].firstMatch
        XCTAssertTrue(packLabel.waitForExistence(timeout: 3))
        packLabel.click()
        let detailsButton = application.buttons["Pack Details"]
        XCTAssertTrue(detailsButton.waitForExistence(timeout: 2))
        detailsButton.click()

        XCTAssertTrue(
            application.buttons[
                "Replace Contents from ZIP…"
            ].waitForExistence(timeout: 2)
        )
        XCTAssertFalse(application.buttons["Add Files…"].exists)
        XCTAssertFalse(
            application.buttons["Check GitHub Revision…"].exists
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
            expectsStaticText: true,
            screenshotName: "settings"
        )
        captureDocumentationSurface(
            initialScreen: "import-preview",
            appearance: .light,
            windowTitle: "MojiPond Import Preview",
            expectedText: "Review “Pond Favorites”",
            expectsStaticText: true,
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
            expectsStaticText: true,
            screenshotName: "emoji-browser-dark"
        )
    }

    private func captureLibraryImportSurface(
        appearance: AppUITestAppearance,
        screenshotName: String
    ) -> Data {
        let application = launch(
            initialScreen: "library",
            appearance: appearance
        )
        defer {
            application.terminate()
        }

        assertLibraryIsReady(application)
        let importPackButtons = application.buttons.matching(
            NSPredicate(format: "label == %@", "Import Pack")
        )
        let importPackButton = importPackButtons.firstMatch
        XCTAssertTrue(
            importPackButton.waitForExistence(timeout: 2),
            "Expected Import Pack to be available"
        )
        XCTAssertEqual(
            importPackButtons.count,
            1,
            "Expected exactly one accessible Import Pack button"
        )
        importPackButton.click()
        XCTAssertTrue(
            application.staticTexts[
                "Import a ZIP pack"
            ].waitForExistence(timeout: 2)
        )
        XCTAssertTrue(application.buttons["Choose ZIP…"].exists)
        for removedControl in [
            "Choose Images…",
            "Choose Folder…",
            "Choose emoji.json…",
            "Review GitHub Import"
        ] {
            XCTAssertFalse(application.buttons[removedControl].exists)
        }
        return attachScreen(
            named: screenshotName,
            element: application.windows["MojiPond Library"]
        )
    }

    private func captureDocumentationSurface(
        initialScreen: String,
        appearance: AppUITestAppearance,
        windowTitle: String,
        windowIdentifier: String? = nil,
        expectedText: String,
        expectsStaticText: Bool = false,
        screenshotName: String
    ) {
        let application = launch(
            initialScreen: initialScreen,
            appearance: appearance
        )
        defer {
            application.terminate()
        }

        let window = if let windowIdentifier {
            application.dialogs[windowIdentifier]
        } else {
            application.windows[windowTitle]
        }
        XCTAssertTrue(
            window.waitForExistence(timeout: 5),
            "Expected \(windowTitle) to exist"
        )
        let matchingText = expectsStaticText
            ? window.staticTexts[expectedText]
            : window.descendants(matching: .any)[expectedText]
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
            ].firstMatch.waitForExistence(timeout: 5)
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
            AppUITestArgument.appearance,
            appearance.rawValue
        ]
        application.launch()
        return application
    }

    @discardableResult
    private func attachScreen(
        named name: String,
        element: XCUIElement
    ) -> Data {
        let screenshot = element.screenshot()
        let attachment = XCTAttachment(
            screenshot: screenshot
        )
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
        return screenshot.pngRepresentation
    }
}

private enum AppUITestArgument {
    static let enabled = "--mojipond-ui-testing"
    static let screen = "--mojipond-ui-test-screen"
    static let permissionScenario =
        "--mojipond-ui-test-permissions"
    static let appearance =
        "--mojipond-ui-test-appearance"
}

private enum AppUITestAppearance: String {
    case light
    case dark
}

private enum AppUITestPermissionScenario: String {
    case notRequested = "not-requested"
    case denied
    case granted
    case revoked
}
