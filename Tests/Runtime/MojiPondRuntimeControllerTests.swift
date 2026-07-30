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

    func testLockStopsMonitorAndUnlockRestartsIt() {
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

        controller.sessionDidLock()
        XCTAssertEqual(controller.state, .sessionLocked)
        XCTAssertFalse(monitor.isRunning)
        XCTAssertEqual(monitor.stopCount, 1)

        controller.sessionDidUnlock()
        XCTAssertEqual(controller.state, .running)
        XCTAssertTrue(monitor.isRunning)
        XCTAssertEqual(monitor.startCount, 2)
        controller.stop()
    }

    func testSecureInputSuspendsAndSameAppRecoveryReturnsToRunning() async {
        let permissions = MutableRuntimePermissionChecker(
            permissions: RuntimePermissionPreflight(
                inputMonitoringGranted: true,
                accessibilityGranted: true
            )
        )
        let monitor = FakeRuntimeEventMonitor()
        let secureInput = MutableRuntimeSecureInputChecker(isEnabled: true)
        let textSystem = FakeAccessibilityTextSystem()
        textSystem.text = ""
        textSystem.selection = NSRange(location: 0, length: 0)
        let item = EmojiItem(
            id: "test.frog",
            shortcode: Shortcode(rawValue: "frog")!,
            name: "frog",
            category: "test",
            content: .unicode(UnicodeEmojiContent(value: "🐸")),
            packID: "test"
        )
        let controller = MojiPondRuntimeController(
            searchIndex: EmojiSearchIndex(items: [item]),
            permissionChecker: permissions,
            secureInputChecker: secureInput,
            applicationIdentity: FixedRuntimeIdentityProvider(),
            presenter: RuntimeLifecyclePresenter(),
            accessibility: AccessibilityTextAdapter(system: textSystem),
            eventMonitor: monitor
        )

        controller.start()

        let suspended = await eventually {
            controller.state == .contextSuspended(.secureEventInput)
        }
        XCTAssertTrue(suspended)

        let permissionChecksAfterSuspension = permissions.checkCount
        try? await Task.sleep(for: .seconds(1.1))
        XCTAssertEqual(
            permissions.checkCount,
            permissionChecksAfterSuspension,
            "Context recovery must use cached permission state"
        )

        secureInput.isEnabled = false
        let recovered = await eventually(timeout: .seconds(2)) {
            controller.state == .running
        }
        XCTAssertTrue(recovered)
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

    private func eventually(
        timeout: Duration = .seconds(1),
        condition: @escaping @MainActor () -> Bool
    ) async -> Bool {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: timeout)
        while clock.now < deadline {
            if condition() {
                return true
            }
            try? await Task.sleep(for: .milliseconds(5))
        }
        return condition()
    }
}

private final class MutableRuntimeSecureInputChecker:
    RuntimeSecureInputChecking,
    @unchecked Sendable
{
    private let lock = NSLock()
    private var storedValue: Bool

    init(isEnabled: Bool) {
        storedValue = isEnabled
    }

    var isEnabled: Bool {
        get { lock.withLock { storedValue } }
        set { lock.withLock { storedValue = newValue } }
    }

    var secureEventInputEnabled: Bool {
        isEnabled
    }
}

private struct FixedRuntimeIdentityProvider:
    RuntimeApplicationIdentityProviding
{
    func bundleIdentifier(for processIdentifier: pid_t) -> String? {
        _ = processIdentifier
        return "com.example.Editor"
    }
}

private final class MutableRuntimePermissionChecker:
    RuntimePermissionChecking,
    @unchecked Sendable
{
    private let lock = NSLock()
    private var storedPermissions: RuntimePermissionPreflight
    private var storedCheckCount = 0

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

    var checkCount: Int {
        lock.withLock {
            storedCheckCount
        }
    }

    func currentPermissions() -> RuntimePermissionPreflight {
        lock.withLock {
            storedCheckCount += 1
            return storedPermissions
        }
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
