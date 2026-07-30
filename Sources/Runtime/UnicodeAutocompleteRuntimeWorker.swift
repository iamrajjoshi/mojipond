import CoreGraphics
import Foundation
import UniformTypeIdentifiers

enum UnicodeAutocompleteRuntimeDiagnostic: Equatable, Sendable {
    case unsupportedTarget
    case clipboardRestoreFailed
    case sessionDenied(RuntimeSessionDenial)
    case sessionAllowed
    case mediaCopyFallbackAvailable(
        RuntimeMediaCopyFallbackDiagnostic
    )
}

struct UnicodeAutocompleteRuntimeConfiguration: Equatable, Sendable {
    var preferences: MojiPondPreferences
    var suggestionLimit: Int
    var accessibilitySettleDelayMilliseconds: Int
    var accessibilityRetryLimit: Int
    var mediaSearchDebounceMilliseconds: Int
    var mediaResultLimit: Int
    var mediaInactivityTimeoutMilliseconds: Int

    init(
        preferences: MojiPondPreferences = .defaults,
        suggestionLimit: Int = 5,
        accessibilitySettleDelayMilliseconds: Int = 12,
        accessibilityRetryLimit: Int = 2,
        mediaSearchDebounceMilliseconds: Int = 140,
        mediaResultLimit: Int = 12,
        mediaInactivityTimeoutMilliseconds: Int = 8_000
    ) {
        self.preferences = preferences
        self.suggestionLimit = min(max(1, suggestionLimit), 5)
        self.accessibilitySettleDelayMilliseconds = min(
            max(0, accessibilitySettleDelayMilliseconds),
            100
        )
        self.accessibilityRetryLimit = min(max(0, accessibilityRetryLimit), 4)
        self.mediaSearchDebounceMilliseconds = min(
            max(0, mediaSearchDebounceMilliseconds),
            1_000
        )
        self.mediaResultLimit = min(max(4, mediaResultLimit), 24)
        self.mediaInactivityTimeoutMilliseconds = min(
            max(100, mediaInactivityTimeoutMilliseconds),
            60_000
        )
    }
}

@MainActor
final class RuntimeMainActorBridge {
    private let presenter: any RuntimeSuggestionPresenting
    private let insertionEngine: InsertionEngine
    private let presentationDelayMilliseconds: Int

    init(
        presenter: any RuntimeSuggestionPresenting,
        insertionEngine: InsertionEngine,
        presentationDelayMilliseconds: Int = 0
    ) {
        self.presenter = presenter
        self.insertionEngine = insertionEngine
        self.presentationDelayMilliseconds = max(
            0,
            presentationDelayMilliseconds
        )
    }

    func apply(_ update: RuntimeSuggestionPanelUpdate) {
        presenter.apply(update)
    }

    func applyMedia(_ update: RuntimeMediaPanelUpdate) {
        presenter.applyMedia(update)
    }

    func applyReportingVisibility(
        _ update: RuntimeSuggestionPanelUpdate
    ) async -> Bool {
        await waitForPresentationDelay()
        return presenter.applyReportingVisibility(update)
    }

    func applyMediaReportingVisibility(
        _ update: RuntimeMediaPanelUpdate
    ) async -> Bool {
        await waitForPresentationDelay()
        return presenter.applyMediaReportingVisibility(update)
    }

    private func waitForPresentationDelay() async {
        guard presentationDelayMilliseconds > 0 else {
            return
        }
        try? await Task.sleep(
            for: .milliseconds(presentationDelayMilliseconds)
        )
    }

    func insertUnicode(
        value: String,
        replacing request: AccessibilityReplacementRequest
    ) async -> InsertionResult {
        await insertionEngine.insert(
            .unicode(value),
            replacing: request
        )
    }

    func insertDownloadedMedia(
        _ payload: PasteboardItemPayload,
        replacing request: AccessibilityReplacementRequest
    ) async -> InsertionResult {
        await insertionEngine.insert(
            .media(payload),
            replacing: request
        )
    }
}

/// Owns every mutable parser/search/session value on one serial queue. Event-tap
/// handlers only enqueue immutable snapshots into this object.
final class UnicodeAutocompleteRuntimeWorker: @unchecked Sendable {
    private enum CapturePurpose: Sendable {
        case establishSession
        case showSuggestions
        case showBrowser
        case insert(item: EmojiItem)
    }

    private enum MediaCapturePurpose: Sendable {
        case search(query: String)
        case insert(result: MediaCommandResult)
        case validationFailure
    }

    private struct ActiveTransaction: @unchecked Sendable {
        let transactionID: ParserTransactionID
        var sessionTarget: AccessibilityTextTarget?
        var expectedToken: String
        var caretBounds: CGRect?
        var results: [EmojiSearchResult]
        var presentationRows: [RuntimeSuggestionRow]
        var selectedIndex: Int
        var visibleMode: RuntimeInterceptionMode
        var browserQuery: String
        var captureGeneration: UInt64
        var activityRevision: UInt64
        var bundleIdentifier: String?
    }

    private struct ActiveMediaTransaction: @unchecked Sendable {
        let generation: UInt64
        var sessionTarget: AccessibilityTextTarget?
        var expectedToken: String
        var caretBounds: CGRect?
        var command: MediaCommandKind
        var panelState: RuntimeMediaPanelState
        var results: [MediaCommandResult]
        var grid: MediaCommandGrid
        var attributions: [MediaCommandAttribution]
        var captureGeneration: UInt64
        var activityRevision: UInt64
        var isVisible: Bool
    }

    private let queue: DispatchQueue
    private let managedMediaResolutionQueue: DispatchQueue
    private let interceptionGate: RuntimeInterceptionGate
    private let contextProvider: any RuntimeTextContextCapturing
    private let mainActorBridge: RuntimeMainActorBridge
    private let usageStore: (any EmojiUsageStore)?
    private let frontmostApplication:
        any RuntimeFrontmostApplicationProviding
    private let managedMediaResolver: any RuntimeManagedMediaResolving
    private let managedMediaPayloadBuilder:
        @Sendable (RuntimeResolvedManagedMedia) -> PasteboardItemPayload
    private let adaptiveGlyphPayloadService: AdaptiveGlyphPayloadService
    private let mediaCommandCoordinator:
        (any RuntimeMediaCommandCoordinating)?
    private let remoteMediaCache:
        (any RuntimeRemoteMediaCaching)?
    private let diagnosticHandler:
        (@Sendable (UnicodeAutocompleteRuntimeDiagnostic) -> Void)?

    private var parser: ShortcodeParser
    private var mediaParser = MediaCommandParser()
    private var searchIndex: EmojiSearchIndex
    private var usageSnapshot: EmojiUsageSnapshot
    private var configuration: UnicodeAutocompleteRuntimeConfiguration
    private var activeTransaction: ActiveTransaction?
    private var activeMediaTransaction: ActiveMediaTransaction?
    private var mediaOperation: Task<Void, Never>?
    private var mediaGeneration: UInt64 = 0
    private var managedMediaRoot: URL?
    private var mediaNetworkOptions: MediaCommandNetworkOptions
    private var captureEnabled = false
    private var uiRevision: UInt64 = 0

    init(
        searchIndex: EmojiSearchIndex,
        configuration: UnicodeAutocompleteRuntimeConfiguration,
        interceptionGate: RuntimeInterceptionGate,
        contextProvider: any RuntimeTextContextCapturing,
        mainActorBridge: RuntimeMainActorBridge,
        usageStore: (any EmojiUsageStore)? = nil,
        frontmostApplication:
            any RuntimeFrontmostApplicationProviding =
                MacRuntimeFrontmostApplicationProvider(),
        managedMediaResolver:
            any RuntimeManagedMediaResolving =
                RuntimeManagedMediaResolver(),
        managedMediaRoot: URL? = nil,
        adaptiveGlyphPayloadService:
            AdaptiveGlyphPayloadService = .shared,
        managedMediaPayloadBuilder:
            @escaping @Sendable (RuntimeResolvedManagedMedia) ->
                PasteboardItemPayload = { $0.pasteboardPayload },
        mediaCommandCoordinator:
            (any RuntimeMediaCommandCoordinating)? = nil,
        remoteMediaCache:
            (any RuntimeRemoteMediaCaching)? = nil,
        initialUsageSnapshot: EmojiUsageSnapshot = EmojiUsageSnapshot(),
        diagnosticHandler:
            (@Sendable (UnicodeAutocompleteRuntimeDiagnostic) -> Void)? = nil,
        queueLabel: String = "com.rajjoshi.MojiPond.autocomplete-runtime"
    ) {
        self.searchIndex = searchIndex
        self.configuration = configuration
        self.interceptionGate = interceptionGate
        self.contextProvider = contextProvider
        self.mainActorBridge = mainActorBridge
        self.usageStore = usageStore
        self.frontmostApplication = frontmostApplication
        self.managedMediaResolver = managedMediaResolver
        self.managedMediaPayloadBuilder = managedMediaPayloadBuilder
        self.managedMediaRoot = managedMediaRoot?
            .standardizedFileURL
            .resolvingSymlinksInPath()
        self.adaptiveGlyphPayloadService = adaptiveGlyphPayloadService
        self.mediaCommandCoordinator = mediaCommandCoordinator
        self.remoteMediaCache = remoteMediaCache
        self.diagnosticHandler = diagnosticHandler
        usageSnapshot = initialUsageSnapshot
        mediaNetworkOptions = MediaCommandNetworkOptions(
            preferences: configuration.preferences.network
        )
        parser = ShortcodeParser(
            configuration: ShortcodeParserConfiguration(
                preferences: configuration.preferences.shortcode
            )
        )
        queue = DispatchQueue(label: queueLabel, qos: .userInteractive)
        managedMediaResolutionQueue = DispatchQueue(
            label: "\(queueLabel).managed-media-resolution",
            qos: .userInitiated
        )
    }

    func enqueue(_ snapshot: KeyboardEventSnapshot) {
        queue.async { [weak self] in
            self?.process(snapshot)
        }
    }

    func setCaptureEnabled(_ enabled: Bool) {
        queue.async { [weak self] in
            guard let self else {
                return
            }
            captureEnabled = enabled
            interceptionGate.setCaptureEnabled(enabled)
            if !enabled {
                cancelAllTransactions(reason: .permissionLost)
            }
        }
    }

    func updateConfiguration(
        _ configuration: UnicodeAutocompleteRuntimeConfiguration
    ) {
        queue.async { [weak self] in
            guard let self else {
                return
            }
            self.configuration = configuration
            parser.configuration = ShortcodeParserConfiguration(
                preferences: configuration.preferences.shortcode
            )
            contextProvider.updateExclusions(
                configuration.preferences.exclusions
            )
            mediaNetworkOptions = MediaCommandNetworkOptions(
                preferences: configuration.preferences.network
            )
            cancelAllTransactions(reason: .externallyCancelled)
        }
    }

    func updateSearchIndex(_ searchIndex: EmojiSearchIndex) {
        queue.async { [weak self] in
            guard let self else {
                return
            }
            self.searchIndex = searchIndex
            cancelAllTransactions(reason: .externallyCancelled)
        }
    }

    func updateManagedMediaRoot(_ root: URL?) {
        queue.async { [weak self] in
            guard let self else {
                return
            }
            managedMediaRoot = root?
                .standardizedFileURL
                .resolvingSymlinksInPath()
            cancelAllTransactions(reason: .externallyCancelled)
        }
    }

    func updateMediaNetworkOptions(
        _ options: MediaCommandNetworkOptions
    ) {
        queue.async { [weak self] in
            guard let self else {
                return
            }
            mediaNetworkOptions = options
            cancelMediaTransaction(showCancelled: false)
        }
    }

    func updateUsageSnapshot(_ usageSnapshot: EmojiUsageSnapshot) {
        queue.async { [weak self] in
            self?.usageSnapshot = usageSnapshot
        }
    }

    func reset(_ reason: ParserResetReason) {
        queue.async { [weak self] in
            self?.cancelAllTransactions(reason: reason)
        }
    }

    func openBrowser() {
        queue.async { [weak self] in
            guard let self, captureEnabled else {
                return
            }
            cancelAllTransactions(reason: .externallyCancelled)
            let transition = parser.handle(
                .character(configuration.preferences.shortcode.trigger.character)
            )
            handle(transition.actions)
            let closing = parser.handle(
                .character(configuration.preferences.shortcode.trigger.character)
            )
            guard
                let browserAction = closing.actions.first(where: { action in
                    if case .openBrowser = action {
                        return true
                    }
                    return false
                }),
                case let .openBrowser(transactionID, _) = browserAction
            else {
                cancelCurrentTransaction(reason: .externallyCancelled)
                return
            }
            showBrowser(
                transactionID: transactionID,
                expectedToken: ""
            )
        }
    }

    func refreshContextState() {
        queue.async { [weak self] in
            guard let self, captureEnabled else {
                return
            }
            do {
                _ = try contextProvider.capture(
                    expectedToken: "",
                    trigger: configuration.preferences.shortcode.trigger.character
                )
                diagnosticHandler?(.sessionAllowed)
            } catch let error as RuntimeTextCaptureError {
                if case .denied = error {
                    emitDiagnostic(for: error)
                }
            } catch {
                return
            }
        }
    }

    private func process(_ snapshot: KeyboardEventSnapshot) {
        guard captureEnabled else {
            return
        }
        let action = RuntimeKeyboardEventMapper.action(for: snapshot)
        let interceptionOutcome = snapshot.interceptionOutcome
            ?? interceptionGate.outcome(for: snapshot)

        if activeMediaTransaction?.isVisible == true {
            if interceptionOutcome.mode == .media {
                if handleMediaGridKey(snapshot) {
                    return
                }
            } else if isMediaSurfaceKey(snapshot) {
                cancelMediaTransaction(showCancelled: false)
                return
            }
        }

        let activeBundleIdentifier =
            frontmostApplication.bundleIdentifier()
        if processMediaParser(
            action: action,
            snapshot: snapshot,
            bundleIdentifier: activeBundleIdentifier
        ) {
            return
        }

        if activeTransaction?.visibleMode == .browser {
            if interceptionOutcome.mode == .browser {
                if handleBrowserAction(action) {
                    return
                }
            } else if isBrowserSurfaceAction(action) {
                cancelCurrentTransaction(reason: .externallyCancelled)
                return
            }
        }

        if activeTransaction?.visibleMode == .suggestions,
           interceptionOutcome.mode != .suggestions,
           isSuggestionSurfaceAction(action) {
            cancelCurrentTransaction(reason: .externallyCancelled)
            return
        }

        if case let .reset(reason) = action {
            cancelCurrentTransaction(reason: reason)
            return
        }

        if case let .navigation(_, modifiers) = action,
           activeTransaction?.visibleMode != .suggestions,
           !modifiers.containsNavigationModifier {
            cancelCurrentTransaction(reason: .cursorMoved)
            return
        }

        guard let input = parserInput(for: action) else {
            return
        }
        let transition = parser.handle(input)
        handle(transition.actions)
    }

    private func isSuggestionSurfaceAction(
        _ action: RuntimeKeyboardAction
    ) -> Bool {
        switch action {
        case let .navigation(key, modifiers):
            guard !modifiers.containsNavigationModifier else {
                return false
            }
            switch key {
            case .arrowUp, .arrowDown:
                return true
            case .tab:
                return configuration.preferences.shortcode.acceptsTab
            case .returnKey:
                return configuration.preferences.shortcode.acceptsReturn
            }
        case .escape:
            return true
        case .character, .backspace, .reset, .ignore:
            return false
        }
    }

    private func isBrowserSurfaceAction(
        _ action: RuntimeKeyboardAction
    ) -> Bool {
        switch action {
        case .navigation, .escape, .reset, .backspace:
            return true
        case let .character(character, _):
            return EmojiAliasSyntax.isValidToken(String(character))
        case .ignore:
            return false
        }
    }

    private func isMediaSurfaceKey(
        _ snapshot: KeyboardEventSnapshot
    ) -> Bool {
        guard snapshot.type == .keyDown else {
            return false
        }
        switch snapshot.keyCode {
        case RuntimeKeyboardKeyCode.leftArrow,
             RuntimeKeyboardKeyCode.rightArrow,
             RuntimeKeyboardKeyCode.upArrow,
             RuntimeKeyboardKeyCode.downArrow,
             RuntimeKeyboardKeyCode.tab,
             RuntimeKeyboardKeyCode.returnKey,
             RuntimeKeyboardKeyCode.keypadEnter,
             RuntimeKeyboardKeyCode.escape:
            return true
        default:
            return false
        }
    }

    private func processMediaParser(
        action: RuntimeKeyboardAction,
        snapshot: KeyboardEventSnapshot,
        bundleIdentifier: String?
    ) -> Bool {
        let input: MediaCommandParserInput
        switch action {
        case let .character(character, _):
            input = .text(String(character))
        case .backspace:
            input = .backspace
        case .escape:
            input = .escape
        case .reset:
            input = .contextInvalidated
        case .navigation, .ignore:
            return false
        }

        let mediaAction = mediaParser.consume(
            MediaCommandParserEvent(
                input: input,
                bundleIdentifier: bundleIdentifier,
                timestamp: Double(snapshot.timestamp) / 1_000_000_000,
                modifiers: mediaModifiers(from: snapshot.flags)
            )
        )
        switch mediaAction {
        case .none, .recognized, .limitReached:
            return false
        case .cancelled:
            if activeMediaTransaction != nil {
                cancelMediaTransaction(showCancelled: false)
            }
            return false
        case let .queryChanged(command, query):
            guard let expectedToken = mediaParser.renderedToken else {
                cancelMediaTransaction(showCancelled: false)
                return true
            }
            if query.isEmpty {
                suspendMediaTransactionKeepingParser()
                return true
            }
            guard
                expectedToken.utf16.count
                    <= AccessibilityTextAdapter
                        .maximumShortcodeContextLength
            else {
                showMediaValidationFailure(
                    command: command,
                    expectedToken: expectedToken
                )
                return true
            }
            beginMediaSearch(
                command: command,
                query: query,
                expectedToken: expectedToken
            )
            return true
        }
    }

    private func mediaModifiers(
        from flags: CGEventFlags
    ) -> MediaCommandModifierFlags {
        var modifiers: MediaCommandModifierFlags = []
        if flags.contains(.maskCommand) {
            modifiers.insert(.command)
        }
        if flags.contains(.maskControl) {
            modifiers.insert(.control)
        }
        if flags.contains(.maskAlternate) {
            modifiers.insert(.option)
        }
        if flags.contains(.maskShift) {
            modifiers.insert(.shift)
        }
        return modifiers
    }

    private func parserInput(
        for action: RuntimeKeyboardAction
    ) -> ShortcodeParserInput? {
        switch action {
        case let .character(character, modifiers):
            .character(character, modifiers: modifiers)
        case let .backspace(modifiers):
            .backspace(modifiers: modifiers)
        case let .navigation(key, modifiers):
            .navigation(key, modifiers: modifiers)
        case .escape:
            .escape
        case let .reset(reason):
            .reset(reason)
        case .ignore:
            nil
        }
    }

    private func handleBrowserAction(_ action: RuntimeKeyboardAction) -> Bool {
        guard
            let transaction = activeTransaction,
            transaction.visibleMode == .browser
        else {
            return false
        }

        switch action {
        case let .navigation(key, modifiers):
            guard !modifiers.containsNavigationModifier else {
                cancelCurrentTransaction(reason: .unsupportedModifiers)
                return true
            }
            switch key {
            case .arrowUp:
                moveSelection(transactionID: transaction.transactionID, delta: -1)
            case .arrowDown:
                moveSelection(transactionID: transaction.transactionID, delta: 1)
            case .tab, .returnKey:
                acceptCurrentSelection(transactionID: transaction.transactionID)
            }
            return true
        case .escape:
            cancelCurrentTransaction(reason: .escape)
            return true
        case let .reset(reason):
            cancelCurrentTransaction(reason: reason)
            return true
        case let .character(character, modifiers):
            guard !modifiers.containsUnsupportedTypingModifier else {
                cancelCurrentTransaction(reason: .unsupportedModifiers)
                return true
            }
            guard EmojiAliasSyntax.isValidToken(String(character)) else {
                cancelCurrentTransaction(
                    reason: .invalidCharacter(character)
                )
                return false
            }
            guard
                transaction.browserQuery.utf8.count
                    < Shortcode.maximumLength
            else {
                return true
            }
            updateBrowserQuery(
                transactionID: transaction.transactionID,
                query: transaction.browserQuery
                    + EmojiAliasSyntax.normalizedToken(String(character))
            )
            return true
        case let .backspace(modifiers):
            guard !modifiers.containsUnsupportedTypingModifier else {
                cancelCurrentTransaction(reason: .unsupportedModifiers)
                return true
            }
            guard !transaction.browserQuery.isEmpty else {
                return true
            }
            var query = transaction.browserQuery
            query.removeLast()
            updateBrowserQuery(
                transactionID: transaction.transactionID,
                query: query
            )
            return true
        case .ignore:
            return true
        }
    }

    private func beginMediaSearch(
        command: MediaCommandKind,
        query: String,
        expectedToken: String
    ) {
        cancelCurrentTransaction(reason: .externallyCancelled)
        cancelMediaOperation()
        mediaGeneration &+= 1
        if mediaGeneration == 0 {
            mediaGeneration = 1
        }
        let generation = mediaGeneration
        var transaction = ActiveMediaTransaction(
            generation: generation,
            sessionTarget: nil,
            expectedToken: expectedToken,
            caretBounds: nil,
            command: command,
            panelState: .loading,
            results: [],
            grid: MediaCommandGrid(columnCount: 4),
            attributions: [],
            captureGeneration: 0,
            activityRevision: 0,
            isVisible: false
        )
        armMediaInactivityTimeout(for: &transaction)
        activeMediaTransaction = transaction
        scheduleMediaCapture(
            generation: generation,
            expectedToken: expectedToken,
            purpose: .search(query: query)
        )
    }

    private func showMediaValidationFailure(
        command: MediaCommandKind,
        expectedToken: String
    ) {
        cancelCurrentTransaction(reason: .externallyCancelled)
        cancelMediaOperation()
        mediaGeneration &+= 1
        if mediaGeneration == 0 {
            mediaGeneration = 1
        }
        let generation = mediaGeneration
        var transaction = ActiveMediaTransaction(
            generation: generation,
            sessionTarget: nil,
            expectedToken: expectedToken,
            caretBounds: nil,
            command: command,
            panelState: .failed(.invalidQuery),
            results: [],
            grid: MediaCommandGrid(columnCount: 4),
            attributions: [],
            captureGeneration: 0,
            activityRevision: 0,
            isVisible: false
        )
        armMediaInactivityTimeout(for: &transaction)
        activeMediaTransaction = transaction
        scheduleMediaCapture(
            generation: generation,
            expectedToken: expectedToken,
            purpose: .validationFailure
        )
    }

    private func scheduleMediaCapture(
        generation: UInt64,
        expectedToken: String,
        purpose: MediaCapturePurpose
    ) {
        guard var transaction = activeMediaTransaction,
              transaction.generation == generation else {
            return
        }
        transaction.captureGeneration &+= 1
        transaction.expectedToken = expectedToken
        activeMediaTransaction = transaction
        let captureGeneration = transaction.captureGeneration
        let delay = configuration.accessibilitySettleDelayMilliseconds
        queue.asyncAfter(
            deadline: .now() + .milliseconds(delay)
        ) { [weak self] in
            self?.performMediaCapture(
                generation: generation,
                captureGeneration: captureGeneration,
                expectedToken: expectedToken,
                purpose: purpose,
                attempt: 0
            )
        }
    }

    private func performMediaCapture(
        generation: UInt64,
        captureGeneration: UInt64,
        expectedToken: String,
        purpose: MediaCapturePurpose,
        attempt: Int
    ) {
        guard
            captureEnabled,
            let transaction = activeMediaTransaction,
            transaction.generation == generation,
            transaction.captureGeneration == captureGeneration,
            transaction.expectedToken == expectedToken
        else {
            return
        }

        do {
            let capture = try contextProvider.capture(
                expectedToken: expectedToken,
                trigger: "/"
            )
            guard
                capture.bundleIdentifier
                    == MediaCommandParser.messagesBundleIdentifier
            else {
                cancelMediaTransaction(showCancelled: false)
                return
            }
            finishMediaCapture(
                generation: generation,
                captureGeneration: captureGeneration,
                expectedToken: expectedToken,
                purpose: purpose,
                capture: capture
            )
        } catch let error as RuntimeTextCaptureError {
            if
                error.isTransient,
                attempt < configuration.accessibilityRetryLimit
            {
                queue.asyncAfter(deadline: .now() + .milliseconds(12)) {
                    [weak self] in
                    self?.performMediaCapture(
                        generation: generation,
                        captureGeneration: captureGeneration,
                        expectedToken: expectedToken,
                        purpose: purpose,
                        attempt: attempt + 1
                    )
                }
            } else {
                emitDiagnostic(for: error)
                cancelMediaTransaction(showCancelled: false)
            }
        } catch {
            cancelMediaTransaction(showCancelled: false)
        }
    }

    private func finishMediaCapture(
        generation: UInt64,
        captureGeneration: UInt64,
        expectedToken: String,
        purpose: MediaCapturePurpose,
        capture: RuntimeTextCapture
    ) {
        guard
            var transaction = activeMediaTransaction,
            transaction.generation == generation,
            transaction.captureGeneration == captureGeneration
        else {
            return
        }
        if let target = transaction.sessionTarget {
            guard
                target.processIdentifier
                    == capture.target.processIdentifier
            else {
                cancelMediaTransaction(showCancelled: false)
                return
            }
        } else {
            transaction.sessionTarget = capture.target
        }
        transaction.caretBounds = capture.context.caretBounds
        transaction.isVisible = true
        activeMediaTransaction = transaction

        switch purpose {
        case let .search(query):
            transaction.panelState = .loading
            activeMediaTransaction = transaction
            presentMedia(transaction)
            let debounce = configuration.mediaSearchDebounceMilliseconds
            queue.asyncAfter(
                deadline: .now() + .milliseconds(debounce)
            ) { [weak self] in
                self?.launchMediaSearch(
                    generation: generation,
                    query: query
                )
            }

        case .validationFailure:
            presentMedia(transaction)

        case let .insert(result):
            guard
                let sessionTarget = transaction.sessionTarget,
                let request = RuntimeReplacementRequestFactory.make(
                    sessionTarget: sessionTarget,
                    capture: capture,
                    expectedToken: expectedToken
                )
            else {
                cancelMediaTransaction(showCancelled: false)
                return
            }
            resolveAndInsertMediaCommandResult(
                result,
                request: request,
                generation: generation,
                expectedToken: expectedToken,
                command: transaction.command
            )
        }
    }

    private func launchMediaSearch(
        generation: UInt64,
        query: String
    ) {
        guard
            let transaction = activeMediaTransaction,
            transaction.generation == generation,
            transaction.expectedToken == mediaParser.renderedToken
        else {
            return
        }
        guard let mediaCommandCoordinator else {
            updateMediaPanel(
                generation: generation,
                state: .failed(.providerUnavailable)
            )
            return
        }

        let command = transaction.command
        let options = mediaNetworkOptions
        let limit = configuration.mediaResultLimit
        mediaOperation = Task { [weak self] in
            let state = await mediaCommandCoordinator.search(
                command: command,
                query: query,
                bundleIdentifier:
                    MediaCommandParser.messagesBundleIdentifier,
                networkOptions: options,
                limit: limit
            )
            guard let self else {
                return
            }
            queue.async { [weak self] in
                self?.applyMediaSearchState(
                    state,
                    generation: generation
                )
            }
        }
    }

    private func applyMediaSearchState(
        _ state: MediaCommandSearchState,
        generation: UInt64
    ) {
        guard
            var transaction = activeMediaTransaction,
            transaction.generation == generation
        else {
            return
        }
        mediaOperation = nil
        let results = state.runtimeResults
        transaction.panelState = state.runtimePanelState
        transaction.results = results?.items ?? []
        transaction.grid.updateItems(transaction.results)
        transaction.attributions = results?.attributions ?? []
        transaction.isVisible = true
        activeMediaTransaction = transaction
        presentMedia(transaction)
    }

    private func updateMediaPanel(
        generation: UInt64,
        state: RuntimeMediaPanelState
    ) {
        guard var transaction = activeMediaTransaction,
              transaction.generation == generation else {
            return
        }
        transaction.panelState = state
        transaction.results = []
        transaction.grid.updateItems([])
        transaction.attributions = []
        transaction.isVisible = true
        activeMediaTransaction = transaction
        presentMedia(transaction)
    }

    private func handleMediaGridKey(
        _ snapshot: KeyboardEventSnapshot
    ) -> Bool {
        guard
            snapshot.type == .keyDown,
            var transaction = activeMediaTransaction,
            transaction.isVisible,
            snapshot.flags.intersection([
                .maskControl,
                .maskAlternate,
                .maskCommand,
                .maskSecondaryFn
            ]).isEmpty
        else {
            return false
        }

        let key: MediaCommandGridKey
        switch snapshot.keyCode {
        case RuntimeKeyboardKeyCode.leftArrow:
            key = .left
        case RuntimeKeyboardKeyCode.rightArrow:
            key = .right
        case RuntimeKeyboardKeyCode.upArrow:
            key = .up
        case RuntimeKeyboardKeyCode.downArrow:
            key = .down
        case RuntimeKeyboardKeyCode.tab:
            key = .tab(backward: snapshot.flags.contains(.maskShift))
        case RuntimeKeyboardKeyCode.returnKey,
             RuntimeKeyboardKeyCode.keypadEnter:
            key = .returnKey
        case RuntimeKeyboardKeyCode.escape:
            key = .escape
        default:
            return false
        }

        armMediaInactivityTimeout(for: &transaction)
        let action = transaction.grid.handle(key)
        switch action {
        case .ignored:
            break
        case .dismiss:
            cancelMediaTransaction(showCancelled: true)
            return true
        case .moved:
            activeMediaTransaction = transaction
            presentMedia(transaction)
        case let .activate(index):
            guard transaction.results.indices.contains(index) else {
                return true
            }
            let selectedResult = transaction.results[index]
            transaction.panelState = .resolving
            activeMediaTransaction = transaction
            presentMedia(transaction)
            scheduleMediaCapture(
                generation: transaction.generation,
                expectedToken: transaction.expectedToken,
                purpose: .insert(result: selectedResult)
            )
        }
        return true
    }

    private func armMediaInactivityTimeout(
        for transaction: inout ActiveMediaTransaction
    ) {
        transaction.activityRevision &+= 1
        let generation = transaction.generation
        let activityRevision = transaction.activityRevision
        let timeout = configuration.mediaInactivityTimeoutMilliseconds
        queue.asyncAfter(deadline: .now() + .milliseconds(timeout)) {
            [weak self] in
            guard
                let self,
                let current = activeMediaTransaction,
                current.generation == generation,
                current.activityRevision == activityRevision
            else {
                return
            }
            cancelMediaTransaction(showCancelled: false)
        }
    }

    private func resolveAndInsertMediaCommandResult(
        _ result: MediaCommandResult,
        request: AccessibilityReplacementRequest,
        generation: UInt64,
        expectedToken: String,
        command: MediaCommandKind
    ) {
        guard let mediaCommandCoordinator else {
            updateMediaPanel(
                generation: generation,
                state: .failed(.providerUnavailable)
            )
            return
        }
        let bridge = mainActorBridge
        let remoteMediaCache = remoteMediaCache
        mediaOperation = Task { [weak self] in
            let download: MediaCommandDownload
            do {
                download = try await RuntimeMediaDownloadResolver(
                    coordinator: mediaCommandCoordinator,
                    cache: remoteMediaCache
                ).resolve(result)
                try Task.checkCancellation()
            } catch {
                guard !Task.isCancelled else {
                    return
                }
                guard let self else {
                    return
                }
                queue.async { [weak self] in
                    guard
                        let self,
                        activeMediaTransaction?.generation == generation
                    else {
                        return
                    }
                    diagnosticHandler?(
                        .mediaCopyFallbackAvailable(
                            RuntimeMediaCopyFallbackDiagnostic(
                                source: .sticker,
                                reason: .downloadFailed
                            )
                        )
                    )
                    updateMediaPanel(
                        generation: generation,
                        state: .failed(.unsupportedMedia)
                    )
                }
                return
            }

            do {
                let payload = try RuntimeMediaPayloadBuilder.payload(
                    for: download
                )
                try Task.checkCancellation()
                guard await self?.mediaInsertionIsStillActive(
                    generation: generation,
                    expectedToken: expectedToken
                ) == true else {
                    return
                }
                try Task.checkCancellation()
                let insertionResult = await bridge.insertDownloadedMedia(
                    payload,
                    replacing: request
                )
                guard let self else {
                    return
                }
                queue.async { [weak self] in
                    guard
                        let self,
                        activeMediaTransaction?.generation == generation
                    else {
                        return
                    }
                    if case let .copyFallbackAvailable(reason) =
                        insertionResult
                    {
                        diagnosticHandler?(
                            .mediaCopyFallbackAvailable(
                                RuntimeMediaCopyFallbackDiagnostic(
                                    source: .sticker,
                                    reason: .insertionFailed(reason),
                                    payload: payload
                                )
                            )
                        )
                    } else if Self.clipboardRestoreFailed(
                        in: insertionResult
                    ) {
                        diagnosticHandler?(.clipboardRestoreFailed)
                    }
                    clearMediaTransaction()
                }
            } catch {
                guard !Task.isCancelled else {
                    return
                }
                guard let self else {
                    return
                }
                queue.async { [weak self] in
                    guard
                        let self,
                        activeMediaTransaction?.generation == generation
                    else {
                        return
                    }
                    diagnosticHandler?(
                        .mediaCopyFallbackAvailable(
                            RuntimeMediaCopyFallbackDiagnostic(
                                source: .sticker,
                                reason: .unsupportedDownloadedMedia
                            )
                        )
                    )
                    updateMediaPanel(
                        generation: generation,
                        state: .failed(.unsupportedMedia)
                    )
                }
            }
        }
    }

    private func mediaInsertionIsStillActive(
        generation: UInt64,
        expectedToken: String
    ) async -> Bool {
        await withCheckedContinuation { continuation in
            queue.async { [weak self] in
                guard
                    let self,
                    let transaction = activeMediaTransaction,
                    transaction.generation == generation,
                    transaction.expectedToken == expectedToken,
                    mediaParser.renderedToken == expectedToken
                else {
                    continuation.resume(returning: false)
                    return
                }
                continuation.resume(returning: true)
            }
        }
    }

    private func presentMedia(_ transaction: ActiveMediaTransaction) {
        guard
            transaction.isVisible,
            let caretBounds = transaction.caretBounds
        else {
            hideMediaSurface()
            return
        }
        uiRevision &+= 1
        let snapshot = RuntimeMediaPanelSnapshot(
            revision: uiRevision,
            command: transaction.command,
            state: transaction.panelState,
            items: transaction.results.map {
                RuntimeMediaPanelItem(
                    id: $0.id,
                    title: $0.media.title,
                    previewURL: $0.media.previewURL,
                    provider: $0.media.provider
                )
            },
            selectedIndex: transaction.grid.selectedIndex,
            attributions: RuntimeMediaAttributionPolicy.normalized(
                items: transaction.results,
                declared: transaction.attributions
            )
        )
        let revision = snapshot.revision
        let generation = transaction.generation
        let bridge = mainActorBridge
        let queue = queue
        Task { @MainActor [weak self] in
            let isVisible = await bridge.applyMediaReportingVisibility(
                .show(
                    snapshot: snapshot,
                    quartzCaretBounds: caretBounds
                )
            )
            queue.async { [weak self] in
                self?.finishMediaPresentation(
                    revision: revision,
                    generation: generation,
                    isVisible: isVisible
                )
            }
        }
    }

    private func finishMediaPresentation(
        revision: UInt64,
        generation: UInt64,
        isVisible: Bool
    ) {
        guard
            uiRevision == revision,
            activeMediaTransaction?.generation == generation
        else {
            return
        }
        guard isVisible else {
            cancelMediaTransaction(showCancelled: false)
            return
        }
        interceptionGate.setMode(
            .media,
            acceptsTab: true,
            acceptsReturn: true
        )
    }

    private func hideMediaSurface() {
        interceptionGate.setMode(
            .hidden,
            acceptsTab: configuration.preferences.shortcode.acceptsTab,
            acceptsReturn:
                configuration.preferences.shortcode.acceptsReturn
        )
        uiRevision &+= 1
        let revision = uiRevision
        let bridge = mainActorBridge
        Task { @MainActor in
            bridge.applyMedia(.hide(revision: revision))
        }
    }

    private func cancelMediaOperation() {
        mediaOperation?.cancel()
        mediaOperation = nil
        if let mediaCommandCoordinator {
            Task {
                _ = await mediaCommandCoordinator.cancel()
            }
        }
    }

    private func cancelMediaTransaction(showCancelled: Bool) {
        let cancelledTransaction = activeMediaTransaction
        cancelMediaOperation()
        mediaParser.reset()
        mediaGeneration &+= 1
        activeMediaTransaction = nil

        guard
            showCancelled,
            var transaction = cancelledTransaction,
            let caretBounds = transaction.caretBounds
        else {
            hideMediaSurface()
            return
        }
        transaction.panelState = .cancelled
        transaction.results = []
        transaction.grid.updateItems([])
        transaction.attributions = []
        transaction.isVisible = false
        interceptionGate.setMode(
            .hidden,
            acceptsTab: configuration.preferences.shortcode.acceptsTab,
            acceptsReturn:
                configuration.preferences.shortcode.acceptsReturn
        )
        uiRevision &+= 1
        let revision = uiRevision
        let snapshot = RuntimeMediaPanelSnapshot(
            revision: revision,
            command: transaction.command,
            state: .cancelled,
            items: [],
            selectedIndex: nil,
            attributions: []
        )
        let bridge = mainActorBridge
        Task { @MainActor in
            bridge.applyMedia(
                .show(
                    snapshot: snapshot,
                    quartzCaretBounds: caretBounds
                )
            )
        }
        queue.asyncAfter(deadline: .now() + .milliseconds(350)) {
            [weak self] in
            guard let self, uiRevision == revision else {
                return
            }
            hideMediaSurface()
        }
    }

    private func clearMediaTransaction() {
        cancelMediaOperation()
        mediaParser.reset()
        activeMediaTransaction = nil
        hideMediaSurface()
    }

    private func suspendMediaTransactionKeepingParser() {
        cancelMediaOperation()
        mediaGeneration &+= 1
        activeMediaTransaction = nil
        hideMediaSurface()
    }

    private func handle(_ actions: [ShortcodeParserAction]) {
        for action in actions {
            switch action {
            case let .began(session):
                begin(session)

            case let .updateSuggestions(transactionID, query, token):
                updateSuggestions(
                    transactionID: transactionID,
                    query: query,
                    token: token
                )

            case let .hideSuggestions(transactionID):
                guard activeTransaction?.transactionID == transactionID else {
                    continue
                }
                hideSurface()

            case let .requestExactReplacement(
                transactionID,
                shortcode,
                token
            ):
                replaceExactMatch(
                    transactionID: transactionID,
                    shortcode: shortcode,
                    token: token
                )

            case let .openBrowser(transactionID, token):
                showBrowser(
                    transactionID: transactionID,
                    token: token
                )

            case let .moveSelection(transactionID, direction):
                let delta = direction == .arrowUp ? -1 : 1
                moveSelection(
                    transactionID: transactionID,
                    delta: delta
                )

            case let .acceptSelected(transactionID, _, token):
                acceptCurrentSelection(
                    transactionID: transactionID,
                    token: token
                )

            case let .reset(transactionID, _):
                clear(transactionID: transactionID)
            }
        }
    }

    private func begin(_ session: ShortcodeParserSession) {
        let token = session.token(
            trigger: configuration.preferences.shortcode.trigger
        )
        var transaction = ActiveTransaction(
            transactionID: session.transactionID,
            sessionTarget: nil,
            expectedToken: token.rendered,
            caretBounds: nil,
            results: [],
            presentationRows: [],
            selectedIndex: 0,
            visibleMode: .hidden,
            browserQuery: "",
            captureGeneration: 0,
            activityRevision: 0,
            bundleIdentifier: nil
        )
        armShortcodeInactivityTimeout(for: &transaction)
        activeTransaction = transaction
        scheduleCapture(
            transactionID: session.transactionID,
            expectedToken: token.rendered,
            purpose: .establishSession
        )
    }

    private func updateSuggestions(
        transactionID: ParserTransactionID,
        query: String,
        token: ParsedShortcodeToken
    ) {
        guard var transaction = activeTransaction,
              transaction.transactionID == transactionID else {
            return
        }

        transaction.expectedToken = token.rendered
        setResults(
            Array(
                searchIndex.search(
                    query,
                    usage: usageSnapshot,
                    limit: max(configuration.suggestionLimit, 1)
                ).prefix(configuration.suggestionLimit)
            ),
            in: &transaction
        )
        transaction.selectedIndex = 0
        armShortcodeInactivityTimeout(for: &transaction)
        activeTransaction = transaction

        guard !transaction.results.isEmpty else {
            hideSurface()
            return
        }
        retainSurfacePresentationDuringRefresh()
        scheduleCapture(
            transactionID: transactionID,
            expectedToken: token.rendered,
            purpose: .showSuggestions
        )
    }

    private func replaceExactMatch(
        transactionID: ParserTransactionID,
        shortcode: String,
        token: ParsedShortcodeToken
    ) {
        guard activeTransaction?.transactionID == transactionID else {
            return
        }
        hideSurface()
        guard
            let result = searchIndex.exactMatch(
                for: shortcode,
                usage: usageSnapshot
            )
        else {
            clear(transactionID: transactionID)
            return
        }
        scheduleCapture(
            transactionID: transactionID,
            expectedToken: token.rendered,
            purpose: .insert(item: result.item)
        )
    }

    private func showBrowser(
        transactionID: ParserTransactionID,
        token: ParsedShortcodeToken
    ) {
        showBrowser(
            transactionID: transactionID,
            expectedToken: token.rendered
        )
    }

    private func showBrowser(
        transactionID: ParserTransactionID,
        expectedToken: String
    ) {
        guard var transaction = activeTransaction,
              transaction.transactionID == transactionID else {
            return
        }
        transaction.expectedToken = expectedToken
        transaction.browserQuery = ""
        setResults(
            Array(
                searchIndex.search(
                    "",
                    usage: usageSnapshot,
                    limit: max(searchIndex.count, 1)
                )
            ),
            in: &transaction
        )
        transaction.selectedIndex = 0
        transaction.visibleMode = .hidden
        armShortcodeInactivityTimeout(for: &transaction)
        activeTransaction = transaction
        hideSurface()
        guard !transaction.results.isEmpty else {
            clear(transactionID: transactionID)
            return
        }
        scheduleCapture(
            transactionID: transactionID,
            expectedToken: expectedToken,
            purpose: .showBrowser
        )
    }

    private func updateBrowserQuery(
        transactionID: ParserTransactionID,
        query: String
    ) {
        guard var transaction = activeTransaction,
              transaction.transactionID == transactionID,
              transaction.visibleMode == .browser
        else {
            return
        }
        transaction.browserQuery = query
        setResults(
            Array(
                searchIndex.search(
                    query,
                    usage: usageSnapshot,
                    limit: max(searchIndex.count, 1)
                )
            ),
            in: &transaction
        )
        transaction.selectedIndex = 0
        armShortcodeInactivityTimeout(for: &transaction)
        activeTransaction = transaction
        present(transaction)
        prepareSelectedAdaptiveGlyphIfUseful(in: transaction)
    }

    private func moveSelection(
        transactionID: ParserTransactionID,
        delta: Int
    ) {
        guard var transaction = activeTransaction,
              transaction.transactionID == transactionID,
              !transaction.results.isEmpty,
              transaction.visibleMode != .hidden else {
            return
        }
        let count = transaction.results.count
        transaction.selectedIndex =
            (transaction.selectedIndex + delta + count) % count
        armShortcodeInactivityTimeout(for: &transaction)
        activeTransaction = transaction
        present(transaction)
        prepareSelectedAdaptiveGlyphIfUseful(in: transaction)
    }

    private func armShortcodeInactivityTimeout(
        for transaction: inout ActiveTransaction
    ) {
        transaction.activityRevision &+= 1
        let transactionID = transaction.transactionID
        let activityRevision = transaction.activityRevision
        let timeoutMilliseconds = Int(
            configuration.preferences.shortcode.parserTimeout * 1_000
        )
        queue.asyncAfter(
            deadline: .now() + .milliseconds(timeoutMilliseconds)
        ) { [weak self] in
            guard
                let self,
                let current = activeTransaction,
                current.transactionID == transactionID,
                current.activityRevision == activityRevision
            else {
                return
            }
            cancelCurrentTransaction(reason: .timeout)
        }
    }

    private func acceptCurrentSelection(
        transactionID: ParserTransactionID,
        token: ParsedShortcodeToken? = nil
    ) {
        guard
            var transaction = activeTransaction,
            transaction.transactionID == transactionID,
            transaction.results.indices.contains(transaction.selectedIndex)
        else {
            clear(transactionID: transactionID)
            return
        }
        if let token {
            transaction.expectedToken = token.rendered
            activeTransaction = transaction
        }
        let item = transaction.results[transaction.selectedIndex].item
        hideSurface()
        scheduleCapture(
            transactionID: transactionID,
            expectedToken: transaction.expectedToken,
            purpose: .insert(item: item)
        )
    }

    private func scheduleCapture(
        transactionID: ParserTransactionID,
        expectedToken: String,
        purpose: CapturePurpose
    ) {
        guard var transaction = activeTransaction,
              transaction.transactionID == transactionID else {
            return
        }
        transaction.captureGeneration &+= 1
        transaction.expectedToken = expectedToken
        activeTransaction = transaction
        let generation = transaction.captureGeneration
        let delay = configuration.accessibilitySettleDelayMilliseconds
        queue.asyncAfter(
            deadline: .now() + .milliseconds(delay)
        ) { [weak self] in
            self?.performCapture(
                transactionID: transactionID,
                generation: generation,
                expectedToken: expectedToken,
                purpose: purpose,
                attempt: 0
            )
        }
    }

    private func performCapture(
        transactionID: ParserTransactionID,
        generation: UInt64,
        expectedToken: String,
        purpose: CapturePurpose,
        attempt: Int
    ) {
        guard
            captureEnabled,
            let current = activeTransaction,
            current.transactionID == transactionID,
            current.captureGeneration == generation,
            current.expectedToken == expectedToken
        else {
            return
        }

        do {
            let capture = try contextProvider.capture(
                expectedToken: expectedToken,
                trigger: configuration.preferences.shortcode.trigger.character
            )
            finishCapture(
                transactionID: transactionID,
                generation: generation,
                expectedToken: expectedToken,
                purpose: purpose,
                capture: capture
            )
        } catch let error as RuntimeTextCaptureError {
            if
                error.isTransient,
                attempt < configuration.accessibilityRetryLimit
            {
                queue.asyncAfter(deadline: .now() + .milliseconds(12)) {
                    [weak self] in
                    self?.performCapture(
                        transactionID: transactionID,
                        generation: generation,
                        expectedToken: expectedToken,
                        purpose: purpose,
                        attempt: attempt + 1
                    )
                }
            } else {
                emitDiagnostic(for: error)
                cancelCurrentTransaction(
                    reason: parserResetReason(for: error)
                )
            }
        } catch {
            cancelCurrentTransaction(reason: .externallyCancelled)
        }
    }

    private func finishCapture(
        transactionID: ParserTransactionID,
        generation: UInt64,
        expectedToken: String,
        purpose: CapturePurpose,
        capture: RuntimeTextCapture
    ) {
        guard var transaction = activeTransaction,
              transaction.transactionID == transactionID,
              transaction.captureGeneration == generation else {
            return
        }
        if let target = transaction.sessionTarget {
            guard target.processIdentifier == capture.target.processIdentifier else {
                cancelCurrentTransaction(reason: .focusChanged)
                return
            }
        } else {
            transaction.sessionTarget = capture.target
        }
        transaction.caretBounds = capture.context.caretBounds
        transaction.bundleIdentifier = capture.bundleIdentifier
        activeTransaction = transaction
        diagnosticHandler?(.sessionAllowed)

        switch purpose {
        case .establishSession:
            break
        case .showSuggestions:
            transaction.visibleMode = .suggestions
            activeTransaction = transaction
            present(transaction)
            prepareSelectedAdaptiveGlyphIfUseful(in: transaction)
        case .showBrowser:
            transaction.visibleMode = .browser
            activeTransaction = transaction
            present(transaction)
            prepareSelectedAdaptiveGlyphIfUseful(in: transaction)
        case let .insert(item):
            guard
                let sessionTarget = transaction.sessionTarget,
                let request = RuntimeReplacementRequestFactory.make(
                    sessionTarget: sessionTarget,
                    capture: capture,
                    expectedToken: expectedToken
                )
            else {
                cancelCurrentTransaction(reason: .focusChanged)
                return
            }
            performInsertion(
                item: item,
                request: request,
                transactionID: transactionID
            )
        }
    }

    private func performInsertion(
        item: EmojiItem,
        request: AccessibilityReplacementRequest,
        transactionID: ParserTransactionID
    ) {
        switch item.content {
        case .unicode:
            performUnicodeInsertion(
                item: item,
                request: request,
                transactionID: transactionID
            )
        case let .media(media):
            performManagedMediaInsertion(
                item: item,
                media: media,
                request: request,
                transactionID: transactionID
            )
        }
    }

    private func performUnicodeInsertion(
        item: EmojiItem,
        request: AccessibilityReplacementRequest,
        transactionID: ParserTransactionID
    ) {
        guard let value = unicodeValue(for: item) else {
            clear(transactionID: transactionID)
            return
        }
        let selectedTone = selectedSkinTone(for: item)
        let bridge = mainActorBridge
        Task { @MainActor [weak self] in
            let result = await bridge.insertUnicode(
                value: value,
                replacing: request
            )
            guard let self else {
                return
            }
            queue.async { [weak self] in
                guard let self else {
                    return
                }
                if case .inserted = result, let usageStore {
                    Task {
                        try? await usageStore.recordUse(
                            itemID: item.id,
                            skinTone: selectedTone,
                            at: Date()
                        )
                    }
                }
                if Self.clipboardRestoreFailed(in: result) {
                    diagnosticHandler?(.clipboardRestoreFailed)
                }
                clear(transactionID: transactionID)
            }
        }
    }

    private func performManagedMediaInsertion(
        item: EmojiItem,
        media: MediaEmojiContent,
        request: AccessibilityReplacementRequest,
        transactionID: ParserTransactionID
    ) {
        guard
            activeTransaction?.sessionTarget?.processIdentifier
                == request.target.processIdentifier
        else {
            clear(transactionID: transactionID)
            return
        }

        guard let managedMediaRoot else {
            diagnosticHandler?(
                .mediaCopyFallbackAvailable(
                    RuntimeMediaCopyFallbackDiagnostic(
                        source: .customEmoji(
                            shortcode: item.shortcode.rawValue
                        ),
                        reason: .managedLibraryUnavailable
                    )
                )
            )
            clear(transactionID: transactionID)
            return
        }

        guard
            let pendingRevision = beginPendingManagedMediaInsertion(
                transactionID: transactionID
            )
        else {
            return
        }
        let resolver = managedMediaResolver
        managedMediaResolutionQueue.async { [weak self] in
            let resolved = try? resolver.resolve(
                media,
                beneath: managedMediaRoot
            )
            guard let self else {
                return
            }
            queue.async { [weak self] in
                guard
                    let self,
                    let current = activeTransaction,
                    current.transactionID == transactionID,
                    current.activityRevision == pendingRevision,
                    current.sessionTarget?.processIdentifier
                        == request.target.processIdentifier
                else {
                    return
                }
                guard let resolved else {
                    diagnosticHandler?(
                        .mediaCopyFallbackAvailable(
                            RuntimeMediaCopyFallbackDiagnostic(
                                source: .customEmoji(
                                    shortcode: item.shortcode.rawValue
                                ),
                                reason: .invalidManagedAsset
                            )
                        )
                    )
                    clear(transactionID: transactionID)
                    return
                }
                finishManagedMediaResolution(
                    resolved,
                    item: item,
                    media: media,
                    request: request,
                    transactionID: transactionID,
                    pendingRevision: pendingRevision
                )
            }
        }
    }

    private func finishManagedMediaResolution(
        _ resolved: RuntimeResolvedManagedMedia,
        item: EmojiItem,
        media: MediaEmojiContent,
        request: AccessibilityReplacementRequest,
        transactionID: ParserTransactionID,
        pendingRevision: UInt64
    ) {
        let captureBundleIdentifier =
            activeTransaction?.bundleIdentifier
        if resolved.insertionPolicy
            == .copyOnlyAnimatedWebPExperimental,
            !Self.canInsertFirstFrameGlyph(
                into: captureBundleIdentifier
            )
        {
            offerAnimatedWebPCopyFallback(
                resolved,
                item: item,
                request: request,
                transactionID: transactionID,
                pendingRevision: pendingRevision
            )
            return
        }
        guard
            captureBundleIdentifier
                == MediaCommandParser.messagesBundleIdentifier
        else {
            buildManagedMediaPayload(
                resolved,
                transactionID: transactionID,
                pendingRevision: pendingRevision,
                targetProcessIdentifier:
                    request.target.processIdentifier
            ) { [weak self] payload in
                guard let self else {
                    return
                }
                diagnosticHandler?(
                    .mediaCopyFallbackAvailable(
                        RuntimeMediaCopyFallbackDiagnostic(
                            source: .customEmoji(
                                shortcode: item.shortcode.rawValue
                            ),
                            reason: .notMessages,
                            payload: payload
                        )
                    )
                )
                clear(transactionID: transactionID)
            }
            return
        }

        let shortcode = item.shortcode.rawValue
        let inlineFallback = ":\(shortcode):"
        let contentIdentifier = adaptiveGlyphContentIdentifier(
            for: media,
            shortcode: shortcode
        )
        let glyphRequest = AdaptiveGlyphPayloadRequest(
            sourceData: resolved.originalData,
            sourceType: resolved.uniformType,
            contentIdentifier: contentIdentifier,
            accessibilityDescription: inlineFallback,
            plainTextFallback: inlineFallback,
            framePolicy: adaptiveGlyphFramePolicy(for: media)
        )

        let targetProcessIdentifier = request.target.processIdentifier
        adaptiveGlyphPayloadService.payload(for: glyphRequest) {
            [weak self] glyphPayload in
            guard let self else {
                return
            }
            queue.async { [weak self] in
                guard
                    let self,
                    let current = activeTransaction,
                    current.transactionID == transactionID,
                    current.activityRevision == pendingRevision,
                    current.sessionTarget?.processIdentifier
                        == targetProcessIdentifier
                else {
                    return
                }
                if let glyphPayload {
                    insertManagedMediaPayload(
                        glyphPayload,
                        item: item,
                        request: request,
                        transactionID: transactionID
                    )
                } else if resolved.insertionPolicy
                    == .copyOnlyAnimatedWebPExperimental
                {
                    offerAnimatedWebPCopyFallback(
                        resolved,
                        item: item,
                        request: request,
                        transactionID: transactionID,
                        pendingRevision: pendingRevision
                    )
                } else {
                    buildAndInsertManagedMediaFallback(
                        resolved,
                        item: item,
                        request: request,
                        transactionID: transactionID,
                        pendingRevision: pendingRevision
                    )
                }
            }
        }
    }

    private func buildAndInsertManagedMediaFallback(
        _ resolved: RuntimeResolvedManagedMedia,
        item: EmojiItem,
        request: AccessibilityReplacementRequest,
        transactionID: ParserTransactionID,
        pendingRevision: UInt64
    ) {
        buildManagedMediaPayload(
            resolved,
            transactionID: transactionID,
            pendingRevision: pendingRevision,
            targetProcessIdentifier: request.target.processIdentifier
        ) { [weak self] payload in
            guard let self else {
                return
            }
            insertManagedMediaPayload(
                payload,
                item: item,
                request: request,
                transactionID: transactionID
            )
        }
    }

    private func offerAnimatedWebPCopyFallback(
        _ resolved: RuntimeResolvedManagedMedia,
        item: EmojiItem,
        request: AccessibilityReplacementRequest,
        transactionID: ParserTransactionID,
        pendingRevision: UInt64
    ) {
        buildManagedMediaPayload(
            resolved,
            transactionID: transactionID,
            pendingRevision: pendingRevision,
            targetProcessIdentifier: request.target.processIdentifier
        ) { [weak self] payload in
            guard let self else {
                return
            }
            diagnosticHandler?(
                .mediaCopyFallbackAvailable(
                    RuntimeMediaCopyFallbackDiagnostic(
                        source: .customEmoji(
                            shortcode: item.shortcode.rawValue
                        ),
                        reason: .animatedWebPExperimental,
                        payload: payload
                    )
                )
            )
            clear(transactionID: transactionID)
        }
    }

    private func buildManagedMediaPayload(
        _ resolved: RuntimeResolvedManagedMedia,
        transactionID: ParserTransactionID,
        pendingRevision: UInt64,
        targetProcessIdentifier: pid_t,
        completion: @escaping @Sendable (PasteboardItemPayload) -> Void
    ) {
        let payloadBuilder = managedMediaPayloadBuilder
        managedMediaResolutionQueue.async { [weak self] in
            let payload = payloadBuilder(resolved)
            guard let self else {
                return
            }
            queue.async { [weak self] in
                guard
                    let self,
                    let current = activeTransaction,
                    current.transactionID == transactionID,
                    current.activityRevision == pendingRevision,
                    current.sessionTarget?.processIdentifier
                        == targetProcessIdentifier
                else {
                    return
                }
                completion(payload)
            }
        }
    }

    private func insertManagedMediaPayload(
        _ payload: PasteboardItemPayload,
        item: EmojiItem,
        request: AccessibilityReplacementRequest,
        transactionID: ParserTransactionID
    ) {
        guard
            var transaction = activeTransaction,
            transaction.transactionID == transactionID,
            transaction.sessionTarget?.processIdentifier
                == request.target.processIdentifier
        else {
            return
        }
        // Payload preparation is complete. Invalidate its long timeout before
        // handing the final, focus-revalidated insertion to the main actor.
        transaction.activityRevision &+= 1
        activeTransaction = transaction

        let bridge = mainActorBridge
        Task { @MainActor [weak self] in
            let result = await bridge.insertDownloadedMedia(
                payload,
                replacing: request
            )
            guard let self else {
                return
            }
            queue.async { [weak self] in
                guard let self else {
                    return
                }
                switch result {
                case let .inserted(method):
                    if let usageStore {
                        Task {
                            try? await usageStore.recordUse(
                                itemID: item.id,
                                skinTone: nil,
                                at: Date()
                            )
                        }
                    }
                    if method == .temporaryPasteboard(.restoreFailed) {
                        diagnosticHandler?(.clipboardRestoreFailed)
                    }
                case let .copyFallbackAvailable(reason):
                    diagnosticHandler?(
                        .mediaCopyFallbackAvailable(
                            RuntimeMediaCopyFallbackDiagnostic(
                                source: .customEmoji(
                                    shortcode: item.shortcode.rawValue
                                ),
                                reason: .insertionFailed(reason),
                                payload: payload
                            )
                        )
                    )
                }
                clear(transactionID: transactionID)
            }
        }
    }

    private func beginPendingManagedMediaInsertion(
        transactionID: ParserTransactionID
    ) -> UInt64? {
        guard
            var transaction = activeTransaction,
            transaction.transactionID == transactionID
        else {
            return nil
        }
        transaction.activityRevision &+= 1
        activeTransaction = transaction
        let revision = transaction.activityRevision
        queue.asyncAfter(deadline: .now() + .seconds(30)) { [weak self] in
            guard
                let self,
                let current = activeTransaction,
                current.transactionID == transactionID,
                current.activityRevision == revision
            else {
                return
            }
            cancelCurrentTransaction(reason: .timeout)
        }
        return revision
    }

    private func prepareSelectedAdaptiveGlyphIfUseful(
        in transaction: ActiveTransaction
    ) {
        guard
            transaction.bundleIdentifier
                == MediaCommandParser.messagesBundleIdentifier,
            let managedMediaRoot,
            transaction.results.indices.contains(transaction.selectedIndex)
        else {
            return
        }

        let query: String
        switch transaction.visibleMode {
        case .suggestions:
            query = transaction.expectedToken
                .dropFirst()
                .lowercased()
        case .browser:
            query = transaction.browserQuery.lowercased()
        case .hidden, .media:
            return
        }
        guard query.utf8.count >= 3 else {
            return
        }

        let item = transaction.results[transaction.selectedIndex].item
        let canInsertFirstFrameGlyph = Self.canInsertFirstFrameGlyph(
            into: transaction.bundleIdentifier
        )
        guard
            item.shortcode.rawValue.lowercased().hasPrefix(query),
            case let .media(media) = item.content,
            !media.isAnimated || canInsertFirstFrameGlyph
        else {
            return
        }

        let shortcode = item.shortcode.rawValue
        let inlineFallback = ":\(shortcode):"
        let contentIdentifier = adaptiveGlyphContentIdentifier(
            for: media,
            shortcode: shortcode
        )
        let sourceType = adaptiveGlyphSourceType(for: media.mediaType)
        let framePolicy = adaptiveGlyphFramePolicy(for: media)
        let key = AdaptiveGlyphPayloadCacheKey(
            sourceType: sourceType,
            contentIdentifier: contentIdentifier,
            accessibilityDescription: inlineFallback,
            plainTextFallback: inlineFallback,
            framePolicy: framePolicy
        )
        let resolver = managedMediaResolver
        adaptiveGlyphPayloadService.prepare(
            for: key,
            loader: {
                guard
                    let resolved = try? resolver.resolve(
                        media,
                        beneath: managedMediaRoot
                    ),
                    resolved.insertionPolicy == .automatic
                        || canInsertFirstFrameGlyph,
                    resolved.uniformType == sourceType
                else {
                    return nil
                }
                return AdaptiveGlyphPayloadRequest(
                    sourceData: resolved.originalData,
                    sourceType: resolved.uniformType,
                    contentIdentifier: contentIdentifier,
                    accessibilityDescription: inlineFallback,
                    plainTextFallback: inlineFallback,
                    framePolicy: framePolicy
                )
            }
        )
    }

    private func adaptiveGlyphSourceType(
        for mediaType: EmojiMediaType
    ) -> UTType {
        switch mediaType {
        case .png:
            .png
        case .jpeg:
            .jpeg
        case .gif:
            .gif
        case .webP:
            .webP
        }
    }

    private func adaptiveGlyphFramePolicy(
        for media: MediaEmojiContent
    ) -> AdaptiveGlyphFramePolicy {
        media.isAnimated ? .firstFrame : .requireSingleFrame
    }

    private func adaptiveGlyphContentIdentifier(
        for media: MediaEmojiContent,
        shortcode: String
    ) -> String {
        let frameSuffix = media.isAnimated ? ":f0" : ""
        return "mojipond:\(media.contentHash.lowercased()):\(shortcode)\(frameSuffix)"
    }

    private static func canInsertFirstFrameGlyph(
        into bundleIdentifier: String?
    ) -> Bool {
        guard
            bundleIdentifier
                == MediaCommandParser.messagesBundleIdentifier
        else {
            return false
        }
        if #available(macOS 15.0, *) {
            return true
        }
        return false
    }

    private func setResults(
        _ results: [EmojiSearchResult],
        in transaction: inout ActiveTransaction
    ) {
        transaction.results = results
        transaction.presentationRows = results.map { result in
            let artworkURLs = displayArtworkURLs(for: result.item)
            return RuntimeSuggestionRow(
                id: result.item.id,
                glyph: displayGlyph(for: result.item),
                artworkURL: artworkURLs.first,
                artworkFallbackURL: artworkURLs.dropFirst().first,
                artworkRootURL: artworkURLs.isEmpty
                    ? nil
                    : managedMediaRoot,
                shortcode: result.item.shortcode.rawValue,
                name: result.item.name
            )
        }
    }

    private func present(_ transaction: ActiveTransaction) {
        guard
            transaction.visibleMode != .hidden,
            let caretBounds = transaction.caretBounds,
            !transaction.results.isEmpty
                || transaction.visibleMode == .browser
        else {
            hideSurface()
            return
        }

        uiRevision &+= 1
        let snapshot = RuntimeSuggestionPanelSnapshot(
            revision: uiRevision,
            transactionID: transaction.transactionID,
            mode: transaction.visibleMode,
            rows: transaction.presentationRows,
            selectedIndex: transaction.selectedIndex,
            query: transaction.visibleMode == .browser
                ? transaction.browserQuery
                : nil
        )
        let revision = snapshot.revision
        let transactionID = transaction.transactionID
        let mode = transaction.visibleMode
        let update = RuntimeSuggestionPanelUpdate.show(
            snapshot: snapshot,
            quartzCaretBounds: caretBounds
        )
        let bridge = mainActorBridge
        let queue = queue
        Task { @MainActor [weak self] in
            let isVisible = await bridge.applyReportingVisibility(update)
            queue.async { [weak self] in
                self?.finishSuggestionPresentation(
                    revision: revision,
                    transactionID: transactionID,
                    mode: mode,
                    isVisible: isVisible
                )
            }
        }
    }

    private func finishSuggestionPresentation(
        revision: UInt64,
        transactionID: ParserTransactionID,
        mode: RuntimeInterceptionMode,
        isVisible: Bool
    ) {
        guard
            uiRevision == revision,
            activeTransaction?.transactionID == transactionID,
            activeTransaction?.visibleMode == mode
        else {
            return
        }
        guard isVisible else {
            cancelCurrentTransaction(reason: .externallyCancelled)
            return
        }
        interceptionGate.setMode(
            mode,
            acceptsTab: configuration.preferences.shortcode.acceptsTab,
            acceptsReturn: configuration.preferences.shortcode.acceptsReturn
        )
    }

    private func hideSurface() {
        if var transaction = activeTransaction {
            transaction.visibleMode = .hidden
            activeTransaction = transaction
        }
        interceptionGate.setMode(
            .hidden,
            acceptsTab: configuration.preferences.shortcode.acceptsTab,
            acceptsReturn: configuration.preferences.shortcode.acceptsReturn
        )
        uiRevision &+= 1
        let update = RuntimeSuggestionPanelUpdate.hide(revision: uiRevision)
        let bridge = mainActorBridge
        Task { @MainActor in
            bridge.apply(update)
        }
    }

    private func retainSurfacePresentationDuringRefresh() {
        // Preserve an already-armed suggestions gate so immediate acceptance
        // remains responsive. Initial presentation is still fail-closed
        // because the gate begins hidden and is armed only after visibility is
        // confirmed.
        // Invalidate any in-flight presentation completion without ordering
        // the current panel out. The next verified capture updates it in place.
        uiRevision &+= 1
        let update = RuntimeSuggestionPanelUpdate.retain(
            revision: uiRevision
        )
        let bridge = mainActorBridge
        Task { @MainActor in
            bridge.apply(update)
        }
    }

    private func clear(transactionID: ParserTransactionID) {
        guard activeTransaction?.transactionID == transactionID else {
            return
        }
        activeTransaction = nil
        hideSurface()
    }

    private func cancelCurrentTransaction(reason: ParserResetReason) {
        if parser.state.session != nil {
            _ = parser.handle(.reset(reason))
        }
        activeTransaction = nil
        hideSurface()
    }

    private func cancelAllTransactions(reason: ParserResetReason) {
        cancelCurrentTransaction(reason: reason)
        cancelMediaTransaction(showCancelled: false)
    }

    private func displayGlyph(for item: EmojiItem) -> String {
        switch item.content {
        case .unicode:
            unicodeValue(for: item) ?? "◇"
        case let .media(media):
            media.isAnimated ? "GIF" : "▧"
        }
    }

    private func displayArtworkURLs(for item: EmojiItem) -> [URL] {
        guard
            let managedMediaRoot,
            case let .media(media) = item.content
        else {
            return []
        }
        return [
            media.thumbnailRelativePath,
            media.relativePath
        ]
        .compactMap { $0 }
        .filter(StoredAsset.isSafeRelativePath)
        .map {
            managedMediaRoot
                .appendingPathComponent($0, isDirectory: false)
                .standardizedFileURL
        }
        .reduce(into: [URL]()) { result, candidate in
            if !result.contains(candidate) {
                result.append(candidate)
            }
        }
    }

    private func selectedSkinTone(for item: EmojiItem) -> EmojiSkinTone? {
        usageSnapshot.preferredSkinToneByItemID[item.id]
            ?? configuration.preferences.defaultSkinTone
    }

    private func unicodeValue(for item: EmojiItem) -> String? {
        guard case let .unicode(content) = item.content else {
            return nil
        }
        return content.value(for: selectedSkinTone(for: item))
    }

    private static func clipboardRestoreFailed(
        in result: InsertionResult
    ) -> Bool {
        result == .inserted(.temporaryPasteboard(.restoreFailed))
    }

    private func parserResetReason(
        for error: RuntimeTextCaptureError
    ) -> ParserResetReason {
        switch error {
        case let .denied(denial):
            switch denial {
            case .permissionUnavailable:
                .permissionLost
            case .secureEventInput, .secureField, .secureStatusUnknown:
                .secureInput
            case .applicationUnknown,
                 .domainUnknown,
                 .excludedApplication,
                 .excludedDomain:
                .applicationChanged
            }
        case .inaccessibleTarget:
            .focusChanged
        case .invalidTokenContext:
            .cursorMoved
        }
    }

    private func emitDiagnostic(for error: RuntimeTextCaptureError) {
        switch error {
        case let .denied(denial):
            diagnosticHandler?(.sessionDenied(denial))
        case .inaccessibleTarget, .invalidTokenContext:
            diagnosticHandler?(.unsupportedTarget)
        }
    }
}
