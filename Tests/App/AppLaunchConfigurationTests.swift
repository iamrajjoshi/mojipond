import Foundation
import XCTest
@testable import MojiPond

final class AppLaunchConfigurationTests: XCTestCase {
    func testProductionLaunchIgnoresUITestScreenArgument() {
        let configuration = AppLaunchConfiguration.parse(
            arguments: [
                "MojiPond",
                AppLaunchConfiguration.uiTestScreenArgument,
                "library"
            ],
            processIdentifier: 42,
            temporaryDirectory: URL(fileURLWithPath: "/tmp")
        )

        XCTAssertFalse(configuration.isUITesting)
        XCTAssertNil(configuration.initialScreen)
        XCTAssertEqual(
            configuration.uiTestPermissionScenario,
            .notRequested
        )
        XCTAssertNil(configuration.uiTestAppearance)
        XCTAssertNil(configuration.ephemeralRootURL)
        XCTAssertEqual(
            configuration.initialPresentation(
                hasCompletedOnboarding: true
            ),
            .statusItemOnly
        )
    }

    func testUITestLaunchDefaultsToOnboardingAndIsolatesData() {
        let configuration = AppLaunchConfiguration.parse(
            arguments: [
                "MojiPond",
                AppLaunchConfiguration.uiTestingFlag
            ],
            processIdentifier: 42,
            temporaryDirectory: URL(fileURLWithPath: "/tmp")
        )

        XCTAssertTrue(configuration.isUITesting)
        XCTAssertEqual(configuration.initialScreen, .onboarding)
        XCTAssertEqual(
            configuration.uiTestPermissionScenario,
            .notRequested
        )
        XCTAssertEqual(configuration.uiTestAppearance, .light)
        XCTAssertEqual(
            configuration.ephemeralRootURL,
            URL(
                fileURLWithPath: "/tmp/MojiPond-UI-Tests-42",
                isDirectory: true
            )
        )
    }

    func testUITestLaunchSelectsLibrary() {
        let configuration = AppLaunchConfiguration.parse(
            arguments: [
                "MojiPond",
                AppLaunchConfiguration.uiTestingFlag,
                AppLaunchConfiguration.uiTestScreenArgument,
                "library"
            ],
            processIdentifier: 7,
            temporaryDirectory: URL(fileURLWithPath: "/private/tmp")
        )

        XCTAssertTrue(configuration.isUITesting)
        XCTAssertEqual(configuration.initialScreen, .library)
        XCTAssertEqual(
            configuration.ephemeralRootURL,
            URL(
                fileURLWithPath: "/private/tmp/MojiPond-UI-Tests-7",
                isDirectory: true
            )
        )
    }

    @MainActor
    func testUITestLaunchSelectsDocumentationSurfaceAndPermissionState() {
        let configuration = AppLaunchConfiguration.parse(
            arguments: [
                "MojiPond",
                AppLaunchConfiguration.uiTestingFlag,
                AppLaunchConfiguration.uiTestScreenArgument,
                "import-preview",
                AppLaunchConfiguration.uiTestPermissionArgument,
                "revoked",
                AppLaunchConfiguration.uiTestAppearanceArgument,
                "dark"
            ],
            processIdentifier: 8,
            temporaryDirectory: URL(fileURLWithPath: "/private/tmp")
        )

        XCTAssertTrue(configuration.isUITesting)
        XCTAssertEqual(configuration.initialScreen, .importPreview)
        XCTAssertEqual(
            configuration.uiTestPermissionScenario,
            .revoked
        )
        XCTAssertEqual(configuration.uiTestAppearance, .dark)
        let appState = configuration.makeAppState()
        XCTAssertFalse(appState.launchAtLoginEnabled)
    }

    func testUITestLaunchFallsBackForUnknownScreenAndPermissionState() {
        let configuration = AppLaunchConfiguration.parse(
            arguments: [
                "MojiPond",
                AppLaunchConfiguration.uiTestingFlag,
                AppLaunchConfiguration.uiTestScreenArgument,
                "unknown",
                AppLaunchConfiguration.uiTestPermissionArgument,
                "unknown",
                AppLaunchConfiguration.uiTestAppearanceArgument,
                "unknown"
            ],
            processIdentifier: 9,
            temporaryDirectory: URL(fileURLWithPath: "/private/tmp")
        )

        XCTAssertEqual(configuration.initialScreen, .onboarding)
        XCTAssertEqual(
            configuration.uiTestPermissionScenario,
            .notRequested
        )
        XCTAssertEqual(configuration.uiTestAppearance, .light)
    }

    func testCompletedProductionLaunchStaysInMenuBarByDefault() {
        let configuration = AppLaunchConfiguration.parse(
            arguments: ["MojiPond"],
            processIdentifier: 42,
            temporaryDirectory: URL(fileURLWithPath: "/tmp")
        )

        XCTAssertEqual(
            configuration.initialPresentation(
                hasCompletedOnboarding: true
            ),
            .statusItemOnly
        )
        XCTAssertEqual(
            configuration.initialPresentation(
                hasCompletedOnboarding: false
            ),
            .onboarding
        )
    }

    func testExplicitProductionLaunchArgumentOpensLibrary() {
        let configuration = AppLaunchConfiguration.parse(
            arguments: [
                "MojiPond",
                AppLaunchConfiguration.openLibraryArgument
            ],
            processIdentifier: 42,
            temporaryDirectory: URL(fileURLWithPath: "/tmp")
        )

        XCTAssertEqual(
            configuration.initialPresentation(
                hasCompletedOnboarding: true
            ),
            .library
        )
    }
}
