import Foundation

/// A normalized shortcode without the surrounding trigger characters.
///
/// MojiPond deliberately keeps the accepted alphabet small so imported names are
/// predictable across filesystems, JSON encoders, and apps:
/// `[a-z0-9][a-z0-9_+-]{0,63}`.
struct Shortcode: RawRepresentable, Codable, Hashable, Comparable, Sendable {
    static let maximumLength = 64

    let rawValue: String

    init?(rawValue: String) {
        guard Self.isValid(rawValue) else {
            return nil
        }
        self.rawValue = rawValue
    }

    init(validating value: String) throws {
        guard Self.isValid(value) else {
            throw ShortcodeError.invalid(value)
        }
        rawValue = value
    }

    init(normalizing value: String) throws {
        let normalized = Self.normalizedString(from: value)
        guard Self.isValid(normalized) else {
            throw ShortcodeError.cannotNormalize(value)
        }
        rawValue = normalized
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        let value = try container.decode(String.self)
        guard Self.isValid(value) else {
            throw DecodingError.dataCorruptedError(
                in: container,
                debugDescription: "Invalid shortcode: \(value)"
            )
        }
        rawValue = value
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }

    static func < (lhs: Shortcode, rhs: Shortcode) -> Bool {
        lhs.rawValue < rhs.rawValue
    }

    static func isValid(_ value: String) -> Bool {
        let bytes = Array(value.utf8)
        guard !bytes.isEmpty, bytes.count <= maximumLength, isASCIILetterOrDigit(bytes[0]) else {
            return false
        }

        return bytes.dropFirst().allSatisfy {
            isASCIILetterOrDigit($0) || $0 == 0x5F || $0 == 0x2B || $0 == 0x2D
        }
    }

    static func normalizedString(from input: String) -> String {
        var value = input.trimmingCharacters(in: .whitespacesAndNewlines)
        if value.count >= 2, value.first == ":", value.last == ":" {
            value.removeFirst()
            value.removeLast()
        }

        value = value.folding(options: [.diacriticInsensitive, .widthInsensitive], locale: Locale(identifier: "en_US_POSIX"))
            .lowercased(with: Locale(identifier: "en_US_POSIX"))

        var output = ""
        var needsSeparator = false

        for scalar in value.unicodeScalars {
            guard scalar.isASCII else {
                needsSeparator = !output.isEmpty
                continue
            }

            let byte = UInt8(scalar.value)
            if isASCIILetterOrDigit(byte) {
                if needsSeparator, !output.isEmpty, output.last != "_" {
                    output.append("_")
                }
                needsSeparator = false
                output.unicodeScalars.append(scalar)
            } else if (byte == 0x5F || byte == 0x2B || byte == 0x2D), !output.isEmpty {
                if needsSeparator, output.last != "_" {
                    output.append("_")
                }
                needsSeparator = false
                output.unicodeScalars.append(scalar)
            } else {
                needsSeparator = !output.isEmpty
            }

            if output.utf8.count >= maximumLength {
                break
            }
        }

        while output.last == "_" {
            output.removeLast()
        }
        if output.utf8.count > maximumLength {
            output = String(decoding: output.utf8.prefix(maximumLength), as: UTF8.self)
        }
        return output
    }

    private static func isASCIILetterOrDigit(_ byte: UInt8) -> Bool {
        (0x61...0x7A).contains(byte) || (0x30...0x39).contains(byte)
    }
}

enum ShortcodeError: Error, Equatable, LocalizedError, Sendable {
    case invalid(String)
    case cannotNormalize(String)

    var errorDescription: String? {
        switch self {
        case let .invalid(value):
            "“\(value)” is not a valid MojiPond shortcode."
        case let .cannotNormalize(value):
            "“\(value)” does not contain a usable shortcode."
        }
    }
}
