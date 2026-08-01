import XCTest

@MainActor
final class MojiPondUITests: XCTestCase {
    func testOnboardingKeepsPermissionsAndPracticeOnOneScreen() {
        continueAfterFailure = false
        let application = launch(
            initialScreen: "onboarding",
            appearance: .light
        )
        defer {
            application.terminate()
        }

        let setupExists = application.staticTexts[
            "Welcome to MojiPond"
        ].waitForExistence(timeout: 5)
        XCTAssertTrue(setupExists)
        XCTAssertTrue(
            application.staticTexts["Input Monitoring"].exists
        )
        XCTAssertTrue(application.staticTexts["Accessibility"].exists)
        XCTAssertFalse(
            application.staticTexts["Send & Media Pasting"].exists
        )
        let onboardingWindow = application.windows["Set Up MojiPond"]
        XCTAssertTrue(onboardingWindow.waitForExistence(timeout: 2))
        attachScreen(
            named: "onboarding-setup",
            element: onboardingWindow
        )

        let practiceFieldExists = application.descendants(
            matching: .any
        )["onboarding.practiceField"].waitForExistence(timeout: 2)
        XCTAssertTrue(practiceFieldExists)
        XCTAssertFalse(application.buttons["Try It"].exists)
        XCTAssertFalse(application.buttons["Back"].exists)
        XCTAssertFalse(application.buttons["Use Library Only"].exists)
        let privacyWindowExists = application.windows.matching(
            NSPredicate(
                format: "title CONTAINS[c] %@",
                "Privacy & Security"
            )
        ).firstMatch.exists
        XCTAssertFalse(privacyWindowExists)
        attachScreen(
            named: "onboarding-setup",
            element: onboardingWindow
        )

        application.buttons["Open Library"].click()
        XCTAssertTrue(
            application.windows[
                "MojiPond Library"
            ].waitForExistence(timeout: 5)
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
        let nameField = application.descendants(
            matching: .any
        )["newPack.name"]
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
                expectedStatus: "Needs access",
                screenshotName: "onboarding-permissions-denied"
            ),
            (
                .granted,
                expectedStatus: "Granted",
                screenshotName: "onboarding-permissions-granted"
            ),
            (
                .revoked,
                expectedStatus: "Needs access",
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

    func testRequestAccessUpdatesThePermissionCardToGranted() {
        continueAfterFailure = false
        let application = launch(
            initialScreen: "onboarding",
            appearance: .light,
            permissionScenario: .grantOnRequest
        )
        defer {
            application.terminate()
        }

        let request = application.buttons[
            "Request Accessibility Access"
        ]
        XCTAssertTrue(request.waitForExistence(timeout: 5))
        request.click()

        let granted = application.descendants(matching: .any).matching(
            NSPredicate(
                format: "label == %@ AND value == %@",
                "Accessibility permission",
                "Granted"
            )
        ).firstMatch
        XCTAssertTrue(granted.waitForExistence(timeout: 2))
        XCTAssertFalse(request.exists)
        XCTAssertFalse(
            application.buttons["Open Accessibility Settings"].exists
        )
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
            expectedText: "importPreview.title",
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

    func testSettingsHidesUnavailableUpdatesAndReportsUsageReset() {
        continueAfterFailure = false
        let application = launch(
            initialScreen: "settings",
            appearance: .light
        )
        defer {
            application.terminate()
        }

        let settingsWindow = application.windows["MojiPond Settings"]
        XCTAssertTrue(settingsWindow.waitForExistence(timeout: 5))
        XCTAssertFalse(
            application.switches["Check for signed updates"].exists
        )

        application.descendants(matching: .any)["Privacy"].click()
        XCTAssertTrue(
            application.staticTexts["Accessibility"]
                .waitForExistence(timeout: 2)
        )
        XCTAssertTrue(
            application.staticTexts["Input Monitoring"].exists
        )
        XCTAssertFalse(
            application.staticTexts["Send & Media Pasting"].exists
        )
        XCTAssertFalse(
            application.buttons["Allow Send & Media Pasting"].exists
        )

        application.descendants(matching: .any)["About"].click()
        XCTAssertTrue(
            application.staticTexts[
                "Shortcodes and custom emoji for your Mac."
            ].waitForExistence(timeout: 2)
        )
        XCTAssertFalse(application.buttons["Check for Updates…"].exists)
        XCTAssertFalse(
            application.staticTexts.matching(
                NSPredicate(
                    format: "label CONTAINS[c] %@",
                    "local ad-hoc build"
                )
            ).firstMatch.exists
        )

        application.descendants(matching: .any)["Library"].click()
        let resetButton = application.buttons[
            "Reset recents and usage ranking"
        ]
        XCTAssertTrue(resetButton.waitForExistence(timeout: 2))
        resetButton.click()
        XCTAssertTrue(
            application.staticTexts[
                "Reset recents and usage ranking?"
            ].waitForExistence(timeout: 2)
        )
        let resetConfirmation = settingsWindow.sheets.firstMatch
        XCTAssertTrue(resetConfirmation.waitForExistence(timeout: 2))
        resetConfirmation.buttons["Reset"].firstMatch.click()
        let usageResetNotice = application.descendants(
            matching: .any
        )["settings.usageResetNotice"]
        XCTAssertTrue(usageResetNotice.waitForExistence(timeout: 2))
        XCTAssertTrue(
            application.staticTexts[
                "Recents and usage ranking were reset."
            ].waitForExistence(timeout: 2)
        )

        application.buttons["Open MojiPond Library"].click()
        XCTAssertTrue(
            application.windows[
                "MojiPond Library"
            ].waitForExistence(timeout: 5)
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
        let importZIPButtons = application.buttons.matching(
            NSPredicate(format: "label == %@", "Import ZIP")
        )
        let importZIPButton = importZIPButtons.firstMatch
        XCTAssertTrue(
            importZIPButton.waitForExistence(timeout: 2),
            "Expected Import ZIP to be available"
        )
        XCTAssertEqual(
            importZIPButtons.count,
            1,
            "Expected exactly one accessible Import ZIP button"
        )
        importZIPButton.click()
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
                "Welcome to MojiPond"
            ].waitForExistence(timeout: 5)
        )
        let permissionStatus = application.descendants(
            matching: .any
        ).matching(
            NSPredicate(
                format: "label == %@ AND value == %@",
                "Input Monitoring permission",
                expectedStatus
            )
        ).firstMatch
        XCTAssertTrue(
            permissionStatus.waitForExistence(timeout: 2),
            "Expected permission status \(expectedStatus)"
        )
        switch scenario {
        case .notRequested, .grantOnRequest:
            XCTAssertTrue(
                application.buttons[
                    "Request Input Monitoring Access"
                ].exists
            )
            XCTAssertTrue(
                application.buttons[
                    "Open Input Monitoring Settings"
                ].exists
            )
        case .denied, .revoked:
            XCTAssertTrue(
                application.buttons[
                    "Request Input Monitoring Access"
                ].exists
            )
            XCTAssertTrue(
                application.buttons[
                    "Open Input Monitoring Settings"
                ].exists
            )
        case .granted:
            XCTAssertFalse(
                application.buttons[
                    "Allow Input Monitoring"
                ].exists
            )
            XCTAssertFalse(
                application.buttons[
                    "Open Input Monitoring Settings"
                ].exists
            )
        }
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
                "Import ZIP"
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
            "-ApplePersistenceIgnoreState",
            "YES",
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
    case grantOnRequest = "grant-on-request"
    case revoked
}
