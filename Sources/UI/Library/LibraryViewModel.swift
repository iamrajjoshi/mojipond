import AppKit
import Combine
import Foundation

protocol LibraryImportPreparing: Sendable {
    func prepare(
        _ request: ImportRequest,
        against library: MojiPondLibrary,
        reservedShortcodeOwners: [ReservedShortcodeOwner]
    ) async throws -> ImportPreparation
}

extension ImportOrchestrator: LibraryImportPreparing {}

private enum LibraryPasteboardSource: Sendable {
    case ready(PasteboardItemPayload)
    case managed(MediaEmojiContent, rootURL: URL)
}

@MainActor
final class LibraryViewModel: ObservableObject {
    typealias MutationCallback = @MainActor (MojiPondLibrary) -> Void
    typealias UsageMutationCallback = @MainActor () -> Void
    typealias BuiltInPackLoader = @Sendable () throws -> EmojiCatalogPack

    @Published private(set) var loadState: LibraryLoadState = .idle
    @Published private(set) var library = MojiPondLibrary()
    @Published private(set) var builtInPack: EmojiCatalogPack?
    @Published private(set) var usageSnapshot = EmojiUsageSnapshot()
    @Published var scope: LibraryScope = .all
    @Published var searchText = ""
    @Published var categoryFilter: String?
    @Published var contentFilter: LibraryContentFilter = .all
    @Published var layout: LibraryLayout = .grid
    @Published private(set) var isPreparingImport = false
    @Published private(set) var isInstallingImport = false
    @Published private(set) var importSession: LibraryImportSession?
    @Published private(set) var conflictChoices: [UUID: LibraryConflictChoice] = [:]
    @Published private(set) var conflictRenameValues: [UUID: String] = [:]
    @Published var pendingRemoval: LibraryRemovalTarget?
    @Published var notice: LibraryNotice?
    @Published private(set) var undoMessage: String?
    let paths: ApplicationPaths
    let thumbnailService: any LibraryThumbnailServing

    private let store: LibraryStore
    private let importer: any LibraryImportPreparing
    private let builtInLoader: BuiltInPackLoader
    private let onMutation: MutationCallback
    private let pasteboard: any PasteboardAccessing
    private let usageStore: (any EmojiUsageStore)?
    private let onUsageMutation: UsageMutationCallback
    private var preparation: ImportPreparation?
    private var importTask: Task<Void, Never>?
    private var importOperationID: UUID?
    private var undoMutation: UndoMutation?

    init(
        store: LibraryStore,
        paths: ApplicationPaths,
        importer: (any LibraryImportPreparing)? = nil,
        builtInLoader: @escaping BuiltInPackLoader = {
            try BuiltInRuntimeCatalogLoader().loadPack()
        },
        thumbnailService: (any LibraryThumbnailServing)? = nil,
        pasteboard: any PasteboardAccessing = MacPasteboardAccess(),
        usageStore: (any EmojiUsageStore)? = nil,
        onMutation: @escaping MutationCallback = { _ in },
        onUsageMutation: @escaping UsageMutationCallback = {}
    ) {
        self.store = store
        self.paths = paths
        self.importer = importer ?? ImportOrchestrator(
            temporaryRootURL: paths.importStagingRoot
        )
        self.builtInLoader = builtInLoader
        self.thumbnailService =
            thumbnailService ?? LibraryThumbnailPipeline(
                rootURL: paths.cachesRoot.appendingPathComponent(
                    "Library Thumbnails",
                    isDirectory: true
                )
            )
        self.pasteboard = pasteboard
        self.usageStore = usageStore
        self.onMutation = onMutation
        self.onUsageMutation = onUsageMutation
    }

    static func live(
        onMutation: @escaping MutationCallback = { _ in }
    ) -> LibraryViewModel {
        do {
            let paths = try ApplicationPaths.live()
            let builtInPack = try BuiltInRuntimeCatalogLoader().loadPack()
            return LibraryViewModel(
                store: LibraryStore(
                    rootURL: paths.libraryRoot,
                    reservedShortcodes:
                        BuiltInShortcodeReservations.shortcodes(
                            in: builtInPack
                        )
                ),
                paths: paths,
                builtInLoader: { builtInPack },
                onMutation: onMutation
            )
        } catch {
            let fallbackBase = FileManager.default.temporaryDirectory
                .appendingPathComponent("MojiPond-Unavailable", isDirectory: true)
            let paths = ApplicationPaths(
                applicationSupportBase: fallbackBase,
                cachesBase: fallbackBase
            )
            let model = LibraryViewModel(
                store: LibraryStore(rootURL: paths.libraryRoot),
                paths: paths,
                builtInLoader: { throw error },
                onMutation: onMutation
            )
            model.loadState = .failed(error.localizedDescription)
            return model
        }
    }

    deinit {
        importTask?.cancel()
    }

    var packs: [EmojiPack] {
        library.packs.sorted {
            if $0.priority != $1.priority {
                return $0.priority < $1.priority
            }
            return $0.name.localizedStandardCompare($1.name) == .orderedAscending
        }
    }

    var selectedPack: EmojiPack? {
        guard case let .pack(id) = scope else {
            return nil
        }
        return library.packs.first(where: { $0.id == id })
    }

    var allDisplayItems: [LibraryDisplayItem] {
        builtInDisplayItems + customDisplayItems
    }

    var personalAliasCount: Int {
        usageSnapshot.customAliasesByItemID.values.reduce(0) {
            $0 + $1.count
        }
    }

    var visibleItems: [LibraryDisplayItem] {
        let scoped = allDisplayItems.filter { item in
            switch scope {
            case .all:
                true
            case .favorites:
                isFavorite(item)
            case .aliases:
                true
            case .builtIn:
                item.origin == .builtIn
            case .custom:
                if case .custom = item.origin {
                    true
                } else {
                    false
                }
            case let .pack(packID):
                item.origin == .custom(packID: packID)
            }
        }
        let categoryFiltered = scoped.filter { item in
            categoryFilter == nil || item.category == categoryFilter
        }
        let contentFiltered = categoryFiltered.filter { item in
            switch contentFilter {
            case .all:
                true
            case .unicode:
                item.unicode != nil
            case .images:
                item.assetURL != nil && !item.isAnimated
            case .animated:
                item.isAnimated
            }
        }
        let query = Self.normalizedSearch(searchText)
        guard !query.isEmpty else {
            return contentFiltered
        }
        return contentFiltered.filter { item in
            var values = [
                item.shortcode,
                item.displayName,
                item.category,
                item.packName
            ]
            values.append(contentsOf: item.aliases)
            values.append(contentsOf: customAliases(for: item))
            values.append(contentsOf: item.tags)
            if let sourceFilename = item.sourceFilename {
                values.append((sourceFilename as NSString).lastPathComponent)
            }
            return values.contains {
                Self.normalizedSearch($0).contains(query)
            }
        }
    }

    var availableCategories: [String] {
        let categories = allDisplayItems.compactMap { item -> String? in
            switch scope {
            case .all:
                return item.category
            case .favorites:
                return isFavorite(item) ? item.category : nil
            case .aliases:
                return item.category
            case .builtIn:
                return item.origin == .builtIn ? item.category : nil
            case .custom:
                if case .custom = item.origin {
                    return item.category
                }
                return nil
            case let .pack(packID):
                return item.origin == .custom(packID: packID) ? item.category : nil
            }
        }
        return Array(Set(categories)).sorted {
            $0.localizedStandardCompare($1) == .orderedAscending
        }
    }

    var selectedScopeTitle: String {
        switch scope {
        case .all:
            "All Emoji"
        case .favorites:
            "Favorites"
        case .aliases:
            "Aliases"
        case .builtIn:
            builtInPack?.name ?? "Built-in Emoji"
        case .custom:
            "Custom Emoji"
        case .pack:
            selectedPack?.name ?? "Pack"
        }
    }

    var selectedScopeSubtitle: String {
        switch scope {
        case .all:
            let sourceCount = packs.count + 1
            let sourceNoun = sourceCount == 1 ? "source" : "sources"
            return "\(allDisplayItems.count.formatted()) emoji across \(sourceCount) \(sourceNoun)"
        case .favorites:
            return "\(usageSnapshot.favoriteItemIDs.count.formatted()) favorite emoji"
        case .aliases:
            let count = personalAliasCount
            let noun = count == 1 ? "personal alias" : "personal aliases"
            return count == 0
                ? "Choose an emoji to add an alias"
                : "\(count.formatted()) \(noun) · Choose an emoji to edit"
        case .builtIn:
            return builtInPack?.packDescription
                ?? "Unicode emoji and familiar GitHub-style aliases"
        case .custom:
            let packNoun = packs.count == 1 ? "pack" : "packs"
            return "\(customDisplayItems.count.formatted()) emoji in \(packs.count) installed \(packNoun)"
        case .pack:
            guard let pack = selectedPack else {
                return "This pack is no longer installed."
            }
            let state = pack.isEnabled ? "Enabled" : "Disabled"
            return "\(pack.items.count.formatted()) emoji · \(state) · \(sourceSummary(for: pack))"
        }
    }

    var unresolvedConflictCount: Int {
        guard let session = importSession else {
            return 0
        }
        return session.preview.collisions.reduce(into: 0) { count, collision in
            guard let choice = conflictChoices[collision.id] else {
                count += 1
                return
            }
            if choice == .renameIncoming {
                let normalized = Shortcode.normalizedString(
                    from: conflictRenameValues[collision.id, default: ""]
                )
                if Shortcode(rawValue: normalized) == nil {
                    count += 1
                }
            }
        }
    }

    var canInstallImport: Bool {
        importSession != nil
            && importSession?.preview.items.isEmpty == false
            && unresolvedConflictCount == 0
            && !isInstallingImport
            && !isPreparingImport
    }

    func reload() async {
        loadState = .loading
        var messages: [String] = []
        var loadedAny = false

        do {
            let snapshot = try await store.snapshot()
            library = snapshot
            await reconcileThumbnailCache(with: snapshot)
            loadedAny = true
        } catch {
            library = MojiPondLibrary()
            messages.append("Custom packs: \(error.localizedDescription)")
        }

        do {
            builtInPack = try builtInLoader()
            loadedAny = true
        } catch {
            builtInPack = nil
            messages.append("Built-in emoji: \(error.localizedDescription)")
        }

        if let usageStore {
            do {
                usageSnapshot = try await usageStore.snapshot()
            } catch {
                messages.append("Favorites and recents: \(error.localizedDescription)")
            }
        }

        if messages.isEmpty {
            loadState = .loaded
        } else if loadedAny {
            loadState = .partial(messages.joined(separator: "\n"))
        } else {
            loadState = .failed(messages.joined(separator: "\n"))
        }
        repairSelection()
        repairCategoryFilter()
    }

    func setPackEnabled(_ packID: UUID, isEnabled: Bool) async {
        guard let pack = library.packs.first(where: { $0.id == packID }),
              pack.isEnabled != isEnabled else {
            return
        }
        do {
            try await store.setPackEnabled(packID, isEnabled: isEnabled)
            try await finishMutation(
                message: isEnabled ? "Enabled \(pack.name)." : "Disabled \(pack.name).",
                undo: .setEnabled(packID: packID, isEnabled: pack.isEnabled)
            )
        } catch {
            presentError("Couldn’t update pack", error)
        }
    }

    func movePack(_ packID: UUID, by offset: Int) async {
        guard let sourceIndex = packs.firstIndex(where: { $0.id == packID }) else {
            return
        }
        let destination = sourceIndex + offset
        guard packs.indices.contains(destination) else {
            return
        }
        await movePack(
            packID,
            from: sourceIndex,
            to: destination
        )
    }

    func movePack(_ packID: UUID, toPack destinationPackID: UUID) async {
        guard
            packID != destinationPackID,
            let sourceIndex = packs.firstIndex(where: { $0.id == packID }),
            let destination = packs.firstIndex(where: {
                $0.id == destinationPackID
            })
        else {
            return
        }
        await movePack(
            packID,
            from: sourceIndex,
            to: destination
        )
    }

    private func movePack(
        _ packID: UUID,
        from sourceIndex: Int,
        to destination: Int
    ) async {
        do {
            try await store.movePack(packID, to: destination)
            try await finishMutation(
                message: "Reordered packs.",
                undo: .move(packID: packID, destination: sourceIndex)
            )
        } catch {
            presentError("Couldn’t reorder pack", error)
        }
    }

    func requestRemovePack(_ pack: EmojiPack) {
        pendingRemoval = LibraryRemovalTarget(
            kind: .pack(pack.id),
            title: "Remove “\(pack.name)”?",
            message: "This removes \(pack.items.count.formatted()) emoji and their managed files. This cannot be undone."
        )
    }

    func requestRemoveItem(packID: UUID, item: LibraryEmoji) {
        pendingRemoval = LibraryRemovalTarget(
            kind: .item(packID: packID, itemID: item.id),
            title: "Remove :\(item.shortcode.rawValue):?",
            message: "The emoji and its unreferenced managed asset will be removed. This cannot be undone."
        )
    }

    func confirmRemoval() async {
        guard let target = pendingRemoval else {
            return
        }
        pendingRemoval = nil
        do {
            switch target.kind {
            case let .pack(packID):
                try await store.removePack(packID)
            case let .item(packID, itemID):
                _ = try await store.removeItem(packID: packID, itemID: itemID)
            }
            try await finishMutation(message: "Removed from the library.", undo: nil)
        } catch {
            presentError(target.failureTitle, error)
        }
    }

    func updateItem(_ draft: LibraryItemDraft) async -> Bool {
        do {
            let shortcode = try Self.shortcode(from: draft.shortcode)
            let aliases = try Self.shortcodes(from: draft.aliases)
            try validateClaimsAgainstReservations(
                [shortcode] + aliases,
                excludingRuntimeItemID: draft.itemID.uuidString
            )
            let additionalReservedShortcodes = Set(
                effectiveReservedShortcodeOwners(
                    excludingRuntimeItemID: draft.itemID.uuidString
                ).map(\.shortcode)
            )
            let tags = Self.commaSeparatedValues(draft.tags)
            _ = try await store.updateItemMetadata(
                packID: draft.packID,
                itemID: draft.itemID,
                shortcode: shortcode,
                aliases: aliases,
                displayName: Self.nilIfBlank(draft.displayName),
                tags: tags,
                category: Self.nilIfBlank(draft.category),
                additionalReservedShortcodes:
                    additionalReservedShortcodes
            )
            try await finishMutation(message: "Saved :\(shortcode.rawValue):.", undo: nil)
            return true
        } catch {
            presentError("Couldn’t save emoji", error)
            return false
        }
    }

    func replaceItemAsset(
        packID: UUID,
        itemID: UUID,
        sourceURL: URL
    ) async -> Bool {
        do {
            _ = try await store.replaceItemAsset(
                packID: packID,
                itemID: itemID,
                with: sourceURL
            )
            try await finishMutation(message: "Replaced the emoji file.", undo: nil)
            return true
        } catch {
            presentError("Couldn’t replace file", error)
            return false
        }
    }

    func prepareImport(
        _ request: ImportRequest,
        destination: LibraryImportDestination = .newPack
    ) {
        if Self.requiresNetworkAccess(request) {
            notice = LibraryNotice(
                kind: .warning,
                title: "Use a local ZIP",
                message: "Network imports are not available in the Library."
            )
            return
        }
        guard builtInPack != nil else {
            notice = LibraryNotice(
                kind: .warning,
                title: "Built-in emoji unavailable",
                message:
                    "MojiPond cannot safely check shortcode conflicts until the built-in catalog loads."
            )
            return
        }

        importTask?.cancel()
        let operationID = UUID()
        importOperationID = operationID
        isPreparingImport = true
        notice = nil
        let importer = self.importer
        let store = self.store
        let stagingRoot = paths.importStagingRoot
        let reservedShortcodeOwners =
            effectiveReservedShortcodeOwners(
                excludingPackID: destination.replacedPackID
            )
        importTask = Task { [weak self] in
            do {
                try FileManager.default.createDirectory(
                    at: stagingRoot,
                    withIntermediateDirectories: true,
                    attributes: [.posixPermissions: 0o700]
                )
                var snapshot = try await store.snapshot()
                if case let .replace(packID) = destination {
                    snapshot.packs.removeAll { $0.id == packID }
                }
                let prepared = try await importer.prepare(
                    request,
                    against: snapshot,
                    reservedShortcodeOwners: reservedShortcodeOwners
                )
                if Task.isCancelled {
                    try? await prepared.discard()
                    throw CancellationError()
                }
                guard let self else {
                    try? await prepared.discard()
                    return
                }
                guard self.importOperationID == operationID else {
                    try? await prepared.discard()
                    return
                }
                self.preparation = prepared
                self.importSession = LibraryImportSession(
                    preview: prepared.preview,
                    duplicateContent: prepared.duplicateContent,
                    destination: destination
                )
                self.conflictChoices = [:]
                self.conflictRenameValues = Dictionary(
                    uniqueKeysWithValues: prepared.preview.collisions.map {
                        ($0.id, Self.defaultRename(for: $0))
                    }
                )
                self.isPreparingImport = false
                self.importTask = nil
                self.importOperationID = nil
            } catch is CancellationError {
                guard self?.importOperationID == operationID else {
                    return
                }
                self?.isPreparingImport = false
                self?.importTask = nil
                self?.importOperationID = nil
            } catch {
                guard self?.importOperationID == operationID else {
                    return
                }
                self?.isPreparingImport = false
                self?.importTask = nil
                self?.importOperationID = nil
                self?.presentError("Couldn’t prepare import", error)
            }
        }
    }

    @discardableResult
    func prepareDroppedURLs(_ urls: [URL]) -> Bool {
        guard urls.count == 1, let url = urls.first, url.isFileURL else {
            notice = LibraryNotice(
                kind: .warning,
                title: "Nothing to import",
                message: "Drop one local ZIP archive."
            )
            return false
        }
        let values = try? url.resourceValues(forKeys: [.isDirectoryKey])
        guard
            values?.isDirectory != true,
            url.pathExtension.lowercased() == "zip"
        else {
            notice = LibraryNotice(
                kind: .warning,
                title: "ZIP archive required",
                message: "Choose a local ZIP archive."
            )
            return false
        }
        prepareImport(.zipArchive(url))
        return true
    }

    func cancelImport() {
        importOperationID = nil
        importTask?.cancel()
        importTask = nil
        isPreparingImport = false
    }

    func discardImport() async {
        importOperationID = nil
        importTask?.cancel()
        importTask = nil
        isPreparingImport = false
        let prepared = preparation
        let thumbnailSourceURLs =
            prepared?.preview.preparedPack.items.compactMap(
                \.assetSourceURL
            ) ?? []
        clearImportState()
        do {
            try await prepared?.discard()
        } catch {
            presentError("Couldn’t discard import", error)
        }
        for sourceURL in thumbnailSourceURLs {
            try? await thumbnailService.invalidate(
                sourceURL: sourceURL
            )
        }
    }

    func setConflictChoice(
        _ choice: LibraryConflictChoice?,
        for collisionID: UUID
    ) {
        if choice == .replaceExisting,
           let collision = importSession?.preview.collisions.first(
               where: { $0.id == collisionID }
           ),
           case .reserved = collision.existing {
            conflictChoices.removeValue(forKey: collisionID)
            notice = LibraryNotice(
                kind: .warning,
                title: "Protected shortcode",
                message: "Keep the protected name or rename the incoming emoji."
            )
            return
        }
        if let choice {
            conflictChoices[collisionID] = choice
        } else {
            conflictChoices.removeValue(forKey: collisionID)
        }
    }

    func setConflictRename(_ value: String, for collisionID: UUID) {
        conflictRenameValues[collisionID] = value
    }

    func applyChoiceToAll(_ choice: LibraryConflictChoice) {
        guard let session = importSession else {
            return
        }
        for collision in session.preview.collisions {
            if choice == .replaceExisting,
               case .reserved = collision.existing {
                continue
            }
            if choice == .dropIncomingAlias,
               case .primary = collision.incomingClaim {
                continue
            }
            if choice == .renameIncoming {
                continue
            }
            conflictChoices[collision.id] = choice
        }
    }

    func installPreparedImport() async {
        guard let session = importSession, let preparation else {
            return
        }
        guard builtInPack != nil else {
            notice = LibraryNotice(
                kind: .error,
                title: "Built-in emoji unavailable",
                message:
                    "Reload the library before installing so MojiPond can revalidate protected shortcodes."
            )
            return
        }
        guard canInstallImport else {
            notice = LibraryNotice(
                kind: .warning,
                title: "Resolve every conflict",
                message: "Choose an action for each shortcode conflict before installing."
            )
            return
        }
        do {
            isInstallingImport = true
            let currentReservedShortcodeOwners =
                effectiveReservedShortcodeOwners(
                    excludingPackID: session.destination.replacedPackID
                )
            var decisions: [UUID: CollisionDecision] = [:]
            for collision in session.preview.collisions {
                guard let choice = conflictChoices[collision.id] else {
                    throw LibraryViewModelError.unresolvedConflict
                }
                switch choice {
                case .keepExisting:
                    decisions[collision.id] = .skipIncomingItem
                case .replaceExisting:
                    decisions[collision.id] = .replaceExistingItem
                case .dropIncomingAlias:
                    decisions[collision.id] = .dropIncomingAlias
                case .renameIncoming:
                    decisions[collision.id] = .renameIncomingClaim(
                        try Self.shortcode(
                            from: conflictRenameValues[collision.id, default: ""]
                        )
                    )
                }
            }
            let installed: EmojiPack
            switch session.destination {
            case .newPack:
                installed = try await preparation.install(
                    into: store,
                    decisions: decisions,
                    reservedShortcodeOwners:
                        currentReservedShortcodeOwners
                )
            case let .replace(packID):
                installed = try await preparation.replacePackContents(
                    in: store,
                    packID: packID,
                    decisions: decisions,
                    reservedShortcodeOwners:
                        currentReservedShortcodeOwners
                )
            }
            clearImportState()
            try await finishMutation(
                message: successMessage(for: session.destination, pack: installed),
                undo: nil
            )
            scope = .pack(installed.id)
        } catch {
            isInstallingImport = false
            presentError("Couldn’t install pack", error)
        }
    }

    func exportPack(_ packID: UUID, to destinationURL: URL) async -> Bool {
        do {
            let exported = try await store.exportPortablePack(
                packID,
                to: destinationURL
            )
            notice = LibraryNotice(
                kind: .information,
                title: "Pack exported",
                message: exported.path
            )
            return true
        } catch {
            presentError("Couldn’t export pack", error)
            return false
        }
    }

    func revealURL(for pack: EmojiPack) -> URL {
        paths.libraryRoot
            .appendingPathComponent("assets", isDirectory: true)
            .appendingPathComponent(pack.id.uuidString.lowercased(), isDirectory: true)
    }

    func item(packID: UUID, itemID: UUID) -> LibraryEmoji? {
        library.packs
            .first(where: { $0.id == packID })?
            .items
            .first(where: { $0.id == itemID })
    }

    func undoLastMutation() async {
        guard let undoMutation else {
            return
        }
        self.undoMutation = nil
        undoMessage = nil
        do {
            switch undoMutation {
            case let .setEnabled(packID, isEnabled):
                try await store.setPackEnabled(packID, isEnabled: isEnabled)
            case let .move(packID, destination):
                try await store.movePack(packID, to: destination)
            }
            try await finishMutation(message: "Undid the last change.", undo: nil)
        } catch {
            presentError("Couldn’t undo change", error)
        }
    }

    func dismissUndo() {
        undoMutation = nil
        undoMessage = nil
    }

    func dismissNotice() {
        notice = nil
    }

    func copyToClipboard(_ item: LibraryDisplayItem) async {
        do {
            let source = try pasteboardSource(for: item)
            let payload: PasteboardItemPayload
            switch source {
            case let .ready(value):
                payload = value
            case let .managed(media, rootURL):
                payload = try await Task.detached(
                    priority: .userInitiated
                ) {
                    try RuntimeManagedMediaResolver()
                        .resolve(media, beneath: rootURL)
                        .pasteboardPayload
                }.value
            }
            try Task.checkCancellation()
            guard pasteboard.replaceContents(with: [payload]) else {
                throw LibraryCopyError.pasteboardWriteFailed
            }
            notice = LibraryNotice(
                kind: .information,
                title: "Copied \(item.displayName)",
                message: item.unicode == nil
                    ? "Original image copied to the clipboard."
                    : "Unicode emoji copied to the clipboard."
            )
        } catch is CancellationError {
            return
        } catch {
            presentError("Couldn’t copy emoji", error)
        }
    }

    func isFavorite(_ item: LibraryDisplayItem) -> Bool {
        usageSnapshot.isFavorite(runtimeItemID(for: item))
    }

    func toggleFavorite(_ item: LibraryDisplayItem) async {
        guard let usageStore else {
            presentError(
                "Couldn’t change favorite",
                LibraryUsageError.storeUnavailable
            )
            return
        }
        do {
            try await usageStore.setFavorite(
                !isFavorite(item),
                itemID: runtimeItemID(for: item)
            )
            usageSnapshot = try await usageStore.snapshot()
            onUsageMutation()
            notice = LibraryNotice(
                kind: .information,
                title: isFavorite(item)
                    ? "Added to Favorites"
                    : "Removed from Favorites",
                message: item.displayName
            )
        } catch {
            presentError("Couldn’t change favorite", error)
        }
    }

    func availableSkinTones(
        for item: LibraryDisplayItem
    ) -> [EmojiSkinTone] {
        guard
            item.origin == .builtIn,
            let builtIn = builtInItem(for: item),
            case let .unicode(content) = builtIn.content
        else {
            return []
        }
        return EmojiSkinTone.allCases.filter { tone in
            content.skinToneVariants.contains {
                $0.skinTone == tone
            }
        }
    }

    func preferredSkinTone(
        for item: LibraryDisplayItem
    ) -> EmojiSkinTone? {
        usageSnapshot.preferredSkinToneByItemID[runtimeItemID(for: item)]
    }

    func customAliases(
        for item: LibraryDisplayItem
    ) -> [String] {
        usageSnapshot.customAliasesByItemID[
            runtimeItemID(for: item),
            default: []
        ]
    }

    func setCustomAliases(
        _ value: String,
        for item: LibraryDisplayItem
    ) async {
        guard let usageStore else {
            presentError(
                "Couldn’t save aliases",
                LibraryUsageError.storeUnavailable
            )
            return
        }
        let aliases = Self.commaSeparatedValues(value).map {
            EmojiAliasSyntax.normalizedToken($0)
        }
        guard aliases.allSatisfy(EmojiAliasSyntax.isValidToken) else {
            presentError(
                "Couldn’t save aliases",
                LibraryUsageError.invalidAlias
            )
            return
        }
        do {
            try validateCustomAliases(
                aliases,
                for: item
            )
            try await usageStore.setCustomAliases(
                aliases,
                itemID: runtimeItemID(for: item)
            )
            usageSnapshot = try await usageStore.snapshot()
            onUsageMutation()
            notice = LibraryNotice(
                kind: .information,
                title: "Aliases updated",
                message: item.displayName
            )
        } catch {
            presentError("Couldn’t save aliases", error)
        }
    }

    func setPreferredSkinTone(
        _ skinTone: EmojiSkinTone?,
        for item: LibraryDisplayItem
    ) async {
        guard let usageStore else {
            presentError(
                "Couldn’t change skin tone",
                LibraryUsageError.storeUnavailable
            )
            return
        }
        do {
            try await usageStore.setPreferredSkinTone(
                skinTone,
                itemID: runtimeItemID(for: item)
            )
            usageSnapshot = try await usageStore.snapshot()
            onUsageMutation()
            notice = LibraryNotice(
                kind: .information,
                title: "Skin tone preference updated",
                message: item.displayName
            )
        } catch {
            presentError("Couldn’t change skin tone", error)
        }
    }

    func cancelRemoval() {
        pendingRemoval = nil
    }

    func sourceSummary(for pack: EmojiPack) -> String {
        switch pack.source.kind {
        case .individualFiles:
            "Individual files"
        case .folder:
            pack.source.displayLocation.map { "Folder · \($0)" } ?? "Folder"
        case .slackManifest:
            pack.source.displayLocation.map { "Slack export · \($0)" } ?? "Slack export"
        case .zipArchive:
            pack.source.displayLocation.map { "ZIP · \($0)" } ?? "ZIP archive"
        case .github:
            if let github = pack.source.github {
                "GitHub · \(github.owner)/\(github.repository) @ \(github.ref)"
            } else {
                "GitHub"
            }
        case .builtIn:
            "Bundled with MojiPond"
        }
    }

    func prepareReplacement(
        fromZIP url: URL,
        for packID: UUID
    ) {
        guard let pack = library.packs.first(where: { $0.id == packID }) else {
            return
        }
        prepareImport(
            .zipArchive(url, packName: pack.name),
            destination: .replace(packID: packID)
        )
    }

    private var builtInDisplayItems: [LibraryDisplayItem] {
        guard let builtInPack else {
            return []
        }
        return builtInPack.items.enumerated().map { index, item in
            let unicode: String?
            switch item.content {
            case let .unicode(content):
                unicode = content.value
            case .media:
                unicode = nil
            }
            return LibraryDisplayItem(
                id: "builtin-\(item.id)",
                origin: .builtIn,
                packName: builtInPack.name,
                packEnabled: builtInPack.isEnabled,
                shortcode: item.shortcode.rawValue,
                aliases: item.aliases,
                displayName: item.name,
                tags: item.keywords,
                sourceFilename: nil,
                category: item.category,
                unicode: unicode,
                assetURL: nil,
                format: nil,
                isAnimated: item.content.isAnimated,
                order: item.order ?? index
            )
        }
    }

    private var customDisplayItems: [LibraryDisplayItem] {
        packs.flatMap { pack in
            pack.items.map { item in
                let asset = item.payload.asset
                let assetURL = asset.map {
                    paths.libraryRoot.appendingPathComponent($0.relativePath)
                }
                return LibraryDisplayItem(
                    id: "custom-\(item.id.uuidString)",
                    origin: .custom(packID: pack.id),
                    packName: pack.name,
                    packEnabled: pack.isEnabled,
                    shortcode: item.shortcode.rawValue,
                    aliases: item.aliases.map(\.rawValue),
                    displayName: item.displayName ?? item.shortcode.rawValue,
                    tags: item.tags,
                    sourceFilename: item.sourceFilename,
                    category: item.category ?? "Custom",
                    unicode: item.payload.unicode,
                    assetURL: assetURL,
                    format: asset?.format,
                    isAnimated: (asset?.frameCount ?? 1) > 1,
                    order: item.order
                )
            }
        }
    }

    private func pasteboardSource(
        for item: LibraryDisplayItem
    ) throws -> LibraryPasteboardSource {
        if let unicode = item.unicode {
            return .ready(.text(unicode))
        }
        guard
            case let .custom(packID) = item.origin,
            let pack = library.packs.first(where: { $0.id == packID }),
            let libraryItem = pack.items.first(where: {
                "custom-\($0.id.uuidString)" == item.id
            }),
            let asset = libraryItem.payload.asset
        else {
            throw LibraryCopyError.itemUnavailable
        }
        let media = MediaEmojiContent(
            mediaType: asset.format,
            relativePath: asset.relativePath,
            originalFilename: libraryItem.sourceFilename,
            contentHash: asset.sha256,
            isAnimated: asset.frameCount > 1
        )
        return .managed(media, rootURL: paths.libraryRoot)
    }

    private func runtimeItemID(
        for item: LibraryDisplayItem
    ) -> EmojiItem.ID {
        switch item.origin {
        case .builtIn:
            String(item.id.dropFirst("builtin-".count))
        case .custom:
            String(item.id.dropFirst("custom-".count))
        }
    }

    private func builtInItem(
        for item: LibraryDisplayItem
    ) -> EmojiItem? {
        builtInPack?.items.first {
            $0.id == runtimeItemID(for: item)
        }
    }

    private func finishMutation(
        message: String,
        undo: UndoMutation?
    ) async throws {
        let snapshot = try await store.snapshot()
        library = snapshot
        await reconcileThumbnailCache(with: snapshot)
        onMutation(snapshot)
        undoMutation = undo
        undoMessage = undo == nil ? nil : message
        notice = LibraryNotice(
            kind: .information,
            title: message,
            message: ""
        )
        repairSelection()
        repairCategoryFilter()
    }

    private func successMessage(
        for destination: LibraryImportDestination,
        pack: EmojiPack
    ) -> String {
        switch destination {
        case .newPack:
            "Installed \(pack.name) with \(pack.items.count.formatted()) emoji."
        case .replace:
            "Updated \(pack.name) with \(pack.items.count.formatted()) reviewed emoji."
        }
    }

    private func repairSelection() {
        if case let .pack(id) = scope,
           !library.packs.contains(where: { $0.id == id }) {
            scope = .custom
        }
    }

    private func repairCategoryFilter() {
        if let categoryFilter,
           !availableCategories.contains(categoryFilter) {
            self.categoryFilter = nil
        }
    }

    private func clearImportState() {
        preparation = nil
        importSession = nil
        conflictChoices = [:]
        conflictRenameValues = [:]
        isPreparingImport = false
        isInstallingImport = false
    }

    private func reconcileThumbnailCache(
        with library: MojiPondLibrary
    ) async {
        let sourceURLs = Set(
            library.packs.flatMap(\.items).compactMap {
                $0.payload.asset
            }.map {
                paths.libraryRoot.appendingPathComponent(
                    $0.relativePath,
                    isDirectory: false
                )
            }
        )
        try? await thumbnailService.reconcile(
            retaining: sourceURLs
        )
    }

    private func effectiveReservedShortcodeOwners(
        excludingPackID: UUID? = nil,
        excludingRuntimeItemID: String? = nil
    ) -> [ReservedShortcodeOwner] {
        guard let builtInPack else {
            return []
        }

        let displayItems = allDisplayItems.filter { item in
            guard runtimeItemID(for: item) != excludingRuntimeItemID else {
                return false
            }
            if case let .custom(packID) = item.origin,
               packID == excludingPackID {
                return false
            }
            return true
        }
        let canonicalClaims = Set(
            displayItems.flatMap {
                [$0.shortcode] + $0.aliases
            }.map(EmojiAliasSyntax.normalizedToken)
        )
        var claimedShortcodes = Set<Shortcode>()
        var owners = BuiltInShortcodeReservations.owners(
            in: builtInPack
        ).sorted {
            if $0.shortcode != $1.shortcode {
                return $0.shortcode < $1.shortcode
            }
            if $0.isAlias != $1.isAlias {
                return !$0.isAlias
            }
            return $0.itemID < $1.itemID
        }.filter {
            claimedShortcodes.insert($0.shortcode).inserted
        }
        for item in displayItems.sorted(by: {
            runtimeItemID(for: $0) < runtimeItemID(for: $1)
        }) {
            let itemID = runtimeItemID(for: item)
            let packID = switch item.origin {
            case .builtIn:
                builtInPack.id
            case let .custom(packID):
                packID.uuidString.lowercased()
            }
            for alias in usageSnapshot.customAliasesByItemID[
                itemID,
                default: []
            ].sorted() {
                let normalizedAlias =
                    EmojiAliasSyntax.normalizedToken(alias)
                guard
                    !canonicalClaims.contains(normalizedAlias),
                    let shortcode = Shortcode(
                        rawValue: normalizedAlias
                    ),
                    claimedShortcodes.insert(shortcode).inserted
                else {
                    // Leading +/- aliases are searchable but cannot collide
                    // with the stricter imported shortcode namespace.
                    // Canonical/self duplicates already have a stronger owner.
                    continue
                }
                owners.append(
                    ReservedShortcodeOwner(
                        shortcode: shortcode,
                        itemID: itemID,
                        itemName: item.displayName,
                        packID: packID,
                        packName: item.packName,
                        isAlias: true,
                        source: .customAlias
                    )
                )
            }
        }
        return owners.sorted {
            if $0.shortcode != $1.shortcode {
                return $0.shortcode < $1.shortcode
            }
            if $0.source != $1.source {
                return $0.source == .builtIn
            }
            if $0.packID != $1.packID {
                return $0.packID < $1.packID
            }
            return $0.itemID < $1.itemID
        }
    }

    private func validateClaimsAgainstReservations(
        _ claims: [Shortcode],
        excludingRuntimeItemID: String? = nil
    ) throws {
        guard builtInPack != nil else {
            throw LibraryViewModelError.builtInCatalogUnavailable
        }
        let reserved = Set(
            effectiveReservedShortcodeOwners(
                excludingRuntimeItemID: excludingRuntimeItemID
            ).map(\.shortcode)
        )
        if let collision = Set(claims)
            .intersection(reserved)
            .sorted()
            .first {
            throw LibraryViewModelError.protectedShortcode(collision)
        }
    }

    private func validateCustomAliases(
        _ aliases: [String],
        for target: LibraryDisplayItem
    ) throws {
        guard builtInPack != nil else {
            throw LibraryViewModelError.builtInCatalogUnavailable
        }
        let targetID = runtimeItemID(for: target)
        let targetClaims = Set(
            ([target.shortcode] + target.aliases)
                .map(EmojiAliasSyntax.normalizedToken)
        )
        if let collision = aliases.first(where: {
            targetClaims.contains(
                EmojiAliasSyntax.normalizedToken($0)
            )
        }) {
            throw LibraryUsageError.aliasCollision(collision)
        }
        var claimed = Set<String>()
        for item in allDisplayItems
            where runtimeItemID(for: item) != targetID {
            claimed.insert(
                EmojiAliasSyntax.normalizedToken(item.shortcode)
            )
            for alias in item.aliases {
                claimed.insert(
                    EmojiAliasSyntax.normalizedToken(alias)
                )
            }
            for alias in usageSnapshot.customAliasesByItemID[
                runtimeItemID(for: item),
                default: []
            ] {
                claimed.insert(
                    EmojiAliasSyntax.normalizedToken(alias)
                )
            }
        }
        if let collision = aliases.first(where: {
            claimed.contains(EmojiAliasSyntax.normalizedToken($0))
        }) {
            throw LibraryUsageError.aliasCollision(collision)
        }
    }

    private func presentError(_ title: String, _ error: Error) {
        notice = LibraryNotice(
            kind: .error,
            title: title,
            message: error.localizedDescription
        )
    }

    private static func requiresNetworkAccess(_ request: ImportRequest) -> Bool {
        switch request {
        case .github:
            true
        case let .slackManifest(_, _, allowRemoteAssets):
            allowRemoteAssets
        case let .folder(_, _, allowRemoteSlackAssets):
            allowRemoteSlackAssets
        case .files, .zipArchive:
            false
        }
    }

    private static func defaultRename(for collision: ImportCollision) -> String {
        let suffix = collision.incomingCandidateID.uuidString
            .prefix(4)
            .lowercased()
        let base = collision.shortcode.rawValue
        let maximumBaseLength = max(1, Shortcode.maximumLength - suffix.count - 1)
        return "\(base.prefix(maximumBaseLength))_\(suffix)"
    }

    private static func shortcode(from value: String) throws -> Shortcode {
        let normalized = Shortcode.normalizedString(from: value)
        guard let shortcode = Shortcode(rawValue: normalized) else {
            throw ShortcodeError.cannotNormalize(value)
        }
        return shortcode
    }

    private static func shortcodes(from value: String) throws -> [Shortcode] {
        var seen = Set<Shortcode>()
        return try commaSeparatedValues(value).compactMap { token in
            let shortcode = try shortcode(from: token)
            return seen.insert(shortcode).inserted ? shortcode : nil
        }
    }

    private static func commaSeparatedValues(_ value: String) -> [String] {
        value
            .split(whereSeparator: { $0 == "," || $0 == "\n" })
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
    }

    private static func nilIfBlank(_ value: String) -> String? {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    private static func normalizedSearch(_ value: String) -> String {
        var trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.first == ":" {
            trimmed.removeFirst()
        }
        if trimmed.last == ":" {
            trimmed.removeLast()
        }
        return trimmed.folding(
            options: [.caseInsensitive, .diacriticInsensitive],
            locale: Locale(identifier: "en_US_POSIX")
        )
    }

    private enum UndoMutation {
        case setEnabled(packID: UUID, isEnabled: Bool)
        case move(packID: UUID, destination: Int)
    }
}

private extension LibraryImportDestination {
    var replacedPackID: UUID? {
        guard case let .replace(packID) = self else {
            return nil
        }
        return packID
    }
}

private enum LibraryCopyError: Error, LocalizedError {
    case itemUnavailable
    case pasteboardWriteFailed

    var errorDescription: String? {
        switch self {
        case .itemUnavailable:
            "The original emoji is no longer available."
        case .pasteboardWriteFailed:
            "The Mac clipboard did not accept the emoji."
        }
    }
}

private enum LibraryUsageError: Error, LocalizedError {
    case storeUnavailable
    case invalidAlias
    case aliasCollision(String)

    var errorDescription: String? {
        switch self {
        case .storeUnavailable:
            "Usage preferences are unavailable."
        case .invalidAlias:
            "Aliases must use 1–64 letters, numbers, underscores, plus signs, or hyphens."
        case let .aliasCollision(alias):
            "Alias \(alias) is already used by another emoji."
        }
    }
}

enum LibraryViewModelError: Error, Equatable, LocalizedError {
    case unresolvedConflict
    case builtInCatalogUnavailable
    case protectedShortcode(Shortcode)

    var errorDescription: String? {
        switch self {
        case .unresolvedConflict:
            "Every shortcode conflict needs a decision."
        case .builtInCatalogUnavailable:
            "The built-in emoji catalog is unavailable, so MojiPond cannot safely validate shortcode conflicts."
        case let .protectedShortcode(shortcode):
            "Shortcode \(shortcode.rawValue) is already protected by a built-in emoji or one of your aliases."
        }
    }
}
