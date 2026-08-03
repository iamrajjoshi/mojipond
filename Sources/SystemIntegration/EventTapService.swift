import CoreGraphics
import Foundation

enum RuntimeKeyboardKeyCode {
    static let digit3: CGKeyCode = 20
    static let digit4: CGKeyCode = 21
    static let digit6: CGKeyCode = 22
    static let digit5: CGKeyCode = 23
    static let returnKey: CGKeyCode = 36
    static let tab: CGKeyCode = 48
    static let delete: CGKeyCode = 51
    static let escape: CGKeyCode = 53
    static let keypadEnter: CGKeyCode = 76
    static let home: CGKeyCode = 115
    static let pageUp: CGKeyCode = 116
    static let end: CGKeyCode = 119
    static let pageDown: CGKeyCode = 121
    static let leftArrow: CGKeyCode = 123
    static let rightArrow: CGKeyCode = 124
    static let downArrow: CGKeyCode = 125
    static let upArrow: CGKeyCode = 126
}

enum RuntimeInterceptionMode: Equatable, Sendable {
    case hidden
    case suggestions
    case browser
    case media
    case committing
}

struct KeyboardEventSnapshot: Equatable, Sendable {
    let typeRawValue: UInt32
    let keyCode: CGKeyCode
    let flagsRawValue: UInt64
    let timestamp: UInt64
    let characters: String?
    let interceptionOutcome: EventInterceptionOutcome?

    init(
        typeRawValue: UInt32,
        keyCode: CGKeyCode,
        flagsRawValue: UInt64,
        timestamp: UInt64,
        characters: String?,
        interceptionOutcome: EventInterceptionOutcome? = nil
    ) {
        self.typeRawValue = typeRawValue
        self.keyCode = keyCode
        self.flagsRawValue = flagsRawValue
        self.timestamp = timestamp
        self.characters = characters
        self.interceptionOutcome = interceptionOutcome
    }

    var type: CGEventType? {
        CGEventType(rawValue: typeRawValue)
    }

    var flags: CGEventFlags {
        CGEventFlags(rawValue: flagsRawValue)
    }

    func delivered(
        with outcome: EventInterceptionOutcome
    ) -> Self {
        Self(
            typeRawValue: typeRawValue,
            keyCode: keyCode,
            flagsRawValue: flagsRawValue,
            timestamp: timestamp,
            characters: characters,
            interceptionOutcome: outcome
        )
    }
}

enum EventInterceptionDecision: Equatable, Sendable {
    case passThrough
    case intercept
}

struct EventInterceptionOutcome: Equatable, Sendable {
    let decision: EventInterceptionDecision
    let mode: RuntimeInterceptionMode?
    /// Identifies the bounded shortcode prediction that observed this event.
    /// The worker uses it only to verify that an Accessibility capture belongs
    /// to the same event-tap session; it never affects public interception
    /// semantics.
    let predictionGeneration: UInt64?
    /// Identifies the synchronous interaction state that decided this event.
    /// The worker may activate a commit only while this revision is current,
    /// preventing an older queued event from rearming a canceled surface.
    let interactionRevision: UInt64?
    /// Orders event-tap observations independently from UI interaction state.
    /// The worker uses this to keep older search work from hiding a surface
    /// after a newer correction has already been observed.
    let eventRevision: UInt64?
    /// True only for an OS-owned interaction, such as the macOS screenshot
    /// flow, that must pass through without invalidating the active token.
    let preservesAutocompleteContext: Bool

    static let passThrough = Self(
        decision: .passThrough,
        mode: nil,
        predictionGeneration: nil,
        interactionRevision: nil,
        eventRevision: nil,
        preservesAutocompleteContext: false
    )
    static let intercept = Self(
        decision: .intercept,
        mode: nil,
        predictionGeneration: nil,
        interactionRevision: nil,
        eventRevision: nil,
        preservesAutocompleteContext: false
    )

    static func intercepting(
        _ mode: RuntimeInterceptionMode,
        predictionGeneration: UInt64? = nil,
        interactionRevision: UInt64? = nil,
        eventRevision: UInt64? = nil,
        preservesAutocompleteContext: Bool = false
    ) -> Self {
        Self(
            decision: .intercept,
            mode: mode,
            predictionGeneration: predictionGeneration,
            interactionRevision: interactionRevision,
            eventRevision: eventRevision,
            preservesAutocompleteContext: preservesAutocompleteContext
        )
    }

    static func passingThrough(
        predictionGeneration: UInt64?,
        interactionRevision: UInt64? = nil,
        eventRevision: UInt64? = nil,
        preservesAutocompleteContext: Bool = false
    ) -> Self {
        Self(
            decision: .passThrough,
            mode: nil,
            predictionGeneration: predictionGeneration,
            interactionRevision: interactionRevision,
            eventRevision: eventRevision,
            preservesAutocompleteContext: preservesAutocompleteContext
        )
    }

    static func == (
        lhs: EventInterceptionOutcome,
        rhs: EventInterceptionOutcome
    ) -> Bool {
        lhs.decision == rhs.decision && lhs.mode == rhs.mode
    }
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
        @Sendable (KeyboardEventSnapshot) -> EventInterceptionOutcome
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
        interceptionPolicy(snapshot).decision
    }

    @discardableResult
    func process(_ snapshot: KeyboardEventSnapshot) -> EventInterceptionDecision {
        let outcome = interceptionPolicy(snapshot)
        let deliveredSnapshot = snapshot.delivered(with: outcome)
        handlerQueue.async { [eventHandler] in
            eventHandler(deliveredSnapshot)
        }
        return outcome.decision
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

    static func snapshot(
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
            characters: keyboardCharacters(type: type, from: event)
        )
    }

    private static func keyboardCharacters(
        type: CGEventType,
        from event: CGEvent
    ) -> String? {
        guard type == .keyDown else {
            return nil
        }

        var length = 0
        event.keyboardGetUnicodeString(
            maxStringLength: 0,
            actualStringLength: &length,
            unicodeString: nil
        )
        guard length > 0, length <= 64 else {
            return nil
        }

        var units = [UniChar](repeating: 0, count: length)
        var actualLength = 0
        units.withUnsafeMutableBufferPointer { buffer in
            event.keyboardGetUnicodeString(
                maxStringLength: buffer.count,
                actualStringLength: &actualLength,
                unicodeString: buffer.baseAddress
            )
        }
        guard actualLength > 0, actualLength <= units.count else {
            return nil
        }
        return String(utf16CodeUnits: units, count: actualLength)
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
