import Foundation

actor LibraryStore {
    private static let maximumManifestBytes: Int64 = 10 * 1_024 * 1_024

    let rootURL: URL
    let manifestURL: URL
    let assetsURL: URL

    private let fileManager: FileManager
    private let validator: AssetValidator
    private let reservedShortcodes: Set<Shortcode>
    private var cachedLibrary: MojiPondLibrary?

    init(
        rootURL: URL,
        validator: AssetValidator = .init(),
        fileManager: FileManager = .default,
        reservedShortcodes: Set<Shortcode> = []
    ) {
        self.rootURL = rootURL.standardizedFileURL
        manifestURL = self.rootURL.appendingPathComponent(
            MojiPondLibrary.manifestFilename,
            isDirectory: false
        )
        assetsURL = self.rootURL.appendingPathComponent("assets", isDirectory: true)
        self.validator = validator
        self.fileManager = fileManager
        self.reservedShortcodes = reservedShortcodes
    }

    func snapshot() throws -> MojiPondLibrary {
        try loadIfNeeded()
    }

    func reload() throws -> MojiPondLibrary {
        cachedLibrary = nil
        return try loadIfNeeded()
    }

    func assetURL(for asset: StoredAsset) throws -> URL {
        guard StoredAsset.isSafeRelativePath(asset.relativePath) else {
            throw LibraryStoreError.unsafeStoredPath(asset.relativePath)
        }
        let url = rootURL.appendingPathComponent(asset.relativePath).standardizedFileURL
        guard Self.isDescendant(url, of: rootURL) else {
            throw LibraryStoreError.unsafeStoredPath(asset.relativePath)
        }
        return url
    }

    @discardableResult
    func createPack(
        name: String,
        source: PackSource = PackSource(kind: .individualFiles)
    ) throws -> EmojiPack {
        let id = UUID()
        return try createPack(
            id: id,
            manifest: PackManifestMetadata(packID: .local(id), name: name),
            source: source
        )
    }

    @discardableResult
    func createPack(
        id: UUID = UUID(),
        manifest: PackManifestMetadata,
        source: PackSource = PackSource(kind: .individualFiles)
    ) throws -> EmojiPack {
        var library = try loadIfNeeded()
        let pack = EmojiPack(
            id: id,
            name: manifest.name,
            manifest: manifest,
            priority: library.packs.count,
            source: source,
            updateMetadata: PackUpdateMetadata(
                contentSHA256: Self.packDigest(items: [])
            ),
            items: []
        )
        library.packs.append(pack)
        Self.recalculatePriorities(in: &library)
        try commit(library)
        return pack
    }

    /// Creates a Unicode-backed emoji in an existing user pack.
    ///
    /// Shortcodes are checked across the whole library before the manifest is
    /// changed. Existing entries are never replaced implicitly.
    @discardableResult
    func createUnicodeItem(
        in packID: UUID,
        shortcode: Shortcode,
        unicode: String,
        aliases: [Shortcode] = [],
        displayName: String? = nil,
        tags: [String] = [],
        category: String? = nil,
        additionalReservedShortcodes: Set<Shortcode> = []
    ) throws -> LibraryEmoji {
        var library = try loadIfNeeded()
        guard let packIndex = library.packs.firstIndex(
            where: { $0.id == packID }
        ) else {
            throw LibraryStoreError.packNotFound(packID)
        }
        guard library.packs[packIndex].source.kind != .builtIn else {
            throw LibraryStoreError.cannotModifyBuiltInPack(packID)
        }
        try UnicodeEmojiValueValidator.validate(unicode)

        let claims = [shortcode] + aliases
        guard Set(claims).count == claims.count else {
            throw LibraryStoreError.duplicateItemClaims
        }
        let itemID = UUID()
        try ensureClaimsAreAvailable(
            claims,
            excludingItemID: itemID,
            additionalReservedShortcodes:
                additionalReservedShortcodes,
            in: library
        )

        let item = LibraryEmoji(
            id: itemID,
            shortcode: shortcode,
            aliases: aliases,
            displayName: displayName,
            tags: tags,
            category: category,
            order: library.packs[packIndex].items.count,
            sourceFilename: nil,
            payload: .unicode(unicode)
        )
        library.packs[packIndex].items.append(item)
        try touchPack(at: packIndex, in: &library)
        try commit(library)
        return item
    }

    @discardableResult
    func install(_ resolved: ResolvedPackImport) throws -> EmojiPack {
        var library = try loadIfNeeded()
        guard !resolved.pack.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw LibraryStoreError.emptyPackName
        }
        guard !library.packs.contains(where: { $0.id == resolved.pack.id }) else {
            throw LibraryStoreError.packAlreadyExists(resolved.pack.id)
        }
        try ensureClaimsAreNotReserved(
            resolved.pack.items.flatMap {
                [$0.shortcode] + $0.aliases
            }
        )

        try prepareDirectories()
        let stagingURL = rootURL.appendingPathComponent(
            ".staging-\(UUID().uuidString.lowercased())",
            isDirectory: true
        )
        let finalPackAssetsURL = assetsURL.appendingPathComponent(
            resolved.pack.id.uuidString.lowercased(),
            isDirectory: true
        )
        guard !fileManager.fileExists(atPath: stagingURL.path),
              !fileManager.fileExists(atPath: finalPackAssetsURL.path) else {
            throw LibraryStoreError.assetDirectoryAlreadyExists
        }

        try fileManager.createDirectory(
            at: stagingURL,
            withIntermediateDirectories: false,
            attributes: [.posixPermissions: 0o700]
        )
        var stagingStillExists = true
        defer {
            if stagingStillExists {
                try? fileManager.removeItem(at: stagingURL)
            }
        }

        var installedItems: [LibraryEmoji] = []
        var copiedFilenames = Set<String>()
        for (candidateIndex, candidate) in resolved.pack.items.enumerated() {
            let payload: EmojiPayload
            let sourceFilename: String?
            switch candidate.content {
            case let .unicode(value):
                try UnicodeEmojiValueValidator.validate(value)
                payload = .unicode(value)
                sourceFilename = nil
            case let .asset(previewValidation):
                let currentValidation = try validator.validate(
                    fileAt: candidate.sourceURL
                )
                guard currentValidation == previewValidation else {
                    throw LibraryStoreError.sourceChanged(candidate.sourceURL)
                }

                let filename = "\(currentValidation.digest.sha256).\(currentValidation.format.preferredFilenameExtension)"
                let stagedAssetURL = stagingURL.appendingPathComponent(
                    filename,
                    isDirectory: false
                )
                if copiedFilenames.insert(filename).inserted {
                    try fileManager.copyItem(
                        at: candidate.sourceURL,
                        to: stagedAssetURL
                    )
                    try fileManager.setAttributes(
                        [.posixPermissions: 0o600],
                        ofItemAtPath: stagedAssetURL.path
                    )
                    let copiedValidation = try validator.validate(
                        fileAt: stagedAssetURL
                    )
                    guard copiedValidation == currentValidation else {
                        throw LibraryStoreError.copyVerificationFailed(
                            candidate.sourceFilename
                        )
                    }
                }

                let relativePath = [
                    "assets",
                    resolved.pack.id.uuidString.lowercased(),
                    filename
                ].joined(separator: "/")
                payload = .asset(
                    StoredAsset(
                        relativePath: relativePath,
                        format: currentValidation.format,
                        sha256: currentValidation.digest.sha256,
                        byteCount: currentValidation.digest.byteCount,
                        pixelWidth: currentValidation.pixelWidth,
                        pixelHeight: currentValidation.pixelHeight,
                        frameCount: currentValidation.frameCount
                    )
                )
                sourceFilename = candidate.sourceFilename
            }
            installedItems.append(
                LibraryEmoji(
                    id: candidate.id,
                    shortcode: candidate.shortcode,
                    aliases: candidate.aliases,
                    displayName: candidate.displayName,
                    tags: candidate.tags,
                    category: candidate.category,
                    order: candidate.order >= 0 ? candidate.order : candidateIndex,
                    sourceFilename: sourceFilename,
                    payload: payload
                )
            )
        }

        var metadata = resolved.pack.updateMetadata
        metadata.lastUpdatedAt = Date()
        if metadata.contentSHA256 == nil {
            metadata.contentSHA256 = Self.packDigest(
                items: installedItems
            )
        }
        var manifest = resolved.pack.manifest
        manifest.name = resolved.pack.name.trimmingCharacters(in: .whitespacesAndNewlines)
        let installedPack = EmojiPack(
            id: resolved.pack.id,
            name: manifest.name,
            manifest: manifest,
            priority: library.packs.count,
            source: resolved.pack.source,
            updateMetadata: metadata,
            items: installedItems
        )

        for packIndex in library.packs.indices {
            library.packs[packIndex].items.removeAll {
                resolved.existingItemIDsToReplace.contains($0.id)
            }
        }
        library.packs.append(installedPack)
        Self.recalculatePriorities(in: &library)
        library.updatedAt = Date()
        _ = try library.validated()

        try fileManager.moveItem(at: stagingURL, to: finalPackAssetsURL)
        stagingStillExists = false
        do {
            try persist(library)
        } catch {
            try? fileManager.removeItem(at: finalPackAssetsURL)
            throw error
        }
        cachedLibrary = library
        cleanUpAssetsAfterCommit(in: library)
        return installedPack
    }

    /// Appends reviewed import candidates to an existing pack. New files are
    /// validated into a private staging directory before any managed asset is
    /// moved. If persistence fails, every newly-created managed file is removed.
    @discardableResult
    func append(
        _ resolved: ResolvedPackImport,
        to packID: UUID
    ) throws -> EmojiPack {
        var library = try loadIfNeeded()
        try ensureClaimsAreNotReserved(
            resolved.pack.items.flatMap {
                [$0.shortcode] + $0.aliases
            }
        )
        guard library.packs.contains(where: { $0.id == packID }) else {
            throw LibraryStoreError.packNotFound(packID)
        }

        try prepareDirectories()
        let packAssetsURL = assetsURL.appendingPathComponent(
            packID.uuidString.lowercased(),
            isDirectory: true
        )
        try ensureSafeDirectory(packAssetsURL)
        let stagingURL = rootURL.appendingPathComponent(
            ".staging-\(UUID().uuidString.lowercased())",
            isDirectory: true
        )
        try fileManager.createDirectory(
            at: stagingURL,
            withIntermediateDirectories: false,
            attributes: [.posixPermissions: 0o700]
        )
        defer { try? fileManager.removeItem(at: stagingURL) }

        let appendedItems = try stageImportedItems(
            resolved.pack.items,
            for: packID,
            at: stagingURL
        )
        for index in library.packs.indices {
            library.packs[index].items.removeAll {
                resolved.existingItemIDsToReplace.contains($0.id)
            }
        }
        guard let targetIndex = library.packs.firstIndex(where: { $0.id == packID }) else {
            throw LibraryStoreError.packNotFound(packID)
        }
        library.packs[targetIndex].items.append(contentsOf: appendedItems)
        for index in library.packs[targetIndex].items.indices {
            library.packs[targetIndex].items[index].order = index
        }
        try touchPack(at: targetIndex, in: &library)
        library.updatedAt = Date()
        _ = try library.validated()

        var createdURLs: [URL] = []
        do {
            for filename in Set(
                appendedItems.compactMap { $0.payload.asset?.relativePath }
                    .map { URL(fileURLWithPath: $0).lastPathComponent }
            ) {
                let stagedURL = stagingURL.appendingPathComponent(filename)
                let finalURL = packAssetsURL.appendingPathComponent(filename)
                if fileManager.fileExists(atPath: finalURL.path) {
                    let expected = try validator.validate(fileAt: stagedURL)
                    guard try validator.validate(fileAt: finalURL) == expected else {
                        throw LibraryStoreError.copyVerificationFailed(filename)
                    }
                } else {
                    try fileManager.moveItem(at: stagedURL, to: finalURL)
                    createdURLs.append(finalURL)
                }
            }
            try persist(library)
        } catch {
            for url in createdURLs {
                try? fileManager.removeItem(at: url)
            }
            throw error
        }
        cachedLibrary = library
        cleanUpAssetsAfterCommit(in: library)
        return library.packs[targetIndex]
    }

    /// Replaces the contents of an existing pack after a reviewed re-import.
    /// The pack's runtime identity, order, enabled state, and existing
    /// attribution remain stable. Its entire asset directory is swapped before
    /// the manifest is committed and restored if persistence fails.
    @discardableResult
    func replacePackContents(
        _ resolved: ResolvedPackImport,
        in packID: UUID
    ) throws -> EmojiPack {
        var library = try loadIfNeeded()
        try ensureClaimsAreNotReserved(
            resolved.pack.items.flatMap {
                [$0.shortcode] + $0.aliases
            }
        )
        guard let targetIndex = library.packs.firstIndex(where: { $0.id == packID }) else {
            throw LibraryStoreError.packNotFound(packID)
        }
        let existingPack = library.packs[targetIndex]

        try prepareDirectories()
        let stagingURL = rootURL.appendingPathComponent(
            ".staging-\(UUID().uuidString.lowercased())",
            isDirectory: true
        )
        let backupURL = rootURL.appendingPathComponent(
            ".backup-\(UUID().uuidString.lowercased())",
            isDirectory: true
        )
        let finalPackAssetsURL = assetsURL.appendingPathComponent(
            packID.uuidString.lowercased(),
            isDirectory: true
        )
        try fileManager.createDirectory(
            at: stagingURL,
            withIntermediateDirectories: false,
            attributes: [.posixPermissions: 0o700]
        )
        var stagingStillExists = true
        var backupStillExists = false
        defer {
            if stagingStillExists {
                try? fileManager.removeItem(at: stagingURL)
            }
            if backupStillExists {
                try? fileManager.removeItem(at: backupURL)
            }
        }

        var replacementItems = try stageImportedItems(
            resolved.pack.items,
            for: packID,
            at: stagingURL
        )
        for index in replacementItems.indices {
            replacementItems[index].order = index
        }

        for index in library.packs.indices where index != targetIndex {
            library.packs[index].items.removeAll {
                resolved.existingItemIDsToReplace.contains($0.id)
            }
        }

        var updatedManifest = existingPack.manifest
        updatedManifest.version = resolved.pack.manifest.version
        if updatedManifest.author == nil {
            updatedManifest.author = resolved.pack.manifest.author
        }
        if updatedManifest.description == nil {
            updatedManifest.description = resolved.pack.manifest.description
        }
        if updatedManifest.sourceURL == nil {
            updatedManifest.sourceURL = resolved.pack.manifest.sourceURL
        }
        if updatedManifest.license == nil {
            updatedManifest.license = resolved.pack.manifest.license
        }
        var updatedMetadata = existingPack.updateMetadata
        updatedMetadata.lastUpdatedAt = Date()
        updatedMetadata.lastCheckedAt = Date()
        updatedMetadata.sourceRevision =
            resolved.pack.updateMetadata.sourceRevision
                ?? existingPack.updateMetadata.sourceRevision
        updatedMetadata.sourceETag =
            resolved.pack.updateMetadata.sourceETag
                ?? existingPack.updateMetadata.sourceETag
        updatedMetadata.contentSHA256 = Self.packDigest(items: replacementItems)

        library.packs[targetIndex] = EmojiPack(
            id: existingPack.id,
            name: existingPack.name,
            manifest: updatedManifest,
            priority: existingPack.priority,
            isEnabled: existingPack.isEnabled,
            source: existingPack.source,
            updateMetadata: updatedMetadata,
            items: replacementItems
        )
        library.updatedAt = Date()
        _ = try library.validated()

        let hadExistingAssets = fileManager.fileExists(
            atPath: finalPackAssetsURL.path
        )
        if hadExistingAssets {
            try ensureSafeDirectory(finalPackAssetsURL)
            try fileManager.moveItem(at: finalPackAssetsURL, to: backupURL)
            backupStillExists = true
        }
        do {
            try fileManager.moveItem(at: stagingURL, to: finalPackAssetsURL)
            stagingStillExists = false
            try persist(library)
        } catch {
            try? fileManager.removeItem(at: finalPackAssetsURL)
            if backupStillExists {
                try? fileManager.moveItem(at: backupURL, to: finalPackAssetsURL)
                backupStillExists = false
            }
            throw error
        }

        cachedLibrary = library
        if backupStillExists {
            do {
                try fileManager.removeItem(at: backupURL)
                backupStillExists = false
            } catch {
                // The committed pack is valid. The deferred cleanup gets one
                // more chance without reporting a failed update after commit.
            }
        }
        cleanUpAssetsAfterCommit(in: library)
        return library.packs[targetIndex]
    }

    func setPackEnabled(_ packID: UUID, isEnabled: Bool) throws {
        var library = try loadIfNeeded()
        guard let index = library.packs.firstIndex(where: { $0.id == packID }) else {
            throw LibraryStoreError.packNotFound(packID)
        }
        library.packs[index].isEnabled = isEnabled
        try commit(library)
    }

    @discardableResult
    func updateItemMetadata(
        packID: UUID,
        itemID: UUID,
        shortcode: Shortcode,
        aliases: [Shortcode],
        displayName: String?,
        tags: [String],
        category: String?,
        additionalReservedShortcodes: Set<Shortcode> = []
    ) throws -> LibraryEmoji {
        var library = try loadIfNeeded()
        guard let packIndex = library.packs.firstIndex(where: { $0.id == packID }) else {
            throw LibraryStoreError.packNotFound(packID)
        }
        guard let itemIndex = library.packs[packIndex].items.firstIndex(
            where: { $0.id == itemID }
        ) else {
            throw LibraryStoreError.itemNotFound(itemID)
        }

        let claims = [shortcode] + aliases
        guard Set(claims).count == claims.count else {
            throw LibraryStoreError.duplicateItemClaims
        }
        try ensureClaimsAreAvailable(
            claims,
            excludingItemID: itemID,
            additionalReservedShortcodes:
                additionalReservedShortcodes,
            in: library
        )

        library.packs[packIndex].items[itemIndex].shortcode = shortcode
        library.packs[packIndex].items[itemIndex].aliases = aliases
        library.packs[packIndex].items[itemIndex].displayName = displayName
        library.packs[packIndex].items[itemIndex].tags = tags
        library.packs[packIndex].items[itemIndex].category = category
        try touchPack(at: packIndex, in: &library)
        let updatedItem = library.packs[packIndex].items[itemIndex]
        try commit(library)
        return updatedItem
    }

    @discardableResult
    func replaceItemAsset(
        packID: UUID,
        itemID: UUID,
        with sourceURL: URL
    ) throws -> LibraryEmoji {
        var library = try loadIfNeeded()
        guard let packIndex = library.packs.firstIndex(where: { $0.id == packID }) else {
            throw LibraryStoreError.packNotFound(packID)
        }
        guard let itemIndex = library.packs[packIndex].items.firstIndex(
            where: { $0.id == itemID }
        ) else {
            throw LibraryStoreError.itemNotFound(itemID)
        }

        let validatedSource = try validator.validate(fileAt: sourceURL)
        try prepareDirectories()
        let packAssetsURL = assetsURL.appendingPathComponent(
            packID.uuidString.lowercased(),
            isDirectory: true
        )
        try ensureSafeDirectory(packAssetsURL)
        let filename = [
            validatedSource.digest.sha256,
            validatedSource.format.preferredFilenameExtension
        ].joined(separator: ".")
        let finalURL = packAssetsURL.appendingPathComponent(filename, isDirectory: false)
        let stagingURL = rootURL.appendingPathComponent(
            ".staging-\(UUID().uuidString.lowercased())",
            isDirectory: true
        )
        try fileManager.createDirectory(
            at: stagingURL,
            withIntermediateDirectories: false,
            attributes: [.posixPermissions: 0o700]
        )
        defer { try? fileManager.removeItem(at: stagingURL) }

        let stagedFile = stagingURL.appendingPathComponent(filename, isDirectory: false)
        try fileManager.copyItem(at: sourceURL, to: stagedFile)
        try fileManager.setAttributes(
            [.posixPermissions: 0o600],
            ofItemAtPath: stagedFile.path
        )
        guard try validator.validate(fileAt: stagedFile) == validatedSource else {
            throw LibraryStoreError.copyVerificationFailed(sourceURL.lastPathComponent)
        }

        var createdFinalAsset = false
        if fileManager.fileExists(atPath: finalURL.path) {
            guard try validator.validate(fileAt: finalURL) == validatedSource else {
                throw LibraryStoreError.copyVerificationFailed(filename)
            }
        } else {
            try fileManager.moveItem(at: stagedFile, to: finalURL)
            createdFinalAsset = true
        }

        let relativePath = [
            "assets",
            packID.uuidString.lowercased(),
            filename
        ].joined(separator: "/")
        let storedAsset = StoredAsset(
            relativePath: relativePath,
            format: validatedSource.format,
            sha256: validatedSource.digest.sha256,
            byteCount: validatedSource.digest.byteCount,
            pixelWidth: validatedSource.pixelWidth,
            pixelHeight: validatedSource.pixelHeight,
            frameCount: validatedSource.frameCount
        )
        library.packs[packIndex].items[itemIndex].payload = .asset(storedAsset)
        library.packs[packIndex].items[itemIndex].sourceFilename = sourceURL.lastPathComponent
        try touchPack(at: packIndex, in: &library)
        let updatedItem = library.packs[packIndex].items[itemIndex]
        do {
            try commit(library)
        } catch {
            if createdFinalAsset {
                try? fileManager.removeItem(at: finalURL)
            }
            throw error
        }
        cleanUpAssetsAfterCommit(in: library)
        return updatedItem
    }

    @discardableResult
    func removeItem(packID: UUID, itemID: UUID) throws -> LibraryEmoji {
        var library = try loadIfNeeded()
        guard let packIndex = library.packs.firstIndex(where: { $0.id == packID }) else {
            throw LibraryStoreError.packNotFound(packID)
        }
        guard let itemIndex = library.packs[packIndex].items.firstIndex(
            where: { $0.id == itemID }
        ) else {
            throw LibraryStoreError.itemNotFound(itemID)
        }
        let removed = library.packs[packIndex].items.remove(at: itemIndex)
        for index in library.packs[packIndex].items.indices {
            library.packs[packIndex].items[index].order = index
        }
        try touchPack(at: packIndex, in: &library)
        try commit(library)
        cleanUpAssetsAfterCommit(in: library)
        return removed
    }

    func movePack(_ packID: UUID, to destinationIndex: Int) throws {
        var library = try loadIfNeeded()
        guard library.packs.indices.contains(destinationIndex) else {
            throw LibraryStoreError.invalidPackIndex(destinationIndex)
        }
        guard let sourceIndex = library.packs.firstIndex(where: { $0.id == packID }) else {
            throw LibraryStoreError.packNotFound(packID)
        }
        let pack = library.packs.remove(at: sourceIndex)
        library.packs.insert(pack, at: destinationIndex)
        Self.recalculatePriorities(in: &library)
        try commit(library)
    }

    func removePack(_ packID: UUID) throws {
        var library = try loadIfNeeded()
        guard let index = library.packs.firstIndex(where: { $0.id == packID }) else {
            throw LibraryStoreError.packNotFound(packID)
        }
        library.packs.remove(at: index)
        Self.recalculatePriorities(in: &library)
        try commit(library)
        cleanUpAssetsAfterCommit(in: library)
    }

    func setPackUpdateMetadata(
        _ packID: UUID,
        metadata: PackUpdateMetadata
    ) throws {
        var library = try loadIfNeeded()
        guard let index = library.packs.firstIndex(where: { $0.id == packID }) else {
            throw LibraryStoreError.packNotFound(packID)
        }
        library.packs[index].updateMetadata = metadata
        try commit(library)
    }

    func setPackManifestMetadata(
        _ packID: UUID,
        metadata: PackManifestMetadata
    ) throws {
        var library = try loadIfNeeded()
        guard let index = library.packs.firstIndex(where: { $0.id == packID }) else {
            throw LibraryStoreError.packNotFound(packID)
        }
        library.packs[index].manifest = metadata
        try commit(library)
    }

    func markPackChecked(
        _ packID: UUID,
        at date: Date = Date(),
        sourceRevision: String? = nil,
        sourceETag: String? = nil
    ) throws {
        var library = try loadIfNeeded()
        guard let index = library.packs.firstIndex(where: { $0.id == packID }) else {
            throw LibraryStoreError.packNotFound(packID)
        }
        library.packs[index].updateMetadata.lastCheckedAt = date
        if let sourceRevision {
            library.packs[index].updateMetadata.sourceRevision = sourceRevision
        }
        if let sourceETag {
            library.packs[index].updateMetadata.sourceETag = sourceETag
        }
        try commit(library)
    }

    func cleanUpAssets() throws {
        let library = try loadIfNeeded()
        try cleanupUnreferencedAssets(in: library)
    }

    @discardableResult
    func exportPortablePack(
        _ packID: UUID,
        to destinationURL: URL
    ) throws -> URL {
        let library = try loadIfNeeded()
        guard let pack = library.packs.first(where: { $0.id == packID }) else {
            throw LibraryStoreError.packNotFound(packID)
        }
        guard !fileManager.fileExists(atPath: destinationURL.path),
              (try? fileManager.destinationOfSymbolicLink(atPath: destinationURL.path)) == nil
        else {
            throw LibraryStoreError.exportDestinationAlreadyExists
        }
        let parentURL = destinationURL.deletingLastPathComponent()
        let parentValues = try parentURL.resourceValues(forKeys: [
            .isDirectoryKey,
            .isSymbolicLinkKey
        ])
        guard parentValues.isDirectory == true, parentValues.isSymbolicLink != true else {
            throw LibraryStoreError.unsafeExportDestination
        }

        let stagingURL = parentURL.appendingPathComponent(
            ".mojipond-export-\(UUID().uuidString.lowercased())",
            isDirectory: true
        )
        try fileManager.createDirectory(
            at: stagingURL,
            withIntermediateDirectories: false,
            attributes: [.posixPermissions: 0o700]
        )
        var shouldCleanUp = true
        defer {
            if shouldCleanUp {
                try? fileManager.removeItem(at: stagingURL)
            }
        }

        let exportedAssetsURL = stagingURL.appendingPathComponent("emoji", isDirectory: true)
        var createdAssetsDirectory = false
        var portableItems: [PortablePackEmoji] = []
        for item in pack.items.sorted(by: { $0.order < $1.order }) {
            switch item.payload.kind {
            case .unicode:
                guard let unicode = item.payload.unicode else {
                    throw LibraryModelError.invalidPayload
                }
                try UnicodeEmojiValueValidator.validate(unicode)
                portableItems.append(
                    PortablePackEmoji(
                        shortcode: item.shortcode,
                        aliases: item.aliases,
                        displayName: item.displayName,
                        tags: item.tags,
                        category: item.category,
                        order: item.order,
                        unicode: unicode
                    )
                )
            case .asset:
                guard let asset = item.payload.asset else {
                    throw LibraryModelError.invalidPayload
                }
                if !createdAssetsDirectory {
                    try fileManager.createDirectory(
                        at: exportedAssetsURL,
                        withIntermediateDirectories: false,
                        attributes: [.posixPermissions: 0o700]
                    )
                    createdAssetsDirectory = true
                }
                let sourceAssetURL = try assetURL(for: asset)
                let currentValidation = try validator.validate(
                    fileAt: sourceAssetURL
                )
                guard currentValidation.digest.sha256 == asset.sha256,
                      currentValidation.digest.byteCount == asset.byteCount,
                      currentValidation.format == asset.format else {
                    throw LibraryStoreError.storedAssetChanged(
                        asset.relativePath
                    )
                }

                let filename = "\(item.shortcode.rawValue).\(asset.format.preferredFilenameExtension)"
                let exportedRelativePath = "emoji/\(filename)"
                let exportedURL = exportedAssetsURL.appendingPathComponent(
                    filename,
                    isDirectory: false
                )
                try fileManager.copyItem(
                    at: sourceAssetURL,
                    to: exportedURL
                )
                try fileManager.setAttributes(
                    [.posixPermissions: 0o600],
                    ofItemAtPath: exportedURL.path
                )
                guard try validator.validate(fileAt: exportedURL)
                    == currentValidation else {
                    throw LibraryStoreError.copyVerificationFailed(filename)
                }
                portableItems.append(
                    PortablePackEmoji(
                        shortcode: item.shortcode,
                        aliases: item.aliases,
                        displayName: item.displayName,
                        tags: item.tags,
                        category: item.category,
                        order: item.order,
                        file: exportedRelativePath
                    )
                )
            }
        }

        let portableManifest = try PortablePackManifest(
            id: pack.manifest.packID,
            name: pack.manifest.name,
            version: pack.manifest.version,
            author: pack.manifest.author,
            description: pack.manifest.description,
            sourceURL: pack.manifest.sourceURL,
            license: pack.manifest.license,
            emoji: portableItems
        ).validated()
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        let manifestData = try encoder.encode(portableManifest)
        let exportedManifestURL = stagingURL.appendingPathComponent(
            MojiPondLibrary.manifestFilename,
            isDirectory: false
        )
        try manifestData.write(to: exportedManifestURL, options: [.atomic])
        try fileManager.setAttributes(
            [.posixPermissions: 0o600],
            ofItemAtPath: exportedManifestURL.path
        )

        try fileManager.moveItem(at: stagingURL, to: destinationURL)
        shouldCleanUp = false
        return destinationURL
    }

    private func loadIfNeeded() throws -> MojiPondLibrary {
        if let cachedLibrary {
            return cachedLibrary
        }
        try prepareDirectories()

        if (try? fileManager.destinationOfSymbolicLink(atPath: manifestURL.path)) != nil {
            throw LibraryStoreError.unsafeManifest
        }
        guard fileManager.fileExists(atPath: manifestURL.path) else {
            let library = MojiPondLibrary()
            try persist(library)
            cachedLibrary = library
            return library
        }

        let values = try manifestURL.resourceValues(forKeys: [
            .isRegularFileKey,
            .isSymbolicLinkKey,
            .fileSizeKey
        ])
        guard values.isRegularFile == true, values.isSymbolicLink != true else {
            throw LibraryStoreError.unsafeManifest
        }
        let size = Int64(values.fileSize ?? 0)
        guard size > 0, size <= Self.maximumManifestBytes else {
            throw LibraryStoreError.manifestSizeInvalid(size)
        }

        let data = try Data(contentsOf: manifestURL, options: [.mappedIfSafe])
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let decoded: MojiPondLibrary
        do {
            decoded = try decoder.decode(MojiPondLibrary.self, from: data)
        } catch {
            throw LibraryStoreError.cannotDecodeManifest(error.localizedDescription)
        }
        let migrated = try decoded.migratedToCurrent()
        let library = try migrated.validated()
        if migrated.schemaVersion != decoded.schemaVersion {
            try persist(library)
        }
        cachedLibrary = library
        return library
    }

    private func commit(_ proposedLibrary: MojiPondLibrary) throws {
        var library = proposedLibrary
        library.updatedAt = Date()
        _ = try library.validated()
        try persist(library)
        cachedLibrary = library
    }

    private func persist(_ library: MojiPondLibrary) throws {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        let data = try encoder.encode(library)
        guard Int64(data.count) <= Self.maximumManifestBytes else {
            throw LibraryStoreError.manifestSizeInvalid(Int64(data.count))
        }
        try data.write(to: manifestURL, options: [.atomic])
        try fileManager.setAttributes(
            [.posixPermissions: 0o600],
            ofItemAtPath: manifestURL.path
        )
    }

    private func prepareDirectories() throws {
        try ensureSafeDirectory(rootURL)
        try ensureSafeDirectory(assetsURL)
    }

    private func ensureSafeDirectory(_ url: URL) throws {
        if (try? fileManager.destinationOfSymbolicLink(atPath: url.path)) != nil {
            throw LibraryStoreError.unsafeDirectory(url)
        }
        if fileManager.fileExists(atPath: url.path) {
            let values = try url.resourceValues(forKeys: [
                .isDirectoryKey,
                .isSymbolicLinkKey
            ])
            guard values.isDirectory == true, values.isSymbolicLink != true else {
                throw LibraryStoreError.unsafeDirectory(url)
            }
        } else {
            try fileManager.createDirectory(
                at: url,
                withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700]
            )
        }
    }

    /// The manifest is the source of truth. Once it has been committed, a
    /// failure to reclaim an unreferenced file must not make the caller believe
    /// the mutation failed. `cleanUpAssets()` remains available as a
    /// retryable, throwing maintenance operation.
    private func cleanUpAssetsAfterCommit(
        in library: MojiPondLibrary
    ) {
        try? cleanupUnreferencedAssets(in: library)
    }

    private func cleanupUnreferencedAssets(in library: MojiPondLibrary) throws {
        try ensureSafeDirectory(assetsURL)
        let referencedPaths = Set(
            library.packs.flatMap(\.items).compactMap { item -> String? in
                guard item.payload.kind == .asset else {
                    return nil
                }
                return item.payload.asset?.relativePath
            }
        )
        let keys: [URLResourceKey] = [
            .isDirectoryKey,
            .isRegularFileKey,
            .isSymbolicLinkKey
        ]
        guard let enumerator = fileManager.enumerator(
            at: assetsURL,
            includingPropertiesForKeys: keys,
            options: [.skipsHiddenFiles],
            errorHandler: { _, _ in false }
        ) else {
            throw LibraryStoreError.cannotEnumerateAssets
        }

        var unreferencedFiles: [URL] = []
        var directories: [URL] = []
        let rootPath = rootURL.path
        for case let url as URL in enumerator {
            let standardized = url.standardizedFileURL
            guard Self.isDescendant(standardized, of: assetsURL) else {
                throw LibraryStoreError.unsafeStoredPath(standardized.path)
            }
            let values = try standardized.resourceValues(forKeys: Set(keys))
            if values.isSymbolicLink == true {
                unreferencedFiles.append(standardized)
                if values.isDirectory == true {
                    enumerator.skipDescendants()
                }
                continue
            }
            if values.isDirectory == true {
                directories.append(standardized)
                continue
            }
            guard values.isRegularFile == true else {
                unreferencedFiles.append(standardized)
                continue
            }
            let relativePath = String(standardized.path.dropFirst(rootPath.count + 1))
            if !referencedPaths.contains(relativePath) {
                unreferencedFiles.append(standardized)
            }
        }

        for url in unreferencedFiles {
            try fileManager.removeItem(at: url)
        }
        for directory in directories.sorted(by: { $0.path.count > $1.path.count }) {
            if (try fileManager.contentsOfDirectory(atPath: directory.path)).isEmpty {
                try fileManager.removeItem(at: directory)
            }
        }
    }

    private func ensureClaimsAreAvailable(
        _ claims: [Shortcode],
        excludingItemID: UUID,
        additionalReservedShortcodes: Set<Shortcode> = [],
        in library: MojiPondLibrary
    ) throws {
        try ensureClaimsAreNotReserved(
            claims,
            additionalReservedShortcodes:
                additionalReservedShortcodes
        )
        let requested = Set(claims)
        for pack in library.packs {
            for item in pack.items where item.id != excludingItemID {
                for existing in [item.shortcode] + item.aliases where requested.contains(existing) {
                    throw LibraryStoreError.shortcodeCollision(
                        existing,
                        existingItemID: item.id
                    )
                }
            }
        }
    }

    private func ensureClaimsAreNotReserved(
        _ claims: [Shortcode],
        additionalReservedShortcodes: Set<Shortcode> = []
    ) throws {
        if let shortcode = Set(claims)
            .intersection(
                reservedShortcodes.union(
                    additionalReservedShortcodes
                )
            )
            .sorted()
            .first {
            throw LibraryStoreError.reservedShortcode(shortcode)
        }
    }

    private func stageImportedItems(
        _ candidates: [PreparedEmoji],
        for packID: UUID,
        at stagingURL: URL
    ) throws -> [LibraryEmoji] {
        var copiedFilenames = Set<String>()
        return try candidates.enumerated().map { index, candidate in
            let payload: EmojiPayload
            let sourceFilename: String?
            switch candidate.content {
            case let .unicode(value):
                try UnicodeEmojiValueValidator.validate(value)
                payload = .unicode(value)
                sourceFilename = nil
            case let .asset(previewValidation):
                let currentValidation = try validator.validate(
                    fileAt: candidate.sourceURL
                )
                guard currentValidation == previewValidation else {
                    throw LibraryStoreError.sourceChanged(candidate.sourceURL)
                }
                let filename = [
                    currentValidation.digest.sha256,
                    currentValidation.format.preferredFilenameExtension
                ].joined(separator: ".")
                let stagedAssetURL = stagingURL.appendingPathComponent(
                    filename,
                    isDirectory: false
                )
                if copiedFilenames.insert(filename).inserted {
                    try fileManager.copyItem(
                        at: candidate.sourceURL,
                        to: stagedAssetURL
                    )
                    try fileManager.setAttributes(
                        [.posixPermissions: 0o600],
                        ofItemAtPath: stagedAssetURL.path
                    )
                    guard try validator.validate(fileAt: stagedAssetURL)
                        == currentValidation else {
                        throw LibraryStoreError.copyVerificationFailed(
                            candidate.sourceFilename
                        )
                    }
                }
                payload = .asset(
                    StoredAsset(
                        relativePath: [
                            "assets",
                            packID.uuidString.lowercased(),
                            filename
                        ].joined(separator: "/"),
                        format: currentValidation.format,
                        sha256: currentValidation.digest.sha256,
                        byteCount: currentValidation.digest.byteCount,
                        pixelWidth: currentValidation.pixelWidth,
                        pixelHeight: currentValidation.pixelHeight,
                        frameCount: currentValidation.frameCount
                    )
                )
                sourceFilename = candidate.sourceFilename
            }
            return LibraryEmoji(
                id: candidate.id,
                shortcode: candidate.shortcode,
                aliases: candidate.aliases,
                displayName: candidate.displayName,
                tags: candidate.tags,
                category: candidate.category,
                order: index,
                sourceFilename: sourceFilename,
                payload: payload
            )
        }
    }

    private func touchPack(
        at index: Int,
        in library: inout MojiPondLibrary
    ) throws {
        library.packs[index].updateMetadata.lastUpdatedAt = Date()
        library.packs[index].updateMetadata.contentSHA256 = Self.packDigest(
            items: library.packs[index].items
        )
        try library.packs[index].manifest.validate()
    }

    private static func packDigest(items: [LibraryEmoji]) -> String {
        let stableInput = items.sorted { $0.shortcode < $1.shortcode }.map { item in
            [
                item.shortcode.rawValue,
                item.aliases.sorted().map(\.rawValue).joined(separator: ","),
                item.tags.sorted().joined(separator: ","),
                item.category ?? "",
                String(item.order),
                item.payload.asset?.sha256 ?? item.payload.unicode ?? ""
            ].joined(separator: "\u{001F}")
        }.joined(separator: "\u{001E}")
        return ContentHasher.sha256(of: Data(stableInput.utf8)).sha256
    }

    private static func recalculatePriorities(in library: inout MojiPondLibrary) {
        for index in library.packs.indices {
            library.packs[index].priority = index
        }
    }

    private static func isDescendant(_ candidate: URL, of root: URL) -> Bool {
        candidate.standardizedFileURL.path.hasPrefix(root.standardizedFileURL.path + "/")
    }
}

enum LibraryStoreError: Error, Equatable, LocalizedError, Sendable {
    case unsafeDirectory(URL)
    case unsafeManifest
    case manifestSizeInvalid(Int64)
    case cannotDecodeManifest(String)
    case unsafeStoredPath(String)
    case emptyPackName
    case packAlreadyExists(UUID)
    case packNotFound(UUID)
    case cannotModifyBuiltInPack(UUID)
    case itemNotFound(UUID)
    case invalidPackIndex(Int)
    case duplicateItemClaims
    case reservedShortcode(Shortcode)
    case shortcodeCollision(Shortcode, existingItemID: UUID)
    case assetDirectoryAlreadyExists
    case sourceChanged(URL)
    case copyVerificationFailed(String)
    case storedAssetChanged(String)
    case cannotEnumerateAssets
    case exportDestinationAlreadyExists
    case unsafeExportDestination

    var errorDescription: String? {
        switch self {
        case let .unsafeDirectory(url):
            "Library directory \(url.path) is not a safe directory."
        case .unsafeManifest:
            "mojipond.json is not a safe regular file."
        case let .manifestSizeInvalid(size):
            "mojipond.json has an invalid size of \(size) bytes."
        case let .cannotDecodeManifest(message):
            "Could not decode mojipond.json: \(message)"
        case let .unsafeStoredPath(path):
            "Stored asset path \(path) is unsafe."
        case .emptyPackName:
            "Pack name cannot be empty."
        case let .packAlreadyExists(id):
            "Pack \(id) already exists."
        case let .packNotFound(id):
            "Pack \(id) was not found."
        case let .cannotModifyBuiltInPack(id):
            "Built-in pack \(id) cannot be changed."
        case let .itemNotFound(id):
            "Emoji \(id) was not found."
        case let .invalidPackIndex(index):
            "Pack index \(index) is out of bounds."
        case .duplicateItemClaims:
            "An emoji shortcode and its aliases must be unique."
        case let .reservedShortcode(shortcode):
            "Shortcode \(shortcode.rawValue) is reserved by the built-in emoji library."
        case let .shortcodeCollision(shortcode, existingItemID):
            "Shortcode \(shortcode.rawValue) is already used by emoji \(existingItemID)."
        case .assetDirectoryAlreadyExists:
            "Pack asset directory already exists."
        case let .sourceChanged(url):
            "Source file changed after preview: \(url.lastPathComponent)."
        case let .copyVerificationFailed(filename):
            "Copied asset \(filename) failed verification."
        case let .storedAssetChanged(path):
            "Stored asset \(path) no longer matches its library metadata."
        case .cannotEnumerateAssets:
            "Could not enumerate stored assets."
        case .exportDestinationAlreadyExists:
            "Portable pack export destination already exists."
        case .unsafeExportDestination:
            "Portable pack export parent is not a safe directory."
        }
    }
}
