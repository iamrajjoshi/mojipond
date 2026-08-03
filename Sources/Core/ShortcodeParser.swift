import Foundation

struct ParserTransactionID: RawRepresentable, Codable, Hashable, Comparable, Sendable {
    let rawValue: UInt64

    static func < (lhs: ParserTransactionID, rhs: ParserTransactionID) -> Bool {
        lhs.rawValue < rhs.rawValue
    }
}

struct ParserModifiers: OptionSet, Codable, Hashable, Sendable {
    let rawValue: UInt

    static let shift = ParserModifiers(rawValue: 1 << 0)
    static let control = ParserModifiers(rawValue: 1 << 1)
    static let option = ParserModifiers(rawValue: 1 << 2)
    static let command = ParserModifiers(rawValue: 1 << 3)
    static let capsLock = ParserModifiers(rawValue: 1 << 4)
    static let function = ParserModifiers(rawValue: 1 << 5)

    var containsUnsupportedTypingModifier: Bool {
        !intersection([.control, .option, .command, .function]).isEmpty
    }

    var containsNavigationModifier: Bool {
        !subtracting(.capsLock).isEmpty
    }
}

enum ParserNavigationKey: Equatable, Sendable {
    case arrowUp
    case arrowDown
    case tab
    case returnKey
}

enum ParserResetReason: Equatable, Sendable {
    case focusChanged
    case applicationChanged
    case mouseClick
    case cursorMoved
    case unsupportedModifiers
    case invalidCharacter(Character)
    case escape
    case timeout
    case screenLocked
    case permissionLost
    case secureInput
    case deadKeyOrIME
    case openingTriggerDeleted
    case exactReplacementDisabled
    case doubleTriggerDisabled
    case acceptanceDisabled
    case externallyCancelled
}

enum ShortcodeParserInput: Equatable, Sendable {
    case character(Character, modifiers: ParserModifiers = [])
    case backspace(modifiers: ParserModifiers = [])
    case navigation(ParserNavigationKey, modifiers: ParserModifiers = [])
    case escape
    /// Reset events model focus/app changes, pointer or cursor movement,
    /// dead-key/IME composition, secure input, screen lock, and permission loss.
    case reset(ParserResetReason)
    /// Allows a coordinator timer to expire a session even when no new key
    /// arrives.
    case timeout
}

struct ParsedShortcodeToken: Equatable, Sendable {
    let trigger: ShortcodeTrigger
    let query: String
    let renderedQuery: String
    let isClosed: Bool

    init(
        trigger: ShortcodeTrigger,
        query: String,
        renderedQuery: String? = nil,
        isClosed: Bool
    ) {
        self.trigger = trigger
        self.query = query
        self.renderedQuery = renderedQuery ?? query
        self.isClosed = isClosed
    }

    var rendered: String {
        let close = isClosed ? String(trigger.character) : ""
        return "\(trigger.rawValue)\(renderedQuery)\(close)"
    }

    var utf16Length: Int {
        rendered.utf16.count
    }
}

struct ShortcodeParserSession: Equatable, Sendable {
    let transactionID: ParserTransactionID
    let openedAt: Date
    var lastInputAt: Date
    var query: String
    var renderedQuery: String
    var recoverableSuffixLength: Int

    init(
        transactionID: ParserTransactionID,
        openedAt: Date,
        lastInputAt: Date,
        query: String,
        renderedQuery: String? = nil,
        recoverableSuffixLength: Int
    ) {
        self.transactionID = transactionID
        self.openedAt = openedAt
        self.lastInputAt = lastInputAt
        self.query = query
        self.renderedQuery = renderedQuery ?? query
        self.recoverableSuffixLength = recoverableSuffixLength
    }

    func token(trigger: ShortcodeTrigger, closed: Bool = false) -> ParsedShortcodeToken {
        ParsedShortcodeToken(
            trigger: trigger,
            query: query,
            renderedQuery: renderedQuery,
            isClosed: closed
        )
    }
}

enum ShortcodeParserState: Equatable, Sendable {
    case idle
    case collecting(ShortcodeParserSession)

    var session: ShortcodeParserSession? {
        guard case let .collecting(session) = self else {
            return nil
        }
        return session
    }
}

enum ShortcodeParserAction: Equatable, Sendable {
    case began(ShortcodeParserSession)
    case updateSuggestions(
        transactionID: ParserTransactionID,
        query: String,
        token: ParsedShortcodeToken
    )
    case hideSuggestions(transactionID: ParserTransactionID)
    case requestExactReplacement(
        transactionID: ParserTransactionID,
        shortcode: String,
        token: ParsedShortcodeToken
    )
    case openBrowser(
        transactionID: ParserTransactionID,
        token: ParsedShortcodeToken
    )
    case moveSelection(
        transactionID: ParserTransactionID,
        direction: ParserNavigationKey
    )
    case acceptSelected(
        transactionID: ParserTransactionID,
        query: String,
        token: ParsedShortcodeToken
    )
    case reset(transactionID: ParserTransactionID, reason: ParserResetReason)
}

struct ShortcodeParserTransition: Equatable, Sendable {
    let previousState: ShortcodeParserState
    let currentState: ShortcodeParserState
    let actions: [ShortcodeParserAction]
    /// Only navigation and dismissal events owned by a visible suggestion
    /// panel are consumed. Typed token characters always reach the target app.
    let shouldConsumeEvent: Bool
}

struct ShortcodeParserConfiguration: Equatable, Sendable {
    var preferences: ShortcodePreferences
    var maximumTokenLength: Int

    init(
        preferences: ShortcodePreferences = ShortcodePreferences(),
        maximumTokenLength: Int = Shortcode.maximumLength
    ) {
        self.preferences = preferences
        self.maximumTokenLength = min(max(1, maximumTokenLength), Shortcode.maximumLength)
    }
}

/// An explicit, bounded state machine. It has no OS dependencies and is
/// intended to be owned by a single serial event coordinator.
struct ShortcodeParser: Sendable {
    private(set) var state: ShortcodeParserState = .idle
    var configuration: ShortcodeParserConfiguration

    private var nextTransactionID: UInt64
    private var dismissedTransactionID: ParserTransactionID? = nil

    init(
        configuration: ShortcodeParserConfiguration = ShortcodeParserConfiguration(),
        startingTransactionID: UInt64 = 1
    ) {
        self.configuration = configuration
        nextTransactionID = max(1, startingTransactionID)
    }

    @discardableResult
    mutating func handle(
        _ input: ShortcodeParserInput,
        at date: Date = Date()
    ) -> ShortcodeParserTransition {
        let originalState = state
        var actions: [ShortcodeParserAction] = []

        if expireIfNeeded(at: date, actions: &actions), input == .timeout {
            return transition(from: originalState, actions: actions, shouldConsume: false)
        }

        switch input {
        case let .character(character, modifiers):
            handleCharacter(character, modifiers: modifiers, at: date, actions: &actions)
            return transition(from: originalState, actions: actions, shouldConsume: false)

        case let .backspace(modifiers):
            handleBackspace(modifiers: modifiers, at: date, actions: &actions)
            return transition(from: originalState, actions: actions, shouldConsume: false)

        case let .navigation(key, modifiers):
            let shouldConsume = handleNavigation(
                key,
                modifiers: modifiers,
                at: date,
                actions: &actions
            )
            return transition(from: originalState, actions: actions, shouldConsume: shouldConsume)

        case .escape:
            let shouldConsume = panelIsVisible
            if
                shouldConsume,
                let session = state.session
            {
                dismissedTransactionID = session.transactionID
                actions.append(
                    .hideSuggestions(
                        transactionID: session.transactionID
                    )
                )
            } else {
                reset(.escape, actions: &actions)
            }
            return transition(from: originalState, actions: actions, shouldConsume: shouldConsume)

        case let .reset(reason):
            reset(reason, actions: &actions)
            return transition(from: originalState, actions: actions, shouldConsume: false)

        case .timeout:
            return transition(from: originalState, actions: actions, shouldConsume: false)
        }
    }

    /// Restores a parser session only after the runtime has rediscovered and
    /// validated an open token at the current caret through Accessibility.
    @discardableResult
    mutating func restoreValidatedToken(
        _ token: ParsedShortcodeToken,
        at date: Date = Date()
    ) -> ShortcodeParserTransition? {
        guard
            state == .idle,
            token.trigger == configuration.preferences.trigger,
            !token.isClosed,
            token.query.utf8.count <= configuration.maximumTokenLength,
            token.query.isEmpty
                || EmojiAliasSyntax.isValidToken(token.query)
        else {
            return nil
        }

        let originalState = state
        var actions: [ShortcodeParserAction] = []
        let session = ShortcodeParserSession(
            transactionID: ParserTransactionID(
                rawValue: nextTransactionID
            ),
            openedAt: date,
            lastInputAt: date,
            query: EmojiAliasSyntax.normalizedToken(token.query),
            renderedQuery: token.renderedQuery,
            recoverableSuffixLength: 0
        )
        dismissedTransactionID = nil
        nextTransactionID &+= 1
        state = .collecting(session)
        actions.append(.began(session))
        if
            !session.query.isEmpty
                || configuration.preferences
                    .showsSuggestionsOnBareTrigger
        {
            refreshSuggestions(for: session, actions: &actions)
        }
        return transition(
            from: originalState,
            actions: actions,
            shouldConsume: false
        )
    }

    private mutating func handleCharacter(
        _ character: Character,
        modifiers: ParserModifiers,
        at date: Date,
        actions: inout [ShortcodeParserAction]
    ) {
        if modifiers.containsUnsupportedTypingModifier {
            reset(.unsupportedModifiers, actions: &actions)
            return
        }

        guard case var .collecting(session) = state else {
            if character == configuration.preferences.trigger.character {
                beginSession(at: date, actions: &actions)
            }
            return
        }
        dismissedTransactionID = nil

        if session.recoverableSuffixLength > 0 {
            if
                character
                    == configuration.preferences.trigger.character
            {
                reset(.externallyCancelled, actions: &actions)
                beginSession(at: date, actions: &actions)
                return
            }
            if session.recoverableSuffixLength < Int.max {
                session.recoverableSuffixLength += 1
            }
            session.lastInputAt = date
            state = .collecting(session)
            actions.append(
                .hideSuggestions(
                    transactionID: session.transactionID
                )
            )
            return
        }

        if character == configuration.preferences.trigger.character {
            handleClosingTrigger(session: session, actions: &actions)
            return
        }

        guard EmojiAliasSyntax.isValidToken(String(character)) else {
            session.recoverableSuffixLength = 1
            session.lastInputAt = date
            state = .collecting(session)
            actions.append(
                .hideSuggestions(
                    transactionID: session.transactionID
                )
            )
            return
        }
        guard session.query.utf8.count < configuration.maximumTokenLength else {
            session.recoverableSuffixLength = 1
            session.lastInputAt = date
            state = .collecting(session)
            actions.append(
                .hideSuggestions(
                    transactionID: session.transactionID
                )
            )
            return
        }

        session.query.append(
            contentsOf: EmojiAliasSyntax.normalizedToken(String(character))
        )
        session.renderedQuery.append(character)
        session.lastInputAt = date
        state = .collecting(session)
        refreshSuggestions(for: session, actions: &actions)
    }

    private mutating func handleClosingTrigger(
        session: ShortcodeParserSession,
        actions: inout [ShortcodeParserAction]
    ) {
        if session.query.isEmpty {
            guard configuration.preferences.opensBrowserOnDoubleTrigger else {
                reset(.doubleTriggerDisabled, actions: &actions)
                return
            }
            let token = session.token(trigger: configuration.preferences.trigger, closed: true)
            state = .idle
            actions.append(.openBrowser(transactionID: session.transactionID, token: token))
            return
        }

        guard configuration.preferences.replacesOnExactClosingTrigger else {
            reset(.exactReplacementDisabled, actions: &actions)
            return
        }

        let token = session.token(trigger: configuration.preferences.trigger, closed: true)
        state = .idle
        actions.append(
            .requestExactReplacement(
                transactionID: session.transactionID,
                shortcode: session.query,
                token: token
            )
        )
    }

    private mutating func handleBackspace(
        modifiers: ParserModifiers,
        at date: Date,
        actions: inout [ShortcodeParserAction]
    ) {
        guard case var .collecting(session) = state else {
            return
        }
        dismissedTransactionID = nil
        if modifiers.containsUnsupportedTypingModifier {
            reset(.unsupportedModifiers, actions: &actions)
            return
        }
        if session.recoverableSuffixLength > 0 {
            session.recoverableSuffixLength -= 1
            session.lastInputAt = date
            state = .collecting(session)
            if session.recoverableSuffixLength > 0 {
                actions.append(
                    .hideSuggestions(
                        transactionID: session.transactionID
                    )
                )
            } else {
                refreshSuggestions(for: session, actions: &actions)
            }
            return
        }
        guard !session.query.isEmpty else {
            reset(.openingTriggerDeleted, actions: &actions)
            return
        }

        session.query.removeLast()
        session.renderedQuery.removeLast()
        session.lastInputAt = date
        state = .collecting(session)
        refreshSuggestions(for: session, actions: &actions)
    }

    private mutating func handleNavigation(
        _ key: ParserNavigationKey,
        modifiers: ParserModifiers,
        at date: Date,
        actions: inout [ShortcodeParserAction]
    ) -> Bool {
        guard case var .collecting(session) = state else {
            return false
        }
        if modifiers.containsNavigationModifier {
            reset(.unsupportedModifiers, actions: &actions)
            return false
        }
        guard panelIsVisible else {
            reset(.cursorMoved, actions: &actions)
            return false
        }

        switch key {
        case .arrowUp, .arrowDown:
            session.lastInputAt = date
            state = .collecting(session)
            actions.append(.moveSelection(transactionID: session.transactionID, direction: key))
            return true

        case .tab:
            guard configuration.preferences.acceptsTab else {
                reset(.acceptanceDisabled, actions: &actions)
                return false
            }
            accept(session, actions: &actions)
            return true

        case .returnKey:
            guard configuration.preferences.acceptsReturn else {
                reset(.acceptanceDisabled, actions: &actions)
                return false
            }
            accept(session, actions: &actions)
            return true
        }
    }

    private mutating func accept(
        _ session: ShortcodeParserSession,
        actions: inout [ShortcodeParserAction]
    ) {
        state = .idle
        actions.append(
            .acceptSelected(
                transactionID: session.transactionID,
                query: session.query,
                token: session.token(trigger: configuration.preferences.trigger)
            )
        )
    }

    private mutating func beginSession(
        at date: Date,
        actions: inout [ShortcodeParserAction]
    ) {
        let session = ShortcodeParserSession(
            transactionID: ParserTransactionID(rawValue: nextTransactionID),
            openedAt: date,
            lastInputAt: date,
            query: "",
            renderedQuery: "",
            recoverableSuffixLength: 0
        )
        dismissedTransactionID = nil
        nextTransactionID &+= 1
        state = .collecting(session)
        actions.append(.began(session))
        if configuration.preferences.showsSuggestionsOnBareTrigger {
            refreshSuggestions(for: session, actions: &actions)
        }
    }

    private func refreshSuggestions(
        for session: ShortcodeParserSession,
        actions: inout [ShortcodeParserAction]
    ) {
        guard
            !session.query.isEmpty
                || configuration.preferences.showsSuggestionsOnBareTrigger
        else {
            actions.append(
                .hideSuggestions(transactionID: session.transactionID)
            )
            return
        }
        actions.append(
            .updateSuggestions(
                transactionID: session.transactionID,
                query: session.query,
                token: session.token(
                    trigger: configuration.preferences.trigger
                )
            )
        )
    }

    @discardableResult
    private mutating func expireIfNeeded(
        at date: Date,
        actions: inout [ShortcodeParserAction]
    ) -> Bool {
        let timeout = configuration.preferences.parserTimeout
        guard timeout > 0,
              case let .collecting(session) = state,
              date.timeIntervalSince(session.lastInputAt) >= timeout else {
            return false
        }
        reset(.timeout, actions: &actions)
        return true
    }

    private mutating func reset(
        _ reason: ParserResetReason,
        actions: inout [ShortcodeParserAction]
    ) {
        guard case let .collecting(session) = state else {
            return
        }
        state = .idle
        dismissedTransactionID = nil
        actions.append(.reset(transactionID: session.transactionID, reason: reason))
    }

    private var panelIsVisible: Bool {
        guard case let .collecting(session) = state else {
            return false
        }
        return dismissedTransactionID != session.transactionID
            && session.recoverableSuffixLength == 0
            && (
                configuration.preferences.showsSuggestionsOnBareTrigger
                    || !session.query.isEmpty
            )
    }

    private func transition(
        from previousState: ShortcodeParserState,
        actions: [ShortcodeParserAction],
        shouldConsume: Bool
    ) -> ShortcodeParserTransition {
        ShortcodeParserTransition(
            previousState: previousState,
            currentState: state,
            actions: actions,
            shouldConsumeEvent: shouldConsume
        )
    }
}
