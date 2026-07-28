import Foundation

struct GemojiRecord: Decodable, Equatable, Sendable {
    let emoji: String
    let description: String
    let category: String
    let aliases: [String]
    let tags: [String]
    let unicodeVersion: String?
    let hasSkinTones: Bool

    private enum CodingKeys: String, CodingKey {
        case emoji
        case description
        case category
        case aliases
        case tags
        case unicodeVersion = "unicode_version"
        case hasSkinTones = "skin_tones"
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        emoji = try container.decode(String.self, forKey: .emoji)
        description = try container.decode(String.self, forKey: .description)
        category = try container.decode(String.self, forKey: .category)
        aliases = try container.decode([String].self, forKey: .aliases)
        tags = try container.decodeIfPresent([String].self, forKey: .tags) ?? []
        unicodeVersion = try container.decodeIfPresent(String.self, forKey: .unicodeVersion)
        hasSkinTones = try container.decodeIfPresent(Bool.self, forKey: .hasSkinTones) ?? false
    }
}

enum GemojiDatasetError: Error, Equatable, LocalizedError, Sendable {
    case emptyEmoji(record: Int)
    case missingUsableAlias(record: Int)
    case duplicateIdentifier(String)

    var errorDescription: String? {
        switch self {
        case let .emptyEmoji(record):
            "gemoji record \(record) has no Unicode value."
        case let .missingUsableAlias(record):
            "gemoji record \(record) has no alias that can be used as a canonical shortcode."
        case let .duplicateIdentifier(identifier):
            "gemoji contains the duplicate item identifier “\(identifier)”."
        }
    }
}

/// Converts GitHub's pinned `db/emoji.json` representation into MojiPond's
/// immutable built-in pack model.
struct GemojiDatasetDecoder: Sendable {
    static let defaultRevision = "0eca75db9301421efc8710baf7a7576793ae452a"

    let packID: String
    let packPriority: Int
    let revision: String

    init(
        packID: String = "builtin.gemoji",
        packPriority: Int = 0,
        revision: String = GemojiDatasetDecoder.defaultRevision
    ) {
        self.packID = packID
        self.packPriority = packPriority
        self.revision = revision
    }

    func decode(_ data: Data) throws -> EmojiCatalogPack {
        let records = try JSONDecoder().decode([GemojiRecord].self, from: data)
        var identifiers = Set<String>()
        let items = try records.enumerated().map { index, record in
            try map(record, index: index, identifiers: &identifiers)
        }

        return EmojiCatalogPack(
            id: packID,
            name: "Built-in Emoji",
            version: revision,
            packDescription: "GitHub-style aliases backed by the open-source gemoji dataset.",
            source: .builtIn(dataset: "github/gemoji", revision: revision),
            attribution: PackAttribution(
                author: "GitHub, Inc.",
                licenseName: "MIT",
                licenseURL: URL(string: "https://github.com/github/gemoji/blob/master/LICENSE"),
                sourceURL: URL(string: "https://github.com/github/gemoji")
            ),
            priority: packPriority,
            items: items
        )
    }

    private func map(
        _ record: GemojiRecord,
        index: Int,
        identifiers: inout Set<String>
    ) throws -> EmojiItem {
        guard !record.emoji.isEmpty else {
            throw GemojiDatasetError.emptyEmoji(record: index)
        }
        guard let canonical = record.aliases.lazy.compactMap({ Shortcode(rawValue: $0) }).first else {
            throw GemojiDatasetError.missingUsableAlias(record: index)
        }

        let identifier = "\(packID).\(canonical.rawValue)"
        guard identifiers.insert(identifier).inserted else {
            throw GemojiDatasetError.duplicateIdentifier(identifier)
        }

        let variants: [UnicodeEmojiVariant]
        if record.hasSkinTones {
            variants = EmojiSkinTone.allCases.map { tone in
                UnicodeEmojiVariant(
                    skinTone: tone,
                    value: Self.applying(tone, to: record.emoji)
                )
            }
        } else {
            variants = []
        }

        return EmojiItem(
            id: identifier,
            shortcode: canonical,
            name: record.description,
            aliases: record.aliases,
            keywords: record.tags,
            category: record.category,
            content: .unicode(
                UnicodeEmojiContent(
                    value: record.emoji,
                    unicodeVersion: record.unicodeVersion,
                    skinToneVariants: variants
                )
            ),
            packID: packID,
            packPriority: packPriority,
            order: index
        )
    }

    /// Inserts the modifier before the first ZWJ. This preserves variation
    /// selectors and correctly handles sequences such as `🧑‍🦽`.
    private static func applying(_ tone: EmojiSkinTone, to emoji: String) -> String {
        var scalars = Array(emoji.unicodeScalars)
        guard let modifier = tone.modifier.unicodeScalars.first else {
            return emoji
        }
        let insertionIndex = scalars.firstIndex(where: { $0.value == 0x200D }) ?? scalars.endIndex
        scalars.insert(modifier, at: insertionIndex)
        return String(String.UnicodeScalarView(scalars))
    }
}
