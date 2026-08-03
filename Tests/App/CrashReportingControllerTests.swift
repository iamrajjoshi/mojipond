import XCTest
import Sentry
@testable import MojiPond

@MainActor
final class CrashReportingControllerTests: XCTestCase {
    func testStartsAndStopsSDKWhenPreferenceChanges() {
        let sdk = CrashReportingSDKSpy()
        let controller = CrashReportingController(sdk: sdk)

        controller.setEnabled(true)
        controller.setEnabled(true)
        XCTAssertEqual(sdk.startCallCount, 1)
        XCTAssertEqual(sdk.closeCallCount, 0)

        controller.setEnabled(false)
        controller.setEnabled(false)
        XCTAssertEqual(sdk.startCallCount, 1)
        XCTAssertEqual(sdk.closeCallCount, 1)

        controller.setEnabled(true)
        XCTAssertEqual(sdk.startCallCount, 2)
        XCTAssertEqual(sdk.closeCallCount, 1)
    }

    func testLaunchPolicySuppressesUnitAndUITestTraffic() {
        XCTAssertFalse(
            CrashReportingLaunchPolicy.allowsReporting(
                isUITesting: true,
                environment: [:]
            )
        )
        XCTAssertFalse(
            CrashReportingLaunchPolicy.allowsReporting(
                isUITesting: false,
                environment: ["XCTestConfigurationFilePath": "tests.xctest"]
            )
        )
        XCTAssertTrue(
            CrashReportingLaunchPolicy.allowsReporting(
                isUITesting: false,
                environment: [:]
            )
        )
    }

    func testLaunchPolicyWaitsForFirstRunChoice() {
        XCTAssertFalse(
            CrashReportingLaunchPolicy.shouldEnable(
                isUITesting: false,
                environment: [:],
                hasCompletedOnboarding: false,
                userAllowsCrashReports: true
            )
        )
        XCTAssertFalse(
            CrashReportingLaunchPolicy.shouldEnable(
                isUITesting: false,
                environment: [:],
                hasCompletedOnboarding: true,
                userAllowsCrashReports: false
            )
        )
        XCTAssertTrue(
            CrashReportingLaunchPolicy.shouldEnable(
                isUITesting: false,
                environment: [:],
                hasCompletedOnboarding: true,
                userAllowsCrashReports: true
            )
        )
    }

    func testSentryOptionsAreLimitedToCrashAndHangReporting() {
        let options = Options()

        SystemSentrySDKController.configure(
            options,
            isDebugBuild: false
        )

        XCTAssertFalse(options.debug)
        XCTAssertEqual(options.environment, "production")
        XCTAssertTrue(
            options.cacheDirectoryPath.hasSuffix(
                "/Caches/MojiPond/Sentry"
            )
        )
        XCTAssertFalse(options.sendDefaultPii)
        XCTAssertFalse(options.sendClientReports)
        XCTAssertFalse(options.enableMemoryIntrospection)
        XCTAssertFalse(options.enableAutoSessionTracking)
        XCTAssertFalse(options.enableAutoBreadcrumbTracking)
        XCTAssertEqual(options.maxBreadcrumbs, 0)
        XCTAssertFalse(options.enableSwizzling)
        XCTAssertFalse(options.enableNetworkBreadcrumbs)
        XCTAssertFalse(options.enableNetworkTracking)
        XCTAssertFalse(options.enableCaptureFailedRequests)
        XCTAssertFalse(options.enableMetrics)
        XCTAssertFalse(options.enableLogs)
        XCTAssertFalse(options.enableAutoPerformanceTracing)
        XCTAssertFalse(options.enableCoreDataTracing)
        XCTAssertFalse(options.enableDataSwizzling)
        XCTAssertFalse(options.enableFileIOTracing)
        XCTAssertFalse(options.enableTimeToFullDisplayTracing)
        XCTAssertFalse(options.enablePersistingTracesWhenCrashing)
        XCTAssertEqual(options.tracesSampleRate, 0)
        XCTAssertTrue(options.enableAppHangTracking)
        XCTAssertEqual(options.appHangTimeoutInterval, 4)
        XCTAssertFalse(options.enableUncaughtNSExceptionReporting)
        XCTAssertNil(options.configureProfiling)
        XCTAssertEqual(options.shutdownTimeInterval, 0)
    }
}

@MainActor
private final class CrashReportingSDKSpy:
    CrashReportingSDKControlling
{
    private(set) var isEnabled = false
    private(set) var startCallCount = 0
    private(set) var closeCallCount = 0

    func start() {
        startCallCount += 1
        isEnabled = true
    }

    func close() {
        closeCallCount += 1
        isEnabled = false
    }
}
