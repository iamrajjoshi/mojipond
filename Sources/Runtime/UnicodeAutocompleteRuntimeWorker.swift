import Foundation

enum UnicodeAutocompleteRuntimeDiagnostic: Equatable, Sendable {
    case unsupportedTarget
    case sessionDenied(RuntimeSessionDenial)
}

struct UnicodeAutocompleteRuntimeConfiguration: Equatable, Sendable {
    var preferences: MojiPondPreferences
    var suggestionLimit: Int
    var browserLimit: Int
    var accessibilitySettleDelayMilliseconds: Int
    var accessibilityRetryLimit: Int

    init(
        preferences: MojiPondPreferences = .defaults,
        suggestionLimit: Int = 5,
        browserLimit: Int = 12,
        accessibilitySettleDelayMilliseconds: Int = 12,
        accessibilityRetryLimit: Int = 2
    ) {
        self.preferences = preferences
        self.suggestionLimit = min(max(1, suggestionLimit), 5)
        self.browserLimit = min(max(5, browserLimit), 20)
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

    init(
        presenter: any RuntimeSuggestionPresenting,
        insertionEngine: InsertionEngine
    ) {
        self.presenter = presenter
        self.insertionEngine = insertionEngine
    }

    func apply(_ update: RuntimeSuggestionPanelUpdate) {
        presenter.apply(update)
    }

    func insert(
        value: String,
        replacing request: AccessibilityReplacementRequest
    ) async -> Bool {
        let result = await insertionEngine.insert(
            .unicode(value),
            replacing: request
        )
        if case .inserted = result {
            return true
        }
        return false
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

    private struct ActiveTransaction: @unchecked Sendable {
        let transactionID: ParserTransactionID
        var sessionTarget: AccessibilityTextTarget?
        var expectedToken: String
        var caretBounds: CGRect?
        var results: [EmojiSearchResult]
        var selectedIndex: Int
        var visibleMode: RuntimeInterceptionMode
        var captureGeneration: UInt64
    }

    private let queue: DispatchQueue
    private let interceptionGate: RuntimeInterceptionGate
    private let contextProvider: any RuntimeTextContextCapturing
    private let mainActorBridge: RuntimeMainActorBridge
    private let usageStore: (any EmojiUsageStore)?
    private let diagnosticHandler:
        (@Sendable (UnicodeAutocompleteRuntimeDiagnostic) -> Void)?

    private var parser: ShortcodeParser
    private var searchIndex: EmojiSearchIndex
    private var usageSnapshot: EmojiUsageSnapshot
    private var configuration: UnicodeAutocompleteRuntimeConfiguration
    private var activeTransaction: ActiveTransaction?
    private var captureEnabled = false
    private var uiRevision: UInt64 = 0

    init(
        searchIndex: EmojiSearchIndex,
        configuration: UnicodeAutocompleteRuntimeConfiguration,
        interceptionGate: RuntimeInterceptionGate,
        contextProvider: any RuntimeTextContextCapturing,
        mainActorBridge: RuntimeMainActorBridge,
        usageStore: (any EmojiUsageStore)? = nil,
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
        self.diagnosticHandler = diagnosticHandler
        usageSnapshot = initialUsageSnapshot
        parser = ShortcodeParser(
            configuration: ShortcodeParserConfiguration(
                preferences: configuration.preferences.shortcode
            )
        )
        queue = DispatchQueue(label: queueLabel, qos: .userInteractive)
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
                cancelCurrentTransaction(reason: .permissionLost)
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
            cancelCurrentTransaction(reason: .externallyCancelled)
        }
    }

    func updateSearchIndex(_ searchIndex: EmojiSearchIndex) {
        queue.async { [weak self] in
            guard let self else {
                return
            }
            self.searchIndex = searchIndex
            cancelCurrentTransaction(reason: .externallyCancelled)
        }
    }

    func updateUsageSnapshot(_ usageSnapshot: EmojiUsageSnapshot) {
        queue.async { [weak self] in
            self?.usageSnapshot = usageSnapshot
        }
    }

    func reset(_ reason: ParserResetReason) {
        queue.async { [weak self] in
            self?.cancelCurrentTransaction(reason: reason)
        }
    }

    func openBrowser() {
        queue.async { [weak self] in
            guard let self, captureEnabled else {
                return
            }
            cancelCurrentTransaction(reason: .externallyCancelled)
            let transition = parser.handle(
                .character(configuration.preferences.shortcode.trigger.character)
            )
            handle(transition.actions)
            let closing = parser.handle(
                .character(configuration.preferences.shortcode.trigger.character)
            )
            handle(closing.actions)
        }
    }

    private func process(_ snapshot: KeyboardEventSnapshot) {
        guard captureEnabled else {
            return
        }
        let action = RuntimeKeyboardEventMapper.action(for: snapshot)

        if activeTransaction?.visibleMode == .browser,
           handleBrowserAction(action) {
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
        case .character, .backspace:
            cancelCurrentTransaction(reason: .externallyCancelled)
            return false
        case .ignore:
            return true
        }
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
        activeTransaction = ActiveTransaction(
            transactionID: session.transactionID,
            sessionTarget: nil,
            expectedToken: token.rendered,
            caretBounds: nil,
            results: [],
            selectedIndex: 0,
            visibleMode: .hidden,
            captureGeneration: 0
        )
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
        transaction.results = unicodeResults(
            searchIndex.search(
                query,
                usage: usageSnapshot,
                limit: max(configuration.suggestionLimit * 4, 20)
            ),
            limit: configuration.suggestionLimit
        )
        transaction.selectedIndex = 0
        activeTransaction = transaction
        hideSurface()

        guard !transaction.results.isEmpty else {
            return
        }
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
            ),
            case .unicode = result.item.content
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
        guard var transaction = activeTransaction,
              transaction.transactionID == transactionID else {
            return
        }
        transaction.expectedToken = token.rendered
        transaction.results = unicodeResults(
            searchIndex.search(
                "",
                usage: usageSnapshot,
                limit: max(configuration.browserLimit * 4, 48)
            ),
            limit: configuration.browserLimit
        )
        transaction.selectedIndex = 0
        transaction.visibleMode = .hidden
        activeTransaction = transaction
        hideSurface()
        guard !transaction.results.isEmpty else {
            clear(transactionID: transactionID)
            return
        }
        scheduleCapture(
            transactionID: transactionID,
            expectedToken: token.rendered,
            purpose: .showBrowser
        )
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
        activeTransaction = transaction
        present(transaction)
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
        activeTransaction = transaction

        switch purpose {
        case .establishSession:
            break
        case .showSuggestions:
            transaction.visibleMode = .suggestions
            activeTransaction = transaction
            present(transaction)
        case .showBrowser:
            transaction.visibleMode = .browser
            activeTransaction = transaction
            present(transaction)
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
        guard let value = unicodeValue(for: item) else {
            clear(transactionID: transactionID)
            return
        }
        let selectedTone = selectedSkinTone(for: item)
        let bridge = mainActorBridge
        Task { @MainActor [weak self] in
            let didInsert = await bridge.insert(
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
                if didInsert, let usageStore {
                    Task {
                        try? await usageStore.recordUse(
                            itemID: item.id,
                            skinTone: selectedTone,
                            at: Date()
                        )
                    }
                }
                clear(transactionID: transactionID)
            }
        }
    }

    private func present(_ transaction: ActiveTransaction) {
        guard
            transaction.visibleMode != .hidden,
            let caretBounds = transaction.caretBounds,
            !transaction.results.isEmpty
        else {
            hideSurface()
            return
        }

        uiRevision &+= 1
        let snapshot = RuntimeSuggestionPanelSnapshot(
            revision: uiRevision,
            transactionID: transaction.transactionID,
            mode: transaction.visibleMode,
            rows: transaction.results.map { result in
                RuntimeSuggestionRow(
                    id: result.item.id,
                    glyph: unicodeValue(for: result.item) ?? "◇",
                    shortcode: result.item.shortcode.rawValue,
                    name: result.item.name
                )
            },
            selectedIndex: transaction.selectedIndex
        )
        interceptionGate.setMode(
            transaction.visibleMode,
            acceptsTab: configuration.preferences.shortcode.acceptsTab,
            acceptsReturn: configuration.preferences.shortcode.acceptsReturn
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

    private func unicodeResults(
        _ results: [EmojiSearchResult],
        limit: Int
    ) -> [EmojiSearchResult] {
        Array(
            results.lazy.filter {
                if case .unicode = $0.item.content {
                    return true
                }
                return false
            }.prefix(limit)
        )
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
            case .applicationUnknown, .excludedApplication:
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
