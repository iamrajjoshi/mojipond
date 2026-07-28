import Foundation

/// The portable pack-level `mojipond.json` format.
///
/// Paths are always relative to the manifest's directory. The model contains no
/// executable hooks, commands, or scripts.
struct PortablePackManifest: Codable, Equatable, Sendable {
    static let currentSchemaVersion = 2
    private static let supportedSchemaVersions = 1...currentSchemaVersion

    var schemaVersion: Int
    var id: PackIdentifier
    var name: String
    var version: String
    var author: String?
    var description: String?
    var sourceURL: URL?
    var license: String?
    var emoji: [PortablePackEmoji]

    init(
        schemaVersion: Int = Self.currentSchemaVersion,
        id: PackIdentifier,
        name: String,
        version: String,
        author: String? = nil,
        description: String? = nil,
        sourceURL: URL? = nil,
        license: String? = nil,
        emoji: [PortablePackEmoji]
    ) {
        self.schemaVersion = schemaVersion
        self.id = id
        self.name = name
        self.version = version
        self.author = author
        self.description = description
        self.sourceURL = sourceURL
        self.license = license
        self.emoji = emoji
    }

    private enum CodingKeys: String, CodingKey {
        case schemaVersion
        case id
        case name
        case version
        case author
        case description
        case sourceURL = "source"
        case license
        case emoji
    }

    var metadata: PackManifestMetadata {
        PackManifestMetadata(
            packID: id,
            name: name,
            version: version,
            author: author,
            description: description,
            sourceURL: sourceURL,
            license: license
        )
    }

    func validated() throws -> Self {
        guard Self.supportedSchemaVersions.contains(schemaVersion) else {
            throw PortablePackManifestError.unsupportedSchemaVersion(schemaVersion)
        }
        try metadata.validate()

        var claims = Set<Shortcode>()
        var paths = Set<String>()
        for entry in emoji {
            switch (entry.file, entry.unicode) {
            case let (.some(file), .none):
                guard Self.isSafeAssetPath(file) else {
                    throw PortablePackManifestError.unsafeAssetPath(file)
                }
                let normalizedPath = file
                    .precomposedStringWithCanonicalMapping
                    .lowercased()
                guard paths.insert(normalizedPath).inserted else {
                    throw PortablePackManifestError.duplicateAssetPath(file)
                }
            case let (.none, .some(unicode)):
                guard schemaVersion >= 2 else {
                    throw PortablePackManifestError.unicodeRequiresSchemaVersion2(
                        entry.shortcode
                    )
                }
                do {
                    try UnicodeEmojiValueValidator.validate(unicode)
                } catch {
                    throw PortablePackManifestError.invalidUnicode(
                        entry.shortcode,
                        error.localizedDescription
                    )
                }
            case (.none, .none):
                throw PortablePackManifestError.missingEmojiContent(
                    entry.shortcode
                )
            case (.some, .some):
                throw PortablePackManifestError.conflictingEmojiContent(
                    entry.shortcode
                )
            }
            for claim in [entry.shortcode] + entry.aliases {
                guard claims.insert(claim).inserted else {
                    throw PortablePackManifestError.duplicateShortcode(claim)
                }
            }

            let validationProbe = LibraryEmoji(
                shortcode: entry.shortcode,
                aliases: entry.aliases,
                displayName: entry.displayName,
                tags: entry.tags,
                category: entry.category,
                order: entry.order ?? 0,
                sourceFilename: entry.file,
                payload: .unicode(entry.unicode ?? "🐸")
            )
            do {
                try validationProbe.validate()
            } catch {
                throw PortablePackManifestError.invalidEmojiMetadata(
                    entry.shortcode,
                    error.localizedDescription
                )
            }
        }
        return self
    }

    static func decode(_ data: Data) throws -> Self {
        do {
            return try JSONDecoder().decode(Self.self, from: data).validated()
        } catch let error as PortablePackManifestError {
            throw error
        } catch {
            throw PortablePackManifestError.invalidJSON(error.localizedDescription)
        }
    }

    static func isSafeAssetPath(_ path: String) -> Bool {
        guard !path.isEmpty,
              path.utf8.count <= 1_024,
              !path.hasPrefix("/"),
              !path.contains("\\"),
              !path.contains(":"),
              !path.unicodeScalars.contains(where: { $0.value == 0 || $0.value < 0x20 })
        else {
            return false
        }
        let components = path.split(separator: "/", omittingEmptySubsequences: false)
        return components.allSatisfy {
            !$0.isEmpty && $0 != "." && $0 != ".." && $0.utf8.count <= 255
        }
    }
}

struct PortablePackEmoji: Codable, Equatable, Sendable {
    var shortcode: Shortcode
    var aliases: [Shortcode]
    var displayName: String?
    var tags: [String]
    var category: String?
    var order: Int?
    var file: String?
    var unicode: String?

    init(
        shortcode: Shortcode,
        aliases: [Shortcode] = [],
        displayName: String? = nil,
        tags: [String] = [],
        category: String? = nil,
        order: Int? = nil,
        file: String
    ) {
        self.shortcode = shortcode
        self.aliases = aliases
        self.displayName = displayName
        self.tags = tags
        self.category = category
        self.order = order
        self.file = file
        unicode = nil
    }

    init(
        shortcode: Shortcode,
        aliases: [Shortcode] = [],
        displayName: String? = nil,
        tags: [String] = [],
        category: String? = nil,
        order: Int? = nil,
        unicode: String
    ) {
        self.shortcode = shortcode
        self.aliases = aliases
        self.displayName = displayName
        self.tags = tags
        self.category = category
        self.order = order
        file = nil
        self.unicode = unicode
    }

    private enum CodingKeys: String, CodingKey {
        case shortcode
        case aliases
        case displayName
        case tags
        case category
        case order
        case file
        case unicode
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        shortcode = try container.decode(Shortcode.self, forKey: .shortcode)
        aliases = try container.decodeIfPresent([Shortcode].self, forKey: .aliases) ?? []
        displayName = try container.decodeIfPresent(String.self, forKey: .displayName)
        tags = try container.decodeIfPresent([String].self, forKey: .tags) ?? []
        category = try container.decodeIfPresent(String.self, forKey: .category)
        order = try container.decodeIfPresent(Int.self, forKey: .order)
        file = try container.decodeIfPresent(String.self, forKey: .file)
        unicode = try container.decodeIfPresent(String.self, forKey: .unicode)
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(shortcode, forKey: .shortcode)
        if !aliases.isEmpty {
            try container.encode(aliases, forKey: .aliases)
        }
        try container.encodeIfPresent(displayName, forKey: .displayName)
        if !tags.isEmpty {
            try container.encode(tags, forKey: .tags)
        }
        try container.encodeIfPresent(category, forKey: .category)
        try container.encodeIfPresent(order, forKey: .order)
        try container.encodeIfPresent(file, forKey: .file)
        try container.encodeIfPresent(unicode, forKey: .unicode)
    }
}

enum PortablePackManifestError: Error, Equatable, LocalizedError, Sendable {
    case invalidJSON(String)
    case unsupportedSchemaVersion(Int)
    case unsafeAssetPath(String)
    case duplicateAssetPath(String)
    case duplicateShortcode(Shortcode)
    case missingEmojiContent(Shortcode)
    case conflictingEmojiContent(Shortcode)
    case unicodeRequiresSchemaVersion2(Shortcode)
    case invalidUnicode(Shortcode, String)
    case invalidEmojiMetadata(Shortcode, String)
    case manifestTooLarge(actual: Int64, limit: Int64)
    case unsafeManifestFile
    case assetOutsidePack(String)
    case missingAsset(String)
    case assetRejected(String, String)
    case totalBytesExceeded(Int64)

    var errorDescription: String? {
        switch self {
        case let .invalidJSON(message):
            "Portable mojipond.json is invalid: \(message)"
        case let .unsupportedSchemaVersion(version):
            "Portable pack schema version \(version) is not supported."
        case let .unsafeAssetPath(path):
            "Portable pack asset path \(path) is unsafe."
        case let .duplicateAssetPath(path):
            "Portable pack asset path \(path) appears more than once."
        case let .duplicateShortcode(shortcode):
            "Portable pack shortcode \(shortcode.rawValue) appears more than once."
        case let .missingEmojiContent(shortcode):
            "Portable pack emoji \(shortcode.rawValue) must contain either file or unicode."
        case let .conflictingEmojiContent(shortcode):
            "Portable pack emoji \(shortcode.rawValue) cannot contain both file and unicode."
        case let .unicodeRequiresSchemaVersion2(shortcode):
            "Portable pack emoji \(shortcode.rawValue) uses Unicode content, which requires schema version 2."
        case let .invalidUnicode(shortcode, message):
            "Portable pack emoji \(shortcode.rawValue) has invalid Unicode content: \(message)"
        case let .invalidEmojiMetadata(shortcode, message):
            "Portable pack emoji \(shortcode.rawValue) is invalid: \(message)"
        case let .manifestTooLarge(actual, limit):
            "Portable mojipond.json is \(actual) bytes, above the \(limit)-byte limit."
        case .unsafeManifestFile:
            "Portable mojipond.json is not a safe regular file."
        case let .assetOutsidePack(path):
            "Portable pack asset \(path) escaped the pack directory."
        case let .missingAsset(path):
            "Portable pack asset \(path) does not exist."
        case let .assetRejected(path, message):
            "Portable pack asset \(path) was rejected: \(message)"
        case let .totalBytesExceeded(limit):
            "Portable pack assets exceed the \(limit)-byte total limit."
        }
    }
}
