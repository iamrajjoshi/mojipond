import AppKit
import Combine
import Foundation

protocol LibraryImportPreparing: Sendable {
    func prepare(
        _ request: ImportRequest,
        against library: MojiPondLibrary
    ) async throws -> ImportPreparation
}

extension ImportOrchestrator: LibraryImportPreparing {}

@MainActor
final class LibraryViewModel: ObservableObject {
    typealias MutationCallback = @MainActor (MojiPondLibrary) -> Void
    typealias BuiltInPackLoader = @Sendable () throws -> EmojiCatalogPack

    @Published private(set) var loadState: LibraryLoadState = .idle
    @Published private(set) var library = MojiPondLibrary()
    @Published private(set) var builtInPack: EmojiCatalogPack?
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

    private let store: LibraryStore
    private let importer: any LibraryImportPreparing
    private let builtInLoader: BuiltInPackLoader
    private let onMutation: MutationCallback
    private let pasteboard: any PasteboardAccessing
    private var preparation: ImportPreparation?
    private var importTask: Task<Void, Never>?
    private var undoMutation: UndoMutation?

    init(
        store: LibraryStore,
        paths: ApplicationPaths,
        importer: (any LibraryImportPreparing)? = nil,
        builtInLoader: @escaping BuiltInPackLoader = {
            try BuiltInRuntimeCatalogLoader().loadPack()
        },
        pasteboard: any PasteboardAccessing = MacPasteboardAccess(),
        onMutation: @escaping MutationCallback = { _ in }
    ) {
        self.store = store
        self.paths = paths
        self.importer = importer ?? ImportOrchestrator(
            temporaryRootURL: paths.importStagingRoot
        )
        self.builtInLoader = builtInLoader
        self.pasteboard = pasteboard
        self.onMutation = onMutation
    }

    static func live(
        onMutation: @escaping MutationCallback = { _ in }
    ) -> LibraryViewModel {
        do {
            let paths = try ApplicationPaths.live()
            return LibraryViewModel(
                store: LibraryStore(rootURL: paths.libraryRoot),
                paths: paths,
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

    var visibleItems: [LibraryDisplayItem] {
        let scoped = allDisplayItems.filter { item in
            switch scope {
            case .all:
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
            let values = [
                item.shortcode,
                item.displayName,
                item.category,
                item.packName
            ] + item.aliases + item.tags
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
            return "\(allDisplayItems.count.formatted()) emoji across \(packs.count + 1) sources"
        case .builtIn:
            return builtInPack?.packDescription
                ?? "Unicode emoji and familiar GitHub-style aliases"
        case .custom:
            return "\(customDisplayItems.count.formatted()) emoji in \(packs.count) installed packs"
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

    @discardableResult
    func createPack(_ draft: LibraryPackDraft) async -> Bool {
        do {
            let trimmedName = draft.name.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmedName.isEmpty else {
                throw LibraryViewModelError.emptyPackName
            }
            let id = UUID()
            let sourceURL: URL?
            if draft.sourceURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                sourceURL = nil
            } else {
                guard let candidate = URL(string: draft.sourceURL),
                      candidate.scheme?.lowercased() == "https" else {
                    throw LibraryViewModelError.invalidSourceURL
                }
                sourceURL = candidate
            }
            let manifest = PackManifestMetadata(
                packID: .local(id),
                name: trimmedName,
                version: Self.nilIfBlank(draft.version) ?? "1.0.0",
                author: Self.nilIfBlank(draft.author),
                description: Self.nilIfBlank(draft.description),
                sourceURL: sourceURL,
                license: Self.nilIfBlank(draft.license)
            )
            _ = try await store.createPack(id: id, manifest: manifest)
            try await finishMutation(
                message: "Created \(trimmedName).",
                undo: nil
            )
            scope = .pack(id)
            return true
        } catch {
            presentError("Couldn’t create pack", error)
            return false
        }
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
            presentError("Couldn’t remove item", error)
        }
    }

    func updateItem(_ draft: LibraryItemDraft) async -> Bool {
        do {
            let shortcode = try Self.shortcode(from: draft.shortcode)
            let aliases = try Self.shortcodes(from: draft.aliases)
            let tags = Self.commaSeparatedValues(draft.tags)
            _ = try await store.updateItemMetadata(
                packID: draft.packID,
                itemID: draft.itemID,
                shortcode: shortcode,
                aliases: aliases,
                displayName: Self.nilIfBlank(draft.displayName),
                tags: tags,
                category: Self.nilIfBlank(draft.category)
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
        networkAccessGranted: Bool = false,
        destination: LibraryImportDestination = .newPack
    ) {
        if Self.requiresNetworkAccess(request), !networkAccessGranted {
            notice = LibraryNotice(
                kind: .warning,
                title: "Network access not granted",
                message: "Turn on the explicit network option for this import, then try again."
            )
            return
        }

        importTask?.cancel()
        isPreparingImport = true
        notice = nil
        let importer = self.importer
        let store = self.store
        let stagingRoot = paths.importStagingRoot
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
                    against: snapshot
                )
                try Task.checkCancellation()
                guard let self else {
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
            } catch is CancellationError {
                self?.isPreparingImport = false
                self?.importTask = nil
            } catch {
                self?.isPreparingImport = false
                self?.importTask = nil
                self?.presentError("Couldn’t prepare import", error)
            }
        }
    }

    func prepareDroppedURLs(_ urls: [URL]) {
        let safeURLs = urls.filter(\.isFileURL)
        guard !safeURLs.isEmpty else {
            notice = LibraryNotice(
                kind: .warning,
                title: "Nothing to import",
                message: "Drop local image files, a folder, a ZIP archive, or emoji.json."
            )
            return
        }
        if safeURLs.count == 1, let url = safeURLs.first {
            let values = try? url.resourceValues(forKeys: [.isDirectoryKey])
            if values?.isDirectory == true {
                prepareImport(.folder(url))
                return
            }
            if url.pathExtension.lowercased() == "zip" {
                prepareImport(.zipArchive(url))
                return
            }
            if url.lastPathComponent.lowercased() == "emoji.json" {
                prepareImport(.slackManifest(url))
                return
            }
        }
        let defaultName = safeURLs.count == 1
            ? safeURLs[0].deletingPathExtension().lastPathComponent
            : "Imported Emoji"
        prepareImport(.files(safeURLs, packName: defaultName))
    }

    func cancelImport() {
        importTask?.cancel()
        importTask = nil
        isPreparingImport = false
    }

    func discardImport() async {
        importTask?.cancel()
        importTask = nil
        isPreparingImport = false
        let prepared = preparation
        clearImportState()
        do {
            try await prepared?.discard()
        } catch {
            presentError("Couldn’t discard import", error)
        }
    }

    func setConflictChoice(
        _ choice: LibraryConflictChoice?,
        for collisionID: UUID
    ) {
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
                    decisions: decisions
                )
            case let .append(packID):
                installed = try await preparation.append(
                    into: store,
                    packID: packID,
                    decisions: decisions
                )
            case let .replace(packID):
                installed = try await preparation.replacePackContents(
                    in: store,
                    packID: packID,
                    decisions: decisions
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

    func canMovePack(_ packID: UUID, by offset: Int) -> Bool {
        guard let source = packs.firstIndex(where: { $0.id == packID }) else {
            return false
        }
        return packs.indices.contains(source + offset)
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

    func showNotice(_ notice: LibraryNotice) {
        self.notice = notice
    }

    func copyToClipboard(_ item: LibraryDisplayItem) {
        do {
            let payload = try pasteboardPayload(for: item)
            guard pasteboard.replaceContents(with: [payload]) else {
                throw LibraryCopyError.pasteboardWriteFailed
            }
            notice = LibraryNotice(
                kind: .information,
                title: "Copied \(item.displayName)",
                message: item.unicode == nil
                    ? "Original image bytes are on the clipboard."
                    : "Unicode emoji is on the clipboard."
            )
        } catch {
            presentError("Couldn’t copy emoji", error)
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

    func prepareAddFiles(_ urls: [URL], to packID: UUID) {
        guard let pack = library.packs.first(where: { $0.id == packID }) else {
            return
        }
        prepareImport(
            .files(urls, packName: pack.name),
            destination: .append(packID: packID)
        )
    }

    func prepareReplacement(
        from urls: [URL],
        for packID: UUID,
        allowRemoteSlackAssets: Bool = false
    ) {
        guard let pack = library.packs.first(where: { $0.id == packID }),
              !urls.isEmpty else {
            return
        }
        let request: ImportRequest
        if urls.count == 1, let url = urls.first {
            let values = try? url.resourceValues(forKeys: [.isDirectoryKey])
            if values?.isDirectory == true {
                request = .folder(
                    url,
                    packName: pack.name,
                    allowRemoteSlackAssets: allowRemoteSlackAssets
                )
            } else if url.pathExtension.lowercased() == "zip" {
                request = .zipArchive(url, packName: pack.name)
            } else if url.lastPathComponent.lowercased() == "emoji.json" {
                request = .slackManifest(
                    url,
                    packName: pack.name,
                    allowRemoteAssets: allowRemoteSlackAssets
                )
            } else {
                request = .files(urls, packName: pack.name)
            }
        } else {
            request = .files(urls, packName: pack.name)
        }
        prepareImport(
            request,
            networkAccessGranted: allowRemoteSlackAssets,
            destination: .replace(packID: packID)
        )
    }

    func prepareGitHubUpdate(
        for packID: UUID,
        networkAccessGranted: Bool
    ) {
        guard let pack = library.packs.first(where: { $0.id == packID }),
              let github = pack.source.github,
              let repositoryURL = URL(
                  string: "https://github.com/\(github.owner)/\(github.repository)"
              ) else {
            notice = LibraryNotice(
                kind: .warning,
                title: "GitHub source unavailable",
                message: "This pack does not contain a valid GitHub source reference."
            )
            return
        }
        prepareImport(
            .github(
                repositoryURL,
                ref: github.ref,
                subdirectory: github.subdirectory,
                packName: pack.name
            ),
            networkAccessGranted: networkAccessGranted,
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

    private func pasteboardPayload(
        for item: LibraryDisplayItem
    ) throws -> PasteboardItemPayload {
        if let unicode = item.unicode {
            return .text(unicode)
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
            mediaType: Self.mediaType(for: asset.format),
            relativePath: asset.relativePath,
            originalFilename: libraryItem.sourceFilename,
            contentHash: asset.sha256,
            isAnimated: asset.frameCount > 1
        )
        return try RuntimeManagedMediaResolver()
            .resolve(media, beneath: paths.libraryRoot)
            .pasteboardPayload
    }

    private static func mediaType(
        for format: AssetFormat
    ) -> EmojiMediaType {
        switch format {
        case .png:
            .png
        case .jpeg:
            .jpeg
        case .gif:
            .gif
        case .webP:
            .webP
        }
    }

    private func finishMutation(
        message: String,
        undo: UndoMutation?
    ) async throws {
        let snapshot = try await store.snapshot()
        library = snapshot
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
        case .append:
            "Added files to \(pack.name). It now has \(pack.items.count.formatted()) emoji."
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

enum LibraryViewModelError: Error, Equatable, LocalizedError {
    case emptyPackName
    case invalidSourceURL
    case unresolvedConflict

    var errorDescription: String? {
        switch self {
        case .emptyPackName:
            "Enter a name for the pack."
        case .invalidSourceURL:
            "Source URLs must be valid HTTPS links."
        case .unresolvedConflict:
            "Every shortcode conflict needs a decision."
        }
    }
}
