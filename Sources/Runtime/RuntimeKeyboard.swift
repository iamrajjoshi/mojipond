import CoreGraphics
import Foundation

enum RuntimeKeyboardAction: Equatable, Sendable {
    case character(Character, modifiers: ParserModifiers)
    case backspace(modifiers: ParserModifiers)
    case navigation(ParserNavigationKey, modifiers: ParserModifiers)
    case escape
    case reset(ParserResetReason)
    case ignore
}

/// Converts the immutable event-tap snapshot into the parser's OS-independent
/// input vocabulary. This work runs on MojiPond's serial runtime queue, never
/// in the event-tap callback.
enum RuntimeKeyboardEventMapper {
    static func action(for snapshot: KeyboardEventSnapshot) -> RuntimeKeyboardAction {
        guard let type = snapshot.type else {
            return .ignore
        }

        switch type {
        case .leftMouseDown, .rightMouseDown, .otherMouseDown:
            return .reset(.mouseClick)
        case .flagsChanged:
            return .ignore
        case .keyDown:
            break
        default:
            return .ignore
        }

        let modifiers = parserModifiers(
            from: snapshot.flags,
            for: snapshot.keyCode
        )
        if beginsSystemScreenshotFlow(snapshot) {
            return .ignore
        }
        switch snapshot.keyCode {
        case RuntimeKeyboardKeyCode.delete:
            return .backspace(modifiers: modifiers)
        case RuntimeKeyboardKeyCode.upArrow:
            return .navigation(.arrowUp, modifiers: modifiers)
        case RuntimeKeyboardKeyCode.downArrow:
            return .navigation(.arrowDown, modifiers: modifiers)
        case RuntimeKeyboardKeyCode.tab:
            return .navigation(.tab, modifiers: modifiers)
        case RuntimeKeyboardKeyCode.returnKey, RuntimeKeyboardKeyCode.keypadEnter:
            return .navigation(.returnKey, modifiers: modifiers)
        case RuntimeKeyboardKeyCode.escape:
            return .escape
        case RuntimeKeyboardKeyCode.leftArrow,
             RuntimeKeyboardKeyCode.rightArrow,
             RuntimeKeyboardKeyCode.home,
             RuntimeKeyboardKeyCode.end,
             RuntimeKeyboardKeyCode.pageUp,
             RuntimeKeyboardKeyCode.pageDown:
            return .reset(.cursorMoved)
        default:
            break
        }

        guard
            let characters = snapshot.characters,
            !characters.isEmpty
        else {
            return .reset(.deadKeyOrIME)
        }
        var iterator = characters.makeIterator()
        guard let character = iterator.next(), iterator.next() == nil else {
            return .reset(.deadKeyOrIME)
        }
        return .character(character, modifiers: modifiers)
    }

    static func parserModifiers(
        from flags: CGEventFlags,
        for keyCode: CGKeyCode? = nil
    ) -> ParserModifiers {
        var result: ParserModifiers = []
        if flags.contains(.maskShift) {
            result.insert(.shift)
        }
        if flags.contains(.maskControl) {
            result.insert(.control)
        }
        if flags.contains(.maskAlternate) {
            result.insert(.option)
        }
        if flags.contains(.maskCommand) {
            result.insert(.command)
        }
        if flags.contains(.maskAlphaShift) {
            result.insert(.capsLock)
        }
        if
            flags.contains(.maskSecondaryFn),
            keyCode.map({ !isPhysicalArrow($0) }) ?? true
        {
            result.insert(.function)
        }
        return result
    }

    static func hasUnsupportedInterceptionModifiers(
        _ snapshot: KeyboardEventSnapshot
    ) -> Bool {
        let modifiers = parserModifiers(
            from: snapshot.flags,
            for: snapshot.keyCode
        )
        switch snapshot.keyCode {
        case RuntimeKeyboardKeyCode.leftArrow,
             RuntimeKeyboardKeyCode.rightArrow,
             RuntimeKeyboardKeyCode.upArrow,
             RuntimeKeyboardKeyCode.downArrow,
             RuntimeKeyboardKeyCode.tab,
             RuntimeKeyboardKeyCode.returnKey,
             RuntimeKeyboardKeyCode.keypadEnter,
             RuntimeKeyboardKeyCode.escape,
             RuntimeKeyboardKeyCode.delete:
            return modifiers.containsNavigationModifier
        default:
            return modifiers.containsUnsupportedTypingModifier
        }
    }

    static func beginsSystemScreenshotFlow(
        _ snapshot: KeyboardEventSnapshot
    ) -> Bool {
        guard snapshot.type == .keyDown else {
            return false
        }
        let modifiers = parserModifiers(
            from: snapshot.flags,
            for: snapshot.keyCode
        )
        guard
            modifiers.contains([.command, .shift]),
            modifiers.subtracting([
                .command,
                .shift,
                .control,
                .capsLock
            ]).isEmpty
        else {
            return false
        }
        switch snapshot.keyCode {
        case RuntimeKeyboardKeyCode.digit3,
             RuntimeKeyboardKeyCode.digit4,
             RuntimeKeyboardKeyCode.digit5,
             RuntimeKeyboardKeyCode.digit6:
            return true
        default:
            return false
        }
    }

    private static func isPhysicalArrow(_ keyCode: CGKeyCode) -> Bool {
        switch keyCode {
        case RuntimeKeyboardKeyCode.leftArrow,
             RuntimeKeyboardKeyCode.rightArrow,
             RuntimeKeyboardKeyCode.upArrow,
             RuntimeKeyboardKeyCode.downArrow:
            true
        default:
            false
        }
    }
}

/// The only mutable state consulted synchronously by the event-tap callback.
/// Its critical section is bounded to a lock, a 64-character token, one hash
/// lookup, and key-code comparisons; parser, search, AX, storage, and UI work
/// never run here.
final class RuntimeInterceptionGate: @unchecked Sendable {
    private struct ExactCommitPrediction {
        let generation: UInt64
        let trigger: Character
        var token: String
        var recoverableSuffixLength = 0
        var isVerified = false
        var isClosed = false
    }

    private struct State {
        var captureEnabled = false
        var mode = RuntimeInterceptionMode.hidden
        var acceptsTab = true
        var acceptsReturn = true
        var presentationRevision: UInt64 = 0
        var presentationInteractionRevision: UInt64 = 0
        var exactCommitTrigger: Character = ":"
        var exactCommitEnabled = true
        var exactCommitTokens = Set<String>()
        var exactCommitPrediction: ExactCommitPrediction?
        var nextPredictionGeneration: UInt64 = 0
        var eventRevision: UInt64 = 0
        var interactionRevision: UInt64 = 0
        var nextCommitGeneration: UInt64 = 0
        var activeCommitGeneration: UInt64?
        var pendingCommitSendGeneration: UInt64?
        var preactivationCommitSendRevision: UInt64?
        var queuedAcceptanceRevision: UInt64?
        var canReplayCommitSend = true
        var systemScreenshotFlowActive = false
        var revalidatesTextEdits = false
        var suggestionPanelQuartzFrame: CGRect?
    }

    private let lock = NSLock()
    private var state = State()

    func setCaptureEnabled(_ enabled: Bool) {
        lock.withLock {
            state.captureEnabled = enabled
            if !enabled {
                state.mode = .hidden
                state.exactCommitPrediction = nil
                state.systemScreenshotFlowActive = false
                state.revalidatesTextEdits = false
                state.suggestionPanelQuartzFrame = nil
                clearCommitIntent(state: &state)
                state.interactionRevision &+= 1
            }
        }
    }

    func setCanReplayCommitSend(_ canReplay: Bool) {
        lock.withLock {
            state.canReplayCommitSend = canReplay
            if !canReplay {
                state.pendingCommitSendGeneration = nil
                state.preactivationCommitSendRevision = nil
            }
        }
    }

    func setMode(
        _ mode: RuntimeInterceptionMode,
        acceptsTab: Bool,
        acceptsReturn: Bool,
        preservingExactCommitPrediction: Bool = false
    ) {
        lock.withLock {
            let invalidatesInteraction =
                mode == .hidden
                    && !preservingExactCommitPrediction
                    && (
                        state.mode != .hidden
                            || state.exactCommitPrediction != nil
                    )
            state.mode = mode
            state.acceptsTab = acceptsTab
            state.acceptsReturn = acceptsReturn
            if invalidatesInteraction {
                clearCommitIntent(state: &state)
                state.interactionRevision &+= 1
            }
            if mode == .browser {
                state.exactCommitPrediction = nil
                clearCommitIntent(state: &state)
            }
            if mode == .hidden || mode == .browser {
                state.revalidatesTextEdits = false
            }
            if mode == .hidden {
                state.suggestionPanelQuartzFrame = nil
            }
        }
    }

    func setSuggestionPanelQuartzFrame(_ frame: CGRect?) {
        lock.withLock {
            guard
                state.mode == .suggestions || state.mode == .browser,
                let frame,
                frame.width > 0,
                frame.height > 0,
                frame.origin.x.isFinite,
                frame.origin.y.isFinite,
                frame.width.isFinite,
                frame.height.isFinite
            else {
                state.suggestionPanelQuartzFrame = nil
                return
            }
            state.suggestionPanelQuartzFrame = frame.standardized
        }
    }

    @discardableResult
    func expectPresentation(
        revision: UInt64,
        interactionRevision: UInt64
    ) -> Bool {
        lock.withLock {
            guard
                revision >= state.presentationRevision,
                interactionRevision == state.interactionRevision
            else {
                return false
            }
            state.presentationRevision = revision
            state.presentationInteractionRevision =
                interactionRevision
            return true
        }
    }

    var interactionRevision: UInt64 {
        lock.withLock {
            state.interactionRevision
        }
    }

    func isEventRevisionCurrent(_ revision: UInt64?) -> Bool {
        lock.withLock {
            guard let revision else {
                return false
            }
            return state.eventRevision == revision
        }
    }

    @discardableResult
    func activatePresentation(
        revision: UInt64,
        mode: RuntimeInterceptionMode,
        acceptsTab: Bool,
        acceptsReturn: Bool,
        revalidatesTextEdits: Bool = false
    ) -> Bool {
        lock.withLock {
            guard
                state.captureEnabled,
                state.presentationRevision == revision,
                state.presentationInteractionRevision
                    == state.interactionRevision,
                state.mode != .committing
            else {
                return false
            }
            state.mode = mode
            state.acceptsTab = acceptsTab
            state.acceptsReturn = acceptsReturn
            state.revalidatesTextEdits = revalidatesTextEdits
            return true
        }
    }

    func invalidatePresentation(revision: UInt64) {
        lock.withLock {
            state.presentationRevision = max(
                state.presentationRevision,
                revision
            )
        }
    }

    func configureExactCommitPrediction(
        trigger: Character,
        isEnabled: Bool,
        exactTokens: Set<String>
    ) {
        lock.withLock {
            state.exactCommitTrigger = trigger
            state.exactCommitEnabled = isEnabled
            state.exactCommitTokens = exactTokens
            state.exactCommitPrediction = nil
            state.revalidatesTextEdits = false
            state.interactionRevision &+= 1
            if state.mode == .committing {
                state.mode = .hidden
                state.presentationRevision &+= 1
            }
            clearCommitIntent(state: &state)
        }
    }

    func disarmExactCommit() {
        lock.withLock {
            state.exactCommitPrediction = nil
        }
    }

    /// Seeds the constant-time prediction from a token that Accessibility has
    /// rediscovered and validated after a pass-through caret or text edit.
    func restoreExactCommitPrediction(
        expectedToken: String
    ) -> UInt64? {
        lock.withLock {
            guard
                state.captureEnabled,
                state.exactCommitEnabled,
                expectedToken.first == state.exactCommitTrigger,
                expectedToken.count == 1
                    || expectedToken.last != state.exactCommitTrigger
            else {
                return nil
            }
            let query = String(expectedToken.dropFirst())
            guard
                query.utf8.count <= Shortcode.maximumLength,
                query.isEmpty || EmojiAliasSyntax.isValidToken(query)
            else {
                return nil
            }
            state.nextPredictionGeneration &+= 1
            if state.nextPredictionGeneration == 0 {
                state.nextPredictionGeneration = 1
            }
            let prediction = ExactCommitPrediction(
                generation: state.nextPredictionGeneration,
                trigger: state.exactCommitTrigger,
                token: EmojiAliasSyntax.normalizedToken(query),
                isVerified: true
            )
            state.exactCommitPrediction = prediction
            return prediction.generation
        }
    }

    @discardableResult
    func verifyExactCommitPrediction(
        generation: UInt64?,
        expectedToken: String
    ) -> Bool {
        lock.withLock {
            guard
                let generation,
                var prediction = state.exactCommitPrediction,
                prediction.generation == generation,
                prediction.recoverableSuffixLength == 0,
                expectedToken.first == prediction.trigger,
                expectedToken.last != prediction.trigger
                    || expectedToken.count == 1
            else {
                return false
            }
            let expectedQuery = EmojiAliasSyntax.normalizedToken(
                String(expectedToken.dropFirst())
            )
            guard prediction.token.hasPrefix(expectedQuery) else {
                return false
            }
            prediction.isVerified = true
            state.exactCommitPrediction = prediction
            if
                prediction.isClosed,
                state.exactCommitTokens.contains(prediction.token)
            {
                state.mode = .committing
            }
            return true
        }
    }

    @discardableResult
    func activateCommit(
        interactionRevision: UInt64?,
        acceptsTab: Bool,
        acceptsReturn: Bool
    ) -> UInt64? {
        lock.withLock {
            guard
                state.captureEnabled,
                let interactionRevision,
                state.interactionRevision == interactionRevision
            else {
                return nil
            }
            let carriesPreactivationSend =
                (
                    state.mode == .committing
                        || state.queuedAcceptanceRevision
                            == interactionRevision
                )
                && state.preactivationCommitSendRevision
                    == interactionRevision
            state.nextCommitGeneration &+= 1
            if state.nextCommitGeneration == 0 {
                state.nextCommitGeneration = 1
            }
            let generation = state.nextCommitGeneration
            state.activeCommitGeneration = generation
            state.pendingCommitSendGeneration =
                carriesPreactivationSend ? generation : nil
            state.preactivationCommitSendRevision = nil
            state.queuedAcceptanceRevision = nil
            state.mode = .committing
            state.suggestionPanelQuartzFrame = nil
            state.acceptsTab = acceptsTab
            state.acceptsReturn = acceptsReturn
            state.exactCommitPrediction = nil
            state.revalidatesTextEdits = false
            state.interactionRevision &+= 1
            return generation
        }
    }

    func hasPendingCommitSend(generation: UInt64) -> Bool {
        lock.withLock {
            state.mode == .committing
                && state.activeCommitGeneration == generation
                && state.pendingCommitSendGeneration == generation
        }
    }

    func isCommitActive(generation: UInt64) -> Bool {
        lock.withLock {
            state.mode == .committing
                && state.activeCommitGeneration == generation
        }
    }

    /// Atomically finishes a commit unless a successful insertion still needs
    /// to replay an intercepted Return.
    func finishCommit(
        generation: UInt64,
        retainingPendingSend: Bool
    ) -> Bool {
        lock.withLock {
            guard
                state.mode == .committing,
                state.activeCommitGeneration == generation
            else {
                return false
            }
            if
                retainingPendingSend,
                state.canReplayCommitSend,
                state.pendingCommitSendGeneration == generation
            {
                return true
            }
            state.mode = .hidden
            state.exactCommitPrediction = nil
            state.revalidatesTextEdits = false
            clearCommitIntent(state: &state)
            state.presentationRevision &+= 1
            state.interactionRevision &+= 1
            return false
        }
    }

    func claimPendingCommitSend(generation: UInt64) -> Bool {
        lock.withLock {
            guard
                state.mode == .committing,
                state.activeCommitGeneration == generation,
                state.pendingCommitSendGeneration == generation
            else {
                return false
            }
            state.pendingCommitSendGeneration = nil
            return true
        }
    }

    var mode: RuntimeInterceptionMode {
        lock.withLock {
            state.mode
        }
    }

    var isExactCommitArmed: Bool {
        lock.withLock {
            state.exactCommitPrediction?.isVerified == true
                && state.exactCommitPrediction?
                    .recoverableSuffixLength == 0
        }
    }

    func decision(for snapshot: KeyboardEventSnapshot) -> EventInterceptionDecision {
        outcome(for: snapshot).decision
    }

    func outcome(
        for snapshot: KeyboardEventSnapshot
    ) -> EventInterceptionOutcome {
        let (
            current,
            predictionGeneration,
            previousMode,
            passesUnreplayableReturn,
            preservesAutocompleteContext,
            requiresContextRecovery,
            preservesSuggestionSurface
        ) = lock.withLock {
            let previousMode = state.mode
            let wasCommitting = previousMode == .committing
            var passesUnreplayableReturn = false
            let preservesSystemInteraction =
                updateSystemScreenshotFlow(
                    for: snapshot,
                    state: &state
                )
            let preservesPanelInteraction =
                !preservesSystemInteraction
                    && Self.isSuggestionPanelInteraction(
                        snapshot,
                        state: state
                    )
            let preservesAutocompleteContext =
                preservesSystemInteraction || preservesPanelInteraction
            let generation: UInt64?
            let preservesSuggestionSurface =
                !preservesAutocompleteContext
                    && state.mode == .suggestions
                    && Self.movesCaretWithoutInterception(
                        snapshot.keyCode,
                        modifiers: RuntimeKeyboardEventMapper
                            .parserModifiers(
                                from: snapshot.flags,
                                for: snapshot.keyCode
                            )
                    )
            let requiresContextRecovery =
                !preservesAutocompleteContext
                    && Self.requiresContextRecovery(
                        for: snapshot,
                        state: state
                    )
            if preservesAutocompleteContext {
                generation = state.exactCommitPrediction?.generation
            } else {
                generation = updateExactCommitPrediction(
                    for: snapshot,
                    requiresContextRecovery: requiresContextRecovery,
                    state: &state
                )
            }
            if !preservesAutocompleteContext,
                state.captureEnabled,
                wasCommitting,
                state.mode == .committing,
                Self.isUnmodifiedReturn(snapshot)
            {
                if state.canReplayCommitSend {
                    if let commitGeneration =
                        state.activeCommitGeneration {
                        state.pendingCommitSendGeneration =
                            commitGeneration
                    } else {
                        state.preactivationCommitSendRevision =
                            state.interactionRevision
                    }
                } else {
                    passesUnreplayableReturn = true
                }
            } else if !preservesAutocompleteContext,
                state.captureEnabled,
                !wasCommitting,
                Self.isPresentationAcceptance(
                    snapshot,
                    mode: state.mode,
                    acceptsTab: state.acceptsTab,
                    acceptsReturn: state.acceptsReturn
                )
            {
                if
                    state.queuedAcceptanceRevision
                        == state.interactionRevision,
                    Self.isUnmodifiedReturn(snapshot)
                {
                    if state.canReplayCommitSend {
                        state.preactivationCommitSendRevision =
                            state.interactionRevision
                    } else {
                        passesUnreplayableReturn = true
                    }
                } else {
                    state.queuedAcceptanceRevision =
                        state.interactionRevision
                }
            } else if !preservesAutocompleteContext,
                state.queuedAcceptanceRevision
                    == state.interactionRevision
            {
                state.queuedAcceptanceRevision = nil
                state.preactivationCommitSendRevision = nil
            }
            return (
                state,
                generation,
                previousMode,
                passesUnreplayableReturn,
                preservesAutocompleteContext,
                requiresContextRecovery,
                preservesSuggestionSurface
            )
        }
        if preservesAutocompleteContext {
            return .passingThrough(
                predictionGeneration: predictionGeneration,
                interactionRevision: current.interactionRevision,
                eventRevision: current.eventRevision,
                preservesAutocompleteContext: true,
                requiresContextRecovery: false,
                preservesSuggestionSurface: false
            )
        }
        if
            current.captureEnabled,
            previousMode != .hidden,
            current.mode == .hidden,
            snapshot.type == .keyDown,
            snapshot.keyCode == RuntimeKeyboardKeyCode.escape,
            !RuntimeKeyboardEventMapper
                .hasUnsupportedInterceptionModifiers(snapshot)
        {
            return .intercepting(
                previousMode,
                predictionGeneration: predictionGeneration,
                interactionRevision: current.interactionRevision,
                eventRevision: current.eventRevision
            )
        }
        if passesUnreplayableReturn {
            return .passingThrough(
                predictionGeneration: predictionGeneration,
                interactionRevision: current.interactionRevision,
                eventRevision: current.eventRevision
            )
        }
        if requiresContextRecovery {
            return .passingThrough(
                predictionGeneration: predictionGeneration,
                interactionRevision: current.interactionRevision,
                eventRevision: current.eventRevision,
                requiresContextRecovery: true
            )
        }
        if preservesSuggestionSurface {
            return .passingThrough(
                predictionGeneration: predictionGeneration,
                interactionRevision: current.interactionRevision,
                eventRevision: current.eventRevision,
                preservesSuggestionSurface: true
            )
        }
        guard
            current.captureEnabled,
            current.mode != .hidden,
            snapshot.type == .keyDown,
            !RuntimeKeyboardEventMapper
                .hasUnsupportedInterceptionModifiers(snapshot)
        else {
            return .passingThrough(
                predictionGeneration: predictionGeneration,
                interactionRevision: current.interactionRevision,
                eventRevision: current.eventRevision
            )
        }

        if current.mode == .committing {
            let decision: EventInterceptionDecision = switch snapshot.keyCode {
            case RuntimeKeyboardKeyCode.returnKey,
                 RuntimeKeyboardKeyCode.keypadEnter,
                 RuntimeKeyboardKeyCode.escape:
                .intercept
            default:
                .passThrough
            }
            return decision == .intercept
                ? .intercepting(
                    .committing,
                    predictionGeneration: predictionGeneration,
                    interactionRevision: current.interactionRevision,
                    eventRevision: current.eventRevision
                )
                : .passingThrough(
                    predictionGeneration: predictionGeneration,
                    interactionRevision: current.interactionRevision,
                    eventRevision: current.eventRevision
                )
        }

        let decision: EventInterceptionDecision = switch snapshot.keyCode {
        case RuntimeKeyboardKeyCode.escape:
            .intercept
        case RuntimeKeyboardKeyCode.leftArrow,
             RuntimeKeyboardKeyCode.rightArrow:
            .passThrough
        case RuntimeKeyboardKeyCode.upArrow,
             RuntimeKeyboardKeyCode.downArrow:
            .intercept
        case RuntimeKeyboardKeyCode.tab:
            current.acceptsTab || current.mode == .browser
                ? .intercept
                : .passThrough
        case RuntimeKeyboardKeyCode.returnKey, RuntimeKeyboardKeyCode.keypadEnter:
            current.acceptsReturn || current.mode == .browser
                ? .intercept
                : .passThrough
        case RuntimeKeyboardKeyCode.delete:
            current.mode == .browser
                ? .intercept
                : .passThrough
        default:
            current.mode == .browser
                    && isValidBrowserQueryCharacter(snapshot.characters)
                ? .intercept
                : .passThrough
        }
        return decision == .intercept
            ? .intercepting(
                current.mode,
                predictionGeneration: predictionGeneration,
                interactionRevision: current.interactionRevision,
                eventRevision: current.eventRevision
            )
            : .passingThrough(
                predictionGeneration: predictionGeneration,
                interactionRevision: current.interactionRevision,
                eventRevision: current.eventRevision
            )
    }

    private func updateSystemScreenshotFlow(
        for snapshot: KeyboardEventSnapshot,
        state: inout State
    ) -> Bool {
        guard state.captureEnabled else {
            state.systemScreenshotFlowActive = false
            return false
        }
        if RuntimeKeyboardEventMapper.beginsSystemScreenshotFlow(snapshot) {
            state.systemScreenshotFlowActive =
                snapshot.keyCode == RuntimeKeyboardKeyCode.digit4
                    || snapshot.keyCode
                        == RuntimeKeyboardKeyCode.digit5
            return true
        }
        guard state.systemScreenshotFlowActive else {
            return false
        }
        switch snapshot.type {
        case .leftMouseDown, .rightMouseDown, .otherMouseDown:
            state.systemScreenshotFlowActive = false
            return true
        case .keyDown:
            switch snapshot.keyCode {
            case RuntimeKeyboardKeyCode.escape,
                 RuntimeKeyboardKeyCode.returnKey,
                 RuntimeKeyboardKeyCode.keypadEnter:
                state.systemScreenshotFlowActive = false
            default:
                break
            }
            return true
        case .flagsChanged:
            return true
        default:
            return false
        }
    }

    private static func isSuggestionPanelInteraction(
        _ snapshot: KeyboardEventSnapshot,
        state: State
    ) -> Bool {
        guard
            state.captureEnabled,
            state.mode == .suggestions || state.mode == .browser,
            let frame = state.suggestionPanelQuartzFrame,
            let location = snapshot.globalLocation
        else {
            return false
        }
        switch snapshot.type {
        case .leftMouseDown, .rightMouseDown, .otherMouseDown:
            return frame.contains(location)
        default:
            return false
        }
    }

    private func updateExactCommitPrediction(
        for snapshot: KeyboardEventSnapshot,
        requiresContextRecovery: Bool,
        state: inout State
    ) -> UInt64? {
        switch snapshot.type {
        case .leftMouseDown, .rightMouseDown, .otherMouseDown:
            state.eventRevision &+= 1
            state.exactCommitPrediction = nil
            state.mode = .hidden
            state.revalidatesTextEdits = false
            clearCommitIntent(state: &state)
            state.presentationRevision &+= 1
            state.interactionRevision &+= 1
            return nil
        case .keyDown:
            state.eventRevision &+= 1
            break
        default:
            return state.exactCommitPrediction?.generation
        }

        guard
            state.captureEnabled
        else {
            state.exactCommitPrediction = nil
            return nil
        }

        let modifiers = RuntimeKeyboardEventMapper.parserModifiers(
            from: snapshot.flags,
            for: snapshot.keyCode
        )
        if Self.movesCaretWithoutInterception(
            snapshot.keyCode,
            modifiers: modifiers
        ), state.mode == .suggestions
            || state.exactCommitPrediction != nil
        {
            let generation = state.exactCommitPrediction?.generation
            preserveSuggestionsForCaretMovement(state: &state)
            return generation
        }

        if requiresContextRecovery {
            let generation = state.exactCommitPrediction?.generation
            suspendForContextRecovery(state: &state)
            return generation
        }

        guard !modifiers.containsUnsupportedTypingModifier else {
            invalidatePassThroughContext(state: &state)
            return nil
        }

        if
            snapshot.keyCode == RuntimeKeyboardKeyCode.escape,
            state.mode == .suggestions
                || state.mode == .browser
        {
            let generation = state.exactCommitPrediction?.generation
            state.mode = .hidden
            state.revalidatesTextEdits = false
            clearCommitIntent(state: &state)
            state.presentationRevision &+= 1
            state.interactionRevision &+= 1
            return generation
        }

        guard
            state.exactCommitEnabled,
            !state.exactCommitTokens.isEmpty
        else {
            state.exactCommitPrediction = nil
            return nil
        }

        if snapshot.keyCode == RuntimeKeyboardKeyCode.delete {
            guard
                var prediction = state.exactCommitPrediction,
                !prediction.isClosed
            else {
                invalidatePassThroughContext(state: &state)
                return nil
            }
            if prediction.recoverableSuffixLength > 0 {
                prediction.recoverableSuffixLength -= 1
                state.exactCommitPrediction = prediction
                return prediction.generation
            }
            guard !prediction.token.isEmpty else {
                invalidatePassThroughContext(state: &state)
                return nil
            }
            prediction.token.removeLast()
            state.exactCommitPrediction = prediction
            return prediction.generation
        }

        if
            state.mode == .suggestions,
            snapshot.keyCode == RuntimeKeyboardKeyCode.upArrow
                || snapshot.keyCode == RuntimeKeyboardKeyCode.downArrow
        {
            return state.exactCommitPrediction?.generation
        }

        if Self.invalidatesExactCommitPrediction(snapshot.keyCode) {
            let generation = state.exactCommitPrediction?.generation
            if
                state.mode == .committing,
                snapshot.keyCode == RuntimeKeyboardKeyCode.returnKey
                    || snapshot.keyCode
                        == RuntimeKeyboardKeyCode.keypadEnter,
                !RuntimeKeyboardEventMapper
                    .hasUnsupportedInterceptionModifiers(snapshot)
            {
                return generation
            }
            if state.mode == .committing
                || state.mode == .hidden
                    && state.exactCommitPrediction != nil {
                invalidatePassThroughContext(state: &state)
            } else {
                state.exactCommitPrediction = nil
            }
            return generation
        }

        guard
            let characters = snapshot.characters,
            characters.count == 1,
            let character = characters.first
        else {
            invalidatePassThroughContext(state: &state)
            return nil
        }

        if
            var prediction = state.exactCommitPrediction,
            !prediction.isClosed,
            prediction.recoverableSuffixLength > 0
        {
            if character == state.exactCommitTrigger {
                invalidatePassThroughContext(state: &state)
                state.nextPredictionGeneration &+= 1
                let replacement = ExactCommitPrediction(
                    generation: state.nextPredictionGeneration,
                    trigger: character,
                    token: ""
                )
                state.exactCommitPrediction = replacement
                return replacement.generation
            }
            if prediction.recoverableSuffixLength < Int.max {
                prediction.recoverableSuffixLength += 1
            }
            state.exactCommitPrediction = prediction
            suspendPassThroughContext(state: &state)
            return prediction.generation
        }

        if character == state.exactCommitTrigger {
            if var prediction = state.exactCommitPrediction {
                guard
                    !prediction.isClosed,
                    !prediction.token.isEmpty,
                    state.exactCommitTokens.contains(prediction.token)
                else {
                    let generation = prediction.generation
                    invalidatePassThroughContext(state: &state)
                    return generation
                }
                prediction.isClosed = true
                state.exactCommitPrediction = prediction
                if prediction.isVerified {
                    state.mode = .committing
                }
                return prediction.generation
            }

            guard state.mode == .hidden else {
                return nil
            }
            state.nextPredictionGeneration &+= 1
            let prediction = ExactCommitPrediction(
                generation: state.nextPredictionGeneration,
                trigger: character,
                token: ""
            )
            state.exactCommitPrediction = prediction
            return prediction.generation
        }

        guard
            var prediction = state.exactCommitPrediction,
            !prediction.isClosed
        else {
            // Presentation and exact-match prediction are intentionally
            // independent. A delayed UI refresh can leave the suggestion
            // surface visible after its prediction was disarmed; valid token
            // typing must still reach the parser without tearing that surface
            // down. The parser will publish the refreshed results.
            if
                state.mode == .suggestions,
                EmojiAliasSyntax.isValidToken(String(character)),
                state.queuedAcceptanceRevision
                    != state.interactionRevision
            {
                return nil
            }
            invalidatePassThroughContext(state: &state)
            return nil
        }
        guard EmojiAliasSyntax.isValidToken(String(character)) else {
            prediction.recoverableSuffixLength = 1
            state.exactCommitPrediction = prediction
            suspendPassThroughContext(state: &state)
            return prediction.generation
        }
        guard
            prediction.token.utf8.count < Shortcode.maximumLength
        else {
            prediction.recoverableSuffixLength = 1
            state.exactCommitPrediction = prediction
            suspendPassThroughContext(state: &state)
            return prediction.generation
        }
        prediction.token.append(
            contentsOf: EmojiAliasSyntax.normalizedToken(String(character))
        )
        state.exactCommitPrediction = prediction
        return prediction.generation
    }

    private func suspendPassThroughContext(
        state: inout State
    ) {
        let invalidatedInteraction =
            state.exactCommitPrediction != nil
                || state.mode == .suggestions
        if state.mode == .suggestions {
            state.mode = .hidden
            clearCommitIntent(state: &state)
            state.presentationRevision &+= 1
        }
        state.revalidatesTextEdits = false
        if invalidatedInteraction {
            state.interactionRevision &+= 1
        }
    }

    private func invalidatePassThroughContext(
        state: inout State
    ) {
        let invalidatedInteraction =
            state.exactCommitPrediction != nil
                || state.mode == .suggestions
                || state.mode == .committing
        state.exactCommitPrediction = nil
        state.revalidatesTextEdits = false
        if state.mode == .suggestions || state.mode == .committing {
            state.mode = .hidden
            clearCommitIntent(state: &state)
            state.presentationRevision &+= 1
        }
        if invalidatedInteraction {
            state.interactionRevision &+= 1
        }
    }

    private func suspendForContextRecovery(
        state: inout State
    ) {
        let invalidatedInteraction =
            state.exactCommitPrediction != nil
                || state.mode == .suggestions
        state.exactCommitPrediction = nil
        state.revalidatesTextEdits = false
        if state.mode == .suggestions {
            state.mode = .hidden
            clearCommitIntent(state: &state)
        }
        if invalidatedInteraction {
            state.interactionRevision &+= 1
        }
    }

    private func preserveSuggestionsForCaretMovement(
        state: inout State
    ) {
        let invalidatedInteraction =
            state.exactCommitPrediction != nil
                || state.mode == .suggestions
        state.exactCommitPrediction = nil
        state.revalidatesTextEdits = true
        state.acceptsTab = false
        state.acceptsReturn = false
        clearCommitIntent(state: &state)
        if invalidatedInteraction {
            state.interactionRevision &+= 1
        }
    }

    private static func requiresContextRecovery(
        for snapshot: KeyboardEventSnapshot,
        state: State
    ) -> Bool {
        guard
            state.captureEnabled,
            snapshot.type == .keyDown
        else {
            return false
        }
        let modifiers = RuntimeKeyboardEventMapper.parserModifiers(
            from: snapshot.flags,
            for: snapshot.keyCode
        )
        if movesCaretWithoutInterception(
            snapshot.keyCode,
            modifiers: modifiers
        ) {
            return false
        }
        guard snapshot.keyCode != RuntimeKeyboardKeyCode.escape else {
            return false
        }
        let isModifiedEditWhileVisible =
            state.mode == .suggestions
                && modifiers.containsUnsupportedTypingModifier
                && (
                    snapshot.keyCode == RuntimeKeyboardKeyCode.delete
                        || snapshot.characters?.count == 1
                )
        guard
            state.revalidatesTextEdits
                || isModifiedEditWhileVisible
        else {
            return false
        }
        if snapshot.keyCode == RuntimeKeyboardKeyCode.delete {
            return true
        }
        guard
            let characters = snapshot.characters,
            characters.count == 1
        else {
            return false
        }
        return true
    }

    private static func movesCaretWithoutInterception(
        _ keyCode: CGKeyCode,
        modifiers: ParserModifiers
    ) -> Bool {
        switch keyCode {
        case RuntimeKeyboardKeyCode.leftArrow,
             RuntimeKeyboardKeyCode.rightArrow,
             RuntimeKeyboardKeyCode.home,
             RuntimeKeyboardKeyCode.end,
             RuntimeKeyboardKeyCode.pageUp,
             RuntimeKeyboardKeyCode.pageDown:
            true
        case RuntimeKeyboardKeyCode.upArrow,
             RuntimeKeyboardKeyCode.downArrow:
            modifiers.containsNavigationModifier
        default:
            false
        }
    }

    private static func invalidatesExactCommitPrediction(
        _ keyCode: CGKeyCode
    ) -> Bool {
        switch keyCode {
        case RuntimeKeyboardKeyCode.returnKey,
             RuntimeKeyboardKeyCode.keypadEnter,
             RuntimeKeyboardKeyCode.tab,
             RuntimeKeyboardKeyCode.escape,
             RuntimeKeyboardKeyCode.upArrow,
             RuntimeKeyboardKeyCode.downArrow:
            true
        default:
            false
        }
    }

    private static func isUnmodifiedReturn(
        _ snapshot: KeyboardEventSnapshot
    ) -> Bool {
        snapshot.type == .keyDown
            && (
                snapshot.keyCode == RuntimeKeyboardKeyCode.returnKey
                    || snapshot.keyCode
                        == RuntimeKeyboardKeyCode.keypadEnter
            )
            && !RuntimeKeyboardEventMapper
                .hasUnsupportedInterceptionModifiers(snapshot)
    }

    private static func isPresentationAcceptance(
        _ snapshot: KeyboardEventSnapshot,
        mode: RuntimeInterceptionMode,
        acceptsTab: Bool,
        acceptsReturn: Bool
    ) -> Bool {
        guard
            mode == .suggestions || mode == .browser,
            snapshot.type == .keyDown,
            !RuntimeKeyboardEventMapper
                .hasUnsupportedInterceptionModifiers(snapshot)
        else {
            return false
        }
        switch snapshot.keyCode {
        case RuntimeKeyboardKeyCode.tab:
            return acceptsTab || mode == .browser
        case RuntimeKeyboardKeyCode.returnKey,
             RuntimeKeyboardKeyCode.keypadEnter:
            return acceptsReturn || mode == .browser
        default:
            return false
        }
    }

    private func clearCommitIntent(state: inout State) {
        state.activeCommitGeneration = nil
        state.pendingCommitSendGeneration = nil
        state.preactivationCommitSendRevision = nil
        state.queuedAcceptanceRevision = nil
    }

    private func isValidBrowserQueryCharacter(
        _ characters: String?
    ) -> Bool {
        guard
            let characters,
            characters.count == 1
        else {
            return false
        }
        return characters == " "
            || EmojiAliasSyntax.isValidToken(characters)
    }

}
