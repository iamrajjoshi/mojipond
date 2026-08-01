import Foundation

/// Alias tokens accept the same bounded ASCII alphabet as the parser. Canonical
/// imported names continue to use the stricter shared ``Shortcode`` type.
enum EmojiAliasSyntax {
    static func normalizedToken(_ value: String) -> String {
        value.lowercased(with: Locale(identifier: "en_US_POSIX"))
    }

    static func isValidToken(_ value: String) -> Bool {
        let scalars = value.unicodeScalars
        guard !scalars.isEmpty, scalars.count <= Shortcode.maximumLength else {
            return false
        }
        return scalars.allSatisfy { scalar in
            (scalar.value >= 97 && scalar.value <= 122)
                || (scalar.value >= 65 && scalar.value <= 90)
                || (scalar.value >= 48 && scalar.value <= 57)
                || scalar == "_"
                || scalar == "+"
                || scalar == "-"
        }
    }
}

enum EmojiSkinTone: String, CaseIterable, Codable, Hashable, Sendable {
    case light
    case mediumLight
    case medium
    case mediumDark
    case dark

    var modifier: String {
        switch self {
        case .light: "🏻"
        case .mediumLight: "🏼"
        case .medium: "🏽"
        case .mediumDark: "🏾"
        case .dark: "🏿"
        }
    }

    var displayName: String {
        switch self {
        case .light: "Light"
        case .mediumLight: "Medium-light"
        case .medium: "Medium"
        case .mediumDark: "Medium-dark"
        case .dark: "Dark"
        }
    }
}

struct UnicodeEmojiVariant: Codable, Hashable, Sendable {
    let skinTone: EmojiSkinTone
    let value: String

    init(skinTone: EmojiSkinTone, value: String) {
        self.skinTone = skinTone
        self.value = value
    }
}

struct UnicodeEmojiContent: Codable, Hashable, Sendable {
    let value: String
    let unicodeVersion: String?
    let skinToneVariants: [UnicodeEmojiVariant]

    init(
        value: String,
        unicodeVersion: String? = nil,
        skinToneVariants: [UnicodeEmojiVariant] = []
    ) {
        self.value = value
        self.unicodeVersion = unicodeVersion
        self.skinToneVariants = skinToneVariants
    }

    func value(for skinTone: EmojiSkinTone?) -> String {
        guard let skinTone else {
            return value
        }
        return skinToneVariants.first(where: { $0.skinTone == skinTone })?.value ?? value
    }
}

enum AssetFormat: String, Codable, CaseIterable, Hashable, Sendable {
    case png
    case jpeg
    case gif
    case webP

    var preferredFilenameExtension: String {
        switch self {
        case .png: "png"
        case .jpeg: "jpg"
        case .gif: "gif"
        case .webP: "webp"
        }
    }

    var supportsAnimation: Bool {
        self == .gif || self == .webP
    }
}

struct MediaDimensions: Codable, Hashable, Sendable {
    let width: Int
    let height: Int

    init(width: Int, height: Int) {
        self.width = width
        self.height = height
    }
}

/// A reference to media copied into MojiPond's managed Application Support
/// directory. Original image bytes live on disk and are never represented by
/// a recompressed bitmap in metadata.
struct MediaEmojiContent: Codable, Hashable, Sendable {
    let mediaType: AssetFormat
    let relativePath: String
    let thumbnailRelativePath: String?
    let originalFilename: String?
    let contentHash: String
    let dimensions: MediaDimensions?
    let isAnimated: Bool

    init(
        mediaType: AssetFormat,
        relativePath: String,
        thumbnailRelativePath: String? = nil,
        originalFilename: String? = nil,
        contentHash: String,
        dimensions: MediaDimensions? = nil,
        isAnimated: Bool = false
    ) {
        self.mediaType = mediaType
        self.relativePath = relativePath
        self.thumbnailRelativePath = thumbnailRelativePath
        self.originalFilename = originalFilename
        self.contentHash = contentHash
        self.dimensions = dimensions
        self.isAnimated = isAnimated
    }
}

enum EmojiContent: Codable, Hashable, Sendable {
    case unicode(UnicodeEmojiContent)
    case media(MediaEmojiContent)

    var isAnimated: Bool {
        switch self {
        case .unicode:
            false
        case let .media(media):
            media.isAnimated
        }
    }
}

struct EmojiItem: Identifiable, Codable, Hashable, Sendable {
    typealias ID = String

    let id: ID
    var shortcode: Shortcode
    var name: String
    var aliases: [String]
    var keywords: [String]
    var category: String
    var content: EmojiContent
    var packID: String
    /// Higher values sort ahead of lower values after textual match quality.
    var packPriority: Int
    var order: Int?

    init(
        id: ID,
        shortcode: Shortcode,
        name: String,
        aliases: [String] = [],
        keywords: [String] = [],
        category: String,
        content: EmojiContent,
        packID: String,
        packPriority: Int = 0,
        order: Int? = nil
    ) {
        self.id = id
        self.shortcode = shortcode
        self.name = name
        self.aliases = Self.uniqueNormalizedTokens(aliases, excluding: shortcode.rawValue)
        self.keywords = Self.uniqueNormalizedSearchTerms(keywords)
        self.category = category
        self.content = content
        self.packID = packID
        self.packPriority = packPriority
        self.order = order
    }

    var allShortcodes: [String] {
        [shortcode.rawValue] + aliases
    }

    private static func uniqueNormalizedTokens(_ values: [String], excluding: String) -> [String] {
        var seen = Set([excluding])
        var result: [String] = []
        for value in values {
            let normalized = EmojiAliasSyntax.normalizedToken(value)
            guard EmojiAliasSyntax.isValidToken(normalized), seen.insert(normalized).inserted else {
                continue
            }
            result.append(normalized)
        }
        return result
    }

    private static func uniqueNormalizedSearchTerms(_ values: [String]) -> [String] {
        var seen = Set<String>()
        var result: [String] = []
        for value in values {
            let normalized = value.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !normalized.isEmpty else {
                continue
            }
            let key = normalized.folding(
                options: [.caseInsensitive, .diacriticInsensitive],
                locale: Locale(identifier: "en_US_POSIX")
            )
            guard seen.insert(key).inserted else {
                continue
            }
            result.append(normalized)
        }
        return result
    }
}

enum EmojiPackSource: Codable, Hashable, Sendable {
    case builtIn(dataset: String, revision: String?)
    case local
    case github(owner: String, repository: String, revision: String?, subdirectory: String?)
}

struct PackAttribution: Codable, Hashable, Sendable {
    var author: String?
    var licenseName: String?
    var licenseURL: URL?
    var sourceURL: URL?

    init(
        author: String? = nil,
        licenseName: String? = nil,
        licenseURL: URL? = nil,
        sourceURL: URL? = nil
    ) {
        self.author = author
        self.licenseName = licenseName
        self.licenseURL = licenseURL
        self.sourceURL = sourceURL
    }
}

struct EmojiCatalogPack: Identifiable, Codable, Hashable, Sendable {
    typealias ID = String

    let id: ID
    var name: String
    var version: String?
    var packDescription: String?
    var source: EmojiPackSource
    var attribution: PackAttribution
    var isEnabled: Bool
    /// Higher values have higher search precedence.
    var priority: Int
    var items: [EmojiItem]

    init(
        id: ID,
        name: String,
        version: String? = nil,
        packDescription: String? = nil,
        source: EmojiPackSource,
        attribution: PackAttribution = PackAttribution(),
        isEnabled: Bool = true,
        priority: Int = 0,
        items: [EmojiItem] = []
    ) {
        self.id = id
        self.name = name
        self.version = version
        self.packDescription = packDescription
        self.source = source
        self.attribution = attribution
        self.isEnabled = isEnabled
        self.priority = priority
        self.items = items
    }
}
