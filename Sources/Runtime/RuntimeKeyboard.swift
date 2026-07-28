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

enum RuntimeKeyboardKeyCode {
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

        let modifiers = parserModifiers(from: snapshot.flags)
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

    static func parserModifiers(from flags: CGEventFlags) -> ParserModifiers {
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
        if flags.contains(.maskSecondaryFn) {
            result.insert(.function)
        }
        return result
    }
}

enum RuntimeInterceptionMode: Equatable, Sendable {
    case hidden
    case suggestions
    case browser
    case media
}

/// The only mutable state consulted synchronously by the event-tap callback.
/// Its critical section is bounded to a lock, scalar reads, and key-code
/// comparisons; parser, search, AX, storage, and UI work never run here.
final class RuntimeInterceptionGate: @unchecked Sendable {
    private struct State {
        var captureEnabled = false
        var mode = RuntimeInterceptionMode.hidden
        var acceptsTab = true
        var acceptsReturn = true
    }

    private let lock = NSLock()
    private var state = State()

    func setCaptureEnabled(_ enabled: Bool) {
        lock.withLock {
            state.captureEnabled = enabled
            if !enabled {
                state.mode = .hidden
            }
        }
    }

    func setMode(
        _ mode: RuntimeInterceptionMode,
        acceptsTab: Bool,
        acceptsReturn: Bool
    ) {
        lock.withLock {
            state.mode = mode
            state.acceptsTab = acceptsTab
            state.acceptsReturn = acceptsReturn
        }
    }

    var mode: RuntimeInterceptionMode {
        lock.withLock {
            state.mode
        }
    }

    func decision(for snapshot: KeyboardEventSnapshot) -> EventInterceptionDecision {
        outcome(for: snapshot).decision
    }

    func outcome(
        for snapshot: KeyboardEventSnapshot
    ) -> EventInterceptionOutcome {
        let current = lock.withLock {
            state
        }
        guard
            current.captureEnabled,
            current.mode != .hidden,
            snapshot.type == .keyDown,
            !hasUnsupportedNavigationModifiers(snapshot.flags)
        else {
            return .passThrough
        }

        let decision: EventInterceptionDecision = switch snapshot.keyCode {
        case RuntimeKeyboardKeyCode.escape:
            .intercept
        case RuntimeKeyboardKeyCode.leftArrow,
             RuntimeKeyboardKeyCode.rightArrow:
            current.mode == .media ? .intercept : .passThrough
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
            ? .intercepting(current.mode)
            : .passThrough
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
        return EmojiAliasSyntax.isValidToken(characters)
    }

    private func hasUnsupportedNavigationModifiers(_ flags: CGEventFlags) -> Bool {
        !flags.intersection([
            .maskControl,
            .maskAlternate,
            .maskCommand,
            .maskSecondaryFn
        ]).isEmpty
    }
}
