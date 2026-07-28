import Foundation

actor LibraryStore {
    private static let maximumManifestBytes: Int64 = 10 * 1_024 * 1_024

    let rootURL: URL
    let manifestURL: URL
    let assetsURL: URL

    private let fileManager: FileManager
    private let validator: AssetValidator
    private var cachedLibrary: MojiPondLibrary?

    init(
        rootURL: URL,
        validator: AssetValidator = .init(),
        fileManager: FileManager = .default
    ) {
        self.rootURL = rootURL.standardizedFileURL
        manifestURL = self.rootURL.appendingPathComponent(
            MojiPondLibrary.manifestFilename,
            isDirectory: false
        )
        assetsURL = self.rootURL.appendingPathComponent("assets", isDirectory: true)
        self.validator = validator
        self.fileManager = fileManager
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

    @discardableResult
    func install(_ resolved: ResolvedPackImport) throws -> EmojiPack {
        var library = try loadIfNeeded()
        guard !resolved.pack.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw LibraryStoreError.emptyPackName
        }
        guard !library.packs.contains(where: { $0.id == resolved.pack.id }) else {
            throw LibraryStoreError.packAlreadyExists(resolved.pack.id)
        }

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
            let currentValidation = try validator.validate(fileAt: candidate.sourceURL)
            guard currentValidation == candidate.asset else {
                throw LibraryStoreError.sourceChanged(candidate.sourceURL)
            }

            let filename = "\(currentValidation.digest.sha256).\(currentValidation.format.preferredFilenameExtension)"
            let stagedAssetURL = stagingURL.appendingPathComponent(filename, isDirectory: false)
            if copiedFilenames.insert(filename).inserted {
                try fileManager.copyItem(at: candidate.sourceURL, to: stagedAssetURL)
                try fileManager.setAttributes(
                    [.posixPermissions: 0o600],
                    ofItemAtPath: stagedAssetURL.path
                )
                let copiedValidation = try validator.validate(fileAt: stagedAssetURL)
                guard copiedValidation == currentValidation else {
                    throw LibraryStoreError.copyVerificationFailed(candidate.sourceFilename)
                }
            }

            let relativePath = [
                "assets",
                resolved.pack.id.uuidString.lowercased(),
                filename
            ].joined(separator: "/")
            let storedAsset = StoredAsset(
                relativePath: relativePath,
                format: currentValidation.format,
                sha256: currentValidation.digest.sha256,
                byteCount: currentValidation.digest.byteCount,
                pixelWidth: currentValidation.pixelWidth,
                pixelHeight: currentValidation.pixelHeight,
                frameCount: currentValidation.frameCount
            )
            installedItems.append(
                LibraryEmoji(
                    id: candidate.id,
                    shortcode: candidate.shortcode,
                    aliases: candidate.aliases,
                    displayName: candidate.displayName,
                    tags: candidate.tags,
                    category: candidate.category,
                    order: candidate.order >= 0 ? candidate.order : candidateIndex,
                    sourceFilename: candidate.sourceFilename,
                    payload: .asset(storedAsset)
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
        try cleanupUnreferencedAssets(in: library)
        return installedPack
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
        category: String?
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
        try cleanupUnreferencedAssets(in: library)
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
        try cleanupUnreferencedAssets(in: library)
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
        try cleanupUnreferencedAssets(in: library)
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
        try fileManager.createDirectory(
            at: exportedAssetsURL,
            withIntermediateDirectories: false,
            attributes: [.posixPermissions: 0o700]
        )
        var portableItems: [PortablePackEmoji] = []
        for item in pack.items.sorted(by: { $0.order < $1.order }) {
            guard item.payload.kind == .asset, let asset = item.payload.asset else {
                throw LibraryStoreError.cannotExportUnicodeItem(item.id)
            }
            let sourceAssetURL = try assetURL(for: asset)
            let currentValidation = try validator.validate(fileAt: sourceAssetURL)
            guard currentValidation.digest.sha256 == asset.sha256,
                  currentValidation.digest.byteCount == asset.byteCount,
                  currentValidation.format == asset.format else {
                throw LibraryStoreError.storedAssetChanged(asset.relativePath)
            }

            let filename = "\(item.shortcode.rawValue).\(asset.format.preferredFilenameExtension)"
            let exportedRelativePath = "emoji/\(filename)"
            let exportedURL = exportedAssetsURL.appendingPathComponent(
                filename,
                isDirectory: false
            )
            try fileManager.copyItem(at: sourceAssetURL, to: exportedURL)
            try fileManager.setAttributes(
                [.posixPermissions: 0o600],
                ofItemAtPath: exportedURL.path
            )
            guard try validator.validate(fileAt: exportedURL) == currentValidation else {
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
        in library: MojiPondLibrary
    ) throws {
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
    case itemNotFound(UUID)
    case invalidPackIndex(Int)
    case duplicateItemClaims
    case shortcodeCollision(Shortcode, existingItemID: UUID)
    case assetDirectoryAlreadyExists
    case sourceChanged(URL)
    case copyVerificationFailed(String)
    case storedAssetChanged(String)
    case cannotEnumerateAssets
    case exportDestinationAlreadyExists
    case unsafeExportDestination
    case cannotExportUnicodeItem(UUID)

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
        case let .itemNotFound(id):
            "Emoji \(id) was not found."
        case let .invalidPackIndex(index):
            "Pack index \(index) is out of bounds."
        case .duplicateItemClaims:
            "An emoji shortcode and its aliases must be unique."
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
        case let .cannotExportUnicodeItem(id):
            "Emoji \(id) is Unicode-only and cannot be exported as an asset pack."
        }
    }
}
