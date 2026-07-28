import Foundation

enum ImportRequest: Sendable {
    case files([URL], packName: String)
    case folder(
        URL,
        packName: String? = nil,
        allowRemoteSlackAssets: Bool = false
    )
    case slackManifest(
        URL,
        packName: String? = nil,
        allowRemoteAssets: Bool = false
    )
    case zipArchive(URL, packName: String? = nil)
    case github(
        URL,
        ref: String? = nil,
        subdirectory: String? = nil,
        packName: String? = nil
    )
}

struct ImportDuplicateContentOwner: Equatable, Sendable {
    let packID: UUID
    let packName: String
    let itemID: UUID
    let shortcode: Shortcode
}

struct ImportDuplicateContentGroup: Equatable, Sendable {
    let sha256: String
    let incomingItemIDs: [UUID]
    let existingItems: [ImportDuplicateContentOwner]
}

struct ImportOrchestrator: Sendable {
    let scanner: ImportScanner
    let extractor: ZipArchiveExtractor
    let slackImporter: SlackManifestImporter
    let githubClient: GitHubImportClient
    let temporaryRootURL: URL

    init(
        scanner: ImportScanner = .init(),
        extractor: ZipArchiveExtractor = .init(),
        transport: any ImportHTTPTransport = URLSessionImportHTTPTransport(),
        githubTokenProvider: any GitHubAccessTokenProviding =
            AnonymousGitHubAccessTokenProvider(),
        githubLimits: GitHubImportLimits = .default,
        slackLimits: SlackManifestImportLimits = .default,
        temporaryRootURL: URL = FileManager.default.temporaryDirectory
    ) {
        self.scanner = scanner
        self.extractor = extractor
        slackImporter = SlackManifestImporter(
            transport: transport,
            validator: scanner.validator,
            limits: slackLimits
        )
        githubClient = GitHubImportClient(
            transport: transport,
            tokenProvider: githubTokenProvider,
            limits: githubLimits
        )
        self.temporaryRootURL = temporaryRootURL.standardizedFileURL
    }

    func prepare(
        _ request: ImportRequest,
        against library: MojiPondLibrary
    ) async throws -> ImportPreparation {
        try Task.checkCancellation()
        let workspaceURL = try makeWorkspace()
        var shouldCleanUp = true
        defer {
            if shouldCleanUp {
                try? FileManager.default.removeItem(at: workspaceURL)
            }
        }

        let scanResult: ImportScanResult
        switch request {
        case let .files(urls, packName):
            scanResult = try scanner.scanFiles(urls, packName: packName)
        case let .folder(folderURL, packName, allowRemoteSlackAssets):
            scanResult = try await scanFolder(
                at: folderURL,
                packName: packName,
                allowRemoteSlackAssets: allowRemoteSlackAssets,
                workspaceURL: workspaceURL
            )
        case let .slackManifest(manifestURL, packName, allowRemoteAssets):
            scanResult = try await slackImporter.scan(
                manifestAt: manifestURL,
                packName: packName,
                allowRemoteAssets: allowRemoteAssets,
                workingDirectory: workspaceURL
            )
        case let .zipArchive(archiveURL, packName):
            scanResult = try await scanZIPArchive(
                at: archiveURL,
                packName: packName,
                workspaceURL: workspaceURL
            )
        case let .github(repositoryURL, ref, subdirectory, packName):
            scanResult = try await scanGitHub(
                repositoryURL: repositoryURL,
                ref: ref,
                subdirectory: subdirectory,
                packName: packName,
                workspaceURL: workspaceURL
            )
        }
        try Task.checkCancellation()

        let preview = ImportCollisionAnalyzer.makePreview(
            scanResult: scanResult,
            library: library
        )
        let duplicateContent = Self.duplicateContent(
            in: preview,
            library: library
        )
        let preparation = ImportPreparation(
            preview: preview,
            duplicateContent: duplicateContent,
            workspaceURL: workspaceURL
        )
        shouldCleanUp = false
        return preparation
    }

    func prepare(
        _ request: ImportRequest,
        using store: LibraryStore
    ) async throws -> ImportPreparation {
        let library = try await store.snapshot()
        return try await prepare(request, against: library)
    }

    private func scanFolder(
        at folderURL: URL,
        packName: String?,
        allowRemoteSlackAssets: Bool,
        workspaceURL: URL
    ) async throws -> ImportScanResult {
        let root = folderURL.standardizedFileURL
        let portableManifestURL = root.appendingPathComponent(
            MojiPondLibrary.manifestFilename,
            isDirectory: false
        )
        if Self.fileOrSymbolicLinkExists(at: portableManifestURL) {
            return try scanner.scanFolder(at: root, packName: packName)
        }

        let slackManifestURL = root.appendingPathComponent(
            "emoji.json",
            isDirectory: false
        )
        if Self.fileOrSymbolicLinkExists(at: slackManifestURL) {
            return try await slackImporter.scan(
                manifestAt: slackManifestURL,
                packName: packName,
                allowRemoteAssets: allowRemoteSlackAssets,
                workingDirectory: workspaceURL
            )
        }
        return try scanner.scanFolder(at: root, packName: packName)
    }

    private func scanZIPArchive(
        at archiveURL: URL,
        packName: String?,
        workspaceURL: URL
    ) async throws -> ImportScanResult {
        let extractedURL = workspaceURL.appendingPathComponent(
            "extracted",
            isDirectory: true
        )
        _ = try extractor.extract(
            archiveAt: archiveURL,
            to: extractedURL
        )
        let root = try Self.singleArchiveRoot(in: extractedURL)
        let result = try await scanFolder(
            at: root,
            packName: packName
                ?? archiveURL.deletingPathExtension().lastPathComponent,
            allowRemoteSlackAssets: false,
            workspaceURL: workspaceURL
        )
        var preparedPack = result.preparedPack
        preparedPack.source = PackSource(
            kind: .zipArchive,
            displayLocation: archiveURL.lastPathComponent
        )
        return ImportScanResult(
            preparedPack: preparedPack,
            rejections: result.rejections,
            ignoredFileCount: result.ignoredFileCount
        )
    }

    private func scanGitHub(
        repositoryURL: URL,
        ref: String?,
        subdirectory: String?,
        packName: String?,
        workspaceURL: URL
    ) async throws -> ImportScanResult {
        let fetched = try await githubClient.fetchArchive(
            from: repositoryURL,
            ref: ref,
            subdirectory: subdirectory
        )
        try Task.checkCancellation()

        let archiveURL = workspaceURL.appendingPathComponent(
            "github.zip",
            isDirectory: false
        )
        try fetched.archiveData.write(to: archiveURL, options: [.atomic])
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o600],
            ofItemAtPath: archiveURL.path
        )
        let extractedURL = workspaceURL.appendingPathComponent(
            "github",
            isDirectory: true
        )
        _ = try extractor.extract(
            archiveAt: archiveURL,
            to: extractedURL
        )
        var root = try Self.singleArchiveRoot(in: extractedURL)
        if let subdirectory = fetched.requestedReference.subdirectory {
            root = try Self.safeSubdirectory(
                subdirectory,
                below: root
            )
        }

        let defaultName = fetched.requestedReference.subdirectory
            .map { URL(fileURLWithPath: $0).lastPathComponent }
            ?? fetched.requestedReference.repository
        let result = try await scanFolder(
            at: root,
            packName: packName ?? defaultName,
            allowRemoteSlackAssets: false,
            workspaceURL: workspaceURL
        )
        var preparedPack = result.preparedPack
        preparedPack.source = fetched.requestedReference.packSource
        preparedPack.updateMetadata.sourceRevision = fetched.commitSHA
        preparedPack.updateMetadata.sourceETag = fetched.sourceETag
        preparedPack.updateMetadata.contentSHA256 = ContentHasher.sha256(
            of: fetched.archiveData
        ).sha256
        preparedPack.manifest.sourceURL =
            fetched.requestedReference.canonicalRepositoryURL
        if let packName {
            preparedPack.name = packName
            preparedPack.manifest.name = packName
        }
        if preparedPack.manifest.packID.rawValue.hasPrefix("local.") {
            preparedPack.manifest.packID = Self.githubPackIdentifier(
                fetched.requestedReference
            )
        }
        return ImportScanResult(
            preparedPack: preparedPack,
            rejections: result.rejections,
            ignoredFileCount: result.ignoredFileCount
        )
    }

    private func makeWorkspace() throws -> URL {
        let values = try temporaryRootURL.resourceValues(forKeys: [
            .isDirectoryKey,
            .isSymbolicLinkKey
        ])
        guard values.isDirectory == true, values.isSymbolicLink != true else {
            throw ImportOrchestrationError.unsafeTemporaryRoot
        }
        let workspaceURL = temporaryRootURL.appendingPathComponent(
            ".mojipond-import-\(UUID().uuidString.lowercased())",
            isDirectory: true
        )
        try FileManager.default.createDirectory(
            at: workspaceURL,
            withIntermediateDirectories: false,
            attributes: [.posixPermissions: 0o700]
        )
        return workspaceURL
    }

    private static func singleArchiveRoot(in extractedURL: URL) throws -> URL {
        let children = try FileManager.default.contentsOfDirectory(
            at: extractedURL,
            includingPropertiesForKeys: [
                .isDirectoryKey,
                .isSymbolicLinkKey
            ],
            options: [.skipsHiddenFiles]
        )
        guard children.count == 1, let child = children.first else {
            return extractedURL
        }
        let values = try child.resourceValues(forKeys: [
            .isDirectoryKey,
            .isSymbolicLinkKey
        ])
        return values.isDirectory == true && values.isSymbolicLink != true
            ? child
            : extractedURL
    }

    private static func safeSubdirectory(
        _ relativePath: String,
        below root: URL
    ) throws -> URL {
        var candidate = root.standardizedFileURL
        let components = relativePath.split(separator: "/").map(String.init)
        for component in components {
            candidate.appendPathComponent(component, isDirectory: true)
            let values: URLResourceValues
            do {
                values = try candidate.resourceValues(forKeys: [
                    .isDirectoryKey,
                    .isSymbolicLinkKey
                ])
            } catch {
                throw ImportOrchestrationError.githubSubdirectoryNotFound(
                    relativePath
                )
            }
            guard values.isDirectory == true, values.isSymbolicLink != true else {
                throw ImportOrchestrationError.githubSubdirectoryNotFound(
                    relativePath
                )
            }
        }
        guard candidate.standardizedFileURL.path.hasPrefix(
            root.standardizedFileURL.path + "/"
        ) else {
            throw ImportOrchestrationError.githubSubdirectoryNotFound(
                relativePath
            )
        }
        return candidate
    }

    private static func githubPackIdentifier(
        _ reference: GitHubRepositoryReference
    ) -> PackIdentifier {
        let identity = [
            reference.owner.lowercased(),
            reference.repository.lowercased(),
            reference.subdirectory ?? ""
        ].joined(separator: "/")
        let digest = ContentHasher.sha256(of: Data(identity.utf8)).sha256
        return PackIdentifier(rawValue: "github.\(digest.prefix(48))")!
    }

    private static func fileOrSymbolicLinkExists(at url: URL) -> Bool {
        FileManager.default.fileExists(atPath: url.path)
            || (try? FileManager.default.destinationOfSymbolicLink(
                atPath: url.path
            )) != nil
    }

    private static func duplicateContent(
        in preview: ImportPreview,
        library: MojiPondLibrary
    ) -> [ImportDuplicateContentGroup] {
        var incomingByDigest: [String: [UUID]] = [:]
        for item in preview.preparedPack.items {
            incomingByDigest[item.asset.digest.sha256, default: []].append(item.id)
        }

        var existingByDigest: [String: [ImportDuplicateContentOwner]] = [:]
        for pack in library.packs {
            for item in pack.items {
                guard item.payload.kind == .asset,
                      let asset = item.payload.asset else {
                    continue
                }
                existingByDigest[asset.sha256, default: []].append(
                    ImportDuplicateContentOwner(
                        packID: pack.id,
                        packName: pack.name,
                        itemID: item.id,
                        shortcode: item.shortcode
                    )
                )
            }
        }

        return incomingByDigest.keys.sorted().compactMap { digest in
            let incoming = incomingByDigest[digest, default: []].sorted {
                $0.uuidString < $1.uuidString
            }
            let existing = existingByDigest[digest, default: []].sorted {
                if $0.packName != $1.packName {
                    return $0.packName < $1.packName
                }
                if $0.shortcode != $1.shortcode {
                    return $0.shortcode < $1.shortcode
                }
                return $0.itemID.uuidString < $1.itemID.uuidString
            }
            guard incoming.count + existing.count > 1 else {
                return nil
            }
            return ImportDuplicateContentGroup(
                sha256: digest,
                incomingItemIDs: incoming,
                existingItems: existing
            )
        }
    }
}

actor ImportPreparation {
    nonisolated let preview: ImportPreview
    nonisolated let duplicateContent: [ImportDuplicateContentGroup]
    nonisolated let workingDirectoryURL: URL

    private let workspaceLease: ImportWorkspaceLease
    private var state = State.ready

    init(
        preview: ImportPreview,
        duplicateContent: [ImportDuplicateContentGroup],
        workspaceURL: URL
    ) {
        self.preview = preview
        self.duplicateContent = duplicateContent
        workingDirectoryURL = workspaceURL
        workspaceLease = ImportWorkspaceLease(url: workspaceURL)
    }

    func install(
        into store: LibraryStore,
        decisions: [UUID: CollisionDecision] = [:]
    ) async throws -> EmojiPack {
        switch state {
        case .ready:
            state = .installing
        case .installing:
            throw ImportPreparationError.installAlreadyInProgress
        case .discarded:
            throw ImportPreparationError.discarded
        }

        do {
            let library = try await store.snapshot()
            let resolved = try ImportCollisionAnalyzer.resolve(
                preview: preview,
                decisions: decisions,
                library: library
            )
            let pack = try await store.install(resolved)
            workspaceLease.cleanUp()
            state = .discarded
            return pack
        } catch {
            state = .ready
            throw error
        }
    }

    func discard() throws {
        switch state {
        case .ready:
            state = .discarded
            workspaceLease.cleanUp()
        case .installing:
            throw ImportPreparationError.installAlreadyInProgress
        case .discarded:
            return
        }
    }

    private enum State {
        case ready
        case installing
        case discarded
    }
}

enum ImportPreparationError: Error, Equatable, LocalizedError, Sendable {
    case installAlreadyInProgress
    case discarded

    var errorDescription: String? {
        switch self {
        case .installAlreadyInProgress:
            "This import is already being installed."
        case .discarded:
            "This import preparation has already been discarded."
        }
    }
}

enum ImportOrchestrationError: Error, Equatable, LocalizedError, Sendable {
    case unsafeTemporaryRoot
    case githubSubdirectoryNotFound(String)

    var errorDescription: String? {
        switch self {
        case .unsafeTemporaryRoot:
            "The temporary import root is not a safe directory."
        case let .githubSubdirectoryNotFound(path):
            "GitHub subdirectory \(path) was not found in the archive."
        }
    }
}

private final class ImportWorkspaceLease: @unchecked Sendable {
    let url: URL

    private let lock = NSLock()
    private var isActive = true

    init(url: URL) {
        self.url = url
    }

    func cleanUp() {
        lock.lock()
        guard isActive else {
            lock.unlock()
            return
        }
        isActive = false
        lock.unlock()
        try? FileManager.default.removeItem(at: url)
    }

    deinit {
        cleanUp()
    }
}
