import Foundation

struct PreparedEmoji: Identifiable, Equatable, Sendable {
    let id: UUID
    var shortcode: Shortcode
    var aliases: [Shortcode]
    var displayName: String?
    var tags: [String]
    var category: String?
    var order: Int
    let sourceURL: URL
    let sourceFilename: String
    let content: PreparedEmojiContent

    var assetSourceURL: URL? {
        guard case .asset = content else {
            return nil
        }
        return sourceURL
    }

    var asset: ValidatedAsset? {
        guard case let .asset(asset) = content else {
            return nil
        }
        return asset
    }

    var unicode: String? {
        guard case let .unicode(value) = content else {
            return nil
        }
        return value
    }

    init(
        id: UUID = UUID(),
        shortcode: Shortcode,
        aliases: [Shortcode] = [],
        displayName: String? = nil,
        tags: [String] = [],
        category: String? = nil,
        order: Int = 0,
        sourceURL: URL,
        sourceFilename: String? = nil,
        asset: ValidatedAsset
    ) {
        self.id = id
        self.shortcode = shortcode
        self.aliases = aliases
        self.displayName = displayName
        self.tags = tags
        self.category = category
        self.order = order
        self.sourceURL = sourceURL
        self.sourceFilename = sourceFilename ?? sourceURL.lastPathComponent
        content = .asset(asset)
    }

    init(
        id: UUID = UUID(),
        shortcode: Shortcode,
        aliases: [Shortcode] = [],
        displayName: String? = nil,
        tags: [String] = [],
        category: String? = nil,
        order: Int = 0,
        unicode: String,
        sourceURL: URL,
        sourceFilename: String = "Unicode emoji"
    ) {
        self.id = id
        self.shortcode = shortcode
        self.aliases = aliases
        self.displayName = displayName
        self.tags = tags
        self.category = category
        self.order = order
        self.sourceURL = sourceURL
        self.sourceFilename = sourceFilename
        content = .unicode(unicode)
    }
}

enum PreparedEmojiContent: Equatable, Sendable {
    case asset(ValidatedAsset)
    case unicode(String)
}

struct PreparedPackImport: Equatable, Sendable {
    let id: UUID
    var name: String
    var manifest: PackManifestMetadata
    var source: PackSource
    var updateMetadata: PackUpdateMetadata
    var items: [PreparedEmoji]

    init(
        id: UUID = UUID(),
        name: String,
        manifest: PackManifestMetadata? = nil,
        source: PackSource,
        updateMetadata: PackUpdateMetadata = .init(),
        items: [PreparedEmoji]
    ) {
        self.id = id
        self.name = name
        self.manifest = manifest ?? PackManifestMetadata(
            packID: .local(id),
            name: name
        )
        self.source = source
        self.updateMetadata = updateMetadata
        self.items = items
    }
}

struct ImportRejection: Identifiable, Equatable, Sendable {
    let id: UUID
    let source: String
    let reason: String

    init(id: UUID = UUID(), source: String, reason: String) {
        self.id = id
        self.source = source
        self.reason = reason
    }
}

struct ImportScanResult: Equatable, Sendable {
    let preparedPack: PreparedPackImport
    let rejections: [ImportRejection]
    let ignoredFileCount: Int

    var acceptedFileCount: Int {
        preparedPack.items.count
    }
}

struct ImportPreview: Equatable, Sendable {
    let preparedPack: PreparedPackImport
    let items: [ImportPreviewItem]
    let collisions: [ImportCollision]
    let rejections: [ImportRejection]
    let ignoredFileCount: Int
    let totalByteCount: Int64

    var requiresDecisions: Bool {
        !collisions.isEmpty
    }
}

struct ImportPreviewItem: Identifiable, Equatable, Sendable {
    let id: UUID
    let sourceFilename: String
    let shortcode: Shortcode
    let aliases: [Shortcode]
    let unicode: String?
    let format: AssetFormat?
    let byteCount: Int64
    let pixelWidth: Int
    let pixelHeight: Int
    let frameCount: Int
}

struct ImportCollision: Identifiable, Equatable, Sendable {
    enum Claim: Equatable, Sendable {
        case primary
        case alias(index: Int)
    }

    enum Existing: Equatable, Sendable {
        case library(ShortcodeOwner)
        case reserved(ReservedShortcodeOwner)
        case incoming(candidateID: UUID, claim: Claim)
    }

    let id: UUID
    let shortcode: Shortcode
    let incomingCandidateID: UUID
    let incomingClaim: Claim
    let existing: Existing

    init(
        id: UUID = UUID(),
        shortcode: Shortcode,
        incomingCandidateID: UUID,
        incomingClaim: Claim,
        existing: Existing
    ) {
        self.id = id
        self.shortcode = shortcode
        self.incomingCandidateID = incomingCandidateID
        self.incomingClaim = incomingClaim
        self.existing = existing
    }
}

struct ShortcodeOwner: Equatable, Hashable, Sendable {
    let packID: UUID
    let packName: String
    let itemID: UUID
    let isAlias: Bool
}

struct ReservedShortcodeOwner: Equatable, Hashable, Sendable {
    enum Source: Equatable, Hashable, Sendable {
        case builtIn
        case customAlias
    }

    let shortcode: Shortcode
    let itemID: String
    let itemName: String
    let packID: String
    let packName: String
    let isAlias: Bool
    let source: Source
}

enum BuiltInShortcodeReservations {
    static func owners(
        in pack: EmojiCatalogPack?
    ) -> [ReservedShortcodeOwner] {
        guard let pack else {
            return []
        }
        return pack.items.flatMap { item in
            let primary = ReservedShortcodeOwner(
                shortcode: item.shortcode,
                itemID: item.id,
                itemName: item.name,
                packID: pack.id,
                packName: pack.name,
                isAlias: false,
                source: .builtIn
            )
            let aliases = item.aliases.compactMap {
                Shortcode(rawValue: $0)
            }.map {
                ReservedShortcodeOwner(
                    shortcode: $0,
                    itemID: item.id,
                    itemName: item.name,
                    packID: pack.id,
                    packName: pack.name,
                    isAlias: true,
                    source: .builtIn
                )
            }
            return [primary] + aliases
        }
    }

    static func shortcodes(
        in pack: EmojiCatalogPack
    ) -> Set<Shortcode> {
        Set(owners(in: pack).map(\.shortcode))
    }
}

enum CollisionDecision: Equatable, Sendable {
    case skipIncomingItem
    case replaceExistingItem
    case renameIncomingClaim(Shortcode)
    case dropIncomingAlias
}

struct ResolvedPackImport: Equatable, Sendable {
    let pack: PreparedPackImport
    let existingItemIDsToReplace: Set<UUID>
}

enum ImportCollisionAnalyzer {
    static func makePreview(
        scanResult: ImportScanResult,
        library: MojiPondLibrary,
        reservedShortcodeOwners: [ReservedShortcodeOwner] = []
    ) -> ImportPreview {
        let owners = existingOwners(in: library)
        let reservedOwners = Dictionary(
            grouping: reservedShortcodeOwners,
            by: \.shortcode
        )
        var seenIncoming: [Shortcode: (UUID, ImportCollision.Claim)] = [:]
        var collisions: [ImportCollision] = []

        for candidate in scanResult.preparedPack.items {
            let claims: [(Shortcode, ImportCollision.Claim)] =
                [(candidate.shortcode, .primary)]
                + candidate.aliases.enumerated().map { ($0.element, .alias(index: $0.offset)) }

            for (shortcode, claim) in claims {
                if let protectedOwners = reservedOwners[shortcode] {
                    for owner in protectedOwners {
                        collisions.append(
                            ImportCollision(
                                shortcode: shortcode,
                                incomingCandidateID: candidate.id,
                                incomingClaim: claim,
                                existing: .reserved(owner)
                            )
                        )
                    }
                }
                if let existingOwners = owners[shortcode] {
                    for owner in existingOwners {
                        collisions.append(
                            ImportCollision(
                                shortcode: shortcode,
                                incomingCandidateID: candidate.id,
                                incomingClaim: claim,
                                existing: .library(owner)
                            )
                        )
                    }
                }
                if let prior = seenIncoming[shortcode] {
                    collisions.append(
                        ImportCollision(
                            shortcode: shortcode,
                            incomingCandidateID: candidate.id,
                            incomingClaim: claim,
                            existing: .incoming(candidateID: prior.0, claim: prior.1)
                        )
                    )
                } else {
                    seenIncoming[shortcode] = (candidate.id, claim)
                }
            }
        }

        let previewItems = scanResult.preparedPack.items.map { candidate in
            if let asset = candidate.asset {
                ImportPreviewItem(
                    id: candidate.id,
                    sourceFilename: candidate.sourceFilename,
                    shortcode: candidate.shortcode,
                    aliases: candidate.aliases,
                    unicode: nil,
                    format: asset.format,
                    byteCount: asset.digest.byteCount,
                    pixelWidth: asset.pixelWidth,
                    pixelHeight: asset.pixelHeight,
                    frameCount: asset.frameCount
                )
            } else {
                ImportPreviewItem(
                    id: candidate.id,
                    sourceFilename: candidate.sourceFilename,
                    shortcode: candidate.shortcode,
                    aliases: candidate.aliases,
                    unicode: candidate.unicode,
                    format: nil,
                    byteCount: 0,
                    pixelWidth: 0,
                    pixelHeight: 0,
                    frameCount: 0
                )
            }
        }
        return ImportPreview(
            preparedPack: scanResult.preparedPack,
            items: previewItems,
            collisions: collisions,
            rejections: scanResult.rejections,
            ignoredFileCount: scanResult.ignoredFileCount,
            totalByteCount: previewItems.reduce(0) { $0 + $1.byteCount }
        )
    }

    static func resolve(
        preview: ImportPreview,
        decisions: [UUID: CollisionDecision],
        library: MojiPondLibrary,
        reservedShortcodeOwners: [ReservedShortcodeOwner] = []
    ) throws -> ResolvedPackImport {
        var candidates = Dictionary(
            uniqueKeysWithValues: preview.preparedPack.items.map { ($0.id, $0) }
        )
        var skipped = Set<UUID>()
        var replacements = Set<UUID>()

        for collision in preview.collisions {
            guard let decision = decisions[collision.id] else {
                throw CollisionResolutionError.missingDecision(collision.id)
            }
            guard var candidate = candidates[collision.incomingCandidateID] else {
                continue
            }
            if skipped.contains(candidate.id) {
                continue
            }

            switch decision {
            case .skipIncomingItem:
                skipped.insert(candidate.id)
            case .replaceExistingItem:
                switch collision.existing {
                case let .library(owner):
                    guard currentLibraryItem(
                        ownedBy: owner,
                        stillClaims: collision.shortcode,
                        in: library
                    ) else {
                        throw CollisionResolutionError.staleExistingOwner(
                            owner.itemID
                        )
                    }
                    replacements.insert(owner.itemID)
                case .reserved:
                    throw CollisionResolutionError
                        .cannotReplaceReservedShortcode(
                            collision.shortcode
                        )
                case let .incoming(otherCandidateID, _):
                    skipped.insert(otherCandidateID)
                }
            case let .renameIncomingClaim(replacement):
                switch collision.incomingClaim {
                case .primary:
                    candidate.shortcode = replacement
                case .alias:
                    guard let index = candidate.aliases.firstIndex(of: collision.shortcode) else {
                        throw CollisionResolutionError.invalidAliasIndex
                    }
                    candidate.aliases[index] = replacement
                }
                candidates[candidate.id] = candidate
            case .dropIncomingAlias:
                guard case .alias = collision.incomingClaim,
                      let index = candidate.aliases.firstIndex(of: collision.shortcode) else {
                    throw CollisionResolutionError.cannotDropPrimaryShortcode
                }
                candidate.aliases.remove(at: index)
                candidates[candidate.id] = candidate
            }
        }

        let resolvedItems = preview.preparedPack.items.compactMap { original in
            skipped.contains(original.id) ? nil : candidates[original.id]
        }
        var resolvedPack = preview.preparedPack
        resolvedPack.items = resolvedItems
        try verifyNoRemainingCollisions(
            items: resolvedItems,
            library: library,
            reservedShortcodeOwners: reservedShortcodeOwners,
            replacing: replacements
        )
        return ResolvedPackImport(pack: resolvedPack, existingItemIDsToReplace: replacements)
    }

    private static func currentLibraryItem(
        ownedBy owner: ShortcodeOwner,
        stillClaims shortcode: Shortcode,
        in library: MojiPondLibrary
    ) -> Bool {
        guard
            let pack = library.packs.first(where: {
                $0.id == owner.packID
            }),
            let item = pack.items.first(where: {
                $0.id == owner.itemID
            })
        else {
            return false
        }
        return item.shortcode == shortcode
            || item.aliases.contains(shortcode)
    }

    private static func existingOwners(
        in library: MojiPondLibrary
    ) -> [Shortcode: [ShortcodeOwner]] {
        var owners: [Shortcode: [ShortcodeOwner]] = [:]
        for pack in library.packs {
            for item in pack.items {
                owners[item.shortcode, default: []].append(
                    ShortcodeOwner(
                        packID: pack.id,
                        packName: pack.name,
                        itemID: item.id,
                        isAlias: false
                    )
                )
                for alias in item.aliases {
                    owners[alias, default: []].append(
                        ShortcodeOwner(
                            packID: pack.id,
                            packName: pack.name,
                            itemID: item.id,
                            isAlias: true
                        )
                    )
                }
            }
        }
        return owners
    }

    private static func verifyNoRemainingCollisions(
        items: [PreparedEmoji],
        library: MojiPondLibrary,
        reservedShortcodeOwners: [ReservedShortcodeOwner],
        replacing replacements: Set<UUID>
    ) throws {
        var claimed = Set<Shortcode>()
        for item in items {
            for shortcode in [item.shortcode] + item.aliases {
                guard claimed.insert(shortcode).inserted else {
                    throw CollisionResolutionError.unresolved(shortcode)
                }
            }
        }

        for pack in library.packs {
            for item in pack.items where !replacements.contains(item.id) {
                for shortcode in [item.shortcode] + item.aliases where claimed.contains(shortcode) {
                    throw CollisionResolutionError.unresolved(shortcode)
                }
            }
        }

        let currentReservations = Set(reservedShortcodeOwners)
        for collision in previewReservedCollisions(
            in: claimed,
            owners: currentReservations
        ) {
            throw CollisionResolutionError.unresolved(collision)
        }
    }

    private static func previewReservedCollisions(
        in claimed: Set<Shortcode>,
        owners: Set<ReservedShortcodeOwner>
    ) -> Set<Shortcode> {
        Set(
            owners.lazy
                .map(\.shortcode)
                .filter(claimed.contains)
        )
    }
}

enum CollisionResolutionError: Error, Equatable, LocalizedError, Sendable {
    case missingDecision(UUID)
    case invalidAliasIndex
    case cannotDropPrimaryShortcode
    case cannotReplaceReservedShortcode(Shortcode)
    case staleExistingOwner(UUID)
    case unresolved(Shortcode)

    var errorDescription: String? {
        switch self {
        case let .missingDecision(id):
            "Collision \(id) has no decision."
        case .invalidAliasIndex:
            "An alias changed while collision decisions were being applied."
        case .cannotDropPrimaryShortcode:
            "An emoji’s primary shortcode cannot be dropped."
        case let .cannotReplaceReservedShortcode(shortcode):
            "Shortcode \(shortcode.rawValue) is protected. Keep it or rename the incoming emoji."
        case let .staleExistingOwner(itemID):
            "Emoji \(itemID) changed after the import preview. Review the conflicts again before installing."
        case let .unresolved(shortcode):
            "Shortcode \(shortcode.rawValue) still collides after applying decisions."
        }
    }
}
