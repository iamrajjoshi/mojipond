import XCTest
@testable import MojiPond

@MainActor
final class MojiPondRuntimeControllerTests: XCTestCase {
    func testLifecycleStartsStopsAndPausesInjectedMonitor() {
        let permissions = MutableRuntimePermissionChecker(
            permissions: RuntimePermissionPreflight(
                inputMonitoringGranted: true,
                accessibilityGranted: true
            )
        )
        let monitor = FakeRuntimeEventMonitor()
        let controller = makeController(
            permissions: permissions,
            monitor: monitor
        )

        controller.start()
        XCTAssertEqual(controller.state, .running)
        XCTAssertEqual(monitor.startCount, 1)

        controller.setEnabled(false)
        XCTAssertEqual(controller.state, .paused)
        XCTAssertEqual(monitor.stopCount, 1)

        controller.setEnabled(true)
        XCTAssertEqual(controller.state, .running)
        XCTAssertEqual(monitor.startCount, 2)

        controller.stop()
        XCTAssertEqual(controller.state, .stopped)
        XCTAssertEqual(monitor.stopCount, 2)
    }

    func testPermissionLifecycleWaitsWithoutPromptThenStartsOnHook() {
        let permissions = MutableRuntimePermissionChecker(
            permissions: RuntimePermissionPreflight(
                inputMonitoringGranted: false,
                accessibilityGranted: false
            )
        )
        let monitor = FakeRuntimeEventMonitor()
        let controller = makeController(
            permissions: permissions,
            monitor: monitor
        )

        controller.start()

        XCTAssertEqual(controller.state, .waitingForPermissions)
        XCTAssertEqual(
            controller.lastDiagnostic,
            .permissionUnavailable
        )
        XCTAssertEqual(monitor.startCount, 0)

        permissions.permissions = RuntimePermissionPreflight(
            inputMonitoringGranted: true,
            accessibilityGranted: true
        )
        controller.permissionStateDidChange()

        XCTAssertEqual(controller.state, .running)
        XCTAssertEqual(monitor.startCount, 1)
        controller.reset(reason: .applicationChanged)
        controller.stop()
    }

    private func makeController(
        permissions: MutableRuntimePermissionChecker,
        monitor: FakeRuntimeEventMonitor
    ) -> MojiPondRuntimeController {
        let item = EmojiItem(
            id: "test.frog",
            shortcode: Shortcode(rawValue: "frog")!,
            name: "frog",
            category: "test",
            content: .unicode(UnicodeEmojiContent(value: "🐸")),
            packID: "test"
        )
        return MojiPondRuntimeController(
            searchIndex: EmojiSearchIndex(items: [item]),
            permissionChecker: permissions,
            presenter: RuntimeLifecyclePresenter(),
            eventMonitor: monitor
        )
    }
}

private final class MutableRuntimePermissionChecker:
    RuntimePermissionChecking,
    @unchecked Sendable
{
    private let lock = NSLock()
    private var storedPermissions: RuntimePermissionPreflight

    init(permissions: RuntimePermissionPreflight) {
        storedPermissions = permissions
    }

    var permissions: RuntimePermissionPreflight {
        get {
            lock.withLock {
                storedPermissions
            }
        }
        set {
            lock.withLock {
                storedPermissions = newValue
            }
        }
    }

    func currentPermissions() -> RuntimePermissionPreflight {
        permissions
    }
}

private final class FakeRuntimeEventMonitor: RuntimeEventMonitoring {
    private(set) var isRunning = false
    private(set) var startCount = 0
    private(set) var stopCount = 0

    func start() throws {
        startCount += 1
        isRunning = true
    }

    func stop() {
        if isRunning {
            stopCount += 1
        }
        isRunning = false
    }
}

@MainActor
private final class RuntimeLifecyclePresenter: RuntimeSuggestionPresenting {
    func apply(_ update: RuntimeSuggestionPanelUpdate) {
        _ = update
    }
}
