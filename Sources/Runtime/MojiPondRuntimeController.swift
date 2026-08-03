import AppKit
import Combine
import CoreGraphics
import Foundation

protocol RuntimeEventMonitoring: AnyObject {
    var isRunning: Bool { get }
    func start() throws
    func stop()
}

extension SessionEventTapService: RuntimeEventMonitoring {}

enum MojiPondRuntimeState: Equatable, Sendable {
    case stopped
    case paused
    case sessionLocked
    case waitingForPermissions
    case contextSuspended(RuntimeSessionDenial)
    case running
    case failed(String)
}

enum MojiPondRuntimeDiagnostic: Equatable, Sendable {
    case eventTapStarted
    case eventTapStopped
    case eventTapCreationFailed
    case eventTapDisabledByTimeout(reenableCount: Int)
    case eventTapDisabledByUserInput(reenableCount: Int)
    case eventTapRepeatedDisablement(totalCount: Int)
    case permissionUnavailable
    case unsupportedTarget
    case clipboardRestoreFailed
    case sendAfterInsertionUnavailable
    case sessionDenied(RuntimeSessionDenial)
    case sessionAllowed
    case catalogLoadFailed(String)
    case startupFailed(String)
}

enum MojiPondRuntimeControllerError: Error, LocalizedError {
    case builtInCatalog(Error)

    var errorDescription: String? {
        switch self {
        case let .builtInCatalog(error):
            "MojiPond could not load its built-in emoji library: \(error.localizedDescription)"
        }
    }
}

private final class MojiPondRuntimeDiagnosticRelay: @unchecked Sendable {
    private let lock = NSLock()
    private var sink:
        (@Sendable (MojiPondRuntimeDiagnostic) -> Void)?

    func setSink(
        _ sink: @escaping @Sendable (MojiPondRuntimeDiagnostic) -> Void
    ) {
        lock.withLock {
            self.sink = sink
        }
    }

    func emit(_ diagnostic: MojiPondRuntimeDiagnostic) {
        let currentSink:
            (@Sendable (MojiPondRuntimeDiagnostic) -> Void)? = lock.withLock {
                self.sink
            }
        currentSink?(diagnostic)
    }
}

private final class MojiPondRuntimeMediaDiagnosticRelay:
    @unchecked Sendable
{
    private let lock = NSLock()
    private var sink:
        (@Sendable (RuntimeMediaCopyFallbackDiagnostic) -> Void)?

    func setSink(
        _ sink: @escaping @Sendable (
            RuntimeMediaCopyFallbackDiagnostic
        ) -> Void
    ) {
        lock.withLock {
            self.sink = sink
        }
    }

    func emit(_ diagnostic: RuntimeMediaCopyFallbackDiagnostic) {
        let currentSink:
            (@Sendable (RuntimeMediaCopyFallbackDiagnostic) -> Void)? =
                lock.withLock {
                    sink
                }
        currentSink?(diagnostic)
    }
}

/// AppDelegate-facing lifecycle for global Unicode autocomplete. Starting this
/// controller performs preflight checks only; permission prompts remain an
/// explicit onboarding/settings action.
@MainActor
final class MojiPondRuntimeController: ObservableObject {
    @Published private(set) var state: MojiPondRuntimeState = .stopped
    @Published private(set) var lastDiagnostic: MojiPondRuntimeDiagnostic?
    @Published private(set) var lastMediaCopyFallback:
        RuntimeMediaCopyFallbackDiagnostic?

    var onDiagnostic: ((MojiPondRuntimeDiagnostic) -> Void)?
    var onMediaCopyFallback:
        ((RuntimeMediaCopyFallbackDiagnostic) -> Void)?

    private let permissionChecker: any RuntimePermissionChecking
    private let cachedPermissions: CachedRuntimePermissionChecker
    private let usageStore: (any EmojiUsageStore)?
    private let interceptionGate: RuntimeInterceptionGate
    private let worker: UnicodeAutocompleteRuntimeWorker
    private let eventTap: any RuntimeEventMonitoring
    private var configuration: UnicodeAutocompleteRuntimeConfiguration
    private var wantsToRun = false
    private var userEnabled = true
    private var contextRecoveryTimer: Timer?
    private var observingWorkspace = false
    private var sessionIsActive = true

    convenience init(
        bundle: Bundle = .main,
        preferences: MojiPondPreferences = .defaults,
        usageStore: (any EmojiUsageStore)? = nil,
        managedMediaRoot: URL? = nil,
        onCatalogLoadError:
            ((MojiPondRuntimeDiagnostic) -> Void)? = nil
    ) throws {
        let searchIndex: EmojiSearchIndex
        do {
            searchIndex = try BuiltInRuntimeCatalogLoader(
                dataProvider: BundleRuntimeCatalogDataProvider(bundle: bundle)
            ).loadSearchIndex()
        } catch {
            onCatalogLoadError?(
                .catalogLoadFailed(error.localizedDescription)
            )
            throw MojiPondRuntimeControllerError.builtInCatalog(error)
        }
        self.init(
            searchIndex: searchIndex,
            preferences: preferences,
            usageStore: usageStore,
            managedMediaRoot: managedMediaRoot
        )
    }

    init(
        searchIndex: EmojiSearchIndex,
        preferences: MojiPondPreferences = .defaults,
        usageStore: (any EmojiUsageStore)? = nil,
        permissionChecker: any RuntimePermissionChecking =
            MacRuntimePermissionChecker(),
        secureInputChecker: any RuntimeSecureInputChecking =
            MacRuntimeSecureInputChecker(),
        applicationIdentity: any RuntimeApplicationIdentityProviding =
            MacRuntimeApplicationIdentityProvider(),
        presenter: (any RuntimeSuggestionPresenting)? = nil,
        accessibility: AccessibilityTextAdapter = AccessibilityTextAdapter(),
        insertionEngine: InsertionEngine? = nil,
        eventMonitor: (any RuntimeEventMonitoring)? = nil,
        managedMediaRoot: URL? = nil,
        managedMediaResolver:
            any RuntimeManagedMediaResolving =
                RuntimeManagedMediaResolver()
    ) {
        let gate = RuntimeInterceptionGate()
        let diagnostics = MojiPondRuntimeDiagnosticRelay()
        let mediaDiagnostics =
            MojiPondRuntimeMediaDiagnosticRelay()
        let resolvedPresenter = presenter
            ?? RuntimeSuggestionPanelController()
        let resolvedInsertionEngine = insertionEngine
            ?? InsertionEngine(accessibility: accessibility)
        let cachedPermissions = CachedRuntimePermissionChecker()
        let bridge = RuntimeMainActorBridge(
            presenter: resolvedPresenter,
            insertionEngine: resolvedInsertionEngine
        )
        let contextProvider = RuntimeAccessibilityTextContextProvider(
            accessibility: accessibility,
            permissionChecker: cachedPermissions,
            secureInputChecker: secureInputChecker,
            applicationIdentity: applicationIdentity,
            exclusions: preferences.exclusions
        )
        let configuration = UnicodeAutocompleteRuntimeConfiguration(
            preferences: preferences
        )
        let worker = UnicodeAutocompleteRuntimeWorker(
            searchIndex: searchIndex,
            configuration: configuration,
            interceptionGate: gate,
            contextProvider: contextProvider,
            mainActorBridge: bridge,
            usageStore: usageStore,
            managedMediaResolver: managedMediaResolver,
            managedMediaRoot: managedMediaRoot,
            diagnosticHandler: {
                [diagnostics, mediaDiagnostics] diagnostic in
                switch diagnostic {
                case .unsupportedTarget:
                    diagnostics.emit(.unsupportedTarget)
                case .clipboardRestoreFailed:
                    diagnostics.emit(.clipboardRestoreFailed)
                case .sendAfterInsertionUnavailable:
                    diagnostics.emit(.sendAfterInsertionUnavailable)
                case let .sessionDenied(denial):
                    diagnostics.emit(.sessionDenied(denial))
                case .sessionAllowed:
                    diagnostics.emit(.sessionAllowed)
                case let .mediaCopyFallbackAvailable(fallback):
                    mediaDiagnostics.emit(fallback)
                }
            }
        )

        self.permissionChecker = permissionChecker
        self.cachedPermissions = cachedPermissions
        self.usageStore = usageStore
        interceptionGate = gate
        self.worker = worker
        self.configuration = configuration
        userEnabled = preferences.activationMode == .enabled
        eventTap = eventMonitor
            ?? SessionEventTapService(
                eventTypes: [
                    .keyDown,
                    .flagsChanged,
                    .leftMouseDown,
                    .rightMouseDown,
                    .otherMouseDown
                ],
                interceptionPolicy: { [gate] snapshot in
                    gate.outcome(for: snapshot)
                },
                eventHandler: { [worker] snapshot in
                    worker.enqueue(snapshot)
                },
                diagnosticHandler: { [worker, diagnostics] diagnostic in
                    if case .repeatedDisablement = diagnostic {
                        worker.reset(.permissionLost)
                    }
                    switch diagnostic {
                    case .started:
                        diagnostics.emit(.eventTapStarted)
                    case .stopped:
                        diagnostics.emit(.eventTapStopped)
                    case .creationFailed:
                        diagnostics.emit(.eventTapCreationFailed)
                    case let .disabledByTimeout(reenableCount):
                        diagnostics.emit(
                            .eventTapDisabledByTimeout(
                                reenableCount: reenableCount
                            )
                        )
                    case let .disabledByUserInput(reenableCount):
                        diagnostics.emit(
                            .eventTapDisabledByUserInput(
                                reenableCount: reenableCount
                            )
                        )
                    case let .repeatedDisablement(totalCount):
                        diagnostics.emit(
                            .eventTapRepeatedDisablement(
                                totalCount: totalCount
                            )
                        )
                    }
                }
            )
        diagnostics.setSink { [weak self] diagnostic in
            Task { @MainActor [weak self] in
                self?.publish(diagnostic)
            }
        }
        mediaDiagnostics.setSink { [weak self] diagnostic in
            Task { @MainActor [weak self] in
                self?.publishMediaCopyFallback(diagnostic)
            }
        }
    }

    func start() {
        guard !wantsToRun else {
            reconcileRuntime()
            return
        }
        wantsToRun = true
        registerWorkspaceObservers()
        contextRecoveryTimer = Timer.scheduledTimer(
            withTimeInterval: 1,
            repeats: true
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.refreshSuspendedContext()
            }
        }
        loadUsageSnapshot()
        reconcileRuntime()
    }

    func stop() {
        wantsToRun = false
        contextRecoveryTimer?.invalidate()
        contextRecoveryTimer = nil
        unregisterWorkspaceObservers()
        eventTap.stop()
        worker.setCaptureEnabled(false)
        interceptionGate.setCaptureEnabled(false)
        state = .stopped
    }

    func setEnabled(_ enabled: Bool) {
        userEnabled = enabled
        reconcileRuntime()
    }

    func updatePreferences(_ preferences: MojiPondPreferences) {
        configuration.preferences = preferences
        worker.updateConfiguration(configuration)
        userEnabled = preferences.activationMode == .enabled
        reconcileRuntime()
    }

    func updateSearchIndex(_ searchIndex: EmojiSearchIndex) {
        worker.updateSearchIndex(searchIndex)
    }

    func openBrowser() {
        worker.openBrowser()
    }

    func reset(reason: ParserResetReason) {
        worker.reset(reason)
    }

    func permissionStateDidChange() {
        reconcileRuntime()
    }

    func reloadUsageSnapshot() {
        loadUsageSnapshot()
    }

    private func reconcileRuntime() {
        guard wantsToRun else {
            return
        }
        guard userEnabled else {
            eventTap.stop()
            worker.setCaptureEnabled(false)
            interceptionGate.setCaptureEnabled(false)
            state = .paused
            return
        }
        guard sessionIsActive else {
            eventTap.stop()
            worker.setCaptureEnabled(false)
            interceptionGate.setCaptureEnabled(false)
            state = .sessionLocked
            return
        }

        let permissions = permissionChecker.currentPermissions()
        cachedPermissions.update(permissions)
        interceptionGate.setCanReplayCommitSend(
            permissions.eventPostingGranted
        )
        guard permissions.canMonitorTyping else {
            eventTap.stop()
            worker.setCaptureEnabled(false)
            interceptionGate.setCaptureEnabled(false)
            if state != .waitingForPermissions {
                publish(.permissionUnavailable)
            }
            state = .waitingForPermissions
            return
        }

        var didStartMonitor = false
        if !eventTap.isRunning {
            do {
                try eventTap.start()
                didStartMonitor = true
            } catch {
                worker.setCaptureEnabled(false)
                interceptionGate.setCaptureEnabled(false)
                state = .failed(error.localizedDescription)
                publish(.startupFailed(error.localizedDescription))
                return
            }
        }
        worker.setCaptureEnabled(true)
        interceptionGate.setCaptureEnabled(true)
        if case .contextSuspended = state {
            worker.refreshContextState()
            return
        }
        state = .running
        if didStartMonitor {
            worker.refreshContextState()
        }
    }

    private func refreshSuspendedContext() {
        guard
            wantsToRun,
            userEnabled,
            sessionIsActive,
            case .contextSuspended = state
        else {
            return
        }
        worker.refreshContextState()
    }

    private func loadUsageSnapshot() {
        guard let usageStore else {
            return
        }
        let worker = worker
        Task {
            guard let snapshot = try? await usageStore.snapshot() else {
                return
            }
            worker.updateUsageSnapshot(snapshot)
        }
    }

    private func publish(_ diagnostic: MojiPondRuntimeDiagnostic) {
        switch diagnostic {
        case let .sessionDenied(denial):
            if sessionIsActive {
                state = denial == .permissionUnavailable
                    ? .waitingForPermissions
                    : .contextSuspended(denial)
            }
        case .sessionAllowed:
            if
                sessionIsActive,
                wantsToRun,
                userEnabled,
                case .contextSuspended = state
            {
                state = .running
            }
        default:
            break
        }
        lastDiagnostic = diagnostic
        onDiagnostic?(diagnostic)
    }

    private func publishMediaCopyFallback(
        _ diagnostic: RuntimeMediaCopyFallbackDiagnostic
    ) {
        lastMediaCopyFallback = diagnostic
        onMediaCopyFallback?(diagnostic)
    }

    private func registerWorkspaceObservers() {
        guard !observingWorkspace else {
            return
        }
        observingWorkspace = true
        let workspaceCenter = NSWorkspace.shared.notificationCenter
        workspaceCenter.addObserver(
            self,
            selector: #selector(frontmostApplicationChanged),
            name: NSWorkspace.didActivateApplicationNotification,
            object: nil
        )
        workspaceCenter.addObserver(
            self,
            selector: #selector(screenOrSessionLocked),
            name: NSWorkspace.sessionDidResignActiveNotification,
            object: nil
        )
        workspaceCenter.addObserver(
            self,
            selector: #selector(screenOrSessionLocked),
            name: NSWorkspace.screensDidSleepNotification,
            object: nil
        )
        workspaceCenter.addObserver(
            self,
            selector: #selector(screenOrSessionUnlocked),
            name: NSWorkspace.sessionDidBecomeActiveNotification,
            object: nil
        )
        workspaceCenter.addObserver(
            self,
            selector: #selector(screenOrSessionUnlocked),
            name: NSWorkspace.screensDidWakeNotification,
            object: nil
        )

        DistributedNotificationCenter.default().addObserver(
            self,
            selector: #selector(screenOrSessionLocked),
            name: Notification.Name("com.apple.screenIsLocked"),
            object: nil
        )
        DistributedNotificationCenter.default().addObserver(
            self,
            selector: #selector(screenOrSessionUnlocked),
            name: Notification.Name("com.apple.screenIsUnlocked"),
            object: nil
        )
    }

    private func unregisterWorkspaceObservers() {
        guard observingWorkspace else {
            return
        }
        observingWorkspace = false
        NSWorkspace.shared.notificationCenter.removeObserver(self)
        DistributedNotificationCenter.default().removeObserver(self)
    }

    @objc
    private func frontmostApplicationChanged(_ notification: Notification) {
        _ = notification
        worker.reset(.applicationChanged)
        worker.refreshContextState()
    }

    @objc
    private func screenOrSessionLocked(_ notification: Notification) {
        _ = notification
        sessionDidLock()
    }

    @objc
    private func screenOrSessionUnlocked(_ notification: Notification) {
        _ = notification
        sessionDidUnlock()
    }

    func sessionDidLock() {
        sessionIsActive = false
        worker.reset(.screenLocked)
        eventTap.stop()
        worker.setCaptureEnabled(false)
        interceptionGate.setCaptureEnabled(false)
        if wantsToRun {
            state = .sessionLocked
        }
    }

    func sessionDidUnlock() {
        sessionIsActive = true
        worker.reset(.externallyCancelled)
        reconcileRuntime()
    }
}
