import Foundation

struct MediaCommandModifierFlags: OptionSet, Equatable, Sendable {
    let rawValue: UInt8

    static let command = MediaCommandModifierFlags(rawValue: 1 << 0)
    static let control = MediaCommandModifierFlags(rawValue: 1 << 1)
    static let option = MediaCommandModifierFlags(rawValue: 1 << 2)
    static let shift = MediaCommandModifierFlags(rawValue: 1 << 3)

    static let commandProducing: MediaCommandModifierFlags = [
        .command,
        .control,
        .option
    ]
}

enum MediaCommandParserInput: Equatable, Sendable {
    case text(String)
    case backspace
    case escape
    case contextInvalidated
}

struct MediaCommandParserEvent: Equatable, Sendable {
    let input: MediaCommandParserInput
    let bundleIdentifier: String?
    let timestamp: TimeInterval
    let modifiers: MediaCommandModifierFlags

    init(
        input: MediaCommandParserInput,
        bundleIdentifier: String?,
        timestamp: TimeInterval,
        modifiers: MediaCommandModifierFlags = []
    ) {
        self.input = input
        self.bundleIdentifier = bundleIdentifier
        self.timestamp = timestamp
        self.modifiers = modifiers
    }
}

enum MediaCommandParserAction: Equatable, Sendable {
    case none
    case recognized(MediaCommandKind)
    case queryChanged(MediaCommandKind, String)
    case limitReached(MediaCommandKind, Int)
    case cancelled
}

struct MediaCommandParser: Sendable {
    static let messagesBundleIdentifier = "com.apple.MobileSMS"

    enum State: Equatable, Sendable {
        case idle
        case commandPrefix(String)
        case awaitingQuery(MediaCommandKind)
        case query(MediaCommandKind, String)
    }

    private(set) var state: State = .idle
    private let inactivityTimeout: TimeInterval
    private var lastEventTimestamp: TimeInterval?

    init(inactivityTimeout: TimeInterval = 8) {
        self.inactivityTimeout = max(inactivityTimeout, 0)
    }

    mutating func consume(_ event: MediaCommandParserEvent) -> MediaCommandParserAction {
        guard event.bundleIdentifier == Self.messagesBundleIdentifier else {
            return resetIfNeeded()
        }
        guard event.timestamp.isFinite else {
            return resetIfNeeded()
        }

        if let lastEventTimestamp,
           event.timestamp < lastEventTimestamp ||
           event.timestamp - lastEventTimestamp > inactivityTimeout {
            state = .idle
        }
        self.lastEventTimestamp = event.timestamp

        if !event.modifiers.intersection(.commandProducing).isEmpty {
            return resetIfNeeded()
        }

        switch event.input {
        case let .text(text):
            var latestAction = MediaCommandParserAction.none
            for character in text {
                let action = consume(character)
                if action != .none {
                    latestAction = action
                }
            }
            return latestAction
        case .backspace:
            return consumeBackspace()
        case .escape, .contextInvalidated:
            return resetIfNeeded()
        }
    }

    mutating func reset() {
        state = .idle
        lastEventTimestamp = nil
    }

    private mutating func consume(_ character: Character) -> MediaCommandParserAction {
        switch state {
        case .idle:
            guard character == "/" else {
                return .none
            }
            state = .commandPrefix("")
            return .none

        case let .commandPrefix(prefix):
            if character == "/" {
                state = .commandPrefix("")
                return .none
            }
            if character.isWhitespace {
                guard let command = MediaCommandKind(rawValue: prefix) else {
                    return resetIfNeeded()
                }
                state = .awaitingQuery(command)
                return .recognized(command)
            }
            guard let scalar = character.unicodeScalars.only,
                  scalar.isASCII,
                  CharacterSet.letters.contains(scalar)
            else {
                return resetIfNeeded()
            }

            let candidate = prefix + character.lowercased()
            guard MediaCommandKind.allCases.contains(where: {
                $0.rawValue.hasPrefix(candidate)
            }) else {
                return resetIfNeeded()
            }
            state = .commandPrefix(candidate)
            return .none

        case let .awaitingQuery(command):
            guard !character.isNewline else {
                return resetIfNeeded()
            }
            guard !character.isWhitespace else {
                return .none
            }
            state = .query(command, String(character))
            return .queryChanged(command, String(character))

        case let .query(command, query):
            guard !character.isNewline else {
                return resetIfNeeded()
            }
            let limit = command.maximumQueryLength
            guard query.count < limit else {
                return .limitReached(command, limit)
            }
            if character.isWhitespace, query.last?.isWhitespace == true {
                return .none
            }
            let updatedQuery = query + String(character)
            state = .query(command, updatedQuery)
            return .queryChanged(command, updatedQuery)
        }
    }

    private mutating func consumeBackspace() -> MediaCommandParserAction {
        switch state {
        case .idle:
            return .none
        case let .commandPrefix(prefix):
            guard !prefix.isEmpty else {
                return resetIfNeeded()
            }
            let shortened = String(prefix.dropLast())
            state = .commandPrefix(shortened)
            return .none
        case let .awaitingQuery(command):
            state = .commandPrefix(command.rawValue)
            return .none
        case let .query(command, query):
            let shortened = String(query.dropLast())
            if shortened.isEmpty {
                state = .awaitingQuery(command)
            } else {
                state = .query(command, shortened)
            }
            return .queryChanged(command, shortened)
        }
    }

    private mutating func resetIfNeeded() -> MediaCommandParserAction {
        guard state != .idle else {
            lastEventTimestamp = nil
            return .none
        }
        reset()
        return .cancelled
    }
}

private extension Unicode.Scalar {
    var isASCII: Bool {
        value <= 0x7f
    }
}

private extension Character.UnicodeScalarView {
    var only: Unicode.Scalar? {
        guard count == 1 else {
            return nil
        }
        return first
    }
}
