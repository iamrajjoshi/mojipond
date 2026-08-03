import Foundation
import XCTest
@testable import MojiPond

@MainActor
final class AppUpdateControllerTests: XCTestCase {
    func testConfigurationRequiresHTTPSFeedAndEd25519PublicKey() {
        XCTAssertTrue(
            SparkleUpdateConfiguration(
                feedURL: URL(string: "https://updates.example.com/appcast.xml"),
                publicKey: Data(repeating: 1, count: 32)
            ).isConfigured
        )
        XCTAssertFalse(
            SparkleUpdateConfiguration(
                feedURL: URL(string: "http://updates.example.com/appcast.xml"),
                publicKey: Data(repeating: 1, count: 32)
            ).isConfigured
        )
        XCTAssertFalse(
            SparkleUpdateConfiguration(
                feedURL: URL(string: "https://updates.example.com/appcast.xml"),
                publicKey: Data(repeating: 1, count: 31)
            ).isConfigured
        )
        XCTAssertFalse(
            SparkleUpdateConfiguration(
                feedURL: URL(
                    string: "https://user:secret@updates.example.com/appcast.xml"
                ),
                publicKey: Data(repeating: 1, count: 32)
            ).isConfigured
        )
    }

    func testReleaseBundlePinsSparkleSecurityConfiguration() {
        let bundle = Bundle(for: AppDelegate.self)
        let configuration = SparkleUpdateConfiguration.load(bundle: bundle)

        XCTAssertEqual(
            configuration.feedURL?.absoluteString,
            "https://mojipond.com/releases/appcast.xml"
        )
        XCTAssertEqual(
            configuration.publicKey?.base64EncodedString(),
            "YOBfWktYxbGqBH8Hd6AMyRjZeqKG8QLIeHcH4yun6Ho="
        )
        XCTAssertTrue(configuration.isConfigured)
        XCTAssertEqual(
            bundle.object(forInfoDictionaryKey: "SURequireSignedFeed")
                as? Bool,
            true
        )
        XCTAssertEqual(
            bundle.object(
                forInfoDictionaryKey: "SUVerifyUpdateBeforeExtraction"
            ) as? Bool,
            true
        )
        XCTAssertEqual(
            bundle.object(forInfoDictionaryKey: "SUEnableSystemProfiling")
                as? Bool,
            false
        )
        XCTAssertEqual(
            bundle.object(forInfoDictionaryKey: "SUEnableAutomaticChecks")
                as? Bool,
            false
        )
        XCTAssertEqual(
            bundle.object(forInfoDictionaryKey: "SUAutomaticallyUpdate")
                as? Bool,
            false
        )
    }

    func testConfiguredControllerUsesSparkleForChecksAndPreferences() {
        let driver = SparkleUpdaterDriverSpy()
        driver.automaticallyChecksForUpdates = true
        let controller = AppUpdateController(
            configuration: configuredUpdateConfiguration,
            driver: driver
        )

        controller.start()

        XCTAssertTrue(controller.isConfigured)
        XCTAssertTrue(controller.canCheckForUpdates)
        XCTAssertTrue(controller.automaticChecksEnabled)
        XCTAssertEqual(driver.startCallCount, 1)

        controller.setAutomaticChecksEnabled(false)
        XCTAssertFalse(controller.automaticChecksEnabled)

        controller.setAutomaticChecksEnabled(true)
        XCTAssertTrue(controller.automaticChecksEnabled)
        XCTAssertEqual(driver.startCallCount, 1)

        controller.checkManually()
        XCTAssertEqual(driver.checkCallCount, 1)

        driver.publishCanCheckForUpdates(false)
        XCTAssertFalse(controller.canCheckForUpdates)
        controller.checkManually()
        XCTAssertEqual(driver.checkCallCount, 1)

        driver.publishCanCheckForUpdates(true)
        XCTAssertTrue(controller.canCheckForUpdates)
        controller.checkManually()
        XCTAssertEqual(driver.checkCallCount, 2)
    }

    func testUnconfiguredControllerDoesNotStartOrCheck() {
        let driver = SparkleUpdaterDriverSpy()
        let controller = AppUpdateController(
            configuration: SparkleUpdateConfiguration(
                feedURL: nil,
                publicKey: nil
            ),
            driver: driver
        )

        controller.start()
        controller.setAutomaticChecksEnabled(true)
        controller.checkManually()

        XCTAssertFalse(controller.isConfigured)
        XCTAssertFalse(controller.canCheckForUpdates)
        XCTAssertFalse(controller.automaticChecksEnabled)
        XCTAssertEqual(driver.startCallCount, 0)
        XCTAssertEqual(driver.checkCallCount, 0)
    }

    private var configuredUpdateConfiguration: SparkleUpdateConfiguration {
        SparkleUpdateConfiguration(
            feedURL: URL(string: "https://updates.example.com/appcast.xml"),
            publicKey: Data(repeating: 1, count: 32)
        )
    }
}

@MainActor
private final class SparkleUpdaterDriverSpy: SparkleUpdaterDriving {
    var automaticallyChecksForUpdates = false
    var canCheckForUpdates = true
    private(set) var startCallCount = 0
    private(set) var checkCallCount = 0
    private var availabilityHandler: (@MainActor (Bool) -> Void)?

    func start() {
        startCallCount += 1
    }

    func checkForUpdates() {
        checkCallCount += 1
    }

    func observeCanCheckForUpdates(
        _ handler: @escaping @MainActor (Bool) -> Void
    ) {
        availabilityHandler = handler
        handler(canCheckForUpdates)
    }

    func publishCanCheckForUpdates(_ canCheck: Bool) {
        canCheckForUpdates = canCheck
        availabilityHandler?(canCheck)
    }
}
