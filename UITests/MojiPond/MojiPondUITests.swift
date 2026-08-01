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
            "Set up typing shortcuts"
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

        application.buttons["Continue Without Shortcuts"].click()
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
        let libraryWindow = application.windows["MojiPond Library"]
        parkPointer(in: libraryWindow)
        attachScreen(
            named: "library-initial",
            element: libraryWindow
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

    func testLibraryUsesZIPImportInsteadOfManualCreation() {
        continueAfterFailure = false
        let application = launch(
            initialScreen: "library-empty-pack",
            appearance: .light
        )
        defer {
            application.terminate()
        }

        XCTAssertTrue(
            application.windows["MojiPond Library"]
                .waitForExistence(timeout: 5)
        )
        XCTAssertTrue(
            application.buttons["Import ZIP"].waitForExistence(timeout: 5)
        )
        XCTAssertFalse(application.buttons["New Empty Pack…"].exists)

        let packButton = application.buttons.matching(
            NSPredicate(
                format: "label CONTAINS[c] %@",
                "ZIP Only Pack"
            )
        ).firstMatch
        XCTAssertTrue(packButton.waitForExistence(timeout: 3))
        packButton.click()
        XCTAssertTrue(
            application.buttons["Pack Details"]
                .waitForExistence(timeout: 2)
        )
        application.buttons["Pack Details"].click()
        XCTAssertTrue(
            application.buttons["Export Pack…"]
                .waitForExistence(timeout: 2)
        )
        application.buttons["Done"].click()
        XCTAssertTrue(
            application.staticTexts["No emoji in this view"]
                .waitForExistence(timeout: 2)
        )
        XCTAssertFalse(application.buttons["Add Unicode Emoji"].exists)

        packButton.rightClick()
        XCTAssertTrue(
            application.menuItems["Pack Details…"]
                .waitForExistence(timeout: 2)
        )
        XCTAssertFalse(application.buttons["Add Unicode Emoji…"].exists)
        XCTAssertFalse(application.menuItems["Add Unicode Emoji…"].exists)
        application.typeKey(.escape, modifierFlags: [])
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
            expectedText: "runtime.browserQuery",
            screenshotName: "emoji-browser-dark"
        )
    }

    func testSettingsHidesUnavailableUpdatesAndReportsUsageReset() {
        continueAfterFailure = false
        let application = launch(
            initialScreen: "settings",
            appearance: .light,
            permissionScenario: .denied
        )
        defer {
            application.terminate()
        }

        let settingsWindow = application.windows["MojiPond Settings"]
        XCTAssertTrue(settingsWindow.waitForExistence(timeout: 5))
        XCTAssertFalse(
            application.checkBoxes["Keep MojiPond up to date"].exists
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
        XCTAssertTrue(
            application.staticTexts["Image emoji in Messages"].exists
        )
        let imagePermissionStatus = application.descendants(
            matching: .any
        ).matching(
            NSPredicate(
                format: "label == %@ AND value == %@",
                "Image emoji in Messages permission",
                "Denied"
            )
        ).firstMatch
        XCTAssertTrue(imagePermissionStatus.exists)

        let domainField = application.textFields["Website domain"]
        XCTAssertTrue(domainField.exists)
        domainField.click()
        domainField.typeText("example.com")
        application.buttons["Add"].click()
        XCTAssertTrue(application.staticTexts["Includes subdomains"].exists)

        domainField.click()
        domainField.typeText("example.com")
        application.checkBoxes["Include subdomains"].click()
        application.buttons["Add"].click()
        XCTAssertEqual(
            application.descendants(matching: .any).matching(
                identifier: "settings.disabledDomain.example.com"
            ).count,
            1
        )
        XCTAssertTrue(application.staticTexts["Exact host"].exists)

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
        let resetButton = application.buttons["Reset learned ordering…"]
        XCTAssertTrue(resetButton.waitForExistence(timeout: 2))
        resetButton.click()
        let resetConfirmation = settingsWindow.sheets.firstMatch
        XCTAssertTrue(resetConfirmation.waitForExistence(timeout: 2))
        XCTAssertTrue(
            resetConfirmation.staticTexts[
                "Reset recent emoji and learned ordering?"
            ].waitForExistence(timeout: 2)
        )
        let confirmResetButton = resetConfirmation.buttons["Reset"]
        XCTAssertTrue(confirmResetButton.waitForExistence(timeout: 2))
        confirmResetButton.click()
        let usageResetNotice = application.descendants(
            matching: .any
        )["settings.usageResetNotice"]
        XCTAssertTrue(usageResetNotice.waitForExistence(timeout: 2))
        XCTAssertTrue(
            application.staticTexts[
                "Learned ordering was reset."
            ].waitForExistence(timeout: 2)
        )

        application.buttons["Open MojiPond Library"].click()
        XCTAssertTrue(
            application.windows[
                "MojiPond Library"
            ].waitForExistence(timeout: 5)
        )
    }

    func testConfiguredUpdatesExposeKeepUpToDatePreference() {
        continueAfterFailure = false
        let application = launch(
            initialScreen: "settings",
            appearance: .light,
            updateScenario: .configured
        )
        defer {
            application.terminate()
        }

        XCTAssertTrue(
            application.windows["MojiPond Settings"]
                .waitForExistence(timeout: 5)
        )
        let updateToggle = application.checkBoxes[
            "Keep MojiPond up to date"
        ]
        XCTAssertTrue(updateToggle.waitForExistence(timeout: 2))
        XCTAssertTrue(
            application.staticTexts[
                "Checks once per day and adds Update to the menu bar. "
                    + "Downloads and installs require your approval."
            ].exists
        )
        XCTAssertTrue(application.menuItems["Check for Updates…"].exists)

        let initialValue = String(describing: updateToggle.value)
        updateToggle.click()
        XCTAssertNotEqual(
            String(describing: updateToggle.value),
            initialValue
        )
    }

    func testSettingsExposeShortcutSafetyAndAliasFlows() {
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

        application.buttons["Shortcuts"].click()
        XCTAssertTrue(
            application.staticTexts["Acceptance"]
                .waitForExistence(timeout: 2)
        )
        XCTAssertTrue(application.staticTexts["Trigger"].exists)
        XCTAssertTrue(application.staticTexts["Exact shortcodes"].exists)
        attachScreen(
            named: "settings-shortcuts",
            element: settingsWindow
        )

        application.buttons["Privacy"].click()
        XCTAssertTrue(
            application.staticTexts["Always disabled"]
                .waitForExistence(timeout: 2)
        )
        XCTAssertTrue(application.checkBoxes["Include subdomains"].exists)
        attachScreen(
            named: "settings-privacy",
            element: settingsWindow
        )

        application.buttons["Library"].click()
        let manageAliases = application.buttons["Manage Aliases"]
        XCTAssertTrue(manageAliases.waitForExistence(timeout: 2))
        manageAliases.click()

        let libraryWindow = application.windows["MojiPond Library"]
        XCTAssertTrue(libraryWindow.waitForExistence(timeout: 5))
        XCTAssertTrue(
            libraryWindow.staticTexts["Aliases"]
                .firstMatch.waitForExistence(timeout: 3)
        )

        let aliasesSidebar = libraryWindow.buttons[
            "library.sidebar.aliases"
        ]
        XCTAssertTrue(aliasesSidebar.waitForExistence(timeout: 2))
        aliasesSidebar.click()
        aliasesSidebar.typeKey(.downArrow, modifierFlags: [])
        XCTAssertTrue(
            libraryWindow.staticTexts["Built-in Emoji"]
                .waitForExistence(timeout: 2)
        )
        libraryWindow.typeKey(.upArrow, modifierFlags: [])
        XCTAssertTrue(
            libraryWindow.staticTexts["Aliases"]
                .firstMatch.waitForExistence(timeout: 2)
        )
        attachScreen(
            named: "library-aliases",
            element: libraryWindow
        )

        let emojiWithoutAlias = libraryWindow.buttons.matching(
            NSPredicate(
                format: "label CONTAINS %@",
                "no personal aliases"
            )
        ).firstMatch
        XCTAssertTrue(emojiWithoutAlias.waitForExistence(timeout: 5))
        emojiWithoutAlias.click()
        XCTAssertTrue(
            application.staticTexts["Your aliases"]
                .waitForExistence(timeout: 3)
        )
        XCTAssertTrue(
            application.descendants(matching: .any)[
                "library.personalAliases"
            ].exists
        )
        let aliasesField = application.descendants(matching: .any)[
            "library.personalAliases"
        ]
        aliasesField.click()
        aliasesField.typeText("pond_ui_alias")
        let saveAliasesButton = application.buttons["Save Aliases"]
        XCTAssertTrue(saveAliasesButton.isEnabled)
        saveAliasesButton.click()
        XCTAssertTrue(
            application.descendants(matching: .any)[
                "library.personalAliasesSaved"
            ].waitForExistence(timeout: 3)
        )
        XCTAssertFalse(saveAliasesButton.isEnabled)
        attachScreen(
            named: "library-personal-alias-editor",
            element: libraryWindow
        )
        aliasesField.click()
        aliasesField.typeText("_unsaved")
        XCTAssertTrue(saveAliasesButton.isEnabled)
        XCTAssertFalse(
            application.descendants(matching: .any)[
                "library.personalAliasesSaved"
            ].exists
        )
        application.buttons["Done"].click()
        XCTAssertTrue(
            application.staticTexts[
                "Discard unsaved alias changes?"
            ].waitForExistence(timeout: 2)
        )
        libraryWindow.sheets.buttons["Keep Editing"].firstMatch.click()
        XCTAssertTrue(aliasesField.exists)
        application.buttons["Done"].click()
        let discardChangesButton = libraryWindow.sheets.buttons[
            "Discard Changes"
        ].firstMatch
        XCTAssertTrue(
            discardChangesButton.waitForExistence(timeout: 2)
        )
        discardChangesButton.click()
        XCTAssertTrue(
            libraryWindow.buttons.matching(
                NSPredicate(
                    format: "label CONTAINS %@",
                    "personal aliases, colon pond_ui_alias colon"
                )
            ).firstMatch.waitForExistence(timeout: 3)
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
        for removedControl in [
            "Choose Images…",
            "Choose Folder…",
            "Choose emoji.json…",
            "Review GitHub Import",
            "Choose ZIP…"
        ] {
            XCTAssertFalse(application.buttons[removedControl].exists)
        }
        let libraryWindow = application.windows["MojiPond Library"]
        parkPointer(in: libraryWindow)
        return attachScreen(
            named: screenshotName,
            element: libraryWindow
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
        if initialScreen == "suggestions" {
            XCTAssertTrue(
                window.descendants(matching: .any)[
                    "Duck, colon duck colon"
                ].waitForExistence(timeout: 2),
                "Expected the compact panel to expose a sixth suggestion"
            )
            XCTAssertTrue(
                window.descendants(matching: .any)[
                    "Up and Down Arrow choose, Tab or Return inserts, Escape closes"
                ].waitForExistence(timeout: 2),
                "Expected keyboard guidance to remain in the footer"
            )
            XCTAssertFalse(
                window.staticTexts["MojiPond"].exists,
                "The suggestion panel should not spend a row on branding"
            )
        }
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
                "Set up typing shortcuts"
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
            XCTAssertFalse(
                application.buttons[
                    "Open Input Monitoring Settings"
                ].exists
            )
        case .denied, .revoked:
            XCTAssertFalse(
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
            AppUITestPermissionScenario = .notRequested,
        updateScenario: AppUITestUpdateScenario = .unconfigured
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
            appearance.rawValue,
            AppUITestArgument.updateScenario,
            updateScenario.rawValue,
            "-settings.selectedDestination",
            "General"
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

    private func parkPointer(in window: XCUIElement) {
        window.coordinate(
            withNormalizedOffset: CGVector(dx: 0.5, dy: 0.02)
        ).click()
    }
}

private enum AppUITestArgument {
    static let enabled = "--mojipond-ui-testing"
    static let screen = "--mojipond-ui-test-screen"
    static let permissionScenario =
        "--mojipond-ui-test-permissions"
    static let appearance =
        "--mojipond-ui-test-appearance"
    static let updateScenario =
        "--mojipond-ui-test-updates"
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

private enum AppUITestUpdateScenario: String {
    case unconfigured
    case configured
}
