import CoreGraphics
import Foundation
import UniformTypeIdentifiers

enum UnicodeAutocompleteRuntimeDiagnostic: Equatable, Sendable {
    case unsupportedTarget
    case clipboardRestoreFailed
    case sendAfterInsertionUnavailable
    case sessionDenied(RuntimeSessionDenial)
    case sessionAllowed
    case mediaCopyFallbackAvailable(
        RuntimeMediaCopyFallbackDiagnostic
    )
}

enum RuntimePresentationApplicationResult: Equatable, Sendable {
    case rejected
    case applied(isVisible: Bool)
}

struct UnicodeAutocompleteRuntimeConfiguration: Equatable, Sendable {
    var preferences: MojiPondPreferences
    var suggestionLimit: Int
    var accessibilitySettleDelayMilliseconds: Int
    var accessibilityRetryLimit: Int

    init(
        preferences: MojiPondPreferences = .defaults,
        suggestionLimit: Int = 60,
        accessibilitySettleDelayMilliseconds: Int = 12,
        accessibilityRetryLimit: Int = 2
    ) {
        self.preferences = preferences
        self.suggestionLimit = min(
            max(1, suggestionLimit),
            100
        )
        self.accessibilitySettleDelayMilliseconds = min(
            max(0, accessibilitySettleDelayMilliseconds),
            100
        )
        self.accessibilityRetryLimit = min(max(0, accessibilityRetryLimit), 4)
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

    func applyReportingVisibility(
        _ update: RuntimeSuggestionPanelUpdate,
        willApply: @escaping @MainActor @Sendable () -> Bool = { true }
    ) async -> RuntimePresentationApplicationResult {
        guard await waitForPresentationDelay() else {
            return .rejected
        }
        guard willApply() else {
            return .rejected
        }
        return .applied(
            isVisible: presenter.applyReportingVisibility(update)
        )
    }

    private func waitForPresentationDelay() async -> Bool {
        guard presentationDelayMilliseconds > 0 else {
            return !Task.isCancelled
        }
        do {
            try await Task.sleep(
                for: .milliseconds(presentationDelayMilliseconds)
            )
        } catch {
            return false
        }
        return !Task.isCancelled
    }

    func insertUnicode(
        value: String,
        replacing request: AccessibilityReplacementRequest,
        authorization: @escaping @Sendable () -> Bool
    ) async -> InsertionResult? {
        guard authorization() else {
            return nil
        }
        return await insertionEngine.insert(
            .unicode(value),
            replacing: request
        )
    }

    func insertDownloadedMediaIfAuthorized(
        _ payload: PasteboardItemPayload,
        replacing request: AccessibilityReplacementRequest,
        authorization: @escaping @Sendable () -> Bool
    ) async -> InsertionResult? {
        guard authorization() else {
            return nil
        }
        return await insertionEngine.insert(
            .media(payload),
            replacing: request
        )
    }

    func sendReturnAfterConfirmedInsertion(
        replacing request: AccessibilityReplacementRequest,
        claimSend: @escaping @Sendable () -> Bool
    ) async -> Bool {
        await insertionEngine.sendReturnAfterConfirmedInsertion(
            replacing: request,
            claimSend: claimSend
        )
    }

    var canSendSyntheticEvents: Bool {
        insertionEngine.canPostEvents
    }
}

/// Owns every mutable parser/search/session value on one serial queue. Event-tap
/// handlers only enqueue immutable snapshots into this object.
final class UnicodeAutocompleteRuntimeWorker: @unchecked Sendable {
    private static let messagesBundleIdentifier = "com.apple.MobileSMS"

    private enum CapturePurpose: Sendable {
        case establishSession
        case showSuggestions
        case revalidateCaretMovement
        case showBrowser
        case insert(item: EmojiItem)
    }

    private struct ActiveTransaction: @unchecked Sendable {
        struct CommitState: Sendable {
            let gateGeneration: UInt64
        }

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
        var commitState: CommitState?
        var predictionGeneration: UInt64?
        var presentationInteractionRevision: UInt64
        var canAcceptSelection: Bool
    }

    private let queue: DispatchQueue
    private let managedMediaResolutionQueue: DispatchQueue
    private let interceptionGate: RuntimeInterceptionGate
    private let contextProvider: any RuntimeTextContextCapturing
    private let mainActorBridge: RuntimeMainActorBridge
    private let usageStore: (any EmojiUsageStore)?
    private let managedMediaResolver: any RuntimeManagedMediaResolving
    private let managedMediaPayloadBuilder:
        @Sendable (RuntimeResolvedManagedMedia) -> PasteboardItemPayload
    private let adaptiveGlyphPayloadService: AdaptiveGlyphPayloadService
    private let diagnosticHandler:
        (@Sendable (UnicodeAutocompleteRuntimeDiagnostic) -> Void)?

    private var parser: ShortcodeParser
    private var searchIndex: EmojiSearchIndex
    private var usageSnapshot: EmojiUsageSnapshot
    private var configuration: UnicodeAutocompleteRuntimeConfiguration
    private var activeTransaction: ActiveTransaction?
    private var suggestionPresentationTask: Task<Void, Never>?
    private var pendingSendTask: Task<Void, Never>?
    private var pendingSendGeneration: UInt64 = 0
    private var managedMediaRoot: URL?
    private var captureEnabled = false
    private var uiRevision: UInt64 = 0
    private var processingPredictionGeneration: UInt64?
    private var processingInteractionRevision: UInt64?
    private var processingEventRevision: UInt64?
    private var contextRecoveryGeneration: UInt64 = 0
    private var needsContextRecovery = false
    private var contextRecoveryTarget: AccessibilityTextTarget?

    init(
        searchIndex: EmojiSearchIndex,
        configuration: UnicodeAutocompleteRuntimeConfiguration,
        interceptionGate: RuntimeInterceptionGate,
        contextProvider: any RuntimeTextContextCapturing,
        mainActorBridge: RuntimeMainActorBridge,
        usageStore: (any EmojiUsageStore)? = nil,
        managedMediaResolver:
            any RuntimeManagedMediaResolving =
                RuntimeManagedMediaResolver(),
        managedMediaRoot: URL? = nil,
        adaptiveGlyphPayloadService:
            AdaptiveGlyphPayloadService = .shared,
        managedMediaPayloadBuilder:
            @escaping @Sendable (RuntimeResolvedManagedMedia) ->
                PasteboardItemPayload = { $0.pasteboardPayload },
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
        self.managedMediaResolver = managedMediaResolver
        self.managedMediaPayloadBuilder = managedMediaPayloadBuilder
        self.managedMediaRoot = managedMediaRoot?
            .standardizedFileURL
            .resolvingSymlinksInPath()
        self.adaptiveGlyphPayloadService = adaptiveGlyphPayloadService
        self.diagnosticHandler = diagnosticHandler
        usageSnapshot = initialUsageSnapshot
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
        refreshExactCommitPredictionConfiguration()
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
            refreshExactCommitPredictionConfiguration()
            cancelAllTransactions(reason: .externallyCancelled)
        }
    }

    func updateSearchIndex(_ searchIndex: EmojiSearchIndex) {
        queue.async { [weak self] in
            guard let self else {
                return
            }
            self.searchIndex = searchIndex
            refreshExactCommitPredictionConfiguration()
            cancelAllTransactions(reason: .externallyCancelled)
        }
    }

    func updateUsageSnapshot(_ usageSnapshot: EmojiUsageSnapshot) {
        queue.async { [weak self] in
            guard let self else {
                return
            }
            self.usageSnapshot = usageSnapshot
            refreshExactCommitPredictionConfiguration()
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
        processingPredictionGeneration =
            interceptionOutcome.predictionGeneration
        processingInteractionRevision =
            interceptionOutcome.interactionRevision
        processingEventRevision =
            interceptionOutcome.eventRevision
        defer {
            processingPredictionGeneration = nil
            processingInteractionRevision = nil
            processingEventRevision = nil
        }

        if interceptionOutcome.preservesAutocompleteContext {
            return
        }

        let hadRecoverableUnicodeContext =
            activeTransaction != nil
                || parser.state.session != nil
                || needsContextRecovery
        if interceptionOutcome.requiresContextRecovery {
            guard hadRecoverableUnicodeContext else {
                return
            }
            suspendCurrentTransactionForContextRecovery()
            scheduleContextRecovery()
            return
        }
        if
            activeTransaction?.visibleMode == .suggestions,
            interceptionOutcome.preservesSuggestionSurface
        {
            preserveSuggestionsAfterCaretMovement(snapshot)
            return
        }
        if needsContextRecovery {
            if isFreshTrigger(action) {
                abandonContextRecovery()
            } else if isContextRecoveryFollowUp(action) {
                scheduleContextRecovery()
                return
            } else if action != .ignore {
                abandonContextRecovery()
                return
            }
        }

        if handleCommitAction(
            action,
            interceptionOutcome: interceptionOutcome
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
            if
                hadRecoverableUnicodeContext,
                reason == .cursorMoved
            {
                scheduleContextRecovery()
            }
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
        if
            hadRecoverableUnicodeContext,
            shouldRecoverContext(after: action),
            transition.actions.contains(where: { parserAction in
                guard case .reset = parserAction else {
                    return false
                }
                return true
            })
        {
            scheduleContextRecovery()
        }
    }

    private func isFreshTrigger(
        _ action: RuntimeKeyboardAction
    ) -> Bool {
        guard
            case let .character(character, modifiers) = action,
            !modifiers.containsUnsupportedTypingModifier
        else {
            return false
        }
        return character
            == configuration.preferences.shortcode.trigger.character
    }

    private func preserveSuggestionsAfterCaretMovement(
        _ snapshot: KeyboardEventSnapshot
    ) {
        guard
            var transaction = activeTransaction,
            transaction.visibleMode == .suggestions
        else {
            return
        }
        let modifiers = RuntimeKeyboardEventMapper.parserModifiers(
            from: snapshot.flags,
            for: snapshot.keyCode
        )
        if
            modifiers.contains(.shift)
                || !modifiers.contains(.option)
                    && !modifiers.contains(.command)
        {
            transaction.selectedIndex = -1
        }
        transaction.canAcceptSelection = false
        if let processingInteractionRevision {
            transaction.presentationInteractionRevision =
                processingInteractionRevision
        }
        armShortcodeInactivityTimeout(for: &transaction)
        activeTransaction = transaction
        retainSurfacePresentationDuringRefresh()
        present(transaction)
        scheduleCapture(
            transactionID: transaction.transactionID,
            expectedToken: transaction.expectedToken,
            purpose: .revalidateCaretMovement
        )
    }

    private func isContextRecoveryFollowUp(
        _ action: RuntimeKeyboardAction
    ) -> Bool {
        switch action {
        case let .character(character, modifiers):
            return modifiers.containsUnsupportedTypingModifier
                || EmojiAliasSyntax.isValidToken(String(character))
        case .backspace:
            return true
        case .reset(.cursorMoved):
            return true
        case .navigation:
            return true
        case .escape, .reset, .ignore:
            return false
        }
    }

    private func shouldRecoverContext(
        after action: RuntimeKeyboardAction
    ) -> Bool {
        switch action {
        case let .character(_, modifiers),
             let .backspace(modifiers):
            return modifiers.containsUnsupportedTypingModifier
        case let .navigation(_, modifiers):
            return modifiers.containsNavigationModifier
        case .reset(.cursorMoved):
            return true
        case .escape, .reset, .ignore:
            return false
        }
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

    private func handleCommitAction(
        _ action: RuntimeKeyboardAction,
        interceptionOutcome: EventInterceptionOutcome
    ) -> Bool {
        guard activeTransaction?.commitState != nil else {
            return false
        }

        if
            action == .escape,
            interceptionOutcome.decision == .intercept
        {
            cancelCurrentTransaction(reason: .escape)
            return true
        }

        guard
            case let .navigation(key, modifiers) = action,
            key == .returnKey,
            !modifiers.containsNavigationModifier
        else {
            return false
        }
        return true
    }

    private func isBrowserSurfaceAction(
        _ action: RuntimeKeyboardAction
    ) -> Bool {
        switch action {
        case .navigation, .escape, .reset, .backspace:
            return true
        case let .character(character, _):
            return character == " "
                || EmojiAliasSyntax.isValidToken(String(character))
        case .ignore:
            return false
        }
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
            let characterText = String(character)
            guard characterText == " "
                    || EmojiAliasSyntax.isValidToken(characterText) else {
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
            let nextQuery: String
            if characterText == " " {
                guard !transaction.browserQuery.isEmpty,
                      transaction.browserQuery.last != " " else {
                    return true
                }
                nextQuery = transaction.browserQuery + " "
            } else {
                nextQuery = transaction.browserQuery
                    + EmojiAliasSyntax.normalizedToken(characterText)
            }
            updateBrowserQuery(
                transactionID: transaction.transactionID,
                query: nextQuery
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

    private func handle(_ actions: [ShortcodeParserAction]) {
        for (index, action) in actions.enumerated() {
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
                guard
                    var transaction = activeTransaction,
                    transaction.transactionID == transactionID
                else {
                    continue
                }
                armShortcodeInactivityTimeout(for: &transaction)
                activeTransaction = transaction
                guard
                    interceptionGate.isEventRevisionCurrent(
                        processingEventRevision
                    )
                else {
                    continue
                }
                hideSurface(
                    preservingExactCommitPrediction: true
                )

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
                let beginsFreshSession = actions
                    .dropFirst(index + 1)
                    .contains { laterAction in
                        if case .began = laterAction {
                            return true
                        }
                        return false
                    }
                clear(
                    transactionID: transactionID,
                    preservingFreshSession: beginsFreshSession
                )
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
            selectedIndex: -1,
            visibleMode: .hidden,
            browserQuery: "",
            captureGeneration: 0,
            activityRevision: 0,
            bundleIdentifier: nil,
            commitState: nil,
            predictionGeneration: processingPredictionGeneration,
            presentationInteractionRevision:
                processingInteractionRevision
                    ?? interceptionGate.interactionRevision,
            canAcceptSelection: true
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
        if let processingInteractionRevision {
            transaction.presentationInteractionRevision =
                processingInteractionRevision
        }
        setResults(
            Array(
                searchIndex.search(
                    query,
                    usage: usageSnapshot,
                    limit: max(configuration.suggestionLimit, 1)
                )
            ),
            in: &transaction
        )
        transaction.selectedIndex = -1
        armShortcodeInactivityTimeout(for: &transaction)
        activeTransaction = transaction

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
        guard
            let result = searchIndex.exactMatch(
                for: shortcode,
                usage: usageSnapshot
            )
        else {
            clear(transactionID: transactionID)
            return
        }
        guard beginCommit(
            transactionID: transactionID,
            item: result.item
        ) else {
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
        if let processingInteractionRevision {
            transaction.presentationInteractionRevision =
                processingInteractionRevision
        }
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
        if let processingInteractionRevision {
            transaction.presentationInteractionRevision =
                processingInteractionRevision
        }
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
        if transaction.results.indices.contains(
            transaction.selectedIndex
        ) {
            let nextIndex = transaction.selectedIndex + delta
            transaction.selectedIndex = transaction.results.indices
                .contains(nextIndex) ? nextIndex : -1
        } else {
            transaction.selectedIndex = delta < 0 ? count - 1 : 0
        }
        if let processingInteractionRevision {
            transaction.presentationInteractionRevision =
                processingInteractionRevision
        }
        armShortcodeInactivityTimeout(for: &transaction)
        activeTransaction = transaction
        present(transaction)
        prepareSelectedAdaptiveGlyphIfUseful(in: transaction)
    }

    private func armShortcodeInactivityTimeout(
        for transaction: inout ActiveTransaction
    ) {
        transaction.activityRevision &+= 1
        let timeout = configuration.preferences.shortcode.parserTimeout
        guard timeout > 0 else {
            return
        }
        let transactionID = transaction.transactionID
        let activityRevision = transaction.activityRevision
        let timeoutMilliseconds = Int(timeout * 1_000)
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
        guard var transaction = activeTransaction,
              transaction.transactionID == transactionID else {
            clear(transactionID: transactionID)
            return
        }
        let acceptedIndex = transaction.results.indices.contains(
            transaction.selectedIndex
        ) ? transaction.selectedIndex : 0
        guard transaction.results.indices.contains(acceptedIndex) else {
            clear(transactionID: transactionID)
            return
        }
        transaction.selectedIndex = acceptedIndex
        if let token {
            transaction.expectedToken = token.rendered
        }
        activeTransaction = transaction
        let item = transaction.results[acceptedIndex].item
        guard beginCommit(
            transactionID: transactionID,
            item: item
        ) else {
            return
        }
        scheduleCapture(
            transactionID: transactionID,
            expectedToken: transaction.expectedToken,
            purpose: .insert(item: item)
        )
    }

    @discardableResult
    private func beginCommit(
        transactionID: ParserTransactionID,
        item: EmojiItem
    ) -> Bool {
        guard
            var transaction = activeTransaction,
            transaction.transactionID == transactionID
        else {
            return false
        }
        guard let gateGeneration = interceptionGate.activateCommit(
            interactionRevision: processingInteractionRevision,
            acceptsTab: configuration.preferences.shortcode.acceptsTab,
            acceptsReturn: true
        ) else {
            cancelCurrentTransaction(reason: .externallyCancelled)
            return false
        }
        let showsProgress: Bool
        if case .media = item.content {
            showsProgress = true
            transaction.visibleMode = .committing
        } else {
            showsProgress = false
            transaction.visibleMode = .hidden
        }
        transaction.activityRevision &+= 1
        transaction.commitState = ActiveTransaction.CommitState(
            gateGeneration: gateGeneration
        )
        activeTransaction = transaction
        if showsProgress {
            scheduleCommitProgress(
                transactionID: transactionID
            )
        } else {
            hideSurface(preservingInterceptionMode: true)
        }
        return true
    }

    private func scheduleCommitProgress(
        transactionID: ParserTransactionID
    ) {
        queue.asyncAfter(
            deadline: .now() + .milliseconds(120)
        ) { [weak self] in
            guard
                let self,
                let transaction = activeTransaction,
                transaction.transactionID == transactionID,
                transaction.visibleMode == .committing,
                transaction.commitState != nil,
                let caretBounds = transaction.caretBounds,
                transaction.presentationRows.indices.contains(
                    transaction.selectedIndex
                )
            else {
                return
            }

            uiRevision &+= 1
            let selectedRow = transaction.presentationRows[
                transaction.selectedIndex
            ]
            let snapshot = RuntimeSuggestionPanelSnapshot(
                revision: uiRevision,
                transactionID: transactionID,
                mode: .committing,
                rows: [selectedRow],
                selectedIndex: 0,
                query: nil,
                trigger: configuration.preferences.shortcode.trigger,
                acceptsTab: false,
                acceptsReturn: false
            )
            let update = RuntimeSuggestionPanelUpdate.show(
                snapshot: snapshot,
                quartzCaretBounds: caretBounds
            )
            let bridge = mainActorBridge
            Task { @MainActor in
                bridge.apply(update)
            }
        }
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

    private func scheduleContextRecovery() {
        guard captureEnabled else {
            cancelContextRecovery()
            return
        }
        needsContextRecovery = true
        contextRecoveryGeneration &+= 1
        if contextRecoveryGeneration == 0 {
            contextRecoveryGeneration = 1
        }
        let generation = contextRecoveryGeneration
        let delay = configuration.accessibilitySettleDelayMilliseconds
        queue.asyncAfter(
            deadline: .now() + .milliseconds(delay)
        ) { [weak self] in
            self?.performContextRecovery(
                generation: generation,
                attempt: 0
            )
        }
    }

    private func performContextRecovery(
        generation: UInt64,
        attempt: Int
    ) {
        guard
            captureEnabled,
            needsContextRecovery,
            generation == contextRecoveryGeneration,
            activeTransaction == nil,
            parser.state == .idle
        else {
            return
        }
        do {
            guard let contextRecoveryTarget else {
                failContextRecovery(reason: .focusChanged)
                return
            }
            let configuredTrigger =
                configuration.preferences.shortcode.trigger
            let capture = try contextProvider.captureCurrentToken(
                trigger: configuredTrigger.character
            )
            guard
                contextProvider.representsSameTarget(
                    contextRecoveryTarget,
                    capture.target
                )
            else {
                failContextRecovery(reason: .focusChanged)
                return
            }
            guard
                let completeToken = capture.token,
                completeToken.first == configuredTrigger.character
            else {
                failContextRecovery(reason: .cursorMoved)
                return
            }
            needsContextRecovery = false
            self.contextRecoveryTarget = nil
            processingInteractionRevision =
                interceptionGate.interactionRevision
            defer {
                processingPredictionGeneration = nil
                processingInteractionRevision = nil
            }
            if
                recoverClosedTokenIfNeeded(
                    completeToken,
                    capture: capture,
                    trigger: configuredTrigger
                )
            {
                return
            }
            guard
                let renderedToken = capture.tokenPrefixThroughSelection,
                renderedToken.first == configuredTrigger.character,
                renderedToken.count == 1
                    || renderedToken.last
                        != configuredTrigger.character
            else {
                failContextRecovery(reason: .cursorMoved)
                return
            }
            let query = String(renderedToken.dropFirst())
            let token = ParsedShortcodeToken(
                trigger: configuredTrigger,
                query: EmojiAliasSyntax.normalizedToken(query),
                renderedQuery: query,
                isClosed: false
            )
            let canAcceptSelection = Self.canAcceptSelection(
                in: capture.context
            )
            let predictionGeneration = canAcceptSelection
                ? interceptionGate.restoreExactCommitPrediction(
                    expectedToken: renderedToken
                )
                : nil
            processingPredictionGeneration = predictionGeneration
            guard
                let transition = parser.restoreValidatedToken(token)
            else {
                failContextRecovery(reason: .cursorMoved)
                return
            }
            handle(transition.actions)
            guard var transaction = activeTransaction else {
                failContextRecovery(reason: .cursorMoved)
                return
            }
            transaction.sessionTarget = capture.target
            transaction.caretBounds = capture.context.caretBounds
            transaction.bundleIdentifier = capture.bundleIdentifier
            transaction.canAcceptSelection = canAcceptSelection
            activeTransaction = transaction
        } catch let error as RuntimeTextCaptureError {
            if
                error.isTransient,
                attempt < configuration.accessibilityRetryLimit
            {
                let delay = Self.accessibilityRetryDelayMilliseconds(
                    afterFailedAttempt: attempt
                )
                queue.asyncAfter(
                    deadline: .now() + .milliseconds(delay)
                ) { [weak self] in
                    self?.performContextRecovery(
                        generation: generation,
                        attempt: attempt + 1
                    )
                }
            } else {
                failContextRecovery(
                    reason: parserResetReason(for: error)
                )
                if case .denied = error {
                    emitDiagnostic(for: error)
                }
            }
        } catch {
            failContextRecovery(reason: .externallyCancelled)
        }
    }

    /// A closing trigger can arrive immediately after caret navigation, before
    /// the settled AX revalidation has re-armed the constant-time prediction.
    /// Recover that exact, closed token from AX and route it through the same
    /// guarded commit pipeline instead of leaving the literal shortcode.
    private func recoverClosedTokenIfNeeded(
        _ completeToken: String,
        capture: RuntimeTextCapture,
        trigger: ShortcodeTrigger
    ) -> Bool {
        guard
            completeToken.count > 1,
            completeToken.last == trigger.character
        else {
            return false
        }
        guard
            configuration.preferences.shortcode
                .replacesOnExactClosingTrigger,
            Self.canAcceptSelection(in: capture.context)
        else {
            failContextRecovery(reason: .cursorMoved)
            return true
        }
        let renderedQuery = String(
            completeToken.dropFirst().dropLast()
        )
        let normalizedQuery = EmojiAliasSyntax.normalizedToken(
            renderedQuery
        )
        guard
            !normalizedQuery.isEmpty,
            EmojiAliasSyntax.isValidToken(normalizedQuery)
        else {
            failContextRecovery(reason: .cursorMoved)
            return true
        }
        let openToken = ParsedShortcodeToken(
            trigger: trigger,
            query: normalizedQuery,
            renderedQuery: renderedQuery,
            isClosed: false
        )
        guard let transition = parser.restoreValidatedToken(openToken) else {
            failContextRecovery(reason: .cursorMoved)
            return true
        }
        handle(transition.actions)
        guard var transaction = activeTransaction else {
            failContextRecovery(reason: .cursorMoved)
            return true
        }
        transaction.sessionTarget = capture.target
        transaction.caretBounds = capture.context.caretBounds
        transaction.bundleIdentifier = capture.bundleIdentifier
        transaction.canAcceptSelection = true
        activeTransaction = transaction
        let closingTransition = parser.handle(
            .character(trigger.character)
        )
        handle(closingTransition.actions)
        return true
    }

    private func cancelContextRecovery() {
        needsContextRecovery = false
        contextRecoveryTarget = nil
        contextRecoveryGeneration &+= 1
    }

    private func abandonContextRecovery() {
        cancelContextRecovery()
        hideSurface()
    }

    private func failContextRecovery(reason: ParserResetReason) {
        cancelContextRecovery()
        cancelCurrentTransaction(reason: reason)
    }

    private func suspendCurrentTransactionForContextRecovery() {
        if contextRecoveryTarget == nil {
            contextRecoveryTarget = activeTransaction?.sessionTarget
        }
        if parser.state.session != nil {
            _ = parser.handle(.reset(.cursorMoved))
        }
        if let commitState = activeTransaction?.commitState {
            _ = interceptionGate.finishCommit(
                generation: commitState.gateGeneration,
                retainingPendingSend: false
            )
        }
        cancelPendingSend()
        activeTransaction = nil
        retainSurfacePresentationDuringRefresh()
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
        if
            let commitState = current.commitState,
            !interceptionGate.isCommitActive(
                generation: commitState.gateGeneration
            )
        {
            clear(transactionID: transactionID)
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
                let delay = Self.accessibilityRetryDelayMilliseconds(
                    afterFailedAttempt: attempt
                )
                queue.asyncAfter(deadline: .now() + .milliseconds(delay)) {
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

    private static func accessibilityRetryDelayMilliseconds(
        afterFailedAttempt attempt: Int
    ) -> Int {
        min(60, 12 << min(max(0, attempt), 3))
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
        if
            let commitState = transaction.commitState,
            !interceptionGate.isCommitActive(
                generation: commitState.gateGeneration
            )
        {
            clear(transactionID: transactionID)
            return
        }
        if let target = transaction.sessionTarget {
            guard
                contextProvider.representsSameTarget(
                    target,
                    capture.target
                )
            else {
                cancelCurrentTransaction(reason: .focusChanged)
                return
            }
        } else {
            transaction.sessionTarget = capture.target
        }
        transaction.caretBounds = capture.context.caretBounds
        transaction.bundleIdentifier = capture.bundleIdentifier
        transaction.canAcceptSelection = Self.canAcceptSelection(
            in: capture.context
        )
        activeTransaction = transaction
        diagnosticHandler?(.sessionAllowed)

        switch purpose {
        case .establishSession:
            if transaction.canAcceptSelection {
                verifyExactCommitPrediction(for: transaction)
            }
        case .showSuggestions:
            transaction.visibleMode = .suggestions
            activeTransaction = transaction
            if transaction.canAcceptSelection {
                verifyExactCommitPrediction(for: transaction)
            }
            present(transaction)
            prepareSelectedAdaptiveGlyphIfUseful(in: transaction)
        case .revalidateCaretMovement:
            transaction.visibleMode = .suggestions
            if transaction.canAcceptSelection {
                transaction.predictionGeneration = interceptionGate
                    .restoreExactCommitPrediction(
                        expectedToken: expectedToken
                    )
            } else {
                transaction.predictionGeneration = nil
            }
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

    private func verifyExactCommitPrediction(
        for transaction: ActiveTransaction
    ) {
        let trigger = configuration.preferences.shortcode.trigger
        guard
            transaction.expectedToken.first == trigger.character,
            transaction.expectedToken.last != trigger.character
                || transaction.expectedToken.count == 1
        else {
            return
        }
        interceptionGate.verifyExactCommitPrediction(
            generation: transaction.predictionGeneration,
            expectedToken: transaction.expectedToken
        )
    }

    private func refreshExactCommitPredictionConfiguration() {
        interceptionGate.configureExactCommitPrediction(
            trigger: configuration.preferences.shortcode.trigger.character,
            isEnabled: configuration.preferences.shortcode
                .replacesOnExactClosingTrigger,
            exactTokens: searchIndex.exactTokens(usage: usageSnapshot)
        )
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
        guard
            let commitGeneration = activeTransaction?
                .commitState?.gateGeneration
        else {
            clear(transactionID: transactionID)
            return
        }
        let gate = interceptionGate
        Task { @MainActor [weak self] in
            let result = await bridge.insertUnicode(
                value: value,
                replacing: request,
                authorization: { [gate] in
                    gate.isCommitActive(
                        generation: commitGeneration
                    )
                }
            )
            guard let self else {
                return
            }
            queue.async { [weak self] in
                guard let self else {
                    return
                }
                guard let result else {
                    clear(transactionID: transactionID)
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
                completeTransactionAfterInsertion(
                    result,
                    request: request,
                    transactionID: transactionID
                )
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
            captureBundleIdentifier == Self.messagesBundleIdentifier
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
        guard let commitGeneration =
            transaction.commitState?.gateGeneration
        else {
            clear(transactionID: transactionID)
            return
        }
        let gate = interceptionGate
        Task { @MainActor [weak self] in
            let result = await bridge.insertDownloadedMediaIfAuthorized(
                payload,
                replacing: request,
                authorization: { [gate] in
                    gate.isCommitActive(
                        generation: commitGeneration
                    )
                }
            )
            guard let self else {
                return
            }
            queue.async { [weak self] in
                guard let self else {
                    return
                }
                guard let result else {
                    clear(transactionID: transactionID)
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
                completeTransactionAfterInsertion(
                    result,
                    request: request,
                    transactionID: transactionID
                )
            }
        }
    }

    private func completeTransactionAfterInsertion(
        _ result: InsertionResult,
        request: AccessibilityReplacementRequest,
        transactionID: ParserTransactionID
    ) {
        guard
            case .inserted = result,
            let transaction = activeTransaction,
            transaction.transactionID == transactionID,
            let commitState = transaction.commitState,
            interceptionGate.finishCommit(
                generation: commitState.gateGeneration,
                retainingPendingSend: true
            )
        else {
            clear(transactionID: transactionID)
            return
        }

        let bridge = mainActorBridge
        let queue = queue
        let gate = interceptionGate
        pendingSendTask?.cancel()
        pendingSendGeneration &+= 1
        let sendGeneration = pendingSendGeneration
        pendingSendTask = Task { @MainActor [weak self] in
            guard
                let self,
                await confirmPendingSend(
                    transactionID: transactionID,
                    generation: sendGeneration,
                    gateGeneration: commitState.gateGeneration
                )
            else {
                return
            }
            let couldPostBeforeSend = bridge.canSendSyntheticEvents
            let sent = await bridge.sendReturnAfterConfirmedInsertion(
                replacing: request,
                claimSend: { [gate] in
                    gate.claimPendingCommitSend(
                        generation: commitState.gateGeneration
                    )
                }
            )
            let sendPermissionUnavailable =
                !sent
                && (
                    !couldPostBeforeSend
                        || !bridge.canSendSyntheticEvents
                )
            queue.async { [weak self] in
                guard
                    let self,
                    pendingSendGeneration == sendGeneration
                else {
                    return
                }
                if sendPermissionUnavailable {
                    diagnosticHandler?(.sendAfterInsertionUnavailable)
                }
                pendingSendTask = nil
                clear(transactionID: transactionID)
            }
        }
    }

    private func confirmPendingSend(
        transactionID: ParserTransactionID,
        generation: UInt64,
        gateGeneration: UInt64
    ) async -> Bool {
        await withCheckedContinuation { continuation in
            queue.async { [weak self] in
                guard
                    let self,
                    pendingSendGeneration == generation,
                    let transaction = activeTransaction,
                    transaction.transactionID == transactionID,
                    transaction.commitState?.gateGeneration
                        == gateGeneration,
                    interceptionGate.hasPendingCommitSend(
                        generation: gateGeneration
                    )
                else {
                    continuation.resume(returning: false)
                    return
                }
                continuation.resume(returning: true)
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
        let selectedIndex = transaction.results.indices.contains(
            transaction.selectedIndex
        ) ? transaction.selectedIndex : 0
        guard
            transaction.bundleIdentifier == Self.messagesBundleIdentifier,
            let managedMediaRoot,
            transaction.results.indices.contains(selectedIndex)
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
        case .hidden, .committing:
            return
        }
        guard query.utf8.count >= 3 else {
            return
        }

        let item = transaction.results[selectedIndex].item
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
        for mediaType: AssetFormat
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
            bundleIdentifier == Self.messagesBundleIdentifier
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
            let caretBounds = transaction.caretBounds
        else {
            hideSurface()
            return
        }

        uiRevision &+= 1
        let hasSelection = !transaction.results.isEmpty
        let isBrowser = transaction.visibleMode == .browser
        let acceptsTab = hasSelection
            && transaction.canAcceptSelection
            && (isBrowser
                || configuration.preferences.shortcode.acceptsTab)
        let acceptsReturn = hasSelection
            && transaction.canAcceptSelection
            && (isBrowser
                || configuration.preferences.shortcode.acceptsReturn)
        let snapshot = RuntimeSuggestionPanelSnapshot(
            revision: uiRevision,
            transactionID: transaction.transactionID,
            mode: transaction.visibleMode,
            rows: transaction.presentationRows,
            selectedIndex: transaction.selectedIndex,
            query: transaction.visibleMode == .browser
                ? transaction.browserQuery
                : nil,
            trigger: configuration.preferences.shortcode.trigger,
            acceptsTab: acceptsTab,
            acceptsReturn: acceptsReturn
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
        guard interceptionGate.expectPresentation(
            revision: revision,
            interactionRevision:
                transaction.presentationInteractionRevision
        ) else {
            return
        }
        let gate = interceptionGate
        suggestionPresentationTask?.cancel()
        suggestionPresentationTask = Task { @MainActor [weak self] in
            guard !Task.isCancelled else {
                return
            }
            let result = await bridge.applyReportingVisibility(
                update,
                willApply: {
                    gate.activatePresentation(
                        revision: revision,
                        mode: mode,
                        acceptsTab: acceptsTab,
                        acceptsReturn: acceptsReturn,
                        revalidatesTextEdits:
                            mode == .suggestions
                                && !transaction.canAcceptSelection
                    )
                }
            )
            guard !Task.isCancelled else {
                return
            }
            queue.async { [weak self] in
                self?.finishSuggestionPresentation(
                    revision: revision,
                    transactionID: transactionID,
                    mode: mode,
                    result: result
                )
            }
        }
    }

    private func finishSuggestionPresentation(
        revision: UInt64,
        transactionID: ParserTransactionID,
        mode: RuntimeInterceptionMode,
        result: RuntimePresentationApplicationResult
    ) {
        guard
            uiRevision == revision,
            activeTransaction?.transactionID == transactionID,
            activeTransaction?.visibleMode == mode
        else {
            return
        }
        suggestionPresentationTask = nil
        guard case let .applied(isVisible) = result else {
            return
        }
        guard isVisible else {
            cancelCurrentTransaction(reason: .externallyCancelled)
            return
        }
    }

    private func hideSurface(
        preservingInterceptionMode: Bool = false,
        preservingExactCommitPrediction: Bool = false
    ) {
        suggestionPresentationTask?.cancel()
        suggestionPresentationTask = nil
        if
            !preservingInterceptionMode,
            !preservingExactCommitPrediction
        {
            interceptionGate.disarmExactCommit()
        }
        if var transaction = activeTransaction {
            transaction.visibleMode = .hidden
            activeTransaction = transaction
        }
        uiRevision &+= 1
        interceptionGate.invalidatePresentation(revision: uiRevision)
        if !preservingInterceptionMode {
            interceptionGate.setMode(
                .hidden,
                acceptsTab: configuration.preferences.shortcode.acceptsTab,
                acceptsReturn:
                    configuration.preferences.shortcode.acceptsReturn,
                preservingExactCommitPrediction:
                    preservingExactCommitPrediction
            )
        }
        let update = RuntimeSuggestionPanelUpdate.hide(revision: uiRevision)
        let bridge = mainActorBridge
        Task { @MainActor in
            bridge.apply(update)
        }
    }

    private func retainSurfacePresentationDuringRefresh() {
        suggestionPresentationTask?.cancel()
        suggestionPresentationTask = nil
        // Preserve an already-armed suggestions gate so immediate acceptance
        // remains responsive. Initial presentation is still fail-closed
        // because the gate begins hidden and is armed only after visibility is
        // confirmed.
        // Invalidate any in-flight presentation completion without ordering
        // the current panel out. The next verified capture updates it in place.
        uiRevision &+= 1
        interceptionGate.invalidatePresentation(revision: uiRevision)
        let update = RuntimeSuggestionPanelUpdate.retain(
            revision: uiRevision
        )
        let bridge = mainActorBridge
        Task { @MainActor in
            bridge.apply(update)
        }
    }

    private func clear(
        transactionID: ParserTransactionID,
        preservingFreshSession: Bool = false
    ) {
        guard activeTransaction?.transactionID == transactionID else {
            return
        }
        if let commitState = activeTransaction?.commitState {
            _ = interceptionGate.finishCommit(
                generation: commitState.gateGeneration,
                retainingPendingSend: false
            )
        }
        cancelPendingSend()
        activeTransaction = nil
        hideSurface(
            preservingInterceptionMode: preservingFreshSession,
            preservingExactCommitPrediction: preservingFreshSession
        )
    }

    private func cancelCurrentTransaction(reason: ParserResetReason) {
        if parser.state.session != nil {
            _ = parser.handle(.reset(reason))
        }
        if let commitState = activeTransaction?.commitState {
            _ = interceptionGate.finishCommit(
                generation: commitState.gateGeneration,
                retainingPendingSend: false
            )
        }
        cancelPendingSend()
        activeTransaction = nil
        hideSurface()
    }

    private static func canAcceptSelection(
        in context: AccessibilityTextContext
    ) -> Bool {
        guard
            context.selection.length == 0,
            let tokenRange = context.tokenRange,
            tokenRange.location <= Int.max - tokenRange.length
        else {
            return false
        }
        return tokenRange.location + tokenRange.length
            == context.selection.location
    }

    private func cancelPendingSend() {
        pendingSendGeneration &+= 1
        pendingSendTask?.cancel()
        pendingSendTask = nil
    }

    private func cancelAllTransactions(reason: ParserResetReason) {
        cancelContextRecovery()
        cancelCurrentTransaction(reason: reason)
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
