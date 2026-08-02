import Foundation
import Sentry

@MainActor
protocol CrashReportingSDKControlling: AnyObject {
    var isEnabled: Bool { get }

    func start()
    func close()
}

@MainActor
final class SystemSentrySDKController: CrashReportingSDKControlling {
    private static let dsn =
        "https://5a1985821be92d8348971b1fffe7960d@o4509294838415360.ingest.us.sentry.io/4511838980800512"
    private static let cacheDirectoryPath = FileManager.default
        .urls(for: .cachesDirectory, in: .userDomainMask)
        .first?
        .appendingPathComponent("MojiPond/Sentry", isDirectory: true)
        .path

    var isEnabled: Bool {
        SentrySDK.isEnabled
    }

    func start() {
        SentrySDK.start { options in
            #if DEBUG
            Self.configure(options, isDebugBuild: true)
            #else
            Self.configure(options, isDebugBuild: false)
            #endif
        }
    }

    static func configure(
        _ options: Options,
        isDebugBuild: Bool
    ) {
        options.dsn = dsn
        if let cacheDirectoryPath {
            options.cacheDirectoryPath = cacheDirectoryPath
        }
        options.debug = isDebugBuild
        options.environment = isDebugBuild
            ? "development"
            : "production"

        options.sendDefaultPii = false
        options.sendClientReports = false
        options.enableMemoryIntrospection = false
        options.enableAutoSessionTracking = false
        options.enableAutoBreadcrumbTracking = false
        options.maxBreadcrumbs = 0
        options.enableSwizzling = false
        options.enableNetworkBreadcrumbs = false
        options.enableNetworkTracking = false
        options.enableCaptureFailedRequests = false
        options.enableMetrics = false
        options.enableLogs = false
        options.enableAutoPerformanceTracing = false
        options.enableCoreDataTracing = false
        options.enableDataSwizzling = false
        options.enableFileIOTracing = false
        options.enableTimeToFullDisplayTracing = false
        options.enablePersistingTracesWhenCrashing = false
        options.tracesSampleRate = 0
        options.enableAppHangTracking = true
        options.appHangTimeoutInterval = 4
        options.enableUncaughtNSExceptionReporting = false

        // Opting out should not block the main thread while queued events
        // are flushed. Reports captured before opt-out may still be sent.
        options.shutdownTimeInterval = 0
    }

    func close() {
        SentrySDK.close()
    }
}

@MainActor
final class CrashReportingController {
    private let sdk: any CrashReportingSDKControlling

    init(
        sdk: any CrashReportingSDKControlling =
            SystemSentrySDKController()
    ) {
        self.sdk = sdk
    }

    func setEnabled(_ enabled: Bool) {
        guard enabled != sdk.isEnabled else {
            return
        }
        if enabled {
            sdk.start()
        } else {
            sdk.close()
        }
    }
}

enum CrashReportingLaunchPolicy {
    static func allowsReporting(
        isUITesting: Bool,
        environment: [String: String]
    ) -> Bool {
        !isUITesting
            && environment["XCTestConfigurationFilePath"] == nil
    }
}
