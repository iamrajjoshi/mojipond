import Foundation

struct MojiPondLibrary: Codable, Equatable, Sendable {
    static let currentSchemaVersion = 2
    static let manifestFilename = "mojipond.json"

    var schemaVersion: Int
    var updatedAt: Date
    var packs: [EmojiPack]

    init(
        schemaVersion: Int = Self.currentSchemaVersion,
        updatedAt: Date = Date(),
        packs: [EmojiPack] = []
    ) {
        self.schemaVersion = schemaVersion
        self.updatedAt = updatedAt
        self.packs = packs
    }

    func validated() throws -> Self {
        guard schemaVersion == Self.currentSchemaVersion else {
            throw LibraryModelError.unsupportedSchemaVersion(schemaVersion)
        }

        var packIDs = Set<UUID>()
        var stablePackIDs = Set<PackIdentifier>()
        var allItemIDs = Set<UUID>()
        for pack in packs {
            guard packIDs.insert(pack.id).inserted else {
                throw LibraryModelError.duplicatePackID(pack.id)
            }
            guard stablePackIDs.insert(pack.manifest.packID).inserted else {
                throw LibraryModelError.duplicateStablePackID(pack.manifest.packID)
            }
            try pack.validate(itemIDs: &allItemIDs)
        }
        return self
    }

    func migratedToCurrent() throws -> Self {
        switch schemaVersion {
        case Self.currentSchemaVersion:
            return self
        case 1:
            var migrated = self
            migrated.schemaVersion = Self.currentSchemaVersion
            for index in migrated.packs.indices {
                migrated.packs[index].priority = index
                for itemIndex in migrated.packs[index].items.indices {
                    migrated.packs[index].items[itemIndex].order = itemIndex
                }
            }
            return migrated
        default:
            throw LibraryModelError.unsupportedSchemaVersion(schemaVersion)
        }
    }
}

struct PackIdentifier: RawRepresentable, Codable, Hashable, Comparable, Sendable {
    static let maximumLength = 128

    let rawValue: String

    init?(rawValue: String) {
        guard Self.isValid(rawValue) else {
            return nil
        }
        self.rawValue = rawValue
    }

    init(validating value: String) throws {
        guard Self.isValid(value) else {
            throw LibraryModelError.invalidStablePackID(value)
        }
        rawValue = value
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        let value = try container.decode(String.self)
        guard Self.isValid(value) else {
            throw DecodingError.dataCorruptedError(
                in: container,
                debugDescription: "Invalid stable pack ID: \(value)"
            )
        }
        rawValue = value
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }

    static func < (lhs: Self, rhs: Self) -> Bool {
        lhs.rawValue < rhs.rawValue
    }

    static func local(_ uuid: UUID) -> Self {
        // UUID text only contains lowercase hexadecimal and hyphens.
        Self(rawValue: "local.\(uuid.uuidString.lowercased())")!
    }

    private static func isValid(_ value: String) -> Bool {
        let bytes = Array(value.utf8)
        guard !bytes.isEmpty, bytes.count <= maximumLength,
              Self.isAlphaNumeric(bytes[0]),
              !value.hasSuffix("."),
              !value.contains("..") else {
            return false
        }
        return bytes.allSatisfy {
            Self.isAlphaNumeric($0) || $0 == 0x2E || $0 == 0x5F || $0 == 0x2D
        }
    }

    private static func isAlphaNumeric(_ byte: UInt8) -> Bool {
        (0x30...0x39).contains(byte) || (0x61...0x7A).contains(byte)
    }
}

struct PackManifestMetadata: Codable, Equatable, Sendable {
    var packID: PackIdentifier
    var name: String
    var version: String
    var author: String?
    var description: String?
    var sourceURL: URL?
    var license: String?

    init(
        packID: PackIdentifier,
        name: String,
        version: String = "1.0.0",
        author: String? = nil,
        description: String? = nil,
        sourceURL: URL? = nil,
        license: String? = nil
    ) {
        self.packID = packID
        self.name = name
        self.version = version
        self.author = author
        self.description = description
        self.sourceURL = sourceURL
        self.license = license
    }

    func validate() throws {
        guard Self.isSafeText(name, maximumLength: 200), !name.isEmpty else {
            throw LibraryModelError.invalidManifestMetadata("name")
        }
        guard Self.isSafeText(version, maximumLength: 64), !version.isEmpty else {
            throw LibraryModelError.invalidManifestMetadata("version")
        }
        if let author, !Self.isSafeText(author, maximumLength: 256) {
            throw LibraryModelError.invalidManifestMetadata("author")
        }
        if let description, !Self.isSafeText(description, maximumLength: 4_096) {
            throw LibraryModelError.invalidManifestMetadata("description")
        }
        if let license, !Self.isSafeText(license, maximumLength: 256) {
            throw LibraryModelError.invalidManifestMetadata("license")
        }
        if let sourceURL {
            guard sourceURL.scheme?.lowercased() == "https",
                  sourceURL.host != nil,
                  sourceURL.user == nil,
                  sourceURL.password == nil else {
                throw LibraryModelError.invalidManifestMetadata("source")
            }
        }
    }

    private static func isSafeText(_ value: String, maximumLength: Int) -> Bool {
        value.utf8.count <= maximumLength
            && !value.unicodeScalars.contains(where: { $0.value == 0 || $0.value < 0x09 })
    }
}

struct EmojiPack: Identifiable, Codable, Equatable, Sendable {
    var id: UUID
    var manifest: PackManifestMetadata
    var priority: Int
    var isEnabled: Bool
    var source: PackSource
    var updateMetadata: PackUpdateMetadata
    var items: [LibraryEmoji]

    var name: String {
        get { manifest.name }
        set { manifest.name = newValue }
    }

    init(
        id: UUID = UUID(),
        name: String,
        manifest: PackManifestMetadata? = nil,
        priority: Int = 0,
        isEnabled: Bool = true,
        source: PackSource,
        updateMetadata: PackUpdateMetadata = .init(),
        items: [LibraryEmoji]
    ) {
        self.id = id
        self.manifest = manifest ?? PackManifestMetadata(
            packID: .local(id),
            name: name
        )
        self.priority = priority
        self.isEnabled = isEnabled
        self.source = source
        self.updateMetadata = updateMetadata
        self.items = items
    }

    private enum CodingKeys: String, CodingKey {
        case id
        case manifest
        case legacyName = "name"
        case priority
        case isEnabled
        case source
        case updateMetadata
        case items
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        if let decodedManifest = try container.decodeIfPresent(
            PackManifestMetadata.self,
            forKey: .manifest
        ) {
            manifest = decodedManifest
        } else {
            let legacyName = try container.decodeIfPresent(String.self, forKey: .legacyName)
                ?? "Untitled Pack"
            manifest = PackManifestMetadata(packID: .local(id), name: legacyName)
        }
        priority = try container.decodeIfPresent(Int.self, forKey: .priority) ?? 0
        isEnabled = try container.decodeIfPresent(Bool.self, forKey: .isEnabled) ?? true
        source = try container.decode(PackSource.self, forKey: .source)
        updateMetadata = try container.decodeIfPresent(
            PackUpdateMetadata.self,
            forKey: .updateMetadata
        ) ?? PackUpdateMetadata()
        items = try container.decode([LibraryEmoji].self, forKey: .items)
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(manifest, forKey: .manifest)
        try container.encode(priority, forKey: .priority)
        try container.encode(isEnabled, forKey: .isEnabled)
        try container.encode(source, forKey: .source)
        try container.encode(updateMetadata, forKey: .updateMetadata)
        try container.encode(items, forKey: .items)
    }

    fileprivate func validate(itemIDs: inout Set<UUID>) throws {
        guard priority >= 0 else {
            throw LibraryModelError.invalidPackPriority(priority)
        }
        try manifest.validate()

        var shortcodes = Set<Shortcode>()
        for item in items {
            guard itemIDs.insert(item.id).inserted else {
                throw LibraryModelError.duplicateItemID(item.id)
            }
            for shortcode in [item.shortcode] + item.aliases {
                guard shortcodes.insert(shortcode).inserted else {
                    throw LibraryModelError.duplicateShortcodeInPack(shortcode, id)
                }
            }
            try item.validate()
            try item.payload.validate()
        }
        try source.validate()
        try updateMetadata.validate()
    }
}

struct LibraryEmoji: Identifiable, Codable, Equatable, Sendable {
    var id: UUID
    var shortcode: Shortcode
    var aliases: [Shortcode]
    var displayName: String?
    var tags: [String]
    var category: String?
    var order: Int
    var sourceFilename: String?
    var payload: EmojiPayload

    init(
        id: UUID = UUID(),
        shortcode: Shortcode,
        aliases: [Shortcode] = [],
        displayName: String? = nil,
        tags: [String] = [],
        category: String? = nil,
        order: Int = 0,
        sourceFilename: String? = nil,
        payload: EmojiPayload
    ) {
        self.id = id
        self.shortcode = shortcode
        self.aliases = aliases
        self.displayName = displayName
        self.tags = tags
        self.category = category
        self.order = order
        self.sourceFilename = sourceFilename
        self.payload = payload
    }

    private enum CodingKeys: String, CodingKey {
        case id
        case shortcode
        case aliases
        case displayName
        case tags
        case category
        case order
        case sourceFilename
        case payload
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        shortcode = try container.decode(Shortcode.self, forKey: .shortcode)
        aliases = try container.decodeIfPresent([Shortcode].self, forKey: .aliases) ?? []
        displayName = try container.decodeIfPresent(String.self, forKey: .displayName)
        tags = try container.decodeIfPresent([String].self, forKey: .tags) ?? []
        category = try container.decodeIfPresent(String.self, forKey: .category)
        order = try container.decodeIfPresent(Int.self, forKey: .order) ?? 0
        sourceFilename = try container.decodeIfPresent(String.self, forKey: .sourceFilename)
        payload = try container.decode(EmojiPayload.self, forKey: .payload)
    }

    func validate() throws {
        guard order >= 0 else {
            throw LibraryModelError.invalidItemOrder(order)
        }
        guard tags.count <= 64 else {
            throw LibraryModelError.invalidTags(shortcode)
        }
        var normalizedTags = Set<String>()
        for tag in tags {
            let trimmed = tag.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty,
                  trimmed.utf8.count <= 64,
                  !trimmed.unicodeScalars.contains(where: { $0.value == 0 || $0.value < 0x20 }),
                  normalizedTags.insert(trimmed.lowercased()).inserted else {
                throw LibraryModelError.invalidTags(shortcode)
            }
        }
        if let category {
            let trimmed = category.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty, trimmed.utf8.count <= 128 else {
                throw LibraryModelError.invalidCategory(shortcode)
            }
        }
    }
}

struct EmojiPayload: Codable, Equatable, Sendable {
    enum Kind: String, Codable, Sendable {
        case unicode
        case asset
    }

    var kind: Kind
    var unicode: String?
    var asset: StoredAsset?

    static func unicode(_ value: String) -> Self {
        Self(kind: .unicode, unicode: value, asset: nil)
    }

    static func asset(_ asset: StoredAsset) -> Self {
        Self(kind: .asset, unicode: nil, asset: asset)
    }

    fileprivate func validate() throws {
        switch kind {
        case .unicode:
            guard let unicode, !unicode.isEmpty, asset == nil else {
                throw LibraryModelError.invalidPayload
            }
        case .asset:
            guard unicode == nil, let asset else {
                throw LibraryModelError.invalidPayload
            }
            try asset.validate()
        }
    }
}

struct StoredAsset: Codable, Equatable, Sendable {
    var relativePath: String
    var format: AssetFormat
    var sha256: String
    var byteCount: Int64
    var pixelWidth: Int
    var pixelHeight: Int
    var frameCount: Int

    fileprivate func validate() throws {
        guard Self.isSafeRelativePath(relativePath) else {
            throw LibraryModelError.unsafeAssetPath(relativePath)
        }
        guard sha256.count == 64, sha256.utf8.allSatisfy({ byte in
            (0x30...0x39).contains(byte) || (0x61...0x66).contains(byte)
        }) else {
            throw LibraryModelError.invalidAssetDigest(sha256)
        }
        guard byteCount > 0, pixelWidth > 0, pixelHeight > 0, frameCount > 0 else {
            throw LibraryModelError.invalidAssetMetadata(relativePath)
        }
    }

    static func isSafeRelativePath(_ path: String) -> Bool {
        guard !path.isEmpty, !path.hasPrefix("/"), !path.contains("\\"),
              !path.unicodeScalars.contains(where: { $0.value == 0 || $0.value < 0x20 }) else {
            return false
        }
        let components = path.split(separator: "/", omittingEmptySubsequences: false)
        return !components.isEmpty && components.allSatisfy { component in
            !component.isEmpty && component != "." && component != ".."
        }
    }
}

enum AssetFormat: String, Codable, CaseIterable, Equatable, Sendable {
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
}

struct PackSource: Codable, Equatable, Sendable {
    enum Kind: String, Codable, Sendable {
        case individualFiles
        case folder
        case slackManifest
        case zipArchive
        case github
        case builtIn
    }

    var kind: Kind
    var displayLocation: String?
    var github: GitHubPackSource?

    init(kind: Kind, displayLocation: String? = nil, github: GitHubPackSource? = nil) {
        self.kind = kind
        self.displayLocation = displayLocation
        self.github = github
    }

    fileprivate func validate() throws {
        guard (kind == .github) == (github != nil) else {
            throw LibraryModelError.invalidPackSource
        }
    }
}

struct GitHubPackSource: Codable, Equatable, Sendable {
    var owner: String
    var repository: String
    var ref: String
    var subdirectory: String?
}

struct PackUpdateMetadata: Codable, Equatable, Sendable {
    var installedAt: Date
    var lastUpdatedAt: Date
    var lastCheckedAt: Date?
    var sourceRevision: String?
    var sourceETag: String?
    var contentSHA256: String?

    init(
        installedAt: Date = Date(),
        lastUpdatedAt: Date = Date(),
        lastCheckedAt: Date? = nil,
        sourceRevision: String? = nil,
        sourceETag: String? = nil,
        contentSHA256: String? = nil
    ) {
        self.installedAt = installedAt
        self.lastUpdatedAt = lastUpdatedAt
        self.lastCheckedAt = lastCheckedAt
        self.sourceRevision = sourceRevision
        self.sourceETag = sourceETag
        self.contentSHA256 = contentSHA256
    }

    fileprivate func validate() throws {
        if let contentSHA256 {
            guard contentSHA256.count == 64, contentSHA256.utf8.allSatisfy({ byte in
                (0x30...0x39).contains(byte) || (0x61...0x66).contains(byte)
            }) else {
                throw LibraryModelError.invalidAssetDigest(contentSHA256)
            }
        }
    }
}

enum LibraryModelError: Error, Equatable, LocalizedError, Sendable {
    case unsupportedSchemaVersion(Int)
    case duplicatePackID(UUID)
    case duplicateStablePackID(PackIdentifier)
    case duplicateItemID(UUID)
    case invalidStablePackID(String)
    case invalidManifestMetadata(String)
    case invalidPackPriority(Int)
    case invalidItemOrder(Int)
    case invalidTags(Shortcode)
    case invalidCategory(Shortcode)
    case duplicateShortcodeInPack(Shortcode, UUID)
    case invalidPayload
    case unsafeAssetPath(String)
    case invalidAssetDigest(String)
    case invalidAssetMetadata(String)
    case invalidPackSource

    var errorDescription: String? {
        switch self {
        case let .unsupportedSchemaVersion(version):
            "Library schema version \(version) is not supported."
        case let .duplicatePackID(id):
            "Pack ID \(id) appears more than once."
        case let .duplicateStablePackID(id):
            "Stable pack ID \(id.rawValue) appears more than once."
        case let .duplicateItemID(id):
            "Emoji ID \(id) appears more than once."
        case let .invalidStablePackID(id):
            "Stable pack ID \(id) is invalid."
        case let .invalidManifestMetadata(field):
            "Pack manifest field \(field) is invalid."
        case let .invalidPackPriority(priority):
            "Pack priority \(priority) is invalid."
        case let .invalidItemOrder(order):
            "Emoji order \(order) is invalid."
        case let .invalidTags(shortcode):
            "Emoji \(shortcode.rawValue) has invalid or duplicate tags."
        case let .invalidCategory(shortcode):
            "Emoji \(shortcode.rawValue) has an invalid category."
        case let .duplicateShortcodeInPack(shortcode, id):
            "Shortcode \(shortcode.rawValue) appears more than once in pack \(id)."
        case .invalidPayload:
            "An emoji payload is malformed."
        case let .unsafeAssetPath(path):
            "Asset path \(path) is unsafe."
        case let .invalidAssetDigest(digest):
            "Asset digest \(digest) is invalid."
        case let .invalidAssetMetadata(path):
            "Asset metadata for \(path) is invalid."
        case .invalidPackSource:
            "Pack source metadata is inconsistent."
        }
    }
}
