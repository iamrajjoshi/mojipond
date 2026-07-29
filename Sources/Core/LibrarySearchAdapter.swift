import Foundation

enum LibrarySearchAdapterError: Error, Equatable, LocalizedError, Sendable {
    case missingUnicode(itemID: UUID)
    case missingAsset(itemID: UUID)
    case missingGitHubSource(packID: UUID)

    var errorDescription: String? {
        switch self {
        case let .missingUnicode(itemID):
            "Library item \(itemID) declares Unicode content but has no Unicode value."
        case let .missingAsset(itemID):
            "Library item \(itemID) declares media content but has no managed asset."
        case let .missingGitHubSource(packID):
            "GitHub-backed pack \(packID) has no GitHub source metadata."
        }
    }
}

/// Converts persisted library records into the richer immutable values used by
/// local search. This adapter copies metadata only; it never opens asset files.
enum EmojiLibrarySearchAdapter {
    static func catalog(
        from packs: [EmojiPack],
        priorityByPackID: [UUID: Int] = [:]
    ) throws -> [EmojiCatalogPack] {
        try packs
            .filter(\.isEnabled)
            .map { pack in
                try catalogPack(
                    from: pack,
                    priority: priorityByPackID[pack.id, default: 0]
                )
            }
    }

    static func catalogPack(
        from pack: EmojiPack,
        priority: Int
    ) throws -> EmojiCatalogPack {
        let packID = pack.id.uuidString
        let source: EmojiPackSource
        switch pack.source.kind {
        case .builtIn:
            source = .builtIn(
                dataset: pack.source.displayLocation ?? "built-in",
                revision: pack.updateMetadata.sourceRevision
            )
        case .github:
            guard let github = pack.source.github else {
                throw LibrarySearchAdapterError.missingGitHubSource(packID: pack.id)
            }
            source = .github(
                owner: github.owner,
                repository: github.repository,
                revision: github.ref,
                subdirectory: github.subdirectory
            )
        case .individualFiles, .folder, .slackManifest, .zipArchive:
            source = .local
        }

        let items = try pack.items.map { libraryItem in
            EmojiItem(
                id: libraryItem.id.uuidString,
                shortcode: libraryItem.shortcode,
                name: libraryItem.displayName ?? libraryItem.shortcode.rawValue,
                aliases: libraryItem.aliases.map(\.rawValue),
                keywords: libraryItem.tags,
                category: libraryItem.category ?? "Custom",
                content: try content(from: libraryItem),
                packID: packID,
                packPriority: priority,
                order: libraryItem.order
            )
        }

        return EmojiCatalogPack(
            id: packID,
            name: pack.name,
            source: source,
            isEnabled: true,
            priority: priority,
            items: items
        )
    }

    private static func content(from item: LibraryEmoji) throws -> EmojiContent {
        switch item.payload.kind {
        case .unicode:
            guard let value = item.payload.unicode else {
                throw LibrarySearchAdapterError.missingUnicode(itemID: item.id)
            }
            return .unicode(UnicodeEmojiContent(value: value))

        case .asset:
            guard let asset = item.payload.asset else {
                throw LibrarySearchAdapterError.missingAsset(itemID: item.id)
            }
            return .media(
                MediaEmojiContent(
                    mediaType: mediaType(for: asset.format),
                    relativePath: asset.relativePath,
                    originalFilename: item.sourceFilename,
                    contentHash: asset.sha256,
                    dimensions: MediaDimensions(
                        width: asset.pixelWidth,
                        height: asset.pixelHeight
                    ),
                    isAnimated: asset.frameCount > 1
                )
            )
        }
    }

    private static func mediaType(for format: AssetFormat) -> EmojiMediaType {
        switch format {
        case .png: .png
        case .jpeg: .jpeg
        case .gif: .gif
        case .webP: .webP
        }
    }
}
