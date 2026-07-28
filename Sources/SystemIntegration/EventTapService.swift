import CoreGraphics
import Foundation

struct KeyboardEventSnapshot: Equatable, Sendable {
    let typeRawValue: UInt32
    let keyCode: CGKeyCode
    let flagsRawValue: UInt64
    let timestamp: UInt64
    let characters: String?

    var type: CGEventType? {
        CGEventType(rawValue: typeRawValue)
    }

    var flags: CGEventFlags {
        CGEventFlags(rawValue: flagsRawValue)
    }
}

enum EventInterceptionDecision: Equatable, Sendable {
    case passThrough
    case intercept
}

enum EventTapDiagnostic: Equatable, Sendable {
    case started
    case stopped
    case creationFailed
    case disabledByTimeout(reenableCount: Int)
    case disabledByUserInput(reenableCount: Int)
    case repeatedDisablement(totalCount: Int)
}

struct EventTapDiagnosticSnapshot: Equatable, Sendable {
    let timeoutDisablements: Int
    let userInputDisablements: Int
    let reenablements: Int
}

enum EventTapServiceError: Error, Equatable {
    case alreadyRunning
    case couldNotCreateTap
    case couldNotCreateRunLoopSource
}

/// A session event tap whose callback only snapshots the keyboard event, checks
/// MojiPond's recursion tag, and asks a serial handler whether to intercept it.
///
/// The supplied handler must be constant-time. Accessibility, storage, search,
/// media decoding, and UI work belong in work enqueued by that handler.
final class SessionEventTapService: @unchecked Sendable {
    typealias InterceptionPolicy =
        @Sendable (KeyboardEventSnapshot) -> EventInterceptionDecision
    typealias EventHandler = @Sendable (KeyboardEventSnapshot) -> Void
    typealias DiagnosticHandler = @Sendable (EventTapDiagnostic) -> Void

    /// An arbitrary nonzero marker kept private to the local event source field.
    static let syntheticEventTag: Int64 = 0x4D_6F_6A_69_50_6F_6E_64

    private let handlerQueue: DispatchQueue
    private let diagnosticQueue: DispatchQueue
    private let interceptionPolicy: InterceptionPolicy
    private let eventHandler: EventHandler
    private let diagnosticHandler: DiagnosticHandler?
    private let eventMask: CGEventMask
    private let lock = NSLock()

    private var eventTap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?
    private var workerRunLoop: CFRunLoop?
    private var workerThread: Thread?
    private var shutdownSignal: DispatchSemaphore?
    private var startupInProgress = false
    private var stopRequested = false
    private var timeoutDisablements = 0
    private var userInputDisablements = 0
    private var reenablements = 0

    init(
        label: String = "com.rajjoshi.MojiPond.event-tap",
        eventTypes: Set<CGEventType> = [.keyDown, .flagsChanged],
        diagnosticQueue: DispatchQueue = .main,
        interceptionPolicy: @escaping InterceptionPolicy = { _ in .passThrough },
        eventHandler: @escaping EventHandler,
        diagnosticHandler: DiagnosticHandler? = nil
    ) {
        handlerQueue = DispatchQueue(label: "\(label).handler", qos: .userInteractive)
        self.diagnosticQueue = diagnosticQueue
        self.interceptionPolicy = interceptionPolicy
        self.eventHandler = eventHandler
        self.diagnosticHandler = diagnosticHandler
        eventMask = eventTypes.reduce(CGEventMask(0)) { mask, eventType in
            mask | (CGEventMask(1) << eventType.rawValue)
        }
    }

    var isRunning: Bool {
        lock.withLock {
            eventTap != nil || startupInProgress
        }
    }

    var diagnostics: EventTapDiagnosticSnapshot {
        lock.withLock {
            EventTapDiagnosticSnapshot(
                timeoutDisablements: timeoutDisablements,
                userInputDisablements: userInputDisablements,
                reenablements: reenablements
            )
        }
    }

    func start() throws {
        let mayStart = lock.withLock { () -> Bool in
            guard eventTap == nil, !startupInProgress else {
                return false
            }
            startupInProgress = true
            stopRequested = false
            return true
        }
        guard mayStart else {
            throw EventTapServiceError.alreadyRunning
        }

        let startup = EventTapStartupSignal()
        let shutdown = DispatchSemaphore(value: 0)
        let thread = Thread { [weak self, startup, shutdown] in
            self?.runEventTap(startup: startup, shutdown: shutdown)
        }
        lock.withLock {
            workerThread = thread
            shutdownSignal = shutdown
        }
        thread.name = "com.rajjoshi.MojiPond.event-tap.run-loop"
        thread.qualityOfService = .userInteractive
        thread.start()

        startup.wait()
        if let error = startup.error {
            throw error
        }
    }

    func stop() {
        let state = lock.withLock {
            stopRequested = true
            return (
                workerRunLoop,
                workerThread,
                shutdownSignal,
                startupInProgress
            )
        }
        guard state.0 != nil || state.3 else {
            return
        }
        if let runLoop = state.0 {
            CFRunLoopStop(runLoop)
            CFRunLoopWakeUp(runLoop)
        }
        if state.1 !== Thread.current {
            _ = state.2?.wait(timeout: .now() + 2)
        }
    }

    deinit {
        stop()
    }

    static func isSyntheticEvent(_ event: CGEvent) -> Bool {
        event.getIntegerValueField(.eventSourceUserData) == syntheticEventTag
    }

    static func tagAsSynthetic(_ event: CGEvent) {
        event.setIntegerValueField(
            .eventSourceUserData,
            value: syntheticEventTag
        )
    }

    private static let callback: CGEventTapCallBack = {
        proxy,
        type,
        event,
        userInfo
    in
        guard let userInfo else {
            return Unmanaged.passUnretained(event)
        }
        let service = Unmanaged<SessionEventTapService>
            .fromOpaque(userInfo)
            .takeUnretainedValue()
        return service.handleTapEvent(proxy: proxy, type: type, event: event)
    }

    private func runEventTap(
        startup: EventTapStartupSignal,
        shutdown: DispatchSemaphore
    ) {
        let opaqueSelf = Unmanaged.passUnretained(self).toOpaque()
        guard let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,
            eventsOfInterest: eventMask,
            callback: Self.callback,
            userInfo: opaqueSelf
        ) else {
            lock.withLock {
                startupInProgress = false
                stopRequested = false
                workerThread = nil
                shutdownSignal = nil
            }
            emitDiagnostic(.creationFailed)
            startup.complete(with: .couldNotCreateTap)
            shutdown.signal()
            return
        }
        guard let source = CFMachPortCreateRunLoopSource(nil, tap, 0) else {
            CFMachPortInvalidate(tap)
            lock.withLock {
                startupInProgress = false
                stopRequested = false
                workerThread = nil
                shutdownSignal = nil
            }
            startup.complete(with: .couldNotCreateRunLoopSource)
            shutdown.signal()
            return
        }

        let runLoop = CFRunLoopGetCurrent()
        let shouldStop = lock.withLock { () -> Bool in
            eventTap = tap
            runLoopSource = source
            workerRunLoop = runLoop
            startupInProgress = false
            return stopRequested
        }
        CFRunLoopAddSource(runLoop, source, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
        startup.complete(with: nil)
        emitDiagnostic(.started)

        if !shouldStop {
            CFRunLoopRun()
        }

        CGEvent.tapEnable(tap: tap, enable: false)
        CFRunLoopRemoveSource(runLoop, source, .commonModes)
        CFMachPortInvalidate(tap)
        lock.withLock {
            eventTap = nil
            runLoopSource = nil
            workerRunLoop = nil
            workerThread = nil
            shutdownSignal = nil
            stopRequested = false
        }
        emitDiagnostic(.stopped)
        shutdown.signal()
    }

    private func handleTapEvent(
        proxy: CGEventTapProxy,
        type: CGEventType,
        event: CGEvent
    ) -> Unmanaged<CGEvent>? {
        _ = proxy
        if type == .tapDisabledByTimeout {
            reenable(after: .timeout)
            return Unmanaged.passUnretained(event)
        }
        if type == .tapDisabledByUserInput {
            reenable(after: .userInput)
            return Unmanaged.passUnretained(event)
        }
        if Self.isSyntheticEvent(event) {
            return Unmanaged.passUnretained(event)
        }

        let snapshot = Self.snapshot(type: type, event: event)
        let decision = process(snapshot)
        switch decision {
        case .passThrough:
            return Unmanaged.passUnretained(event)
        case .intercept:
            return nil
        }
    }

    private enum DisablementReason {
        case timeout
        case userInput
    }

    func interceptionDecision(
        for snapshot: KeyboardEventSnapshot
    ) -> EventInterceptionDecision {
        interceptionPolicy(snapshot)
    }

    @discardableResult
    func process(_ snapshot: KeyboardEventSnapshot) -> EventInterceptionDecision {
        let decision = interceptionDecision(for: snapshot)
        handlerQueue.async { [eventHandler] in
            eventHandler(snapshot)
        }
        return decision
    }

    func simulateDisablementForTesting(timedOut: Bool) {
        reenable(after: timedOut ? .timeout : .userInput)
    }

    private func reenable(after reason: DisablementReason) {
        let result = lock.withLock { () -> (CFMachPort?, EventTapDiagnostic, Int) in
            switch reason {
            case .timeout:
                timeoutDisablements += 1
            case .userInput:
                userInputDisablements += 1
            }
            reenablements += 1
            let diagnostic: EventTapDiagnostic = switch reason {
            case .timeout:
                .disabledByTimeout(reenableCount: reenablements)
            case .userInput:
                .disabledByUserInput(reenableCount: reenablements)
            }
            return (
                eventTap,
                diagnostic,
                timeoutDisablements + userInputDisablements
            )
        }
        if let tap = result.0 {
            CGEvent.tapEnable(tap: tap, enable: true)
        }
        emitDiagnostic(result.1)
        if result.2 >= 3 {
            emitDiagnostic(.repeatedDisablement(totalCount: result.2))
        }
    }

    private static func snapshot(
        type: CGEventType,
        event: CGEvent
    ) -> KeyboardEventSnapshot {
        KeyboardEventSnapshot(
            typeRawValue: type.rawValue,
            keyCode: CGKeyCode(
                event.getIntegerValueField(.keyboardEventKeycode)
            ),
            flagsRawValue: event.flags.rawValue,
            timestamp: event.timestamp,
            characters: keyboardCharacters(from: event)
        )
    }

    private static func keyboardCharacters(from event: CGEvent) -> String? {
        var length = 0
        event.keyboardGetUnicodeString(
            maxStringLength: 0,
            actualStringLength: &length,
            unicodeString: nil
        )
        guard length > 0 else {
            return nil
        }

        var units = [UniChar](repeating: 0, count: length)
        event.keyboardGetUnicodeString(
            maxStringLength: units.count,
            actualStringLength: &length,
            unicodeString: &units
        )
        return String(utf16CodeUnits: units, count: length)
    }

    private func emitDiagnostic(_ diagnostic: EventTapDiagnostic) {
        guard let diagnosticHandler else {
            return
        }
        diagnosticQueue.async {
            diagnosticHandler(diagnostic)
        }
    }
}

private final class EventTapStartupSignal: @unchecked Sendable {
    let semaphore = DispatchSemaphore(value: 0)
    private let lock = NSLock()
    private var storedError: EventTapServiceError?

    var error: EventTapServiceError? {
        lock.withLock {
            storedError
        }
    }

    func complete(with error: EventTapServiceError?) {
        lock.withLock {
            storedError = error
        }
        semaphore.signal()
    }

    func wait() {
        semaphore.wait()
    }
}
