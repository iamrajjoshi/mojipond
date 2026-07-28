import Foundation

struct SlackEmojiManifest: Equatable, Sendable {
    let entries: [SlackEmojiManifestEntry]
}

struct SlackEmojiManifestEntry: Equatable, Sendable {
    let shortcode: Shortcode
    let assetURL: URL
    let aliases: [Shortcode]
}

enum SlackEmojiManifestParser {
    static func parse(data: Data) throws -> SlackEmojiManifest {
        let root: JSONValue
        do {
            root = try JSONDecoder().decode(JSONValue.self, from: data)
        } catch {
            throw SlackManifestError.invalidJSON
        }

        let rawRecords = try records(from: root)
        var definitions: [Shortcode: Definition] = [:]
        for record in rawRecords {
            let shortcode = try normalizedShortcode(record.name)
            guard definitions[shortcode] == nil else {
                throw SlackManifestError.duplicateName(shortcode)
            }

            if let aliasTarget = record.aliasTarget {
                definitions[shortcode] = .alias(try normalizedShortcode(aliasTarget))
            } else if let assetURL = record.assetURL {
                definitions[shortcode] = .asset(try validatedRemoteURL(assetURL))
            } else {
                throw SlackManifestError.missingURLOrAlias(record.name)
            }
        }

        var visitState: [Shortcode: VisitState] = [:]
        var resolvedTargets: [Shortcode: Shortcode] = [:]
        var stack: [Shortcode] = []

        func resolve(_ shortcode: Shortcode) throws -> Shortcode {
            if let resolved = resolvedTargets[shortcode] {
                return resolved
            }
            guard let definition = definitions[shortcode] else {
                throw SlackManifestError.missingAliasTarget(shortcode)
            }
            if visitState[shortcode] == .visiting {
                let cycleStart = stack.firstIndex(of: shortcode) ?? 0
                throw SlackManifestError.aliasCycle(Array(stack[cycleStart...]) + [shortcode])
            }

            visitState[shortcode] = .visiting
            stack.append(shortcode)
            let resolved: Shortcode
            switch definition {
            case .asset:
                resolved = shortcode
            case let .alias(target):
                resolved = try resolve(target)
            }
            _ = stack.popLast()
            visitState[shortcode] = .visited
            resolvedTargets[shortcode] = resolved
            return resolved
        }

        for shortcode in definitions.keys.sorted() {
            _ = try resolve(shortcode)
        }

        var aliasesByCanonical: [Shortcode: [Shortcode]] = [:]
        for (shortcode, target) in resolvedTargets where shortcode != target {
            aliasesByCanonical[target, default: []].append(shortcode)
        }

        let entries = definitions.keys.sorted().compactMap { shortcode -> SlackEmojiManifestEntry? in
            guard case let .asset(url) = definitions[shortcode] else {
                return nil
            }
            return SlackEmojiManifestEntry(
                shortcode: shortcode,
                assetURL: url,
                aliases: aliasesByCanonical[shortcode, default: []].sorted()
            )
        }
        return SlackEmojiManifest(entries: entries)
    }

    private static func records(from root: JSONValue) throws -> [RawRecord] {
        switch root {
        case let .array(values):
            return try values.map(record(from:))
        case let .object(object):
            if let emoji = object["emoji"] {
                switch emoji {
                case let .array(values):
                    return try values.map(record(from:))
                case let .object(map):
                    return try records(fromStringMap: map)
                default:
                    throw SlackManifestError.unsupportedShape
                }
            }
            return try records(fromStringMap: object)
        default:
            throw SlackManifestError.unsupportedShape
        }
    }

    private static func records(fromStringMap map: [String: JSONValue]) throws -> [RawRecord] {
        var records: [RawRecord] = []
        for key in map.keys.sorted() {
            guard let value = map[key] else {
                continue
            }
            if ["ok", "cache_ts", "response_metadata"].contains(key) {
                continue
            }
            guard case let .string(rawValue) = value else {
                throw SlackManifestError.unsupportedShape
            }
            if rawValue.hasPrefix("alias:") {
                records.append(
                    RawRecord(
                        name: key,
                        assetURL: nil,
                        aliasTarget: String(rawValue.dropFirst("alias:".count))
                    )
                )
            } else {
                records.append(RawRecord(name: key, assetURL: rawValue, aliasTarget: nil))
            }
        }
        return records
    }

    private static func record(from value: JSONValue) throws -> RawRecord {
        guard case let .object(object) = value,
              case let .string(name)? = object["name"] else {
            throw SlackManifestError.unsupportedShape
        }

        let aliasKeys = ["alias_for", "aliasFor", "alias"]
        let urlKeys = ["url", "image_url", "imageUrl"]
        let alias = aliasKeys.lazy.compactMap { key -> String? in
            guard case let .string(value)? = object[key], !value.isEmpty else {
                return nil
            }
            return value.hasPrefix("alias:")
                ? String(value.dropFirst("alias:".count))
                : value
        }.first
        let url = urlKeys.lazy.compactMap { key -> String? in
            guard case let .string(value)? = object[key], !value.isEmpty else {
                return nil
            }
            return value
        }.first

        return RawRecord(name: name, assetURL: alias == nil ? url : nil, aliasTarget: alias)
    }

    private static func normalizedShortcode(_ value: String) throws -> Shortcode {
        do {
            return try Shortcode(normalizing: value)
        } catch {
            throw SlackManifestError.invalidName(value)
        }
    }

    private static func validatedRemoteURL(_ value: String) throws -> URL {
        guard let components = URLComponents(string: value),
              components.scheme?.lowercased() == "https",
              let host = components.host,
              !host.isEmpty,
              components.user == nil,
              components.password == nil,
              components.fragment == nil,
              let url = components.url else {
            throw SlackManifestError.invalidAssetURL(value)
        }
        return url
    }

    private struct RawRecord {
        let name: String
        let assetURL: String?
        let aliasTarget: String?
    }

    private enum Definition {
        case asset(URL)
        case alias(Shortcode)
    }

    private enum VisitState {
        case visiting
        case visited
    }
}

enum SlackManifestError: Error, Equatable, LocalizedError, Sendable {
    case invalidJSON
    case unsupportedShape
    case invalidName(String)
    case duplicateName(Shortcode)
    case missingURLOrAlias(String)
    case invalidAssetURL(String)
    case missingAliasTarget(Shortcode)
    case aliasCycle([Shortcode])

    var errorDescription: String? {
        switch self {
        case .invalidJSON:
            "Slack emoji.json is not valid JSON."
        case .unsupportedShape:
            "Slack emoji.json uses an unsupported structure."
        case let .invalidName(name):
            "Slack emoji name \(name) cannot be normalized safely."
        case let .duplicateName(shortcode):
            "Slack emoji name \(shortcode.rawValue) appears more than once."
        case let .missingURLOrAlias(name):
            "Slack emoji \(name) has neither an image URL nor an alias target."
        case let .invalidAssetURL(value):
            "Slack emoji URL \(value) is not a valid HTTPS URL."
        case let .missingAliasTarget(shortcode):
            "Slack alias points to missing emoji \(shortcode.rawValue)."
        case let .aliasCycle(shortcodes):
            "Slack aliases contain a cycle: \(shortcodes.map(\.rawValue).joined(separator: " → "))."
        }
    }
}

private enum JSONValue: Decodable {
    case string(String)
    case number(Double)
    case object([String: JSONValue])
    case array([JSONValue])
    case bool(Bool)
    case null

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() {
            self = .null
        } else if let value = try? container.decode(Bool.self) {
            self = .bool(value)
        } else if let value = try? container.decode(Double.self) {
            self = .number(value)
        } else if let value = try? container.decode(String.self) {
            self = .string(value)
        } else if let value = try? container.decode([String: JSONValue].self) {
            self = .object(value)
        } else if let value = try? container.decode([JSONValue].self) {
            self = .array(value)
        } else {
            throw DecodingError.dataCorruptedError(
                in: container,
                debugDescription: "Unsupported JSON value"
            )
        }
    }
}
